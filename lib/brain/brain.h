// HydraCoaster reminder brain — pure decision logic, no Arduino/ESP-IDF deps.
//
// Ported from poc/hydra_server.py (class Hydra: compute(), remind_factors(),
// remind_after_s(), maybe_remind()). The firmware sketch drives this with raw
// load-cell counts at ~10 Hz and reads back derived state / events; all NVS
// persistence, BLE, and timing come from the caller — this class only ever
// sees time as an explicit now_ms so it stays trivially unit-testable.
//
// Dropped from the Python original: the "session" concept (replaced by the
// trailing-60-minute behavior factor) and weather (lives on the phone; the
// caller passes in an already weather-adjusted interval_s).

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace hydra {

// ── Tunables — same values/semantics as poc/hydra_server.py ─────────────────
constexpr float    WINDOW_S         = 2.5f;    // rolling sample window
constexpr float    STABLE_STD_G     = 3.0f;    // "stable" if stddev under this many grams
constexpr float    SETTLE_HOLD_S    = 1.5f;    // must stay stable this long before it's trusted
constexpr uint8_t  MIN_SAMPLES      = 8;       // need at least this many samples to judge stability
constexpr float    CUP_MIN_G        = 20.0f;   // above this a cup is considered present
constexpr float    ZERO_TRACK_G     = 10.0f;   // auto-rezero any settled cup-free reading below this
constexpr float    ZERO_TRACK_MIN_S = 5.0f;    // at most once per this many seconds
constexpr float    SIP_MIN_G        = 10.0f;   // settled plateau drop that counts as a sip
constexpr uint32_t REMIND_REPEAT_S  = 300;     // nag at most this often
constexpr float    GOOD_HOUR_G      = 250.0f;  // trailing-hour intake that earns the behavior factor
constexpr float    BEHAVIOR_FACTOR  = 1.5f;    // interval multiplier once GOOD_HOUR_G is hit
constexpr uint32_t GOOD_HOUR_S      = 3600;    // trailing window for the behavior factor

constexpr size_t WINDOW_CAP  = 32; // fixed cap on the rolling raw-sample window
constexpr size_t SIP_LOG_CAP = 32; // fixed ring of recent sips (for the behavior factor)

// Command result codes — mirrored on the BLE command-status characteristic.
enum class CmdResult : uint8_t {
    OK             = 0,
    NO_SIGNAL      = 1, // window not settled (includes: no samples yet)
    LOAD_TOO_SMALL = 2, // calibration delta too small to be a real load
};

// Notable events produced by a single addSample() call.
struct SampleEvent {
    bool  autoZeroed  = false; // tare changed this update — caller should persist it
    bool  sipDetected = false; // a sip was detected this update
    float sipGrams    = 0.0f;  // amount of the sip, valid only if sipDetected
};

class Brain {
public:
    Brain() = default;

    // Calibration — caller persists these (NVS) and restores them at boot.
    void    setTare(int32_t tareCounts) { tare_ = tareCounts; }
    int32_t tare() const { return tare_; }
    void    setCountsPerGram(float countsPerGram) { countsPerGram_ = countsPerGram; }
    float   countsPerGram() const { return countsPerGram_; }

    // Feed one raw load-cell sample (~10 Hz). Returns any notable events.
    SampleEvent addSample(uint64_t nowMs, int32_t rawCounts);

    // Derived state, valid after the first addSample().
    float smoothedGrams() const { return smoothed_; }
    float stddevGrams() const { return stddev_; }
    bool  stable() const { return stable_; }
    bool  settled() const { return settled_; }
    bool  cupPresent() const { return cupPresent_; }

    // 1.5x once trailing-60-min intake reaches GOOD_HOUR_G, else 1.0x.
    float behaviorFactor(uint64_t nowMs) const;

    // Due when now - last_drink >= interval_s * behaviorFactor(now), AND
    // at least REMIND_REPEAT_S has passed since the last acknowledged
    // reminder. Caller calls acknowledgeReminder() once it has acted (BLE
    // notify / buzz) to start the repeat-cap window.
    bool reminderDue(uint64_t nowMs, uint16_t intervalS) const;
    void acknowledgeReminder(uint64_t nowMs);

    // Commands for the BLE command characteristic.
    CmdResult tareCommand();
    CmdResult calibrate(float knownMassG);

private:
    struct RawSample { uint64_t ms; int32_t raw; };
    struct SipRecord  { uint64_t ms; float grams; };

    float   toGrams(int32_t raw) const;
    void    pushSample(uint64_t nowMs, int32_t rawCounts);
    void    evictOld(uint64_t nowMs);
    int32_t medianRaw() const;
    void    recompute(uint64_t nowMs, SampleEvent &ev);
    void    recordSip(uint64_t nowMs, float grams);

    // Rolling raw-sample window (ring buffer, oldest-first).
    std::array<RawSample, WINDOW_CAP> window_{};
    size_t windowHead_  = 0;
    size_t windowCount_ = 0;

    // Calibration.
    int32_t tare_          = 0;
    float   countsPerGram_ = 1.0f;

    // Derived state.
    float smoothed_   = 0.0f;
    float stddev_     = 0.0f;
    bool  stable_     = false;
    bool  settled_    = false;
    bool  cupPresent_ = false;

    bool     stableSinceValid_ = false;
    uint64_t stableSinceMs_    = 0;

    uint64_t lastZeroMs_ = 0;

    bool  hasPlateau_ = false;
    float plateauG_   = 0.0f;

    bool     hasSample_  = false;
    uint64_t lastDrinkMs_ = 0;

    bool     hasReminded_  = false;
    uint64_t lastRemindMs_ = 0;

    // Recent sips, ring buffer (oldest-first), for the behavior factor.
    std::array<SipRecord, SIP_LOG_CAP> sips_{};
    size_t sipHead_  = 0;
    size_t sipCount_ = 0;
};

} // namespace hydra
