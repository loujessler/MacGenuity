//
//  QuadCastProfile.swift
//  MacGenuity
//
//  HyperX QuadCast / QuadCast S / QuadCast 2 / QuadCast 2S / DuoCast.
//
//  Why this profile exists even without working HID lighting:
//    • Detection — without it, the QuadCast HID interfaces show up in the
//      Diagnostics window as "Unknown" and the Settings sidebar can't
//      label them. The profile tags them as a known family so the UI
//      shows the right icon, name and grouping.
//    • Future protocol work — the QuadCast family uses USB control
//      transfers (HID class SET_REPORT / GET_REPORT, wValue 0x0300, no
//      explicit endpoint) for lighting and a separate interrupt endpoint
//      pair (0x06/0x85) for the QuadCast 2S display engine. The existing
//      `HIDTransport` (built on `IOHIDDevice`) handles feature reports,
//      so a future PR can add lighting via `parseInfo`/feature send.
//
//  Protocol references (community reverse-engineering):
//    • https://github.com/Ors1mer/QuadcastRGB — QuadCast S, DuoCast,
//      QuadCast 2 (Kingston VID 0x0951 PID 0x171F; HP VID 0x03F0 PIDs
//      0x098C / 0x09AF / ...)
//    • https://github.com/j-muell/QuadcastRGB2S — QuadCast 2S (PID 0x02B5)
//    • https://gitlab.com/CalcProgrammer1/OpenRGB issue #1298
//
//  No `lighting` capability is advertised yet — turning it on would expose
//  a non-functional editor in the Devices pane. Capability stays at
//  `.info` until the actual SET_REPORT-based wire protocol is implemented
//  and verified on real hardware.
//

import Foundation

final class QuadCastProfile: DeviceProfile {
    let identifier  = "hyperx.cast-family"
    let displayName = "HyperX Cast family (QuadCast / DuoCast / SoloCast)"
    let author      = "MacGenuity"

    /// `info` only — see file header. Lighting is not implemented yet.
    let capabilities: DeviceCapabilities = [.info]

    // MARK: - Known IDs

    /// Kingston-era VIDs, before HP transferred the brand. The QuadCast S
    /// kept this VID after the rebrand for backwards compatibility with
    /// existing NGENUITY installs.
    private static let kingstonPIDs: Set<Int> = [
        0x171F,  // QuadCast S
    ]

    /// HP-era PIDs across the QuadCast / DuoCast lineup. The list comes
    /// from Ors1mer/QuadcastRGB (`product_ids_hp`) plus QuadCast 2S.
    private static let hpPIDs: Set<Int> = [
        0x0F8B,
        0x028C,
        0x048C,
        0x068C,
        0x098C,  // DuoCast
        0x09AF,  // QuadCast 2
        0x02B5,  // QuadCast 2S
    ]

    // MARK: - DeviceProfile

    func match(_ fp: DeviceFingerprint) -> Double {
        let name = fp.lowercaseProduct

        // Strong match: known VID + PID combination.
        if fp.vendorID == 0x0951, Self.kingstonPIDs.contains(fp.productID) {
            return 0.95
        }
        if fp.vendorID == 0x03F0, Self.hpPIDs.contains(fp.productID) {
            return 0.95
        }

        // Weaker name match — covers HID interfaces that report the
        // product string but with a PID we haven't catalogued yet.
        // SoloCast is included so it doesn't fall through to
        // DefaultHyperXProfile, which would then try to send Pulsefire
        // mouse packets to a microphone (manifests as "device not found").
        var score = 0.0
        if name.contains("quadcast") || name.contains("duocast") || name.contains("solocast") {
            score += 0.7
            if HIDDeviceFinder.hyperxVendorIDs.contains(fp.vendorID) {
                score += 0.1
            }
        }
        return min(score, 0.9)
    }

    // MARK: - Info

    /// QuadCast doesn't speak the Pulsefire `0x50` info command — its info
    /// is exposed via standard USB descriptors (CoreAudio enumerates name
    /// & manufacturer from the same descriptors). We synthesise a minimal
    /// `MouseInfo` from the fingerprint instead of issuing a HID request.
    func infoRequests() -> [ProfilePacket] { [] }

    func parseInfo(_ data: Data) throws -> MouseInfo {
        // Never called — `infoRequests()` returns an empty list, so the
        // device service skips the parse step. Throw to signal misuse if
        // a future caller bypasses the request list.
        throw HIDError.malformedReport(reason: "QuadCast does not implement HID info parse")
    }

    // MARK: - Battery (USB-powered, no battery)

    func batteryRequests() -> [ProfilePacket] { [] }
    func parseBattery(_ data: Data) throws -> BatteryState {
        throw HIDError.malformedReport(reason: "QuadCast is USB-powered; no battery")
    }

    // MARK: - Lighting / DPI (not yet implemented)

    func lightingPackets(target: LEDTarget,
                         effect: LEDEffect,
                         color: RGBColor,
                         brightness: Int,
                         speed: Int) -> [ProfilePacket]
    {
        // Capability `.lighting` is not advertised, so the UI never asks.
        // Returning an empty list keeps any accidental call a no-op
        // instead of writing garbage Pulsefire packets to the mic.
        []
    }

    func dpiPackets(profile: Int, dpi: Int, dpiColor: RGBColor) -> [ProfilePacket] {
        []
    }
}
