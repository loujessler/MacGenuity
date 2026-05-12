//
//  Services.swift
//  MacGenuity
//
//  Service protocols. UI/ViewModels depend on these abstractions only.
//

import Foundation

struct DeviceSnapshot {
    let info: MouseInfo?
    let battery: BatteryState?
    let error: HIDError?
}

protocol DeviceService: AnyObject {
    func currentAccessState() -> HIDAccessState
    func requestAccess() async -> HIDAccessState

    func probe() async throws -> DeviceSnapshot

    func applyLighting(target: LEDTarget,
                       effect: LEDEffect,
                       color: RGBColor,
                       brightness: Int,
                       speed: Int,
                       includeHasteProbe: Bool) async throws

    func applyDPI(profile: Int, dpi: Int) async throws

    /// NGENUITY-style batch: writes every level's DPI + colour + enable
    /// bitmap, selects the active profile, and commits. The single
    /// `applyDPI` above remains for convenience / live-stream paths.
    func applyDPIBatch(levels: [DPILevel], activeProfile: Int) async throws

    /// Live preview when the user clicks a DPI radio button. Sends only
    /// the `D3 00 00 01 N` select packet + commit — no value/colour
    /// rewrites, no batch — so the device responds immediately without
    /// reapplying every other setting.
    func selectDPIProfile(_ profile: Int) async throws

    /// Lists every plausible HyperX device currently attached, deduped
    /// by VID:PID (one entry per physical mouse/headset).
    func availableDevices() -> [DeviceFingerprint]

    /// Forces the service to use the device with the given fingerprint.
    /// Closes the current transport, stores the user preference, and the
    /// next refresh / control call rediscovers using that VID:PID.
    func setActiveDevice(_ fingerprint: DeviceFingerprint?) async
    func sendHasteDirectFrame(_ color: RGBColor) async throws

    /// Re-bind one physical button. Followed by `commitPacket()` so the
    /// device persists the change immediately. Mirrors `applyDPIBatch`'s
    /// commit pattern.
    func applyButtonAssignment(_ assignment: ButtonAssignment) async throws

    /// Apply a full set of button assignments at once. Sends each `0xD4`
    /// packet then a single commit at the end — minimises the number of
    /// `DE 03 00` round-trips.
    func applyButtonAssignments(_ assignments: [ButtonAssignment]) async throws

    /// Snapshot of the currently resolved profile (if any). UI uses this to
    /// show capabilities and the chosen profile identifier.
    func snapshotProfile() async -> ActiveProfileSnapshot?

    /// Fire-and-discover for the diagnostics window. Doesn't open the device.
    func diagnosticsCandidates() -> [DiagnosticsCandidate]

    /// Send an arbitrary packet for diagnostics. The first byte is treated
    /// as the command for response matching.
    func sendRawPacket(_ bytes: Data,
                       sendKind: ProfilePacket.SendKind,
                       receiveKind: ProfilePacket.ReceiveKind) async throws -> Data?

    func disconnect() async
}

protocol AudioService: AnyObject {
    func connectedMicrophones() -> [MicrophoneInfo]

    /// Toggle the hardware/software mute flag for `deviceID`. Returns
    /// `true` if CoreAudio accepted the write — `false` means the
    /// device doesn't expose a settable mute (some HyperX mics route
    /// mute through the on-device tap-to-mute and refuse remote control).
    @discardableResult
    func setMicrophoneMute(_ muted: Bool, deviceID: UInt32) -> Bool

    /// Set input-volume scalar in `[0, 1]`. Returns false if the device
    /// has no software volume (in which case the user has to use the
    /// hardware gain dial).
    @discardableResult
    func setMicrophoneVolume(_ scalar: Float, deviceID: UInt32) -> Bool
}
