//
//  SettingsScene.swift
//  MacGenuity
//
//  Settings window. Hosts the live device-control editors that used to
//  clutter the menu-bar dropdown. Open via the menu's Settings… button.
//

import SwiftUI
import AppKit

struct SettingsScene: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var presetStore: PresetStore

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            LightingPane(viewModel: viewModel, presetStore: presetStore)
                .tabItem { Label("Lighting", systemImage: "lightbulb") }

            DPIPane(viewModel: viewModel)
                .tabItem { Label("DPI", systemImage: "scope") }

            ProfilesPane(viewModel: viewModel)
                .tabItem { Label("Profiles", systemImage: "puzzlepiece.extension") }

            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 460)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                Toggle("Show battery percent in menu bar", isOn: $settings.showBatteryPercent)
                Toggle("Notify on low battery", isOn: $settings.lowBatteryWarningEnabled)
            }

            Section {
                Picker("Refresh", selection: $settings.refreshInterval) {
                    Text("30 sec").tag(TimeInterval(30))
                    Text("1 min").tag(TimeInterval(60))
                    Text("5 min").tag(TimeInterval(300))
                    Text("15 min").tag(TimeInterval(900))
                }
                Picker("Low-battery threshold", selection: $settings.lowBatteryThreshold) {
                    ForEach([10, 15, 20, 25, 30, 40], id: \.self) { v in
                        Text("\(v)%").tag(v)
                    }
                }
            }

            if let error = settings.launchAtLoginError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Lighting

