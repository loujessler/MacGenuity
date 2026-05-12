//
//  DeviceViewModel.swift
//  MacGenuity
//
//  Owns the published state observed by the menu bar UI. @MainActor.
//  Heavy work runs in the actor-isolated `DeviceService`.
//

import Foundation
import SwiftUI

extension Notification.Name {
    static let deviceDidChange = Notification.Name("MacGenuity.deviceDidChange")
}

@MainActor
final class DeviceViewModel: ObservableObject {
    @Published private(set) var status: MouseStatus = .unknown
    @Published private(set) var info: MouseInfo?
    @Published private(set) var battery: BatteryState?
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var microphones: [MicrophoneInfo] = []
    @Published private(set) var lastControlMessage: String?
    @Published private(set) var accessState: HIDAccessState = .unknown
    @Published private(set) var activeProfile: ActiveProfileSnapshot?
    /// All HyperX-shaped devices currently attached, deduped by VID:PID.
    /// Populated on every refresh so the device-picker stays current.
    @Published private(set) var availableDevices: [DeviceFingerprint] = []

    /// The stable key the user has currently *picked* in the device
    /// selector, independent of whether a profile claims that device.
    /// E.g. selecting a HyperX microphone keeps `selectedDeviceKey` set
    /// to the mic's key even though no profile resolves it; the picker
    /// can therefore still show the user's choice.
    @Published private(set) var selectedDeviceKey: String?

    private let minimumPollInterval: TimeInterval = 15
    private(set) var pollInterval: TimeInterval = 60

    let deviceService: DeviceService
    let audioService: AudioService
    let history: BatteryHistory
    let presetStore: PresetStore
    let deviceStates: DeviceStateStore
    let notifier: Notifier
    private let logger: LoggerType
    private weak var settings: AppSettings?

    private var pollTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var microphoneObserver: NSObjectProtocol?
    /// Restores the previous lighting state after a DPI profile colour flash.
    /// Cancellable so rapid radio clicks coalesce into one final restore.
    private var dpiPreviewRestoreTask: Task<Void, Never>?

    /// Last fingerprint we've seen connected. Used to detect device-switch
    /// events and reload per-device state.
    private var lastFingerprintKey: String?

