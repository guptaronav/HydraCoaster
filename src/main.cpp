/*
 * HydraCoaster — product firmware
 *
 * NAU7802 load cell -> lib/brain (sip detection, auto-zero, reminder due) ->
 * BLE GATT per docs/ble-protocol.md. NimBLE-Arduino, no pairing/bonding.
 *
 * Two envs share this file (see platformio.ini):
 *   hydra      BLE only — the product build.
 *   hydra_ota  + WiFi/mDNS/ArduinoOTA for bench reflashing, gated behind
 *              HYDRA_WIFI_OTA so the plain `hydra` build has zero WiFi symbols.
 *
 * Hardware init sequence, alert() 3-tone buzzer + NeoPixel flash, and the
 * WiFi/OTA startup are ported verbatim (patterns only) from test_nau/main.cpp.
 *
 * Serial commands (bench convenience, mirrors test_nau):
 *   t  tare    — zero the scale (coaster EMPTY)
 *   c  calib   — set counts/gram against CAL_KNOWN_MASS_G
 *   b  buzz    — play the alert (wiring test)
 */

#include <Arduino.h>
#include <Adafruit_NAU7802.h>
#include <Adafruit_MAX1704X.h>
#include <Preferences.h>
#include <NimBLEDevice.h>
#include <esp_timer.h>
#include <time.h>
#include <sys/time.h>
#include <cstring>
#include <cmath>

#include "brain.h"

#ifdef HYDRA_WIFI_OTA
#include <WiFi.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include "secrets.h"
#endif

using hydra::Brain;
using hydra::CmdResult;
using hydra::SampleEvent;

// ── BLE UUIDs — docs/ble-protocol.md ─────────────────────────────────────────
static const char *SERVICE_UUID    = "AD0BD001-2A44-4E5B-9C8B-4B1E7C0D5E2A";
static const char *CHR_WEIGHT_UUID = "AD0BD002-2A44-4E5B-9C8B-4B1E7C0D5E2A";
static const char *CHR_SIPLOG_UUID = "AD0BD003-2A44-4E5B-9C8B-4B1E7C0D5E2A";
static const char *CHR_TIME_UUID   = "AD0BD004-2A44-4E5B-9C8B-4B1E7C0D5E2A";
static const char *CHR_INTERV_UUID = "AD0BD005-2A44-4E5B-9C8B-4B1E7C0D5E2A";
static const char *CHR_PREFS_UUID  = "AD0BD006-2A44-4E5B-9C8B-4B1E7C0D5E2A";
static const char *CHR_CMD_UUID    = "AD0BD007-2A44-4E5B-9C8B-4B1E7C0D5E2A";
static const char *CHR_STATUS_UUID = "AD0BD008-2A44-4E5B-9C8B-4B1E7C0D5E2A";

// ── Notification hardware (verbatim pattern from test_nau/main.cpp) ─────────
static constexpr uint8_t  BUZZER_PIN    = 7;
static constexpr uint32_t TONES_HZ[]    = {700, 3400, 4200};
static constexpr uint32_t TONE_MS       = 250;
static constexpr uint32_t TONE_GAP_MS   = 60;

static void alert(bool sound, bool light) {
    for (uint32_t f : TONES_HZ) {
        if (light) rgbLedWrite(PIN_NEOPIXEL, 255, 255, 255);
        if (sound) {
            ledcAttach(BUZZER_PIN, f, 10);
            ledcWrite(BUZZER_PIN, 512);
        }
        delay(TONE_MS);
        if (sound) {
            ledcWrite(BUZZER_PIN, 0);
            ledcDetach(BUZZER_PIN);
        }
        if (light) rgbLedWrite(PIN_NEOPIXEL, 0, 0, 0);
        delay(TONE_GAP_MS);
    }
}

// ── Timing tunables ───────────────────────────────────────────────────────────
static constexpr uint64_t SAMPLE_PERIOD_MS       = 100;   // feed the brain at ~10 Hz
static constexpr uint64_t WEIGHT_NOTIFY_PERIOD_MS = 500;  // D002 at ~2 Hz
static constexpr uint64_t BATTERY_PERIOD_MS       = 60'000;
static constexpr uint32_t BACKFILL_DELAY_MS       = 15;   // between D003 backfill notifies
static constexpr int      SETTLE_SAMPLES          = 80;   // ADC settle discard at boot, ~1 s @ 80 SPS
static constexpr float    CAL_KNOWN_MASS_G        = 200.0f; // bench mass for the serial 'c' command

