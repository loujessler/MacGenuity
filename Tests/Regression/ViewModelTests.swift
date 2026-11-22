import Foundation

private final class SilentLogger: LoggerType {
    func log(_ level: LogLevel, _ channel: LogChannel, _ message: @autoclosure () -> String) {}
}

private final class FakeDeviceService: DeviceService {
    var fingerprint: DeviceFingerprint
    var devices: [DeviceFingerprint]
    var selections: [String?] = []
    var access: HIDAccessState = .granted
    var battery: BatteryState? = BatteryState(percent: 60, isCharging: false)
    var probeError: HIDError?
    var probeCount = 0
    var permissionRequests = 0
    var lightingColors: [RGBColor] = []
    var keepaliveCount = 0
    var lightingCommits: [Bool] = []
    var directModes: [Bool] = []
    var lightingError: HIDError?
    var dpiError: HIDError?
    var sentButtons: [ButtonAssignment] = []
    var selectionGate: CheckedContinuation<Void, Never>?
    var delaySelection = false

    init(fingerprint: DeviceFingerprint) {
        self.fingerprint = fingerprint
        self.devices = [fingerprint]
    }
    func currentAccessState() -> HIDAccessState { access }
    func requestAccess() async -> HIDAccessState {
        permissionRequests += 1
        return access
    }
    func probe() async throws -> DeviceSnapshot {
        probeCount += 1
        if let probeError { throw probeError }
        return DeviceSnapshot(info: nil, battery: battery, error: nil)
    }
    func availableDevices() -> [DeviceFingerprint] { devices }
    func setActiveDevice(_ fingerprint: DeviceFingerprint?) async {
        selections.append(fingerprint?.stableKey)
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
        directModes.append(includeHasteProbe)
    }
    func applyDPI(profile: Int, dpi: Int) async throws {}
    func applyDPIBatch(levels: [DPILevel], activeProfile: Int) async throws {}
    func selectDPIProfile(_ profile: Int) async throws {
        if let dpiError { throw dpiError }
        if delaySelection {
            await withCheckedContinuation { selectionGate = $0 }
        }
    }
    func sendHasteDirectFrame(_ color: RGBColor) async throws { keepaliveCount += 1 }
    func applyButtonAssignment(_ assignment: ButtonAssignment) async throws {}
    func applyButtonAssignments(_ assignments: [ButtonAssignment]) async throws { sentButtons = assignments }
    func diagnosticsCandidates() -> [DiagnosticsCandidate] { [] }
    func sendRawPacket(_ bytes: Data, to fingerprint: DeviceFingerprint, sendKind: ProfilePacket.SendKind,
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
    var effectWrites = 0
    func snapshot() async -> QuadCast2SHardwareState { .disconnected }
    func applyStaticLighting(color: RGBColor, brightness: Int) async throws {}
    func applyLightingEffect(_ configuration: QuadCast2SEffectConfiguration) async throws { effectWrites += 1 }
    func stopLightingEffect() async {}
    func restoreAutonomousLighting() async throws {}
}

@MainActor
enum ViewModelTests {
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Timed out waiting for an automatic device refresh")
    }