    init(deviceService: DeviceService? = nil,
         audioService: AudioService? = nil,
         history: BatteryHistory? = nil,
         presetStore: PresetStore? = nil,
         deviceStates: DeviceStateStore? = nil,
         notifier: Notifier? = nil,
         logger: LoggerType = FileLogger.shared)
    {
        self.deviceService = deviceService ?? HyperXDeviceService()
        self.audioService = audioService ?? CoreAudioMicrophoneService()
        self.history = history ?? BatteryHistory()
        self.presetStore = presetStore ?? PresetStore()
        self.deviceStates = deviceStates ?? DeviceStateStore()
        self.notifier = notifier ?? Notifier.shared
        self.logger = logger
        self.accessState = self.deviceService.currentAccessState()

        // Push updates from CoreAudio: when the on-device tap-to-mute
        // pad or any other app toggles the input device's mute / volume
        // state, refresh immediately instead of waiting for the next
        // poll tick (which can be 60 s away).
        microphoneObserver = NotificationCenter.default.addObserver(
            forName: .microphoneStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
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
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.pollInterval ?? 60
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
        Task { [weak self] in await self?.deviceService.disconnect() }
        logger.info(.app, "DeviceViewModel stopped")
    }

    func setPollInterval(_ interval: TimeInterval) {
        pollInterval = max(minimumPollInterval, interval)
        logger.info(.app, "pollInterval=\(pollInterval)")
    }

    // MARK: - Permission

    func refreshAccessState() {
        accessState = deviceService.currentAccessState()
    }

    func requestAccess() async {
        accessState = await deviceService.requestAccess()
        if accessState == .granted {
            await refresh()
        }
    }

    /// One-shot first-launch helper. If macOS has never seen us ask for
    /// Input Monitoring, `currentAccessState()` returns `.unknown` and
    /// no system prompt is ever shown — `IOHIDRequestAccess` is what
    /// actually triggers the TCC dialog. Call this at app startup so
    /// the user gets the standard "MacGenuity wants to monitor input"
    /// alert instead of silently broken HID probing.
    func requestAccessIfNeeded() async {
        let state = deviceService.currentAccessState()
        accessState = state
        guard state == .unknown else { return }
        logger.info(.app, "first-launch: triggering Input Monitoring prompt")
        await requestAccess()
    }

    func openInputMonitoringSettings() {
        HIDPermission.openSystemSettings()
    }

    // MARK: - Refresh

    func refresh() async {
        let mics = audioService.connectedMicrophones()
        self.microphones = mics
        // Also keep the device picker fresh — discovery is cheap and
        // doesn't open anything, so it can run on every poll.
        let devices = deviceService.availableDevices()
        self.availableDevices = devices

        // Reconcile the user's saved selection with what's actually
        // present. Three cases:
        //   • selection is still attached    → keep it
        //   • selection is gone              → fall back to first available
        //   • no selection yet (cold start)  → default to first available
        let availableKeys = Set(devices.map { $0.stableKey })
        if let key = selectedDeviceKey, !availableKeys.contains(key) {
            selectedDeviceKey = devices.first?.stableKey
        } else if selectedDeviceKey == nil, let first = devices.first {
            selectedDeviceKey = first.stableKey
        }

        accessState = deviceService.currentAccessState()
        if accessState == .denied {
            self.status = .permissionRequired
            self.lastError = PermissionError.inputMonitoringDenied.errorDescription
            return
        }

        do {
            let snapshot = try await deviceService.probe()
            let newProfile = await deviceService.snapshotProfile()
            let newKey = newProfile?.fingerprint.stableKey

            // Detect device-switch and CLEAR cached state. Without this,
            // unplugging a Pulsefire while a QuadCast remains attached
            // would leave the mouse's stale battery glyph in the menu
            // bar — the new active profile (QuadCast) has no battery
            // capability and its probe returns nil battery, but the
            // previous `self.battery` was never reset.
            if newKey != lastFingerprintKey {
                self.info = nil
                self.battery = nil
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
            self.activeProfile = newProfile

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
                        deviceName: info?.displayName
                    )
                }
            } else if newProfile?.capabilities.contains(.battery) != true {
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
            accessState = .denied
            self.status = .permissionRequired
            self.lastError = PermissionError.inputMonitoringDenied.errorDescription
        } catch HIDError.deviceNotFound {
            self.status = .disconnected
            self.lastError = nil
            self.info = nil
            self.battery = nil
            self.activeProfile = nil
            lastFingerprintKey = nil
        } catch {
            self.status = .error(error.localizedDescription)
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Lighting / DPI

    func applyLighting(state: DeviceLightingState) async {
        keepaliveTask?.cancel(); keepaliveTask = nil
        presetStore.recordColor(state.color)

        // Opacity is software-side: pre-multiply the RGB before sending.
        // This applies to all effects (static, breathing, etc.) and is
        // independent from the hardware brightness byte.
        let wireColor = state.effectiveColor

        do {
            try await deviceService.applyLighting(
                target: state.target,
                effect: state.effect,
                color: wireColor,
                brightness: state.brightness,
                speed: state.speed,
                includeHasteProbe: state.includeHasteProbe
            )
            // Persist as the last-applied state for THIS device.
            if let fp = activeProfile?.fingerprint {
                deviceStates.record(lighting: state, for: fp)
            }
            lastControlMessage = "Lighting applied"
            if state.includeHasteProbe && state.effect == .staticColor {
                startKeepalive(color: wireColor)
            }
        } catch HIDError.notPermitted {
            accessState = .denied
            lastControlMessage = "Permission required"
        } catch {
            lastControlMessage = "Lighting failed: \(error.localizedDescription)"
            logger.error(.lighting, "applyLighting: \(error.localizedDescription)")
        }
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

    /// Live-stream variant of `applyLighting`: sends one frame, does not
    /// touch the keepalive task, does not record the colour in recents,
    /// silently swallows transient HID errors. Used by the colour picker's
    /// "Live update" toggle while the user drags sliders.
    func streamLightingFrame(target: LEDTarget,
                             effect: LEDEffect,
                             color: RGBColor,
                             brightness: Int,
                             speed: Int) async
    {
        do {
            try await deviceService.applyLighting(
                target: target, effect: effect, color: color,
                brightness: brightness, speed: speed,
                includeHasteProbe: false
            )
        } catch HIDError.notPermitted {
            accessState = .denied
        } catch {
            // Live updates fire often; do not flood the UI with transient
            // errors — the user will see the issue on the next `Apply`.
            logger.debug(.lighting, "stream frame failed: \(error.localizedDescription)")
        }
    }

    func applyPreset(_ preset: LightingPreset) async {
        await applyLighting(state: DeviceLightingState(
            target: preset.target,
            effect: preset.effect,
            color: preset.color,
            brightness: preset.brightness,
            opacity: preset.opacity,
            speed: preset.speed,
            includeHasteProbe: preset.includeHasteProbe
        ))
    }

    /// NGENUITY-style: write every profile (DPI + colour + enable bitmap)
    /// and select the active one in a single batch. Used by the new DPI
    /// pane that mirrors NGENUITY's UX.
    func applyDPIBatch(levels: [DPILevel], activeProfile: Int) async {
        keepaliveTask?.cancel(); keepaliveTask = nil
        do {
            try await deviceService.applyDPIBatch(levels: levels,
                                                  activeProfile: activeProfile)
            if let fp = self.activeProfile?.fingerprint {
                deviceStates.record(
                    dpi: DeviceDPIState(levels: levels, activeProfile: activeProfile),
                    for: fp
                )
            }
            lastControlMessage = "DPI batch applied (active = \(activeProfile))"
        } catch HIDError.notPermitted {
            accessState = .denied
            lastControlMessage = "Permission required"
        } catch HIDError.deviceNotFound {
            lastControlMessage = "Device not found — replug receiver"
        } catch {
            lastControlMessage = "DPI batch failed: \(error.localizedDescription)"
            logger.error(.hid, "applyDPIBatch: \(error.localizedDescription)")
        }
    }

    func applyDPI(profile: Int, dpi: Int) async {
        keepaliveTask?.cancel(); keepaliveTask = nil
        do {
            try await deviceService.applyDPI(profile: profile, dpi: dpi)
            if let fp = activeProfile?.fingerprint {
                deviceStates.record(activeProfile: profile, dpi: dpi, for: fp)
            }
            lastControlMessage = "DPI profile \(profile) set to \(dpi)"
        } catch HIDError.notPermitted {
            accessState = .denied
            lastControlMessage = "Permission required"
        } catch {
            lastControlMessage = "DPI failed: \(error.localizedDescription)"
            logger.error(.hid, "applyDPI: \(error.localizedDescription)")
        }
    }

    // MARK: - Microphones

    /// Toggle mute on a HyperX microphone via CoreAudio. Triggers a
    /// refresh so the UI mirrors what actually happened on the device.
    func setMicrophoneMute(_ muted: Bool, for mic: MicrophoneInfo) async {
        let ok = audioService.setMicrophoneMute(muted, deviceID: mic.id)
        lastControlMessage = ok
            ? "Microphone \(muted ? "muted" : "unmuted")"
            : "Mute not settable (use the on-device tap-to-mute)"
        await refresh()
    }

    /// Set software input volume on a HyperX microphone (0…100 %).
    /// QuadCast / SoloCast may refuse this and require the hardware
    /// gain dial — in that case `ok == false` and we surface a note.
    func setMicrophoneVolume(_ percent: Int, for mic: MicrophoneInfo) async {
        let scalar = Float(max(0, min(100, percent))) / 100.0
        let ok = audioService.setMicrophoneVolume(scalar, deviceID: mic.id)
        if !ok {
            lastControlMessage = "Volume not settable in software — use the hardware gain dial"
        }
        await refresh()
    }

    // MARK: - Buttons

    /// Send the full set of `0xD4` packets followed by a single commit,
    /// then mirror the new mapping into per-device state so reopening
    /// the editor shows what the device actually has.
    func applyButtonAssignments(_ assignments: [ButtonAssignment]) async {
        keepaliveTask?.cancel(); keepaliveTask = nil
        do {
            try await deviceService.applyButtonAssignments(assignments)
            if let fp = activeProfile?.fingerprint {
                deviceStates.record(buttons: DeviceButtonState(assignments: assignments),
                                    for: fp)
            }
            lastControlMessage = "Button assignments applied"
        } catch HIDError.notPermitted {
            accessState = .denied
            lastControlMessage = "Permission required"
        } catch HIDError.deviceNotFound {
            lastControlMessage = "Device not found — replug receiver"
        } catch {
            lastControlMessage = "Buttons failed: \(error.localizedDescription)"
            logger.error(.hid, "applyButtonAssignments: \(error.localizedDescription)")
        }
    }

    // MARK: - Device selection

    func setActiveDevice(_ fingerprint: DeviceFingerprint?) async {
        // Remember the user's choice independently of whether a profile
        // resolves it. This way the picker keeps showing the chosen
        // device's name even when (e.g.) the user picks a microphone
        // that doesn't have a HID control profile.
        selectedDeviceKey = fingerprint?.stableKey
        await deviceService.setActiveDevice(fingerprint)
        // Force a refresh so activeProfile / battery hydrate from the new device.
        await refresh()
    }

    /// Live-preview helper: send the `D3 00 + commit` select packet AND
    /// flash the profile's indicator colour through the LED via a one-shot
    /// `D2` static-colour packet so the user gets visual feedback. The
    /// previous lighting state is automatically restored after
    /// `dpiPreviewDuration` so this acts as a non-persistent preview —
    /// only the explicit "Apply lighting" path persists.
    private static let dpiPreviewDuration: TimeInterval = 1.5

    func selectDPIProfile(_ profile: Int, previewColor: RGBColor) async {
        // Cancel any in-flight restore from a previous click.
        dpiPreviewRestoreTask?.cancel()
        dpiPreviewRestoreTask = nil

        // Capture the lighting state to restore BEFORE the flash. If the
        // user has never applied lighting, this is the default (red,
        // brightness 100, opacity 255). Keepalive — if any — is cancelled
        // by the upcoming applyLighting calls.
        let restoreState = currentDeviceState.lighting

        do {
            // 1. Apply the DPI select packet (D3 00 + commit). DPI
            //    actually changes here.
            try await deviceService.selectDPIProfile(profile)
            if let fp = activeProfile?.fingerprint {
                deviceStates.update(fp) { $0.dpi.activeProfile = profile }
            }

            // 2. Push the profile's colour to the LED for visible feedback.
            //    Use the preview-grade `streamLightingFrame` so we don't
            //    spawn a haste keepalive or write the colour into preset
            //    history — this is a TRANSIENT flash, not user intent.
            await streamLightingFrame(
                target: .logo,
                effect: .staticColor,
                color: previewColor.clamped(),
                brightness: 100,
                speed: 0
            )
        } catch HIDError.notPermitted {
            accessState = .denied
            return
        } catch {
            logger.warning(.hid, "selectDPIProfile preview failed: \(error.localizedDescription)")
            return
        }

        // 3. Schedule a restore of the previous lighting after the
        //    preview window. Cancellable so consecutive clicks within
        //    the window only restore once at the end.
        let duration = UInt64(Self.dpiPreviewDuration * 1_000_000_000)
        dpiPreviewRestoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            if Task.isCancelled { return }
            await self?.streamLightingFrame(
                target: .logo,
                effect: restoreState.effect,
                color: restoreState.effectiveColor,
                brightness: restoreState.brightness,
                speed: restoreState.speed
            )
        }
    }

    // MARK: - Keepalive

    private func startKeepalive(color: RGBColor) {
        let service = deviceService
        let log = logger
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await service.sendHasteDirectFrame(color)
                } catch HIDError.notPermitted {
                    self?.accessState = .denied
                    return
                } catch {
                    log.warning(.lighting, "keepalive: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        lastControlMessage = "Static lighting keepalive started"
    }
}
