//
//  MenuBarLabel.swift
//  MacGenuity
//
//  Tray icon. Always renders something — even when no device is connected
//  or permission is missing — so the user can always reach the menu.
//

import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        // Single always-on icon path. The status influences which symbol
        // is shown but never collapses to nothing — that was the cause of
        // "tray icon disappears when mouse disconnects".
        if let battery = viewModel.battery, viewModel.status != .disconnected {
            HStack(spacing: 2) {
                Image(systemName: batteryIcon(battery))
                if settings.showBatteryPercent {
                    Text("\(battery.percent)%")
                        .font(.system(size: 11, weight: .medium))
                }
            }
        } else {
            Image(systemName: brandedFallbackIcon)
        }
    }

    /// Branded "no battery readout" icon. Picks the symbol that best
    /// describes the *current* state but never returns nil / blank.
    private var brandedFallbackIcon: String {
        switch viewModel.status {
        case .permissionRequired:
            return "lock.shield"
        case .disconnected:
            // Mouse is gone but we keep the same family glyph so the user
            // still recognises it as "their HyperX app".
            return "computermouse.slash"
        case .error:
            return "exclamationmark.triangle.fill"
        case .unknown, .connected:
            return "computermouse"
        }
    }

    private func batteryIcon(_ b: BatteryState) -> String {
        if b.isCharging { return "bolt" }
        switch b.percent {
        case 75...:    return "battery.100"
        case 50..<75:  return "battery.75"
        case 25..<50:  return "battery.50"
        case 10..<25:  return "battery.25"
        default:       return "battery.0"
        }
    }
}
