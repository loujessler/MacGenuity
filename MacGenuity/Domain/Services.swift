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
    var dpi: DeviceDPIState?
    var wheelColour: WheelColour?
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
                       includeHasteProbe: Bool, persist: Bool) async throws

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

    /// Returns a representative interface for each attached receiver.
    func availableDevices() async -> [DeviceFingerprint]

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
    /// packet then a single profile-specific commit at the end.
    func applyButtonAssignments(_ assignments: [ButtonAssignment]) async throws

    /// Snapshot of the currently resolved profile (if any). UI uses this to
    /// show capabilities and the chosen profile identifier.
    func snapshotProfile() async -> ActiveProfileSnapshot?

    /// Fire-and-discover for the diagnostics window. Doesn't open the device.
    func diagnosticsCandidates() async -> [DiagnosticsCandidate]

    /// Send an arbitrary packet for diagnostics. The first byte is treated
    /// as the command for response matching.
    func sendRawPacket(_ bytes: Data, to fingerprint: DeviceFingerprint,
                       sendKind: ProfilePacket.SendKind,
                       receiveKind: ProfilePacket.ReceiveKind) async throws -> Data?

    func disconnect() async
}

protocol AudioService: AnyObject {
    func connectedMicrophones() -> [MicrophoneInfo]

    func soloCastHardwareMute(for uid: String) -> Bool?

    /// Applies an explicit user action to this input. The caller reads back the result.
    @discardableResult
    func applyMicrophoneMute(_ action: MicrophoneMuteAction, for microphone: MicrophoneInfo) -> Bool

    /// Set input-volume scalar in `[0, 1]`. Returns false if the device
    /// has no software volume (in which case the user has to use the
    /// hardware gain dial).
    @discardableResult
    func setMicrophoneVolume(_ scalar: Float, deviceID: UInt32) -> Bool
}

protocol QuadCast2SService: AnyObject {
    func snapshot() async -> QuadCast2SHardwareState

    func applyStaticLighting(color: RGBColor, brightness: Int) async throws

    func applyLightingEffect(
        _ configuration: QuadCast2SEffectConfiguration
    ) async throws

    /// Stops software frame streaming and leaves the final rendered frame
    /// visible. Use `restoreAutonomousLighting` to hand control to firmware.
    func stopLightingEffect() async

    func restoreAutonomousLighting() async throws
}
