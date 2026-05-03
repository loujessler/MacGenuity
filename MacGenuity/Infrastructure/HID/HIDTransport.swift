//
//  HIDTransport.swift
//  MacGenuity
//
//  Owns one IOHIDDevice handle and exchanges raw report bytes with it.
//
//  Hardening notes:
//    • The input-report buffer is allocated with `UnsafeMutablePointer<UInt8>.allocate`
//      and owned for the entire transport lifetime by `InputReportCapture`.
//      A previous design used `[UInt8].withUnsafeMutableBufferPointer` and
//      handed the resulting (closure-scoped) pointer to IOKit — that's a
//      dangling pointer the moment the closure returns, and was the root
//      cause of the EXC_BREAKPOINT in `_xzm_xzone_malloc_freelist`.
//    • The capture object is allocated in `open()` and released in `close()`.
//      No more per-request register/unregister churn, no Unmanaged.passRetained
//      gymnastics.
//    • The device is scheduled on the main run loop. The main run loop is
//      always pumped by the SwiftUI host, so callbacks fire reliably and
//      we never end up with stale callbacks on a dormant cooperative-pool
//      thread's run loop.
//    • Buffer size honours `kIOHIDMaxInputReportSizeKey` (with a sane minimum
//      and a 4 KiB cap).
//    • Every callback bounds-checks `reportLength` against the registered
//      capacity before constructing a `Data`.
//

import Foundation
import IOKit
import IOKit.hid

final class HIDTransport {
    static let packetSize = 64
    static let minBufferCapacity = 64
    static let maxBufferCapacity = 4096

    let device: IOHIDDevice
    let bufferCapacity: Int
    private let logger: LoggerType
    private let inputCapture: InputReportCapture
    private var isOpen = false
    private var isScheduled = false

    init(device: IOHIDDevice, logger: LoggerType = FileLogger.shared) {
        self.device = device
        self.logger = logger

        let declared = HIDDeviceFinder.propertyInt(device, kIOHIDMaxInputReportSizeKey)
        let raw = max(declared, Self.minBufferCapacity) + 1
        let capacity = min(raw, Self.maxBufferCapacity)
        self.bufferCapacity = capacity
        self.inputCapture = InputReportCapture(capacity: capacity)
    }

    deinit {
        close()
    }

    // MARK: - Lifecycle

    func open() throws {
        guard !isOpen else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        switch result {
        case kIOReturnSuccess:
            isOpen = true
            logger.info(.hid, "transport: opened device, bufferCapacity=\(bufferCapacity)")
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            logger.warning(.hid, "transport: open denied by TCC (result=\(Hex.ioReturn(result)))")
            throw HIDError.notPermitted
        default:
            logger.error(.hid, "transport: open failed result=\(Hex.ioReturn(result))")
            throw HIDError.openFailed(result)
        }

        scheduleInputCallback()
    }

    func close() {
        unscheduleInputCallback()
        guard isOpen else { return }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
        logger.info(.hid, "transport: closed device")
    }

    // MARK: - Input callback registration

    private func scheduleInputCallback() {
        guard !isScheduled else { return }

        // Pass-unretained is safe here: `inputCapture` is held strongly by
        // `self` for the entire scheduling window. We always unschedule
        // before the transport (and the capture) is deallocated.
        let context = Unmanaged.passUnretained(inputCapture).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputCapture.bufferPointer,
            inputCapture.capacity,
            Self.inputCallback,
            context
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        isScheduled = true
        logger.debug(.hid, "transport: input callback scheduled on main run loop")
    }