// ── Persisted prefs/interval defaults & bounds (docs/ble-protocol.md) ───────
static constexpr uint16_t INTERVAL_DEFAULT = 1200;
static constexpr uint16_t INTERVAL_MIN     = 60;
static constexpr uint16_t INTERVAL_MAX     = 14400;
static constexpr uint8_t  PREFS_DEFAULT    = 0b111;
static constexpr uint8_t  PREFS_MASK       = 0b111; // b0 sound, b1 led, b2 reminders

// ── Sip ring buffer — persisted as one raw-struct blob (internal format,
// not the wire format; see notifySipRecord() for the 10-byte wire packet). ──
static constexpr size_t   RING_CAP   = 64;
static constexpr uint32_t RING_MAGIC = 0x48594452UL; // "HYDR"

struct SipRecord {
    uint32_t seq;         // starts at 1, monotonic, persisted
    uint32_t unixTs;       // 0 = unrecoverable
    uint16_t gramsX10;
    uint32_t bootMsHint;   // boot-relative ms, valid only while unsynced this boot
};

struct RingBlob {
    uint32_t  magic;
    uint32_t  head;
    uint32_t  count;
    uint32_t  nextSeq;
    SipRecord records[RING_CAP];
};

static RingBlob ringBlob;
static uint32_t bootStartSeq = 1; // nextSeq at boot — separates this boot's unsynced events from old ones

// ── Globals ──────────────────────────────────────────────────────────────────
static Adafruit_NAU7802  nau;
static Adafruit_MAX17048 maxlipo;
static Preferences       prefs;
static Brain             brain;
static bool              batteryOk = false;

static uint16_t reminderIntervalS = INTERVAL_DEFAULT;
static uint8_t  prefsByte         = PREFS_DEFAULT;

static NimBLECharacteristic *chrWeight   = nullptr;
static NimBLECharacteristic *chrSipLog   = nullptr;
static NimBLECharacteristic *chrTime     = nullptr;
static NimBLECharacteristic *chrInterval = nullptr;
static NimBLECharacteristic *chrPrefsCh  = nullptr;
static NimBLECharacteristic *chrCommand  = nullptr;
static NimBLECharacteristic *chrStatus   = nullptr;
static NimBLECharacteristic *chrBattery  = nullptr;

static int32_t latestRaw = 0;
static bool    haveRaw   = false;

// Deferred BLE work: onWrite runs on the NimBLE host task, which outranks
// loopTask and can preempt addSample() mid-update — so anything touching
// brain or ringBlob (or blocking ~1 s: backfill delays, alert()) must not
// run there. onWrite only sets these; loop() services them, keeping all
// brain/ring access single-task. Overwrite semantics — a second write before
// service just replaces the request (the protocol says a new last_seq
// restarts the backfill anyway).
static volatile bool     buzzPending     = false;
static volatile bool     tarePending     = false;
static volatile bool     calPending      = false;
static volatile uint16_t calGramsX10     = 0;
static volatile bool     timeSyncPending = false;
static volatile uint32_t timeSyncUnix    = 0;
static volatile bool     backfillPending = false;
static volatile bool     clearLogPending = false;
static volatile uint32_t backfillFromSeq = 0;

