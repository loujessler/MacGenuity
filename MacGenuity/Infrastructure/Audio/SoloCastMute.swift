import Foundation
import IOKit
import IOKit.usb

/// The HP SoloCast can change its USB mute control without notifying CoreAudio.
/// Address the verified UAC1 feature unit on the same physical port as the HAL input.
enum SoloCastMute {
    // IOUSBLib's UUID macros are unavailable in Swift.
    private static let userClient = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
    private static let plugInType = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!
    private static let deviceType = CFUUIDCreateFromString(nil, "152FC496-4891-11D5-9D52-000A27801E86" as CFString)!

    static func locationID(for uid: String) -> UInt32? {
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "AppleUSBAudioEngine", parts[1] == "HP, Inc",
              parts[2] == "HyperX SoloCast", parts[4] == "1",
              let location = UInt32(parts[3], radix: 16), location != 0 else { return nil }
        return location
    }

    static func read(for uid: String) -> Bool? {
        transfer(nil, for: uid)
    }

    static func setMuted(_ muted: Bool, for uid: String) -> Bool {
        transfer(muted, for: uid) == muted
    }

    private static func transfer(_ muted: Bool?, for uid: String) -> Bool? {
        guard let location = locationID(for: uid),
              let match = IOServiceMatching("IOUSBHostDevice") else { return nil }
        let properties = ["idVendor": UInt32(0x03F0), "idProduct": 0x078B,
                          "bcdDevice": 0x4112, "locationID": location]
        let matching = match as NSMutableDictionary
        matching[kIOPropertyMatchKey] = properties
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, userClient, plugInType, &plugIn, &score) == kIOReturnSuccess,
              let plugIn, let factory = plugIn.pointee?.pointee else { return nil }
        defer { _ = factory.Release(plugIn) }
        var pointer: UnsafeMutableRawPointer?
        guard factory.QueryInterface(plugIn, CFUUIDGetUUIDBytes(deviceType), &pointer) == 0,
              let pointer else { return nil }
        let usb = pointer.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface182>?.self)
        guard let device = usb.pointee?.pointee else { return nil }
        defer { _ = device.Release(usb) }

        // Interface 0, feature unit 0x13, master channel, MUTE_CONTROL.
        // Endpoint zero accepts these class requests without opening or seizing the device.
        var value: UInt8 = muted == true ? 1 : 0
        var request = IOUSBDevRequestTO()
        request.bmRequestType = muted == nil ? 0xA1 : 0x21
        request.bRequest = muted == nil ? 0x81 : 0x01
        request.wValue = 0x0100
        request.wIndex = 0x1300
        request.wLength = 1
        request.noDataTimeout = 200
        request.completionTimeout = 200
        let result = withUnsafeMutablePointer(to: &value) {
            request.pData = UnsafeMutableRawPointer($0)
            return device.DeviceRequestTO(usb, &request)
        }
        guard result == kIOReturnSuccess, request.wLenDone == 1, value <= 1 else { return nil }
        return value != 0
    }
}
