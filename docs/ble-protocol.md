# HydraCoaster BLE Protocol v1

The contract between firmware and the iOS app. All multi-byte fields are
**little-endian**. Weights are `int16`/`uint16` in **tenths of a gram**
(`grams_x10`). Timestamps are `uint32` Unix seconds, UTC.

Device advertises as **`HydraCoaster`**. One custom service plus the standard
Battery Service. No pairing/bonding in v1 (open GATT — explicit non-goal;
threat model is "roommate buzzes you").

## Service

`AD0BD001-2A44-4E5B-9C8B-4B1E7C0D5E2A`

Characteristic UUIDs follow the pattern `AD0BD00X-2A44-4E5B-9C8B-4B1E7C0D5E2A`
(only the `X` digit changes).

## Characteristics

### D002 — Live Weight (read, notify) — 5 bytes

| offset | type | field |
|---|---|---|
| 0 | int16 | grams_x10 (smoothed) |
| 2 | uint8 | flags: b0 settled, b1 cup_present, b2 clock_synced |
| 3 | uint16 | stddev_x10 |

Notified at ~2 Hz while subscribed. Powers the Today screen live readout and
the calibration UX ("settling…").

### D003 — Sip Log (write, notify)

**Write** `uint32 last_seq` — "send me everything after this sequence number."
Firmware then **notifies** one packet per stored event, in order:

| offset | type | field |
|---|---|---|
| 0 | uint32 | seq (starts at 1, monotonic, persisted) |
| 4 | uint32 | unix_ts (0 = timestamp unrecoverable) |
| 8 | uint16 | grams_x10 consumed |

Backfill ends with a terminator packet `seq = 0` (other fields zero). After
that, live sip events are notified on this characteristic as they happen.
Writing a new `last_seq` restarts a backfill at any time.

Firmware stores a ring buffer of the most recent **64** events in NVS.

### D004 — Time Sync (write) — 4 bytes

`uint32` Unix seconds UTC. App writes on every connect. Firmware sets its
system clock and back-corrects any ring-buffer events logged since the current
boot while the clock was unsynced (it keeps boot-millis per unsynced event).
Unsynced events from *previous* boots are unrecoverable → `unix_ts = 0`.

### D005 — Reminder Interval (read, write) — 2 bytes

`uint16` seconds. The **weather-adjusted base interval**, computed by the
phone (base 1200 s x weather factor). Persisted in NVS; default **1200**.
Firmware multiplies this by its own behavior factor (below) — the phone never
sees or sets that part.

### D006 — Prefs (read, write) — 1 byte

Bitfield: b0 sound, b1 led, b2 reminders enabled. Persisted in NVS; default
`0b111`.

### D007 — Command (write)

| bytes | command |
|---|---|
| `0x01` | buzz test — full alert, both channels, ignores prefs |
| `0x02` | tare — capture settled median as new zero |
| `0x03` + `uint16 grams_x10` | calibrate with known mass on the coaster |
| `0x04` | clear the sip log ring (seq counter keeps counting — stays unique) |

Results are reported on D008.

### D008 — Command Status (read, notify) — 2 bytes

`uint8 last_cmd`, `uint8 result`: 0 = ok, 1 = no signal (not settled),
2 = load too small / check wiring, 3 = bad command.

### Battery — standard service `0x180F`, char `0x2A19` (read, notify)

Percent from the Feather's MAX17048 fuel gauge. If the gauge is absent or
unreadable, report 100.

## Firmware reminder brain (for reference — lives entirely on-device)

Ported from `poc/hydra_server.py`, same constants: 2.5 s rolling window,
stable = stddev < 3 g over ≥ 8 samples, settled = stable held 1.5 s, cup ≥
20 g, auto-zero any settled cup-free reading < 10 g (≥ 5 s apart), sip =
settled plateau ≥ 10 g below the ratcheted max (rises only ratchet — drift
never fakes or masks a sip). Sip amount = plateau drop.

Reminder: alert per prefs when `now - last_drink ≥ interval x behavior`,
repeat at most every 300 s. **Behavior factor**: 1.5 if total consumed in the
trailing 60 min ≥ 250 g, else 1.0 (replaces the old dashboard "session"
concept).
