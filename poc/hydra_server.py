#!/usr/bin/env python3
"""
HydraCoaster POC bridge + live dashboard.

Reads RAW load-cell counts from the ESP32-C6 — wirelessly via UDP broadcast
(the nau_test sketch sends "raw=<counts>  grams=<value>" lines on port 8809
when WiFi is up), or over USB serial as a fallback (same lines).  ALL
calibration and smoothing lives here on the host, so:
  * calibration uses any custom known mass (no firmware reflash)
  * the averaging / session logic can be tuned instantly

Pipeline:
  raw counts --> time-windowed samples --> median-settled plateau -->
  grams = (raw - tare) / counts_per_gram --> drinking-session tracking

Run:  python3 poc/hydra_server.py
"""

import glob
import json
import os
import re
import socket
import statistics
import threading
import time
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import serial  # pyserial

# ── Tunables ──────────────────────────────────────────────────────────────────
BAUD             = 115200
HTTP_PORT        = 8808
UDP_PORT         = 8809    # firmware broadcasts sample lines here
LINK_TIMEOUT_S   = 2.0     # no samples for this long → "no device"
WINDOW_SECONDS   = 2.5     # rolling window used for smoothing + stability
STABLE_STD_G     = 3.0     # "stable" if std-dev under this many grams
SETTLE_HOLD_S    = 1.5     # must stay stable THIS long before a value locks in
MIN_SAMPLES      = 8       # need at least this many samples to judge stability
CUP_MIN_G        = 20.0    # above this a cup is considered present
ZERO_TRACK_G     = 10.0    # auto-re-zero any settled cup-free reading below this
ZERO_TRACK_MIN_S = 5.0     # at most once per this many seconds
SIP_MIN_G        = 10.0    # settled plateau drop that counts as a drink
REMIND_AFTER_S   = 20 * 60 # base interval: buzz when no drink for this long
REMIND_REPEAT_S  = 5 * 60  # then nag at most this often
GOOD_SESSION_G   = 250.0   # a recent session this big earns a longer interval
WEATHER_REFRESH_S = 30 * 60
SERIAL_GLOB      = "/dev/cu.usbmodem*"

RAW_RE   = re.compile(r"raw=\s*(-?\d+)")
HERE     = os.path.dirname(os.path.abspath(__file__))
CALIB_PATH = os.path.join(HERE, "calibration.json")


def pick_port():
    ports = sorted(glob.glob(SERIAL_GLOB))
    return ports[0] if ports else None


# ── Weather (drives the dynamic reminder interval) ────────────────────────────
SECRETS_H = os.path.join(HERE, "..", "include", "secrets.h")
WEATHER = {"temp_c": None, "humidity": None, "city": None, "at": 0.0}


def _secret(name):
    """Read a #define string from the firmware's secrets.h — one credential
    store for the whole project, never committed."""
    try:
        with open(SECRETS_H) as f:
            m = re.search(rf'#define\s+{name}\s+"([^"]*)"', f.read())
            return m.group(1) if m else None
    except OSError:
        return None


OWM_LAT, OWM_LON = _secret("OWM_LAT"), _secret("OWM_LON")


def weather_loop():
    key = _secret("OWM_API_KEY")
    if not (key and OWM_LAT and OWM_LON):
        print("No OWM credentials in secrets.h — reminders use the static interval.")
        return
    url = (f"https://api.openweathermap.org/data/2.5/weather"
           f"?lat={OWM_LAT}&lon={OWM_LON}&units=metric&appid={key}")
    while True:
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                d = json.load(r)
            WEATHER.update(temp_c=float(d["main"]["temp"]),
                           humidity=float(d["main"]["humidity"]),
                           city=d.get("name") or None,
                           at=time.time())
        except Exception:
            pass  # keep the last reading; retry next cycle
        time.sleep(WEATHER_REFRESH_S)


# ── Notification preferences (persisted) ──────────────────────────────────────
PREFS_PATH = os.path.join(HERE, "prefs.json")
DEFAULT_PREFS = {"sound": True, "led": True, "remind": True}


def load_prefs():
    try:
        with open(PREFS_PATH) as f:
            d = json.load(f)
            return {k: bool(d.get(k, v)) for k, v in DEFAULT_PREFS.items()}
    except Exception:
        return dict(DEFAULT_PREFS)


def save_prefs(prefs):
    try:
        with open(PREFS_PATH, "w") as f:
            json.dump(prefs, f)
    except Exception:
        pass


