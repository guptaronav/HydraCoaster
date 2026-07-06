/*
 * HydraCoaster — smart drink-coaster firmware
 *
 * Hardware
 *   ESP32-C6 Feather
 *   FSR 402 (left)  → GPIO2, voltage divider with 10 kΩ pull-down
 *   FSR 402 (right) → GPIO3, voltage divider with 10 kΩ pull-down
 *   Passive piezo   → GPIO7 (PWM via LEDC)
 *
 * Behaviour
 *   Wakes from deep sleep on a timer.  If a cup is present, checks whether the
 *   user has taken a sip (FSR weight drop) and buzzes at 3 400 Hz if the
 *   reminder interval has elapsed without a detected sip.  Fetches ambient
 *   temperature from OpenWeatherMap once per hour and adjusts the interval.
 *   Returns to deep sleep between cycles.
 */

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include "secrets.h"

// ── Pin assignments ───────────────────────────────────────────────────────────
static constexpr uint8_t PIN_FSR_LEFT  = 2;
static constexpr uint8_t PIN_FSR_RIGHT = 3;
static constexpr uint8_t PIN_BUZZER    = 7;

// ── Buzzer ────────────────────────────────────────────────────────────────────
// 3 400 Hz sits above the range that most ANC headphone algorithms attenuate
static constexpr uint32_t BUZZ_FREQ_HZ  = 3400;
static constexpr uint32_t BUZZ_ON_MS    = 400;
static constexpr uint32_t BUZZ_OFF_MS   = 150;
static constexpr uint8_t  BUZZ_PULSES   = 3;
static constexpr uint8_t  LEDC_RES_BITS = 10;
static constexpr uint32_t LEDC_DUTY_50  = (1u << LEDC_RES_BITS) / 2; // 512

// ── FSR / ADC ────────────────────────────────────────────────────────────────
static constexpr int FSR_CUP_THRESHOLD = 150;  // ADC counts (0–4 095) for cup present
static constexpr int FSR_SIP_DELTA     = 250;  // drop from stored baseline → sip / lift

// ── Timing constants ─────────────────────────────────────────────────────────
static constexpr uint64_t US               = 1'000'000ULL; // µs per second
static constexpr uint64_t SLEEP_NO_CUP_US  = 60ULL  * US; // 1 min — poll when empty
static constexpr uint64_t WEATHER_PERIOD_US = 3'600ULL * US; // refresh every hour
static constexpr uint64_t SNOOZE_US         = 5ULL * 60 * US; // repeat buzz cadence
static constexpr uint32_t WIFI_TIMEOUT_MS   = 15'000UL;

// ── Temperature → reminder interval ──────────────────────────────────────────
static constexpr uint64_t INTERVAL_HOT_US  = 10ULL * 60 * US; // ≥35 °C
static constexpr uint64_t INTERVAL_WARM_US = 15ULL * 60 * US; // ≥28 °C
static constexpr uint64_t INTERVAL_MILD_US = 20ULL * 60 * US; // ≥15 °C
static constexpr uint64_t INTERVAL_COOL_US = 30ULL * 60 * US; // <15 °C

// ── RTC-persistent state (survives deep sleep) ────────────────────────────────
RTC_DATA_ATTR static uint32_t rtcBootCount      = 0;
RTC_DATA_ATTR static int      rtcFsrLeft        = 0;   // FSR reading before last sleep
RTC_DATA_ATTR static int      rtcFsrRight       = 0;
RTC_DATA_ATTR static bool     rtcCupWasPresent  = false;
RTC_DATA_ATTR static uint64_t rtcElapsedUs      = 0;   // accumulated planned-sleep time
RTC_DATA_ATTR static uint64_t rtcLastWeatherUs  = 0;
RTC_DATA_ATTR static uint64_t rtcLastSipUs      = 0;   // elapsed time at last sip / cup placement
RTC_DATA_ATTR static uint64_t rtcLastBuzzUs     = 0;   // elapsed time at last buzz (0 = never)
RTC_DATA_ATTR static uint64_t rtcReminderUs     = INTERVAL_MILD_US;
RTC_DATA_ATTR static float    rtcTempC          = 20.0f;