private struct LightingPane: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var presetStore: PresetStore

    @State private var effect: LEDEffect = .staticColor
    @State private var color: RGBColor = PresetColor.red.rgb
    @State private var brightness: Double = 100
    @State private var opacity: Double = 255
    @State private var speed: Double = 0
    @State private var includeHasteProbe: Bool = false
    @State private var liveStream: Bool = false
    @State private var presetName: String = ""

    @State private var streamTask: Task<Void, Never>?

    var body: some View {
        // Device picker is ALWAYS visible at the top. If the active
        // device doesn't support lighting (or no device is connected),
        // we still show the selector so the user can pick a different
        // device — without it, picking a microphone would lock them out
        // of the entire pane.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DevicePickerRow(viewModel: viewModel)
                Divider()

                if isCapable {
                    modePicker
                    Divider()
                    colorEditor
                    Divider()
                    slidersAndOptions
                    Divider()
                    applyRow
                    Divider()
                    presetsSection
                } else {
                    unsupportedNotice
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { hydrate() }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidChange)) { _ in
            hydrate()
        }
        .onChange(of: color) { newValue in scheduleLiveUpdate(newValue) }
        .onChange(of: opacity) { _ in scheduleLiveUpdate(color) }
    }

    private var isCapable: Bool {
        !viewModel.availableDevices.isEmpty
            && viewModel.activeProfile?.capabilities.contains(.lighting) == true
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode").font(.headline)
            // Target byte (0x00 logo / 0x10 wheel / 0x20 both) is part of
            // the protocol but only `.logo` (0x00) is actually addressable
            // on Pulsefire-class devices. The picker is hidden until a
            // future profile advertises a `lightingMultiZone` capability.
            HStack(spacing: 12) {
                Picker("Effect", selection: $effect) {
                    ForEach(LEDEffect.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 220)
                Spacer()
            }
            if !effect.isVerified {
                Label("This effect is not verified against captured NGENUITY traffic — behaviour is firmware-specific.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var colorEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colour").font(.headline)
            InteractiveColorPicker(color: $color, presetStore: presetStore)
                .frame(maxWidth: 460)
        }
    }

    private var slidersAndOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Brightness").frame(width: 90, alignment: .leading)
                Slider(value: $brightness, in: 0...100, step: 1)
                Text("\(Int(brightness))%").frame(width: 40, alignment: .trailing).monospacedDigit()
            }
            .help("Hardware brightness byte (D2 byte 10). Maps to 0–100 % on the device.")

            HStack(spacing: 8) {
                Text("Opacity").frame(width: 90, alignment: .leading)
                Slider(value: $opacity, in: 0...255, step: 1)
                Text("\(Int(opacity))").frame(width: 40, alignment: .trailing).monospacedDigit()
            }
            .help("Software RGB attenuation. Pre-multiplies the colour before sending. Independent from Brightness; works for every effect.")

            HStack(spacing: 8) {
                Text("Speed").frame(width: 90, alignment: .leading)
                Slider(value: $speed, in: 0...100, step: 1)
                    .disabled(!effect.usesSpeed)
                Text("\(Int(speed))%").frame(width: 40, alignment: .trailing).monospacedDigit()
            }
            .help(effect.usesSpeed ? "" : "Static colour ignores speed.")

            Toggle("Live update — stream while changing", isOn: $liveStream)
                .help("Send a colour packet on every slider change, like NGENUITY does while you drag its colour wheel.")

            if viewModel.activeProfile?.capabilities.contains(.hasteDirect) == true {
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Haste direct color (0x81 + 1 Hz keepalive)", isOn: $includeHasteProbe)
                        Text("Experimental. Sends a streamed-frame command + a 1 Hz keepalive. On Pulsefire firmware this is interpreted as 'next animation step' — leave OFF for plain static colour. Enabling this with the static effect produces a 1 Hz pulse.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var applyRow: some View {
        HStack {
            Button {
                Task { await viewModel.applyLighting(state: snapshotState()) }
            } label: {
                Label("Apply lighting", systemImage: "lightbulb")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
            .disabled(viewModel.activeProfile == nil)

            Spacer()

            if let message = viewModel.lastControlMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func snapshotState() -> DeviceLightingState {
        DeviceLightingState(
            target: .logo,
            effect: effect,
            color: color,
            brightness: Int(brightness.rounded()),
            opacity: Int(opacity.rounded()),
            speed: Int(speed.rounded()),
            includeHasteProbe: includeHasteProbe
        )
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.headline)
            if presetStore.presets.isEmpty {
                Text("Save the current configuration as a named preset to recall it later.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(presetStore.presets) { preset in
                        presetRow(preset)
                    }
                    .onDelete { indices in
                        for index in indices { presetStore.remove(presetStore.presets[index]) }
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 120, maxHeight: 200)
            }

            HStack(spacing: 8) {
                TextField("New preset name", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let trimmed = presetName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let preset = LightingPreset(
                        name: trimmed,
                        target: .logo, effect: effect, color: color,
                        brightness: Int(brightness.rounded()),
                        opacity: Int(opacity.rounded()),
                        speed: Int(speed.rounded()),
                        includeHasteProbe: includeHasteProbe
                    )
                    presetStore.add(preset)
                    presetName = ""
                }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func presetRow(_ preset: LightingPreset) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(swiftUIColor(preset.color))
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 0) {
                Text(preset.name).font(.system(size: 12, weight: .medium))
                Text("\(preset.effect.title) · \(preset.color.hexString) · α=\(preset.opacity)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                effect = preset.effect
                color = preset.color
                brightness = Double(preset.brightness)
                opacity = Double(preset.opacity)
                speed = Double(preset.speed)
                includeHasteProbe = preset.includeHasteProbe
            } label: {
                Image(systemName: "arrow.up.right.circle")
            }
            .buttonStyle(.borderless)
            .help("Load preset into editor")

            Button {
                Task { await viewModel.applyPreset(preset) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Apply preset on device")

            Button {
                presetStore.remove(preset)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete preset")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Load into editor") {
                effect = preset.effect
                color = preset.color
                brightness = Double(preset.brightness)
                opacity = Double(preset.opacity)
                speed = Double(preset.speed)
                includeHasteProbe = preset.includeHasteProbe
            }
            Button("Apply") { Task { await viewModel.applyPreset(preset) } }
            Divider()
            Button("Delete", role: .destructive) { presetStore.remove(preset) }
        }
    }

    private var unsupportedNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if viewModel.availableDevices.isEmpty {
                Text("No HyperX devices connected")
                    .font(.system(size: 13, weight: .medium))
                Text("Plug in a HyperX device to enable lighting controls.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Lighting is not supported by the active device")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Pick a different HyperX device above to control its lighting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }

    private func hydrate() {
        let s = viewModel.currentDeviceState.lighting
        effect = s.effect
        color = s.color
        brightness = Double(s.brightness)
        opacity = Double(s.opacity)
        speed = Double(s.speed)
        includeHasteProbe = s.includeHasteProbe
    }

    /// Debounced live-update: cancels the previous frame and sends a new
    /// one ~30 ms after the last colour or opacity change. Always sends
    /// without haste probing so dragging never starts the 1 Hz keepalive.
    private func scheduleLiveUpdate(_ newColor: RGBColor) {
        guard liveStream else { return }
        streamTask?.cancel()
        let attenuated = applyOpacity(newColor)
        let e = effect
        let b = Int(brightness.rounded())
        let sp = Int(speed.rounded())
        streamTask = Task { [weak viewModel] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            if Task.isCancelled { return }
            await viewModel?.streamLightingFrame(
                target: .logo, effect: e, color: attenuated,
                brightness: b, speed: sp
            )
        }
    }

    private func applyOpacity(_ c: RGBColor) -> RGBColor {
        let scale = max(0.0, min(255.0, opacity)) / 255.0
        let safe = c.clamped()
        return RGBColor(
            red:   Int((Double(safe.red)   * scale).rounded()),
            green: Int((Double(safe.green) * scale).rounded()),
            blue:  Int((Double(safe.blue)  * scale).rounded())
        )
    }

    private func swiftUIColor(_ c: RGBColor) -> Color {
        Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }
}

// MARK: - DPI (NGENUITY-style multi-profile editor)

private struct DPIPane: View {
    @ObservedObject var viewModel: DeviceViewModel

    @State private var levels: [DPILevel] = DeviceDPIState.default.levels
    @State private var activeProfile: Int = DeviceDPIState.default.activeProfile

    var body: some View {
        // Same pattern as LightingPane: picker is always visible so the
        // user can switch back from a non-DPI device without being locked
        // into an empty pane.
        VStack(alignment: .leading, spacing: 12) {
            DevicePickerRow(viewModel: viewModel)
            Divider()

            if isCapable {
                header
                Divider()
                levelsList
                Divider()
                footer
            } else {
                unsupportedNotice
                    .frame(maxWidth: .infinity, minHeight: 220)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { hydrate() }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidChange)) { _ in
            hydrate()
        }
    }

    private var isCapable: Bool {
        !viewModel.availableDevices.isEmpty
            && viewModel.activeProfile?.capabilities.contains(.dpiProfiles) == true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DPI Settings").font(.headline)
            Text("Tap the radio button to choose which profile is active. Each level can be enabled, set 50–16 000 DPI, and given an indicator colour shown on the mouse when you cycle through with the on-mouse DPI button.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var levelsList: some View {
        VStack(spacing: 6) {
            ForEach(levels.indices, id: \.self) { idx in
                levelRow(index: idx)
            }
        }
    }

    private func levelRow(index: Int) -> some View {
        let level = levels[index]
        let isActive = level.index == activeProfile
        let dpiBinding = Binding<Double>(
            get: { Double(levels[index].dpi) },
            set: { levels[index].dpi = stepDPI(Int($0.rounded())) }
        )
        let enabledBinding = Binding<Bool>(
            get: { levels[index].enabled },
            set: { levels[index].enabled = $0 }
        )

        return HStack(spacing: 10) {
            Button {
                activeProfile = level.index
                // Live preview: switch the active DPI profile AND flash
                // its indicator colour through the LED for ~1.5s so the
                // user gets visual confirmation without persisting.
                let pickedColor = levels[index].color
                Task {
                    await viewModel.selectDPIProfile(level.index,
                                                     previewColor: pickedColor)
                }
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help(isActive ? "Active profile" : "Make active (applies + flashes colour)")

            Text("DPI \(level.index)")
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(level.enabled ? .primary : .secondary)

            Slider(value: dpiBinding, in: 50...16_000, step: 50)
                .disabled(!level.enabled)
                .frame(maxWidth: .infinity)

            Text("\(level.dpi)")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(level.enabled ? .primary : .secondary)

            colorWell(for: index)
                .disabled(!level.enabled)

            Toggle("", isOn: enabledBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Enable / disable this profile in the on-mouse DPI cycle")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }

    private func colorWell(for index: Int) -> some View {
        let binding = Binding<Color>(
            get: {
                let c = levels[index].color
                return Color(red: Double(c.red) / 255,
                             green: Double(c.green) / 255,
                             blue: Double(c.blue) / 255)
            },
            set: { newValue in
                levels[index].color = rgb(from: newValue)
            }
        )
        return ColorPicker("", selection: binding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 36, height: 22)
            .help("Indicator colour for this DPI profile")
    }

    private var footer: some View {
        HStack {
            Text("Active: DPI \(activeProfile) (\(levels.first(where: { $0.index == activeProfile })?.dpi ?? 0))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset") {
                levels = DeviceDPIState.default.levels
                activeProfile = DeviceDPIState.default.activeProfile
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    await viewModel.applyDPIBatch(levels: levels,
                                                  activeProfile: activeProfile)
                }
            } label: {
                Label("Apply", systemImage: "scope")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
        }
    }

    private var unsupportedNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if viewModel.availableDevices.isEmpty {
                Text("No HyperX devices connected")
                    .font(.system(size: 13, weight: .medium))
                Text("Plug in a HyperX device to configure DPI profiles.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("DPI control is not supported by the active device")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Pick a different HyperX device above to configure DPI.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }

    private func hydrate() {
        let s = viewModel.currentDeviceState.dpi
        levels = s.levels
        activeProfile = s.activeProfile
    }

    private func stepDPI(_ raw: Int) -> Int {
        let clamped = min(16_000, max(50, raw))
        return (clamped / 50) * 50
    }

    private func rgb(from color: Color) -> RGBColor {
        // Convert through NSColor in sRGB for stable RGB extraction.
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        return RGBColor(
            red:   Int(round(ns.redComponent   * 255)),
            green: Int(round(ns.greenComponent * 255)),
            blue:  Int(round(ns.blueComponent  * 255))
        )
    }
}

// MARK: - Profiles

private struct ProfilesPane: View {
    @ObservedObject var viewModel: DeviceViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Registered device profiles").font(.headline)
                ForEach(ProfileRegistry.shared.profiles, id: \.identifier) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(profile.displayName).font(.system(size: 12, weight: .medium))
                            Spacer()
                            if viewModel.activeProfile?.identifier == profile.identifier {
                                Label("active", systemImage: "checkmark.seal")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            }
                        }
                        Text("id: \(profile.identifier) · author: \(profile.author)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(profile.capabilities.labels.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text("Add a profile via PROFILES.md in Infrastructure/HID/Profiles/.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Device picker (shared)

/// Lets the user pin a specific HyperX device when more than one is
/// attached. Default behaviour (no explicit selection) auto-picks the
/// highest-scoring device.
private struct DevicePickerRow: View {
    @ObservedObject var viewModel: DeviceViewModel

    /// What the picker shows. Driven by the user's last *choice*, not by
    /// whether a profile resolved it — picking a microphone keeps the
    /// label visible even though no `DeviceProfile` matches a SoloCast.
    private var selectionKey: String {
        viewModel.selectedDeviceKey
            ?? viewModel.activeProfile?.fingerprint.stableKey
            ?? viewModel.availableDevices.first?.stableKey
            ?? ""
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "computermouse")
                .foregroundStyle(.secondary)
            Text("Device")
                .frame(width: 60, alignment: .leading)

            Picker("", selection: Binding<String>(
                get: { selectionKey },
                set: { newKey in
                    guard let target = viewModel.availableDevices
                        .first(where: { $0.stableKey == newKey }) else { return }
                    Task { await viewModel.setActiveDevice(target) }
                }
            )) {
                if viewModel.availableDevices.isEmpty {
                    Text("No HyperX devices").tag("")
                } else {
                    ForEach(viewModel.availableDevices, id: \.stableKey) { fp in
                        Text(deviceLabel(fp)).tag(fp.stableKey)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(viewModel.availableDevices.isEmpty)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Re-scan connected devices")
        }
    }

    private func deviceLabel(_ fp: DeviceFingerprint) -> String {
        let name = fp.product.isEmpty ? "Unnamed HyperX" : fp.product
        return "\(name)  (\(Hex.u16(fp.vendorID))/\(Hex.u16(fp.productID)))"
    }
}

// MARK: - About

private struct AboutPane: View {
    private let config = DonationService.shared.config

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "computermouse")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("MacGenuity")
                .font(.title2.weight(.semibold))
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("v\(version) (\(build))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Open-source monitor for HyperX devices on macOS")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link("View on GitHub", destination: URL(string: "https://github.com/loujessler/MacGenuity")!)
                .font(.system(size: 12))
                .foregroundStyle(.blue)

            // --- SUPPORT BLOCK ---
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Text("Support development")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                DonationRow(
                    title: "USDT Polygon (PoS)",
                    value: config.usdt_polygon,
                    scheme: "ethereum"
                )
                DonationRow(
                    title: "USDT TRON (TRC20)",
                    value: config.usdt_trc20,
                    scheme: "tron"
                )
                DonationRow(
                    title: "Bitcoin",
                    value: config.btc,
                    scheme: "bitcoin"
                )
                // External page
//                 Link("All methods (cards, etc.)",
//                      destination: URL(string: "https://your-donation-page")!)
//                     .font(.system(size: 12))
            }
            // ----------------------
            Spacer()
            Text("MIT License")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DonationRow: View {
    let title: String
    let value: String
    let scheme: String?

    @State private var copied = false

    var shortValue: String {
        let prefix = value.prefix(6)
        let suffix = value.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))

                Text(shortValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Open in wallet
            if let scheme {
                Button {
                    if let url = URL(string: "\(scheme):\(value)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .help("Open in wallet")
            }

            // Copy button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)

                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy address")
        }
    }
}