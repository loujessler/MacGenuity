<p align="center">
    <img src="https://img.shields.io/github/v/release/loujessler/macgenuity">
    <img src="https://img.shields.io/github/license/loujessler/macgenuity">
    <img src="https://img.shields.io/github/stars/loujessler/macgenuity">
    <a href="https://loujessler.github.io/MacGenuity/">
      <img src="https://img.shields.io/badge/Donate-Support-blue">
    </a>
</p>

---

# MacGenuity

A lightweight macOS menu-bar application for monitoring and controlling HyperX peripherals — wireless mice, USB microphones, and headset families.

Built with pure Swift and SwiftUI. No third-party dependencies. Distributed as a single self-contained `.app`.

---

## Overview

MacGenuity surfaces real-time device state and lets you change lighting, DPI, button mappings and microphone state from the macOS menu bar — without HP's NGenuity software or any background daemons.

The project is intentionally a low-level, dependency-free macOS utility. It talks to the mouse through IOKit HID directly, and to the audio subsystem through CoreAudio.

---

## Features

### Devices sidebar (BetterDisplay-style)

The Settings window's **Devices** tab lists every attached HyperX peripheral on the left. The detail pane on the right shows ONLY the controls that device actually supports — lighting and DPI for mice, audio controls for microphones. There is no top-level "Lighting" or "DPI" tab any more; those editors live inside the device they belong to.

### Mouse monitoring

- Battery percent + charging state in the menu bar
- Battery-history sparkline (last ~10 hours) and trend indicator
- Device name, firmware version, VID/PID
- Configurable poll interval and low-battery threshold
- Low-battery system notification (UNUserNotificationCenter, throttled)

### Mouse lighting (Pulsefire family)

- Interactive RGB picker with coloured-track sliders, hex input, live preview
- "Live update" streams colour to the device while sliders move (on by default)
- Named lighting presets — save current config, recall in one click
- LED target / effect / brightness / speed / opacity controls
- Haste-family direct-colour probe with throttled (1 Hz) keepalive

### Mouse DPI

- Per-profile DPI value (50 – 16 000, 50-step rounded)
- Up to 5 profiles with per-level enable bitmap and indicator colour
- NGenuity-style batch apply: writes every level + selects active in one `D3` packet flow, committed with `DE 03 00`

### Mouse button remapping (`0xD4` protocol)

- Re-bind middle / side / DPI buttons to mouse functions, media keys, or DPI cycle
- Per-device state persisted between sessions; restore-defaults per-row or batch
- Survives reboot via the same commit pattern as DPI

### Microphone monitoring & control (CoreAudio)

- Auto-detects HyperX QuadCast / QuadCast S / QuadCast 2 / QuadCast 2S / DuoCast / SoloCast
- Mute / unmute toggle directly in the menu-bar tray
- Volume slider, sample rate, stream count, default-input badge in the detail pane
- **Push-based state sync** via `AudioObjectAddPropertyListenerBlock` — physical tap-to-mute on the device flips the in-app toggle within ~50 ms, no polling delay

### Branded menu-bar icon

- Custom mark from `Resources/MenuBarIcon.pdf` (preferred) or `MenuBarIcon.png`
- Loaded as a template `NSImage` so macOS tints it for dark / light menu bars
- Built-in `HyperXMark` template fallback if no asset is shipped

### Extensible device profiles

- `DeviceProfile` protocol with capability flags — UI hides controls a profile doesn't support
- Score-based registry picks the best profile per discovered device
- Shipped profiles: `DefaultHyperXProfile` (NGenuity2 / Pulsefire family), `PulsefireHasteProfile` (worked example), `QuadCastProfile` (detection-only for the Cast family)
- Contributors add their device by copying a profile, tweaking packet bytes, and registering it. See [PROFILES.md](MacGenuity/Infrastructure/HID/Profiles/PROFILES.md).

### Diagnostics window

A dedicated window for contributors and curious users:

- Live tail of structured logs, filterable by level and channel
- Every detected HyperX-shaped HID interface with its full fingerprint and the resolved profile
- Raw-packet sender — paste hex, choose send/receive transport, inspect the response
- One-click "Copy hex" / "Open log file"

### Settings window

Native macOS Settings scene (⌘,) with separate panes for **General**, **Devices** (sidebar + per-device editors), **Profiles** (registered profile listing), and **About**.

### System integration

- Launch at login via `SMAppService`
- First-launch Input Monitoring prompt triggered automatically via `IOHIDRequestAccess`
- One-click "Relaunch" button to pick up freshly-granted TCC permission
- Structured file logging with rotation (5 MB cap)
- `os_log` mirroring (subsystem `io.github.loujessler.macgenuity`)

---

## Architecture

The codebase is organized into clearly bounded layers. UI never touches IOKit or CoreAudio directly — those system APIs live in the Infrastructure layer and are exposed to the rest of the app through the protocols in `Domain/Services.swift`.