    static func run(fingerprint: DeviceFingerprint, soloCast: DeviceFingerprint,
                    unrelated: DeviceFingerprint) async throws {
        let suite = "MacGenuity.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeDeviceService(fingerprint: fingerprint)
        let audio = FakeAudioService()
        let store = DeviceStateStore(defaults: defaults)
        let logger = SilentLogger()
        let castService = FakeQuadCastService()
        let viewModel = DeviceViewModel(deviceService: service, audioService: audio,
            quadCast2SService: castService,
            history: BatteryHistory(defaults: defaults, logger: logger),
            presetStore: PresetStore(defaults: defaults), deviceStates: store,
            quadCast2SStates: QuadCast2SStateStore(defaults: defaults), logger: logger)
        var permissionWindows = 0
        viewModel.showInputMonitoringHelp = { permissionWindows += 1 }
        let input = DeviceFingerprint(vendorID: fingerprint.vendorID, productID: fingerprint.productID,
            product: fingerprint.product, usagePage: 1, usage: 2, maxInput: 8, maxOutput: 0, maxFeature: 0)
        service.devices = [input]
        service.access = .unknown
        await viewModel.refresh()
        await viewModel.refresh()
        precondition(service.permissionRequests == 1, "Request undecided access once")
        precondition(permissionWindows == 1 && viewModel.status == .permissionRequired)
        service.access = .denied
        await viewModel.refresh()
        precondition(service.probeCount == 0 && service.permissionRequests == 1 && permissionWindows == 1,
                     "Protected interfaces must wait for a grant without repeating prompts")
        service.devices = [unrelated, soloCast]
        await viewModel.refresh()
        precondition(viewModel.status == .disconnected && !viewModel.microphones.isEmpty)
        precondition(service.probeCount == 0, "Microphones and unrelated HID devices must not receive mouse probes")
        service.devices.append(fingerprint)
        await viewModel.refresh()
        precondition(viewModel.battery?.percent == 60)
        precondition(viewModel.selectedDeviceKey == fingerprint.stableKey)
        precondition(service.permissionRequests == 1 && permissionWindows == 1)
        precondition(viewModel.status == .connected, "Vendor control must work if its own open succeeds")
        let primary = ButtonAssignment(button: .left, action: .mouseButton(.right))
        let side = ButtonAssignment(button: .sideBack, action: .media(.mute))
        store.record(buttons: DeviceButtonState(assignments: [primary]), for: fingerprint)
        await viewModel.applyButtonAssignments([ButtonAssignment(button: .left, action: .mouseButton(.left)), side])
        precondition(service.sentButtons == [side], "Applying a remap must leave primary clicks alone")
        precondition(store.state(for: fingerprint).buttons.action(for: .left) == primary.action)
        precondition(store.state(for: fingerprint).buttons.action(for: .sideBack) == side.action)
        var onPort = fingerprint
        onPort.locationID = 123
        precondition(store.state(for: onPort).buttons.action(for: .sideBack) == side.action,
                     "Existing model-keyed settings must survive the receiver key migration")
        var moved = onPort
        moved.locationID = 456
        store.setConnectedDevices([onPort])
        var portLighting = DeviceLightingState.default
        portLighting.color = PresetColor.yellow.rgb
        store.record(lighting: portLighting, for: onPort)
        store.setConnectedDevices([moved])
        precondition(store.state(for: moved).lighting == portLighting,
                     "A single receiver without a serial must retain edits when moved to a new port")
        portLighting.color = PresetColor.purple.rgb
        store.record(lighting: portLighting, for: moved)
        store.setConnectedDevices([onPort])
        precondition(store.state(for: onPort).lighting == portLighting,
                     "Moving back to a known port must not restore an obsolete configuration")
        var additional = onPort
        additional.locationID = 789
        store.setConnectedDevices([onPort, additional])
        precondition(store.state(for: additional).lighting == .default,
                     "An additional receiver must not inherit the first receiver's configuration")
        store.record(lighting: .default, for: additional)
        let reloaded = DeviceStateStore(defaults: defaults)
        reloaded.setConnectedDevices([additional])
        precondition(reloaded.state(for: onPort).lighting == portLighting && reloaded.state(for: additional).lighting == .default)
        store.setConnectedDevices(service.devices)
        let olderHistory = try JSONEncoder().encode([BatterySample(date: Date(), percent: 5, isCharging: false)])
        defaults.set(olderHistory, forKey: "batteryHistory.v1")
        let history = BatteryHistory(defaults: defaults, logger: logger)
        history.selectDevice(onPort)
        precondition(history.samples.isEmpty && defaults.data(forKey: "batteryHistory.v1") == olderHistory)
        let now = Date()
        history.record(percent: 80, isCharging: false, at: now.addingTimeInterval(-40_000))
        history.record(percent: 70, isCharging: false, at: now)
        history.selectDevice(fingerprint)
        precondition(!history.samples.contains { $0.percent == 70 })
        history.selectDevice(onPort)
        precondition(history.samples.map(\.percent) == [70])
        service.dpiError = .readTimeout
        let selected = await viewModel.selectDPIProfile(4, previewColor: PresetColor.red.rgb)
        precondition(!selected && store.state(for: fingerprint).dpi.activeProfile != 4)
        precondition(viewModel.dpiMessage != nil && viewModel.buttonsMessage == "Button assignments applied")
        service.dpiError = nil
        let startupSelections = service.selections
        let otherMouse = DeviceFingerprint(vendorID: fingerprint.vendorID, productID: 0x1234,
            product: "HyperX Pulsefire Dart", usagePage: 0xFF00, usage: 1,
            maxInput: 64, maxOutput: 64, maxFeature: 64)
        service.devices.insert(otherMouse, at: 0)
        await viewModel.refresh()
        precondition(service.selections == startupSelections, "A second mouse must not steal the active connection")
        service.devices.removeAll { $0 == fingerprint }
        await viewModel.refresh()
        precondition(viewModel.activeProfile?.fingerprint == otherMouse, "Unplugging the active mouse must select the remaining mouse")
        service.devices = [soloCast, unrelated]
        await viewModel.refresh()
        precondition(viewModel.activeProfile == nil && viewModel.battery == nil && viewModel.selectedDeviceKey == nil)
        viewModel.start()
        service.devices.append(fingerprint)
        NotificationCenter.default.post(name: .hidDevicesChanged, object: nil)
        try await waitUntil { viewModel.activeProfile != nil }
        precondition(viewModel.activeProfile?.fingerprint == fingerprint, "Reconnecting a mouse must not require a UI selection")
        service.devices = [soloCast]
        NotificationCenter.default.post(name: .hidDevicesChanged, object: nil)
        try await waitUntil { viewModel.activeProfile == nil }
        precondition(viewModel.activeProfile == nil && viewModel.microphones.count == 1,
                     "A receiver removal must refresh before the next polling interval")
        service.devices.append(fingerprint)
        NotificationCenter.default.post(name: .hidDevicesChanged, object: nil)
        try await waitUntil { viewModel.activeProfile != nil }
        precondition(viewModel.activeProfile?.fingerprint == fingerprint)
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
        let windowsBeforeDenial = permissionWindows
        service.probeError = .notPermitted
        await viewModel.refresh()
        let deniedProbes = service.probeCount
        await viewModel.refresh()
        precondition(service.probeCount == deniedProbes, "Do not repeatedly open a denied vendor interface")
        precondition(viewModel.status == .permissionRequired && viewModel.activeProfile == nil && viewModel.battery == nil)
        service.probeError = nil
        precondition(viewModel.microphones.count == 1, "HID permission must not hide SoloCast")
        var reattached = fingerprint
        reattached.registryEntryID = 2
        service.devices = [soloCast, reattached]
        await viewModel.refresh()
        precondition(service.probeCount == deniedProbes + 1 && viewModel.status == .connected,
                     "Retry the reattached receiver even if discovery never saw the gap")
        service.probeError = .notPermitted
        await viewModel.refresh()
        precondition(permissionWindows == windowsBeforeDenial + 2, "Offer recovery once for each new denial")
        service.probeError = nil
        service.access = .granted
        await viewModel.refresh()
        precondition(viewModel.status == .connected, "A new grant must retry the selected receiver")

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
        _ = await selection.value
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
        await viewModel.applyDPIBatch(levels: DeviceDPIState.default.levels, activeProfile: 2)
        await viewModel.applyButtonAssignments([side])
        await viewModel.selectDPIProfile(2, previewColor: PresetColor.red.rgb)
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(service.lightingCommits.last == true && service.lightingColors.last == blue.effectiveColor,
                     "Editing DPI or buttons must not discard a pending lighting save")
        await viewModel.selectDPIProfile(3, previewColor: PresetColor.red.rgb)
        await viewModel.applyButtonAssignments([side])
        precondition(service.lightingColors.last == blue.effectiveColor,
                     "Restore the temporary DPI colour before committing other mouse settings")
        var breathing = green
        breathing.effect = .breathing
        breathing.includeHasteProbe = true
        await viewModel.applyLighting(state: breathing)
        precondition(service.directModes.last == false, "A static direct frame must not replace an animated effect")

        await viewModel.applyLighting(state: blue, persist: false)
        await viewModel.setActiveDevice(fingerprint)
        let writesAfterSwitch = service.lightingColors.count
        try await Task.sleep(nanoseconds: 650_000_000)
        precondition(service.lightingColors.count == writesAfterSwitch,
                     "Pending saves must not reach a newly selected device")
        service.lightingError = .notPermitted
        let previousLighting = store.state(for: fingerprint).lighting
        let windowsBeforeControl = permissionWindows
        await viewModel.applyLighting(state: green, persist: false)
        precondition(store.state(for: fingerprint).lighting == previousLighting,
                     "Failed previews must not be recorded as applied")
        let probesAfterControlDenial = service.probeCount
        await viewModel.refresh()
        precondition(service.probeCount == probesAfterControlDenial && permissionWindows == windowsBeforeControl,
                     "A device-level refusal with a valid grant must wait for reconnection without requesting access")
        service.lightingError = nil

        let casts = [UInt32(11), 12].map { id in
            MicrophoneInfo(id: id, name: "HyperX QuadCast 2 S", manufacturer: "HyperX", uid: "mic-\(id)",
                           sampleRate: nil, inputStreamCount: 1, volumePercent: nil, isMuted: nil, isDefaultInput: false)
        }
        audio.microphones = casts
        await viewModel.refresh()
        await viewModel.applyQuadCast2SEffect(.default, for: casts[1])
        precondition(castService.effectWrites == 0, "Never apply an effect to an ambiguous controller")
        audio.microphones.removeFirst()
        await viewModel.refresh()
        await viewModel.applyQuadCast2SEffect(.default, for: casts[0])
        await viewModel.applyQuadCast2SEffect(.default, for: casts[1])
        precondition(castService.effectWrites == 1, "Only the attached microphone may control the remaining LampArray")

        viewModel.setPollInterval(.infinity)
        precondition(viewModel.pollInterval == 60)
        viewModel.stop()
        print("View-model lifecycle, SoloCast isolation and lighting cancellation tests passed")
    }
}
