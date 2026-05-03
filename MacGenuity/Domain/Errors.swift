//
//  Errors.swift
//  MacGenuity
//
//  Explicit error hierarchy. All boundary errors map onto these types
//  so UI can render meaningful state without inspecting raw IOReturn values.
//

import Foundation

enum PermissionError: Error, LocalizedError, Equatable {
    case inputMonitoringDenied
    case inputMonitoringUnknown

    var errorDescription: String? {
        switch self {
        case .inputMonitoringDenied:
            return "Input Monitoring permission is required. Open System Settings → Privacy & Security → Input Monitoring and enable MacGenuity."
        case .inputMonitoringUnknown:
            return "Input Monitoring permission status could not be determined."
        }
    }
}

enum HIDError: Error, LocalizedError, Equatable {
    case deviceNotFound
    case openFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case readTimeout
    case unexpectedResponse
    case bufferOverflow(reportedLength: Int, capacity: Int)
    case malformedReport(reason: String)
    case invalidPacketSize(Int)
    case notPermitted

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "HyperX device not found. Check that the receiver is plugged in."
        case .openFailed(let r):
            return "Failed to open HID device (IOReturn \(Hex.ioReturn(r)))."
        case .writeFailed(let r):
            return "Failed to send HID packet (IOReturn \(Hex.ioReturn(r)))."
        case .readFailed(let r):
            return "Failed to read HID packet (IOReturn \(Hex.ioReturn(r)))."
        case .readTimeout:
            return "Device did not respond in time."
        case .unexpectedResponse:
            return "Unexpected HID response format."
        case .bufferOverflow(let length, let capacity):
            return "HID report length \(length) exceeds buffer capacity \(capacity); dropping report."
        case .malformedReport(let reason):
            return "Malformed HID report: \(reason)."
        case .invalidPacketSize(let size):
            return "Invalid outbound packet size: \(size)."
        case .notPermitted:
            return "macOS denied HID access. Grant Input Monitoring permission and try again."
        }
    }
}

enum DeviceError: Error, LocalizedError {
    case permission(PermissionError)
    case hid(HIDError)
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .permission(let e): return e.errorDescription
        case .hid(let e):        return e.errorDescription
        case .audio(let msg):    return msg
        }
    }
}
