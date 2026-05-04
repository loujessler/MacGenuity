<p align="center">
    <img src="https://img.shields.io/github/v/release/loujessler/macgenuity">
    <img src="https://img.shields.io/github/license/loujessler/macgenuity">
    <img src="https://img.shields.io/github/stars/loujessler/macgenuity">
    <img src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/loujessler/MacGenuity/main/MacGenuity/Resources/donations.json">
</p>

---

# MacGenuity

A lightweight macOS menu bar application for monitoring HyperX wireless devices (mouse and USB microphone).

Built with pure Swift and SwiftUI. No third-party dependencies. Distributed as a single self-contained `.app`.

---

## Overview

MacGenuity surfaces real-time device state from the macOS menu bar without the vendor's NGenuity software or any background daemons.

The project is intentionally a low-level, dependency-free macOS utility. It talks to the device through IOKit HID directly, and to the audio subsystem through CoreAudio.

---

## Features

### Mouse monitoring

- Battery percent + charging state in the menu bar
- Battery-history sparkline (last ~10 hours)
- Battery trend indicator (charging / discharging / stable / rising)
- Device name, firmware version, VID/PID
- Configurable poll interval and low-battery threshold
- Low-battery system notification (UNUserNotificationCenter, throttled)

### Microphone monitoring (CoreAudio)

- Connected HyperX input devices
- Manufacturer, sample rate, stream count
- Gain / mute (when exposed by macOS)

### Lighting

- Interactive RGB picker with coloured-track sliders, hex input, live preview
- Recent-colours strip (persisted across launches)
- Named lighting presets — save current config, recall in one click
- LED target / effect / brightness / speed controls
- Haste-family direct-colour probe with throttled (1 Hz) keepalive

### DPI

- Per-profile DPI value (50–16 000, 50-step rounded)
- Active profile selection (1–4) with on-mouse colour indicator

### Extensible device profiles

- `DeviceProfile` protocol with capability flags — UI hides controls a profile doesn't support.
- Score-based registry picks the best profile per discovered device.
- `DefaultHyperXProfile` covers the NGenuity2 family; `PulsefireHasteProfile` is a worked example.
- Contributors add their device by copying a profile, tweaking packet bytes, and registering it. See [PROFILES.md](MacGenuity/Infrastructure/HID/Profiles/PROFILES.md).

### Diagnostics window

A dedicated window for contributors and curious users:

- Live tail of structured logs, filterable by level and channel
- Every detected HyperX-shaped HID interface with its full fingerprint and the resolved profile
- Raw-packet sender — paste hex, choose send/receive transport, inspect the response
- One-click "Copy hex" / "Open log file"

### Settings window

Native macOS Settings scene (⌘,) with separate panes for **General**, **Lighting** (preset management), **Profiles** (registered profile listing), and **About**.

### System integration

- Launch at login via `SMAppService`
- Native macOS Input Monitoring prompt with a *Recheck* button for stale TCC entries
- Structured file logging with rotation (5 MB cap)
- `os_log` mirroring (subsystem `com.local.macgenuity`)

---

## Architecture

The codebase is organized into clearly bounded layers. UI never touches IOKit or CoreAudio directly — those system APIs live in the Infrastructure layer and are exposed to the rest of the app through the protocols in `Domain/Services.swift`.

