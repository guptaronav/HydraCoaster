/*
 * HydraCoaster weight & consumption demo — not part of the production firmware.
 *
 * Goal: turn the two FSR readings into a stable weight in grams, then measure
 * how much liquid the user drank by comparing settled weight plateaus.
 *
 * Why this is interesting on noisy sensors:
 *   1. ADC counts are NON-LINEAR with force. FSR *conductance* (1/R) is roughly
 *      linear with force, so we convert ADC -> conductance before scaling.
 *   2. A raw reading is meaningless mid-touch. We only trust a weight once it
 *      has SETTLED — i.e. a rolling window of samples has low standard deviation
 *      (the cup is sitting still). This is the "average over reliable time
 *      periods" step.
 *   3. Drinking is detected by differencing consecutive settled plateaus while
 *      the cup is present. A lighter plateau than before => liquid consumed.
 *
 * This same state machine drops straight onto a NAU7802 + load cell later:
 * only readCombinedConductance() / the calibration scale need to change.
 *
 * Serial commands (type the letter, press enter):
 *   t  tare   — zero the scale to the current reading (empty coaster)
 *   c  calib  — record scale using a known mass sitting on the coaster now
 *   r  reset  — reset the consumed-total counter and baseline
 */

#include <Arduino.h>
#include <math.h>

// ── Pins ──────────────────────────────────────────────────────────────────────
static constexpr uint8_t PIN_FSR_LEFT  = 2;
static constexpr uint8_t PIN_FSR_RIGHT = 3;

// ── ADC ───────────────────────────────────────────────────────────────────────
static constexpr int   ADC_MAX     = 4095;   // 12-bit
static constexpr float ADC_CLAMP   = 4094.0; // avoid divide-by-zero at rail

// ── Calibration (persisted only in RAM for this demo) ─────────────────────────
// weight_g = (combinedConductance - tareConductance) * gramsPerUnit
static float tareConductance = 0.0f;
static float gramsPerUnit    = 300.0f; // rough default; use 'c' to set properly
static constexpr float CAL_KNOWN_MASS_G = 200.0f; // known mass you place for 'c'

// ── Settling detector ─────────────────────────────────────────────────────────
static constexpr int    WINDOW_SIZE        = 24;   // samples in rolling window
static constexpr uint32_t SAMPLE_PERIOD_MS = 60;   // ~1.4 s window
static constexpr float  SETTLE_STD_G        = 4.0f; // stable if std-dev under this
static constexpr float  CUP_PRESENT_G       = 30.0f;// above this => a cup is on it
static constexpr float  MIN_SIP_G           = 5.0f; // ignore plateau drops smaller

// ── Water assumption ──────────────────────────────────────────────────────────
static constexpr float WATER_G_PER_ML = 1.0f; // 1 g ≈ 1 mL for water

// ── State ─────────────────────────────────────────────────────────────────────
static float   window[WINDOW_SIZE];
static int     windowCount = 0;
static int     windowHead  = 0;

static bool    haveSettled       = false; // a stable plateau is currently held
static float   settledWeight     = 0.0f;  // value of the current plateau
static float   lastCupPlateau    = NAN;   // last settled weight WITH cup present
static float   totalConsumedG    = 0.0f;

// ── Helpers ───────────────────────────────────────────────────────────────────

// One averaged FSR sample -> conductance proxy (∝ force).
static float fsrConductance(uint8_t pin) {
    int32_t sum = 0;
    for (int i = 0; i < 4; ++i) { sum += analogRead(pin); delayMicroseconds(300); }
    float adc = sum / 4.0f;
    if (adc > ADC_CLAMP) adc = ADC_CLAMP;
    if (adc < 1.0f)      adc = 1.0f;
    // Divider: FSR top, 10k pull-down. conductance ∝ adc / (max - adc).
    return adc / (ADC_MAX - adc);
}

static float readCombinedConductance() {
    return fsrConductance(PIN_FSR_LEFT) + fsrConductance(PIN_FSR_RIGHT);
}

