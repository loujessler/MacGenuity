//
//  HIDDeviceFinder.swift
//  MacGenuity
//
//  Locates HyperX-compatible HID interfaces and produces lightweight
//  fingerprints. The actual HID open is deferred to HIDTransport,
//  which only happens once a profile has been resolved and access has
//  been granted.
//

import Foundation
import IOKit
import IOKit.hid

struct HIDDeviceCandidate {
    let device: IOHIDDevice
    let fingerprint: DeviceFingerprint

    var summary: String {
        "product='\(fingerprint.product)' vid=\(Hex.u16(fingerprint.vendorID)) pid=\(Hex.u16(fingerprint.productID)) usagePage=\(Hex.u16(fingerprint.usagePage)) usage=\(Hex.u16(fingerprint.usage)) reports(in/out/feature)=\(fingerprint.maxInput)/\(fingerprint.maxOutput)/\(fingerprint.maxFeature)"
    }
}

enum HIDDeviceFinder {
    static let hyperxVendorIDs: Set<Int> = [0x0951, 0x03F0]
    static let packetSize = 64

    /// Returns every HyperX-shaped HID interface, sorted by a heuristic
    /// score. The caller (typically `ProfileRegistry`) makes the final
    /// decision based on the active set of profiles.
    static func discoverCandidates(logger: LoggerType = FileLogger.shared) -> [HIDDeviceCandidate] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        let candidates = deviceSet.compactMap { dev -> HIDDeviceCandidate? in
            let fingerprint = DeviceFingerprint(
                vendorID:  propertyInt(dev, kIOHIDVendorIDKey),
                productID: propertyInt(dev, kIOHIDProductIDKey),
                product:   propertyString(dev, kIOHIDProductKey),
                usagePage: propertyInt(dev, kIOHIDPrimaryUsagePageKey),
                usage:     propertyInt(dev, kIOHIDPrimaryUsageKey),
                maxInput:  propertyInt(dev, kIOHIDMaxInputReportSizeKey),
                maxOutput: propertyInt(dev, kIOHIDMaxOutputReportSizeKey),
                maxFeature: propertyInt(dev, kIOHIDMaxFeatureReportSizeKey)
            )

            let lower = fingerprint.lowercaseProduct
            let plausible = hyperxVendorIDs.contains(fingerprint.vendorID)
                || lower.contains("hyperx")
                || lower.contains("pulsefire")
                || lower.contains("ngenuity")
                || lower.contains("cloud")     // headsets with USB control HID
                || lower.contains("alloy")     // keyboards
            guard plausible else { return nil }

            return HIDDeviceCandidate(device: dev, fingerprint: fingerprint)
        }

        for candidate in candidates {
            logger.debug(.hid, "candidate \(candidate.summary)")
        }
        return candidates
    }

    static func propertyInt(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
    }

    static func propertyString(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
    }
}
