//
//  DeviceProfile.swift
//  MacGenuity
//
//  Public extension point. A `DeviceProfile` describes one HyperX
//  product family: how to identify it, which features it supports,
//  and how to encode/decode its specific HID packets.
//
//  See `Infrastructure/HID/Profiles/PROFILES.md` for a step-by-step
//  guide to authoring a new profile.
//

import Foundation

/// Capabilities a profile can advertise. The UI hides controls for
/// capabilities the active profile does not support.
struct DeviceCapabilities: OptionSet, Hashable {
    let rawValue: Int

    static let info         = DeviceCapabilities(rawValue: 1 << 0)
    static let battery      = DeviceCapabilities(rawValue: 1 << 1)
    static let lighting     = DeviceCapabilities(rawValue: 1 << 2)
    static let dpiProfiles  = DeviceCapabilities(rawValue: 1 << 3)
    static let hasteDirect  = DeviceCapabilities(rawValue: 1 << 4)

    static let all: DeviceCapabilities = [.info, .battery, .lighting, .dpiProfiles, .hasteDirect]

    var labels: [String] {
        var out: [String] = []
        if contains(.info)        { out.append("Info") }
        if contains(.battery)     { out.append("Battery") }
        if contains(.lighting)    { out.append("Lighting") }
        if contains(.dpiProfiles) { out.append("DPI") }
        if contains(.hasteDirect) { out.append("Haste direct") }
        return out
    }
}

/// A single HID write the profile expects the transport to perform.
struct ProfilePacket {
    enum SendKind { case output, feature }
    enum ReceiveKind { case input, feature, none }

    let bytes: Data
    /// Where to send this packet. `nil` means "try output, fall back to feature".
    let send: SendKind?
    /// Where to expect a response. `.none` means no reply.
    let receive: ReceiveKind
    /// Whether to also retry with a leading 0x00 report-ID byte if the first try fails.
    let retryWithReportID: Bool
    /// Human-readable label used in logs and the diagnostics view.
    let label: String

    init(bytes: Data,
         send: SendKind? = nil,
         receive: ReceiveKind = .none,
         retryWithReportID: Bool = false,
         label: String)
    {
        self.bytes = bytes
        self.send = send
        self.receive = receive
        self.retryWithReportID = retryWithReportID
        self.label = label
    }
}

/// Lightweight metadata exposed to discovery/UI without leaking IOKit types.
struct DeviceFingerprint: Equatable {
    let vendorID: Int
    let productID: Int
    let product: String
    let usagePage: Int
    let usage: Int
    let maxInput: Int
    let maxOutput: Int
    let maxFeature: Int

    var lowercaseProduct: String { product.lowercased() }
}

/// Implemented by every supported device family.
///
/// Profiles are registered with `ProfileRegistry`. The registry asks each
/// profile for a `match(...)` confidence score against a discovered device;
/// the highest scorer wins. Return `0.0` to opt out.
protocol DeviceProfile: AnyObject {
    /// Stable identifier shown in logs, the UI's profile picker, and diagnostics.
    var identifier: String { get }
    /// Friendly name for the UI ("HyperX Pulsefire Haste 2 Wireless").
    var displayName: String { get }
    /// Author / contributor credit.
    var author: String { get }

    var capabilities: DeviceCapabilities { get }

    /// Confidence score in `[0, 1]` for the given device.
    /// Convention: 0.5 = matches by product-name keyword,
    /// 0.8 = matches VID, 0.95 = exact VID+PID, 1.0 = signature certainty.
    func match(_ fingerprint: DeviceFingerprint) -> Double

    // MARK: - Info / battery

    /// Returns the packet sequence required to retrieve hardware info.
    /// The transport will execute these in order until one yields a
    /// response that `parseInfo` accepts.
    func infoRequests() -> [ProfilePacket]
    func parseInfo(_ data: Data) throws -> MouseInfo

    func batteryRequests() -> [ProfilePacket]
    func parseBattery(_ data: Data) throws -> BatteryState

    // MARK: - Lighting / DPI

    func lightingPackets(target: LEDTarget,
                         effect: LEDEffect,
                         color: RGBColor,
                         brightness: Int,
                         speed: Int) -> [ProfilePacket]

    /// Single-profile apply (legacy / live-stream path).
    func dpiPackets(profile: Int, dpi: Int, dpiColor: RGBColor) -> [ProfilePacket]

    /// Full batch apply mirroring NGENUITY's `D3 01 / D3 02×N / D3 03×N /
    /// D3 00` flow. Profiles that override only the legacy `dpiPackets`
    /// will still work via the default implementation below.
    func dpiBatchPackets(levels: [DPILevel], activeProfile: Int) -> [ProfilePacket]

    /// Used by the keep-alive loop. Profiles that don't support direct
    /// per-frame color updates should return `nil`.
    func hasteDirectFrame(_ color: RGBColor) -> ProfilePacket?
    func hasteSetupPacket() -> ProfilePacket?

    /// Returned packet is sent after a batch of settings writes (DPI,
    /// button remap, etc.) to commit them on the device. NGENUITY uses
    /// `DE 03 00` for this on Pulsefire devices; without it the device
    /// accepts the writes but does not apply them on the next wake.
    /// Profiles that don't need a commit should return `nil`.
    func commitPacket() -> ProfilePacket?
}

extension DeviceProfile {
    /// Default implementations let new profiles opt into a feature one at a time.
    func hasteDirectFrame(_ color: RGBColor) -> ProfilePacket? { nil }
    func hasteSetupPacket() -> ProfilePacket? { nil }
    func commitPacket() -> ProfilePacket? { nil }

    /// Default batch implementation: combine per-level `dpiPackets` calls
    /// and a final select. Profiles for devices with different protocols
    /// can override this.
    func dpiBatchPackets(levels: [DPILevel], activeProfile: Int) -> [ProfilePacket] {
        var packets: [ProfilePacket] = []
        for level in levels where level.enabled {
            packets.append(contentsOf:
                dpiPackets(profile: level.index, dpi: level.dpi, dpiColor: level.color)
            )
        }
        return packets
    }
}
