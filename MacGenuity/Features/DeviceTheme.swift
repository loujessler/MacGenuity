import AppKit
import SwiftUI

enum DeviceTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 1.0, green: 0.38, blue: 0.40, alpha: 1)
        }
        return NSColor(srgbRed: 0.72, green: 0.055, blue: 0.14, alpha: 1)
    })
    static let caption = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 0.76 : 0.34, alpha: 1)
    })

    static let graphite = LinearGradient(
        colors: [Color(red: 0.13, green: 0.14, blue: 0.17), Color(red: 0.055, green: 0.058, blue: 0.082)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let trim = LinearGradient(stops: [
        .init(color: Color(red: 0.83, green: 0.06, blue: 0.15), location: 0),
        .init(color: Color(red: 0.94, green: 0.18, blue: 0.20), location: 0.25),
        .init(color: .white.opacity(0.85), location: 0.38),
        .init(color: .white.opacity(0.22), location: 0.55),
        .init(color: .white.opacity(0.08), location: 1)
    ], startPoint: .leading, endPoint: .trailing)

    static func shortName(_ name: String) -> String {
        let prefix = "HyperX "
        return name.lowercased().hasPrefix(prefix.lowercased()) ? String(name.dropFirst(prefix.count)) : name
    }
}

struct DeviceHeading<Trailing: View>: View {
    let title: String
    let context: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(context)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.78))
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(DeviceTheme.graphite)
        .overlay(alignment: .bottom) { Rectangle().fill(DeviceTheme.trim).frame(height: 2) }
    }
}
