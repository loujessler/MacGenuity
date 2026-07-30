//
//  QuadCast2SAdvancedControls.swift
//  MacGenuity
//
//  Deep editor for the QuadCast 2 S's 12 × 9 cylindrical LampArray.
//

import AppKit
import SwiftUI

struct QuadCast2SAdvancedControls: View {
    let microphone: MicrophoneInfo
    @ObservedObject var viewModel: DeviceViewModel

    @State private var configuration = QuadCast2SEffectConfiguration.default
    @State private var paintColor = QuadCast2SEffectConfiguration.default.palette[0]
    @State private var previewEpoch = Date()
    @State private var selectedCustomFrame = 0
    @State private var previewFrameAnimation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            lightingSection
        }
        .onAppear { hydrate() }
        .onChange(of: microphone.uid) { _ in hydrate() }
    }

    private var lightingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            lightingHeader
            effectPicker
            lampPreview
            if configuration.kind != .spectrum {
                paletteEditor
            }
            effectControls
            if isCanvasEditor {
                customCanvasTools
            }
            actionBar
            statusMessages
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    private var lightingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Advanced LampArray", systemImage: "lightbulb.led")
                    .font(.headline)
                Spacer()
                if viewModel.quadCast2SState.isAnimating {
                    Label("STREAMING", systemImage: "wave.3.right.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                } else if let mode = viewModel.quadCast2SState.lightingMode {
                    Label(
                        mode.title,
                        systemImage: mode == .autonomous
                            ? "wand.and.stars"
                            : "paintpalette"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                capabilityBadge(
                    "\(viewModel.quadCast2SState.lampCount ?? 108) LEDs",
                    icon: "circle.grid.3x3.fill"
                )
                capabilityBadge("12 × 9 cylinder", icon: "cylinder")
                let fps = viewModel.quadCast2SState.maximumFramesPerSecond ?? 30.3
                capabilityBadge("\(Int(fps.rounded(.down))) FPS", icon: "speedometer")
            }

            Text("Every LED is individually addressable. Animated effects are rendered on the Mac and sent as atomic 108-lamp frames.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capabilityBadge(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.09)))
            .foregroundStyle(.secondary)
    }

    private var effectPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Effect").font(.system(size: 11, weight: .medium))
                Spacer()
                Picker("Effect", selection: $configuration.kind) {
                    ForEach(QuadCast2SEffectKind.allCases) { effect in
                        Label(effect.title, systemImage: effect.iconName).tag(effect)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .onChange(of: configuration.kind) { _ in
                    configuration = configuration.normalized()
                    paintColor = configuration.palette[0]
                    selectedCustomFrame = 0
                    previewFrameAnimation = false
                    previewEpoch = Date()
                }
            }
            Text(configuration.kind.detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var lampPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            QuadCast2SLampCanvas(
                configuration: previewConfiguration,
                epoch: previewEpoch,
                onPaint: isCanvasEditor && !previewFrameAnimation
                    ? { paint(lampID: $0) }
                    : nil
            )
            HStack {
                Text("12 columns unwrapped around the microphone")
                Spacer()
                if configuration.kind == .frameAnimator {
                    Text(
                        previewFrameAnimation
                            ? "Playing all frames"
                            : "Frame \(selectedCustomFrame + 1) · drag to paint"
                    )
                } else {
                    Text(configuration.kind == .custom ? "Drag to paint" : "Live preview")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    private var paletteEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(configuration.kind == .custom ? "Paint palette" : "Palette")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Menu {
                    ForEach(PalettePreset.all) { preset in
                        Button(preset.name) {
                            configuration.palette = preset.colors
                            paintColor = preset.colors[0]
                        }
                    }
                } label: {
                    Label("Presets", systemImage: "swatchpalette")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
            }

            HStack(spacing: 6) {
                ForEach(configuration.palette.indices, id: \.self) { index in
                    ColorPicker(
                        "Colour \(index + 1)",
                        selection: paletteBinding(at: index),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Palette colour \(index + 1)")
                }

                Button {
                    let next = configuration.palette.last ?? PresetColor.purple.rgb
                    configuration.palette.append(next)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(
                    configuration.palette.count
                        >= QuadCast2SEffectConfiguration.maximumPaletteColors
                )

                Button {
                    guard configuration.palette.count
                            > configuration.kind.minimumPaletteCount else { return }
                    configuration.palette.removeLast()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(
                    configuration.palette.count
                        <= configuration.kind.minimumPaletteCount
                )

                Spacer()
                Text("\(configuration.palette.count)/8")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var effectControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            valueSlider(
                icon: "sun.max.fill",
                label: "Brightness",
                value: Binding(
                    get: { Double(configuration.brightness) },
                    set: { configuration.brightness = Int($0.rounded()) }
                ),
                range: 0...100,
                step: 1,
                valueText: "\(configuration.brightness)%"
            )

            if configuration.kind.usesSpeedControl {
                valueSlider(
                    icon: "speedometer",
                    label: "Speed",
                    value: $configuration.speed,
                    range: 0.05...3,
                    step: 0.05,
                    valueText: String(format: "%.2f×", configuration.speed)
                )
            }

            if configuration.kind.usesAxis {
                HStack(spacing: 8) {
                    Image(systemName: "move.3d")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Path")
                        .font(.system(size: 10))
                        .frame(width: 62, alignment: .leading)
                    Picker("Path", selection: $configuration.axis) {
                        ForEach(QuadCast2SEffectAxis.allCases) { axis in
                            Label(axis.title, systemImage: axis.iconName).tag(axis)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            if configuration.kind.usesDirection {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Direction")
                        .font(.system(size: 10))
                        .frame(width: 62, alignment: .leading)
                    Picker("Direction", selection: $configuration.direction) {
                        Label("Forward", systemImage: "arrow.right")
                            .tag(QuadCast2SEffectDirection.forward)
                        Label("Reverse", systemImage: "arrow.left")
                            .tag(QuadCast2SEffectDirection.reverse)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            if configuration.kind.usesSpread {
                valueSlider(
                    icon: "arrow.left.and.right",
                    label: "Repeats",
                    value: $configuration.spread,
                    range: 0.25...6,
                    step: 0.25,
                    valueText: String(format: "%.2f×", configuration.spread)
                )
            }

            if configuration.kind.usesSoftness {
                valueSlider(
                    icon: "drop.halffull",
                    label: configuration.kind == .orbit ? "Trail" : "Softness",
                    value: $configuration.softness,
                    range: 0.05...1,
                    step: 0.05,
                    valueText: "\(Int((configuration.softness * 100).rounded()))%"
                )
            }
        }
    }

    private func valueSlider(
        icon: String,
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 10))
                .frame(width: 62, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(valueText)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var customCanvasTools: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            if configuration.kind == .frameAnimator {
                frameTimelineEditor
                Divider()
            }
            HStack(spacing: 8) {
                ColorPicker(
                    "Brush",
                    selection: Binding(
                        get: { color(from: paintColor) },
                        set: { paintColor = rgb(from: $0) }
                    ),
                    supportsOpacity: false
                )
                .font(.system(size: 10, weight: .medium))

                Spacer()
                Button("Fill") { fillCustom(with: paintColor) }
                    .buttonStyle(.borderless)
                Button("Palette bands") { fillCustomWithPalette() }
                    .buttonStyle(.borderless)
                Button("Spectrum") { fillCustomWithSpectrum() }
                    .buttonStyle(.borderless)
                Button("Off") { fillCustom(with: RGBColor(red: 0, green: 0, blue: 0)) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var frameTimelineEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("Frames")
                    .font(.system(size: 10, weight: .medium))
                Text("\(selectedCustomFrame + 1) / \(configuration.customFrames.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button { selectCustomFrame(selectedCustomFrame - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(selectedCustomFrame == 0)

                Button { selectCustomFrame(selectedCustomFrame + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(selectedCustomFrame >= configuration.customFrames.count - 1)

                Button { duplicateCustomFrame() } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate this frame")
                .disabled(
                    configuration.customFrames.count
                        >= QuadCast2SEffectConfiguration.maximumCustomFrames
                )

                Button(role: .destructive) { deleteCustomFrame() } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this frame")
                .disabled(configuration.customFrames.count <= 1)

                Spacer()

                Toggle(
                    isOn: Binding(
                        get: { previewFrameAnimation },
                        set: {
                            previewFrameAnimation = $0
                            previewEpoch = Date()
                        }
                    )
                ) {
                    Text("Preview")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .buttonStyle(.borderless)

            HStack(spacing: 8) {
                Image(systemName: "repeat")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Playback")
                    .font(.system(size: 10))
                    .frame(width: 62, alignment: .leading)
                Picker("Playback", selection: $configuration.framePlayback) {
                    ForEach(QuadCast2SFramePlayback.allCases) { playback in
                        Text(playback.title).tag(playback)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                Image(systemName: "square.2.layers.3d")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Transition")
                    .font(.system(size: 10))
                    .frame(width: 62, alignment: .leading)
                Picker("Transition", selection: $configuration.frameTransition) {
                    ForEach(QuadCast2SFrameTransition.allCases) { transition in
                        Text(transition.title).tag(transition)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            valueSlider(
                icon: "timer",
                label: "Frame time",
                value: $configuration.frameDuration,
                range: 0.05...5,
                step: 0.05,
                valueText: String(format: "%.2fs", configuration.frameDuration)
            )
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await viewModel.restoreQuadCast2SAutonomousLighting(
                        for: microphone
                    )
                }
            } label: {
                Label("Device animation", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)

            if viewModel.quadCast2SState.isAnimating {
                Button {
                    Task { await viewModel.stopQuadCast2SEffect() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button {
                configuration = configuration.normalized()
                Task {
                    await viewModel.applyQuadCast2SEffect(
                        configuration,
                        for: microphone
                    )
                }
            } label: {
                Label(
                    configuration.kind.isAnimated ? "Start effect" : "Apply frame",
                    systemImage: configuration.kind.isAnimated
                        ? "play.fill"
                        : "checkmark.seal"
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .disabled(!viewModel.quadCast2SState.hasLightingInterface)
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let message = viewModel.quadCast2SControlMessage {
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        if let error = viewModel.quadCast2SState.errorMessage {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hydrate() {
        let preference = viewModel.quadCast2SLightingPreference(for: microphone)
        configuration = preference.configuration.normalized()
        paintColor = configuration.palette[0]
        selectedCustomFrame = 0
        previewFrameAnimation = false
        previewEpoch = Date()
    }

    private var isCanvasEditor: Bool {
        configuration.kind == .custom || configuration.kind == .frameAnimator
    }

    private var previewConfiguration: QuadCast2SEffectConfiguration {
        guard configuration.kind == .frameAnimator, !previewFrameAnimation else {
            return configuration
        }
        var preview = configuration
        preview.kind = .custom
        preview.customColors = activeCanvasColors
        return preview
    }

    private var activeCanvasColors: [RGBColor] {
        if configuration.kind == .frameAnimator,
           configuration.customFrames.indices.contains(selectedCustomFrame)
        {
            return configuration.customFrames[selectedCustomFrame]
        }
        return configuration.customColors
    }

    private func paletteBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard configuration.palette.indices.contains(index) else {
                    return color(from: PresetColor.purple.rgb)
                }
                return color(from: configuration.palette[index])
            },
            set: { newColor in
                guard configuration.palette.indices.contains(index) else { return }
                configuration.palette[index] = rgb(from: newColor)
                if index == 0 { paintColor = configuration.palette[index] }
            }
        )
    }

    private func paint(lampID: Int) {
        guard activeCanvasColors.indices.contains(lampID) else { return }
        if configuration.kind == .frameAnimator,
           configuration.customFrames.indices.contains(selectedCustomFrame)
        {
            configuration.customFrames[selectedCustomFrame][lampID] = paintColor.clamped()
        } else {
            configuration.customColors[lampID] = paintColor.clamped()
        }
    }

    private func fillCustom(with color: RGBColor) {
        replaceActiveCanvas(with: Array(
            repeating: color.clamped(),
            count: QuadCast2SEffectConfiguration.customLampCount
        ))
    }

    private func fillCustomWithPalette() {
        let palette = configuration.normalized().palette
        replaceActiveCanvas(with: (0..<108).map { lampID in
            let column = lampID / 9
            return QuadCast2SEffectRenderer.sample(
                palette: palette,
                at: Double(column) / 12
            )
        })
    }

    private func fillCustomWithSpectrum() {
        replaceActiveCanvas(with: (0..<108).map { lampID in
            let column = lampID / 9
            let slot = lampID % 9
            return QuadCast2SEffectRenderer.hsv(
                hue: Double(column) / 12 + Double(slot) / 54,
                saturation: 1,
                value: 1
            )
        })
    }

    private func replaceActiveCanvas(with colors: [RGBColor]) {
        let safe = Array(
            colors.prefix(QuadCast2SEffectConfiguration.customLampCount)
        )
        guard safe.count == QuadCast2SEffectConfiguration.customLampCount else { return }
        if configuration.kind == .frameAnimator,
           configuration.customFrames.indices.contains(selectedCustomFrame)
        {
            configuration.customFrames[selectedCustomFrame] = safe
        } else {
            configuration.customColors = safe
        }
    }

    private func selectCustomFrame(_ index: Int) {
        guard configuration.customFrames.indices.contains(index) else { return }
        selectedCustomFrame = index
        previewFrameAnimation = false
    }

    private func duplicateCustomFrame() {
        configuration = configuration.normalized()
        guard configuration.customFrames.count
                < QuadCast2SEffectConfiguration.maximumCustomFrames else { return }
        let insertionIndex = min(
            selectedCustomFrame + 1,
            configuration.customFrames.count
        )
        configuration.customFrames.insert(activeCanvasColors, at: insertionIndex)
        selectedCustomFrame = insertionIndex
        previewFrameAnimation = false
    }

    private func deleteCustomFrame() {
        guard configuration.customFrames.count > 1,
              configuration.customFrames.indices.contains(selectedCustomFrame)
        else { return }
        configuration.customFrames.remove(at: selectedCustomFrame)
        selectedCustomFrame = min(
            selectedCustomFrame,
            configuration.customFrames.count - 1
        )
        previewFrameAnimation = false
    }

    private func color(from rgb: RGBColor) -> Color {
        let safe = rgb.clamped()
        return Color(
            .sRGB,
            red: Double(safe.red) / 255,
            green: Double(safe.green) / 255,
            blue: Double(safe.blue) / 255,
            opacity: 1
        )
    }

    private func rgb(from color: Color) -> RGBColor {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        return RGBColor(
            red: Int((converted.redComponent * 255).rounded()),
            green: Int((converted.greenComponent * 255).rounded()),
            blue: Int((converted.blueComponent * 255).rounded())
        ).clamped()
    }
}

private struct QuadCast2SLampCanvas: View {
    let configuration: QuadCast2SEffectConfiguration
    let epoch: Date
    let onPaint: ((Int) -> Void)?

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: configuration.kind.isAnimated ? 1 / 30 : 1,
                paused: false
            )
        ) { timeline in
            GeometryReader { geometry in
                Canvas { context, size in
                    draw(
                        context: &context,
                        size: size,
                        elapsed: timeline.date.timeIntervalSince(epoch)
                    )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            paint(at: gesture.location, size: geometry.size)
                        }
                )
            }
        }
        .frame(height: 118)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08))
        )
    }

    private func draw(
        context: inout GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval
    ) {
        let values = QuadCast2SEffectRenderer.render(
            configuration: configuration,
            lamps: QuadCast2SLampLayout.knownQuadCast2S,
            elapsedTime: elapsed
        )
        let gap = 2.0
        let cellWidth = (size.width - gap * 11) / 12
        let cellHeight = (size.height - gap * 8) / 9

        for column in 0..<12 {
            for row in 0..<9 {
                let lampID = QuadCast2SLampLayout.lampID(column: column, row: row)
                guard values.indices.contains(lampID) else { continue }
                let value = values[lampID]
                let rgb = value.color.clamped()
                let intensity = Double(value.intensity) / 255
                let color = Color(
                    .sRGB,
                    red: Double(rgb.red) / 255,
                    green: Double(rgb.green) / 255,
                    blue: Double(rgb.blue) / 255,
                    opacity: max(0.03, intensity)
                )
                let rect = CGRect(
                    x: Double(column) * (cellWidth + gap),
                    y: Double(row) * (cellHeight + gap),
                    width: cellWidth,
                    height: cellHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(color)
                )
            }
        }
    }

    private func paint(at location: CGPoint, size: CGSize) {
        guard let onPaint, size.width > 0, size.height > 0 else { return }
        let column = max(0, min(11, Int(location.x / (size.width / 12))))
        let row = max(0, min(8, Int(location.y / (size.height / 9))))
        onPaint(QuadCast2SLampLayout.lampID(column: column, row: row))
    }
}

private struct PalettePreset: Identifiable {
    let name: String
    let colors: [RGBColor]
    var id: String { name }

    static let all: [PalettePreset] = [
        PalettePreset(
            name: "HyperX",
            colors: [
                RGBColor(red: 255, green: 20, blue: 90),
                RGBColor(red: 150, green: 20, blue: 255),
                RGBColor(red: 20, green: 180, blue: 255)
            ]
        ),
        PalettePreset(
            name: "Vaporwave",
            colors: [
                RGBColor(red: 255, green: 50, blue: 210),
                RGBColor(red: 75, green: 30, blue: 255),
                RGBColor(red: 0, green: 240, blue: 255)
            ]
        ),
        PalettePreset(
            name: "Ocean",
            colors: [
                RGBColor(red: 0, green: 35, blue: 110),
                RGBColor(red: 0, green: 160, blue: 255),
                RGBColor(red: 0, green: 255, blue: 205)
            ]
        ),
        PalettePreset(
            name: "Aurora",
            colors: [
                RGBColor(red: 30, green: 255, blue: 120),
                RGBColor(red: 0, green: 160, blue: 255),
                RGBColor(red: 165, green: 30, blue: 255)
            ]
        ),
        PalettePreset(
            name: "Ember",
            colors: [
                RGBColor(red: 255, green: 20, blue: 0),
                RGBColor(red: 255, green: 120, blue: 0),
                RGBColor(red: 255, green: 235, blue: 80)
            ]
        ),
        PalettePreset(
            name: "Ice",
            colors: [
                RGBColor(red: 225, green: 250, blue: 255),
                RGBColor(red: 80, green: 210, blue: 255),
                RGBColor(red: 60, green: 80, blue: 255)
            ]
        )
    ]
}
