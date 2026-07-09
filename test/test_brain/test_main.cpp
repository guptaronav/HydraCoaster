// Native Unity tests for lib/brain. Time is fully simulated (uint64_t ms
// counters advanced by the test) — no real sleeping, so these run instantly.

#include <unity.h>

#include <cstdint>

#include "brain.h"
#include "quietwin.h"

using hydra::Brain;
using hydra::CmdResult;
using hydra::SampleEvent;
using hydra::quietwin::inQuietWindow;

namespace {

constexpr uint64_t STEP_MS = 100; // ~10 Hz sampling, matches the real sensor loop

// Feed `n` samples of a constant raw value, `stepMs` apart, advancing `nowMs`.
// Aggregates any sip/auto-zero events seen along the way.
struct FeedResult {
    int      sipCount      = 0;
    float    lastSipGrams  = 0.0f;
    uint64_t lastSipAtMs   = 0;
    int      autoZeroCount = 0;
};

FeedResult feedSamples(Brain &b, uint64_t &nowMs, int32_t raw, int n, uint64_t stepMs = STEP_MS) {
    FeedResult r;
    for (int i = 0; i < n; ++i) {
        nowMs += stepMs;
        SampleEvent ev = b.addSample(nowMs, raw);
        if (ev.sipDetected) {
            ++r.sipCount;
            r.lastSipGrams = ev.sipGrams;
            r.lastSipAtMs = nowMs;
        }
        if (ev.autoZeroed) ++r.autoZeroCount;
    }
    return r;
}

// Feed a constant raw value long enough to flush the 2.5 s window and clear
// the 1.5 s settle-hold from any prior (different) reading. 80 samples @
// 100 ms = 8 s of simulated time — generous margin over the ~4 s needed.
FeedResult feedUntilSettled(Brain &b, uint64_t &nowMs, int32_t raw) {
    return feedSamples(b, nowMs, raw, 80);
}

} // namespace

void setUp(void) {}
void tearDown(void) {}

// 1. Settled plateau drop >= 10 g yields exactly one sip with the right amount.
void test_settled_drop_is_a_sip(void) {
    Brain b;
    uint64_t now = 0;

    FeedResult first = feedUntilSettled(b, now, 200); // establish the plateau
    TEST_ASSERT_TRUE(b.settled());
    TEST_ASSERT_TRUE(b.cupPresent());
    TEST_ASSERT_EQUAL_INT(0, first.sipCount);

    FeedResult drop = feedUntilSettled(b, now, 150); // 50 g drop
    TEST_ASSERT_TRUE(b.settled());
    TEST_ASSERT_EQUAL_INT(1, drop.sipCount);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 50.0f, drop.lastSipGrams);
}

// 2. A rise (refill) only ratchets the baseline — no sip. A later drop off
//    the NEW max is detected correctly.
void test_rise_ratchets_without_sip_then_drop_from_new_max_sips(void) {
    Brain b;
    uint64_t now = 0;

    feedUntilSettled(b, now, 200); // first plateau

    FeedResult rise = feedUntilSettled(b, now, 300); // refill, +100 g
    TEST_ASSERT_EQUAL_INT(0, rise.sipCount);

    FeedResult smallDropFromOldMax = feedUntilSettled(b, now, 280); // -20 g off the NEW max (300)
    TEST_ASSERT_EQUAL_INT(1, smallDropFromOldMax.sipCount);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 20.0f, smallDropFromOldMax.lastSipGrams);
}

// 3. A drop under the 10 g sip threshold never registers as a sip.
void test_small_drop_is_not_a_sip(void) {
    Brain b;
    uint64_t now = 0;

    feedUntilSettled(b, now, 200);
    FeedResult small = feedUntilSettled(b, now, 195); // -5 g, under SIP_MIN_G
    TEST_ASSERT_EQUAL_INT(0, small.sipCount);
}

