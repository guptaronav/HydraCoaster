/*
 * FSR live-readout test — not part of the production firmware.
 * Prints raw ADC counts from both pressure sensors continuously so the
 * thresholds in src/main.cpp (FSR_CUP_THRESHOLD, FSR_SIP_DELTA) can be
 * calibrated against real hardware.
 */

#include <Arduino.h>

static constexpr uint8_t PIN_FSR_LEFT  = 2;
static constexpr uint8_t PIN_FSR_RIGHT = 3;

void setup() {
    Serial.begin(115200);
    delay(1000);
    analogReadResolution(12);
    Serial.println("FSR live test — GPIO2 (left) / GPIO3 (right), 0-4095");
    Serial.println("Press on each sensor and watch the values change.");
}

void loop() {
    int left  = analogRead(PIN_FSR_LEFT);
    int right = analogRead(PIN_FSR_RIGHT);
    Serial.printf("L=%4d  R=%4d\n", left, right);
    delay(150);
}