// ── Helpers ───────────────────────────────────────────────────────────────────

static int readFsr(uint8_t pin) {
    // Average 8 samples at 500 µs spacing to smooth ADC noise
    int32_t sum = 0;
    for (int i = 0; i < 8; ++i) {
        sum += analogRead(pin);
        delayMicroseconds(500);
    }
    return static_cast<int>(sum / 8);
}

static uint64_t tempToInterval(float tempC) {
    if (tempC >= 35.0f) return INTERVAL_HOT_US;
    if (tempC >= 28.0f) return INTERVAL_WARM_US;
    if (tempC >= 15.0f) return INTERVAL_MILD_US;
    return INTERVAL_COOL_US;
}

static void buzzReminder() {
    for (uint8_t i = 0; i < BUZZ_PULSES; ++i) {
        ledcAttach(PIN_BUZZER, BUZZ_FREQ_HZ, LEDC_RES_BITS);
        ledcWrite(PIN_BUZZER, LEDC_DUTY_50);
        delay(BUZZ_ON_MS);
        ledcWrite(PIN_BUZZER, 0);
        ledcDetach(PIN_BUZZER);
        if (i < BUZZ_PULSES - 1) delay(BUZZ_OFF_MS);
    }
}

// Returns true and updates rtcTempC / rtcReminderUs on success
static bool fetchWeather() {
    if (strlen(WIFI_SSID) == 0 || strlen(OWM_API_KEY) == 0) return false;

    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && (millis() - t0) < WIFI_TIMEOUT_MS) {
        delay(200);
    }
    if (WiFi.status() != WL_CONNECTED) {
        WiFi.disconnect(true);
        WiFi.mode(WIFI_OFF);
        Serial.println("WiFi connect failed.");
        return false;
    }

    char url[256];
    snprintf(url, sizeof(url),
        "http://api.openweathermap.org/data/2.5/weather"
        "?lat=" OWM_LAT "&lon=" OWM_LON "&units=metric&appid=" OWM_API_KEY);

    HTTPClient http;
    http.setTimeout(10000);
    http.begin(url);
    int code = http.GET();
    bool ok  = false;

    if (code == HTTP_CODE_OK) {
        JsonDocument doc;
        DeserializationError err = deserializeJson(doc, http.getStream());
        if (!err) {
            float t        = doc["main"]["temp"] | rtcTempC;
            rtcTempC       = t;
            rtcReminderUs  = tempToInterval(t);
            ok = true;
            Serial.printf("Weather: %.1f °C → remind every %llu min\n",
                t, rtcReminderUs / (60ULL * US));
        } else {
            Serial.printf("JSON parse error: %s\n", err.c_str());
        }
    } else {
        Serial.printf("Weather HTTP %d\n", code);
    }

    http.end();
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
    return ok;
}

// ── Main ──────────────────────────────────────────────────────────────────────