def load_calibration():
    try:
        with open(CALIB_PATH) as f:
            d = json.load(f)
            return float(d.get("tare", 0.0)), float(d.get("cpg", 1.0)), float(d.get("known_mass", 200.0))
    except Exception:
        return 0.0, 1.0, 200.0


def save_calibration(tare, cpg, known_mass):
    try:
        with open(CALIB_PATH, "w") as f:
            json.dump({"tare": tare, "cpg": cpg, "known_mass": known_mass}, f)
    except Exception:
        pass


class Hydra:
    """Shared state: rolling raw samples, host-side calibration, sessions."""

    def __init__(self):
        self.lock    = threading.Lock()
        self.samples = deque()        # (timestamp, raw_counts)

        # Host-side calibration (persisted across restarts).
        self.tare_counts, self.counts_per_gram, self.known_mass = load_calibration()

        # Derived, recomputed continuously.
        self.smoothed_g  = 0.0
        self.stddev_g    = 0.0
        self.stable      = False      # instantaneously quiet
        self.settled     = False      # quiet AND held long enough to trust
        self.cup_present = False
        self.stable_since = None
        self.last_settled_cup_g = None
        self.last_zero_at = 0.0

        # Drink reminder: clock starts at launch so we never buzz immediately.
        self.prev_plateau_g = None
        self.last_drink_at  = time.time()
        self.last_remind_at = 0.0
        self.prefs = load_prefs()

        self.last_rx = 0.0            # time of the newest sample, any transport
        self.port = None              # human label of the active transport
        self.session = {
            "active": False, "start_g": 0.0, "consumed_g": 0.0,
            "started_at": None, "log": [],
        }

    # -- helpers -------------------------------------------------------------
    def _to_grams(self, raw):
        cpg = self.counts_per_gram if self.counts_per_gram else 1.0
        return (raw - self.tare_counts) / cpg

    def _window_raws(self):
        return [r for (_, r) in self.samples]

    # -- data in -------------------------------------------------------------
    def add_sample(self, raw, source=None):
        now = time.time()
        with self.lock:
            self.last_rx = now
            if source:
                self.port = source
            self.samples.append((now, raw))
            cutoff = now - WINDOW_SECONDS
            while self.samples and self.samples[0][0] < cutoff:
                self.samples.popleft()

    def compute(self):
        with self.lock:
            raws = self._window_raws()
            if not raws:
                return
            now = time.time()
            grams = [self._to_grams(r) for r in raws]
            mean_g = sum(grams) / len(grams)
            var_g  = sum((x - mean_g) ** 2 for x in grams) / len(grams)

            self.smoothed_g  = mean_g
            self.stddev_g    = var_g ** 0.5
            self.stable      = (len(grams) >= MIN_SAMPLES and self.stddev_g < STABLE_STD_G)
            self.cup_present = mean_g > CUP_MIN_G

            # Settle-hold: require sustained stability before trusting a value.
            if self.stable:
                if self.stable_since is None:
                    self.stable_since = now
            else:
                self.stable_since = None
            self.settled = self.stable and self.stable_since is not None \
                and (now - self.stable_since) >= SETTLE_HOLD_S

            # Auto-zero tracking: the zero point drifts over time (thermal +
            # load-cell relaxation, measured ~2 g/min) and jumps on every
            # reboot/OTA flash (the NAU7802 re-runs its offset cal). Re-zero
            # on ANY settled cup-free reading below +ZERO_TRACK_G: near-zero
            # is drift, and negative is provably stale (weight can't be < 0).
            # ponytail: anything lighter than ZERO_TRACK_G left on the coaster
            # gets slowly zeroed away — fine, cups weigh far more than 10 g.
            if (self.settled and not self.cup_present
                    and self.smoothed_g < ZERO_TRACK_G
                    and (now - self.last_zero_at) >= ZERO_TRACK_MIN_S):
                self.tare_counts = statistics.median(raws)
                self.last_zero_at = now
                save_calibration(self.tare_counts, self.counts_per_gram, self.known_mass)

            # Lock in a robust plateau reading (median rejects spikes) only when
            # the weight has been settled for the full hold period.
            if self.settled and self.cup_present:
                self.last_settled_cup_g = statistics.median(grams)
                # Drink detection: a settled plateau SIP_MIN_G below the highest
                # one seen counts as a sip. Rises (refills, and the +2 g/min
                # upward drift) just ratchet the baseline, so drift never fakes
                # or masks a sip.
                p = self.last_settled_cup_g
                if self.prev_plateau_g is None or p > self.prev_plateau_g:
                    self.prev_plateau_g = p
                elif p < self.prev_plateau_g - SIP_MIN_G:
                    self.last_drink_at  = now
                    self.prev_plateau_g = p
                if self.session["active"] and self.last_settled_cup_g is not None:
                    drop = self.session["start_g"] - self.last_settled_cup_g
                    self.session["consumed_g"] = max(0.0, drop)

    # -- calibration (host-side) --------------------------------------------
    def _settled_raw(self):
        """Median raw over the window — the reliable measurement statistic."""
        raws = self._window_raws()
        return statistics.median(raws) if raws else None

    def tare(self):
        with self.lock:
            r = self._settled_raw()
            if r is None:
                return False
            self.tare_counts = r
            save_calibration(self.tare_counts, self.counts_per_gram, self.known_mass)
            return True

    def calibrate(self, known_mass_g):
        with self.lock:
            r = self._settled_raw()
            if r is None or known_mass_g <= 0:
                return False, "no signal"
            delta = r - self.tare_counts
            if abs(delta) < 50:  # counts — essentially no response
                return False, "load too small / check wiring"
            self.counts_per_gram = delta / known_mass_g
            self.known_mass = known_mass_g
            save_calibration(self.tare_counts, self.counts_per_gram, self.known_mass)
            return True, "ok"

    # -- drink reminder --------------------------------------------------------
    def remind_factors(self):
        """[(label, multiplier)] currently adjusting the base interval.
        ponytail: crude tiers, not a physiology model — tune when the
        pacing annoys you."""
        f = []
        t, h = WEATHER["temp_c"], WEATHER["humidity"]
        if t is not None:
            if t >= 30:
                f.append(("hot", 0.5))
            elif t >= 25:
                f.append(("warm", 0.75))
        if h is not None and h < 30:
            f.append(("dry air", 0.85))
        log = self.session["log"]
        if log:
            last = log[-1]
            if (time.time() - last.get("ended_at", 0)) < 3600 \
                    and last["consumed_g"] >= GOOD_SESSION_G:
                f.append(("recent session", 1.5))
        return f

    def remind_after_s(self):
        """Current 'optimal' interval between drinks."""
        k = 1.0
        for _, m in self.remind_factors():
            k *= m
        return REMIND_AFTER_S * k

    def _send_cmd(self, cmd):
        with self.lock:
            wifi = self.port is not None and self.port.startswith("wifi ")
            ip = self.port.split()[1] if wifi else None
        if not ip:
            return False
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.sendto(cmd, (ip, UDP_PORT))
        return True

    def buzz(self):
        """Full test alert (dashboard button) — both channels, ignores prefs."""
        return self._send_cmd(b"BUZZ")

    def maybe_remind(self):
        """Alert when a drink is overdue — cup on the coaster or not.
        Channels follow prefs: BUZZ = sound+light, BEEP / FLASH = one only."""
        now = time.time()
        with self.lock:
            p = self.prefs
            cmd = (b"BUZZ" if p["sound"] and p["led"] else
                   b"BEEP" if p["sound"] else
                   b"FLASH" if p["led"] else None)
            due = (p["remind"] and cmd is not None
                   and (now - self.last_rx) < LINK_TIMEOUT_S
                   and self.port is not None and self.port.startswith("wifi ")
                   and (now - self.last_drink_at) >= self.remind_after_s()
                   and (now - self.last_remind_at) >= REMIND_REPEAT_S)
            if not due:
                return False
            self.last_remind_at = now
        return self._send_cmd(cmd)

    # -- sessions ------------------------------------------------------------
    def start_session(self):
        with self.lock:
            base = self.last_settled_cup_g
            if base is None:
                base = self.smoothed_g
            self.session.update(active=True, start_g=base,
                                consumed_g=0.0, started_at=time.time())

    def end_session(self):
        with self.lock:
            if not self.session["active"]:
                return
            dur = time.time() - (self.session["started_at"] or time.time())
            self.session["log"].append({
                "consumed_g": round(self.session["consumed_g"], 1),
                "start_g":    round(self.session["start_g"], 1),
                "duration_s": int(dur),
                "when":       time.strftime("%H:%M"),
                "ended_at":   time.time(),
            })
            self.session["active"] = False

    # -- snapshot for the UI -------------------------------------------------
    def snapshot(self):
        with self.lock:
            s = self.session
            return {
                "connected":   (time.time() - self.last_rx) < LINK_TIMEOUT_S,
                "port":        self.port,
                "grams":       round(self.smoothed_g, 1),
                "stddev":      round(self.stddev_g, 1),
                "stable":      self.stable,
                "settled":     self.settled,
                "cup_present": self.cup_present,
                "last_drink_s": int(time.time() - self.last_drink_at),
                "remind_after_s": int(self.remind_after_s()),
                "remind_base_s": REMIND_AFTER_S,
                "remind_factors": [{"label": l, "x": m} for l, m in self.remind_factors()],
                "prefs": dict(self.prefs),
                "weather": {"temp_c": WEATHER["temp_c"], "humidity": WEATHER["humidity"]},
                "location": {"city": WEATHER["city"], "lat": OWM_LAT, "lon": OWM_LON},
                "calibration": {
                    "counts_per_gram": round(self.counts_per_gram, 3),
                    "tare":            round(self.tare_counts, 1),
                    "known_mass":      round(self.known_mass, 1),
                },
                "session": {
                    "active":     s["active"],
                    "start_g":    round(s["start_g"], 1),
                    "consumed_g": round(s["consumed_g"], 1),
                    "duration_s": int(time.time() - s["started_at"]) if s["active"] and s["started_at"] else 0,
                    "log":        list(reversed(s["log"][-8:])),
                },
            }


