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
 * Serial commands (type the letter, press Enter):
 *   t  tare    — zero the scale (run with the coaster EMPTY)
 *   c  calib   — set counts/gram (place the known mass, then press c)
 *   p  print   — show the stored tare / calibration values
 */

#include <Arduino.h>
#include <Adafruit_NAU7802.h>
#include <Preferences.h>

Adafruit_NAU7802 nau;
Preferences      prefs;

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
    }
}

void setup() {
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

    // Let the ADC settle before we report anything — discard early samples.
    (void)averageRead(SETTLE_SAMPLES);

    Serial.println("\n=== NAU7802 load-cell demo (persistent cal) ===");
    Serial.println("Commands: [t]are empty | place 200g then [c]alibrate | [p]rint cal");
    printCalibration();
    Serial.println();
}

void loop() {
    int32_t raw = averageRead(8);
    handleSerial(raw);
    float grams = (raw - tareOffset) / countsPerGram;
    Serial.printf("raw=%9ld   grams=%8.1f\n", static_cast<long>(raw), grams);
    delay(50);
}
