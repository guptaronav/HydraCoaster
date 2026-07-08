#include "brain.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace hydra {

namespace {
constexpr uint64_t WINDOW_MS         = static_cast<uint64_t>(WINDOW_S * 1000.0f);
constexpr uint64_t SETTLE_HOLD_MS    = static_cast<uint64_t>(SETTLE_HOLD_S * 1000.0f);
constexpr uint64_t ZERO_TRACK_MIN_MS = static_cast<uint64_t>(ZERO_TRACK_MIN_S * 1000.0f);
constexpr uint64_t REMIND_REPEAT_MS  = static_cast<uint64_t>(REMIND_REPEAT_S) * 1000ULL;
constexpr uint64_t GOOD_HOUR_MS      = static_cast<uint64_t>(GOOD_HOUR_S) * 1000ULL;
constexpr int32_t  CALIBRATE_MIN_DELTA_COUNTS = 50;

float medianOfGrams(const std::array<float, WINDOW_CAP> &grams, size_t n) {
    std::array<float, WINDOW_CAP> sorted{};
    std::copy(grams.begin(), grams.begin() + n, sorted.begin());
    std::sort(sorted.begin(), sorted.begin() + n);
    if (n % 2 == 1) return sorted[n / 2];
    return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0f;
}

int32_t medianOfRaws(const std::array<int32_t, WINDOW_CAP> &raws, size_t n) {
    std::array<int32_t, WINDOW_CAP> sorted{};
    std::copy(raws.begin(), raws.begin() + n, sorted.begin());
    std::sort(sorted.begin(), sorted.begin() + n);
    if (n % 2 == 1) return sorted[n / 2];
    double avg = (static_cast<int64_t>(sorted[n / 2 - 1]) + sorted[n / 2]) / 2.0;
    return static_cast<int32_t>(std::lround(avg));
}
} // namespace

float Brain::toGrams(int32_t raw) const {
    float cpg = countsPerGram_ != 0.0f ? countsPerGram_ : 1.0f;
    return static_cast<float>(raw - tare_) / cpg;
}

void Brain::pushSample(uint64_t nowMs, int32_t rawCounts) {
    size_t idx = (windowHead_ + windowCount_) % WINDOW_CAP;
    if (windowCount_ == WINDOW_CAP) {
        window_[windowHead_] = {nowMs, rawCounts};
        windowHead_ = (windowHead_ + 1) % WINDOW_CAP;
    } else {
        window_[idx] = {nowMs, rawCounts};
        ++windowCount_;
    }
}

void Brain::evictOld(uint64_t nowMs) {
    uint64_t cutoff = nowMs > WINDOW_MS ? nowMs - WINDOW_MS : 0;
    while (windowCount_ > 0 && window_[windowHead_].ms < cutoff) {
        windowHead_ = (windowHead_ + 1) % WINDOW_CAP;
        --windowCount_;
    }
}

int32_t Brain::medianRaw() const {
    std::array<int32_t, WINDOW_CAP> raws{};
    for (size_t i = 0; i < windowCount_; ++i) {
        raws[i] = window_[(windowHead_ + i) % WINDOW_CAP].raw;
    }
    return medianOfRaws(raws, windowCount_);
}

void Brain::recordSip(uint64_t nowMs, float grams) {
    size_t idx = (sipHead_ + sipCount_) % SIP_LOG_CAP;
    if (sipCount_ == SIP_LOG_CAP) {
        sips_[sipHead_] = {nowMs, grams};
        sipHead_ = (sipHead_ + 1) % SIP_LOG_CAP;
    } else {
        sips_[idx] = {nowMs, grams};
        ++sipCount_;
    }
}

