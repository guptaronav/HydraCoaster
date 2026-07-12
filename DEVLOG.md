# Devlog — HydraCoaster

A running log of `guptaronav/HydraCoaster`: a smart coaster (ESP32-C6 Feather
+ NAU7802 load cell) that detects sips by weight and nags you to drink, plus
its SwiftUI companion app.

---

## 2026-07-09 — v2: HidrateSpark parity, and the parts a bottle can't do

I scraped HidrateSpark's app page, put their feature list next to mine in a
table, and turned every gap into a task. Eight tasks later the app matches
them feature-for-feature — and the coaster does one thing their smart bottle
can't: throw a little party on your desk.

### Shipped

- **Personalized goal** — height/weight/activity → daily-goal formula (manual
  override kept), and hot/dry weather now bumps the goal itself, not just the
  reminder cadence.
- **Manual logging + drink catalog** — quick-log buttons plus a 61-drink
  catalog with hydration factors (coffee isn't water, sorry). Sips can be
  reclassified after the fact, and Apple Health gets the factor-weighted ml.
- **Hydration score, streaks, badges** — a daily score from goal % plus how
  evenly you drank through the day, streak tracking, and a "100% club" badge
  set. Theirs is a Premium subscription; mine is a pure function that runs
  on-device for free.
- **Reminder upgrades** — quiet hours (set manually or derived from the
  Health sleep schedule), snooze straight from the notification, and
  gentle/standard/persistent presets that write interval multipliers down to
  the coaster.
- **History analytics** — week/month ranges, a 12-week time-of-day heatmap,
  per-drink-type breakdown, and CSV export via the share sheet.
- **Themes + widget** — accent palettes, a light/dark override, and a
  home/lock-screen progress ring via WidgetKit (App Group shared store).
- **Coaster celebrations** — new firmware command `0x05`: the first time the
  ring crosses 100% each day, the coaster answers with an LED rainbow and a
  tone flourish. This is the feature the comparison table was for.
- Cleanup along the way: the old fixed 14-day history bucketing died
  (superseded by real ranges), the README got rewritten for the v2 feature
  set, and the app version bumped to 2.0.

### Verified

- `pio test -e native` (brain + quiet-window C++ tests) and the ~200 Swift
  Testing cases all green.
- Celebration-capable firmware flashed to the coaster over OTA; app v2.0
  built, installed, and launched on the physical iPhone.

### Friction

- **Focus entitlement vs. free provisioning.** `com.apple.developer.focus-status`
  can't ride a personal-team profile — without it the Focus API just answers
  "not authorized" forever. Dropped the entitlement and hid the Respect Focus
  toggle behind `FocusStatusGate.isSupported = false`; flip it back if the
  project ever moves to a paid developer account. The rest of quiet hours is
  unaffected.
- **The iPhone ghosted devicectl.** The CoreDevice tunnel dropped mid-deploy
  and stayed down for over an hour. Ended up with a background watcher that
  polled for the device and auto-installed the build the moment the phone
  reappeared — the install landed without me touching anything.
- **NimBLE** wanted a clean rebuild after the library changes before the
  firmware would link again.

### Out of scope, on purpose

Social challenges and leaderboards (needs accounts, a backend, and push),
a watch app (big lift), and Fitbit/Withings/Health Connect (different
ecosystems). The social bits get revisited if this ever gets CloudKit and a
paid account.