HYDRA = Hydra()


def serial_reader():
    """Continuously read the serial port; reconnect on loss. USB fallback."""
    while True:
        port = pick_port()
        if not port:
            time.sleep(1.0)
            continue
        try:
            ser = serial.Serial()
            ser.port = port
            ser.baudrate = BAUD
            ser.timeout = 0.3
            ser.dtr = False
            ser.rts = False
            ser.open()
            while True:
                line = ser.readline().decode(errors="replace")
                if not line:
                    continue
                m = RAW_RE.search(line)
                if m:
                    HYDRA.add_sample(int(m.group(1)), source=port)
        except Exception:
            time.sleep(1.0)


def udp_reader():
    """Receive sample lines broadcast by the firmware over WiFi."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", UDP_PORT))
    while True:
        try:
            data, addr = sock.recvfrom(256)
            m = RAW_RE.search(data.decode(errors="replace"))
            if m:
                HYDRA.add_sample(int(m.group(1)), source=f"wifi {addr[0]}")
        except Exception:
            time.sleep(0.5)


def compute_loop():
    while True:
        HYDRA.compute()
        HYDRA.maybe_remind()
        time.sleep(0.08)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path, qs = parsed.path, parse_qs(parsed.query)

        if path == "/":
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")
            return

        if path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                while True:
                    payload = json.dumps(HYDRA.snapshot())
                    self.wfile.write(f"data: {payload}\n\n".encode())
                    self.wfile.flush()
                    time.sleep(0.15)
            except (BrokenPipeError, ConnectionResetError):
                return
            return

        if path == "/api/buzz":
            ok = HYDRA.buzz()
            self._send(200, json.dumps({"ok": ok}))
            return
        if path == "/api/prefs":
            with HYDRA.lock:
                for k in DEFAULT_PREFS:
                    if k in qs:
                        HYDRA.prefs[k] = qs[k][0] in ("1", "true")
                save_prefs(HYDRA.prefs)
                prefs = dict(HYDRA.prefs)
            self._send(200, json.dumps({"ok": True, "prefs": prefs}))
            return
        if path == "/api/tare":
            ok = HYDRA.tare()
            self._send(200, json.dumps({"ok": ok}))
            return
        if path == "/api/calibrate":
            try:
                mass = float(qs.get("grams", ["0"])[0])
            except ValueError:
                mass = 0.0
            ok, msg = HYDRA.calibrate(mass)
            self._send(200, json.dumps({"ok": ok, "msg": msg}))
            return
        if path == "/api/session/start":
            HYDRA.start_session()
            self._send(200, json.dumps({"ok": True}))
            return
        if path == "/api/session/end":
            HYDRA.end_session()
            self._send(200, json.dumps({"ok": True}))
            return

        self._send(404, json.dumps({"error": "not found"}))


def main():
    threading.Thread(target=serial_reader, daemon=True).start()
    threading.Thread(target=udp_reader, daemon=True).start()
    threading.Thread(target=compute_loop, daemon=True).start()
    threading.Thread(target=weather_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), Handler)
    print(f"HydraCoaster POC → http://localhost:{HTTP_PORT}")
    print(f"Listening: UDP :{UDP_PORT} (WiFi) + serial", pick_port() or "(no USB device)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
