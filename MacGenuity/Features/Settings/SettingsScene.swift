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
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            DevicesPane(viewModel: viewModel, presetStore: presetStore)
                .tabItem { Label("Devices", systemImage: "externaldrive.connected.to.line.below") }

            ProfilesPane(viewModel: viewModel)
                .tabItem { Label("Profiles", systemImage: "puzzlepiece.extension") }

            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 720, height: 520)
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

// MARK: - Devices (sidebar + detail)

private struct DevicesPane: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var presetStore: PresetStore

    /// Locally-tracked sidebar selection. Stored as the `ConfigurableDevice.id`
    /// string so the value survives reorderings of `availableDevices` /
    /// `microphones` between refreshes.
    @State private var selection: String?

    var body: some View {
        let devices = unifiedDevices()

        NavigationSplitView {
            sidebar(devices: devices)
                .frame(minWidth: 220, idealWidth: 240)
        } detail: {
            detail(for: resolved(in: devices))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            ensureValidSelection(in: devices)
        }
        .onChange(of: viewModel.availableDevices) { _ in
            let updated = unifiedDevices()
            ensureValidSelection(in: updated)
        }
        .onChange(of: viewModel.microphones) { _ in
            let updated = unifiedDevices()
            ensureValidSelection(in: updated)
        }
    }

    // MARK: Sidebar

    private func sidebar(devices: [ConfigurableDevice]) -> some View {
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
                .help("Re-scan connected devices")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if devices.isEmpty {
                emptySidebarState
            } else {
                List(selection: $selection) {
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
                .onChange(of: selection) { newValue in
                    handleSelectionChange(to: newValue, in: devices)
                }
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
            Text("Plug a device in and press Refresh.")
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
            // Show capabilities of the resolved profile — that's what the
            // user actually gets to control. Fall back to VID/PID.
            if let active = viewModel.activeProfile,
               active.fingerprint.stableKey == fp.stableKey
            {
                return active.capabilities.labels.joined(separator: " · ")
            }
            return "\(Hex.u16(fp.vendorID))/\(Hex.u16(fp.productID))"
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
            case .microphone(let mic):
                MicrophoneDetail(microphone: mic, viewModel: viewModel)
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Pick a device on the left")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Each device exposes only the controls its profile supports — there's no separate Lighting or DPI tab.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
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

        return hids + mics
    }

    private func resolved(in devices: [ConfigurableDevice]) -> ConfigurableDevice? {
        guard let id = selection else { return devices.first }
        return devices.first(where: { $0.id == id }) ?? devices.first
    }

    private func ensureValidSelection(in devices: [ConfigurableDevice]) {
        if let id = selection, devices.contains(where: { $0.id == id }) { return }
        selection = devices.first?.id
        if let first = devices.first {
            handleSelectionChange(to: first.id, in: devices)
        }
    }

    /// When the user picks a HID device, push that choice down to the view
    /// model so subsequent control commands target it. Microphones don't
    /// have an "active device" concept — they're informational only.
    private func handleSelectionChange(to id: String?, in devices: [ConfigurableDevice]) {
        guard let id, let device = devices.first(where: { $0.id == id }) else { return }
        if case .hid(let fp) = device,
           viewModel.selectedDeviceKey != fp.stableKey
        {
            Task { await viewModel.setActiveDevice(fp) }
        }
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
                header
                Divider()

                if let active = viewModel.activeProfile,
                   active.fingerprint.stableKey == fingerprint.stableKey
                {
                    if active.capabilities.contains(.battery), let battery = viewModel.battery {
                        BatterySection(battery: battery)
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
                            ButtonsSection(viewModel: viewModel,
                                           fingerprint: fingerprint)
                        }
                    }
                    let supported: DeviceCapabilities = [.lighting, .dpiProfiles, .battery, .buttons]
                    if active.capabilities.intersection(supported).isEmpty {
                        noControlsNotice(profileName: active.displayName)
                    }
                } else {
                    profileResolutionNotice
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: deviceIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fingerprint.product.isEmpty ? "Unnamed HyperX" : fingerprint.product)
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(Hex.u16(fingerprint.vendorID)) / \(Hex.u16(fingerprint.productID))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if let active = viewModel.activeProfile,
               active.fingerprint.stableKey == fingerprint.stableKey
            {
                Text("Profile: \(active.displayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deviceIcon: String {
        let name = fingerprint.lowercaseProduct
        if name.contains("cast") { return "mic" }
        if name.contains("cloud") || name.contains("headset") { return "headphones" }
        return "computermouse"
    }

    private var profileResolutionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Profile not active for this interface",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            Text("This device is detected, but the selected HID interface isn't the one MacGenuity controls (e.g. it's a secondary mouse interface). Pick the device again from the sidebar — the next probe will resolve a profile.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private func noControlsNotice(profileName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No controls available", systemImage: "checkmark.seal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(profileName) is recognised but doesn't expose any controls MacGenuity can drive yet (lighting, DPI, etc.). The device shows up here so you can confirm detection — protocol support can be added by contributing a profile.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }
}

// MARK: - Battery section

private struct BatterySection: View {
    let battery: BatteryState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Battery").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: battery.isCharging ? "battery.100.bolt" : icon)
                    .foregroundStyle(battery.isCharging ? .green : .primary)
                Text("\(battery.percent)%")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                if battery.isCharging {
                    Text("charging").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var icon: String {
        switch battery.percent {
        case 75...:    return "battery.100"
        case 50..<75:  return "battery.75"
        case 25..<50:  return "battery.50"
        case 10..<25:  return "battery.25"
        default:       return "battery.0"
        }
    }
}

// MARK: - Lighting (capability-gated)

private struct LightingSection: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var presetStore: PresetStore

    @State private var effect: LEDEffect = .staticColor
    @State private var color: RGBColor = PresetColor.red.rgb
    @State private var brightness: Double = 100
    @State private var opacity: Double = 255
    @State private var speed: Double = 0
    @State private var includeHasteProbe: Bool = false
    /// Streaming colour to the device while sliders/picker move is the
    /// expected interaction model now — the editor doubles as a live
    /// preview, and the dedicated "Apply" button persists the final state.
    @State private var liveStream: Bool = true
    @State private var presetName: String = ""

    @State private var streamTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modePicker
            colorEditor
            slidersAndOptions
            applyRow
            presetsSection
        }
        .onAppear { hydrate() }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidChange)) { _ in
            hydrate()
        }
        .onChange(of: color) { newValue in scheduleLiveUpdate(newValue) }
        .onChange(of: opacity) { _ in scheduleLiveUpdate(color) }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Picker("Effect", selection: $effect) {
                    ForEach(LEDEffect.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 260)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Colour").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            InteractiveColorPicker(color: $color, presetStore: presetStore)
                .frame(maxWidth: 460)
        }
    }

    private var slidersAndOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        for index in indices { presetStore.remove(presetStore.presets[index]) }
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

    private func hydrate() {
        let s = viewModel.currentDeviceState.lighting
        effect = s.effect
        color = s.color
        brightness = Double(s.brightness)
        opacity = Double(s.opacity)
        speed = Double(s.speed)
        includeHasteProbe = s.includeHasteProbe
    }

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

