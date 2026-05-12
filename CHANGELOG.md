# Changelog

All notable changes to MacGenuity are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-05-12

A large feature release: per-device settings sidebar, button remapping, microphone controls with push-based state sync, and the QuadCast / SoloCast / DuoCast family is now recognised.

### Added
- **Per-device settings sidebar** (BetterDisplay-style). The Settings window's **Devices** tab lists every attached HyperX peripheral on the left; the detail pane on the right shows only the controls that device actually supports — lighting and DPI for mice, audio properties for microphones.
- **Button remapping** via the NGenuity2 `0xD4` packet. Middle / side / DPI buttons can be re-bound to mouse functions, media keys, or DPI cycle. State is persisted per-device and committed to the mouse with a final `DE 03 00` packet so it survives a reboot.
- **HyperX QuadCast / QuadCast S / QuadCast 2 / QuadCast 2S / DuoCast / SoloCast detection.** Dedicated `QuadCastProfile` claims them by VID/PID (Kingston `0x0951` and HP `0x03F0`) and product name. Prevents the mouse driver from accidentally probing them with Pulsefire packets.
- **Microphone mute and volume controls.** Toggle a switch in the menu-bar tray or in Settings → Devices; volume slider in the detail pane writes back via CoreAudio's `kAudioDevicePropertyMute` / `kAudioDevicePropertyVolumeScalar`.
- **CoreAudio property listeners.** Physical tap-to-mute on a QuadCast / SoloCast now flips the in-app toggle within ~50 ms — no waiting for the next poll tick. Listeners are installed on the device-list selector plus per-device on Mute / Volume, both `Main` and legacy element-1 channels.
- **Custom branded menu-bar icon** loaded from `Resources/MenuBarIcon.pdf` (preferred) or `MenuBarIcon.png`. Falls back to a programmatically-drawn `HyperXMark` template if no asset is shipped.
- **Custom app (Dock) icon** support: drop a single `Resources/AppIcon.png` (1024 × 1024) and `build.sh` auto-compiles all the required `.iconset` sizes through `sips` + `iconutil`. `Resources/AppIcon.icns` is copied as-is if you'd rather ship a pre-built icon set.
- **First-launch TCC prompt.** `requestAccessIfNeeded` is invoked at startup so macOS shows the Input Monitoring dialog immediately instead of leaving the app silently denied forever.
- **One-click Relaunch button** in the permission section. macOS pins Input Monitoring grants to a binary's cdhash and a running process can't see a fresh grant until it restarts; one button quits-and-reopens.
- **Apple Development cert auto-detection** in `build.sh`. With a stable signing identity in your keychain, cdhash stops changing between rebuilds and Input Monitoring permission survives all subsequent builds.
- **`HYPERX_ALLOW_DEBUG` env override** in `build.sh` to force the `com.apple.security.get-task-allow` entitlement on/off regardless of the detected signing identity.

### Changed
- Lighting and DPI editors moved out of top-level tabs into the device they belong to. There's no longer a global "Lighting" or "DPI" view that's stuck on whichever device the user picked last.
- Lighting / DPI / Buttons sections in the device detail pane are now collapsed by default (`DisclosureGroup`). A freshly-opened device shows a clean list of features rather than dumping every control on screen at once.
- "Live update" — streaming colour to the device while sliders move — is enabled by default. The editor is now its own preview.
- Menu-bar tray icon switched from the generic `computermouse` SF Symbol to a HyperX-style monochrome mark drawn as a template NSImage. Adapts automatically to dark / light menu bars.
- `DefaultHyperXProfile.match()` opts out of devices whose product name contains "cast" / "cloud" / "headset" / "alloy". Without this, a SoloCast (VID `0x03F0`) would score 0.6 against the mouse profile and start receiving Pulsefire packets it didn't understand.
- `HyperXDeviceService.probe()` gracefully skips empty packet lists. Profiles like QuadCast that declare the `.info` capability but have no actual HID command to send no longer surface a misleading `readTimeout` error.
- `build.sh` auto-detects signing identity in priority order: `HYPERX_SIGN_IDENTITY` env → `"MacGenuity Dev"` → first available `"Apple Development:"` cert → ad-hoc fallback. Pass `HYPERX_SIGN_IDENTITY="-"` to force ad-hoc.
- `CFBundleIdentifier` changed from `com.local.macgenuity` to `io.github.loujessler.macgenuity` for public distribution.
- `NSInputMonitoringUsageDescription` rewritten to cover lighting, DPI, and button remapping in addition to battery.
- Version bumped to `0.2.0` (build `3`).

