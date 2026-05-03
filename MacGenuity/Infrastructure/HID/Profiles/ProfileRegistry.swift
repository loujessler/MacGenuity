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
        register(DefaultHyperXProfile())
    }

    func register(_ profile: DeviceProfile) {
        profiles.append(profile)
    }

    /// Score every profile against the candidate and return the best match
    /// (or `nil` if no profile claims the device).
    ///
    /// Logs at DEBUG only — `HyperXDeviceService.ensureTransport` logs at
    /// INFO once per actual connection, so production logs aren't spammed
    /// every poll cycle. Logging at INFO here also caused an infinite
    /// re-render loop in the diagnostics window: `FileLogger.tail` is
    /// `@Published`, the diagnostics view called `resolve(...)` from its
    /// body, the resulting INFO line appended to `tail`, SwiftUI re-rendered
    /// the view, the body called `resolve(...)` again, and so on.
    func resolve(for candidate: HIDDeviceCandidate,
                 logger: LoggerType = FileLogger.shared) -> DeviceProfile?
    {
        let scored = profiles.map { (profile: $0, score: $0.match(candidate.fingerprint)) }
        guard let best = scored.filter({ $0.score > 0.0 })
            .max(by: { $0.score < $1.score }) else { return nil }
        logger.debug(.hid, "resolved profile=\(best.profile.identifier) score=\(String(format: "%.2f", best.score)) for \(candidate.summary)")
        return best.profile
    }

    /// Pick the candidate that best matches any registered profile,
    /// preferring vendor control surfaces. Used when multiple HID
    /// interfaces of the same physical device are present.
    func selectBestCandidate(_ candidates: [HIDDeviceCandidate],
                             logger: LoggerType = FileLogger.shared) -> (HIDDeviceCandidate, DeviceProfile)?
    {
        var best: (HIDDeviceCandidate, DeviceProfile, Double)?
        for candidate in candidates {
            guard let profile = resolve(for: candidate, logger: logger) else { continue }
            let score = profile.match(candidate.fingerprint)
                + interfaceBonus(for: candidate.fingerprint)
            if best == nil || score > best!.2 {
                best = (candidate, profile, score)
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func interfaceBonus(for fp: DeviceFingerprint) -> Double {
        var bonus = 0.0
        if fp.usagePage == 0xFF13 || fp.usagePage == 0xFF00 { bonus += 0.2 }
        if fp.maxFeature >= PacketUtils.packetSize { bonus += 0.05 }
        if fp.maxOutput  >= PacketUtils.packetSize { bonus += 0.05 }
        return bonus
    }
}
