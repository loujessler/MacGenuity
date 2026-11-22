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

    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection

            if viewModel.status == .permissionRequired {
                divider
                InputMonitoringHelp()
                    .font(.system(size: 11))
                    .padding(.horizontal, 14)
            }

            if hasMouseDetails {
                divider; mouseSection
            }

            if viewModel.battery != nil, history.samples.count >= 2 {
                divider; batterySection
            }

            if !viewModel.microphones.isEmpty {
                divider; microphoneSection
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
        viewModel.info != nil || viewModel.battery != nil || partialReadError != nil
    }

    private var partialReadError: String? {
        viewModel.status == .connected ? viewModel.lastError : nil
    }

    @ViewBuilder
    private var statusSection: some View {
        switch viewModel.status {
        case .unknown:
            row(icon: "questionmark.circle", label: "Checking…")
        case .connected:
            HStack(spacing: 8) {
                Image(systemName: "computermouse").foregroundStyle(.secondary)
                let product = viewModel.activeProfile?.fingerprint.product ?? ""
                Text(viewModel.info?.displayName ?? (product.isEmpty ? "Mouse connected" : product))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let battery = viewModel.battery {
                    Label("\(battery.percent)%", systemImage: batteryIcon(battery))
                        .foregroundStyle(batteryColor(battery))
                        .monospacedDigit()
                        .fixedSize()
                        .accessibilityLabel(batteryDescription(battery))
                        .help(batteryDescription(battery))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        case .disconnected:
            if viewModel.microphones.isEmpty {
                row(icon: "powerplug", label: "No supported devices connected", muted: true)
            } else {
                row(icon: "mic", label: "Microphone connected")
            }
        case .permissionRequired:
            row(icon: "lock.shield", label: "Input Monitoring required", muted: true)
        case .error(let msg):
            row(icon: "exclamationmark.triangle", label: msg, muted: true)
        }
    }

    @ViewBuilder
    private var mouseSection: some View {
        if let battery = viewModel.battery {
            if shouldShowLowBatteryWarning(battery) {
                detailRow(label: "Warning", value: "Low battery")
            }
            let trend = history.trend
            if !trend.label.isEmpty {
                detailRow(label: "Trend", value: trend.label)
            }
        }
        if let info = viewModel.info {
            detailRow(label: "Firmware", value: info.firmware)
            detailRow(label: "VID/PID", value: "\(Hex.u16(info.vendorID)) / \(Hex.u16(info.productID))")
        }
        if let updated = viewModel.lastUpdate {
            TimelineView(.periodic(from: updated, by: 30)) { context in
                detailRow(label: "Updated", value: relativeTime(updated, now: context.date))
            }
        }
        if let partialReadError {
            detailRow(label: "Read error", value: partialReadError)
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
                microphoneRow(mic)
            }
        }
    }

    /// Quick mute/unmute row. Tap toggles via CoreAudio, the property
    /// listener pushes the new state back, and SwiftUI re-renders the
    /// row — all without closing the menu (the `.window` MenuBarExtra
    /// style keeps the panel open on button taps).
    private func microphoneRow(_ mic: MicrophoneInfo) -> some View {
        let muted = mic.isMuted == true
        return HStack(spacing: 8) {
            Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 13))
                .foregroundStyle(muted ? Color.red : Color.primary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(mic.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                let details = [mic.isMuted.map { $0 ? "Muted" : "Live" },
                               mic.isDefaultInput ? "Default input" : nil].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)

            if mic.isMuted != nil {
                // The toggle represents "microphone is live" — ON means
                // the mic is picking up sound, OFF means muted. This is
                // the inverse of CoreAudio's `kAudioDevicePropertyMute`,
                // so the binding flips the value on the way in/out.
                Toggle("\(mic.displayName) live input", isOn: Binding(
                    get: { !muted },
                    set: { isLive in
                        Task { await viewModel.setMicrophoneMute(!isLive, for: mic) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!mic.canSetMute)
                .help(muted ? "Switch on to unmute" : "Switch off to mute")
            } else {
                // Some HyperX mics route mute exclusively through the
                // on-device tap pad and don't expose a settable CoreAudio
                // property. Show a hint instead of a non-functional toggle.
                Text("hardware only")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
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
            menuButton(label: "Check for Updates…", systemImage: "arrow.down.circle", shortcut: "U") {
                updater.check()
            }
            .disabled(!updater.canCheck)
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

    private func relativeTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 5 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