### Fixed
- **Stale battery glyph after device switch.** Unplugging a Pulsefire while a QuadCast remained attached used to leave the mouse's battery percentage stuck in the menu bar forever. `refresh()` now clears cached `info` / `battery` / `lastUpdate` whenever the active fingerprint changes or the new profile lacks the `.battery` capability.
- **Error triangle when only a microphone is attached.** SoloCast was being matched by `DefaultHyperXProfile`, which then tried to talk Pulsefire to it and reported `HIDError.deviceNotFound`. Fixed at both the profile-match layer (opt-out for audio devices) and the menu-bar icon layer (no triangle when at least one HyperX device is connected).
- **Tray icon "jump" between Live / Muted states.** The toggle label was 4 vs 5 characters wide; the switch now sits at a fixed `minWidth: 90`.
- **App crash if `donations.json` is missing or malformed.** `DonationConfig.init` no longer calls `fatalError` — falls back to an empty config and logs a warning. The About pane skips rows whose address didn't load.
- **Menu-bar icon disappearing for large source PNGs.** Custom PDFs / PNGs are now baked into a 22 pt-tall bitmap NSImage so a 1536 × 1024 source no longer blows up the menu-bar slot.
- **lldb / debugger attach blocked by hardened runtime.** Dev builds (Apple Development / "MacGenuity Dev" identity) now ship with the `com.apple.security.get-task-allow` entitlement. Automatically stripped for Developer ID signs to remain notarization-eligible.

### Improved
- Permission-section help text rewritten to explain the real root cause (cdhash binding) and walk the user through removing the stale TCC entry instead of suggesting an unrelated workaround.
- Microphone toggle logic flipped to a "switch = is mic live?" model in both the tray and Settings — matches expected macOS UX (ON = active, OFF = muted).
- `build.sh` resource copy uses an explicit whitelist (`MenuBarIcon.pdf|png|@2x.png`, `AppIcon.icns|png`). Only named files end up in the bundle; experiment files left in `Resources/` won't accidentally ship.
- Temporary entitlements plist created via `mktemp` and cleaned up through `trap EXIT`.

### Removed
- Top-level Settings tabs `Lighting` and `DPI` (their controls now live inside each device).
- The `mouse.slash` SF Symbol fallback and the menu's "Recheck" permission button (both superseded by the `HyperXMark` template image and the new "Relaunch" button).

### Known Issues
- TCC permission still requires one manual cycle on first install: grant in System Settings → click Relaunch in the tray. The OS deliberately doesn't propagate TCC grants into a running process.
- **QuadCast RGB lighting and polar-pattern selection are NOT implemented yet.** The profile declares only `.info` capability; community protocol notes are documented in `QuadCastProfile.swift` and link to [Ors1mer/QuadcastRGB](https://github.com/Ors1mer/QuadcastRGB) and [j-muell/QuadcastRGB2S](https://github.com/j-muell/QuadcastRGB2S).
- Ad-hoc signing (no Apple Development cert in keychain) still regenerates cdhash per build, forcing a re-grant of Input Monitoring after every rebuild. Use a stable Apple Development or self-signed identity to avoid this — see README.

### Build / Packaging
- Custom build script: `./build.sh` produces `build/MacGenuity.app`.
- Architecture auto-detected from `uname -m` (`arm64` or `x86_64`).
- Signing identity auto-detected: `HYPERX_SIGN_IDENTITY` env → `"MacGenuity Dev"` → first `"Apple Development:"` cert → ad-hoc.
- Pass `HYPERX_SIGN_IDENTITY="-"` to force ad-hoc, or `HYPERX_ALLOW_DEBUG=0` to strip the debug entitlement.

### Notes for Release
- For a public distribution build, set `HYPERX_SIGN_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)"` and `HYPERX_ALLOW_DEBUG=0`. Then run `xcrun notarytool submit` against the resulting `.app`.

---

## [0.1.0] — Initial release

The first tagged release of MacGenuity. Pure-Swift, dependency-free macOS menu-bar utility for HyperX devices.

### Added
- Mouse battery monitoring in the menu bar (percent + charging state) with configurable poll interval.
- Battery-history sparkline and trend indicator.
- HyperX microphone enumeration via CoreAudio.
- Interactive lighting editor: RGB picker with coloured-track sliders, hex input, live preview, recent-colours strip, named presets.
- DPI editor with per-profile colour indicator and 50 – 16 000 DPI range, NGenuity-style batch apply.
- Pulsefire-family lighting & DPI protocol support (`DefaultHyperXProfile`, `PulsefireHasteProfile`).
- Score-based `ProfileRegistry` for community-extensible device profiles.
- Diagnostics window: live log tail, candidate list, raw-packet sender.
- Low-battery system notification (throttled, opt-in).
- Launch-at-login via `SMAppService`.
- Structured file logging with 5 MB rotation, mirrored to `os_log`.
