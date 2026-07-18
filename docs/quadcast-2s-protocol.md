# HyperX QuadCast 2 S protocol notes

These notes document only packet facts implemented by MacGenuity. They were
validated on a retail HyperX QuadCast 2 S and checked against HyperX NGENUITY
2.1.2. No code from HyperX or GPL-licensed community projects is included.

## USB interfaces

| Purpose | VID:PID | HID usage | macOS transport |
| --- | --- | --- | --- |
| LampArray RGB | `03F0:02B5` | page `FF59`, usage `0001` | Feature reports |

The RGB interface implements the USB HID LampArray standard used by Windows
Dynamic Lighting. It is a dedicated non-input interface and remains available
when macOS Input Monitoring access is denied.

## Live LampArray capabilities

Feature report `01` describes the array:

```text
01 LL LL WW WW WW WW HH HH HH HH DD DD DD DD KK KK KK KK TT TT TT TT
```

All multi-byte fields are little-endian. `LL` is the lamp count; `WW`, `HH`,
and `DD` are the physical bounding box; `KK` is the LampArray kind; and `TT`
is the minimum update interval in microseconds.

The tested microphone returned:

| Attribute | Value |
| --- | ---: |
| Lamps | 108 (`0...107`) |
| Bounding box | 101600 × 134200 × 256100 |
| Kind | 4 (peripheral) |
| Minimum update interval | 33000 µs (~30.3 FPS) |

Lamp geometry is queried by writing report `02` with a lamp ID and reading
report `03`:

```text
02 LL LL

03 LL LL XX XX XX XX YY YY YY YY ZZ ZZ ZZ ZZ
   TT TT TT TT PP PP PP PP RR GG BB II AA NN
```

The response carries the lamp ID, XYZ position, update latency, purposes,
channel level counts, programmability, and input binding. All 108 lamps on the
tested unit are programmable, expose 8-bit RGB plus 8-bit intensity, and
report 5000 µs update latency.

The physical arrangement is a 12-column × 9-row cylindrical matrix. Lamp IDs
run serpentine by column: column 0 is `8...0` from top to bottom, column 1 is
`9...17`, and so on. Runtime code interrogates every lamp instead of assuming
that layout; the verified coordinates are retained only as an offline preview
and fallback.

## Arbitrary per-lamp frames

Lamp Multi Update report `04` contains up to eight independently addressed
RGBI values:

```text
04 NN CC
   ID0 ID0 ... ID7 ID7
   R0 G0 B0 I0 ... R7 G7 B7 I7
```

- `NN` is the number of populated slots (`1...8`).
- Each ID is a little-endian 16-bit lamp ID.
- Each slot has independent red, green, blue, and intensity bytes.
- `CC` is `00` for an incomplete frame and `01` for `LampUpdateComplete`.
- The full feature report is 51 bytes; unused slots are zero-filled.

A complete 108-lamp frame is fourteen consecutive report `04` writes: thirteen
eight-lamp batches followed by one four-lamp batch. Only the fourteenth report
sets `LampUpdateComplete`. This makes the visible update atomic instead of
showing partially written bands.

MacGenuity reads the device's declared minimum interval and rate-limits the
host renderer accordingly. The LampArray API therefore supports arbitrary
software-generated imagery, not just NGENUITY's built-in choices. The app
currently exposes spatial palette effects, a 108-cell painter, and a persisted
multi-frame animator with loop/ping-pong and hold/cross-fade playback. Those
effects are a MacGenuity software layer; the USB protocol remains standard
per-lamp RGBI frames.

Host effects require MacGenuity to remain running. They are not written into
the microphone's firmware or onboard memory.

## Range update and autonomous mode

For an efficient one-colour frame, MacGenuity sends these feature reports in
order:

```text
06 00
05 01 00 00 6B 00 RR GG BB II
```

- Report `06` disables autonomous mode so the host can control the lamps.
- Report `05` is a Lamp Range Update covering IDs `0000...006B`.
- `01` is the update-complete flag.
- `RR GG BB` is the colour and `II` is intensity from `00` to `FF`.

Restoring the firmware-defined animation is one feature report:

```text
06 01
```

This path succeeds through `IOHIDDeviceSetReport` on macOS and was exercised
on the physical device before the app implementation was added. On the tested
firmware, report `06` accepts writes but does not answer feature reads.
MacGenuity therefore shows the last mode it successfully selected instead of
delaying controls with a read that times out.

If a frame stream fails after autonomous mode is disabled, the service makes a
best-effort `06 01` write so the microphone is not left dark or frozen.

## Unsupported polar-pattern controls

MacGenuity intentionally does not read, infer, or change the microphone's
polar pattern. A candidate audio-HID status report did not reliably agree with
the physical selector during hardware validation. Its mapping and the
corresponding write transport are therefore excluded from the production
models, protocol code, and UI. Support should only return after repeatable
captures verify both state and control behavior on the physical device.

## Regression coverage

Run `Tests/QuadCast2S/run.sh` without a microphone attached. The feature-local
suite locks down the exact live report `01`, report `03` parsing, the
fourteen-report atomic frame shape, serpentine geometry, every effect renderer,
authored-frame playback, legacy preference migration, and per-microphone
persistence.

## References

- [USB-IF HID Usage Tables Review Request 84: Lighting and Illumination Page](https://www.usb.org/sites/default/files/hutrr84_-_lighting_and_illumination_page.pdf)
- [USB-IF HID specifications](https://www.usb.org/hid)
- [Microsoft Dynamic Lighting and HID LampArray](https://learn.microsoft.com/en-us/windows/apps/develop/devices-sensors/lighting-dynamic-lamparray)
- [Microsoft LampArray minimum-update-interval API](https://learn.microsoft.com/en-us/uwp/api/windows.devices.lights.lamparray.minupdateinterval)
- [HyperX NGENUITY](https://hyperx.com/pages/ngenuity)
- [Apple IOHIDFamily source](https://github.com/apple-oss-distributions/IOHIDFamily)
- [HIDAPI](https://github.com/libusb/hidapi)
- [Ors1mer/QuadcastRGB](https://github.com/Ors1mer/QuadcastRGB)
- [j-muell/QuadcastRGB2S](https://github.com/j-muell/QuadcastRGB2S)
- [OpenRGB QuadCast 2 S merge request](https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/3039)
