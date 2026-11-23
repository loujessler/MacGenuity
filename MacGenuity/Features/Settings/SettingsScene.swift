//
//  SettingsScene.swift
//  MacGenuity
//
//  Settings window. The "Devices" tab follows BetterDisplay's pattern:
//  a sidebar lists every connected HyperX device (HID + CoreAudio mic),
//  and the detail pane shows ONLY the controls that device's profile
//  actually supports — a mouse exposes lighting + DPI, a microphone
//  exposes audio properties, and a device with no recognised capability
//  shows a friendly "no controls available" notice.
//
//  There are no top-level "Lighting" or "DPI" tabs by design: those
//  controls live inside the device they belong to.
//

import SwiftUI
import AppKit

struct SettingsScene: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var presetStore: PresetStore

    var body: some View {
        TabView {
            DevicesPane(viewModel: viewModel, presetStore: presetStore)
                .tabItem { Label("Devices", systemImage: "externaldrive.connected.to.line.below") }

            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .tint(DeviceTheme.accent)
        .accentColor(DeviceTheme.accent)
        .frame(minWidth: 800, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var updater: AppUpdater
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

            Section("Software updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.checksAutomatically }, set: updater.setChecksAutomatically
                ))
                Toggle("Automatically download and install", isOn: Binding(
                    get: { updater.installsAutomatically }, set: updater.setInstallsAutomatically
                ))
                .disabled(!updater.checksAutomatically)
                Button("Check for Updates…", action: updater.check)
                    .disabled(!updater.canCheck)
            }

            if let error = settings.launchAtLoginError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Devices (sidebar + detail)

private struct DevicesPane: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var presetStore: PresetStore

    @State private var browsedDeviceID: String?

    var body: some View {
        let devices = unifiedDevices()
        let mouse = devices.first {
            guard case .hid(let fp) = $0 else { return false }
            return viewModel.selectedDevice?.matchesAttachment(fp) == true
        }
        let current = devices.first { $0.id == browsedDeviceID } ?? mouse ?? devices.first

        HSplitView {
            sidebar(devices: devices, selection: Binding(
                get: { current?.id },
                set: { id in
                    guard let device = devices.first(where: { $0.id == id }) else { return }
                    browsedDeviceID = id
                    if case .hid(let fp) = device, viewModel.registry.supportsMouseControls(fp),
                       viewModel.selectedDevice?.matchesAttachment(fp) != true {
                        Task { await viewModel.setActiveDevice(fp) }
                    }
                }
            ))
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
            detail(for: current)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: devices.map(\.id)) { ids in
            if let browsedDeviceID, !ids.contains(browsedDeviceID) { self.browsedDeviceID = nil }
        }
    }

    // MARK: Sidebar

    private func sidebar(devices: [ConfigurableDevice], selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Connected").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh connected devices")
                .help("Re-scan connected devices")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if devices.isEmpty {
                emptySidebarState
            } else {
                List(selection: selection) {
                    ForEach(ConfigurableDevice.Category.allCases, id: \.self) { category in
                        let group = devices.filter { $0.category == category }
                        if !group.isEmpty {
                            Section(category.title) {
                                ForEach(group) { device in
                                    sidebarRow(device)
                                        .tag(device.id as String?)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(_ device: ConfigurableDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: device.iconName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let subtitle = subtitle(for: device) {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var emptySidebarState: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: "powerplug")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No HyperX devices connected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Connect a mouse or microphone to get started.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private func subtitle(for device: ConfigurableDevice) -> String? {
        switch device {
        case .hid(let fp):
            guard let port = fp.locationID, viewModel.availableDevices.contains(where: {
                $0.product == fp.product && $0.locationID != fp.locationID
            }) else { return nil }
            return String(format: "USB port 0x%08X", port)
        case .microphone(let mic):
            if mic.isDefaultInput { return "Default input" }
            if let muted = mic.isMuted { return muted ? "Muted" : "Live" }
            return nil
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(for device: ConfigurableDevice?) -> some View {
        if let device {
            switch device {
            case .hid(let fp):
                HIDDeviceDetail(
                    fingerprint: fp,
                    viewModel: viewModel,
                    presetStore: presetStore
                )
                .id(fp.attachmentKey)
            case .microphone(let mic):
                MicrophoneDetail(microphone: mic, viewModel: viewModel)
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "cable.connector")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Waiting for a device")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Selection plumbing

    /// Build the deduped, sorted device list. Audio devices that have a
    /// matching HID interface (same product name, e.g. a QuadCast appearing
    /// as both HID and CoreAudio) are kept on the audio side because that
    /// entry has more user-actionable data (volume, mute, sample rate).
    private func unifiedDevices() -> [ConfigurableDevice] {
        let mics = viewModel.microphones.map { ConfigurableDevice.microphone($0) }
        let micNames = Set(viewModel.microphones.map { $0.displayName.lowercased() })

        let hids = viewModel.availableDevices.compactMap { fp -> ConfigurableDevice? in
            // Drop the HID interface if a microphone with the same product
            // name is already in the list — same physical device, different
            // bus.
            let lower = fp.lowercaseProduct
            if !lower.isEmpty, micNames.contains(where: { $0.contains(lower) || lower.contains($0) }) {
                return nil
            }
            return .hid(fp)
        }

        return mics + hids
    }
}

// MARK: - HID device detail

private struct HIDDeviceDetail: View {
    let fingerprint: DeviceFingerprint
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var presetStore: PresetStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let active = viewModel.activeProfile.flatMap { $0.fingerprint.matchesAttachment(fingerprint) ? $0 : nil }
                DeviceHeading(title: DeviceTheme.shortName(fingerprint.product.isEmpty ? "HyperX device" : fingerprint.product),
                              context: active == nil ? "Device settings" : "Mouse settings") {
                    if active != nil, let battery = viewModel.battery {
                        Label("\(battery.percent)%", systemImage: battery.symbol)
                            .font(.system(.headline).monospacedDigit()).foregroundStyle(.white)
                            .accessibilityLabel("Battery \(battery.percent) percent" + (battery.isCharging ? ", charging" : ""))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if let active {
                    if let error = viewModel.lastError {
                        Label(error, systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if active.capabilities.contains(.lighting) {
                        CollapsibleSection(title: "Lighting", systemImage: "lightbulb") {
                            LightingSection(viewModel: viewModel, presetStore: presetStore)
                        }
                    }
                    if active.capabilities.contains(.dpiProfiles) {
                        CollapsibleSection(title: "DPI", systemImage: "scope") {
                            DPISection(viewModel: viewModel)
                        }
                    }
                    if active.capabilities.contains(.buttons) {
                        CollapsibleSection(title: "Buttons", systemImage: "rectangle.grid.2x2") {
                            ButtonsSection(viewModel: viewModel)
                        }
                    }
                    if active.capabilities.contains(.battery) {
                        CollapsibleSection(title: "Battery history", systemImage: "chart.xyaxis.line") {
                            BatteryHistorySection(history: viewModel.history)
                        }
                    }
                } else {
                    connectionStatus
                }
                CollapsibleSection(title: "Device details", systemImage: "info.circle") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        if active != nil, let info = viewModel.info {
                            if let firmware = info.pairedMouseFirmware {
                                GridRow {
                                    Text("Mouse firmware")
                                    Text(firmware).monospacedDigit()
                                }
                            }
                            GridRow {
                                Text(fingerprint.isPulsefireHasteWireless && fingerprint.productID == 0x028E ? "Receiver firmware" : "Firmware")
                                Text(info.firmware).monospacedDigit()
                            }
                        }
                        GridRow {
                            Text("USB vendor / product")
                            Text("\(Hex.u16(fingerprint.vendorID)) / \(Hex.u16(fingerprint.productID))")
                                .font(.system(.body, design: .monospaced))
                        }
                        if active != nil, let updated = viewModel.lastUpdate {
                            GridRow {
                                Text("Last battery reading")
                                Text(updated, style: .time)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if !viewModel.registry.supportsMouseControls(fingerprint) {
            Text("Settings are unavailable for this device.")
                .foregroundStyle(.secondary)
        } else if viewModel.selectedDevice?.matchesAttachment(fingerprint) == true,
                  viewModel.status == .permissionRequired {
            InputMonitoringHelp()
        } else if viewModel.selectedDevice?.matchesAttachment(fingerprint) == true,
                  case .error(let message) = viewModel.status {
            Text(message).foregroundStyle(.secondary)
        } else if viewModel.selectedDevice?.matchesAttachment(fingerprint) == true,
                  viewModel.status == .disconnected {
            Text("Waiting for the mouse receiver.").foregroundStyle(.secondary)
        } else {
            ProgressView("Connecting to mouse…").controlSize(.small)
        }
    }
}

private struct BatteryHistorySection: View {
    @ObservedObject var history: BatteryHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.samples.count >= 2, let first = history.samples.first, let last = history.samples.last {
                HStack {
                    Text("Battery \(history.trend.label)").font(.callout)
                    Spacer()
                    Text("\(last.percent)%").monospacedDigit()
                }
                BatterySparkline(samples: history.samples, lineColor: DeviceTheme.accent,
                                 fillColor: DeviceTheme.accent.opacity(0.12))
                    .frame(height: 52)
                HStack {
                    Text(first.date, style: .time)
                    Spacer()
                    Text(last.date, style: .time)
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Collecting battery readings…").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Lighting (capability-gated)

private struct LightingSection: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var presetStore: PresetStore

    @State private var effect: LEDEffect = .staticColor
    @State private var target: LEDTarget = .logo
    @State private var color: RGBColor = PresetColor.red.rgb
    @State private var brightness: Double = 100
    @State private var opacity: Double = 255
    @State private var speed: Double = 0
    @State private var includeHasteProbe: Bool = false
    /// Preview changes immediately, then save once the user stops editing.
    @State private var liveStream: Bool = true
    @State private var presetName: String = ""
    @State private var editingColour = false
    private var onboard: Bool { viewModel.activeProfile?.fingerprint.isPulsefireHasteWireless == true }

    @State private var streamTask: Task<Void, Never>?
    @State private var hydratedState: DeviceLightingState?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modePicker
            if !onboard || effect != .spectrum { colorEditor }
            slidersAndOptions
            applyRow
            presetsSection
        }
        .onAppear { hydrate() }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidChange)) { _ in
            hydrate()
        }
        .onChange(of: color) { _ in scheduleLiveUpdate() }
        .onChange(of: opacity) { _ in scheduleLiveUpdate() }
        .onChange(of: brightness) { _ in scheduleLiveUpdate() }
        .onChange(of: speed) { _ in scheduleLiveUpdate() }
        .onChange(of: effect) { _ in scheduleLiveUpdate() }
        .onChange(of: target) { _ in scheduleLiveUpdate() }
        .onChange(of: includeHasteProbe) { _ in scheduleLiveUpdate() }
        .onChange(of: liveStream) { enabled in
            if enabled { scheduleLiveUpdate() } else { streamTask?.cancel() }
        }
        .onDisappear { streamTask?.cancel() }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Picker("Effect", selection: $effect) {
                    ForEach(onboard ? [.staticColor, .breathing, .spectrum, .triggerFade] : LEDEffect.allCases) {
                        Text(onboard ? $0.name : $0.title).tag($0)
                    }
                }
                .frame(maxWidth: 260)
                Spacer()
            }
            if !onboard && !effect.isVerified {
                Label("This effect is not verified against captured NGENUITY traffic — behaviour is firmware-specific.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var colorEditor: some View {
        HStack(spacing: 8) {
            Text("Colour").frame(width: 90, alignment: .leading)
            Button { editingColour.toggle() } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(swiftUIColor(color)).frame(width: 22, height: 16)
                    Text("#\(color.hexString)").monospaced()
                }
            }
            .accessibilityLabel("Edit lighting colour")
            .accessibilityValue(color.hexString)
            .popover(isPresented: $editingColour) {
                InteractiveColorPicker(color: $color, presetStore: presetStore).padding().frame(width: 330)
            }
        }
    }

    private var slidersAndOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Brightness").frame(width: 90, alignment: .leading)
                Slider(value: $brightness, in: 0...100, step: 1)
                    .accessibilityLabel("Brightness")
                Text("\(Int(brightness))%")
                    .frame(width: 40, alignment: .trailing).monospacedDigit()
            }

            if effect.usesSpeed {
                HStack(spacing: 8) {
                    Text("Speed").frame(width: 90, alignment: .leading)
                    Slider(value: $speed, in: 0...100, step: 1)
                        .accessibilityLabel("Effect speed")
                    Text("\(Int(speed))%")
                        .frame(width: 40, alignment: .trailing).monospacedDigit()
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live preview")
                    Text(liveStream ? "Changes are saved automatically." : "Use Apply lighting to save changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Live preview", isOn: $liveStream)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    if !onboard {
                        Picker("Lighting zone", selection: $target) {
                            ForEach(LEDTarget.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                    }
                    HStack(spacing: 8) {
                        Text("Colour intensity").frame(width: 100, alignment: .leading)
                        Slider(value: $opacity, in: 0...255, step: 1)
                            .accessibilityLabel("Colour intensity")
                        Text("\(Int((opacity / 255 * 100).rounded()))%")
                            .frame(width: 40, alignment: .trailing).monospacedDigit()
                    }
                    .help("Scale the RGB colour independently of device brightness.")
                    if effect == .staticColor, viewModel.activeProfile?.capabilities.contains(.hasteDirect) == true {
                        Toggle("Experimental direct colour", isOn: $includeHasteProbe)
                        Text("Uses a continuous colour stream. Leave off for normal static lighting; some firmware may pulse in this mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }
        }
        .font(.system(size: 12))
    }

    private var applyRow: some View {
        HStack {
            Button {
                streamTask?.cancel()
                Task { await viewModel.applyLighting(state: snapshotState()) }
            } label: {
                Label("Apply lighting", systemImage: "lightbulb")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.activeProfile == nil)

            Spacer()

            if let message = viewModel.lightingMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func snapshotState() -> DeviceLightingState {
        DeviceLightingState(
            target: target,
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
            Text("Presets").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
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
                        for index in indices.sorted(by: >) {
                            presetStore.remove(presetStore.presets[index])
                        }
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 100, maxHeight: 180)
            }

            HStack(spacing: 8) {
                TextField("New preset name", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let trimmed = presetName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let preset = LightingPreset(
                        name: trimmed,
                        target: target, effect: effect, color: color,
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
        let effect = onboard && preset.effect == .spectrumAlt ? LEDEffect.spectrum : preset.effect
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(swiftUIColor(preset.color))
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 0) {
                Text(preset.name).font(.system(size: 12, weight: .medium))
                Text("\(onboard ? effect.name : effect.title) · \(preset.color.hexString) · α=\(preset.opacity)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                loadEditor(preset.lightingState)
            } label: {
                Image(systemName: "arrow.up.right.circle")
            }
            .buttonStyle(.borderless)
            .help("Load preset into editor")

            Button {
                applyPreset(preset)
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
                loadEditor(preset.lightingState)
            }
            Button("Apply") { applyPreset(preset) }
            Divider()
            Button("Delete", role: .destructive) { presetStore.remove(preset) }
        }
    }

    private func hydrate() {
        loadEditor(viewModel.currentDeviceState.lighting)
    }

    private func applyPreset(_ preset: LightingPreset) {
        loadEditor(preset.lightingState)
        Task { await viewModel.applyPreset(preset) }
    }

    private func loadEditor(_ s: DeviceLightingState) {
        streamTask?.cancel()
        target = s.target
        effect = onboard && s.effect == .spectrumAlt ? .spectrum : s.effect
        color = s.color
        brightness = Double(s.brightness)
        opacity = Double(s.opacity)
        speed = Double(s.speed)
        includeHasteProbe = !onboard && s.includeHasteProbe
        hydratedState = snapshotState()
    }

    private func scheduleLiveUpdate() {
        let state = snapshotState()
        streamTask?.cancel()
        guard liveStream, state != hydratedState, let fingerprint = viewModel.activeProfile?.fingerprint else { return }
        streamTask = Task { [weak viewModel] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled,
                  viewModel?.activeProfile?.fingerprint == fingerprint else { return }
            hydratedState = state
            await viewModel?.applyLighting(state: state, persist: false)
        }
    }

    private func swiftUIColor(_ c: RGBColor) -> Color {
        Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }
}

// MARK: - DPI (capability-gated)

private struct DPISection: View {
    @ObservedObject var viewModel: DeviceViewModel

    @State private var levels: [DPILevel] = DeviceDPIState.default.levels
    @State private var activeProfile: Int = DeviceDPIState.default.activeProfile
    @State private var editingColourIndex: Int?
    private var onboard: Bool { viewModel.activeProfile?.fingerprint.isPulsefireHasteWireless == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose an active level. Enabled levels cycle with the mouse’s DPI button. Apply saves sensitivity and indicator colours.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            levelsList
            footer
            if let message = viewModel.dpiMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { hydrate() }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidChange)) { _ in
            hydrate()
        }
    }

    private var levelsList: some View {
        VStack(spacing: 4) {
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
            set: { levels[index].dpi = DeviceDPIState.clampDPI(Int($0.rounded()), forHasteWireless: onboard) }
        )
        let enabledBinding = Binding<Bool>(
            get: { levels[index].enabled },
            set: { enabled in
                guard enabled || levels.filter({ $0.enabled }).count > 1 else { return }
                levels[index].enabled = enabled
                if !enabled, activeProfile == level.index {
                    activeProfile = levels.first(where: { $0.enabled })?.index ?? activeProfile
                }
            }
        )

        return HStack(spacing: 10) {
            Button {
                let pickedColor = levels[index].color
                Task {
                    if await viewModel.selectDPIProfile(level.index, previewColor: pickedColor) {
                        activeProfile = level.index
                    }
                }
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(!level.enabled)
            .accessibilityLabel("Select DPI level \(level.index)")
            .accessibilityValue(isActive ? "Active" : "Inactive")
            .help(isActive ? "Active DPI level" : "Make active (applies + flashes colour)")

            Text("DPI \(level.index)")
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(level.enabled ? .primary : .secondary)

            Slider(value: dpiBinding, in: (onboard ? 200.0 : 50.0)...16_000, step: onboard ? 100 : 50)
                .disabled(!level.enabled)
                .accessibilityLabel("DPI level \(level.index) sensitivity")
                .accessibilityValue("\(level.dpi) DPI")
                .frame(maxWidth: .infinity)

            Text("\(level.dpi)")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(level.enabled ? .primary : .secondary)

            colorWell(for: index)
                .disabled(!level.enabled)

            Toggle("Enable DPI level \(level.index)", isOn: enabledBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(level.enabled && levels.filter(\.enabled).count == 1)
                .help("Enable / disable this level in the on-mouse DPI cycle")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }

    private func colorWell(for index: Int) -> some View {
        let c = levels[index].color
        return Button { editingColourIndex = index } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255))
                .frame(width: 22, height: 15)
        }
        .accessibilityLabel("DPI level \(levels[index].index) indicator colour")
        .accessibilityValue(c.hexString)
        .popover(isPresented: Binding(get: { editingColourIndex == index },
                                      set: { if !$0 { editingColourIndex = nil } })) {
            InteractiveColorPicker(color: $levels[index].color, presetStore: viewModel.presetStore)
                .padding().frame(width: 330)
        }
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
        }
    }

    private func hydrate() {
        let s = (viewModel.reportedDPI ?? viewModel.currentDeviceState.dpi).normalized(forHasteWireless: onboard)
        levels = s.levels
        activeProfile = s.activeProfile
    }

}

// MARK: - Collapsible section wrapper

/// Generic disclosure container used by every per-device feature pane.
/// Defaults to collapsed so a freshly-opened device shows just a list of
/// chevrons — the user picks what they want to edit instead of being
/// dumped into a wall of controls.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    @State private var isExpanded = false
    @State private var hasExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // Avoid animating the layout of native pickers and sliders.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    hasExpanded = true
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .foregroundStyle(DeviceTheme.accent)
                        .frame(width: 20)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            // Construct each editor on first use, then retain unsaved edits
            // while collapsed without animating its entire view hierarchy.
            if hasExpanded {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 14)
                    content().padding(14)
                }
                .frame(height: isExpanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(isExpanded ? 1 : 0)
                .disabled(!isExpanded)
                .accessibilityHidden(!isExpanded)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Buttons (capability-gated)

private struct ButtonsSection: View {
    @ObservedObject var viewModel: DeviceViewModel

    /// Local edit copy. Hydrated from per-device store on appear and
    /// device-switch; pushed back via `apply`.
    @State private var assignments: [PhysicalButton: ButtonAction] = [:]
    @State private var editedButtons: Set<PhysicalButton> = []
    @State private var applying = false

    private var supportsNavigationShortcuts: Bool {
        viewModel.activeProfile?.fingerprint.isPulsefireHasteWireless == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(supportsNavigationShortcuts
                 ? "A macOS shortcut replaces the selected side button’s onboard macro and works in every app."
                 : "Assign actions to the wheel, side buttons and DPI button. Primary clicks stay unchanged.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(PhysicalButton.remappable, id: \.rawValue) { button in
                buttonRow(button)
            }

            footer
        }
        .onAppear { hydrate() }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidChange)) { _ in
            hydrate()
        }
    }

    private func buttonRow(_ button: PhysicalButton) -> some View {
        let current = assignments[button] ?? ButtonAction.factoryDefault(for: button)
        return HStack(spacing: 10) {
            Image(systemName: button.iconName)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(button.title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)

            Menu {
                Picker("Action for \(button.title)", selection: bindingFor(button: button)) {
                    Section("Mouse") {
                        ForEach(ButtonAction.MouseFunctionCode.allCases) { code in
                            Text(code.title).tag(ButtonAction.mouseButton(code))
                        }
                    }
                    if button.isSideButton, supportsNavigationShortcuts {
                        Section("macOS shortcuts") {
                            ForEach(ButtonAction.NavigationShortcut.allCases, id: \.self) { shortcut in
                                Text(shortcut.title).tag(ButtonAction.macNavigation(shortcut))
                            }
                        }
                    }
                    Text("DPI cycle").tag(ButtonAction.dpiToggle)
                    Section("Media") {
                        ForEach(ButtonAction.MediaFunctionCode.allCases) { code in
                            Text(code.title).tag(ButtonAction.media(code))
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(current.title).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 220)
            .accessibilityLabel("Action for \(button.title)")
            .accessibilityValue(current.title)

            Spacer(minLength: 0)

            // Inline restore-default chevron — quick way to undo a mistake
            // without scrolling to the footer.
            if current != ButtonAction.factoryDefault(for: button) {
                Button {
                    setAction(.factoryDefault(for: button), for: button)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Restore factory default for this button")
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            if let message = viewModel.buttonsMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore defaults") {
                for button in PhysicalButton.remappable {
                    setAction(.factoryDefault(for: button), for: button)
                }
            }
            .buttonStyle(.bordered)

            Button {
                let payload = PhysicalButton.remappable.filter(editedButtons.contains).map { button in
                    ButtonAssignment(
                        button: button,
                        action: assignments[button] ?? ButtonAction.factoryDefault(for: button)
                    )
                }
                applying = true
                Task {
                    if await viewModel.applyButtonAssignments(payload) {
                        for entry in payload where assignments[entry.button] == entry.action {
                            editedButtons.remove(entry.button)
                        }
                    }
                    applying = false
                }
            } label: {
                Label("Apply", systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(editedButtons.isEmpty || applying)
        }
    }

    private func bindingFor(button: PhysicalButton) -> Binding<ButtonAction> {
        Binding<ButtonAction>(
            get: { assignments[button] ?? ButtonAction.factoryDefault(for: button) },
            set: { setAction($0, for: button) }
        )
    }

    private func setAction(_ action: ButtonAction, for button: PhysicalButton) {
        assignments[button] = action
        editedButtons.insert(button)
    }

    private func hydrate() {
        let s = viewModel.currentDeviceState.buttons
        var map: [PhysicalButton: ButtonAction] = [:]
        for button in PhysicalButton.remappable {
            map[button] = s.action(for: button)
        }
        assignments = map
        editedButtons.removeAll()
    }
}

// MARK: - Microphone detail

private struct MicrophoneDetail: View {
    let microphone: MicrophoneInfo
    @ObservedObject var viewModel: DeviceViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controlsSection
                propertiesSection
                castHardwareSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        DeviceHeading(title: DeviceTheme.shortName(microphone.displayName),
                      context: microphone.isDefaultInput ? "Microphone · Default input" : "Microphone settings") {
            Image(systemName: "mic").foregroundStyle(.white).accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio controls").font(.headline)

            // The toggle represents "microphone is live" — ON means the
            // mic is picking up sound, OFF means muted. This mirrors the
            // menu-bar tray toggle and inverts CoreAudio's `Mute` flag
            // on the way in/out of the binding.
            //
            // The label width is fixed so the switch doesn't shift
            // horizontally when the text flips between "Muted" (5 chars)
            // and "Live" (4 chars) — the wider state defines the slot.
            if let muted = microphone.isMuted {
                Toggle(isOn: Binding(
                    get: { !muted },
                    set: { isLive in
                        Task { await viewModel.setMicrophoneMute(!isLive, for: microphone) }
                    }
                )) {
                    Label(muted ? "Muted" : "Live",
                          systemImage: muted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(muted ? Color.red : Color.primary)
                        .frame(minWidth: 90, alignment: .leading)
                }
                .toggleStyle(.switch)
                .disabled(!microphone.canSetMute)
            } else {
                Label("Mute state not exposed by CoreAudio",
                      systemImage: "mic.badge.xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            // Volume slider. `volumePercent` is `nil` on mics that route
            // gain through hardware only — show a note instead of a
            // dead slider.
            if let volume = microphone.volumePercent {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.1.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Slider(value: Binding(
                        get: { Double(volume) },
                        set: { newValue in
                            Task {
                                await viewModel.setMicrophoneVolume(
                                    Int(newValue.rounded()), for: microphone
                                )
                            }
                        }
                    ), in: 0...100, step: 1)
                    .accessibilityLabel("Microphone input volume")
                    .accessibilityValue("\(volume)%")
                    .disabled(!microphone.canSetVolume)
                    Text("\(volume)%")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            } else {
                Label("Input volume is not exposed by CoreAudio",
                      systemImage: "dial.medium")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let message = viewModel.microphoneMessages[microphone.id] {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardware info").font(.headline)
            propertyRow(label: "UID", value: microphone.uid)
            if let rate = microphone.sampleRate {
                propertyRow(label: "Sample rate", value: "\(Int(rate)) Hz")
            }
            propertyRow(label: "Input streams", value: "\(microphone.inputStreamCount)")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    @ViewBuilder
    private var castHardwareSection: some View {
        if microphone.isQuadCast2S {
            QuadCast2SAdvancedControls(microphone: microphone, viewModel: viewModel)
        } else if microphone.isCastFamily && !microphone.isSoloCast {
            VStack(alignment: .leading, spacing: 6) {
                Label("Hardware controls unavailable for this model",
                      systemImage: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                Text("Audio controls are available above. This microphone's lighting controller uses a different protocol from the QuadCast 2 S and is not driven by MacGenuity yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        }
    }

    private func propertyRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private let config = DonationService.shared.config

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            Text("MacGenuity")
                .font(.title2.weight(.semibold))
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Open-source monitor for HyperX devices on macOS")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("View on GitHub", destination: URL(string: "https://github.com/loujessler/MacGenuity")!)
                Link("Release notes", destination: URL(string: "https://github.com/loujessler/MacGenuity/releases")!)
            }
            .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Text("Support development")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                // Skip rows for addresses that didn't load (e.g. when
                // donations.json is missing from the bundle). Empty
                // strings would render meaningless "...0" placeholders.
                if !config.usdt_polygon.isEmpty {
                    DonationRow(title: "USDT Polygon (PoS)",
                                value: config.usdt_polygon, scheme: "ethereum")
                }
                if !config.usdt_trc20.isEmpty {
                    DonationRow(title: "USDT TRON (TRC20)",
                                value: config.usdt_trc20, scheme: "tron")
                }
                if !config.btc.isEmpty {
                    DonationRow(title: "Bitcoin",
                                value: config.btc, scheme: "bitcoin")
                }
            }
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

    private func open() {
        if let scheme,
           let url = URL(string: "\(scheme):\(value)"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {

            NSWorkspace.shared.open(url)
            return
        }

        openExplorer()
    }

    private func openExplorer() {
        let urlString: String

        if value.starts(with: "bc1") {
            urlString = "https://www.blockchain.com/btc/address/\(value)"
        } else if value.starts(with: "T") {
            urlString = "https://tronscan.org/#/address/\(value)"
        } else if value.starts(with: "0x") {
            urlString = "https://polygonscan.com/address/\(value)"
        } else {
            return
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
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

            if scheme != nil {
                Button {
                    open()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .help("Open in wallet")
            }

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
