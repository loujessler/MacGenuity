//
//  DefaultHyperXProfile.swift
//  MacGenuity
//
//  Generic NGenuity2-style profile that works with most HyperX wireless
//  mice (Pulsefire family). Used as the fallback when no more specific
//  profile claims a device.
//

import Foundation

final class DefaultHyperXProfile: DeviceProfile {
    let identifier = "hyperx.default"
    let displayName = "Generic HyperX (NGenuity2)"
    let author = "MacGenuity"

    let capabilities: DeviceCapabilities = [.info, .battery, .lighting, .dpiProfiles, .hasteDirect, .buttons]

    func match(_ fp: DeviceFingerprint) -> Double {
        let known: Set<Int> = [0x0951, 0x03F0]
        let lower = fp.lowercaseProduct

        // Hard opt-out for non-mouse families. The HyperX VIDs are shared
        // across mice, headsets and microphones; a SoloCast on VID 0x03F0
        // would otherwise score 0.6 here, get picked as the "best" HID
        // candidate, and then explode trying to speak the Pulsefire mouse
        // protocol to a mic — surfaced as a misleading "device not found"
        // error with no obvious recovery.
        let nonMouseKeywords = ["cast", "cloud", "headset", "alloy"]
        if nonMouseKeywords.contains(where: { lower.contains($0) }) {
            return 0
        }

        var score = 0.0
        if known.contains(fp.vendorID) { score += 0.6 }
        if lower.contains("hyperx")    { score += 0.15 }
        if lower.contains("pulsefire") { score += 0.15 }

        // Prefer the vendor-specific HID interface (control surface).
        if fp.usagePage == 0xFF13 || fp.usagePage == 0xFF00 { score += 0.1 }
        if fp.maxFeature >= PacketUtils.packetSize { score += 0.05 }
        if fp.maxOutput  >= PacketUtils.packetSize { score += 0.05 }

        return min(score, 0.95)
    }

    // MARK: - Info / battery

    func infoRequests() -> [ProfilePacket] {
        let packet = PacketUtils.empty(command: 0x50)
        return [
            ProfilePacket(bytes: packet, send: .output, receive: .input, label: "info via output→input"),
            ProfilePacket(bytes: packet, send: .feature, receive: .feature,
                          retryWithReportID: true, label: "info via feature")
        ]
    }

