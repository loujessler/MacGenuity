//
//  ConfigurableDevice.swift
//  MacGenuity
//
//  Unified representation of any device that can appear in the Settings
//  sidebar — either a HID-discovered device (mouse, headset) or a
//  CoreAudio-discovered microphone. UI binds to this single type so the
//  list can mix sources without juggling two parallel collections.
//

import Foundation

enum ConfigurableDevice: Identifiable, Hashable {
    case hid(DeviceFingerprint)
    case microphone(MicrophoneInfo)

    var id: String {
        switch self {
        case .hid(let fp):       return "hid:" + fp.stableKey
        case .microphone(let m): return "mic:" + m.uid
        }
    }

    // The inner payloads (`DeviceFingerprint`, `MicrophoneInfo`) don't
    // conform to `Hashable` — `id` already uniquely identifies a device,
    // so route equality/hashing through it.
    static func == (lhs: ConfigurableDevice, rhs: ConfigurableDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displayName: String {
        switch self {
        case .hid(let fp):
            return fp.product.isEmpty ? "Unnamed HyperX" : fp.product
        case .microphone(let m):
            return m.displayName
        }
    }

    /// SF Symbol name used in the sidebar.
    var iconName: String {
        switch self {
        case .hid(let fp):
            // Audio-class devices sometimes show up on the HID bus too; pick
            // an icon based on the product name when we can.
            let name = fp.lowercaseProduct
            if name.contains("cast") || name.contains("mic") { return "mic" }
            if name.contains("cloud") || name.contains("headset") { return "headphones" }
            return "computermouse"
        case .microphone:
            return "mic"
        }
    }

    var category: Category {
        switch self {
        case .hid(let fp):
            let name = fp.lowercaseProduct
            if name.contains("cast") || name.contains("mic") { return .microphone }
            if name.contains("cloud") || name.contains("headset") { return .headset }
            return .mouse
        case .microphone:
            return .microphone
        }
    }

    enum Category: String, CaseIterable {
        case mouse, microphone, headset, other

        var title: String {
            switch self {
            case .mouse:      return "Mice"
            case .microphone: return "Microphones"
            case .headset:    return "Headsets"
            case .other:      return "Other"
            }
        }
    }
}
