//
//  MenuContent.swift
//  MacGenuity
//
//  Compact dropdown shown when the user clicks the menu bar icon.
//  Read-only status + small actionable buttons. All control editors
//  (lighting, DPI, presets) live in the Settings window — keeping the
//  dropdown narrow and uncluttered.
//

import SwiftUI
import AppKit

struct MenuContent: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var history: BatteryHistory

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection

            if viewModel.accessState == .denied || viewModel.status == .permissionRequired {
                divider; permissionSection
            }

            if hasMouseDetails {
                divider; mouseSection
            }

            if !history.samples.isEmpty {
                divider; batterySection
            }

            if !viewModel.microphones.isEmpty {
                divider; microphoneSection
            }

            if let active = viewModel.activeProfile {
                divider; profileBadge(active)
            }

            divider; actionsSection
        }
        .padding(.vertical, 6)
        .frame(width: 280)
    }

    // MARK: - Sections

    private var divider: some View {
        Divider().padding(.vertical, 4)
    }

    private var hasMouseDetails: Bool {
        viewModel.info != nil || viewModel.battery != nil || viewModel.lastError != nil
    }

    @ViewBuilder
    private var statusSection: some View {
        switch viewModel.status {
        case .unknown:
            row(icon: "questionmark.circle", label: "Checking…")
        case .connected:
            if let battery = viewModel.battery {
                batteryRow(battery)
            } else {
                row(icon: "computermouse", label: "Connected")
            }
        case .disconnected:
            row(icon: "computermouse.slash", label: "Mouse not found", muted: true)
        case .permissionRequired:
            row(icon: "lock.shield", label: "Input Monitoring required", muted: true)
        case .error(let msg):
            row(icon: "exclamationmark.triangle", label: msg, muted: true)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input Monitoring access required")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("If the toggle in System Settings is already ON but the app says denied, the build's signature changed. Remove MacGenuity from the list (− button) and re-grant after the next launch.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Grant") { Task { await viewModel.requestAccess() } }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Recheck") {
                    viewModel.refreshAccessState()
                    Task { await viewModel.refresh() }
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button("System Settings") { viewModel.openInputMonitoringSettings() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var mouseSection: some View {
        if let battery = viewModel.battery {
            detailRow(label: "Battery", value: batteryDescription(battery))
            if shouldShowLowBatteryWarning(battery) {
                detailRow(label: "Warning", value: "Low battery")
            }
            let trend = history.trend
            if !trend.label.isEmpty {
                detailRow(label: "Trend", value: trend.label)
            }
        }
        if let info = viewModel.info {
            detailRow(label: "Mouse", value: info.displayName)
            detailRow(label: "Firmware", value: info.firmware)
            detailRow(label: "VID/PID", value: "\(Hex.u16(info.vendorID)) / \(Hex.u16(info.productID))")
        }
        if let updated = viewModel.lastUpdate {
            detailRow(label: "Updated", value: relativeTime(updated))
        }
    }

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Battery history")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            BatterySparkline(samples: history.samples)
                .frame(height: 40)
                .padding(.horizontal, 14)
        }
    }

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Microphones")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            ForEach(viewModel.microphones) { mic in
                detailRow(label: "Device",
                          value: mic.displayName + (mic.isDefaultInput ? " (default)" : ""))
                if let muted = mic.isMuted {
                    detailRow(label: "Mute", value: muted ? "Muted" : "Live")
                }
            }
        }
    }

    private func profileBadge(_ active: ActiveProfileSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(active.displayName).font(.system(size: 11, weight: .medium))
                Text("\(active.capabilities.labels.joined(separator: " · "))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }

    private var actionsSection: some View {
        VStack(spacing: 0) {
            menuButton(label: "Refresh", systemImage: "arrow.clockwise", shortcut: "R") {
                Task { await viewModel.refresh() }
            }
            menuButton(label: "Settings…", systemImage: "gearshape", shortcut: ",") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            menuButton(label: "Diagnostics…", systemImage: "stethoscope", shortcut: "D") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "diagnostics")
            }
            menuButton(label: "Quit", systemImage: "power", shortcut: "Q") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Row builders

    private func batteryRow(_ b: BatteryState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: batteryIcon(b))
                .font(.system(size: 13))
                .foregroundStyle(batteryColor(b))
                .frame(width: 18)
            Text("\(b.percent)%")
                .font(.system(size: 13, weight: .medium))
            if b.isCharging {
                Text("charging")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func row(icon: String, label: String, muted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(muted ? .secondary : .primary)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(muted ? .secondary : .primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }

    private func menuButton(label: String, systemImage: String,
                            shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).frame(width: 16)
                Text(label).font(.system(size: 13))
                Spacer()
                Text("⌘\(shortcut)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(shortcut.lowercased())), modifiers: .command)
    }

    // MARK: - Helpers

    private func batteryIcon(_ b: BatteryState) -> String {
        if b.isCharging { return "battery.100.bolt" }
        switch b.percent {
        case 75...:    return "battery.100"
        case 50..<75:  return "battery.75"
        case 25..<50:  return "battery.50"
        case 10..<25:  return "battery.25"
        default:       return "battery.0"
        }
    }

    private func batteryColor(_ b: BatteryState) -> Color {
        if b.isCharging { return .green }
        switch b.percent {
        case ..<15: return .red
        case ..<30: return .orange
        default:    return .primary
        }
    }

    private func batteryDescription(_ b: BatteryState) -> String {
        b.isCharging ? "\(b.percent)% charging" : "\(b.percent)%"
    }

    private func shouldShowLowBatteryWarning(_ b: BatteryState) -> Bool {
        settings.lowBatteryWarningEnabled && !b.isCharging && b.percent <= settings.lowBatteryThreshold
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