```
MacGenuity/
├── App/
│   └── MacGenuityApp.swift              Scene wiring (MenuBarExtra + Settings + Diagnostics windows)
├── Domain/
│   ├── Models.swift                        Pure value types (Codable RGBColor, MouseInfo, …)
│   ├── Errors.swift                        DeviceError / HIDError / PermissionError
│   ├── Services.swift                      DeviceService / AudioService protocols
│   └── DeviceProfile.swift                 Public extension point for community-authored profiles
├── Features/
│   ├── MenuBar/
│   │   ├── MenuBarLabel.swift              Tray icon + percent
│   │   └── MenuContent.swift               Dropdown content
│   ├── Lighting/
│   │   ├── InteractiveColorPicker.swift    RGB sliders + hex + recent colours
│   │   └── PresetsView.swift               Named lighting preset save / apply / rename / delete
│   ├── Battery/
│   │   └── BatterySparkline.swift          Path-drawn chart of recent samples
│   ├── Diagnostics/
│   │   └── DiagnosticsWindow.swift         Candidate list + raw sender + live log tail
│   └── Settings/
│       └── SettingsScene.swift             General / Lighting / Profiles / About panes
├── Infrastructure/
│   ├── HID/
│   │   ├── HIDPermission.swift             IOHIDCheckAccess / IOHIDRequestAccess
│   │   ├── HIDDeviceFinder.swift           Enumerate HyperX-shaped HID interfaces (no opens)
│   │   ├── HIDTransport.swift              One IOHIDDevice handle, send/receive, persistent input callback
│   │   ├── HyperXDeviceService.swift       Actor that dispatches through the resolved profile
│   │   └── Profiles/
│   │       ├── PacketUtils.swift           Helpers (build, parse, validate)
│   │       ├── ProfileRegistry.swift       Score-based device → profile resolution
│   │       ├── DefaultHyperXProfile.swift  NGenuity2 reference implementation
│   │       ├── PulsefireHasteProfile.swift Worked example for new contributors
│   │       └── PROFILES.md                 Step-by-step authoring guide
│   ├── Audio/
│   │   └── CoreAudioMicrophoneService.swift
│   └── System/
│       ├── AppSettings.swift               UserDefaults + SMAppService
│       ├── BatteryHistory.swift            Persistent rolling timeline
│       ├── PresetStore.swift               Named lighting presets + recent colours
│       └── Notifier.swift                  Low-battery system notifications
├── Shared/
│   ├── Logger.swift                        Levelled logger + rotating file + tail ring buffer
│   └── Hex.swift                           Hex formatting helpers
├── ViewModels/
│   └── DeviceViewModel.swift               @MainActor; the view model SwiftUI observes
└── Resources/
    └── Info.plist
```

### Concurrency model

- `DeviceViewModel` is `@MainActor`. Every `@Published` mutation runs on the main thread.
- `HyperXDeviceService` is an `actor` — one HID I/O at a time, no parallel reports.
- The menu bar UI never blocks: HID work is awaited, never executed inline.
- Tasks capture `self` weakly so the view model can be torn down without leaks.

### Permission handling

The app uses `IOHIDCheckAccess` to determine the current Input Monitoring state and `IOHIDRequestAccess` to politely prompt for it. It will never call `IOHIDDeviceOpen` while access is denied — that previously caused tight TCC retry loops and `TCC deny IOHIDDeviceOpen` log spam.

When permission is missing the menu shows a "Permission" section with a *Grant access* button (triggers the system prompt) and a fallback button that opens the Input Monitoring pane in System Settings.

### HID layer hardening

- The input-report buffer is sized from the device's `kIOHIDMaxInputReportSizeKey` (with a sane minimum and a 4 KiB cap), not a hardcoded 65 bytes. IOKit writes up to that size into the registered buffer regardless of what we pass — using a fixed 65-byte buffer caused heap overruns on devices with larger reports.
- The capture object that owns the buffer is held by `Unmanaged.passRetained` for the entire registration window, drained from the run loop after unregistering, and released only after IOKit has confirmed unregistration. A stray late callback cannot dereference a freed buffer.
- Every callback bounds-checks `reportLength` against the registered capacity before constructing a `Data`.
- The IOHIDDevice handle is opened once and reused across polls. The previous open/close-per-poll pattern produced unnecessary IOKit churn and combined badly with the 22 Hz lighting keepalive.
- The static-color keepalive runs at 1 Hz instead of 22 Hz.
- All packet validators reject empty / echo / out-of-range responses with explicit `HIDError` cases.

---

## Build

Requires only the Xcode Command Line Tools:

```bash
xcode-select --install
./build.sh
open build/MacGenuity.app
```

The build script auto-detects Apple Silicon vs. Intel, ad-hoc signs the bundle, and writes the result to `build/MacGenuity.app`.

