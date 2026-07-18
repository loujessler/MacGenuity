//
//  QuadCast2SProtocol.swift
//  MacGenuity
//
//  Pure packet construction and parsing for the QuadCast 2 S. Keeping the
//  wire format free of IOKit makes the reverse-engineered contract easy to
//  review and test without a microphone attached.
//

import Foundation

enum QuadCast2SProtocol {
    static let vendorID = 0x03F0
    static let controllerProductID = 0x02B5

    static let lampArrayUsagePage = 0xFF59
    static let lampArrayUsage = 0x0001

    static let lampCount = 108
    static let minimumUpdateIntervalMicroseconds: UInt32 = 33_000

    private static let attributesReportID: UInt8 = 0x01
    private static let lampAttributesRequestReportID: UInt8 = 0x02
    private static let lampAttributesResponseReportID: UInt8 = 0x03
    private static let multiUpdateReportID: UInt8 = 0x04
    private static let lampRangeReportID: UInt8 = 0x05
    private static let autonomousModeReportID: UInt8 = 0x06
    private static let multiUpdateSlotCount = 8
    private static let multiUpdateReportSize = 51

    /// Microsoft LampArray range update, applied to all 108 LEDs. Report 6
    /// disables the device's autonomous animation before report 5 supplies
    /// the static colour. Both reports were verified on a retail QuadCast 2 S.
    static func staticLightingReports(
        color: RGBColor,
        brightness: Int
    ) -> [Data] {
        let safeColor = color.clamped()
        let safeBrightness = max(0, min(100, brightness))
        let intensity = UInt8(clamping: (safeBrightness * 255 + 50) / 100)
        let lastLampID = UInt16(lampCount - 1)

        let autonomousOff = Data([autonomousModeReportID, 0x00])
        let rangeUpdate = Data([
            lampRangeReportID,
            0x01, // update-complete flag
            0x00, 0x00,
            UInt8(lastLampID & 0x00FF),
            UInt8((lastLampID >> 8) & 0x00FF),
            UInt8(safeColor.red),
            UInt8(safeColor.green),
            UInt8(safeColor.blue),
            intensity
        ])
        return [autonomousOff, rangeUpdate]
    }

    static var restoreAutonomousLightingReport: Data {
        Data([autonomousModeReportID, 0x01])
    }

    static func lampAttributesRequestReport(lampID: UInt16) -> Data {
        Data([
            lampAttributesRequestReportID,
            UInt8(lampID & 0x00FF),
            UInt8((lampID >> 8) & 0x00FF)
        ])
    }

    static func parseLampArrayAttributes(
        _ report: Data
    ) throws -> QuadCast2SLampArrayAttributes {
        let bytes = [UInt8](report)
        let offset = bytes.count >= 23 && bytes[0] == attributesReportID ? 1 : 0
        guard bytes.count >= offset + 22 else {
            throw QuadCast2SError.malformedReport(reportID: Int(attributesReportID))
        }

        return QuadCast2SLampArrayAttributes(
            lampCount: Int(readUInt16(bytes, at: offset)),
            boundingBoxWidth: readUInt32(bytes, at: offset + 2),
            boundingBoxHeight: readUInt32(bytes, at: offset + 6),
            boundingBoxDepth: readUInt32(bytes, at: offset + 10),
            kind: readUInt32(bytes, at: offset + 14),
            minimumUpdateIntervalMicroseconds: readUInt32(bytes, at: offset + 18)
        )
    }

    static func parseLampAttributes(_ report: Data) throws -> QuadCast2SLamp {
        let bytes = [UInt8](report)
        let offset = bytes.count >= 29 && bytes[0] == lampAttributesResponseReportID
            ? 1
            : 0
        guard bytes.count >= offset + 28 else {
            throw QuadCast2SError.malformedReport(
                reportID: Int(lampAttributesResponseReportID)
            )
        }

        return QuadCast2SLamp(
            id: readUInt16(bytes, at: offset),
            x: readUInt32(bytes, at: offset + 2),
            y: readUInt32(bytes, at: offset + 6),
            z: readUInt32(bytes, at: offset + 10),
            updateLatencyMicroseconds: readUInt32(bytes, at: offset + 14),
            purposes: readUInt32(bytes, at: offset + 18),
            redLevelCount: bytes[offset + 22],
            greenLevelCount: bytes[offset + 23],
            blueLevelCount: bytes[offset + 24],
            intensityLevelCount: bytes[offset + 25],
            isProgrammable: bytes[offset + 26] != 0,
            inputBinding: bytes[offset + 27]
        )
    }

    /// Builds atomic LampMultiUpdate batches. The QuadCast exposes eight
    /// update slots, so a complete 108-LED frame is fourteen 51-byte feature
    /// reports. Only the final report carries LampUpdateComplete (`0x01`).
    static func multiUpdateReports(
        values: [QuadCast2SLampValue],
        availableLampCount: Int = lampCount
    ) throws -> [Data] {
        guard !values.isEmpty else {
            throw QuadCast2SError.invalidLightingFrame("no lamp values")
        }

        let safeLampCount = max(0, min(Int(UInt16.max), availableLampCount))
        let normalized = values.map { $0.normalized() }
        let ids = Set(normalized.map(\.lampID))
        guard ids.count == normalized.count else {
            throw QuadCast2SError.invalidLightingFrame("duplicate lamp IDs")
        }
        guard normalized.allSatisfy({ Int($0.lampID) < safeLampCount }) else {
            throw QuadCast2SError.invalidLightingFrame("lamp ID is outside the array")
        }

        var reports: [Data] = []
        for start in stride(from: 0, to: normalized.count, by: multiUpdateSlotCount) {
            let end = min(start + multiUpdateSlotCount, normalized.count)
            let batch = normalized[start..<end]
            var report = Data(repeating: 0, count: multiUpdateReportSize)
            report[0] = multiUpdateReportID
            report[1] = UInt8(batch.count)
            report[2] = end == normalized.count ? 0x01 : 0x00

            for (slot, value) in batch.enumerated() {
                let idOffset = 3 + slot * 2
                report[idOffset] = UInt8(value.lampID & 0x00FF)
                report[idOffset + 1] = UInt8((value.lampID >> 8) & 0x00FF)

                let color = value.color.clamped()
                let colorOffset = 19 + slot * 4
                report[colorOffset] = UInt8(color.red)
                report[colorOffset + 1] = UInt8(color.green)
                report[colorOffset + 2] = UInt8(color.blue)
                report[colorOffset + 3] = UInt8(value.intensity)
            }
            reports.append(report)
        }
        return reports
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
