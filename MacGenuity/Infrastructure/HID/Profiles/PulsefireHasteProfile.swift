//
//  PulsefireHasteProfile.swift
//  MacGenuity
//
//  Concrete profile for the HyperX Pulsefire Haste (1st & 2nd gen).
//  Behaviour identical to the default profile for now — exists as a
//  worked example for community contributors. Adjust packet bytes
//  here for Haste-specific quirks (e.g. polling rate, sensor mode).
//

import Foundation

final class PulsefireHasteProfile: DeviceProfile {
    let identifier = "hyperx.pulsefire-haste"
    let displayName = "HyperX Pulsefire Haste"
    let author = "MacGenuity"

    let capabilities: DeviceCapabilities = [.info, .battery, .lighting, .dpiProfiles, .hasteDirect]

    private let fallback = DefaultHyperXProfile()

    func match(_ fp: DeviceFingerprint) -> Double {
        let lower = fp.lowercaseProduct
        guard lower.contains("pulsefire") || lower.contains("haste") else { return 0 }

        var score = 0.7  // beats DefaultHyperXProfile when product name contains "haste"
        if fp.usagePage == 0xFF13 || fp.usagePage == 0xFF00 { score += 0.1 }
        if HIDDeviceFinder.hyperxVendorIDs.contains(fp.vendorID) { score += 0.1 }
        return min(score, 0.95)
    }

    func infoRequests() -> [ProfilePacket]    { fallback.infoRequests() }
    func parseInfo(_ d: Data) throws -> MouseInfo { try fallback.parseInfo(d) }
    func batteryRequests() -> [ProfilePacket] { fallback.batteryRequests() }
    func parseBattery(_ d: Data) throws -> BatteryState { try fallback.parseBattery(d) }

    func lightingPackets(target: LEDTarget, effect: LEDEffect, color: RGBColor,
                         brightness: Int, speed: Int) -> [ProfilePacket]
    {
        fallback.lightingPackets(target: target, effect: effect, color: color,
                                 brightness: brightness, speed: speed)
    }

    func dpiPackets(profile: Int, dpi: Int, dpiColor: RGBColor) -> [ProfilePacket] {
        fallback.dpiPackets(profile: profile, dpi: dpi, dpiColor: dpiColor)
    }

    func hasteSetupPacket() -> ProfilePacket?  { fallback.hasteSetupPacket() }
    func hasteDirectFrame(_ c: RGBColor) -> ProfilePacket? { fallback.hasteDirectFrame(c) }
    func commitPacket() -> ProfilePacket? { fallback.commitPacket() }
}