// 4. Auto-zero fires only settled + cup-free + <10 g, rate-limited to 5 s,
//    and moves tare to the window median.
void test_auto_zero_rate_limited_and_updates_tare(void) {
    Brain b;
    uint64_t now = 0;
    TEST_ASSERT_EQUAL_INT32(0, b.tare());

    // 99 samples @ 100 ms: settle happens ~2.3 s in; the first zero-track
    // window opens at t=5.0 s (99th sample lands at t=9.9 s).
    FeedResult upToBoundary = feedSamples(b, now, 5, 99);
    TEST_ASSERT_FALSE(b.cupPresent());
    TEST_ASSERT_TRUE(b.settled());
    TEST_ASSERT_EQUAL_INT(1, upToBoundary.autoZeroCount);
    TEST_ASSERT_EQUAL_INT32(5, b.tare());

    // One more sample lands exactly at t=10.0 s — second window opens.
    FeedResult atSecondWindow = feedSamples(b, now, 5, 1);
    TEST_ASSERT_EQUAL_INT(1, atSecondWindow.autoZeroCount);

    // Nothing fires again immediately after (rate limit holds).
    FeedResult justAfter = feedSamples(b, now, 5, 5);
    TEST_ASSERT_EQUAL_INT(0, justAfter.autoZeroCount);
}

// 5. Behavior factor: >=250 g sipped in the trailing 60 min => 1.5x; sips
//    older than 60 min drop out of the window.
void test_behavior_factor_thresholds_and_expires(void) {
    Brain b;
    uint64_t now = 0;

    feedUntilSettled(b, now, 500);                 // first plateau
    feedUntilSettled(b, now, 350);                 // sip #1: 150 g
    feedUntilSettled(b, now, 500);                 // refill, ratchet back up
    feedUntilSettled(b, now, 350);                 // sip #2: 150 g (total 300 g)

    TEST_ASSERT_EQUAL_FLOAT(1.5f, b.behaviorFactor(now));

    uint64_t muchLater = now + (61ULL * 60 * 1000); // 61 minutes later
    TEST_ASSERT_EQUAL_FLOAT(1.0f, b.behaviorFactor(muchLater));
}

// 6. Reminder: not due before interval, due after, repeat capped at 300 s,
//    and the interval scales by the behavior factor.
void test_reminder_due_repeat_cap_and_behavior_scaling(void) {
    Brain b;
    uint64_t now = 1000;
    b.addSample(now, 0); // first sample only — starts the last-drink clock

    const uint16_t intervalS = 1200;

    TEST_ASSERT_FALSE(b.reminderDue(now + 1199 * 1000ULL, intervalS));
    TEST_ASSERT_TRUE(b.reminderDue(now + 1200 * 1000ULL, intervalS));

    uint64_t remindedAt = now + 1200 * 1000ULL;
    b.acknowledgeReminder(remindedAt);

    // Still overdue on drinking, but the 300 s repeat cap blocks re-firing.
    TEST_ASSERT_FALSE(b.reminderDue(remindedAt + 100 * 1000ULL, intervalS));
    TEST_ASSERT_TRUE(b.reminderDue(remindedAt + 300 * 1000ULL, intervalS));

    // Behavior factor scales the interval: sip enough to earn 1.5x, then
    // confirm the reminder needs 1.5x as long from the new last-drink time.
    Brain scaled;
    uint64_t t = 1000;
    scaled.addSample(t, 0);
    feedUntilSettled(scaled, t, 500);
    FeedResult sip = feedUntilSettled(scaled, t, 240); // single 260 g sip clears GOOD_HOUR_G
    TEST_ASSERT_EQUAL_INT(1, sip.sipCount);
    TEST_ASSERT_EQUAL_FLOAT(1.5f, scaled.behaviorFactor(t));

    uint64_t lastDrinkAt = sip.lastSipAtMs; // the sip resets the last-drink clock, not the feed's end time
    uint64_t neededMs = static_cast<uint64_t>(intervalS) * 1500; // interval * 1.5 factor, in ms
    TEST_ASSERT_FALSE(scaled.reminderDue(lastDrinkAt + neededMs - 1000, intervalS));
    TEST_ASSERT_TRUE(scaled.reminderDue(lastDrinkAt + neededMs, intervalS));
}

