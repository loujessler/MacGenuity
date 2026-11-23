//
//  BatteryHistory.swift
//  MacGenuity
//
//  Persists a rolling battery-percent timeline. Displayed in device settings.
//

import Foundation
import Combine

struct BatterySample: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let percent: Int
    let isCharging: Bool

    init(date: Date, percent: Int, isCharging: Bool) {
        self.id = UUID()
        self.date = date
        self.percent = percent
        self.isCharging = isCharging
    }
}

@MainActor
final class BatteryHistory: ObservableObject {
    @Published private(set) var samples: [BatterySample] = []

    private let defaults: UserDefaults
    private var key: String?
    private let maxSamples = 10 * 60 * 2
    static let timeWindow: TimeInterval = 10 * 60 * 60
    private let logger: LoggerType

    init(defaults: UserDefaults = .standard, logger: LoggerType = FileLogger.shared) {
        self.defaults = defaults
        self.logger = logger
    }

    func selectDevice(_ fingerprint: DeviceFingerprint?) {
        let newKey = fingerprint.map { "batteryHistory.v2." + $0.stableKey }
        guard newKey != key else { return }
        key = newKey
        samples = []
        load()
    }

    func record(percent: Int, isCharging: Bool, at date: Date = Date()) {
        guard key != nil else { return }
        // De-duplicate: skip recording if last sample is identical and < 60s old.
        if let last = samples.last,
           last.percent == percent,
           last.isCharging == isCharging,
           (0..<60).contains(date.timeIntervalSince(last.date)) { return }

        var copy = samples.filter { (0...Self.timeWindow).contains(date.timeIntervalSince($0.date)) }
        copy.append(BatterySample(date: date, percent: percent, isCharging: isCharging))
        if copy.count > maxSamples { copy.removeFirst(copy.count - maxSamples) }
        samples = copy
        persist()
    }

    func reset() {
        samples = []
        persist()
    }

    var trend: BatteryTrend {
        guard samples.count >= 2 else { return .unknown }
        let last = samples.suffix(8)
        let first = last.first!.percent
        let final = last.last!.percent
        let delta = final - first
        if last.last!.isCharging { return .charging }
        if delta <= -2 { return .discharging }
        if delta >= 2 { return .rising }
        return .stable
    }

    private func load() {
        guard let key, let data = defaults.data(forKey: key) else { return }
        do {
            samples = try JSONDecoder().decode([BatterySample].self, from: data)
        } catch {
            logger.warning(.battery, "history decode failed: \(error.localizedDescription)")
        }
    }

    private func persist() {
        guard let key else { return }
        do {
            let data = try JSONEncoder().encode(samples)
            defaults.set(data, forKey: key)
        } catch {
            logger.warning(.battery, "history encode failed: \(error.localizedDescription)")
        }
    }
}

enum BatteryTrend {
    case charging, discharging, stable, rising, unknown

    var label: String {
        switch self {
        case .charging:    return "charging"
        case .discharging: return "discharging"
        case .stable:      return "stable"
        case .rising:      return "rising"
        case .unknown:     return ""
        }
    }
}