    func parseInfo(_ data: Data) throws -> MouseInfo {
        let off = try PacketUtils.validate(data, command: 0x50, minPayloadLength: 0x21)
        let base = data.startIndex
        let pid = Int(data[base + off + 4]) | (Int(data[base + off + 5]) << 8)
        let vid = Int(data[base + off + 6]) | (Int(data[base + off + 7]) << 8)
        guard pid != 0 || vid != 0 else {
            throw HIDError.malformedReport(reason: "info report has zero VID/PID")
        }
        let fw = "\(data[base + off + 0x0B]).\(data[base + off + 0x0A]).\(data[base + off + 9]).\(data[base + off + 8])"

        let scanStart = base + off
        let scanEnd = min(data.endIndex, scanStart + 64)
        let scanRegion = data[scanStart..<scanEnd]
        let nameStart = scanRegion.firstRange(of: Data("HyperX".utf8))?.lowerBound ?? (base + off + 0x0C)
        let nameEnd = min(data.endIndex, nameStart + 40)
        let nameRegion = data[nameStart..<nameEnd]
        let printable = nameRegion.map { byte -> Character in
            (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : " "
        }
        let name = String(printable)
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return MouseInfo(name: name, firmware: fw, vendorID: vid, productID: pid)
    }

    func batteryRequests() -> [ProfilePacket] {
        let packet = PacketUtils.empty(command: 0x51)
        return [
            ProfilePacket(bytes: packet, send: .output, receive: .input, label: "battery via output→input"),
            ProfilePacket(bytes: packet, send: .feature, receive: .feature,
                          retryWithReportID: true, label: "battery via feature")
        ]
    }

    func parseBattery(_ data: Data) throws -> BatteryState {
        let off = try PacketUtils.validate(data, command: 0x51, minPayloadLength: 6)
        let base = data.startIndex
        let percent = Int(data[base + off + 4])
        guard (0...100).contains(percent) else {
            throw HIDError.malformedReport(reason: "battery percent out of range (\(percent))")
        }
        return BatteryState(percent: percent, isCharging: data[base + off + 5] != 0)
    }

    // MARK: - Lighting

    func lightingPackets(target: LEDTarget,
                         effect: LEDEffect,
                         color: RGBColor,
                         brightness: Int,
                         speed: Int) -> [ProfilePacket]
    {
        let safeColor = color.clamped()
        let safeBrightness = UInt8(min(100, max(0, brightness)))
        let safeSpeed = UInt8(min(100, max(0, speed)))

        var packet = Data(count: PacketUtils.packetSize)
        packet[0] = 0xD2
        packet[1] = UInt8(target.rawValue)
        packet[2] = UInt8(effect.rawValue)
        packet[3] = 0x08
        packet[4] = UInt8(safeColor.red)
        packet[5] = UInt8(safeColor.green)
        packet[6] = UInt8(safeColor.blue)
        packet[7] = UInt8(safeColor.red)
        packet[8] = UInt8(safeColor.green)
        packet[9] = UInt8(safeColor.blue)
        packet[10] = safeBrightness
        packet[11] = safeSpeed
        return [ProfilePacket(bytes: packet, label: "setLED")]
    }

    func dpiPackets(profile: Int, dpi: Int, dpiColor: RGBColor) -> [ProfilePacket] {
        // NGENUITY uses an inconsistent profile encoding observed in the
        // wire capture:
        //   • `D3 02 P 02 ...` (DPI value) and `D3 03 P 03 ...` (indicator
        //     color) take a 0-based profile in byte 2 (P = 0…4).
        //   • `D3 00 00 01 N` (active-profile select) takes a **1-based**
        //     profile in the payload byte (N = 1…5).
        //   • `D3 01 00 01 BITS` (enable bitmap) — bit `1 << (5 - profile)`
        //     for the 1-based profile index. NGENUITY enables 5 profiles
        //     (`0x1F`); we expose 4 in the UI but enable all five so a
        //     `selectDPIProfile(5)` call from a future device that has a
        //     fifth profile slot still works.
        let zeroBased = UInt8(min(4, max(1, profile)) - 1)   // 0…3
        let oneBased  = UInt8(min(5, max(1, profile)))       // 1…5
        let safeDPI = min(16_000, max(50, (dpi / 50) * 50))
        let step = safeDPI / 50
        let safeColor = dpiColor.clamped()

        // 1) enable profiles 1–5 (bit `(profile - 1)` per profile)
        var enabledBits = 0
        for p in 1...5 { enabledBits |= 1 << (p - 1) }
        var enabled = Data(count: PacketUtils.packetSize)
        enabled[0] = 0xD3; enabled[1] = 0x01; enabled[3] = 0x01; enabled[4] = UInt8(enabledBits)

        // 2) DPI value (profile 0-based)
        var dpiValue = Data(count: PacketUtils.packetSize)
        dpiValue[0] = 0xD3; dpiValue[1] = 0x02; dpiValue[2] = zeroBased; dpiValue[3] = 0x02
        dpiValue[4] = UInt8(step & 0xFF); dpiValue[5] = UInt8((step >> 8) & 0xFF)

        // 3) profile-change indicator color (profile 0-based)
        var changeColor = Data(count: PacketUtils.packetSize)
        changeColor[0] = 0xD3; changeColor[1] = 0x03; changeColor[2] = zeroBased; changeColor[3] = 0x03
        changeColor[4] = UInt8(safeColor.red); changeColor[5] = UInt8(safeColor.green); changeColor[6] = UInt8(safeColor.blue)

        // 4) select active profile (profile 1-based — see comment above)
        var select = Data(count: PacketUtils.packetSize)
        select[0] = 0xD3; select[3] = 0x01; select[4] = oneBased

        return [
            ProfilePacket(bytes: enabled,     label: "enableDPIProfiles bits=0x\(String(format: "%02X", enabledBits))"),
            ProfilePacket(bytes: dpiValue,    label: "setDPIValue p=\(profile) dpi=\(safeDPI)"),
            ProfilePacket(bytes: changeColor, label: "setDPIChangeColor p=\(profile)"),
            ProfilePacket(bytes: select,      label: "selectDPIProfile p=\(profile)")
        ]
    }

    // MARK: - Haste direct

    func hasteSetupPacket() -> ProfilePacket? {
        var packet = Data(count: PacketUtils.packetSize)
        packet[0] = 0x04
        packet[1] = 0xF2
        packet[7] = 0x02
        return ProfilePacket(bytes: packet, send: .output, receive: .none, label: "hasteDirectSetup")
    }

    func hasteDirectFrame(_ color: RGBColor) -> ProfilePacket? {
        let safe = color.clamped()
        var packet = Data(count: PacketUtils.packetSize)
        packet[0] = 0x81
        packet[1] = UInt8(safe.red)
        packet[2] = UInt8(safe.green)
        packet[3] = UInt8(safe.blue)
        packet[7] = 0x02
        return ProfilePacket(bytes: packet, send: .output, receive: .none, label: "hasteDirectColor")
    }

    /// Full DPI batch matching NGENUITY's wire-captured order:
    ///   1. `D3 01 00 01 BITS` — enable bitmap (which profiles cycle)
    ///   2. `D3 02 P 02 LO HI` — DPI value for each enabled level (P 0-based)
    ///   3. `D3 03 P 03 R G B` — indicator colour for each enabled level
    ///   4. `D3 00 00 01 N`     — select active (N 1-based)
    /// Caller wraps with `commitPacket()` (`DE 03 00`).
    func dpiBatchPackets(levels: [DPILevel], activeProfile: Int) -> [ProfilePacket] {
        // Enable bitmap: bit `(profile - 1)` set means that profile is
        // included in the on-mouse cycle. NGENUITY's pcap only ever
        // showed `0x1F` (all five enabled), so the per-bit mapping had
        // to be inferred — verified empirically: disabling profile 5
        // produced `0x0F`, profile 1 → bit 0, profile 5 → bit 4.
        var bits = 0
        for level in levels where level.enabled {
            let oneBased = max(1, min(5, level.index))
            bits |= 1 << (oneBased - 1)
        }
        var enabled = Data(count: PacketUtils.packetSize)
        enabled[0] = 0xD3; enabled[1] = 0x01; enabled[3] = 0x01; enabled[4] = UInt8(bits)

        var packets: [ProfilePacket] = [
            ProfilePacket(bytes: enabled, label: "enableDPIProfiles bits=0x\(String(format: "%02X", bits))")
        ]

        // Per-level value + colour, ordered by 1-based index (matches NGENUITY).
        for level in levels.sorted(by: { $0.index < $1.index }) where level.enabled {
            let zeroBased = UInt8(max(0, min(4, level.index - 1)))
            let safeDPI = min(16_000, max(50, (level.dpi / 50) * 50))
            let step = safeDPI / 50
            let safeColor = level.color.clamped()

            var value = Data(count: PacketUtils.packetSize)
            value[0] = 0xD3; value[1] = 0x02; value[2] = zeroBased; value[3] = 0x02
            value[4] = UInt8(step & 0xFF); value[5] = UInt8((step >> 8) & 0xFF)
            packets.append(ProfilePacket(bytes: value,
                label: "setDPIValue p=\(level.index) dpi=\(safeDPI)"))

            var color = Data(count: PacketUtils.packetSize)
            color[0] = 0xD3; color[1] = 0x03; color[2] = zeroBased; color[3] = 0x03
            color[4] = UInt8(safeColor.red); color[5] = UInt8(safeColor.green); color[6] = UInt8(safeColor.blue)
            packets.append(ProfilePacket(bytes: color,
                label: "setDPIChangeColor p=\(level.index)"))
        }

        // Select active (1-based per pcap).
        let oneBased = UInt8(max(1, min(5, activeProfile)))
        var select = Data(count: PacketUtils.packetSize)
        select[0] = 0xD3; select[3] = 0x01; select[4] = oneBased
        packets.append(ProfilePacket(bytes: select, label: "selectDPIProfile p=\(activeProfile)"))

        return packets
    }

    // MARK: - Button assignments (0xD4 — NGenuity2 protocol)

    /// `D4 PB AT 02 CODE 04` — see santeri3700/hyperx_pulsefire_dart_reverse_engineering
    /// /protocol/index.md#set-button-assignment.
    ///
    ///   • byte 1 = physical button (0x00…0x05)
    ///   • byte 2 = assignment type (0x01 mouse, 0x03 media, 0x07 DPI switch)
    ///   • byte 3 = `0x02` — "2 bytes follow"
    ///   • byte 4 = function code
    ///   • byte 5 = `0x04` for everything except macros (0x00). We don't
    ///     emit macros from here, so this is hardcoded.
    ///
    /// The packet must be followed by `commitPacket()` (`DE 03 00`) for
    /// the device to apply it on the next event — same as DPI batches.
    func buttonAssignmentPackets(_ assignment: ButtonAssignment) -> [ProfilePacket] {
        var packet = Data(count: PacketUtils.packetSize)
        packet[0] = 0xD4
        packet[1] = UInt8(assignment.button.rawValue)
        packet[2] = assignment.action.assignmentTypeByte
        packet[3] = 0x02
        packet[4] = assignment.action.code
        packet[5] = 0x04
        return [
            ProfilePacket(bytes: packet,
                          label: "setButton \(assignment.button.title) → \(assignment.action.title)")
        ]
    }

    /// `DE 03 00` — NGENUITY sends this immediately after every DPI / button
    /// settings batch on Pulsefire devices. Without it, individual setting
    /// writes are accepted but do not actually take effect.
    func commitPacket() -> ProfilePacket? {
        var packet = Data(count: PacketUtils.packetSize)
        packet[0] = 0xDE
        packet[1] = 0x03
        return ProfilePacket(bytes: packet, send: .output, receive: .none, label: "commitSettings")
    }
}