// MARK: - DPI (capability-gated)

private struct DPISection: View {
    @ObservedObject var viewModel: DeviceViewModel

    @State private var levels: [DPILevel] = DeviceDPIState.default.levels
    @State private var activeProfile: Int = DeviceDPIState.default.activeProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap the radio button to choose which profile is active. Each level can be enabled, set 50–16 000 DPI, and given an indicator colour shown on the mouse when you cycle through with the on-mouse DPI button.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            levelsList
            footer
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
            set: { levels[index].dpi = stepDPI(Int($0.rounded())) }
        )
        let enabledBinding = Binding<Bool>(
            get: { levels[index].enabled },
            set: { levels[index].enabled = $0 }
        )

        return HStack(spacing: 10) {
            Button {
                activeProfile = level.index
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
        }
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
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        return RGBColor(
            red:   Int(round(ns.redComponent   * 255)),
            green: Int(round(ns.greenComponent * 255)),
            blue:  Int(round(ns.blueComponent  * 255))
        )
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

    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content()
                .padding(.top, 8)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }
}

// MARK: - Buttons (capability-gated)

private struct ButtonsSection: View {
    @ObservedObject var viewModel: DeviceViewModel
    let fingerprint: DeviceFingerprint

    /// Local edit copy. Hydrated from per-device store on appear and
    /// device-switch; pushed back via `apply`.
    @State private var assignments: [PhysicalButton: ButtonAction] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Re-bind side buttons, the wheel click and the on-mouse DPI button. Left and right click are intentionally not editable — losing them mid-session would lock you out of the editor.")
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

