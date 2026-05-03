//
//  Models.swift
//  MacGenuity
//
//  Pure value types describing devices and commands.
//  No IOKit / CoreAudio / SwiftUI dependencies — these models are
//  consumed by both Infrastructure (parsers) and Features (UI).
//

import Foundation

struct MouseInfo: Equatable {
    let name: String
    let firmware: String
    let vendorID: Int
    let productID: Int

    var displayName: String {
        name.isEmpty ? "HyperX mouse" : name
    }
}

struct BatteryState: Equatable {
    let percent: Int
    let isCharging: Bool
}

struct MicrophoneInfo: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let manufacturer: String
    let uid: String
    let sampleRate: Double?
    let inputStreamCount: Int
    let volumePercent: Int?
    let isMuted: Bool?
    let isDefaultInput: Bool

    var displayName: String {
        name.isEmpty ? "HyperX microphone" : name
    }

    var isSoloCast: Bool {
        displayName.lowercased().contains("solocast")
    }
}

struct RGBColor: Equatable, Codable, Hashable {
    let red: Int
    let green: Int
    let blue: Int

    func clamped() -> RGBColor {
        RGBColor(
            red: min(255, max(0, red)),
            green: min(255, max(0, green)),
            blue: min(255, max(0, blue))
        )
    }

    var hexString: String {
        String(format: "%02X%02X%02X",
               max(0, min(255, red)),
               max(0, min(255, green)),
               max(0, min(255, blue)))
    }

    static func parseHex(_ text: String) -> RGBColor? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6 || trimmed.count == 3 else { return nil }
        if trimmed.count == 3 {
            // expand "abc" → "aabbcc"
            trimmed = trimmed.map { "\($0)\($0)" }.joined()
        }
        let scanner = Scanner(string: trimmed)
        var packed: UInt64 = 0
        guard scanner.scanHexInt64(&packed) else { return nil }
        return RGBColor(
            red:   Int((packed >> 16) & 0xFF),
            green: Int((packed >> 8) & 0xFF),
            blue:  Int(packed & 0xFF)
        )
    }
}

enum PresetColor: String, CaseIterable, Identifiable {
    case red, blue, yellow, green, white, purple, cyan, orange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red:    return "Red"
        case .blue:   return "Blue"
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .white:  return "White"
        case .purple: return "Purple"
        case .cyan:   return "Cyan"
        case .orange: return "Orange"
        }
    }

    var rgb: RGBColor {
        switch self {
        case .red:    return RGBColor(red: 255, green: 0,   blue: 0)
        case .blue:   return RGBColor(red: 0,   green: 90,  blue: 255)
        case .yellow: return RGBColor(red: 255, green: 220, blue: 0)
        case .green:  return RGBColor(red: 0,   green: 220, blue: 70)
        case .white:  return RGBColor(red: 255, green: 255, blue: 255)
        case .purple: return RGBColor(red: 170, green: 70,  blue: 255)
        case .cyan:   return RGBColor(red: 0,   green: 220, blue: 255)
        case .orange: return RGBColor(red: 255, green: 120, blue: 0)
        }
    }
}

enum LEDTarget: Int, CaseIterable, Identifiable, Codable {
    case logo = 0x00
    case scrollWheel = 0x10
    case both = 0x20

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .logo:        return "Logo"
        case .scrollWheel: return "Wheel"
        case .both:        return "Both"
        }
    }
}

/// Raw `D2` effect byte. Values >0x00 came from prior reverse engineering
/// and are *not* confirmed against the wire capture — assume experimental
/// until proven on real hardware. UI marks them as such.
enum LEDEffect: Int, CaseIterable, Identifiable, Codable {
    /// Confirmed by NGENUITY pcap: `D2 00 00 08 RGB RGB 64 00`.
    case staticColor = 0x00
    case spectrumAlt = 0x10   // experimental
    case spectrum    = 0x12   // experimental
    case breathing   = 0x20   // experimental
    case triggerFade = 0x30   // experimental

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .staticColor: return "Static"
        case .spectrumAlt: return "Spectrum alt (experimental)"
        case .spectrum:    return "Spectrum (experimental)"
        case .breathing:   return "Breathing (experimental)"
        case .triggerFade: return "Trigger fade (experimental)"
        }
    }
    /// Whether this effect is confirmed against captured NGENUITY traffic.
    var isVerified: Bool { self == .staticColor }

    /// Speed has no effect for static colour — animations need it.
    var usesSpeed: Bool { self != .staticColor }
}

/// Higher-level mode used by the UI. Decouples user intent ("I want a steady
/// colour") from the raw protocol byte, and makes capability gating explicit.
enum LEDMode: String, CaseIterable, Identifiable, Codable {
    case off
    case `static`
    case experimental

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off:          return "Off"
        case .static:       return "Static"
        case .experimental: return "Experimental"
        }
    }
}

/// Authorization state for HID input monitoring.
enum HIDAccessState: Equatable {
    case granted
    case denied
    case unknown
}

/// Aggregated mouse-side state observed by the view model.
enum MouseStatus: Equatable {
    case unknown
    case connected
    case disconnected
    case permissionRequired
    case error(String)
}
