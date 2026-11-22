//
//  DeviceStateStore.swift
//  MacGenuity
//
//  Per-device persisted state. Keyed by a stable identifier built from the
//  device's HID fingerprint (VID + PID + usage page + usage). Each device
//  remembers its own last-applied lighting and DPI selection — switching
//  to a different HyperX product no longer leaks state from another.
//

import Foundation
import Combine

struct DeviceLightingState: Codable, Equatable {
    var target: LEDTarget
    var effect: LEDEffect
    var color: RGBColor
    /// Hardware brightness byte (0–100). Maps to byte 10 of the `D2` packet.
    var brightness: Int
    /// Software RGB attenuation (0–255). Multiplied into R/G/B before the
    /// packet is built — independent from `brightness` and applies to all
    /// effects. Intended to feel like NGENUITY's "Opacity" slider.
    var opacity: Int
    var speed: Int
    var includeHasteProbe: Bool

    static let `default` = DeviceLightingState(
        target: .logo,
        effect: .staticColor,
        color: PresetColor.red.rgb,
        brightness: 100,
        opacity: 255,
        speed: 0,
        includeHasteProbe: false
    )

    /// Pre-multiplies `color` by `opacity / 255`. Returned colour is what
    /// actually goes on the wire.
    var effectiveColor: RGBColor {
        let alpha = max(0, min(255, opacity))
        let scale = Double(alpha) / 255.0
        let safe = color.clamped()
        return RGBColor(
            red:   Int((Double(safe.red)   * scale).rounded()),
            green: Int((Double(safe.green) * scale).rounded()),
            blue:  Int((Double(safe.blue)  * scale).rounded())
        )
    }
}

/// One DPI level entry — matches NGENUITY's "DPI Settings" rows: a value,
/// an indicator colour, and an enabled flag (NGENUITY enables 5 by default
/// but lets the user disable individual levels via the radio bitmap).
struct DPILevel: Codable, Equatable, Identifiable {
    var id: Int { index }
    /// 1-based profile index (1…5), shown in the UI as "DPI 1", "DPI 2", …
    let index: Int
    var dpi: Int
    var color: RGBColor
    var enabled: Bool
}

struct DeviceDPIState: Codable, Equatable {
    /// Always 5 entries with `index` 1…5; profile slots a Pulsefire device
    /// supports. Disabled entries simply don't get cycled when the user
    /// presses the on-mouse DPI button.
    var levels: [DPILevel]
    /// 1-based active profile index.
    var activeProfile: Int

    func normalized() -> DeviceDPIState {
        var safeLevels = Self.default.levels.map { fallback -> DPILevel in
            guard var level = levels.first(where: { $0.index == fallback.index }) else {
                return fallback
            }
            level.dpi = (max(50, min(16_000, level.dpi)) / 50) * 50
            level.color = level.color.clamped()
            return level
        }
        var selected = max(1, min(5, activeProfile))
        if !safeLevels.contains(where: { $0.enabled }) {
            safeLevels[selected - 1].enabled = true
        }
        if !safeLevels[selected - 1].enabled {
            selected = safeLevels.first(where: { $0.enabled })?.index ?? selected
        }
        return DeviceDPIState(levels: safeLevels, activeProfile: selected)
    }

    static let `default` = DeviceDPIState(
        levels: [
            DPILevel(index: 1, dpi: 400,  color: PresetColor.red.rgb,    enabled: true),
            DPILevel(index: 2, dpi: 800,  color: PresetColor.yellow.rgb, enabled: true),
            DPILevel(index: 3, dpi: 1600, color: PresetColor.green.rgb,  enabled: true),
            DPILevel(index: 4, dpi: 3200, color: PresetColor.blue.rgb,   enabled: true),
            DPILevel(index: 5, dpi: 6400, color: PresetColor.white.rgb,  enabled: false)
        ],
        activeProfile: 2
    )
}

/// Per-device button-remap state. Keyed by physical button so missing
/// entries fall back to the factory default in `ButtonAction.factoryDefault`.
struct DeviceButtonState: Codable, Equatable {
    var assignments: [ButtonAssignment]

    static let `default` = DeviceButtonState(
        assignments: PhysicalButton.allCases.map { btn in
            ButtonAssignment(button: btn, action: ButtonAction.factoryDefault(for: btn))
        }
    )

    /// Returns the assignment for `button`, falling back to factory default
    /// if the device hasn't been customised yet.
    func action(for button: PhysicalButton) -> ButtonAction {
        assignments.first(where: { $0.button == button })?.action
            ?? ButtonAction.factoryDefault(for: button)
    }
}

