//
//  DeviceViewModel.swift
//  MacGenuity
//
//  Owns the published state observed by the menu bar UI. @MainActor.
//  Heavy work runs in the actor-isolated `DeviceService`.
//

import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    static let hidDevicesChanged = Notification.Name("MacGenuity.hidDevicesChanged")
    static let deviceDidChange = Notification.Name("MacGenuity.deviceDidChange")
}

@MainActor
final class DeviceViewModel: ObservableObject {
    @Published private(set) var status: MouseStatus = .unknown
    @Published private(set) var info: MouseInfo?
    @Published private(set) var battery: BatteryState?
    @Published private(set) var reportedDPI: DeviceDPIState?
    @Published private(set) var wheelColour: WheelColour?
    @Published private(set) var mouseAsleep = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var microphones: [MicrophoneInfo] = []
    @Published private(set) var microphoneMessages: [UInt32: String] = [:]
    @Published private(set) var lightingMessage: String?
    @Published private(set) var dpiMessage: String?
    @Published private(set) var buttonsMessage: String?
    @Published private(set) var quadCast2SState: QuadCast2SHardwareState = .disconnected
    @Published private(set) var quadCast2SControlMessage: String?
    @Published private(set) var accessState: HIDAccessState = .unknown
    @Published private(set) var activeProfile: ActiveProfileSnapshot?
    /// One representative interface per attached receiver.
    /// Populated on every refresh so the device-picker stays current.
    @Published private(set) var availableDevices: [DeviceFingerprint] = []

    /// The mouse currently targeted for control, including while connecting.
    @Published private(set) var selectedDevice: DeviceFingerprint?
    var selectedDeviceKey: String? { selectedDevice?.stableKey }

    private let minimumPollInterval: TimeInterval = 15
    private(set) var pollInterval: TimeInterval = 60

    let registry: ProfileRegistry
    let deviceService: DeviceService
    let audioService: AudioService
    let quadCast2SService: QuadCast2SService
    let history: BatteryHistory
    let presetStore: PresetStore
    let deviceStates: DeviceStateStore
    let quadCast2SStates: QuadCast2SStateStore
    let notifier: Notifier
    private let logger: LoggerType
    private weak var settings: AppSettings?

    var showInputMonitoringHelp: (() -> Void)?
    private var requestedInputMonitoring = false
    private var deniedAccessState: HIDAccessState?
    private var hidObserver: AnyCancellable?
    private var pollTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var lightingSaveTask: Task<Void, Never>?
    private var lightingWriteInFlight = false
    private var microphoneObserver: NSObjectProtocol?
    /// Restores the previous lighting state after a DPI profile colour flash.
    /// Cancellable so rapid radio clicks coalesce into one final restore.
    private var dpiPreviewRestoreTask: Task<Void, Never>?
    private var dpiFlashRestoreState: DeviceLightingState?
    private var dpiSelectionRevision: UInt64 = 0

    /// Last fingerprint we've seen connected. Used to detect device-switch
    /// events and reload per-device state.
    private var lastFingerprintKey: String?
    private var selectionGeneration: UInt64 = 0
    private var lightingGeneration: UInt64 = 0
    private var isRefreshing = false
    private var refreshPending = false

