import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var settings: AppSettings

    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeviceHeading(title: heading, context: "MacGenuity") {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                        .foregroundStyle(.white)
                        .background(Circle().fill(.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r")
                .accessibilityLabel("Refresh devices")
                .help("Refresh devices (⌘R)")
            }

            if viewModel.status == .connected, let profile = viewModel.activeProfile {
                if viewModel.mouseAsleep {
                    statusLine("Mouse asleep · move it to wake", icon: "moon")
                } else {
                    metrics(profile.capabilities)
                }
            } else {
                switch viewModel.status {
                case .permissionRequired:
                    InputMonitoringHelp().padding(16)
                case .error(let message):
                    statusLine(message, icon: "exclamationmark.triangle")
                case .disconnected where viewModel.microphones.isEmpty:
                    statusLine("Connect a HyperX device", icon: "cable.connector")
                default:
                    EmptyView()
                }
            }

            if !viewModel.microphones.isEmpty {
                if viewModel.status == .connected { Divider().padding(.horizontal, 16) }
                VStack(spacing: 0) {
                    ForEach(viewModel.microphones) { mic in microphoneRow(mic) }
                }
                .padding(.vertical, 4)
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    showWindow("settings")
                } label: {
                    Label("Settings…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(",")
                Spacer()
                Menu {
                    Button("Check for Updates…", action: updater.check)
                        .disabled(!updater.canCheck)
                        .keyboardShortcut("u")
                    Button("Diagnostics…") { showWindow("diagnostics") }
                        .keyboardShortcut("d")
                    Divider()
                    Button("Quit MacGenuity") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
                .help("More actions")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 352)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(DeviceTheme.accent)
        .task { await viewModel.refresh() }
    }

    private var heading: String {
        switch viewModel.status {
        case .connected:
            let name = viewModel.info?.displayName ?? viewModel.activeProfile?.fingerprint.product ?? ""
            return name.isEmpty ? "Mouse connected" : DeviceTheme.shortName(name)
        case .unknown: return "Checking devices…"
        case .permissionRequired: return "Input Monitoring required"
        case .error: return "Device unavailable"
        case .disconnected: return viewModel.microphones.isEmpty ? "No devices connected" : "Microphone controls"
        }
    }

    private func metrics(_ capabilities: DeviceCapabilities) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if capabilities.contains(.battery) {
                let battery = viewModel.battery
                let low = battery.map { !$0.isCharging && settings.lowBatteryWarningEnabled && $0.percent <= settings.lowBatteryThreshold } ?? false
                metric("Battery", icon: battery?.symbol ?? "battery.0") {
                    HStack(spacing: 4) {
                        Text(battery.map { "\($0.percent)%" } ?? "—").monospacedDigit()
                        if low {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption).foregroundStyle(DeviceTheme.accent)
                        }
                    }
                }
                .accessibilityValue(battery.map { "\($0.percent) percent" + ($0.isCharging ? ", charging" : low ? ", low" : "") } ?? "Unavailable")
            }
            if capabilities.contains(.dpiProfiles) {
                let state = viewModel.reportedDPI
                let dpi = state?.levels.first { $0.index == state?.activeProfile }?.dpi
                if capabilities.contains(.battery) { metricDivider }
                metric("DPI", icon: "scope") { Text(dpi.map(String.init) ?? "—").monospacedDigit() }
                    .accessibilityValue(dpi.map(String.init) ?? "Unavailable")
            }
            if capabilities.contains(.lighting) {
                if !capabilities.isDisjoint(with: [.battery, .dpiProfiles]) { metricDivider }
                metric("Lighting", icon: "lightbulb") { colourValue }
                    .accessibilityValue(colourText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
    }

    private var metricDivider: some View {
        Divider().frame(height: 39).accessibilityHidden(true)
    }

    private func metric<Value: View>(_ title: String, icon: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DeviceTheme.caption)
            value().font(.system(size: 20, weight: .semibold)).frame(minHeight: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var colourText: String {
        switch viewModel.wheelColour {
        case .single(let rgb): return "#" + rgb.hexString
        case .multicolour: return "Multicolour"
        case .off: return "Off"
        case nil: return "Unavailable"
        }
    }

    @ViewBuilder private var colourValue: some View {
        switch viewModel.wheelColour {
        case .single(let rgb):
            HStack(spacing: 5) {
                Circle().fill(Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255))
                    .overlay(Circle().strokeBorder(.primary.opacity(0.35), lineWidth: 1))
                    .frame(width: 12, height: 12)
                Text(colourText).font(.system(size: 13, weight: .medium, design: .monospaced))
            }
        case .multicolour:
            HStack(spacing: 5) {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                    .frame(width: 12, height: 12)
                Text(colourText).font(.system(size: 12, weight: .semibold))
            }
        case .off: Text("Off")
        case nil: Text("—")
        }
    }

    private func statusLine(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.callout)
            .foregroundStyle(.secondary).padding(16)
    }

    private func microphoneRow(_ mic: MicrophoneInfo) -> some View {
        let muted = mic.needsSystemUnmute || mic.controlMuteState == true
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: muted ? "mic.slash" : "mic")
                    .foregroundStyle(muted ? DeviceTheme.accent : .secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(DeviceTheme.shortName(mic.displayName)).font(.callout.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                MicrophoneMuteControls(microphone: mic, viewModel: viewModel)
            }
            if let message = viewModel.microphoneMessages[mic.id] {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func showWindow(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
