//
//  PacketUtils.swift
//  MacGenuity
//
//  Helpers profiles use to construct and parse HyperX-style packets.
//

import Foundation

enum PacketUtils {
    static let packetSize = 64

    static func empty(command: UInt8) -> Data {
        var packet = Data(count: packetSize)
        packet[0] = command
        return packet
    }

    static func withLeadingReportID(_ packet: Data) -> Data {
        var report = Data([0])
        report.append(packet)
        return report
    }

    /// Locate the command byte within the first 4 bytes of `data`.
    /// Wireless dongles insert a 1–2 byte prefix before the documented packet.
    static func findCommandOffset(in data: Data, command: UInt8) -> Int? {
        let searchLen = min(4, data.count)
        let base = data.startIndex
        for i in 0..<searchLen {
            if data[base + i] == command { return i }
        }
        return nil
    }

    /// Reject obvious echo / empty / junk responses.
    static func validate(_ data: Data,
                         command: UInt8,
                         minPayloadLength: Int = 0) throws -> Int
    {
        guard let off = findCommandOffset(in: data, command: command) else {
            throw HIDError.unexpectedResponse
        }
        let base = data.startIndex
        let payloadStart = min(off + 1, data.count)
        let payloadEnd = min(off + packetSize, data.count)
        if payloadStart < payloadEnd,
           data[(base + payloadStart)..<(base + payloadEnd)].allSatisfy({ $0 == 0 }) {
            throw HIDError.malformedReport(reason: "empty payload after command")
        }
        if minPayloadLength > 0, data.count < off + minPayloadLength {
            throw HIDError.malformedReport(reason: "payload too short (\(data.count) < \(off + minPayloadLength))")
        }
        return off
    }
}