static float conductanceToGrams(float g) {
    return (g - tareConductance) * gramsPerUnit;
}

static void pushSample(float grams) {
    window[windowHead] = grams;
    windowHead = (windowHead + 1) % WINDOW_SIZE;
    if (windowCount < WINDOW_SIZE) ++windowCount;
}

static void windowStats(float &mean, float &stddev) {
    float sum = 0.0f;
    for (int i = 0; i < windowCount; ++i) sum += window[i];
    mean = sum / windowCount;
    float var = 0.0f;
    for (int i = 0; i < windowCount; ++i) {
        float d = window[i] - mean;
        var += d * d;
    }
    stddev = sqrtf(var / windowCount);
}

static void handleSerial(float currentGrams, float currentConductance) {
    if (!Serial.available()) return;
    char c = Serial.read();
    if (c == 't') {
        tareConductance = currentConductance;
        lastCupPlateau  = NAN;
        Serial.println(">> TARE: zeroed to current reading.");
    } else if (c == 'c') {
        // Known mass is sitting on the coaster right now.
        float delta = currentConductance - tareConductance;
        if (delta > 1e-6f) {
            gramsPerUnit = CAL_KNOWN_MASS_G / delta;
            Serial.printf(">> CALIBRATED: %.1f g known -> %.1f g/unit\n",
                          CAL_KNOWN_MASS_G, gramsPerUnit);
        } else {
            Serial.println(">> CALIB FAILED: place the known mass first, then tare, then 'c'.");
        }
    } else if (c == 'r') {
        totalConsumedG = 0.0f;
        lastCupPlateau = NAN;
        Serial.println(">> RESET: consumed total cleared.");
    }
}

// ── Arduino ───────────────────────────────────────────────────────────────────

void setup() {
    Serial.begin(115200);
    delay(1000);
    analogReadResolution(12);
    Serial.println("=== HydraCoaster weight demo ===");
    Serial.println("Commands: [t]are empty coaster | place 200g then [c]alibrate | [r]eset total");
    Serial.println("Place a cup, let it settle, lift & drink, set back down.\n");
}

void loop() {
    float conductance = readCombinedConductance();
    float grams       = conductanceToGrams(conductance);

    handleSerial(grams, conductance);
    pushSample(grams);

    float mean, stddev;
    windowStats(mean, stddev);

    bool windowFull = (windowCount >= WINDOW_SIZE);
    bool isStable   = windowFull && (stddev < SETTLE_STD_G);
    bool cupPresent = mean > CUP_PRESENT_G;

    // ── Settling edge: we just reached a new stable plateau ───────────────────
    if (isStable && !haveSettled) {
        haveSettled   = true;
        settledWeight = mean;

        if (cupPresent) {
            if (!isnan(lastCupPlateau)) {
                float drop = lastCupPlateau - settledWeight;
                if (drop >= MIN_SIP_G) {
                    totalConsumedG += drop;
                    Serial.printf(
                        "  >>> DRANK %.0f g (~%.0f mL) | session total %.0f g (~%.0f mL)\n",
                        drop, drop / WATER_G_PER_ML,
                        totalConsumedG, totalConsumedG / WATER_G_PER_ML);
                } else if (drop < -MIN_SIP_G) {
                    Serial.printf("  >>> REFILLED +%.0f g\n", -drop);
                }
            }
            lastCupPlateau = settledWeight;
            Serial.printf("  [settled] cup = %.0f g\n", settledWeight);
        } else {
            Serial.println("  [settled] coaster empty");
        }
    }

    // Leaving a plateau (someone touched/lifted the cup)
    if (!isStable && haveSettled) {
        haveSettled = false;
    }

    // ── Live status line ──────────────────────────────────────────────────────
    Serial.printf("now=%6.0fg  mean=%6.0fg  std=%5.1f  %s  %s\n",
                  grams, mean, stddev,
                  cupPresent ? "CUP " : "----",
                  isStable   ? "STABLE" : "  ... ");

    delay(SAMPLE_PERIOD_MS);
}