            Picker("", selection: bindingFor(button: button)) {
                Section("Mouse") {
                    ForEach(ButtonAction.MouseFunctionCode.allCases) { code in
                        Text(code.title).tag(ButtonAction.mouseButton(code))
                    }
                }
                Section("DPI") {
                    Text("DPI cycle").tag(ButtonAction.dpiToggle)
                }
                Section("Media") {
                    ForEach(ButtonAction.MediaFunctionCode.allCases) { code in
                        Text("Media: \(code.title)").tag(ButtonAction.media(code))
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220)

            Spacer(minLength: 0)

            // Inline restore-default chevron — quick way to undo a mistake
            // without scrolling to the footer.
            if current != ButtonAction.factoryDefault(for: button) {
                Button {
                    assignments[button] = ButtonAction.factoryDefault(for: button)
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
            if let message = viewModel.lastControlMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore defaults") {
                for button in PhysicalButton.allCases {
                    assignments[button] = ButtonAction.factoryDefault(for: button)
                }
            }
            .buttonStyle(.bordered)

            Button {
                let payload = PhysicalButton.allCases.map { button in
                    ButtonAssignment(
                        button: button,
                        action: assignments[button] ?? ButtonAction.factoryDefault(for: button)
                    )
                }
                Task { await viewModel.applyButtonAssignments(payload) }
            } label: {
                Label("Apply", systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func bindingFor(button: PhysicalButton) -> Binding<ButtonAction> {
        Binding<ButtonAction>(
            get: { assignments[button] ?? ButtonAction.factoryDefault(for: button) },
            set: { assignments[button] = $0 }
        )
    }

    private func hydrate() {
        let s = viewModel.currentDeviceState.buttons
        var map: [PhysicalButton: ButtonAction] = [:]
        for button in PhysicalButton.allCases {
            map[button] = s.action(for: button)
        }
        assignments = map
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
                Divider()
                controlsSection
                propertiesSection
                quadCastNotice
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(microphone.displayName)
                        .font(.system(size: 16, weight: .semibold))
                    if microphone.isDefaultInput {
                        Text("DEFAULT")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if !microphone.manufacturer.isEmpty {
                    Text(microphone.manufacturer)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
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
                    Text("\(volume)%")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            } else {
                Label("Volume controlled by hardware gain dial",
                      systemImage: "dial.medium")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let message = viewModel.lastControlMessage {
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
    private var quadCastNotice: some View {
        let name = microphone.displayName.lowercased()
        if name.contains("quadcast") || name.contains("duocast") {
            VStack(alignment: .leading, spacing: 6) {
                Label("RGB lighting & polar pattern — coming soon",
                      systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                Text("MacGenuity recognises the QuadCast / DuoCast family but doesn't drive its RGB lighting or polar pattern yet. The protocol is documented in the QuadcastRGB project and uses USB control transfers (HID feature reports) — adding it is a tracked enhancement.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.08)))
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