To install:

```bash
cp -R build/MacGenuity.app /Applications/
```

---

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel
- Input Monitoring permission (granted from inside the app or from System Settings → Privacy & Security → Input Monitoring)

---

## TCC and code signing

macOS binds Input Monitoring permission to the **cdhash** (signing hash) of the binary, not its file path. Ad-hoc signing (`codesign --sign -`) recomputes the cdhash on every build, so a previously-granted toggle in System Settings can show "ON" while `IOHIDRequestAccess` still returns `denied`. The app surfaces this with a permission section in the menu and a *Recheck* button.

To make grants survive rebuilds during development, use a stable self-signed identity:

1. Open *Keychain Access* → menu bar → *Certificate Assistant* → *Create a Certificate…*
2. Name `MacGenuity Dev`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**.
3. Trust the cert in your login keychain.
4. Rebuild: `build.sh` will pick it up automatically. (Override with `HYPERX_SIGN_IDENTITY=...` for a Developer ID.)

If a stale grant has to be reset:

```bash
tccutil reset ListenEvent com.local.macgenuity
# Then remove MacGenuity from System Settings → Privacy & Security
# → Input Monitoring (− button), relaunch the app, and click "Grant access".
```

---

## Logs

Log file: `~/Library/Logs/MacGenuity/MacGenuity.log`. Rotates at 5 MB.

Levels: `DEBUG`, `INFO`, `WARN`, `ERROR`, scoped by channel (`app`, `hid`, `audio`, `settings`, `ui`). Output is also mirrored to `os_log` and shows up in Console.app under subsystem `com.local.macgenuity`.

---

## Limitations / non-goals

- Firmware flashing (out of scope).
- Writing settings to onboard memory (`SAVE_TO_HARDWARE`) — intentionally not implemented to avoid corrupting non-volatile mouse memory.
- Full LED / DPI control. The HyperX protocol is only partially reverse-engineered, and several effects are device-specific.
- Polling rate configuration.

Some functionality is intentionally restricted to avoid unsafe device operations.

---

## Roadmap

- Wired-mouse support (no battery, lighting only)
- Save current lighting / DPI to onboard memory (behind an explicit confirmation)
- Polling-rate configuration
- Auto-update check against GitHub releases (read-only)
- Localization (UI is currently English-only)
- More device profiles — please contribute! See [PROFILES.md](MacGenuity/Infrastructure/HID/Profiles/PROFILES.md)

---

## ❤️ Support

MacGenuity is an independent open-source project built without third-party dependencies.

If it replaces proprietary software in your setup or saves you time, consider supporting development:

<p align="center">
  <a href="https://loujessler.github.io/MacGenuity/">
    <img src="https://img.shields.io/badge/Support-Donate-blue?style=for-the-badge">
  </a>
</p>

<p align="center">
  <sub>
    Supports cards and crypto · helps expand device compatibility and maintain the project
  </sub>
</p>

---

## License

MIT — see [LICENSE](LICENSE).

---

## Contributing

The project is built around a community-extensible profile system. The most valuable contribution is **support for additional HyperX devices** — see [PROFILES.md](MacGenuity/Infrastructure/HID/Profiles/PROFILES.md) for a step-by-step authoring guide and [CONTRIBUTING.md](CONTRIBUTING.md) for general guidelines.

The built-in **Diagnostics window** (Menu → Diagnostics, ⌘D) is designed specifically to help contributors:

- Lists every HyperX-shaped HID interface with its full fingerprint (VID/PID, usage page, report sizes).
- Shows which profile claimed each interface — useful for verifying a new `match(_:)` function.
- "Raw packet sender" lets you paste a hex packet, choose `output`/`feature` send transport, choose `input`/`feature`/`none` receive transport, and inspect the response — all without writing code first.
- Live-tail of structured logs filterable by channel and level. One-click "Copy" exports the visible window to the clipboard so you can paste it into a PR.

Don't have a HyperX device handy but want to help? Reverse-engineering, code review, edge-case testing, and improving the diagnostics tooling are all welcome.