    private func unscheduleInputCallback() {
        guard isScheduled else { return }
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputCapture.bufferPointer,
            inputCapture.capacity,
            nil,
            nil
        )
        isScheduled = false
        logger.debug(.hid, "transport: input callback unscheduled")
    }

    // MARK: - Send

    enum ReportKind {
        case input, output, feature

        var name: String {
            switch self {
            case .input:   return "input"
            case .output:  return "output"
            case .feature: return "feature"
            }
        }

        var hidType: IOHIDReportType {
            switch self {
            case .input:   return kIOHIDReportTypeInput
            case .output:  return kIOHIDReportTypeOutput
            case .feature: return kIOHIDReportTypeFeature
            }
        }
    }

    func send(_ packet: Data, as kind: ReportKind, verbose: Bool = true) throws {
        guard isOpen else { throw HIDError.openFailed(kIOReturnNotOpen) }
        guard packet.count == Self.packetSize || packet.count == Self.packetSize + 1 else {
            throw HIDError.invalidPacketSize(packet.count)
        }
        if verbose { logger.debug(.hid, "send \(kind.name) \(packet.hexDump())") }

        let result = packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnNoMemory }
            return IOHIDDeviceSetReport(
                device,
                kind.hidType,
                0,
                base.assumingMemoryBound(to: UInt8.self),
                packet.count
            )
        }
        if result != kIOReturnSuccess {
            if verbose { logger.warning(.hid, "send \(kind.name) failed result=\(Hex.ioReturn(result))") }
            throw HIDError.writeFailed(result)
        }
    }

    // MARK: - Receive (polled GetReport)

    func pollReport(expectingCommand command: UInt8,
                    as kind: ReportKind,
                    attempts: Int,
                    timeoutMs: Int) throws -> Data
    {
        guard isOpen else { throw HIDError.openFailed(kIOReturnNotOpen) }
        var lastError: IOReturn?

        for _ in 0..<attempts {
            var buffer = [UInt8](repeating: 0, count: bufferCapacity)
            var length = CFIndex(buffer.count)
            let result = buffer.withUnsafeMutableBufferPointer { ptr -> IOReturn in
                guard let base = ptr.baseAddress else { return kIOReturnNoMemory }
                return IOHIDDeviceGetReport(device, kind.hidType, 0, base, &length)
            }

            if result == kIOReturnSuccess {
                let safeLength = max(0, min(Int(length), bufferCapacity))
                let data = Data(buffer.prefix(safeLength))
                logger.debug(.hid, "receive \(kind.name) \(data.hexDump())")
                if PacketUtils.findCommandOffset(in: data, command: command) != nil {
                    return data
                }
            } else if result == kIOReturnNotPermitted {
                throw HIDError.notPermitted
            } else {
                lastError = result
                logger.debug(.hid, "receive \(kind.name) result=\(Hex.ioReturn(result))")
            }

            Thread.sleep(forTimeInterval: Double(timeoutMs) / 1000.0 / Double(max(attempts, 1)))
        }

        if let lastError, lastError != kIOReturnUnsupported {
            throw HIDError.readFailed(lastError)
        }
        throw HIDError.readTimeout
    }

    // MARK: - Receive (callback)

    /// Sends `packet`, then waits for the persistent input-report callback
    /// to surface a report containing `command`. The callback runs on the
    /// main run loop; we just poll the capture for matches.
    func sendAndAwaitInputReport(_ packet: Data,
                                 as kind: ReportKind,
                                 expectingCommand command: UInt8,
                                 timeoutMs: Int) throws -> Data
    {
        guard isOpen, isScheduled else {
            throw HIDError.openFailed(kIOReturnNotOpen)
        }

        inputCapture.beginWaiting(for: command)
        defer { inputCapture.endWaiting() }

        try send(packet, as: kind)

        let pollIntervalSeconds = 0.02
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let data = inputCapture.takeMatch() {
                logger.debug(.hid, "receive input matched 0x\(Hex.u8(command)) \(data.hexDump())")
                return data
            }
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
        }
        throw HIDError.readTimeout
    }

    private static let inputCallback: IOHIDReportCallback = {
        context, _, _, _, _, _, reportLength in
        guard let context else { return }
        let capture = Unmanaged<InputReportCapture>.fromOpaque(context).takeUnretainedValue()
        capture.handle(reportLength: reportLength)
    }
}

/// Owns the input-report buffer for the lifetime of its enclosing transport.
/// Buffer is heap-allocated via `UnsafeMutablePointer.allocate` so the pointer
/// we hand to IOKit is stable across Swift's lifetime management.
private final class InputReportCapture {
    let capacity: Int
    let bufferPointer: UnsafeMutablePointer<UInt8>

    private let lock = NSLock()
    private var expectedCommand: UInt8?
    private var matched: Data?

    init(capacity: Int) {
        self.capacity = capacity
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        pointer.initialize(repeating: 0, count: capacity)
        self.bufferPointer = pointer
    }

    deinit {
        bufferPointer.deinitialize(count: capacity)
        bufferPointer.deallocate()
    }

    func beginWaiting(for command: UInt8) {
        lock.lock()
        expectedCommand = command
        matched = nil
        lock.unlock()
    }

    func endWaiting() {
        lock.lock()
        expectedCommand = nil
        // Leave any unread match in place — `takeMatch` clears it. We don't
        // want to lose a report that arrived in the gap between `endWaiting`
        // and the caller checking `takeMatch` once more.
        lock.unlock()
    }

    func takeMatch() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let data = matched
        matched = nil
        return data
    }

    func handle(reportLength: CFIndex) {
        // Defensive bounds check — corrupted reports must never construct a
        // Data with a length larger than the buffer we registered.
        guard reportLength > 0, Int(reportLength) <= capacity else {
            FileLogger.shared.warning(.hid,
                "input callback dropped report length=\(reportLength) capacity=\(capacity)")
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard let command = expectedCommand, matched == nil else { return }

        let data = Data(bytes: bufferPointer, count: Int(reportLength))
        if PacketUtils.findCommandOffset(in: data, command: command) != nil {
            matched = data
        }
    }
}
