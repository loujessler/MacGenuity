//
//  Hex.swift
//  MacGenuity
//

import Foundation

enum Hex {
    static func u8(_ value: UInt8) -> String {
        String(format: "%02X", value)
    }

    static func u16(_ value: Int) -> String {
        String(format: "0x%04X", value)
    }

    static func ioReturn(_ value: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }
}
