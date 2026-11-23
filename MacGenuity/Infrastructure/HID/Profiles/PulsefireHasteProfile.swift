// HyperX Pulsefire Haste Wireless (PF002), USB receiver and cable.
// Packet captures: https://github.com/evan-razzaque/open-pulsefire-haste/tree/main/captures

import Foundation

final class PulsefireHasteProfile: DeviceProfile {
    let identifier = "hyperx.pulsefire-haste"
    let displayName = "HyperX Pulsefire Haste Wireless"
    let author = "MacGenuity"
    let capabilities: DeviceCapabilities = [.info, .battery, .lighting, .dpiProfiles, .buttons]

    private let common = DefaultHyperXProfile()

    func match(_ fp: DeviceFingerprint) -> Double {
        guard fp.isPulsefireHasteWireless, fp.usagePage == 0xFF00, fp.usage == 1,
              fp.maxOutput >= 64, fp.maxInput >= 64 else { return 0 }
        return 1
    }

    func infoRequests() -> [ProfilePacket] { [Self.read(0x50, label: "receiver info")] }
    func parseInfo(_ data: Data) throws -> MouseInfo { try common.parseInfo(data) }
    func batteryRequests() -> [ProfilePacket] { [Self.read(0x51, label: "mouse battery")] }
    func parseBattery(_ data: Data) throws -> BatteryState {
        guard data.count >= 13, data.starts(with: [0x51, 0, 0, 9]), data[4] <= 100, data[5] <= 2 else {
            throw HIDError.unexpectedResponse
        }
        return BatteryState(percent: Int(data[4]), isCharging: data[5] != 0)
    }

    static let linkRequest = read(0x46, label: "wireless link status")
    static let dpiRequest = read(0x53, label: "DPI levels")
    static let pairedMouseInfoRequest = read(0x50, selector: 5, label: "paired mouse firmware")

    static func parseDPI(_ data: Data) throws -> DeviceDPIState {
        guard data.count >= 37, data.starts(with: [0x53, 0, 0, 0x21]), data[4] < 5 else {
            throw HIDError.unexpectedResponse
        }
        let active = Int(data[4]) + 1
        var levels: [DPILevel] = []
        for i in 0..<5 {
            let offset = 12 + 2 * i
            let steps = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            let enabled = data[5] & (1 << i) != 0
            guard !enabled || (2...160).contains(steps) else { throw HIDError.unexpectedResponse }
            let rgb = 22 + 3 * i
            let colour = RGBColor(red: Int(data[rgb]), green: Int(data[rgb + 1]), blue: Int(data[rgb + 2]))
            levels.append(DPILevel(index: i + 1, dpi: steps * 100, color: colour, enabled: enabled))
        }
        guard levels[active - 1].enabled else { throw HIDError.unexpectedResponse }
        return DeviceDPIState(levels: levels, activeProfile: active)
    }

    static func readWheelColour(using request: (ProfilePacket) throws -> Data) throws -> WheelColour {
        let mode = try request(read(0x52, label: "wheel mode"))
        guard mode.count >= 14, mode.starts(with: [0x52, 0, 0, 10]) else { throw HIDError.unexpectedResponse }
        if mode[4] == 3 {
            return WheelColour(RGBColor(red: Int(mode[8]), green: Int(mode[9]), blue: Int(mode[10])))
        }

        let header = try request(read(0x59, label: "wheel frame count"))
        guard header.count >= 7, header.starts(with: [0x59, 0, 0, 3, 0x55]),
              (1...120).contains(header[5]) else { throw HIDError.unexpectedResponse }
        let count = Int(header[5])
        var frames: [RGBColor] = []
        for page in 0..<((count + 19) / 20) {
            var packet = PacketUtils.empty(command: 0x5A)
            let prefix: [UInt8] = [0x5A, UInt8(count), UInt8(page), 60]
            packet.replaceSubrange(0..<4, with: prefix)
            let data = try request(ProfilePacket(bytes: packet, send: .output, receive: .input,
                                                 responsePrefix: prefix, label: "read wheel frames"))
            guard data.count >= 64, data.starts(with: prefix) else { throw HIDError.unexpectedResponse }
            for i in 0..<min(20, count - frames.count) {
                let offset = 4 + 3 * i
                frames.append(RGBColor(red: Int(data[offset]), green: Int(data[offset + 1]), blue: Int(data[offset + 2])))
            }
        }
        // A breathing effect varies in intensity along one hue. Compare against
        // its brightest frame, allowing one RGB step of quantisation per frame.
        func peak(_ c: RGBColor) -> Int { max(c.red, c.green, c.blue) }
        guard let brightest = frames.max(by: { peak($0) < peak($1) }), peak(brightest) > 0 else { return .off }
        let reference = peak(brightest)
        for frame in frames {
            let scale = peak(frame)
            let error = max(abs(frame.red * reference - brightest.red * scale),
                            abs(frame.green * reference - brightest.green * scale),
                            abs(frame.blue * reference - brightest.blue * scale))
            if error > 2 * reference || (reference <= 2 && scale == reference && frame != brightest) {
                return .multicolour
            }
        }
        return .single(brightest)
    }

