#!/usr/bin/env python3
"""Self-check: fake firmware UDP broadcasts must reach the dashboard state.

Run:  python3 poc/test_udp_stream.py   (no device required)
"""

import socket
import threading
import time

import hydra_server as hs


def main():
    hs.UDP_PORT = 18809  # own port — the real coaster broadcasts on 8809
    threading.Thread(target=hs.udp_reader, daemon=True).start()
    time.sleep(0.2)  # let the socket bind

    # Neutral calibration so grams == raw counts.
    hs.HYDRA.tare_counts, hs.HYDRA.counts_per_gram = 0.0, 1.0

    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for _ in range(12):  # > MIN_SAMPLES, same line format as the firmware
        tx.sendto(b"raw=      250   grams=   250.0", ("127.0.0.1", hs.UDP_PORT))
        time.sleep(0.02)
    time.sleep(0.1)
    hs.HYDRA.compute()

    snap = hs.HYDRA.snapshot()
    assert snap["connected"], f"not connected: {snap}"
    assert snap["port"].startswith("wifi "), f"bad source: {snap['port']}"
    assert abs(snap["grams"] - 250.0) < 0.01, f"bad grams: {snap['grams']}"
    assert snap["cup_present"], "cup should read present at 250 g"

    # Link drops to disconnected after LINK_TIMEOUT_S of silence.
    hs.HYDRA.last_rx = time.time() - hs.LINK_TIMEOUT_S - 0.1
    assert not hs.HYDRA.snapshot()["connected"], "should disconnect on silence"

    # Auto-zero tracking: empty + settled + near zero → tare re-captures.
    hs.CALIB_PATH = "/tmp/hydra_test_calibration.json"  # don't touch real cal
    hs.PREFS_PATH = "/tmp/hydra_test_prefs.json"        # or real prefs
    hs.HYDRA.prefs = dict(hs.DEFAULT_PREFS)
    hs.HYDRA.samples.clear()
    hs.HYDRA.stable_since = None
    t_end = time.time() + hs.SETTLE_HOLD_S + 0.6
    while time.time() < t_end:  # drifted zero: steady 7 counts ≈ 7 g
        tx.sendto(b"raw=        7   grams=     7.0", ("127.0.0.1", hs.UDP_PORT))
        hs.HYDRA.compute()
        time.sleep(0.05)
    assert abs(hs.HYDRA.tare_counts - 7) < 1, f"tare not tracked: {hs.HYDRA.tare_counts}"
    assert abs(hs.HYDRA.snapshot()["grams"]) < 1.5, "reading should re-zero"

    # Stale-tare recovery: a reboot shifts raw counts, reading goes deeply
    # negative (impossible weight) → tare re-captures once settled.
    hs.HYDRA.samples.clear()
    hs.HYDRA.stable_since = None
    hs.HYDRA.last_zero_at = 0.0
    t_end = time.time() + hs.SETTLE_HOLD_S + 0.6
    while time.time() < t_end:
        tx.sendto(b"raw=     -500   grams=  -500.0", ("127.0.0.1", hs.UDP_PORT))
        hs.HYDRA.compute()
        time.sleep(0.05)
    assert abs(hs.HYDRA.tare_counts + 500) < 1, f"stale tare not recovered: {hs.HYDRA.tare_counts}"

    # Drink detection: cup lands at 300 g, then a settled 50 g drop = sip.
    def settle(raw_line):
        hs.HYDRA.samples.clear()
        hs.HYDRA.stable_since = None
        t_end = time.time() + hs.SETTLE_HOLD_S + 0.6
        while time.time() < t_end:
            tx.sendto(raw_line, ("127.0.0.1", hs.UDP_PORT))
            hs.HYDRA.compute()
            time.sleep(0.05)

    settle(b"raw=     -200   grams=   300.0")  # tare is -500 → reads 300 g
    hs.HYDRA.last_drink_at = 0.0
    settle(b"raw=     -250   grams=   250.0")  # plateau drops 50 g
    assert time.time() - hs.HYDRA.last_drink_at < 5, "sip not detected"

    # Reminder: overdue + cup present → one BUZZ to the device, then cooldown.
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("127.0.0.1", 28810))
    rx.settimeout(2)
    hs.UDP_PORT = 28810  # maybe_remind sends BUZZ to <device_ip>:UDP_PORT
    hs.HYDRA.last_drink_at = time.time() - hs.REMIND_AFTER_S - 1
    assert hs.HYDRA.maybe_remind(), "reminder should fire"
    assert rx.recvfrom(16)[0] == b"BUZZ", "BUZZ not received"
    assert not hs.HYDRA.maybe_remind(), "reminder should respect cooldown"

    # Manual buzz (the dashboard button) ignores all timers.
    assert hs.HYDRA.buzz(), "manual buzz should send"
    assert rx.recvfrom(16)[0] == b"BUZZ", "manual BUZZ not received"

    # Reminder no longer needs a cup on the coaster.
    hs.HYDRA.cup_present = False
    hs.HYDRA.last_remind_at = 0.0
    assert hs.HYDRA.maybe_remind(), "should remind without a cup"
    assert rx.recvfrom(16)[0] == b"BUZZ", "cup-free BUZZ not received"

    # Prefs steer the channels: led-only → FLASH; reminders off → nothing.
    hs.HYDRA.prefs.update(sound=False, led=True)
    hs.HYDRA.last_remind_at = 0.0
    assert hs.HYDRA.maybe_remind(), "led-only reminder should fire"
    assert rx.recvfrom(16)[0] == b"FLASH", "expected FLASH for led-only"
    hs.HYDRA.prefs.update(remind=False)
    hs.HYDRA.last_remind_at = 0.0
    assert not hs.HYDRA.maybe_remind(), "disabled reminders should not fire"
    hs.HYDRA.prefs.update(sound=True, remind=True)

    # Hot/dry weather shortens the interval; a big recent session stretches it.
    base = hs.REMIND_AFTER_S
    hs.WEATHER.update(temp_c=32.0, humidity=20.0)
    assert hs.HYDRA.remind_after_s() < base * 0.5, "heat should shorten interval"
    hs.WEATHER.update(temp_c=20.0, humidity=50.0)
    hs.HYDRA.session["log"].append({"consumed_g": 300.0, "ended_at": time.time()})
    assert abs(hs.HYDRA.remind_after_s() - base * 1.5) < 1, "recent session should stretch"

    print("OK: UDP stream, link timeout, auto-zero, stale-tare recovery, sip "
          "detection, reminders (cup-free + weather/session-aware), and buzz")


if __name__ == "__main__":
    main()
