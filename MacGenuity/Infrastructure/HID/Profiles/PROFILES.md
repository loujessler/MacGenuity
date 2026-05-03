# Adding a device profile

A *profile* describes one HyperX product family: how to identify it, which features it supports, and how to encode its specific HID packets. The app picks the best-scoring profile from `ProfileRegistry` on every device discovery, so adding support for a new device is a self-contained task.

## TL;DR

1. Capture packets sent by the official software (or this app's diagnostics window) for your device.
2. Copy `DefaultHyperXProfile.swift` to `MyDeviceProfile.swift` and adjust packet bytes.
3. Tighten the `match(_:)` function so it returns a confidence > 0.7 only for *your* device.
4. Register your profile in `ProfileRegistry.init()`.
5. Open a PR.

## What a profile must implement

A profile is a class conforming to [`DeviceProfile`](../../../Domain/DeviceProfile.swift). The protocol is small:

| Method | Purpose |
| --- | --- |
| `identifier` / `displayName` / `author` | Strings shown in logs and the diagnostics window |
| `capabilities` | `OptionSet` advertising which features the device supports |
| `match(_:)` | Returns a `Double` in `[0, 1]` — confidence that this profile owns the given device |
| `infoRequests()` / `parseInfo(_:)` | Hardware-info request packets and parser |
| `batteryRequests()` / `parseBattery(_:)` | Battery request packets and parser |
| `lightingPackets(...)` | Build LED packets |
| `dpiPackets(...)` | Build DPI packets |
| `hasteSetupPacket()` / `hasteDirectFrame(_:)` | Optional — direct per-frame color updates |

`DefaultHyperXProfile` is a working reference implementation for NGenuity2-style mice (Pulsefire family). Most contributors only need to override `match(_:)`, the request bytes, and the parsers.

## Capturing packets from your device

You need to know the byte sequences your device speaks. Three options:

### A. The diagnostics window (recommended for additions)

If your device already shows up in the candidates list (the app sees it as HyperX-shaped and pulls a fingerprint), open **Menu → Diagnostics**:

- The window lists every HyperX-shaped HID interface with its full fingerprint (VID/PID, usage page, report sizes).
- The "Send raw" panel lets you paste a hex packet (e.g. `D2 20 00 08 FF 00 00 ...`) and inspect the response.
- Every input report and every send/receive is logged in the live tail with full byte dumps.

Use this to verify packets you've collected from another source, or to probe the device's response to small variations of known packets.

### B. USB packet capture (necessary for new commands)

For commands not yet documented anywhere, capture the USB traffic from the official software:

- **macOS**: `Wireshark` with `usbmon` enabled. Connect the device, start `NGENUITY` on Windows or boot a Windows VM, capture, decode the HID reports.
- **Windows**: USBPcap + Wireshark.
- **Linux**: `usbmon` + Wireshark.

Filter to `usb.transfer_type == 0x02` (interrupt) or `usb.transfer_type == 0x00` (control) on your device's bus/port. Match request → response pairs.

### C. Reuse community work

Several open-source projects have reverse-engineered HyperX protocols:

- [hyperx-pulsefire-haste](https://github.com/scarjit/hyperx-pulsefire-haste-control) — Haste-family commands
- [openrgb](https://gitlab.com/CalcProgrammer1/OpenRGB) — broad RGB device support including HyperX
- [solaar-style](https://github.com/pwr-Solaar/Solaar) — patterns for HID device control

If you base a profile on one of these, credit them in the `author` string.

## Writing `match(_:)`

The registry calls `match(_:)` against every detected candidate and picks the highest scorer. Conventions:

- `0.0` — opt out completely.
- `0.5` — matches by product-name keyword only.
- `0.7` — matches the family but not the exact PID. (Beats `DefaultHyperXProfile`'s `0.6` ceiling.)
- `0.95` — exact VID + PID match.
- `1.0` — signature byte sequence in info report (only if you need to disambiguate within a family).

The default profile caps itself at `0.95` so a more specific profile with `> 0.95` will always win. Stay below `0.95` unless you genuinely match a specific device.

## Testing your profile

There is no automated harness — each device is physical. Manual checklist:

- [ ] Build and launch with your device plugged in.
- [ ] **Menu → Diagnostics** confirms the resolved profile is yours (the badge shows `identifier`).
- [ ] `infoRequests()` produces a non-empty `MouseInfo`.
- [ ] `batteryRequests()` produces a battery percent in 0–100.
- [ ] `lightingPackets(...)` actually changes the LEDs.
- [ ] `dpiPackets(...)` switches profiles and updates the on-mouse indicator.
- [ ] Pull the dongle while the app is running — status flips to `disconnected`, no crash, no `WARN` in the log.
- [ ] Plug it back in — auto-recovers within one polling interval.

## Capabilities

Advertise only what your profile implements. The UI hides controls for features the active profile doesn't support. For a battery-only headset:

```swift
let capabilities: DeviceCapabilities = [.info, .battery]
```

## Submitting

Open a PR with:

- `MyDeviceProfile.swift` under this folder
- The `register(MyDeviceProfile())` line in `ProfileRegistry.init()`
- A short note in your PR description: device name, VID/PID, where you got the protocol from, what you tested

Include a screenshot of **Menu → Diagnostics** showing the device matched if you can.