void setup() {
    Serial.begin(115200);
    delay(3000); // USB-CDC window: keeps port alive for esptool 1200bps touch

    ++rtcBootCount;
    analogReadResolution(12); // 0–4 095

    int  curLeft  = readFsr(PIN_FSR_LEFT);
    int  curRight = readFsr(PIN_FSR_RIGHT);
    bool cupNow   = (curLeft > FSR_CUP_THRESHOLD) || (curRight > FSR_CUP_THRESHOLD);

    Serial.printf("[Boot %u | %llu s] FSR L=%d R=%d cup=%s temp=%.1f°C\n",
        rtcBootCount, rtcElapsedUs / US,
        curLeft, curRight, cupNow ? "YES" : "NO", rtcTempC);

    uint64_t sleepUs = rtcReminderUs; // default; overridden below

    // ── No cup ───────────────────────────────────────────────────────────────
    if (!cupNow) {
        if (rtcCupWasPresent) {
            // Cup just removed — freeze the reminder clock so we don't fire
            // immediately when the cup comes back after a long absence.
            rtcLastSipUs = rtcElapsedUs;
            Serial.println("Cup removed — reminder clock frozen.");
        }
        rtcFsrLeft       = curLeft;
        rtcFsrRight      = curRight;
        rtcCupWasPresent = false;
        sleepUs          = SLEEP_NO_CUP_US;

    // ── Cup present ───────────────────────────────────────────────────────────
    } else {
        if (!rtcCupWasPresent) {
            // Cup just placed — restart reminder clock from now
            rtcLastSipUs = rtcElapsedUs;
            rtcLastBuzzUs = 0;
            Serial.println("Cup placed — reminder clock started.");
        }

        // ── Weather refresh ───────────────────────────────────────────────────
        bool fetchDue = (rtcBootCount == 1) ||
                        ((rtcElapsedUs - rtcLastWeatherUs) >= WEATHER_PERIOD_US);
        if (fetchDue) {
            if (fetchWeather()) {
                rtcLastWeatherUs = rtcElapsedUs;
            } else {
                Serial.printf("Using cached interval: %llu min\n",
                    rtcReminderUs / (60ULL * US));
            }
        }

        // ── Sip detection ──────────────────────────────────────────────────────
        // Detects a weight drop on either FSR relative to the reading stored
        // before the previous sleep.  Catches both cup lifts (cup removed and
        // returned) and gradual weight loss as liquid is consumed.
        bool sipDetected = (rtcBootCount > 1) && rtcCupWasPresent &&
                           ((rtcFsrLeft  - curLeft)  > FSR_SIP_DELTA ||
                            (rtcFsrRight - curRight) > FSR_SIP_DELTA);

        if (sipDetected) {
            Serial.printf("Sip detected (ΔL=%d ΔR=%d) — timer reset.\n",
                rtcFsrLeft - curLeft, rtcFsrRight - curRight);
            rtcLastSipUs  = rtcElapsedUs;
            rtcLastBuzzUs = 0; // clear snooze history
        }

        // ── Reminder logic ─────────────────────────────────────────────────────
        uint64_t sinceSip  = rtcElapsedUs - rtcLastSipUs;
        bool     overdue   = (sinceSip >= rtcReminderUs);
        // Buzz on first overdue wake, then again every SNOOZE_US until sip
        bool     shouldBuzz = overdue &&
                              !sipDetected &&
                              (rtcLastBuzzUs == 0 ||
                               (rtcElapsedUs - rtcLastBuzzUs) >= SNOOZE_US);

        if (shouldBuzz) {
            Serial.printf("Reminder! %llu min since last sip. Buzzing...\n",
                sinceSip / (60ULL * US));
            buzzReminder();
            rtcLastBuzzUs = rtcElapsedUs;
            sleepUs       = SNOOZE_US; // wake soon to re-check / re-buzz
        } else if (!overdue) {
            // Sleep exactly until the reminder is due
            sleepUs = rtcReminderUs - sinceSip;
        }
        // else: overdue but sip just detected — sleep a full interval

        rtcFsrLeft       = curLeft;
        rtcFsrRight      = curRight;
        rtcCupWasPresent = true;
    }

    // Advance the simulated wall clock by the planned sleep duration
    rtcElapsedUs += sleepUs;

    Serial.printf("Sleeping %llu s.\n", sleepUs / US);
    Serial.flush();
    delay(10); // drain USB-CDC TX buffer

    esp_sleep_enable_timer_wakeup(sleepUs);
    esp_deep_sleep_start();
}

void loop() {
    // Deep sleep resets the chip; execution always re-enters setup().
}
