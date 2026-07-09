/*
 * HydraCoaster load-cell demo — NAU7802 + single-point load cell.
 * Live, accurate weight in grams. Not part of production firmware yet.
 *
 * The whole conversion is one line, found once via tare + calibrate:
 *     grams = (raw - tareOffset) / countsPerGram
 *
 * Calibration is PERSISTED to flash (NVS via Preferences), so it survives
 * reboots and the reset-on-serial-connect behaviour of native USB.
 *
 * Wireless: with WiFi credentials in secrets.h the sketch broadcasts every
 * sample line over UDP (port 8809) — poc/hydra_server.py picks these up with
 * no cable and no host-IP config.  ArduinoOTA runs too, so reflashing works
 * over the air:  pio run -e nau_test_ota -t upload
 * Without credentials (or if WiFi fails) it behaves exactly as before:
 * serial-only over USB.
 *
 * Serial commands (type the letter, press Enter):
 *   t  tare    — zero the scale (run with the coaster EMPTY)
 *   c  calib   — set counts/gram (place the known mass, then press c)
 *   p  print   — show the stored tare / calibration values
 *   b  buzz    — play the 3-tone alert + NeoPixel flash (wiring test)
 *
 * Notify: send the 4 bytes "BUZZ" over UDP to port 8809 and the coaster
 * plays the alert:   echo -n BUZZ | nc -u -w1 hydracoaster.local 8809
 */

#include <Arduino.h>
#include <Adafruit_NAU7802.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include "secrets.h"

Adafruit_NAU7802 nau;
Preferences      prefs;
WiFiUDP          udp;

// ── Wireless streaming ────────────────────────────────────────────────────────
static constexpr uint16_t UDP_PORT        = 8809;    // hydra_server.py listens here
static constexpr uint32_t WIFI_TIMEOUT_MS = 15'000;
static bool      wifiUp = false;
static IPAddress streamDest;   // broadcast by default; HYDRA_HOST_IP overrides

// Non-fatal: no credentials or no network → serial-only, same as before.
static void startWifi() {
    if (strlen(WIFI_SSID) == 0) return;

    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);  // no modem sleep: fixes 1s+ latency spikes that
                           // break OTA. Costs ~70 mA — fine on USB power.
    WiFi.setHostname("hydracoaster");
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && (millis() - t0) < WIFI_TIMEOUT_MS) {
        delay(200);
    }
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("WiFi connect failed — streaming on serial only.");
        WiFi.mode(WIFI_OFF);
        return;
    }
    wifiUp = true;

    // Networks with client isolation can drop broadcasts; define HYDRA_HOST_IP
    // in secrets.h to unicast straight to the dashboard host instead.
    streamDest = WiFi.broadcastIP();
#ifdef HYDRA_HOST_IP
    streamDest.fromString(HYDRA_HOST_IP);
#endif

    MDNS.begin("hydracoaster");             // OTA target: hydracoaster.local
    ArduinoOTA.setHostname("hydracoaster");
    ArduinoOTA.begin();

    udp.begin(UDP_PORT);                    // rx too: "BUZZ" packets trigger buzz()

    Serial.printf("WiFi up: %s — UDP :%u (tx samples / rx BUZZ), OTA ready\n",
                  WiFi.localIP().toString().c_str(), UDP_PORT);
}

// ── Notification hardware ─────────────────────────────────────────────────────
static constexpr uint8_t BUZZER_PIN = 7;  // passive piezo direct — same pin as production

// Three tones per buzz, one per audience:
//  * 700 Hz  — hearing loss: low frequencies survive presbycusis best, and
//              the 50% PWM square wave adds audible harmonics for free.
//  * 3400 Hz — normal: the piezo's resonance, its loudest tone.
//  * 4200 Hz — ANC: active cancellation only nulls below ~1-2 kHz; this is
//              far outside anything it can cancel.
static constexpr uint32_t TONES_HZ[]  = {700, 3400, 4200};
static constexpr uint32_t TONE_MS     = 250;
static constexpr uint32_t TONE_GAP_MS = 60;