// ── Small helpers ────────────────────────────────────────────────────────────
static bool clockSynced() { return time(nullptr) > 1'000'000'000L; }

static int16_t clampI16(long v) {
    if (v > INT16_MAX) return INT16_MAX;
    if (v < INT16_MIN) return INT16_MIN;
    return static_cast<int16_t>(v);
}
static uint16_t clampU16(long v) {
    if (v < 0) return 0;
    if (v > UINT16_MAX) return UINT16_MAX;
    return static_cast<uint16_t>(v);
}

// ── Ring persistence ─────────────────────────────────────────────────────────
static void loadRing() {
    size_t n = prefs.getBytes("sipring", &ringBlob, sizeof(ringBlob));
    if (n != sizeof(ringBlob) || ringBlob.magic != RING_MAGIC) {
        memset(&ringBlob, 0, sizeof(ringBlob));
        ringBlob.magic   = RING_MAGIC;
        ringBlob.nextSeq = 1;
    }
}
static void saveRing() { prefs.putBytes("sipring", &ringBlob, sizeof(ringBlob)); }

static void ringPush(const SipRecord &rec) {
    size_t idx = (ringBlob.head + ringBlob.count) % RING_CAP;
    if (ringBlob.count == RING_CAP) {
        ringBlob.records[ringBlob.head] = rec;
        ringBlob.head = (ringBlob.head + 1) % RING_CAP;
    } else {
        ringBlob.records[idx] = rec;
        ++ringBlob.count;
    }
}

// Back-correct events logged this boot while unsynced: they carry bootMsHint
// (ms since boot at log time) instead of a real unix_ts. Once the clock syncs,
// unix_ts = synced_unix - (now_boot_ms - boot_ms_hint) / 1000. Events from
// earlier boots (seq < bootStartSeq) are left at unix_ts = 0 (unrecoverable).
// Idempotent: once corrected, unix_ts != 0 so the filter naturally excludes it.
static void backCorrectRing(uint32_t syncedUnix, uint64_t nowBootMs) {
    bool changed = false;
    for (size_t i = 0; i < ringBlob.count; ++i) {
        SipRecord &r = ringBlob.records[(ringBlob.head + i) % RING_CAP];
        if (r.unixTs == 0 && r.bootMsHint != 0 && r.seq >= bootStartSeq) {
            uint32_t elapsedS = static_cast<uint32_t>((nowBootMs - r.bootMsHint) / 1000);
            r.unixTs = (syncedUnix > elapsedS) ? (syncedUnix - elapsedS) : 1; // never re-mark as 0
            r.bootMsHint = 0;
            changed = true;
        }
    }
    if (changed) saveRing();
}

// ── D003 Sip Log wire packet: seq(4) unix_ts(4) grams_x10(2), all LE ────────
static void notifySipRecord(const SipRecord &r) {
    uint8_t buf[10];
    memcpy(buf + 0, &r.seq, 4);
    memcpy(buf + 4, &r.unixTs, 4);
    memcpy(buf + 8, &r.gramsX10, 2);
    chrSipLog->setValue(buf, sizeof(buf));
    chrSipLog->notify();
}

static void sendBackfill(uint32_t lastSeq) {
    for (size_t i = 0; i < ringBlob.count; ++i) {
        const SipRecord &r = ringBlob.records[(ringBlob.head + i) % RING_CAP];
        if (r.seq > lastSeq) {
            notifySipRecord(r);
            delay(BACKFILL_DELAY_MS);
        }
    }
    uint8_t term[10] = {0};
    chrSipLog->setValue(term, sizeof(term));
    chrSipLog->notify();
}

static void logSip(float grams, uint64_t nowMs) {
    SipRecord rec{};
    rec.seq        = ringBlob.nextSeq++;
    bool synced    = clockSynced();
    rec.unixTs     = synced ? static_cast<uint32_t>(time(nullptr)) : 0;
    rec.bootMsHint = synced ? 0 : static_cast<uint32_t>(nowMs);
    rec.gramsX10   = clampU16(lroundf(grams * 10.0f));
    ringPush(rec);
    saveRing();
    notifySipRecord(rec); // live sip, same characteristic backfill uses
    Serial.printf(">> Sip: %.1f g (seq=%lu)\n", grams, static_cast<unsigned long>(rec.seq));
}

// ── D002 Live Weight: grams_x10(2) flags(1) stddev_x10(2), all LE ──────────
static void updateWeightChar() {
    int16_t  gramsX10  = clampI16(lroundf(brain.smoothedGrams() * 10.0f));
    uint16_t stddevX10 = clampU16(lroundf(brain.stddevGrams() * 10.0f));
    uint8_t  flags     = 0;
    if (brain.settled())    flags |= 0x01;
    if (brain.cupPresent()) flags |= 0x02;
    if (clockSynced())      flags |= 0x04;

    uint8_t buf[5];
    memcpy(buf + 0, &gramsX10, 2);
    buf[2] = flags;
    memcpy(buf + 3, &stddevX10, 2);

    chrWeight->setValue(buf, sizeof(buf));
    chrWeight->notify(); // no-op if nobody is subscribed
}

static void updateStatusChar(uint8_t lastCmd, uint8_t result) {
    uint8_t buf[2] = {lastCmd, result};
    chrStatus->setValue(buf, sizeof(buf));
    chrStatus->notify();
}

static void updateBattery() {
    uint8_t pct = 100;
    if (batteryOk) {
        float p = maxlipo.cellPercent();
        if (p < 0.0f) p = 0.0f;
        if (p > 100.0f) p = 100.0f;
        pct = static_cast<uint8_t>(lroundf(p));
    }
    chrBattery->setValue(&pct, 1);
    chrBattery->notify(); // no-op if nobody is subscribed
}

// ── D007 Command — valid commands only set flags; loop() runs them against
// the brain and posts the D008 result there (see the deferred-work comment).
static void handleCommand(const uint8_t *data, size_t len) {
    if (len == 1 && data[0] == 0x01) {
        buzzPending = true;
    } else if (len == 1 && data[0] == 0x02) {
        tarePending = true;
    } else if (len == 3 && data[0] == 0x03) {
        uint16_t gramsX10;
        memcpy(&gramsX10, data + 1, 2);
        calGramsX10 = gramsX10;
        calPending  = true;
    } else if (len == 1 && data[0] == 0x04) {
        clearLogPending = true;
    } else {
        updateStatusChar(len > 0 ? data[0] : 0, 3); // bad command
    }
}

// ── NimBLE callbacks ─────────────────────────────────────────────────────────
class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer *server, NimBLEConnInfo &info) override {
        (void)server; (void)info;
        Serial.println(">> BLE central connected");
    }
    void onDisconnect(NimBLEServer *server, NimBLEConnInfo &info, int reason) override {
        (void)server; (void)info; (void)reason;
        Serial.println(">> BLE central disconnected");
        NimBLEDevice::startAdvertising();
    }
};

class GattCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &info) override {
        (void)info;
        NimBLEAttValue val = c->getValue();
        const uint8_t *data = val.data();
        size_t len = val.length();

        if (c == chrTime && len >= 4) {
            uint32_t unixSec;
            memcpy(&unixSec, data, 4);
            struct timeval tv;
            tv.tv_sec  = static_cast<time_t>(unixSec);
            tv.tv_usec = 0;
            settimeofday(&tv, nullptr);   // clock itself is fine inline
            timeSyncUnix    = unixSec;
            timeSyncPending = true;       // ring back-correction runs in loop()
        } else if (c == chrInterval && len >= 2) {
            // Interval/prefs stay inline: they only touch their own aligned
            // byte/16-bit globals (torn reads impossible) + NVS, which locks.
            uint16_t v16;
            memcpy(&v16, data, 2);
            if (v16 >= INTERVAL_MIN && v16 <= INTERVAL_MAX) {
                reminderIntervalS = v16;
                prefs.putUShort("interval", v16);
            } else {
                // Reject out-of-range by ignoring — restore the char's stored
                // value so a subsequent read reflects the unchanged interval.
                chrInterval->setValue(reinterpret_cast<uint8_t *>(&reminderIntervalS), 2);
            }
        } else if (c == chrPrefsCh && len >= 1) {
            prefsByte = data[0] & PREFS_MASK;
            prefs.putUChar("prefs", prefsByte);
            chrPrefsCh->setValue(&prefsByte, 1);
        } else if (c == chrCommand) {
            handleCommand(data, len);
        } else if (c == chrSipLog && len >= 4) {
            uint32_t lastSeq;
            memcpy(&lastSeq, data, 4);
            backfillFromSeq = lastSeq;
            backfillPending = true; // serviced in loop()
        }
    }
};

static ServerCallbacks serverCallbacks;
static GattCallbacks   gattCallbacks;

