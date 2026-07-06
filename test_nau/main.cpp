/*
 * HydraCoaster load-cell demo — NAU7802 + single-point load cell.
 * Live, accurate weight in grams. Not part of production firmware yet.
 *
 * The whole conversion is one line, found once via tare + calibrate:
 *     grams = (raw - tareOffset) / countsPerGram
 *
 * Serial commands (type the letter, press Enter):
 *   t  tare    — zero the scale (run with the coaster EMPTY)
 *   c  calib   — set counts/gram (place the known mass below, then press c)
 *   z  zero-total (reserved for later drink tracking)
 */

#include <Arduino.h>
#include <Adafruit_NAU7802.h>

Adafruit_NAU7802 nau;

// The mass you place on the coaster for calibration (weigh it on a kitchen
// scale if you don't have a proper calibration weight).
static constexpr float CAL_KNOWN_MASS_G = 200.0f;

// Step 3 & 4 results — the two numbers that define the linear fit.
static int32_t tareOffset    = 0;
static float   countsPerGram = 1000.0f; // placeholder until 'c' is run

// ── Averaged raw read (Step 6): blocks until n fresh samples or 1 s timeout ──
static int32_t averageRead(int n) {
    int64_t sum = 0;
    int     got = 0;
    uint32_t start = millis();
    while (got < n && (millis() - start) < 1000) {
        if (nau.available()) { sum += nau.read(); ++got; }
    }
    return got ? static_cast<int32_t>(sum / got) : 0;
}

static void handleSerial(int32_t raw) {
    if (!Serial.available()) return;
    char c = Serial.read();
    if (c == 't') {
        tareOffset = averageRead(64);
        Serial.printf(">> TARE: offset = %ld counts\n", static_cast<long>(tareOffset));
    } else if (c == 'c') {
        int32_t loaded = averageRead(64);
        float   delta  = static_cast<float>(loaded - tareOffset);
        if (fabsf(delta) > 500.0f) {
            countsPerGram = delta / CAL_KNOWN_MASS_G;
            Serial.printf(">> CALIBRATED: %.0f g -> %.2f counts/g\n",
                          CAL_KNOWN_MASS_G, countsPerGram);
        } else {
            Serial.println(">> CALIB FAILED: place the known mass first, then press 'c'.");
        }
    }
}

void setup() {
    Serial.begin(115200);
    delay(1000);

    // Step 1 — bring up the chip over I2C (STEMMA QT).
    if (!nau.begin()) {
        Serial.println("NAU7802 NOT FOUND — check the STEMMA QT cable / solder joints.");
        while (true) delay(200);
    }
    nau.setLDO(NAU7802_3V0);         // excite the bridge from the on-chip LDO
    nau.setGain(NAU7802_GAIN_128);   // load-cell signals are tiny — amplify hard
    nau.setRate(NAU7802_RATE_80SPS); // 80 samples/sec

    // Internal analog calibrations (zeroes the ADC's own offset).
    nau.calibrate(NAU7802_CALMOD_INTERNAL);
    nau.calibrate(NAU7802_CALMOD_OFFSET);

    Serial.println("=== NAU7802 load-cell demo ===");
    Serial.println("1) Empty coaster, press 't' to tare.");
    Serial.printf ("2) Place %.0f g on it, press 'c' to calibrate.\n", CAL_KNOWN_MASS_G);
    Serial.println("Then read live grams. Swap Green/White wires if grams go negative.\n");

    // Auto-tare once at boot (assumes empty on power-up).
    tareOffset = averageRead(64);
}

void loop() {
    int32_t raw = averageRead(8);       // Step 2 + 6: fresh averaged sample
    handleSerial(raw);
    float grams = (raw - tareOffset) / countsPerGram; // Step 5
    Serial.printf("raw=%9ld   grams=%8.1f\n", static_cast<long>(raw), grams);
    delay(50);
}
