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
        // Two cases, no overlays:
        //   • a device with a battery → show the battery glyph and (opt.)
        //     percentage. That's the most actionable status the user can
        //     have in their peripheral vision.
        //   • everything else (no battery / nothing connected / mic only
        //     / probe error) → show the plain HyperX mark.
        //
        // Permission denied is the one exception: it's a system-level
        // problem the user must resolve in System Settings, so we surface
        // a shield instead of letting it hide behind the brand glyph.
        if viewModel.status == .permissionRequired {
            Image(systemName: "lock.shield")
        } else if let battery = viewModel.battery, viewModel.status != .disconnected {
            HStack(spacing: 2) {
                Image(systemName: batteryIcon(battery))
                if settings.showBatteryPercent {
                    Text("\(battery.percent)%")
                        .font(.system(size: 11, weight: .medium))
                }
            }
        } else {
            HyperXMark()
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