    static func isLinked(_ data: Data) throws -> Bool {
        guard data.count >= 5, data.starts(with: [0x46, 0, 0, 1]), data[4] <= 1 else {
            throw HIDError.unexpectedResponse
        }
        return data[4] == 1
    }

    private static func read(_ command: UInt8, selector: UInt8 = 0, label: String) -> ProfilePacket {
        var bytes = PacketUtils.empty(command: command)
        bytes[1] = selector
        return ProfilePacket(bytes: bytes, send: .output, receive: .input,
                             responsePrefix: [command, selector, 0], label: label)
    }

    // Each write is acknowledged by the mouse behind the receiver. A successful USB send
    // alone only means that the receiver accepted the report, including while the mouse sleeps.
    private static func write(_ prefix: [UInt8], _ label: String) -> ProfilePacket {
        var bytes = Data(count: PacketUtils.packetSize)
        bytes.replaceSubrange(0..<prefix.count, with: prefix)
        return ProfilePacket(bytes: bytes, send: .output, receive: .input,
                             responsePrefix: Array(bytes.prefix(3)) + [2, 0xEC, 0xAC], label: label)
    }

    func lightingPackets(target: LEDTarget, effect: LEDEffect, color: RGBColor,
                         brightness: Int, speed: Int) -> [ProfilePacket] {
        // PF002 has one illuminated wheel. D2 byte 1 must be zero for every stored target.
        let level = Double(min(100, max(0, brightness))) / 100
        let speed = min(100, max(0, speed))
        let base = color.clamped()
        func scaled(_ component: Int) -> UInt8 { UInt8((Double(component) * level).rounded()) }
        let rgb = [scaled(base.red), scaled(base.green), scaled(base.blue)]
        let frameCount: Int
        var setup: [UInt8] = [0xD2, 0, 0x40, 8, 255, 255, 255, 0, 0, 0, 100, 0]
        switch effect {
        case .staticColor: frameCount = 1
        case .triggerFade:
            frameCount = 1
            let delay = max(0, 63 - Int((Double(speed) * 0.64).rounded()))
            setup = [0xD2, 0, 0x30, 8] + rgb + [0, 0, 0, 100, UInt8(delay)]
        case .breathing: frameCount = (12000 - 109 * speed) / 100
        case .spectrum, .spectrumAlt: frameCount = 120 - (2 * speed + 4) / 5
        }

        let count = UInt8(frameCount)
        var packets = [Self.write(setup, "wheel effect setup")]
        // NGENUITY replaces the entire 120-frame bank, including the unused tail.
        let palette = [[255, 0, 0], [255, 255, 0], [0, 255, 0], [0, 0, 255], [255, 0, 255]]
        for chunk in 0..<6 {
            var bytes: [UInt8] = [0xDA, count, UInt8(chunk), 60]
            for offset in 0..<20 {
                let i = chunk * 20 + offset
                guard i < frameCount else { break }
                switch effect {
                case .staticColor: bytes += rgb
                case .triggerFade: bytes += [0, 0, 0]
                case .breathing:
                    let wave = sin(.pi * Double(i) / Double(frameCount - 1))
                    bytes += rgb.map { UInt8(Double($0) * wave) }
                case .spectrum, .spectrumAlt:
                    let position = Double(i * palette.count) / Double(frameCount - 1)
                    let segment = Int(position)
                    let fraction = position - Double(segment)
                    let start = palette[segment % palette.count]
                    let end = palette[(segment + 1) % palette.count]
                    for channel in 0..<3 {
                        let mixed = Double(start[channel]) + Double(end[channel] - start[channel]) * fraction
                        bytes.append(scaled(Int(mixed)))
                    }
                }
            }
            packets.append(Self.write(bytes, "wheel frames \(chunk)"))
        }
        packets.append(Self.write([0xD9, 0, 0, 3, 0x55, count, 0x23], "wheel frame count"))
        packets.append(Self.write([0xDB, 0x55], "activate wheel effect"))
        return packets
    }

