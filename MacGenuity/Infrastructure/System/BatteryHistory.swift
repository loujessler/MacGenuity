//
//  BatteryHistory.swift
//  MacGenuity
//
//  Persists a rolling battery-percent timeline. Used by the menu chart
//  and by trend-based notifications.
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
    private let key = "batteryHistory.v1"
    private let maxSamples = 24 * 60 / 5     // ~24h at one sample / 5 min, conservative
    private let logger: LoggerType

    init(defaults: UserDefaults = .standard, logger: LoggerType = FileLogger.shared) {
        self.defaults = defaults
        self.logger = logger
        load()
    }

    func record(percent: Int, isCharging: Bool, at date: Date = Date()) {
        // De-duplicate: skip recording if last sample is identical and < 60s old.
        if let last = samples.last,
           last.percent == percent,
           last.isCharging == isCharging,
           date.timeIntervalSince(last.date) < 60 { return }

        var copy = samples
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
        guard let data = defaults.data(forKey: key) else { return }
        do {
            samples = try JSONDecoder().decode([BatterySample].self, from: data)
        } catch {
            logger.warning(.battery, "history decode failed: \(error.localizedDescription)")
        }
    }

    private func persist() {
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
