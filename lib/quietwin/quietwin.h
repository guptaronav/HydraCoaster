// Quiet-window minute math — pure, header-only, no Arduino/ESP-IDF deps.
//
// Split out of main.cpp (see the D009 section of docs/ble-protocol.md) so
// `pio test -e native` can cover the wrap arithmetic without dragging in
// BLE/NVS/time.h. Both `nowMin`/`startMin`/`endMin` are minutes-of-day
// [0, 1439] — the caller (main.cpp) is responsible for getting them into
// that domain (UTC, per the wire format) before calling in.

#pragma once

#include <cstdint>

namespace hydra {
namespace quietwin {

// True when `nowMin` falls in the half-open window [startMin, endMin).
// Handles a window that wraps past midnight (startMin > endMin, e.g.
// 1380..420 for 23:00-07:00). `startMin == endMin` is a zero-length window
// and always reads as inactive — that's what "0,0 = disabled" (the wire
// convention) falls out of for free, with no special case needed.
inline bool inQuietWindow(uint16_t nowMin, uint16_t startMin, uint16_t endMin) {
    if (startMin == endMin) return false;
    if (startMin < endMin) return nowMin >= startMin && nowMin < endMin;
    return nowMin >= startMin || nowMin < endMin; // wraps midnight
}

} // namespace quietwin
} // namespace hydra
