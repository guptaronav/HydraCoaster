#!/usr/bin/env python3
"""
HydraCoaster POC bridge + live dashboard.

Reads weight from the ESP32-C6 over USB serial (the nau_test sketch prints
"grams=<value>" lines), applies time-windowed averaging + stability detection,
tracks "drinking sessions", and serves a live web UI at http://localhost:8808.

All the smart logic lives here so it can be iterated without reflashing.

Run:  python3 poc/hydra_server.py
"""

import glob
import json
import os
import re
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import serial  # pyserial

# ── Tunables ──────────────────────────────────────────────────────────────────
BAUD             = 115200
HTTP_PORT        = 8808
WINDOW_SECONDS   = 3.0     # averaging window — the "reliable period"
STABLE_STD_G     = 3.0     # settled if std-dev under this (grams)
MIN_SAMPLES      = 8       # need this many samples before trusting stability
CUP_MIN_G        = 20.0    # above this we consider a cup to be present
SERIAL_GLOB      = "/dev/cu.usbmodem*"

GRAMS_RE = re.compile(r"grams=\s*(-?\d+(?:\.\d+)?)")
HERE     = os.path.dirname(os.path.abspath(__file__))


def pick_port():
    ports = sorted(glob.glob(SERIAL_GLOB))
    return ports[0] if ports else None


class Hydra:
    """Shared state: rolling samples, smoothing, and session tracking."""

    def __init__(self):
        self.lock    = threading.Lock()
        self.samples = deque()        # (timestamp, grams)
        self.smoothed = 0.0
        self.stddev   = 0.0
        self.stable   = False
        self.cup_present = False
        self.last_stable_cup_g = None
        self.connected = False
        self.port = None
        self.ser  = None
        self.session = {
            "active": False, "start_g": 0.0, "consumed_g": 0.0,
            "started_at": None, "log": [],
        }

    # -- data in -------------------------------------------------------------
    def add_sample(self, grams):
        now = time.time()
        with self.lock:
            self.samples.append((now, grams))
            cutoff = now - WINDOW_SECONDS
            while self.samples and self.samples[0][0] < cutoff:
                self.samples.popleft()

    def compute(self):
        with self.lock:
            gs = [g for (_, g) in self.samples]
            if not gs:
                return
            mean = sum(gs) / len(gs)
            var  = sum((x - mean) ** 2 for x in gs) / len(gs)
            self.smoothed = mean
            self.stddev   = var ** 0.5
            self.stable   = (len(gs) >= MIN_SAMPLES and self.stddev < STABLE_STD_G)
            self.cup_present = mean > CUP_MIN_G

            # Only trust a settled cup reading to drive session math.
            if self.stable and self.cup_present:
                self.last_stable_cup_g = mean
                if self.session["active"] and self.last_stable_cup_g is not None:
                    drop = self.session["start_g"] - self.last_stable_cup_g
                    self.session["consumed_g"] = max(0.0, drop)

    # -- sessions ------------------------------------------------------------
    def start_session(self):
        with self.lock:
            base = self.last_stable_cup_g
            if base is None:
                base = self.smoothed
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
            })
            self.session["active"] = False

    # -- serial out ----------------------------------------------------------
    def send(self, ch):
        with self.lock:
            if self.ser:
                try:
                    self.ser.write(ch.encode())
                    self.ser.flush()
                except Exception:
                    pass

    # -- snapshot for the UI -------------------------------------------------
    def snapshot(self):
        with self.lock:
            s = self.session
            return {
                "connected":   self.connected,
                "port":        self.port,
                "grams":       round(self.smoothed, 1),
                "stddev":      round(self.stddev, 1),
                "stable":      self.stable,
                "cup_present": self.cup_present,
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
    """Continuously read the serial port; reconnect on loss."""
    while True:
        port = pick_port()
        if not port:
            HYDRA.connected = False
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
            with HYDRA.lock:
                HYDRA.ser = ser
                HYDRA.port = port
                HYDRA.connected = True
            while True:
                line = ser.readline().decode(errors="replace")
                if not line:
                    continue
                m = GRAMS_RE.search(line)
                if m:
                    HYDRA.add_sample(float(m.group(1)))
        except Exception:
            with HYDRA.lock:
                HYDRA.connected = False
                HYDRA.ser = None
            time.sleep(1.0)


def compute_loop():
    while True:
        HYDRA.compute()
        time.sleep(0.08)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # silence default logging
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
        path = parsed.path

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

        if path == "/api/tare":
            HYDRA.send("t")
            self._send(200, json.dumps({"ok": True}))
            return
        if path == "/api/calibrate":
            HYDRA.send("c")
            self._send(200, json.dumps({"ok": True}))
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
    threading.Thread(target=compute_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), Handler)
    print(f"HydraCoaster POC → http://localhost:{HTTP_PORT}")
    print("Reading serial from", pick_port() or "(no device yet)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
