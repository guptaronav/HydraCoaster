# HydraCoaster

HydraCoaster is a smart drink coaster built on an ESP32-C6 Feather with an
NAU7802 load cell for weight sensing and a passive piezo buzzer on GPIO7. The
coaster works standalone: it detects sips from settled weight drops, corrects
sensor drift automatically, logs drinks to flash, and buzzes hydration
reminders on its own — three tones (700 Hz for hearing-loss audibility,
3400 Hz at the piezo's resonance for loudness, 4200 Hz to bypass ANC
headphones) with the onboard NeoPixel flashing in sync.

The companion iOS app connects over Bluetooth LE: it backfills the sip log,
shows daily intake against a goal (fixed or personalized from body metrics,
weather-scaled on hot/dry days via OpenWeatherMap), writes each sip to Apple
Health, mirrors reminders as phone notifications, and pushes the
weather-adjusted reminder interval to the coaster. Drinks can be logged
manually or reclassified across a 61-drink catalog with hydration factors.
History offers week/month charts, a 12-week heatmap, a per-drink breakdown,
and CSV export; an Awards tab tracks streaks and badges, and the coaster
plays a celebration flourish the first time the daily goal is hit. Quiet
hours (manual or derived from the Health sleep schedule) silence both the
coaster and phone overnight, with optional Focus-mode gating. Themes, a
light/dark override, and a home/lock-screen progress widget round it out.
Calibration, tare, sound/light/reminder preferences, and a guided
recalibration flow live in the app's Settings.

## Layout

| Path | What |
|---|---|
| `src/main.cpp` | Product firmware: NAU7802 sampling → `lib/brain` → BLE GATT |
| `lib/brain/` | Decision logic (sip detection, auto-zero, reminders) — pure C++, natively unit-tested |
| `lib/quietwin/` | Quiet-window minute math (header-only, natively unit-tested) |
| `ios/` | SwiftUI companion app + widget extension (xcodegen project) |
| `docs/ble-protocol.md` | The firmware ↔ app BLE contract — single source of truth |
| `poc/` | **Frozen** WiFi-era bench tools (Python server + web dashboard); superseded by the app |
| `test_fsr/`, `test_weight/`, `test_nau/` | Hardware bring-up sketches |

## Firmware

```sh
pio run -e hydra -t upload      # product build (BLE only), flash over USB
pio run -e hydra_ota -t upload  # dev build (+ WiFi/ArduinoOTA), flash over the air
pio test -e native              # brain unit tests, no hardware needed
```

WiFi credentials for the OTA dev build come from `include/secrets.h` (copy
`secrets.h.example`).

## iOS app

```sh
cd ios
cp Secrets.xcconfig.example Secrets.xcconfig   # fill in the OpenWeatherMap key + coords
xcodegen generate
```

Open `ios/HydraCoaster.xcodeproj` in Xcode and run. On this machine the CLI
needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` prefixed to
`xcodebuild`/`xcrun`. Tests: ~200 Swift Testing cases, simulator-only (BLE
requires a real device; the SwiftData store is exercised in-app, not in the
test process — see the note in `ios/HydraCoaster/Data/SyncEngine.swift`).

## First-flash checklist (hardware)

1. `pio run -e hydra -t upload`, open the serial monitor: expect raw/grams
   lines; `t`/`c`/`b` serial commands still work on the bench.
2. iPhone: build/run the app, walk onboarding — the coaster should appear and
   connect during the pair step.
3. Put a cup down, take a sip, lift nothing: Today's ring and sip list update;
   the sip appears in Apple Health.
4. Toggle sound/light in Settings, hit the buzz test.
5. Settings → Recalibrate with a known mass if grams look off.
6. Leave the phone locked past the reminder interval: coaster buzzes; phone
   shows the mirrored notification.