```
MacGenuity/
├── App/
│   └── MacGenuityApp.swift                 Scene wiring (MenuBarExtra + Settings + Diagnostics)
├── Domain/
│   ├── Models.swift                        Pure value types (RGBColor, MouseInfo, ButtonAssignment, …)
│   ├── Errors.swift                        DeviceError / HIDError / PermissionError
│   ├── Services.swift                      DeviceService / AudioService protocols
│   ├── DeviceProfile.swift                 Public extension point for community-authored profiles
│   ├── ConfigurableDevice.swift            Unified HID + audio device type for the sidebar
│   └── Config/
│       └── DonationConfig.swift            Decodes Resources/donations.json (graceful fallback)
├── Features/
│   ├── MenuBar/
│   │   ├── MenuBarLabel.swift              Tray icon + battery / HyperX mark
│   │   ├── MenuContent.swift               Dropdown content (mic mute toggles, permission flow, …)
│   │   └── HyperXMark.swift                Branded template NSImage with PDF/PNG loader
│   ├── Lighting/
│   │   ├── InteractiveColorPicker.swift    RGB sliders + hex + recent colours
│   │   └── PresetsView.swift               Named lighting preset save / apply / rename / delete
│   ├── Battery/
│   │   └── BatterySparkline.swift          Path-drawn chart of recent samples
│   ├── Diagnostics/
│   │   └── DiagnosticsWindow.swift         Candidate list + raw sender + live log tail
│   └── Settings/
│       └── SettingsScene.swift             General / Devices / Profiles / About panes
├── Infrastructure/
│   ├── HID/
│   │   ├── HIDPermission.swift             IOHIDCheckAccess / IOHIDRequestAccess
│   │   ├── HIDDeviceFinder.swift           Enumerate HyperX-shaped HID interfaces (no opens)
│   │   ├── HIDTransport.swift              One IOHIDDevice handle, send/receive, persistent input callback
│   │   ├── HyperXDeviceService.swift       Actor that dispatches through the resolved profile
│   │   └── Profiles/
│   │       ├── PacketUtils.swift           Helpers (build, parse, validate)
│   │       ├── ProfileRegistry.swift       Score-based device → profile resolution
│   │       ├── DefaultHyperXProfile.swift  NGenuity2 reference implementation (lighting / DPI / buttons)
│   │       ├── PulsefireHasteProfile.swift Worked example for new contributors
│   │       ├── QuadCastProfile.swift       Cast-family detection (QuadCast / DuoCast / SoloCast)
│   │       └── PROFILES.md                 Step-by-step authoring guide
│   ├── Audio/
│   │   └── CoreAudioMicrophoneService.swift  CoreAudio enumeration + property listeners + setters
│   └── System/
│       ├── AppSettings.swift               UserDefaults + SMAppService
│       ├── BatteryHistory.swift            Persistent rolling timeline
│       ├── PresetStore.swift               Named lighting presets + recent colours
│       ├── DeviceStateStore.swift          Per-device lighting / DPI / button assignments
│       ├── DockPolicyManager.swift         LSUIElement-aware Dock-icon policy
│       └── Notifier.swift                  Low-battery system notifications
├── Shared/
│   ├── Logger.swift                        Levelled logger + rotating file + tail ring buffer
│   └── Hex.swift                           Hex formatting helpers
├── ViewModels/
│   └── DeviceViewModel.swift               @MainActor; the view model SwiftUI observes
└── Resources/
    ├── Info.plist
    ├── donations.json
    ├── AppIcon.png         (optional — 1024×1024, auto-compiled into AppIcon.icns at build time)
    └── MenuBarIcon.pdf     (optional — vector template for the tray icon)
```

### Concurrency model

- `DeviceViewModel` is `@MainActor`. Every `@Published` mutation runs on the main thread.
- `HyperXDeviceService` is an `actor` — one HID I/O at a time, no parallel reports.
- The menu bar UI never blocks: HID work is awaited, never executed inline.
- Tasks capture `self` weakly so the view model can be torn down without leaks.

### Permission handling

The app uses `IOHIDCheckAccess` to determine the current Input Monitoring state and `IOHIDRequestAccess` to politely prompt for it. It will never call `IOHIDDeviceOpen` while access is denied — that previously caused tight TCC retry loops and `TCC deny IOHIDDeviceOpen` log spam.

