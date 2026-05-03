//
//  Notifier.swift
//  MacGenuity
//
//  Wraps UNUserNotificationCenter for low-battery alerts. Stays
//  side-effect-free until something needs to fire.
//

import Foundation
import UserNotifications

@MainActor
final class Notifier {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false
    private var lastLowBatteryFireDate: Date?
    private let cooldownSeconds: TimeInterval = 60 * 30  // re-alert at most every 30 min
    private let logger: LoggerType

    init(logger: LoggerType = FileLogger.shared) {
        self.logger = logger
    }

    func ensureAuthorized() async {
        if authorizationRequested { return }
        authorizationRequested = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.warning(.app, "notifications: auth failed: \(error.localizedDescription)")
        }
    }

    /// Fire a low-battery notification if conditions warrant it.
    /// Throttled so we never spam the user.
    func notifyLowBatteryIfNeeded(percent: Int, threshold: Int, isCharging: Bool, deviceName: String?) async {
        guard !isCharging, percent <= threshold else { return }
        if let last = lastLowBatteryFireDate,
           Date().timeIntervalSince(last) < cooldownSeconds { return }

        await ensureAuthorized()

        let content = UNMutableNotificationContent()
        content.title = deviceName ?? "HyperX device"
        content.body = "Battery is at \(percent)%."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "lowBattery.\(percent)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            lastLowBatteryFireDate = Date()
            logger.info(.battery, "notify low battery percent=\(percent)")
        } catch {
            logger.warning(.app, "notifications: deliver failed: \(error.localizedDescription)")
        }
    }
}
