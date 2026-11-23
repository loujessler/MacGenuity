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
        precondition(packets.last?.bytes.prefix(5) == Data([0xD3, 0, 0, 1, 1]),
                     "PF002 selects the second DPI level with wire index one")
        let fifth = profile.dpiPackets(profile: 5, dpi: 6400, dpiColor: PresetColor.white.rgb)
        precondition(fifth.first { $0.bytes[1] == 2 }?.bytes[2] == 4,
                     "The fifth DPI slot must not overwrite slot four")
        precondition(fifth[0].bytes.prefix(6) == Data([0xD3, 2, 4, 2, 64, 0]))
        try testHasteSideButtons(profile)
        let dpiCommit = profile.commitPacket(for: .dpi)
        precondition(dpiCommit?.bytes.prefix(2) == Data([0xDE, 3]))
        precondition(profile.commitPacket(for: .buttons)?.bytes.prefix(2) == Data([0xDE, 0xFF]))

        // NGENUITY captures from PF002: half-bright red fade and breathing at 50% speed.
        func wheel(_ effect: LEDEffect, _ brightness: Int, _ speed: Int) -> [Data] {
            let commands = profile.lightingPackets(target: .both, effect: effect,
                color: PresetColor.red.rgb, brightness: brightness, speed: speed)
            precondition(commands.allSatisfy { $0.bytes.count == 64 && $0.receive == .input && $0.send == .output })
            return commands.map(\.bytes)
        }
        let fade = wheel(.triggerFade, 50, 50)
        precondition(fade[0].prefix(12) == Data([0xD2, 0, 0x30, 8, 128, 0, 0, 0, 0, 0, 100, 31]))
        let breathing = wheel(.breathing, 100, 50)
        precondition(breathing.map { $0[0] } == [0xD2, 0xDA, 0xDA, 0xDA, 0xDA, 0xDA, 0xDA, 0xD9, 0xDB])
        precondition(breathing[1].prefix(13) == Data([0xDA, 65, 0, 60, 0, 0, 0, 12, 0, 0, 24, 0, 0]))
        precondition(breathing[7].prefix(7) == Data([0xD9, 0, 0, 3, 0x55, 65, 0x23]))
        precondition(wheel(.breathing, 100, 0)[7][5] == 120 && wheel(.breathing, 100, 100)[7][5] == 11)
        let spectrum = wheel(.spectrum, 100, 50)
        precondition(spectrum[1].prefix(10) == Data([0xDA, 100, 0, 60, 255, 0, 0, 255, 12, 0]))
        precondition(spectrum == wheel(.spectrumAlt, 100, 50))
        for effect in LEDEffect.allCases {
            precondition(wheel(effect, 0, 50)[1...6].allSatisfy { $0.dropFirst(4).allSatisfy { $0 == 0 } })
        }
        precondition(profile.commitPacket(for: .lighting)?.bytes.prefix(2) == Data([0xDE, 0xFF]))
        try testWheelReadback(wheel)

        var dpiReport = Data(count: 64)
        dpiReport.replaceSubrange(0..<6, with: [0x53, 0, 0, 0x21, 2, 7])
        dpiReport[12] = 4
        dpiReport[14] = 8
        dpiReport[16] = 24
        let readDPI = try PulsefireHasteProfile.parseDPI(dpiReport)
        precondition(readDPI.activeProfile == 3 && readDPI.levels[2].dpi == 2400)
        dpiReport[4] = 5
        precondition((try? PulsefireHasteProfile.parseDPI(dpiReport)) == nil)
        testInputReports()

        var emptyBattery = Data(repeating: 0, count: 64)
        emptyBattery[0] = 0x51
        emptyBattery[3] = 9
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
            product: "HyperX Pulsefire Haste Wireless", usagePage: 0xFF00, usage: 1,
            maxInput: 64, maxOutput: 64, maxFeature: 64, registryEntryID: 1)
        precondition(profile.match(haste) > DefaultHyperXProfile().match(haste),
                     "The specific Haste profile must win over the generic driver")
        let registry = ProfileRegistry.shared
        precondition(registry.supportsMouseControls(haste))
        precondition(!registry.supportsMouseControls(soloCast) && !registry.supportsMouseControls(unrelated))
        let secondInterface = DeviceFingerprint(vendorID: haste.vendorID, productID: haste.productID,
            product: haste.product, usagePage: 0xFF13, usage: 1,
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
        precondition(profile.match(keyboardInterface) == 0 && !registry.supportsMouseControls(keyboardInterface))
        precondition(haste.probeRequests(DefaultHyperXProfile().batteryRequests()).map(\.send) == [.output, .feature])
        let haste2 = DeviceFingerprint(vendorID: 0x03F0, productID: 0x0F98, product: "HyperX Pulsefire Haste 2 Wireless",
            usagePage: 0xFF00, usage: 1, maxInput: 64, maxOutput: 64, maxFeature: 0)
        let batteryProfile = registry.resolve(for: haste2)!
        precondition(batteryProfile.capabilities == [.battery] && registry.supportsMouseControls(haste2))
        let query = batteryProfile.batteryRequests()[0]
        precondition(query.reportID == 0x50 && query.responsePrefix == [0x51, 2] && query.bytes.prefix(2) == Data([0x50, 2]))
        let charged = try batteryProfile.parseBattery(Data([0x51, 2, 99, 1]))
        precondition(charged.percent == 99 && charged.isCharging)
        for invalid in [[0xFF, 0x51, 2, 9], [0x51, 3, 9, 0], [0x51, 2, 101, 0], [0x51, 2]] as [[UInt8]] {
            precondition((try? batteryProfile.parseBattery(Data(invalid))) == nil)
        }
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

    private static func testHasteSideButtons(_ profile: DeviceProfile) throws {
        let previous = Data(#"""
        {"assignments":[{"button":4,"action":{"macNavigation":{"_0":47}}},
                        {"button":3,"action":{"macNavigation":{"_0":48}}},
                        {"button":2,"action":{"media":{"_0":4}}}]}
        """#.utf8)
        let saved = try JSONDecoder().decode(DeviceButtonState.self, from: previous)
        precondition(saved.action(for: .sideBack) == .macNavigation(.back))
        precondition(saved.action(for: .sideForward) == .macNavigation(.forward))
        precondition(saved.action(for: .middle) == .media(.mute))
        for entry in saved.assignments where entry.button != .middle {
            precondition(profile.buttonAssignmentPackets(entry).isEmpty,
                         "A saved navigation macro must never be sent to the mouse")
            precondition(DefaultHyperXProfile().buttonAssignmentPackets(entry).isEmpty)
        }

        let cases: [(PhysicalButton, ButtonAction, UInt8, UInt8)] = [
            (.sideBack, .factoryDefault(for: .sideBack), 3, 4),
            (.sideForward, .factoryDefault(for: .sideForward), 4, 5),
            (.sideBack, .mouseButton(.forward), 3, 5),
            (.sideForward, .mouseButton(.back), 4, 4)
        ]
        for (button, action, slot, code) in cases {
            let packets = profile.buttonAssignmentPackets(.init(button: button, action: action))
            precondition(packets.count == 1)
            let packet = packets[0]
            precondition(packet.bytes == Data([0xD4, slot, 1, 2, code, 0]) + Data(count: 58))
            precondition(packet.send == .output && packet.receive == .input)
            precondition(packet.responsePrefix == [0xD4, slot, 1, 2, 0xEC, 0xAC])
        }
    }

    private static func testWheelReadback(_ wheel: (LEDEffect, Int, Int) -> [Data]) throws {
        func read(_ effect: LEDEffect, _ brightness: Int) throws -> WheelColour {
            let bank = wheel(effect, brightness, 50)
            return try PulsefireHasteProfile.readWheelColour { request in
                switch request.bytes[0] {
                case 0x52:
                    if effect == .triggerFade { return Data([0x52, 0, 0, 10, 3, 0, 31, 100, 128, 0, 0, 0, 0, 0]) }
                    return Data([0x52, 0, 0, 10, 4, 0, 0, 100, 255, 255, 255, 0, 0, 0])
                case 0x59:
                    return Data([0x59]) + bank[7].dropFirst()
                case 0x5A:
                    return Data([0x5A]) + bank[Int(request.bytes[2]) + 1].dropFirst()
                default: throw HIDError.unexpectedResponse
                }
            }
        }
        let solid = try read(.staticColor, 50)
        let fade = try read(.triggerFade, 50)
        let breathe = try read(.breathing, 100)
        let spectrum = try read(.spectrum, 50)
        let off = try read(.spectrum, 0)
        precondition(solid == .single(RGBColor(red: 128, green: 0, blue: 0)) && fade == solid)
        precondition(breathe == .single(PresetColor.red.rgb) && spectrum == .multicolour && off == .off)
        precondition((try? PulsefireHasteProfile.readWheelColour { _ in Data([0x52]) }) == nil)
    }

    private static func testInputReports() {
        let capture = InputReportCapture(capacity: 65)
        func report(_ bytes: [UInt8], id: UInt32 = 0) {
            bytes.withUnsafeBufferPointer { capture.handle($0.baseAddress!, length: $0.count, reportID: id) }
        }
        let ack: [UInt8] = [0xDA, 65, 2, 2, 0xEC, 0xAC]
        capture.beginWaiting(for: 0xDA, prefix: ack)
        report([0xDA, 65, 1, 2, 0xEC, 0xAC])
        precondition(capture.waitForMatch(until: Date()) == nil)
        report(ack)
        precondition(capture.waitForMatch(until: Date()) == Data(ack))
        capture.endWaiting()
        for bytes: [UInt8] in [[2, 41, 0], [0x51, 2, 41, 0]] {
            capture.beginWaiting(for: 0x50, prefix: [0x51, 2])
            report(bytes, id: 0x52)
            precondition(capture.waitForMatch(until: Date()) == nil)
            report(bytes, id: 0x51)
            precondition(capture.waitForMatch(until: Date()) == Data([0x51, 2, 41, 0]))
            capture.endWaiting()
        }
    }
}