// ── BLE setup ────────────────────────────────────────────────────────────────
static void setupBLE() {
    NimBLEDevice::init("HydraCoaster");
    NimBLEServer *server = NimBLEDevice::createServer();
    server->setCallbacks(&serverCallbacks);

    NimBLEService *svc = server->createService(SERVICE_UUID);
    chrWeight   = svc->createCharacteristic(CHR_WEIGHT_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    chrSipLog   = svc->createCharacteristic(CHR_SIPLOG_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY);
    chrTime     = svc->createCharacteristic(CHR_TIME_UUID, NIMBLE_PROPERTY::WRITE);
    chrInterval = svc->createCharacteristic(CHR_INTERV_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE);
    chrPrefsCh  = svc->createCharacteristic(CHR_PREFS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE);
    chrCommand  = svc->createCharacteristic(CHR_CMD_UUID, NIMBLE_PROPERTY::WRITE);
    chrStatus   = svc->createCharacteristic(CHR_STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);

    chrSipLog->setCallbacks(&gattCallbacks);
    chrTime->setCallbacks(&gattCallbacks);
    chrInterval->setCallbacks(&gattCallbacks);
    chrPrefsCh->setCallbacks(&gattCallbacks);
    chrCommand->setCallbacks(&gattCallbacks);

    chrInterval->setValue(reinterpret_cast<uint8_t *>(&reminderIntervalS), 2);
    chrPrefsCh->setValue(&prefsByte, 1);
    uint8_t statusInit[2] = {0, 0};
    chrStatus->setValue(statusInit, 2);

    NimBLEService *battSvc = server->createService(NimBLEUUID(static_cast<uint16_t>(0x180F)));
    chrBattery = battSvc->createCharacteristic(NimBLEUUID(static_cast<uint16_t>(0x2A19)),
                                                NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);

    server->start(); // starts all services created above (NimBLEService::start() is a no-op in 2.x)
    updateBattery();

    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(SERVICE_UUID);
    adv->enableScanResponse(true);
    adv->start();
}

#ifdef HYDRA_WIFI_OTA
// ── WiFi + OTA (bench reflashing only — not in the plain `hydra` build) ────
static constexpr uint32_t WIFI_TIMEOUT_MS = 15'000;

static void startWifi() {
    if (strlen(WIFI_SSID) == 0) return;

    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);
    WiFi.setHostname("hydracoaster");
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && (millis() - t0) < WIFI_TIMEOUT_MS) {
        delay(200);
    }
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("WiFi connect failed — OTA unavailable this boot.");
        WiFi.mode(WIFI_OFF);
        return;
    }

    MDNS.begin("hydracoaster");
    ArduinoOTA.setHostname("hydracoaster");
    ArduinoOTA.begin();
    Serial.printf("WiFi up: %s — OTA ready\n", WiFi.localIP().toString().c_str());
}
#endif

// ── Boot-time blocking averaged read (ADC settle only — BLE isn't up yet) ──
static int32_t averageRead(int n) {
    int64_t  sum   = 0;
    int      got   = 0;
    uint32_t start = millis();
    while (got < n && (millis() - start) < 1500) {
        if (nau.available()) { sum += nau.read(); ++got; }
    }
    return got ? static_cast<int32_t>(sum / got) : 0;
}

// ── Serial debug commands (bench convenience) ───────────────────────────────
static void handleSerial() {
    if (!Serial.available()) return;
    char c = Serial.read();
    if (c == 't') {
        CmdResult r = brain.tareCommand();
        if (r == CmdResult::OK) {
            prefs.putLong("tare", brain.tare());
            Serial.printf(">> TARE ok, tare=%ld\n", static_cast<long>(brain.tare()));
        } else {
            Serial.println(">> TARE failed: not settled");
        }
    } else if (c == 'c') {
        CmdResult r = brain.calibrate(CAL_KNOWN_MASS_G);
        if (r == CmdResult::OK) {
            prefs.putFloat("cpg", brain.countsPerGram());
            Serial.printf(">> CALIBRATED %.2f counts/g\n", brain.countsPerGram());
        } else {
            Serial.println(">> CALIBRATE failed: not settled or load too small");
        }
    } else if (c == 'b') {
        alert(true, true);
    }
}

