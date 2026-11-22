//
//  InteractiveColorPicker.swift
//  MacGenuity
//
//  Inline RGB picker with three coloured-track sliders, hex entry,
//  recent-colors strip, and a live preview swatch.
//

import SwiftUI

struct InteractiveColorPicker: View {
    @Binding var color: RGBColor
    @ObservedObject var presetStore: PresetStore

    @State private var hex: String = ""
    @State private var invalidHex = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview

            sliderRow("R", value: bindingFor(.red),   tint: .red)
            sliderRow("G", value: bindingFor(.green), tint: .green)
            sliderRow("B", value: bindingFor(.blue),  tint: .blue)

            HStack(spacing: 8) {
                Text("Hex")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .leading)
                Text("#")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("RRGGBB", text: $hex, onCommit: commitHex)
                    .accessibilityLabel("Hex colour")
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80)
                Spacer(minLength: 0)
            }
            .onChange(of: hex) { _ in invalidHex = false }
            .onChange(of: color) { newValue in
                hex = newValue.hexString
            }
            .onAppear { hex = color.hexString }
            if invalidHex {
                Text("Enter 3 or 6 hexadecimal digits.").font(.caption).foregroundStyle(.red)
            }

            if !presetStore.recentColors.isEmpty {
                recentStrip
            }
            presetStrip
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 4)
    }

    // MARK: -

    private var preview: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(swiftUIColor(color))
                .frame(height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                )
                .overlay(
                    Text("R\(color.red) G\(color.green) B\(color.blue)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(textColorOver(color))
                )
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 14, alignment: .leading)
            Slider(value: value, in: 0...255, step: 1)
                .tint(tint)
                .accessibilityLabel(label == "R" ? "Red" : label == "G" ? "Green" : "Blue")
                .accessibilityValue("\(Int(value.wrappedValue))")
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Recent")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            HStack(spacing: 4) {
                ForEach(presetStore.recentColors, id: \.self) { swatch in
                    Button {
                        color = swatch
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(swiftUIColor(swatch))
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(swatch == color ? Color.primary : Color.secondary.opacity(0.4),
                                            lineWidth: swatch == color ? 1.5 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(swatch.hexString)")
                    .help(swatch.hexString)
                }
            }
        }
    }

    private var presetStrip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Colours")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            HStack(spacing: 4) {
                ForEach(PresetColor.allCases) { preset in
                    Button {
                        color = preset.rgb
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(swiftUIColor(preset.rgb))
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(preset.rgb == color ? Color.primary : Color.secondary.opacity(0.4),
                                            lineWidth: preset.rgb == color ? 1.5 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.title)
                    .help(preset.title)
                }
            }
        }
    }

    // MARK: - Bindings / helpers

    private enum Channel { case red, green, blue }

    private func bindingFor(_ channel: Channel) -> Binding<Double> {
        Binding(
            get: {
                switch channel {
                case .red:   return Double(color.red)
                case .green: return Double(color.green)
                case .blue:  return Double(color.blue)
                }
            },
            set: { newValue in
                let v = Int(newValue.rounded())
                color = RGBColor(
                    red:   channel == .red   ? v : color.red,
                    green: channel == .green ? v : color.green,
                    blue:  channel == .blue  ? v : color.blue
                )
            }
        )
    }

    private func commitHex() {
        if let parsed = RGBColor.parseHex(hex) {
            color = parsed
            hex = parsed.hexString
            invalidHex = false
        } else {
            invalidHex = true
        }
    }

    private func swiftUIColor(_ c: RGBColor) -> Color {
        Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }

    /// Pick black or white text depending on the swatch luminance.
    private func textColorOver(_ c: RGBColor) -> Color {
        func linear(_ channel: Int) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        return luminance > 0.179 ? .black : .white
    }
}
