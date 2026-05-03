//
//  AppSettings.swift
//  MacGenuity
//
//  User-configurable preferences. Storage is plain UserDefaults.
//

import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    @Published var showBatteryPercent: Bool {
        didSet { defaults.set(showBatteryPercent, forKey: Keys.showBatteryPercent) }
    }

    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    @Published var lowBatteryWarningEnabled: Bool {
        didSet { defaults.set(lowBatteryWarningEnabled, forKey: Keys.lowBatteryWarningEnabled) }
    }

    @Published var lowBatteryThreshold: Int {
        didSet { defaults.set(lowBatteryThreshold, forKey: Keys.lowBatteryThreshold) }
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    private let defaults = UserDefaults.standard
    private let logger: LoggerType

    init(logger: LoggerType = FileLogger.shared) {
        self.logger = logger
        self.showBatteryPercent       = defaults.object(forKey: Keys.showBatteryPercent) as? Bool ?? true
        self.refreshInterval          = defaults.object(forKey: Keys.refreshInterval) as? TimeInterval ?? 60
        self.lowBatteryWarningEnabled = defaults.object(forKey: Keys.lowBatteryWarningEnabled) as? Bool ?? true
        self.lowBatteryThreshold      = defaults.object(forKey: Keys.lowBatteryThreshold) as? Int ?? 20
        self.launchAtLogin            = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = nil
            logger.info(.settings, "launchAtLogin=\(launchAtLogin)")
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
            logger.error(.settings, "launchAtLogin failed: \(error.localizedDescription)")
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private enum Keys {
        static let showBatteryPercent = "showBatteryPercent"
        static let refreshInterval = "refreshInterval"
        static let lowBatteryWarningEnabled = "lowBatteryWarningEnabled"
        static let lowBatteryThreshold = "lowBatteryThreshold"
    }
}