struct DeviceState: Codable, Equatable {
    var lighting: DeviceLightingState
    var dpi: DeviceDPIState
    var buttons: DeviceButtonState

    static let `default` = DeviceState(
        lighting: .default,
        dpi: .default,
        buttons: .default
    )

    // Custom decoder: legacy stores written before `buttons` was added
    // would otherwise fail to decode, dropping all per-device state.
    enum CodingKeys: String, CodingKey { case lighting, dpi, buttons }

    init(lighting: DeviceLightingState, dpi: DeviceDPIState, buttons: DeviceButtonState) {
        self.lighting = lighting
        self.dpi = dpi
        self.buttons = buttons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lighting = try container.decode(DeviceLightingState.self, forKey: .lighting)
        self.dpi = try container.decode(DeviceDPIState.self, forKey: .dpi).normalized()
        self.buttons = try container.decodeIfPresent(DeviceButtonState.self, forKey: .buttons)
            ?? .default
    }
}

@MainActor
final class DeviceStateStore: ObservableObject {
    @Published private(set) var statesByKey: [String: DeviceState] = [:]

    private let defaults: UserDefaults
    private let storageKey = "deviceStates.v1"
    private let multipleReceiversKey = "deviceStates.multipleReceivers.v1"
    private var modelsWithMultipleReceivers: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modelsWithMultipleReceivers = Set(defaults.stringArray(forKey: multipleReceiversKey) ?? [])
        load()
    }

    func state(for fingerprint: DeviceFingerprint) -> DeviceState {
        if fingerprint.serialNumber == nil, !modelsWithMultipleReceivers.contains(fingerprint.modelInterfaceKey),
           let state = statesByKey[fingerprint.modelInterfaceKey] { return state }
        if let state = statesByKey[fingerprint.stableKey] { return state }
        guard !modelsWithMultipleReceivers.contains(fingerprint.modelInterfaceKey) else { return .default }
        return statesByKey[fingerprint.modelInterfaceKey] ?? .default
    }

    func setConnectedDevices(_ devices: [DeviceFingerprint]) {
        let groups = Dictionary(grouping: devices, by: \.modelInterfaceKey)
        let shared = groups.compactMap { $0.value.count > 1 ? $0.key : nil }
        if !modelsWithMultipleReceivers.isSuperset(of: shared) {
            modelsWithMultipleReceivers.formUnion(shared)
            defaults.set(modelsWithMultipleReceivers.sorted(), forKey: multipleReceiversKey)
        }
        // Keep a port snapshot for the known receiver in case a second one is attached later.
        var changed = false
        for device in devices where !modelsWithMultipleReceivers.contains(device.modelInterfaceKey) {
            let hasIndividualState = device.serialNumber != nil && statesByKey[device.stableKey] != nil
            if !hasIndividualState, let state = statesByKey[device.modelInterfaceKey],
               state != statesByKey[device.stableKey] {
                statesByKey[device.stableKey] = state
                changed = true
            }
        }
        if changed { persist() }
    }

    func update(_ fingerprint: DeviceFingerprint,
                _ transform: (inout DeviceState) -> Void)
    {
        var state = state(for: fingerprint)
        transform(&state)
        statesByKey[fingerprint.stableKey] = state
        if fingerprint.serialNumber == nil, fingerprint.stableKey != fingerprint.modelInterfaceKey,
           !modelsWithMultipleReceivers.contains(fingerprint.modelInterfaceKey) {
            // A receiver without a serial number can be moved to another USB port.
            statesByKey[fingerprint.modelInterfaceKey] = state
        }
        persist()
    }

    func record(lighting: DeviceLightingState, for fingerprint: DeviceFingerprint) {
        update(fingerprint) { $0.lighting = lighting }
    }

    func record(dpi: DeviceDPIState, for fingerprint: DeviceFingerprint) {
        update(fingerprint) { $0.dpi = dpi }
    }

    func record(buttons: DeviceButtonState, for fingerprint: DeviceFingerprint) {
        update(fingerprint) { $0.buttons = buttons }
    }

    /// Backwards-compat helper used by the live-stream path: updates
    /// just the active profile and its DPI value, leaves other levels
    /// untouched.
    func record(activeProfile: Int, dpi: Int, for fingerprint: DeviceFingerprint) {
        update(fingerprint) { state in
            state.dpi.activeProfile = activeProfile
            if let idx = state.dpi.levels.firstIndex(where: { $0.index == activeProfile }) {
                state.dpi.levels[idx].dpi = dpi
            }
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: DeviceState].self, from: data)
        else { return }
        statesByKey = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(statesByKey) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
