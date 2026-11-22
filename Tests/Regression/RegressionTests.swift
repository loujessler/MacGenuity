import Foundation

@main
enum RegressionTests {
    @MainActor
    static func main() async throws {
        let profile: DeviceProfile = PulsefireHasteProfile()
        let levels = DeviceDPIState.default.levels
        let packets = profile.dpiBatchPackets(levels: levels, activeProfile: 2)
        precondition(packets.filter { $0.bytes[1] == 1 }.count == 1,
                     "A Haste batch must send exactly one enable bitmap")
        precondition(packets.first?.bytes[4] == 0x0F,
                     "Disabled DPI levels must remain disabled")
        precondition(packets.last?.bytes[4] == 2,
                     "The selected DPI level must be applied last")
        let fifth = profile.dpiPackets(profile: 5, dpi: 6400, dpiColor: PresetColor.white.rgb)
        precondition(fifth.first { $0.bytes[1] == 2 }?.bytes[2] == 4,
                     "The fifth DPI slot must not overwrite slot four")

        var emptyBattery = Data(repeating: 0, count: 64)
        emptyBattery[0] = 0x51
        let battery = try profile.parseBattery(emptyBattery)
        precondition(battery.percent == 0 && !battery.isCharging,
                     "An empty battery is a valid battery state")
        for length in 0..<6 {
            do {
                _ = try profile.parseBattery(Data(emptyBattery.prefix(length)))
                preconditionFailure("Truncated battery reports must fail")
            } catch is HIDError {}
        }

        let unrelated = DeviceFingerprint(vendorID: 0x03F0, productID: 1,
            product: "HP Keyboard", usagePage: 1, usage: 6,
            maxInput: 64, maxOutput: 64, maxFeature: 64)
        precondition(DefaultHyperXProfile().match(unrelated) == 0,
                     "An HP vendor ID alone must never authorize mouse commands")
        let soloCast = DeviceFingerprint(vendorID: 0x03F0, productID: 1,
            product: "HyperX SoloCast", usagePage: 0xFF00, usage: 1,
            maxInput: 64, maxOutput: 64, maxFeature: 64)
        precondition(DefaultHyperXProfile().match(soloCast) == 0)
        precondition(profile.match(soloCast) == 0)
        precondition(QuadCastProfile().match(soloCast) > 0)
        let haste = DeviceFingerprint(vendorID: 0x03F0, productID: 0x028E,
            product: "HyperX Pulsefire Haste Wireless", usagePage: 0xFF13, usage: 1,
            maxInput: 64, maxOutput: 64, maxFeature: 64, registryEntryID: 1)
        precondition(profile.match(haste) > DefaultHyperXProfile().match(haste),
                     "The specific Haste profile must win over the generic driver")
        let registry = ProfileRegistry.shared
        precondition(registry.supportsMouseControls(haste))
        precondition(!registry.supportsMouseControls(soloCast) && !registry.supportsMouseControls(unrelated))
        let secondInterface = DeviceFingerprint(vendorID: haste.vendorID, productID: haste.productID,
            product: haste.product, usagePage: 0xFF00, usage: 1,
            maxInput: 64, maxOutput: 64, maxFeature: 64)
        let keyboardInterface = DeviceFingerprint(vendorID: haste.vendorID, productID: haste.productID,
            product: haste.product, usagePage: 1, usage: 6, maxInput: 8, maxOutput: 0, maxFeature: 0)
        precondition(registry.preferredInterface(in: [haste, keyboardInterface]) == haste)
        let interfaces = [secondInterface, keyboardInterface, haste]
        precondition(registry.preferredInterface(in: interfaces) == registry.preferredInterface(in: interfaces.reversed()),
                     "Discovery order must not change the representative interface")
        var firstReceiver = haste
        firstReceiver.locationID = 100
        var secondReceiver = haste
        secondReceiver.locationID = 200
        secondReceiver.registryEntryID = 2
        var inputInterface = keyboardInterface
        inputInterface.locationID = firstReceiver.locationID
        let receivers = [inputInterface, secondReceiver, firstReceiver]
        precondition(registry.representativeDevices(in: receivers) == [firstReceiver, secondReceiver])
        precondition(!firstReceiver.matchesAttachment(secondReceiver))
        precondition(ConfigurableDevice.hid(unrelated).category == .other)
        precondition(ConfigurableDevice.hid(firstReceiver).id != ConfigurableDevice.hid(secondReceiver).id)
        let interruptOnly = DeviceFingerprint(vendorID: haste.vendorID, productID: haste.productID,
            product: haste.product, usagePage: 0xFF00, usage: 1, maxInput: 64, maxOutput: 64, maxFeature: 0)
        precondition(interruptOnly.probeRequests(profile.batteryRequests()).map(\.send) == [.output])
        precondition(haste.probeRequests(profile.batteryRequests()).map(\.send) == [.output, .feature])
        let disabled = levels.map { DPILevel(index: $0.index, dpi: $0.dpi,
                                             color: $0.color, enabled: false) }
        let safe = DeviceDPIState(levels: disabled, activeProfile: 5).normalized()
        precondition(safe.levels[4].enabled && safe.activeProfile == 5)
        let corrupt = DeviceDPIState(levels: [DPILevel(index: 2, dpi: Int.max,
            color: RGBColor(red: -1, green: 300, blue: 0), enabled: true)], activeProfile: 99).normalized()
        precondition(corrupt.levels.count == 5 && corrupt.levels[1].dpi == 16_000)
        precondition(corrupt.levels[1].color == RGBColor(red: 0, green: 255, blue: 0))
        precondition(Data.parseHex("+1") == nil)
        precondition(Data.parseHex("0xDE, AD BE EF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        precondition(Data.parseHex("deadBEEF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        for invalid in ["D0xE", "D E", "DE 0x", "0x+1"] {
            precondition(Data.parseHex(invalid) == nil)
        }
        precondition(RGBColor.parseHex("#aBc")?.hexString == "AABBCC")
        precondition(RGBColor.parseHex(" 12aBcD ")?.hexString == "12ABCD")
        for invalid in ["12GG34", "0x1234", "+12345", "#12", "１２３"] {
            precondition(RGBColor.parseHex(invalid) == nil, "Reject the entire invalid colour")
        }
        print("Mouse protocol and profile regression tests passed")
        try await ViewModelTests.run(fingerprint: haste, soloCast: soloCast, unrelated: unrelated)
    }
}