// 7. Calibrate: too-small delta => code 2; good delta => correct cpg;
//    tare on an unsettled window => code 1.
void test_tare_and_calibrate_result_codes(void) {
    Brain fresh;
    TEST_ASSERT_EQUAL_INT(static_cast<int>(CmdResult::NO_SIGNAL), static_cast<int>(fresh.tareCommand()));
    TEST_ASSERT_EQUAL_INT(static_cast<int>(CmdResult::NO_SIGNAL), static_cast<int>(fresh.calibrate(200.0f)));

    Brain b;
    uint64_t now = 0;
    feedUntilSettled(b, now, 1000);
    TEST_ASSERT_EQUAL_INT(static_cast<int>(CmdResult::OK), static_cast<int>(b.tareCommand()));
    TEST_ASSERT_EQUAL_INT32(1000, b.tare());

    feedUntilSettled(b, now, 1020); // delta 20 counts from the new tare — too small
    TEST_ASSERT_EQUAL_INT(static_cast<int>(CmdResult::LOAD_TOO_SMALL), static_cast<int>(b.calibrate(200.0f)));

    feedUntilSettled(b, now, 1500); // delta 500 counts — good load
    TEST_ASSERT_EQUAL_INT(static_cast<int>(CmdResult::OK), static_cast<int>(b.calibrate(200.0f)));
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 2.5f, b.countsPerGram());
}

// 8. Quiet window (D009, lib/quietwin): non-wrapping window, inside/outside
//    and both boundaries (inclusive start, exclusive end).
void test_quiet_window_non_wrapping(void) {
    TEST_ASSERT_FALSE(inQuietWindow(479, 480, 600));  // just before start
    TEST_ASSERT_TRUE(inQuietWindow(480, 480, 600));   // exactly at start
    TEST_ASSERT_TRUE(inQuietWindow(599, 480, 600));   // just before end
    TEST_ASSERT_FALSE(inQuietWindow(600, 480, 600));  // exactly at end
    TEST_ASSERT_FALSE(inQuietWindow(601, 480, 600));  // just after end
}

// 9. Quiet window wrapping midnight (e.g. 23:00-07:00 => 1380..420): active
//    on both sides of the midnight rollover, inactive in the daytime gap.
void test_quiet_window_wraps_midnight(void) {
    TEST_ASSERT_TRUE(inQuietWindow(1380, 1380, 420));  // exactly at start (23:00)
    TEST_ASSERT_TRUE(inQuietWindow(1439, 1380, 420));  // 23:59
    TEST_ASSERT_TRUE(inQuietWindow(0, 1380, 420));      // midnight
    TEST_ASSERT_TRUE(inQuietWindow(419, 1380, 420));    // 06:59
    TEST_ASSERT_FALSE(inQuietWindow(420, 1380, 420));   // exactly at end (07:00)
    TEST_ASSERT_FALSE(inQuietWindow(1379, 1380, 420));  // 22:59, just before start
    TEST_ASSERT_FALSE(inQuietWindow(720, 1380, 420));   // noon, well outside
}

// 10. start == end is always disabled, regardless of value — this is how
//     "0,0 = disabled" falls out for free with no separate flag.
void test_quiet_window_equal_bounds_is_disabled(void) {
    TEST_ASSERT_FALSE(inQuietWindow(0, 0, 0));
    TEST_ASSERT_FALSE(inQuietWindow(700, 700, 700));
    TEST_ASSERT_FALSE(inQuietWindow(0, 500, 500));
    TEST_ASSERT_FALSE(inQuietWindow(1439, 500, 500));
}

int main(int argc, char **argv) {
    UNITY_BEGIN();
    RUN_TEST(test_settled_drop_is_a_sip);
    RUN_TEST(test_rise_ratchets_without_sip_then_drop_from_new_max_sips);
    RUN_TEST(test_small_drop_is_not_a_sip);
    RUN_TEST(test_auto_zero_rate_limited_and_updates_tare);
    RUN_TEST(test_behavior_factor_thresholds_and_expires);
    RUN_TEST(test_reminder_due_repeat_cap_and_behavior_scaling);
    RUN_TEST(test_tare_and_calibrate_result_codes);
    RUN_TEST(test_quiet_window_non_wrapping);
    RUN_TEST(test_quiet_window_wraps_midnight);
    RUN_TEST(test_quiet_window_equal_bounds_is_disabled);
    return UNITY_END();
}