    func selectDPIPacket(_ profile: Int) -> ProfilePacket {
        Self.write([0xD3, 0, 0, 1, UInt8(max(1, min(5, profile)) - 1)], "select DPI level")
    }

    private func levelPackets(_ profile: Int, dpi: Int, color: RGBColor) -> [ProfilePacket] {
        let index = UInt8(max(1, min(5, profile)) - 1)
        let step = UInt8(DeviceDPIState.clampDPI(dpi, forHasteWireless: true) / 100)
        let c = color.clamped()
        return [Self.write([0xD3, 2, index, 2, step, 0], "DPI value"),
                Self.write([0xD3, 3, index, 3, UInt8(c.red), UInt8(c.green), UInt8(c.blue)], "DPI colour")]
    }

    func dpiPackets(profile: Int, dpi: Int, dpiColor: RGBColor) -> [ProfilePacket] {
        levelPackets(profile, dpi: dpi, color: dpiColor) + [selectDPIPacket(profile)]
    }

    func dpiBatchPackets(levels: [DPILevel], activeProfile: Int) -> [ProfilePacket] {
        let state = DeviceDPIState(levels: levels, activeProfile: activeProfile).normalized(forHasteWireless: true)
        let enabled = state.levels.filter(\.enabled)
        let mask = enabled.reduce(UInt8(0)) { $0 | (1 << ($1.index - 1)) }
        var packets = [Self.write([0xD3, 1, 0, 1, mask], "enabled DPI levels")]
        for level in enabled { packets += levelPackets(level.index, dpi: level.dpi, color: level.color) }
        return packets + [selectDPIPacket(state.activeProfile)]
    }

    func buttonAssignmentPackets(_ assignment: ButtonAssignment) -> [ProfilePacket] {
        // Keep the persisted logical button names. PF002 numbers Back before Forward.
        let slot: UInt8
        switch assignment.button {
        case .sideBack: slot = 3
        case .sideForward: slot = 4
        default: slot = UInt8(assignment.button.rawValue)
        }
        if case .macNavigation(let shortcut) = assignment.action {
            guard assignment.button.isSideButton else { return [] }
            // Each D6 keyboard event is a complete HID state with a little-endian delay.
            // Press Command before the bracket and release it after the bracket is up.
            func keyboard(_ modifiers: UInt8, _ key: UInt8, delay: UInt8) -> [UInt8] {
                [0x1A, modifiers, key, 0, 0, 0, 0, 0, delay, 0]
            }
            let events = keyboard(0x08, 0, delay: 20) + keyboard(0x08, shortcut.rawValue, delay: 20)
                + keyboard(0x08, 0, delay: 20) + keyboard(0, 0, delay: 0)
            return [Self.write([0xD4, slot, 4, 2, slot, 0], "assign onboard macro"),
                    Self.write([0xD6, slot, 0, 4] + events, "navigation keystrokes"),
                    Self.write([0xD5, slot, 0, 5, 4, 0, 0, 0, 0], "play macro once")]
        }

        guard var binding = assignment.action.simpleBinding else { return [] }
        switch assignment.action {
        case .mouseButton(.back): binding.code = 4
        case .mouseButton(.forward): binding.code = 5
        default: break
        }
        return [Self.write([0xD4, slot, binding.type, 2, binding.code, 0], "button assignment")]
    }

    func commitPacket(for setting: MouseSetting) -> ProfilePacket? {
        Self.write([0xDE, setting == .dpi ? 0x03 : 0xFF], "save mouse settings")
    }
}