    init(deviceService: DeviceService? = nil,
         registry: ProfileRegistry = .shared,
         audioService: AudioService? = nil,
         quadCast2SService: QuadCast2SService? = nil,
         history: BatteryHistory? = nil,
         presetStore: PresetStore? = nil,
         deviceStates: DeviceStateStore? = nil,
         quadCast2SStates: QuadCast2SStateStore? = nil,
         notifier: Notifier? = nil,
         logger: LoggerType = FileLogger.shared)
    {
        self.registry = registry
        self.deviceService = deviceService ?? HyperXDeviceService(registry: registry)
        self.audioService = audioService ?? CoreAudioMicrophoneService()
        self.quadCast2SService = quadCast2SService ?? QuadCast2SHardwareService()
        self.history = history ?? BatteryHistory()
        self.presetStore = presetStore ?? PresetStore()
        self.deviceStates = deviceStates ?? DeviceStateStore()
        self.quadCast2SStates = quadCast2SStates ?? QuadCast2SStateStore()
        self.notifier = notifier ?? Notifier.shared
        self.logger = logger
        self.accessState = self.deviceService.currentAccessState()

        // Refresh audio state as soon as CoreAudio reports a change.
        microphoneObserver = NotificationCenter.default.addObserver(
            forName: .microphoneStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMicrophones()
            }
        }
    }

    deinit {
        if let microphoneObserver {
            NotificationCenter.default.removeObserver(microphoneObserver)
        }
    }

    /// State for the currently active device, or default if none.
    var currentDeviceState: DeviceState {
        guard let fp = activeProfile?.fingerprint else { return .default }
        return deviceStates.state(for: fp)
    }

    func attach(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        logger.info(.app, "DeviceViewModel started; log=\(FileLogger.shared.fileURL.path)")
        // Composite receivers publish several HID interfaces during one attachment.
        hidObserver = NotificationCenter.default.publisher(for: .hidDevicesChanged)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.pollInterval ?? 60
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        hidObserver = nil
        pollTask?.cancel(); pollTask = nil
        cancelLightingTasks()
        let service = deviceService
        let castService = quadCast2SService
        Task {
            await service.disconnect()
            await castService.stopLightingEffect()
        }
        logger.info(.app, "DeviceViewModel stopped")
    }

    func setPollInterval(_ interval: TimeInterval) {
        pollInterval = interval.isFinite ? min(900, max(minimumPollInterval, interval)) : 60
        logger.info(.app, "pollInterval=\(pollInterval)")
    }

    // MARK: - Permission

    private func handleAccessDenied(_ checkedState: HIDAccessState? = nil) async {
        let state = checkedState ?? deviceService.currentAccessState()
        guard deniedAccessState != state else { return }
        // Discard results still in flight for the connection that lost access.
        selectionGeneration &+= 1
        let generation = selectionGeneration
        accessState = state
        deniedAccessState = state
        clearDeviceState()
        if accessState == .granted {
            let message = "macOS denied access to the device. Reconnect it and try again."
            lastError = message
            status = .error(message)
            return
        }

        let shouldShowHelp = status != .permissionRequired
        status = .permissionRequired
        lastError = PermissionError.inputMonitoringDenied.errorDescription
        if accessState == .unknown && !requestedInputMonitoring {
            requestedInputMonitoring = true
            let result = await deviceService.requestAccess()
            guard generation == selectionGeneration else { return }
            accessState = result
            if result == .granted {
                deniedAccessState = nil
                await refresh()
                return
            }
            deniedAccessState = result
        }

        if shouldShowHelp { showInputMonitoringHelp?() }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshPending = false
            await refreshOnce()
        } while refreshPending && !Task.isCancelled
    }

    private func refreshMicrophones() {
        let connected = audioService.connectedMicrophones()
        guard microphones != connected else { return }
        microphoneMessages = microphoneMessages.filter { id, _ in
            guard let previous = microphones.first(where: { $0.id == id }) else { return false }
            return connected.contains(previous)
        }
        microphones = connected
    }

    private func refreshOnce() async {
        var generation = selectionGeneration
        refreshMicrophones()
        let mics = microphones
        // Enumeration can block in IOKit; run it on the service actor.
        let devices = await deviceService.availableDevices()
        guard generation == selectionGeneration else { return }
        if devices != availableDevices {
            deviceStates.setConnectedDevices(devices)
            availableDevices = devices
        }

        let mouse = devices.first { selectedDevice?.matchesAttachment($0) == true }
            ?? devices.first { $0.stableKey == selectedDeviceKey }
            ?? devices.first(where: registry.supportsMouseControls)
        if mouse != selectedDevice {
            beginSelection(mouse)
            generation = selectionGeneration
            await deviceService.setActiveDevice(mouse)
            guard generation == selectionGeneration else { return }
        }

        accessState = deviceService.currentAccessState()

        // QuadCast 2 S lighting and polar status live on dedicated
        // non-keyboard HID interfaces. They remain accessible when macOS
        // denies Input Monitoring to the generic mouse/keyboard transport,
        // so refresh them before applying that transport's permission gate.
        if mics.contains(where: { $0.isQuadCast2S }) {
            await refreshQuadCast2S()
        } else {
            quadCast2SState = .disconnected
            quadCast2SControlMessage = nil
        }

        guard generation == selectionGeneration else { return }
        guard let mouse else {
            clearDeviceState()
            status = .disconnected
            lastError = nil
            return
        }
        guard deniedAccessState != accessState else { return }
        deniedAccessState = nil
        if !mouse.isVendorControlInterface && accessState != .granted {
            await handleAccessDenied(accessState)
            return
        }

        do {
            let dpiRevision = dpiSelectionRevision
            let lightingRevision = lightingGeneration
            let snapshot = try await deviceService.probe()
            let newProfile = await deviceService.snapshotProfile()
            guard generation == selectionGeneration else { return }
            let newKey = newProfile?.fingerprint.stableKey
            if activeProfile != newProfile { activeProfile = newProfile }

            // Detect device-switch and CLEAR cached state. Without this,
            // unplugging a Pulsefire while a QuadCast remains attached
            // would leave the mouse's stale battery glyph in the menu
            // bar — the new active profile (QuadCast) has no battery
            // capability and its probe returns nil battery, but the
            // previous `self.battery` was never reset.
            let switched = newKey != lastFingerprintKey
            if switched {
                cancelLightingTasks()
                self.info = nil
                self.battery = nil
                self.reportedDPI = nil
                self.wheelColour = nil
                self.lastError = nil
                self.lastUpdate = nil
                if let key = newKey, let fp = newProfile?.fingerprint {
                    logger.info(.app, "device switched to \(key)")
                    NotificationCenter.default.post(
                        name: .deviceDidChange, object: nil,
                        userInfo: ["fingerprint": fp]
                    )
                } else {
                    logger.info(.app, "active HID device cleared")
                }
                lastFingerprintKey = newKey
            }
            let asleep = snapshot.error == .mouseAsleep
            if mouseAsleep != asleep { mouseAsleep = asleep }
            if mouse.isPulsefireHasteWireless {
                if dpiRevision == dpiSelectionRevision, reportedDPI != snapshot.dpi {
                    reportedDPI = snapshot.dpi
                }
                if switched || lightingRevision == lightingGeneration,
                   !lightingWriteInFlight, wheelColour != snapshot.wheelColour {
                    wheelColour = snapshot.wheelColour
                }
            }
            if let newInfo = snapshot.info { self.info = newInfo }
            if let battery = snapshot.battery {
                self.battery = battery
                self.lastUpdate = Date()
                history.record(percent: battery.percent, isCharging: battery.isCharging)
                if let settings, settings.lowBatteryWarningEnabled {
                    await notifier.notifyLowBatteryIfNeeded(
                        percent: battery.percent,
                        threshold: settings.lowBatteryThreshold,
                        isCharging: battery.isCharging,
                        deviceName: info?.displayName ?? mouse.product, deviceKey: mouse.stableKey
                    )
                    guard generation == selectionGeneration else { return }
                }
            } else {
                // Defensive: if the active profile genuinely has no
                // battery capability (a microphone, say), make sure the
                // UI doesn't keep a stale value across a refresh.
                self.battery = nil
                self.lastUpdate = nil
            }
            self.lastError = snapshot.error?.errorDescription

            if snapshot.battery != nil || snapshot.info != nil {
                self.status = .connected
            } else if let error = snapshot.error {
                self.status = .error(error.localizedDescription)
            } else {
                self.status = .connected
            }
        } catch HIDError.notPermitted {
            guard generation == selectionGeneration else { return }
            await handleAccessDenied()
        } catch HIDError.deviceNotFound {
            guard generation == selectionGeneration else { return }
            clearDeviceState()
            self.status = .disconnected
            self.lastError = nil
            self.info = nil
            self.battery = nil
            self.activeProfile = nil
            lastFingerprintKey = nil
        } catch {
            guard generation == selectionGeneration else { return }
            clearDeviceState()
            self.status = .error(error.localizedDescription)
            self.lastError = error.localizedDescription
        }
    }

    private func cancelLightingTasks() {
        lightingGeneration &+= 1
        lightingWriteInFlight = false
        dpiFlashRestoreState = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
        lightingSaveTask?.cancel(); lightingSaveTask = nil
        dpiPreviewRestoreTask?.cancel(); dpiPreviewRestoreTask = nil
    }

    private func clearDeviceState() {
        cancelLightingTasks()
        lightingMessage = nil
        dpiMessage = nil
        buttonsMessage = nil
        info = nil
        battery = nil
        reportedDPI = nil
        wheelColour = nil
        mouseAsleep = false
        lastUpdate = nil
        activeProfile = nil
        lastFingerprintKey = nil
    }

    // MARK: - Lighting / DPI

    func applyLighting(state: DeviceLightingState, persist: Bool = true) async {
        guard let fingerprint = activeProfile?.fingerprint else { return }
        cancelLightingTasks()
        let generation = selectionGeneration
        let lightingRevision = lightingGeneration
        lightingWriteInFlight = true
        defer { if lightingGeneration == lightingRevision { lightingWriteInFlight = false } }

        do {
            try await writeLighting(state, for: fingerprint, persist: persist)
            // Persist as the last-applied state for THIS device.
            guard generation == selectionGeneration,
                  lightingRevision == lightingGeneration else { return }
            if persist { presetStore.recordColor(state.color) }
            deviceStates.record(lighting: state, for: fingerprint)
            if state.frameBrightness == 0 {
                wheelColour = .off
            } else if state.effect == .spectrum || state.effect == .spectrumAlt {
                wheelColour = .multicolour
            } else {
                let scale = Double(state.frameBrightness) / 100
                let c = state.color.clamped()
                wheelColour = WheelColour(RGBColor(red: Int((Double(c.red) * scale).rounded()),
                                                   green: Int((Double(c.green) * scale).rounded()),
                                                   blue: Int((Double(c.blue) * scale).rounded())))
            }
            lightingMessage = persist ? "Lighting saved" : "Previewing lighting…"
            if persist {
                if usesDirectMode(state) {
                    startKeepalive(color: state.effectiveColor)
                }
            } else {
                // The view can close while this settles. Keep saving owned by
                // the model, and invalidate it on a newer edit or device switch.
                lightingSaveTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, let self,
                          generation == self.selectionGeneration,
                          lightingRevision == self.lightingGeneration else { return }
                    self.lightingSaveTask = nil
                    await self.applyLighting(state: state)
                }
            }
        } catch is CancellationError {
            return
        } catch HIDError.notPermitted {
            guard generation == selectionGeneration,
                  lightingRevision == lightingGeneration else { return }
            await handleAccessDenied()
        } catch {
            guard generation == selectionGeneration,
                  lightingRevision == lightingGeneration else { return }
            lightingMessage = "Lighting failed: \(error.localizedDescription)"
            logger.error(.lighting, "applyLighting: \(error.localizedDescription)")
        }
    }

    private func usesDirectMode(_ state: DeviceLightingState) -> Bool {
        state.includeHasteProbe && state.effect == .staticColor
            && activeProfile?.capabilities.contains(.hasteDirect) == true
            && activeProfile?.fingerprint.isPulsefireHasteWireless == false
    }

    private func writeLighting(_ state: DeviceLightingState, for fingerprint: DeviceFingerprint,
                               persist: Bool) async throws {
        let onboard = fingerprint.isPulsefireHasteWireless
        try await deviceService.applyLighting(
            target: state.target, effect: state.effect, color: onboard ? state.color : state.effectiveColor,
            brightness: onboard ? state.frameBrightness : state.brightness, speed: state.speed,
            includeHasteProbe: persist && usesDirectMode(state), persist: persist)
    }

    /// Convenience overload kept for older callers and presets.
    func applyLighting(target: LEDTarget,
                       effect: LEDEffect,
                       color: RGBColor,
                       brightness: Int,
                       opacity: Int = 255,
                       speed: Int,
                       includeHasteProbe: Bool) async
    {
        await applyLighting(state: DeviceLightingState(
            target: target, effect: effect, color: color,
            brightness: brightness, opacity: opacity,
            speed: speed, includeHasteProbe: includeHasteProbe
        ))
    }

    private func restoreDPIFlashIfNeeded() async throws {
        guard let state = dpiFlashRestoreState, let fingerprint = activeProfile?.fingerprint else { return }
        let revision = lightingGeneration
        dpiPreviewRestoreTask?.cancel()
        dpiPreviewRestoreTask = nil
        try await writeLighting(state, for: fingerprint, persist: false)
        guard revision == lightingGeneration else { return }
        dpiFlashRestoreState = nil
        if usesDirectMode(state) {
            startKeepalive(color: state.effectiveColor)
        }
    }

    func applyPreset(_ preset: LightingPreset) async {
        await applyLighting(state: preset.lightingState)
    }

    /// NGENUITY-style: write every profile (DPI + colour + enable bitmap)
    /// and select the active one in a single batch. Used by the new DPI
    /// pane that mirrors NGENUITY's UX.
    func applyDPIBatch(levels: [DPILevel], activeProfile: Int) async {
        guard let fingerprint = self.activeProfile?.fingerprint else { return }
        let generation = selectionGeneration
        dpiSelectionRevision &+= 1
        let revision = dpiSelectionRevision
        let state = DeviceDPIState(levels: levels, activeProfile: activeProfile)
            .normalized(forHasteWireless: fingerprint.isPulsefireHasteWireless)
        do {
            try await restoreDPIFlashIfNeeded()
            guard generation == selectionGeneration, revision == dpiSelectionRevision else { return }
            try await deviceService.applyDPIBatch(levels: state.levels,
                                                  activeProfile: state.activeProfile)
            guard generation == selectionGeneration, revision == dpiSelectionRevision else { return }
            deviceStates.record(dpi: state, for: fingerprint)
            reportedDPI = state
            dpiMessage = "DPI settings saved · active level \(state.activeProfile)"
        } catch HIDError.notPermitted {
            guard generation == selectionGeneration else { return }
            await handleAccessDenied()
        } catch HIDError.deviceNotFound {
            guard generation == selectionGeneration, revision == dpiSelectionRevision else { return }
            dpiMessage = "Mouse disconnected. Reconnect the receiver and try again."
        } catch {
            guard generation == selectionGeneration, revision == dpiSelectionRevision else { return }
            dpiMessage = "DPI settings failed: \(error.localizedDescription)"
            logger.error(.hid, "applyDPIBatch: \(error.localizedDescription)")
        }
    }

    func applyDPI(profile: Int, dpi: Int) async {
        guard let fingerprint = activeProfile?.fingerprint else { return }
        let dpi = DeviceDPIState.clampDPI(dpi, forHasteWireless: fingerprint.isPulsefireHasteWireless)
        let generation = selectionGeneration
        dpiSelectionRevision &+= 1
        let revision = dpiSelectionRevision
        do {
            try await restoreDPIFlashIfNeeded()
            guard generation == selectionGeneration, revision == dpiSelectionRevision else { return }
            try await deviceService.applyDPI(profile: profile, dpi: dpi)
            guard generation == selectionGeneration, revision == dpiSelectionRevision else { return }
            deviceStates.record(activeProfile: profile, dpi: dpi, for: fingerprint)
            reportedDPI = currentDeviceState.dpi
            dpiMessage = "DPI level \(profile) set to \(dpi)"
        } catch HIDError.notPermitted {
            guard generation == selectionGeneration else { return }
            await handleAccessDenied()
        } catch {
            guard generation == selectionGeneration, revision == dpiSelectionRevision else { return }
            dpiMessage = "DPI failed: \(error.localizedDescription)"
            logger.error(.hid, "applyDPI: \(error.localizedDescription)")
        }
    }

    // MARK: - Microphones

    func applyMicrophoneMute(_ action: MicrophoneMuteAction, for mic: MicrophoneInfo) {
        refreshMicrophones()
        guard let current = microphones.first(where: { $0.id == mic.id && $0.uid == mic.uid }),
              current.allows(action) else { return }
        let accepted = audioService.applyMicrophoneMute(action, for: current)
        refreshMicrophones()
        guard let updated = microphones.first(where: { $0.id == mic.id && $0.uid == mic.uid }) else { return }
        switch action {
        case .system(let muted):
            microphoneMessages[mic.id] = accepted && updated.isMuted == muted
                ? nil : "Couldn’t confirm the macOS mute change."
        case .soloCastHardware(let muted):
            microphoneMessages[mic.id] = accepted && updated.hardwareMuted == muted
                ? nil : "Couldn’t confirm the mute change. Check the SoloCast."
        }
    }

    func observeSoloCastMute(for mic: MicrophoneInfo) async {
        guard mic.hardwareMuted != nil else { return }
        while !Task.isCancelled {
            guard let index = microphones.firstIndex(where: { $0.id == mic.id && $0.uid == mic.uid }) else { return }
            let muted = audioService.soloCastHardwareMute(for: mic.uid)
            if microphones[index].hardwareMuted != muted {
                microphones[index].hardwareMuted = muted
                microphoneMessages[mic.id] = nil
            }
            guard muted != nil else { return }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }

    /// Set software input volume on a HyperX microphone (0…100 %).
    /// QuadCast / SoloCast may refuse this and require the hardware
    /// gain dial — in that case `ok == false` and we surface a note.
    func setMicrophoneVolume(_ percent: Int, for mic: MicrophoneInfo) async {
        let scalar = Float(max(0, min(100, percent))) / 100.0
        let ok = audioService.setMicrophoneVolume(scalar, deviceID: mic.id)
        microphoneMessages[mic.id] = ok ? nil : "Input volume cannot be changed through CoreAudio"
        refreshMicrophones()
    }

    func quadCast2SLightingPreference(
        for microphone: MicrophoneInfo
    ) -> QuadCast2SLightingPreference {
        quadCast2SStates.preference(for: microphone)
    }

    func refreshQuadCast2S() async {
        quadCast2SState = await quadCast2SService.snapshot()
    }

    func applyQuadCast2SLighting(
        color: RGBColor,
        brightness: Int,
        for microphone: MicrophoneInfo
    ) async {
        var configuration = quadCast2SStates
            .preference(for: microphone)
            .configuration
        configuration.kind = .solid
        if configuration.palette.isEmpty {
            configuration.palette = [color.clamped()]
        } else {
            configuration.palette[0] = color.clamped()
        }
        configuration.brightness = brightness
        await applyQuadCast2SEffect(configuration, for: microphone)
    }

    func applyQuadCast2SEffect(
        _ source: QuadCast2SEffectConfiguration,
        for microphone: MicrophoneInfo
    ) async {
        guard canControlLighting(for: microphone) else { return }
        let configuration = source.normalized()
        let mode: QuadCast2SLightingMode = configuration.kind == .solid
            ? .staticColor
            : .hostEffect
        let preference = QuadCast2SLightingPreference(
            mode: mode,
            configuration: configuration
        )
        do {
            try await quadCast2SService.applyLightingEffect(configuration)
            quadCast2SStates.record(preference, for: microphone)
            quadCast2SControlMessage = configuration.kind.isAnimated
                ? "\(configuration.kind.title) is running"
                : "\(configuration.kind.title) applied"
            await refreshQuadCast2S()
        } catch is CancellationError {
            return
        } catch QuadCast2SError.notPermitted {
            quadCast2SControlMessage = QuadCast2SError.notPermitted.localizedDescription
            await refreshQuadCast2S()
        } catch {
            quadCast2SControlMessage = "Lighting failed: \(error.localizedDescription)"
            logger.error(.lighting, "QuadCast 2 S lighting: \(error.localizedDescription)")
        }
    }

    func stopQuadCast2SEffect() async {
        await quadCast2SService.stopLightingEffect()
        quadCast2SControlMessage = "Effect paused on its current frame"
        await refreshQuadCast2S()
    }

    func restoreQuadCast2SAutonomousLighting(for microphone: MicrophoneInfo) async {
        guard canControlLighting(for: microphone) else { return }
        do {
            try await quadCast2SService.restoreAutonomousLighting()
            var preference = quadCast2SStates.preference(for: microphone)
            preference.mode = .autonomous
            quadCast2SStates.record(preference, for: microphone)
            quadCast2SControlMessage = "Device animation restored"
            await refreshQuadCast2S()
        } catch is CancellationError {
            return
        } catch QuadCast2SError.notPermitted {
            quadCast2SControlMessage = QuadCast2SError.notPermitted.localizedDescription
            await refreshQuadCast2S()
        } catch {
            quadCast2SControlMessage = "Lighting failed: \(error.localizedDescription)"
            logger.error(.lighting, "QuadCast 2 S autonomous mode: \(error.localizedDescription)")
        }
    }

    private func canControlLighting(for microphone: MicrophoneInfo) -> Bool {
        let attached = microphones.filter(\.isQuadCast2S)
        guard attached.count <= 1 else {
            quadCast2SControlMessage = QuadCast2SError.ambiguousController.localizedDescription
            return false
        }
        return attached.first?.id == microphone.id && attached.first?.uid == microphone.uid
    }

    // MARK: - Buttons

    /// Send the full set of `0xD4` packets followed by a single commit,
    /// then mirror the new mapping into per-device state so reopening
    /// the editor shows what the device actually has.
    @discardableResult
    func applyButtonAssignments(_ assignments: [ButtonAssignment]) async -> Bool {
        let changes = assignments.filter { PhysicalButton.remappable.contains($0.button) }
        guard let fingerprint = activeProfile?.fingerprint, !changes.isEmpty else { return false }
        let generation = selectionGeneration
        do {
            try await restoreDPIFlashIfNeeded()
            guard generation == selectionGeneration else { return false }
            try await deviceService.applyButtonAssignments(changes)
            guard generation == selectionGeneration else { return false }
            deviceStates.update(fingerprint) { state in
                state.buttons.assignments.removeAll { existing in changes.contains { $0.button == existing.button } }
                state.buttons.assignments.append(contentsOf: changes)
            }
            buttonsMessage = "Button assignments applied"
            return true
        } catch HIDError.notPermitted {
            guard generation == selectionGeneration else { return false }
            await handleAccessDenied()
        } catch HIDError.deviceNotFound {
            guard generation == selectionGeneration else { return false }
            buttonsMessage = "Mouse disconnected. Reconnect the receiver and try again."
        } catch {
            guard generation == selectionGeneration else { return false }
            buttonsMessage = "Buttons failed: \(error.localizedDescription)"
            logger.error(.hid, "applyButtonAssignments: \(error.localizedDescription)")
        }
        return false
    }

    // MARK: - Device selection

    func setActiveDevice(_ fingerprint: DeviceFingerprint?) async {
        beginSelection(fingerprint)
        await deviceService.setActiveDevice(fingerprint)
        await refresh()
    }

    private func beginSelection(_ fingerprint: DeviceFingerprint?) {
        selectionGeneration &+= 1
        deniedAccessState = nil
        clearDeviceState()
        lastError = nil
        status = .unknown
        selectedDevice = fingerprint
        history.selectDevice(fingerprint)
    }

    private static let dpiPreviewDuration: TimeInterval = 1.5

    @discardableResult
    func selectDPIProfile(_ profile: Int, previewColor: RGBColor) async -> Bool {
        guard let fingerprint = activeProfile?.fingerprint else { return false }
        let generation = selectionGeneration
        let lightingRevision = lightingGeneration
        dpiSelectionRevision &+= 1
        let revision = dpiSelectionRevision
        do {
            // The firmware commit also persists the current LED state.
            try await restoreDPIFlashIfNeeded()
            guard generation == selectionGeneration, revision == dpiSelectionRevision else { return false }
            try await deviceService.selectDPIProfile(profile)
        } catch HIDError.notPermitted {
            if generation == selectionGeneration { await handleAccessDenied() }
            return false
        } catch {
            if generation == selectionGeneration, revision == dpiSelectionRevision {
                dpiMessage = "Couldn’t select DPI level: \(error.localizedDescription)"
            }
            return false
        }
        guard generation == selectionGeneration, revision == dpiSelectionRevision else { return false }
        deviceStates.update(fingerprint) { $0.dpi.activeProfile = profile }
        reportedDPI?.activeProfile = profile
        dpiMessage = "DPI level \(profile) selected"

        // PF002 already has the indicator colour for this slot. Replacing its
        // frame bank to flash a colour would destroy effects set by another app.
        if fingerprint.isPulsefireHasteWireless { return true }

        // A pending user colour takes precedence over temporary visual feedback.
        guard lightingRevision == lightingGeneration, !lightingWriteInFlight,
              lightingSaveTask == nil else { return true }
        cancelLightingTasks()
        let flashRevision = lightingGeneration
        let state = currentDeviceState.lighting
        dpiFlashRestoreState = state
        do {
            try await deviceService.applyLighting(
                target: state.target, effect: .staticColor, color: previewColor.clamped(),
                brightness: 100, speed: 0, includeHasteProbe: false, persist: false
            )
        } catch HIDError.notPermitted {
            if generation == selectionGeneration { await handleAccessDenied() }
            return true
        } catch {
            logger.warning(.lighting, "DPI indicator failed: \(error.localizedDescription)")
        }

        guard generation == selectionGeneration, revision == dpiSelectionRevision else { return false }
        guard flashRevision == lightingGeneration, dpiFlashRestoreState != nil else { return true }
        dpiPreviewRestoreTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.dpiPreviewDuration * 1_000_000_000))
                guard let self, self.lightingGeneration == flashRevision else { return }
                self.dpiPreviewRestoreTask = nil
                try await self.restoreDPIFlashIfNeeded()
            } catch is CancellationError {
                return
            } catch HIDError.notPermitted {
                guard let self, self.lightingGeneration == flashRevision else { return }
                await self.handleAccessDenied()
            } catch {
                guard let self, self.lightingGeneration == flashRevision else { return }
                self.lightingMessage = "Couldn’t restore lighting: \(error.localizedDescription)"
            }
        }
        return true
    }

    // MARK: - Keepalive

    private func startKeepalive(color: RGBColor) {
        let service = deviceService
        let log = logger
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await service.sendHasteDirectFrame(color)
                } catch HIDError.notPermitted {
                    guard !Task.isCancelled else { return }
                    await self?.handleAccessDenied()
                    return
                } catch {
                    log.warning(.lighting, "keepalive: \(error.localizedDescription)")
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
