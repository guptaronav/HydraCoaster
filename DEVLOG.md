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

---

## 2026-07-12 — v3: the party always arrives

V2 taught the coaster to celebrate with you. V3 makes sure the celebration
actually shows up — and gives the whole app a pulse while it's at it.

### The party always arrives

Shipping a celebration and reliably delivering one turn out to be different
problems. V2 marked your once-a-day celebration as used the moment the phone
sent the command — so if the coaster rejected it or the reply got lost in the
air, the day burned with nothing played, and it never retried. Now the day is
only recorded when the coaster confirms the flourish actually ran; a bad or
lost reply clears the pending marker and the next qualifying sip simply sends
it again.

Crossing 100% away from the coaster counts too. Log a glass at a restaurant,
walk in the door, and the celebration fires the moment the coaster reconnects
— no waiting for another sip. Amber pulses and ascending chirps, right on cue.

### No more vanishing sips

The nastiest bug of the release: the app called itself "connected" the
instant Bluetooth linked, before it had discovered where writes actually go.
Everything that fires on connect — including the request for sips the coaster
logged while your phone was away — hit a not-ready guard and was silently
dropped. Offline sips just never backfilled. "Connected" now means
ready-to-write, and a failed discovery disconnects for a clean retry. Every
phone-free sip lands in your history on the next reconnect, every time.

### A ring with a pulse

The Today ring traded flat ink for an angular gradient with a liquid sheen,
progress moves on a spring, and the first time it fills each day it does a
quick scale pulse and pins a sparkly "goal reached" under the number — the
on-phone echo of the coaster's flourish. The streak flame bounces when your
streak grows. The Awards tab got tinted icon circles on the stat tiles,
earned badges on accent-washed gradient cards, badge symbols that bounce when
unlocked, and a cascading entrance. Turn on Reduce Motion and all of it
politely sits still.

### Push to party

A Celebration Test button now lives in Settings, right under Buzz Test.
Unlike Buzz Test, it respects your Sound and Light toggles, so it exercises
the exact path a real goal celebration takes. A checkmark plus silence means
your toggles are off — not that something's broken.

### Verified

- Simulator test suite green; celebration-confirmation and reconnect paths
  exercised end-to-end against the physical coaster after an OTA flash.
- Fresh goal-reached screenshots captured in both themes
  (`ios/screenshots/today-goal-reached-*.png`, local only — screenshots are
  gitignored).
- App version bumped to 3.0.