// Blocks ~1 s — fine: samples during a buzz are garbage anyway. The NeoPixel
// (dark otherwise) flashes with each tone — a visual channel when audio fails.
// Fresh ledcAttach per tone: the pattern the production sketch proves out;
// ledcChangeFrequency() is flaky on this core and can go silent.
// sound/light selectable so the dashboard prefs can pick channels:
// UDP "BUZZ" = both, "BEEP" = sound only, "FLASH" = light only.
static void alert(bool sound, bool light) {
    for (uint32_t f : TONES_HZ) {
        if (light) rgbLedWrite(PIN_NEOPIXEL, 255, 255, 255); // full white
        if (sound) {
            ledcAttach(BUZZER_PIN, f, 10);
            ledcWrite(BUZZER_PIN, 512);          // 50% duty
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

// The mass you place on the coaster for calibration.
static constexpr float CAL_KNOWN_MASS_G = 200.0f;

// Discard this many samples after boot so the ADC settles before we trust it.
static constexpr int SETTLE_SAMPLES = 80; // ~1 s at 80 SPS

// The two numbers that define the linear fit — loaded from flash at boot.
static int32_t tareOffset    = 0;
static float   countsPerGram = 1000.0f;

// ── Averaged raw read: blocks until n fresh samples or 1 s timeout ───────────
static int32_t averageRead(int n) {
    int64_t  sum   = 0;
    int      got   = 0;
    uint32_t start = millis();
    while (got < n && (millis() - start) < 1500) {
        if (nau.available()) { sum += nau.read(); ++got; }
    }
    return got ? static_cast<int32_t>(sum / got) : 0;
}

static void printCalibration() {
    Serial.printf(">> STORED: tareOffset = %ld counts, %.2f counts/g\n",
                  static_cast<long>(tareOffset), countsPerGram);
}

static void handleSerial(int32_t raw) {
    if (!Serial.available()) return;
    char c = Serial.read();
    if (c == 't') {
        tareOffset = averageRead(64);
        prefs.putLong("tare", tareOffset);           // persist
        Serial.printf(">> TARE: offset = %ld counts (saved)\n",
                      static_cast<long>(tareOffset));
    } else if (c == 'c') {
        int32_t loaded = averageRead(64);
        float   delta  = static_cast<float>(loaded - tareOffset);
        Serial.printf(">> calib raw: loaded=%ld  tare=%ld  delta=%.0f counts\n",
                      static_cast<long>(loaded), static_cast<long>(tareOffset), delta);
        if (fabsf(delta) > 200.0f) {
            countsPerGram = delta / CAL_KNOWN_MASS_G;
            prefs.putFloat("cpg", countsPerGram);    // persist
            Serial.printf(">> CALIBRATED: %.0f g -> %.2f counts/g (saved)\n",
                          CAL_KNOWN_MASS_G, countsPerGram);
        } else {
            Serial.println(">> CALIB FAILED: load too small — check mounting/wiring.");
        }
    } else if (c == 'p') {
        printCalibration();
    } else if (c == 'b') {
        Serial.println(">> BUZZ");
        alert(true, true);
    }
}

void setup() {
    // NeoPixel dark at boot: its floating data line otherwise latches random
    // colors from electrical noise (the mystery bright-blue incident).
    rgbLedWrite(PIN_NEOPIXEL, 0, 0, 0);

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

    // Load persisted calibration (namespace "hydra").
    prefs.begin("hydra", false);
    tareOffset    = prefs.getLong("tare", 0);
    countsPerGram = prefs.getFloat("cpg", 1000.0f);

    startWifi();

    // Let the ADC settle before we report anything — discard early samples.
    (void)averageRead(SETTLE_SAMPLES);

    Serial.println("\n=== NAU7802 load-cell demo (persistent cal) ===");
    Serial.println("Commands: [t]are empty | place 200g then [c]alibrate | [p]rint cal | [b]uzz");
    printCalibration();
    Serial.println();
}

void loop() {
    if (wifiUp) {
        ArduinoOTA.handle();
        // Our own broadcasts land here too — the strncmp ignores them.
        if (udp.parsePacket() > 0) {
            char cmd[8] = {0};
            udp.read(cmd, sizeof(cmd) - 1);
            if      (strncmp(cmd, "BUZZ", 4)  == 0) alert(true,  true);
            else if (strncmp(cmd, "BEEP", 4)  == 0) alert(true,  false);
            else if (strncmp(cmd, "FLASH", 5) == 0) alert(false, true);
        }
    }

    int32_t raw = averageRead(8);
    handleSerial(raw);
    float grams = (raw - tareOffset) / countsPerGram;

    char line[48];
    snprintf(line, sizeof(line), "raw=%9ld   grams=%8.1f",
             static_cast<long>(raw), static_cast<double>(grams));
    Serial.println(line);

    if (wifiUp && WiFi.status() == WL_CONNECTED) {
        udp.beginPacket(streamDest, UDP_PORT);
        udp.print(line);
        udp.endPacket();
    }
    delay(50);
}