void setup() {
    rgbLedWrite(PIN_NEOPIXEL, 0, 0, 0); // dark at boot — floating data line latches noise otherwise

    Serial.begin(115200);
    delay(1000);

    if (!nau.begin()) {
        Serial.println("NAU7802 NOT FOUND — check the STEMMA QT cable / solder joints.");
        while (true) delay(200);
    }
    nau.setLDO(NAU7802_3V0);
    nau.setGain(NAU7802_GAIN_128);
    nau.setRate(NAU7802_RATE_80SPS);
    nau.calibrate(NAU7802_CALMOD_INTERNAL);
    nau.calibrate(NAU7802_CALMOD_OFFSET);

    batteryOk = maxlipo.begin();
    if (!batteryOk) Serial.println("MAX17048 not found — battery will report 100%.");

    prefs.begin("hydra", false);
    brain.setTare(prefs.getLong("tare", 0));
    brain.setCountsPerGram(prefs.getFloat("cpg", 1000.0f));
    prefsByte = prefs.getUChar("prefs", PREFS_DEFAULT) & PREFS_MASK;
    reminderIntervalS = prefs.getUShort("interval", INTERVAL_DEFAULT);
    if (reminderIntervalS < INTERVAL_MIN || reminderIntervalS > INTERVAL_MAX) {
        reminderIntervalS = INTERVAL_DEFAULT;
    }
    loadRing();
    bootStartSeq = ringBlob.nextSeq;

    (void)averageRead(SETTLE_SAMPLES); // let the ADC settle before we trust it

    setupBLE();

#ifdef HYDRA_WIFI_OTA
    startWifi();
#endif

    Serial.println("\n=== HydraCoaster ready ===");
}

void loop() {
#ifdef HYDRA_WIFI_OTA
    ArduinoOTA.handle();
#endif

    // Deferred BLE requests (set in onWrite; see comment at the flags).
    if (timeSyncPending) {
        timeSyncPending = false;
        backCorrectRing(timeSyncUnix, static_cast<uint64_t>(esp_timer_get_time() / 1000));
    }
    if (backfillPending) {
        backfillPending = false;
        sendBackfill(backfillFromSeq);
    }
    if (buzzPending) {
        buzzPending = false;
        alert(true, true);          // buzz test ignores prefs
        updateStatusChar(0x01, 0);  // D008 result once it has actually played
    }
    if (tarePending) {
        tarePending = false;
        CmdResult r = brain.tareCommand();
        if (r == CmdResult::OK) prefs.putLong("tare", brain.tare());
        updateStatusChar(0x02, static_cast<uint8_t>(r));
    }
    if (calPending) {
        calPending = false;
        CmdResult r = brain.calibrate(calGramsX10 / 10.0f);
        if (r == CmdResult::OK) prefs.putFloat("cpg", brain.countsPerGram());
        updateStatusChar(0x03, static_cast<uint8_t>(r));
    }
    if (clearLogPending) {
        clearLogPending = false;
        // Clear the ring but keep nextSeq monotonic: seqs stay unique across
        // resets, so a phone that missed the reset can never double-import.
        ringBlob.head  = 0;
        ringBlob.count = 0;
        memset(ringBlob.records, 0, sizeof(ringBlob.records));
        saveRing();
        updateStatusChar(0x04, 0);
        Serial.println(">> Sip log cleared");
    }

    while (nau.available()) {
        latestRaw = nau.read();
        haveRaw = true;
    }

    uint64_t nowMs = static_cast<uint64_t>(esp_timer_get_time() / 1000);

    static uint64_t lastTickMs = 0;
    if (haveRaw && (nowMs - lastTickMs) >= SAMPLE_PERIOD_MS) {
        lastTickMs = nowMs;

        SampleEvent ev = brain.addSample(nowMs, latestRaw);
        if (ev.autoZeroed) prefs.putLong("tare", brain.tare());
        if (ev.sipDetected) logSip(ev.sipGrams, nowMs);

        // Needs b2 (reminders) plus at least one output channel — with both
        // channels off, alert() would burn ~1 s doing nothing.
        bool remindersEnabled = (prefsByte & 0x04) && (prefsByte & 0x03);
        if (remindersEnabled && brain.reminderDue(nowMs, reminderIntervalS)) {
            alert(prefsByte & 0x01, prefsByte & 0x02);
            brain.acknowledgeReminder(nowMs);
            Serial.println(">> Reminder fired");
        }

        Serial.printf("raw=%9ld   grams=%8.1f   settled=%d cup=%d\n",
                      static_cast<long>(latestRaw), brain.smoothedGrams(),
                      brain.settled(), brain.cupPresent());
    }

    static uint64_t lastWeightMs = 0;
    if (nowMs - lastWeightMs >= WEIGHT_NOTIFY_PERIOD_MS) {
        lastWeightMs = nowMs;
        updateWeightChar();
    }

    static uint64_t lastBatteryMs = 0;
    if (nowMs - lastBatteryMs >= BATTERY_PERIOD_MS) {
        lastBatteryMs = nowMs;
        updateBattery();
    }

    handleSerial();
}