void Brain::recompute(uint64_t nowMs, SampleEvent &ev) {
    if (windowCount_ == 0) return;

    std::array<float, WINDOW_CAP> grams{};
    for (size_t i = 0; i < windowCount_; ++i) {
        grams[i] = toGrams(window_[(windowHead_ + i) % WINDOW_CAP].raw);
    }

    float sum = 0.0f;
    for (size_t i = 0; i < windowCount_; ++i) sum += grams[i];
    float mean = sum / static_cast<float>(windowCount_);

    float variance = 0.0f;
    for (size_t i = 0; i < windowCount_; ++i) {
        float d = grams[i] - mean;
        variance += d * d;
    }
    variance /= static_cast<float>(windowCount_);

    smoothed_   = mean;
    stddev_     = std::sqrt(variance);
    stable_     = (windowCount_ >= MIN_SAMPLES) && (stddev_ < STABLE_STD_G);
    cupPresent_ = smoothed_ > CUP_MIN_G;

    // Settle-hold: require sustained stability before trusting a value.
    if (stable_) {
        if (!stableSinceValid_) {
            stableSinceMs_ = nowMs;
            stableSinceValid_ = true;
        }
    } else {
        stableSinceValid_ = false;
    }
    settled_ = stable_ && stableSinceValid_ && (nowMs - stableSinceMs_) >= SETTLE_HOLD_MS;

    // Auto-zero: the zero point drifts over time (thermal + load-cell
    // relaxation) and jumps on every reboot. Re-zero on any settled cup-free
    // reading below ZERO_TRACK_G: near-zero is drift, and negative is
    // provably stale (weight can't be < 0). Rate-limited so it can't chase
    // a genuinely light object sitting on the coaster.
    if (settled_ && !cupPresent_ && smoothed_ < ZERO_TRACK_G &&
        (nowMs - lastZeroMs_) >= ZERO_TRACK_MIN_MS) {
        tare_ = medianRaw();
        lastZeroMs_ = nowMs;
        ev.autoZeroed = true;
    }

    // Sip detection (plateau ratchet): a settled plateau SIP_MIN_G below the
    // highest one seen counts as a sip. Rises (refills, upward drift) just
    // ratchet the baseline, so drift never fakes or masks a sip.
    if (settled_ && cupPresent_) {
        float plateau = medianOfGrams(grams, windowCount_);
        if (!hasPlateau_ || plateau > plateauG_) {
            plateauG_ = plateau;
            hasPlateau_ = true;
        } else if (plateau < plateauG_ - SIP_MIN_G) {
            float amount = plateauG_ - plateau;
            lastDrinkMs_ = nowMs;
            plateauG_ = plateau;
            recordSip(nowMs, amount);
            ev.sipDetected = true;
            ev.sipGrams = amount;
        }
    }
}

SampleEvent Brain::addSample(uint64_t nowMs, int32_t rawCounts) {
    if (!hasSample_) {
        lastDrinkMs_ = nowMs;
        hasSample_ = true;
    }
    pushSample(nowMs, rawCounts);
    evictOld(nowMs);

    SampleEvent ev;
    recompute(nowMs, ev);
    return ev;
}

float Brain::behaviorFactor(uint64_t nowMs) const {
    uint64_t cutoff = nowMs > GOOD_HOUR_MS ? nowMs - GOOD_HOUR_MS : 0;
    float total = 0.0f;
    for (size_t i = 0; i < sipCount_; ++i) {
        const SipRecord &s = sips_[(sipHead_ + i) % SIP_LOG_CAP];
        if (s.ms >= cutoff) total += s.grams;
    }
    return total >= GOOD_HOUR_G ? BEHAVIOR_FACTOR : 1.0f;
}

bool Brain::reminderDue(uint64_t nowMs, uint16_t intervalS) const {
    if (!hasSample_) return false;
    float factor = behaviorFactor(nowMs);
    uint64_t neededMs = static_cast<uint64_t>(static_cast<float>(intervalS) * factor * 1000.0f);
    bool overdue  = (nowMs - lastDrinkMs_) >= neededMs;
    bool repeatOk = !hasReminded_ || (nowMs - lastRemindMs_) >= REMIND_REPEAT_MS;
    return overdue && repeatOk;
}

void Brain::acknowledgeReminder(uint64_t nowMs) {
    lastRemindMs_ = nowMs;
    hasReminded_ = true;
}

CmdResult Brain::tareCommand() {
    if (!settled_) return CmdResult::NO_SIGNAL;
    tare_ = medianRaw();
    return CmdResult::OK;
}

CmdResult Brain::calibrate(float knownMassG) {
    if (!settled_ || knownMassG <= 0.0f) return CmdResult::NO_SIGNAL;
    int32_t delta = medianRaw() - tare_;
    if (std::abs(delta) < CALIBRATE_MIN_DELTA_COUNTS) return CmdResult::LOAD_TOO_SMALL;
    countsPerGram_ = static_cast<float>(delta) / knownMassG;
    return CmdResult::OK;
}

} // namespace hydra
