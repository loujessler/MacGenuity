//
//  QuadCast2SStateStore.swift
//  MacGenuity
//
//  Persists the full lighting editor state per CoreAudio device UID.
//  Report 6 is write-only on the tested firmware, so the store also remembers
//  the last lighting mode successfully selected by MacGenuity.
//

import Foundation

@MainActor
final class QuadCast2SStateStore {
    private var preferencesByKey: [String: QuadCast2SLightingPreference] = [:]
    private let defaults: UserDefaults
    private let storageKey = "quadCast2S.lighting.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func preference(for microphone: MicrophoneInfo) -> QuadCast2SLightingPreference {
        preferencesByKey[key(for: microphone)] ?? .default
    }

    func record(
        _ preference: QuadCast2SLightingPreference,
        for microphone: MicrophoneInfo
    ) {
        preferencesByKey[key(for: microphone)] = QuadCast2SLightingPreference(
            mode: preference.mode,
            configuration: preference.configuration.normalized()
        )
        persist()
    }

    private func key(for microphone: MicrophoneInfo) -> String {
        microphone.uid.isEmpty
            ? microphone.displayName.lowercased()
            : microphone.uid
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                [String: QuadCast2SLightingPreference].self,
                from: data
              )
        else { return }
        preferencesByKey = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferencesByKey) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
