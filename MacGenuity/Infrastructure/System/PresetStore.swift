//
//  PresetStore.swift
//  MacGenuity
//
//  Persists user-created lighting presets and a recent-colors strip.
//

import Foundation
import Combine

struct LightingPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var target: LEDTarget
    var effect: LEDEffect
    var color: RGBColor
    var brightness: Int
    /// Software RGB attenuation (0–255). Optional during decode so old
    /// presets without the field still load — they default to fully opaque.
    var opacity: Int
    var speed: Int
    var includeHasteProbe: Bool

    init(id: UUID = UUID(), name: String,
         target: LEDTarget, effect: LEDEffect, color: RGBColor,
         brightness: Int, opacity: Int = 255,
         speed: Int, includeHasteProbe: Bool)
    {
        self.id = id
        self.name = name
        self.target = target
        self.effect = effect
        self.color = color
        self.brightness = brightness
        self.opacity = opacity
        self.speed = speed
        self.includeHasteProbe = includeHasteProbe
    }

    enum CodingKeys: String, CodingKey {
        case id, name, target, effect, color, brightness, opacity, speed, includeHasteProbe
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        target = try c.decode(LEDTarget.self, forKey: .target)
        effect = try c.decode(LEDEffect.self, forKey: .effect)
        color = try c.decode(RGBColor.self, forKey: .color)
        brightness = try c.decode(Int.self, forKey: .brightness)
        opacity = try c.decodeIfPresent(Int.self, forKey: .opacity) ?? 255
        speed = try c.decode(Int.self, forKey: .speed)
        includeHasteProbe = try c.decode(Bool.self, forKey: .includeHasteProbe)
    }
}

@MainActor
final class PresetStore: ObservableObject {
    @Published var presets: [LightingPreset] = [] {
        didSet { persistPresets() }
    }
    @Published var recentColors: [RGBColor] = [] {
        didSet { persistColors() }
    }

    private let defaults: UserDefaults
    private let presetsKey = "lightingPresets.v1"
    private let colorsKey  = "recentColors.v1"
    private let recentColorLimit = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.presets = loadPresets()
        self.recentColors = loadColors()
    }

    // MARK: - Presets

    func add(_ preset: LightingPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
    }

    func remove(_ preset: LightingPreset) {
        presets.removeAll { $0.id == preset.id }
    }

    func rename(_ preset: LightingPreset, to newName: String) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx].name = newName
    }

    // MARK: - Recent colors

    func recordColor(_ color: RGBColor) {
        let clamped = color.clamped()
        var list = recentColors.filter { $0 != clamped }
        list.insert(clamped, at: 0)
        if list.count > recentColorLimit {
            list = Array(list.prefix(recentColorLimit))
        }
        recentColors = list
    }

    // MARK: - Persistence

    private func loadPresets() -> [LightingPreset] {
        guard let data = defaults.data(forKey: presetsKey),
              let decoded = try? JSONDecoder().decode([LightingPreset].self, from: data)
        else { return [] }
        return decoded
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsKey)
    }

    private func loadColors() -> [RGBColor] {
        guard let data = defaults.data(forKey: colorsKey),
              let decoded = try? JSONDecoder().decode([RGBColor].self, from: data)
        else { return [] }
        return decoded
    }

    private func persistColors() {
        guard let data = try? JSONEncoder().encode(recentColors) else { return }
        defaults.set(data, forKey: colorsKey)
    }
}
