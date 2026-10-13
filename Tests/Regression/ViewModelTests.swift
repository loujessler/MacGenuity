import Foundation

private final class SilentLogger: LoggerType {
    func log(_ level: LogLevel, _ channel: LogChannel, _ message: @autoclosure () -> String) {}
}

private final class FakeDeviceService: DeviceService {
    var fingerprint: DeviceFingerprint
    var access: HIDAccessState = .granted
    var battery: BatteryState? = BatteryState(percent: 60, isCharging: false)
    var probeError: HIDError?
    var probeCount = 0
    var lightingColors: [RGBColor] = []
    var keepaliveCount = 0
    var lightingCommits: [Bool] = []
    var lightingError: HIDError?
    var selectionGate: CheckedContinuation<Void, Never>?
    var delaySelection = false

    init(fingerprint: DeviceFingerprint) { self.fingerprint = fingerprint }
    func currentAccessState() -> HIDAccessState { access }
    func requestAccess() async -> HIDAccessState { access }
    func probe() async throws -> DeviceSnapshot {
        probeCount += 1
        if let probeError { throw probeError }
        return DeviceSnapshot(info: nil, battery: battery, error: nil)
    }
    func availableDevices() -> [DeviceFingerprint] { [fingerprint] }
    func setActiveDevice(_ fingerprint: DeviceFingerprint?) async {
        if let fingerprint { self.fingerprint = fingerprint }
    }
    func snapshotProfile() async -> ActiveProfileSnapshot? {
        ActiveProfileSnapshot(identifier: "test", displayName: "Test mouse", author: "Tests",
            capabilities: [.info, .battery, .lighting, .dpiProfiles, .hasteDirect, .buttons],
            fingerprint: fingerprint)
    }
    func applyLighting(target: LEDTarget, effect: LEDEffect, color: RGBColor,
                       brightness: Int, speed: Int, includeHasteProbe: Bool, persist: Bool) async throws {
        if let lightingError { throw lightingError }
        lightingColors.append(color)
        lightingCommits.append(persist)
    }
    func applyDPI(profile: Int, dpi: Int) async throws {}
    func applyDPIBatch(levels: [DPILevel], activeProfile: Int) async throws {}
    func selectDPIProfile(_ profile: Int) async throws {
        if delaySelection {
            await withCheckedContinuation { selectionGate = $0 }
        }
    }
    func sendHasteDirectFrame(_ color: RGBColor) async throws { keepaliveCount += 1 }
    func applyButtonAssignment(_ assignment: ButtonAssignment) async throws {}
    func applyButtonAssignments(_ assignments: [ButtonAssignment]) async throws {}
    func diagnosticsCandidates() -> [DiagnosticsCandidate] { [] }
    func sendRawPacket(_ bytes: Data, sendKind: ProfilePacket.SendKind,
                       receiveKind: ProfilePacket.ReceiveKind) async throws -> Data? { nil }
    func disconnect() async {}
}

private final class FakeAudioService: AudioService {
    var microphones = [MicrophoneInfo(id: 7, name: "HyperX SoloCast", manufacturer: "HyperX",
        uid: "test-solocast", sampleRate: 96_000, inputStreamCount: 1,
        volumePercent: 75, isMuted: false, isDefaultInput: true,
        canSetMute: true, canSetVolume: true)]
    func connectedMicrophones() -> [MicrophoneInfo] { microphones }
    func setMicrophoneMute(_ muted: Bool, deviceID: UInt32) -> Bool { true }
    func setMicrophoneVolume(_ scalar: Float, deviceID: UInt32) -> Bool { true }
}

private final class FakeQuadCastService: QuadCast2SService {
    func snapshot() async -> QuadCast2SHardwareState { .disconnected }
    func applyStaticLighting(color: RGBColor, brightness: Int) async throws {}
    func applyLightingEffect(_ configuration: QuadCast2SEffectConfiguration) async throws {}
    func stopLightingEffect() async {}
    func restoreAutonomousLighting() async throws {}
}

