// The Haste 2 receiver uses numbered interrupt reports, independent of PF002.
// Reference: https://github.com/Tammo0987/hyperx-battery/blob/main/src/device.rs
import Foundation

final class PulsefireHaste2WirelessProfile: DeviceProfile {
    let identifier = "hyperx.pulsefire-haste2-wireless"
    let displayName = "HyperX Pulsefire Haste 2 Wireless"
    let author = "MacGenuity"
    let capabilities: DeviceCapabilities = [.battery]

    func match(_ fp: DeviceFingerprint) -> Double {
        guard fp.vendorID == 0x03F0, fp.productID == 0x0F98, fp.isVendorControlInterface,
              fp.maxInput >= 64, fp.maxOutput >= 64 else { return 0 }
        return 1
    }

    func batteryRequests() -> [ProfilePacket] {
        var bytes = PacketUtils.empty(command: 0x50)
        bytes[1] = 2
        return [ProfilePacket(bytes: bytes, send: .output, receive: .input, reportID: 0x50,
                              responsePrefix: [0x51, 2], label: "Haste 2 battery")]
    }

    func parseBattery(_ data: Data) throws -> BatteryState {
        guard data.count >= 4, data.starts(with: [0x51, 2]), data[2] <= 100 else {
            throw HIDError.unexpectedResponse
        }
        return BatteryState(percent: Int(data[2]), isCharging: data[3] == 1)
    }

    func infoRequests() -> [ProfilePacket] { [] }
    func parseInfo(_ data: Data) throws -> MouseInfo { throw HIDError.unsupportedOperation("Device info") }
    func lightingPackets(target: LEDTarget, effect: LEDEffect, color: RGBColor,
                         brightness: Int, speed: Int) -> [ProfilePacket] { [] }
    func dpiPackets(profile: Int, dpi: Int, dpiColor: RGBColor) -> [ProfilePacket] { [] }
}
