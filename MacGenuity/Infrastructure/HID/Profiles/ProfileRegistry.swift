//
//  ProfileRegistry.swift
//  MacGenuity
//
//  Central registry of supported device profiles. Community contributors
//  add their profiles here — see PROFILES.md.
//

import Foundation

final class ProfileRegistry {
    static let shared = ProfileRegistry()

    private(set) var profiles: [DeviceProfile] = []

    init() {
        // -------------------------------------------------------------
        // Register profiles in order of specificity (most specific first
        // is fine; matching is score-based, not order-based, but it's
        // visually clearer).
        //
        // To contribute a new profile:
        //   1. Add a class implementing `DeviceProfile` under this folder
        //   2. Append a `register(MyDeviceProfile())` line below
        //   3. Open a PR — see PROFILES.md
        // -------------------------------------------------------------
        register(PulsefireHasteProfile())
        register(QuadCastProfile())
        register(DefaultHyperXProfile())
    }

    func register(_ profile: DeviceProfile) {
        profiles.append(profile)
    }

    func resolve(for fingerprint: DeviceFingerprint) -> DeviceProfile? {
        profiles.map { (profile: $0, score: $0.match(fingerprint)) }
            .filter { $0.score > 0 }
            .max { $0.score < $1.score }?.profile
    }

    func supportsMouseControls(_ fingerprint: DeviceFingerprint) -> Bool {
        guard let profile = resolve(for: fingerprint) else { return false }
        return !profile.capabilities.isDisjoint(with: [.battery, .lighting, .dpiProfiles, .buttons])
    }

    /// Use the same ranking for the sidebar and the transport, even when
    /// IOKit returns equally scored interfaces in a different order.
    func preferredInterface(in devices: [DeviceFingerprint]) -> DeviceFingerprint? {
        let ranked = devices.map { fp in
            let score = resolve(for: fp).map { $0.match(fp) + interfaceBonus(for: fp) }
            return (fingerprint: fp, score: score ?? -1)
        }
        return ranked.max { lhs, rhs in
            if lhs.score == rhs.score { return lhs.fingerprint.stableKey > rhs.fingerprint.stableKey }
            return lhs.score < rhs.score
        }?.fingerprint
    }

    private func interfaceBonus(for fp: DeviceFingerprint) -> Double {
        var bonus = 0.0
        if fp.usagePage == 0xFF13 || fp.usagePage == 0xFF00 { bonus += 0.2 }
        if fp.maxFeature >= PacketUtils.packetSize { bonus += 0.05 }
        if fp.maxOutput  >= PacketUtils.packetSize { bonus += 0.05 }
        return bonus
    }
}