@MainActor
enum ViewModelTests {
    static func run(fingerprint: DeviceFingerprint) async throws {
        let suite = "MacGenuity.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeDeviceService(fingerprint: fingerprint)
        let audio = FakeAudioService()
        let store = DeviceStateStore(defaults: defaults)
        let logger = SilentLogger()
        let viewModel = DeviceViewModel(deviceService: service, audioService: audio,
            quadCast2SService: FakeQuadCastService(),
            history: BatteryHistory(defaults: defaults, logger: logger),
            presetStore: PresetStore(defaults: defaults), deviceStates: store,
            quadCast2SStates: QuadCast2SStateStore(defaults: defaults), logger: logger)
        await viewModel.refresh()
        precondition(viewModel.battery?.percent == 60)
        precondition(viewModel.selectedDeviceKey == fingerprint.stableKey)
        let probes = service.probeCount
        await viewModel.setMicrophoneMute(true, for: audio.microphones[0])
        await viewModel.setMicrophoneVolume(50, for: audio.microphones[0])
        precondition(service.probeCount == probes, "Audio changes must not poll HID")
        service.battery = nil
        await viewModel.refresh()
        precondition(viewModel.battery == nil && viewModel.lastUpdate == nil)
        service.battery = BatteryState(percent: 60, isCharging: false)
        await viewModel.refresh()
        service.access = .denied
        await viewModel.refresh()
        precondition(viewModel.activeProfile == nil && viewModel.battery == nil)
        precondition(viewModel.microphones.count == 1, "HID permission must not hide SoloCast")
        service.access = .granted
        await viewModel.refresh()

        await viewModel.selectDPIProfile(3, previewColor: PresetColor.green.rgb)
        let writesBeforeSwitch = service.lightingColors.count
        await viewModel.setActiveDevice(fingerprint)
        try await Task.sleep(nanoseconds: 1_650_000_000)
        precondition(service.lightingColors.count == writesBeforeSwitch,
                     "Switching devices must cancel delayed lighting restoration")

        service.delaySelection = true
        let selection = Task { await viewModel.selectDPIProfile(2, previewColor: PresetColor.red.rgb) }
        while service.selectionGate == nil { await Task.yield() }
        var blue = DeviceLightingState.default
        blue.color = PresetColor.blue.rgb
        await viewModel.applyLighting(state: blue)
        let writesAfterApply = service.lightingColors.count
        service.selectionGate?.resume()
        service.selectionGate = nil
        await selection.value
        try await Task.sleep(nanoseconds: 1_650_000_000)
        precondition(service.lightingColors.count == writesAfterApply,
                     "An older DPI operation must not overwrite a newer lighting edit")
        precondition(store.state(for: fingerprint).lighting.color == blue.color)
        service.delaySelection = false
        var green = DeviceLightingState.default
        green.color = PresetColor.green.rgb
        await viewModel.applyLighting(state: green, persist: false)
        precondition(service.lightingCommits.last == false, "Live frames must not write flash")
        precondition(store.state(for: fingerprint).lighting == green,
                     "Live colour must be the current state, not the previous saved effect")
        let writesAfterPreview = service.lightingColors.count
        try await Task.sleep(nanoseconds: 650_000_000)
        precondition(service.lightingColors.count == writesAfterPreview + 1)
        precondition(service.lightingCommits.last == true,
                     "The settled Live selection must be committed without an Apply click")
        await viewModel.selectDPIProfile(2, previewColor: PresetColor.red.rgb)
        try await Task.sleep(nanoseconds: 1_650_000_000)
        precondition(service.lightingColors.last == green.effectiveColor,
                     "A DPI flash must restore the latest Live colour")
        precondition(service.lightingCommits.last == false,
                     "The transient DPI indicator must never be committed")

        await viewModel.applyLighting(state: blue, persist: false)
        await viewModel.applyLighting(state: green, persist: false)
        let writesAfterLatestPreview = service.lightingColors.count
        try await Task.sleep(nanoseconds: 650_000_000)
        precondition(service.lightingColors.count == writesAfterLatestPreview + 1,
                     "Rapid previews must coalesce to one save")
        precondition(service.lightingColors.last == green.effectiveColor)

        await viewModel.applyLighting(state: blue, persist: false)
        await viewModel.setActiveDevice(fingerprint)
        let writesAfterSwitch = service.lightingColors.count
        try await Task.sleep(nanoseconds: 650_000_000)
        precondition(service.lightingColors.count == writesAfterSwitch,
                     "Pending saves must not reach a newly selected device")
        service.lightingError = .notPermitted
        let previousLighting = store.state(for: fingerprint).lighting
        await viewModel.applyLighting(state: green, persist: false)
        precondition(store.state(for: fingerprint).lighting == previousLighting,
                     "Failed previews must not be recorded as applied")
        service.lightingError = nil

        viewModel.setPollInterval(.infinity)
        precondition(viewModel.pollInterval == 60)
        viewModel.stop()
        print("View-model lifecycle, SoloCast isolation and lighting cancellation tests passed")
    }
}