When permission is missing the menu shows a "Permission" section with **System Settings** (opens the Input Monitoring pane) and **Relaunch** (quits and immediately re-opens the app — required because macOS caches per-process TCC state and a running app can't see a freshly-granted permission until it restarts).

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

The build script:

- Auto-detects Apple Silicon vs. Intel (`arm64-apple-macos13` / `x86_64-apple-macos13`).
- Picks a signing identity in priority order: `HYPERX_SIGN_IDENTITY` env → `"MacGenuity Dev"` self-signed → first `"Apple Development:"` cert → ad-hoc fallback.
- Adds the `com.apple.security.get-task-allow` entitlement for **development** certs so `lldb` can attach; strips it for Developer ID certs to keep the build notarization-eligible.
- Optionally bundles a custom menu-bar icon (`Resources/MenuBarIcon.pdf|png`) and app icon (`Resources/AppIcon.icns` or `AppIcon.png`, auto-compiled through `sips`+`iconutil`).

Writes the result to `build/MacGenuity.app`.

### Distribution build

For a notarization-ready Developer ID build:

```bash
HYPERX_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
HYPERX_ALLOW_DEBUG=0 \
./build.sh

# Wrap and submit
cd build && ditto -c -k --keepParent MacGenuity.app MacGenuity.zip
xcrun notarytool submit MacGenuity.zip --keychain-profile AC_PROFILE --wait
xcrun stapler staple MacGenuity.app
```

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

macOS binds Input Monitoring permission to the **cdhash** (signing hash) of the binary, not its file path or bundle identifier. Ad-hoc signing (`codesign --sign -`) recomputes the cdhash on every build, so a previously-granted toggle in System Settings can show "ON" while `IOHIDRequestAccess` still returns `denied`. The menu's permission section explains the situation and offers a **Relaunch** button — required because macOS caches per-process TCC state and a running app can't see a freshly-granted permission until it restarts.

To make grants survive rebuilds during development, use a stable signing identity. `build.sh` auto-detects, in this order:

1. `HYPERX_SIGN_IDENTITY` env var (explicit override).
2. A self-signed identity named `MacGenuity Dev` in the login keychain.
3. The first available `Apple Development:` cert (gives a stable cdhash).
4. Ad-hoc fallback (cdhash changes every build).

To create a self-signed identity:

1. Open *Keychain Access* → menu bar → *Certificate Assistant* → *Create a Certificate…*
2. Name `MacGenuity Dev`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**.
3. Trust the cert in your login keychain.
4. Rebuild: `build.sh` will pick it up automatically.

If a stale grant has to be reset:

```bash
tccutil reset ListenEvent io.github.loujessler.macgenuity
# Then remove MacGenuity from System Settings → Privacy & Security
# → Input Monitoring (− button), relaunch the app, accept the prompt.
```

---

## Logs

Log file: `~/Library/Logs/MacGenuity/MacGenuity.log`. Rotates at 5 MB.

Levels: `DEBUG`, `INFO`, `WARN`, `ERROR`, scoped by channel (`app`, `hid`, `audio`, `settings`, `ui`, `lighting`). Output is also mirrored to `os_log` and shows up in Console.app under subsystem `io.github.loujessler.macgenuity`.

---

## Custom branding (icons)

You can override both the app icon (Dock) and the menu-bar tray icon without touching code. `build.sh` looks for files in `MacGenuity/Resources/` in this order:

| Slot              | Preferred                        | Fallback                | If neither is present       |
| ----------------- | -------------------------------- | ----------------------- | --------------------------- |
| **Tray icon**     | `MenuBarIcon.pdf` (vector template, 22×22 pt, transparent background, black on alpha) | `MenuBarIcon.png` (any size — auto-baked to 22 pt height at load) | Programmatic `HyperXMark`   |
| **App icon**      | `AppIcon.icns`                   | `AppIcon.png` (1024 × 1024, auto-compiled to `.icns` via `sips` + `iconutil`) | Programmatic stylised "X"   |

The tray icon **must** be a template image (only the alpha channel matters — macOS picks the colour based on the menu-bar appearance). The app icon can use full colour.

To preview a change, drop the file into `MacGenuity/Resources/` and run `./build.sh`. The build script's resource copy is a whitelist — files not in the list don't end up in the bundle.

---

## Limitations / non-goals

- Firmware flashing (out of scope).
- Writing settings to onboard memory (`SAVE_TO_HARDWARE`) — intentionally not implemented to avoid corrupting non-volatile mouse memory.
- Full LED / DPI control. The HyperX protocol is only partially reverse-engineered, and several effects are device-specific.
- Polling rate configuration.

Some functionality is intentionally restricted to avoid unsafe device operations.

---

## Changelog

Release history lives in [CHANGELOG.md](CHANGELOG.md).

---

## Roadmap

- HyperX QuadCast / QuadCast 2S RGB lighting + polar pattern (USB control transfers — protocol notes already linked in `QuadCastProfile.swift`)
- Macro recording on remappable buttons (`0xD5` / `0xD6` protocol — read by `0xD4` editor, no writer yet)
- Wired-mouse support
- Save current lighting / DPI / button config to onboard memory (behind an explicit confirmation)
- Polling-rate configuration (`0xD0` packet, documented but unused)
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
