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

struct DeviceState: Codable, Equatable {
    var lighting: DeviceLightingState
    var dpi: DeviceDPIState

    static let `default` = DeviceState(lighting: .default, dpi: .default)
}

extension DeviceFingerprint {
    /// Stable per-device key. Includes usage so different HID interfaces
    /// of the same physical device get distinct entries.
    var stableKey: String {
        String(format: "%04X:%04X:%04X:%04X",
               vendorID, productID, usagePage, usage)
    }
}

@MainActor
final class DeviceStateStore: ObservableObject {
    @Published private(set) var statesByKey: [String: DeviceState] = [:]

    private let defaults: UserDefaults
    private let storageKey = "deviceStates.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func state(for fingerprint: DeviceFingerprint) -> DeviceState {
        statesByKey[fingerprint.stableKey] ?? .default
    }

    func update(_ fingerprint: DeviceFingerprint,
                _ transform: (inout DeviceState) -> Void)
    {
        var state = statesByKey[fingerprint.stableKey] ?? .default
        transform(&state)
        statesByKey[fingerprint.stableKey] = state
        persist()
    }

    func record(lighting: DeviceLightingState, for fingerprint: DeviceFingerprint) {
        update(fingerprint) { $0.lighting = lighting }
    }

    func record(dpi: DeviceDPIState, for fingerprint: DeviceFingerprint) {
        update(fingerprint) { $0.dpi = dpi }
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
