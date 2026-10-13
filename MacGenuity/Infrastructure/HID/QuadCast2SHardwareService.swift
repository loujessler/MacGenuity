//
//  QuadCast2SHardwareService.swift
//  MacGenuity
//
//  QuadCast 2 S hardware access that is independent from the microphone's
//  CoreAudio stream. IOKit stays confined to this actor and all report I/O is
//  serialized so complete 108-lamp frames cannot interleave.
//

import Foundation
import IOKit
import IOKit.hid

actor QuadCast2SHardwareService: QuadCast2SService {
    private let logger: LoggerType

    /// Report 6 is write-only on the tested firmware, so this is the last
    /// mode successfully selected by this process rather than a device read.
    private var lastKnownLightingMode: QuadCast2SLightingMode?
    private var cachedAttributes: QuadCast2SLampArrayAttributes?
    private var cachedLamps: [QuadCast2SLamp]?

    private var animationTask: Task<Void, Never>?
    private var animationGeneration: UInt64 = 0
    private var animationError: String?
    private var operationGeneration: UInt64 = 0

    init(logger: LoggerType = FileLogger.shared) {
        self.logger = logger
    }

    func snapshot() async -> QuadCast2SHardwareState {
        let candidates = HIDDeviceFinder.discoverCandidates(logger: logger)
        guard let lampArray = candidates.first(where: isLampArray) else {
            animationGeneration &+= 1
            animationTask?.cancel()
            animationTask = nil
            cachedAttributes = nil
            cachedLamps = nil
            lastKnownLightingMode = nil
            return QuadCast2SHardwareState(
                isConnected: false,
                hasLightingInterface: false,
                isAnimating: false,
                lampCount: nil,
                maximumFramesPerSecond: nil,
                lightingMode: nil,
                errorMessage: QuadCast2SError.deviceNotFound.localizedDescription
            )
        }

        var errors: [String] = []
        if cachedAttributes == nil {
            do {
                cachedAttributes = try readLampArrayAttributes(from: lampArray.device)
            } catch {
                errors.append(error.localizedDescription)
                logger.warning(
                    .lighting,
                    "QuadCast 2 S LampArray attributes: \(error.localizedDescription)"
                )
            }
        }

        if let animationError {
            errors.append(animationError)
        }

        let fallbackFPS = 1_000_000
            / Double(QuadCast2SProtocol.minimumUpdateIntervalMicroseconds)
        return QuadCast2SHardwareState(
            isConnected: true,
            hasLightingInterface: true,
            isAnimating: animationTask != nil,
            lampCount: cachedAttributes?.lampCount ?? QuadCast2SProtocol.lampCount,
            maximumFramesPerSecond: cachedAttributes?.maximumFramesPerSecond
                ?? fallbackFPS,
            lightingMode: lastKnownLightingMode,
            errorMessage: errors.first
        )
    }

    func applyStaticLighting(color: RGBColor, brightness: Int) async throws {
        operationGeneration &+= 1
        let operation = operationGeneration
        await stopCurrentAnimation()
        guard operation == operationGeneration else { throw CancellationError() }
        let candidate = try lampArrayCandidate()
        let attributes = (try? loadAttributes(from: candidate.device))
        let reports = QuadCast2SProtocol.staticLightingReports(
            color: color,
            brightness: brightness
        )

        try withOpenDevice(candidate.device) {
            try writeFeatureReport(reports[0], to: candidate.device)
            waitBeforeFirstUpdate(attributes)
            do {
                try writeFeatureReport(reports[1], to: candidate.device)
            } catch {
                // Avoid leaving the controller in manual mode if the actual
                // colour update failed after autonomous mode was disabled.
                try? writeFeatureReport(
                    QuadCast2SProtocol.restoreAutonomousLightingReport,
                    to: candidate.device
                )
                throw error
            }
        }

        animationError = nil
        lastKnownLightingMode = .staticColor
        let safeColor = color.clamped()
        logger.info(
            .lighting,
            "QuadCast 2 S static RGB=#\(safeColor.hexString) brightness=\(max(0, min(100, brightness)))"
        )
    }

    func applyLightingEffect(
        _ source: QuadCast2SEffectConfiguration
    ) async throws {
        let configuration = source.normalized()
        if configuration.kind == .solid {
            try await applyStaticLighting(
                color: configuration.palette[0],
                brightness: configuration.brightness
            )
            return
        }

        operationGeneration &+= 1
        let operation = operationGeneration
        await stopCurrentAnimation()
        guard operation == operationGeneration else { throw CancellationError() }
        let candidate = try lampArrayCandidate()
        let layout = try loadLayout(from: candidate.device)
        let firstFrame = QuadCast2SEffectRenderer.render(
            configuration: configuration,
            lamps: layout.lamps,
            elapsedTime: 0
        )
        try applyFrameOnce(
            firstFrame,
            to: candidate.device,
            attributes: layout.attributes
        )

        animationError = nil
        lastKnownLightingMode = .hostEffect
        guard configuration.kind.isAnimated else {
            logger.info(
                .lighting,
                "QuadCast 2 S custom 108-lamp frame applied brightness=\(configuration.brightness)"
            )
            return
        }

        animationGeneration &+= 1
        let generation = animationGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAnimation(
                configuration: configuration,
                lamps: layout.lamps,
                attributes: layout.attributes,
                generation: generation
            )
        }
        animationTask = task
        logger.info(
            .lighting,
            "QuadCast 2 S effect started kind=\(configuration.kind.rawValue) speed=\(configuration.speed)"
        )
    }

    func stopLightingEffect() async {
        operationGeneration &+= 1
        await stopCurrentAnimation()
    }

    private func stopCurrentAnimation() async {
        guard let task = animationTask else { return }
        animationGeneration &+= 1
        animationTask = nil
        task.cancel()
        await task.value
        logger.info(.lighting, "QuadCast 2 S software effect stopped on final frame")
    }

    func restoreAutonomousLighting() async throws {
        operationGeneration &+= 1
        let operation = operationGeneration
        await stopCurrentAnimation()
        guard operation == operationGeneration else { throw CancellationError() }
        let candidate = try lampArrayCandidate()
        try withOpenDevice(candidate.device) {
            try writeFeatureReport(
                QuadCast2SProtocol.restoreAutonomousLightingReport,
                to: candidate.device
            )
        }
        animationError = nil
        lastKnownLightingMode = .autonomous
        logger.info(.lighting, "QuadCast 2 S autonomous lighting restored")
    }

    // MARK: - Animation

    private func runAnimation(
        configuration: QuadCast2SEffectConfiguration,
        lamps: [QuadCast2SLamp],
        attributes: QuadCast2SLampArrayAttributes,
        generation: UInt64
    ) async {
        do {
            let candidate = try lampArrayCandidate()
            try openDevice(candidate.device)
            defer { closeDevice(candidate.device) }

            do {
                try writeFeatureReport(
                    Data([0x06, 0x00]),
                    to: candidate.device
                )
                try await Task.sleep(
                    nanoseconds: updateIntervalNanoseconds(attributes)
                )

                let start = DispatchTime.now().uptimeNanoseconds
                var nextDeadline = start
                while !Task.isCancelled, generation == animationGeneration {
                    let frameStart = DispatchTime.now().uptimeNanoseconds
                    let elapsed = Double(frameStart &- start) / 1_000_000_000
                    let values = QuadCast2SEffectRenderer.render(
                        configuration: configuration,
                        lamps: lamps,
                        elapsedTime: elapsed
                    )
                    try writeFrame(
                        values,
                        to: candidate.device,
                        lampCount: attributes.lampCount
                    )

                    let interval = updateIntervalNanoseconds(attributes)
                    nextDeadline = max(nextDeadline &+ interval, frameStart &+ interval)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if nextDeadline > now {
                        try await Task.sleep(nanoseconds: nextDeadline - now)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    try? writeFeatureReport(
                        QuadCast2SProtocol.restoreAutonomousLightingReport,
                        to: candidate.device
                    )
                    throw error
                }
            }
        } catch {
            if !Task.isCancelled {
                animationError = "Lighting animation stopped: \(error.localizedDescription)"
                logger.error(.lighting, animationError ?? "Lighting animation stopped")
            }
        }

        if generation == animationGeneration {
            animationTask = nil
        }
    }

    private func applyFrameOnce(
        _ values: [QuadCast2SLampValue],
        to device: IOHIDDevice,
        attributes: QuadCast2SLampArrayAttributes
    ) throws {
        try withOpenDevice(device) {
            try writeFeatureReport(Data([0x06, 0x00]), to: device)
            waitBeforeFirstUpdate(attributes)
            do {
                try writeFrame(values, to: device, lampCount: attributes.lampCount)
            } catch {
                try? writeFeatureReport(
                    QuadCast2SProtocol.restoreAutonomousLightingReport,
                    to: device
                )
                throw error
            }
        }
    }

    private func writeFrame(
        _ values: [QuadCast2SLampValue],
        to device: IOHIDDevice,
        lampCount: Int
    ) throws {
        let reports = try QuadCast2SProtocol.multiUpdateReports(
            values: values,
            availableLampCount: lampCount
        )
        for report in reports {
            try writeFeatureReport(report, to: device, verbose: false)
        }
    }

    // MARK: - LampArray discovery

    private func loadAttributes(
        from device: IOHIDDevice
    ) throws -> QuadCast2SLampArrayAttributes {
        if let cachedAttributes { return cachedAttributes }
        let attributes = try readLampArrayAttributes(from: device)
        cachedAttributes = attributes
        return attributes
    }

    private func readLampArrayAttributes(
        from device: IOHIDDevice
    ) throws -> QuadCast2SLampArrayAttributes {
        let report = try readFeatureReport(
            from: device,
            reportID: 0x01,
            capacity: 32
        )
        return try QuadCast2SProtocol.parseLampArrayAttributes(report)
    }

    private func loadLayout(
        from device: IOHIDDevice
    ) throws -> (
        attributes: QuadCast2SLampArrayAttributes,
        lamps: [QuadCast2SLamp]
    ) {
        let attributes = try loadAttributes(from: device)
        if let cachedLamps, cachedLamps.count == attributes.lampCount {
            return (attributes, cachedLamps)
        }

        let lamps: [QuadCast2SLamp] = try withOpenDevice(device) {
            try writeFeatureReport(
                QuadCast2SProtocol.lampAttributesRequestReport(lampID: 0),
                to: device,
                verbose: false
            )

            var result: [QuadCast2SLamp] = []
            result.reserveCapacity(attributes.lampCount)
            for expectedID in 0..<attributes.lampCount {
                var report = try getFeatureReport(
                    from: device,
                    reportID: 0x03,
                    capacity: 32,
                    verbose: false
                )
                var lamp = try QuadCast2SProtocol.parseLampAttributes(report)
                if Int(lamp.id) != expectedID {
                    try writeFeatureReport(
                        QuadCast2SProtocol.lampAttributesRequestReport(
                            lampID: UInt16(clamping: expectedID)
                        ),
                        to: device,
                        verbose: false
                    )
                    report = try getFeatureReport(
                        from: device,
                        reportID: 0x03,
                        capacity: 32,
                        verbose: false
                    )
                    lamp = try QuadCast2SProtocol.parseLampAttributes(report)
                }
                guard Int(lamp.id) == expectedID, lamp.isProgrammable else {
                    throw QuadCast2SError.malformedReport(reportID: 0x03)
                }
                result.append(lamp)
            }
            return result
        }

        cachedLamps = lamps
        logger.info(
            .lighting,
            "QuadCast 2 S geometry loaded lamps=\(lamps.count) maxFPS=\(String(format: "%.1f", attributes.maximumFramesPerSecond))"
        )
        return (attributes, lamps)
    }

    private func lampArrayCandidate() throws -> HIDDeviceCandidate {
        guard let candidate = HIDDeviceFinder
            .discoverCandidates(logger: logger)
            .first(where: isLampArray)
        else {
            throw QuadCast2SError.interfaceNotFound("LampArray")
        }
        return candidate
    }

    private func isLampArray(_ candidate: HIDDeviceCandidate) -> Bool {
        let fp = candidate.fingerprint
        return fp.vendorID == QuadCast2SProtocol.vendorID
            && fp.productID == QuadCast2SProtocol.controllerProductID
            && fp.usagePage == QuadCast2SProtocol.lampArrayUsagePage
            && fp.usage == QuadCast2SProtocol.lampArrayUsage
    }

    // MARK: - HID report I/O

    private func openDevice(_ device: IOHIDDevice) throws {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnNotPermitted || result == kIOReturnNotPrivileged {
            throw QuadCast2SError.notPermitted
        }
        guard result == kIOReturnSuccess else {
            throw QuadCast2SError.openFailed(result)
        }
    }

    private func closeDevice(_ device: IOHIDDevice) {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func withOpenDevice<T>(
        _ device: IOHIDDevice,
        operation: () throws -> T
    ) throws -> T {
        try openDevice(device)
        defer { closeDevice(device) }
        return try operation()
    }

    private func readFeatureReport(
        from device: IOHIDDevice,
        reportID: UInt8,
        capacity: Int
    ) throws -> Data {
        try withOpenDevice(device) {
            try getFeatureReport(
                from: device,
                reportID: reportID,
                capacity: capacity
            )
        }
    }

    private func getFeatureReport(
        from device: IOHIDDevice,
        reportID: UInt8,
        capacity: Int,
        verbose: Bool = true
    ) throws -> Data {
        let safeCapacity = max(2, min(4096, capacity))
        var buffer = [UInt8](repeating: 0, count: safeCapacity)
        buffer[0] = reportID
        var length = CFIndex(buffer.count)

        let result = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnNoMemory }
            return IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(reportID),
                base,
                &length
            )
        }
        if result == kIOReturnNotPermitted || result == kIOReturnNotPrivileged {
            throw QuadCast2SError.notPermitted
        }
        guard result == kIOReturnSuccess else {
            throw QuadCast2SError.readReportFailed(
                reportID: Int(reportID),
                result: result
            )
        }

        let safeLength = max(0, min(Int(length), buffer.count))
        guard safeLength > 0 else {
            throw QuadCast2SError.malformedReport(reportID: Int(reportID))
        }
        let report = Data(buffer.prefix(safeLength))
        if verbose {
            logger.debug(
                .hid,
                "QuadCast 2 S get feature \(Hex.u8(reportID)) \(report.hexDump())"
            )
        }
        return report
    }

    private func writeFeatureReport(
        _ report: Data,
        to device: IOHIDDevice,
        verbose: Bool = true
    ) throws {
        guard let reportID = report.first else {
            throw QuadCast2SError.malformedReport(reportID: 0)
        }
        let result = report.withUnsafeBytes { bytes -> IOReturn in
            guard let base = bytes.baseAddress else { return kIOReturnNoMemory }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(reportID),
                base.assumingMemoryBound(to: UInt8.self),
                report.count
            )
        }
        if result == kIOReturnNotPermitted || result == kIOReturnNotPrivileged {
            throw QuadCast2SError.notPermitted
        }
        guard result == kIOReturnSuccess else {
            throw QuadCast2SError.writeReportFailed(
                reportID: Int(reportID),
                result: result
            )
        }
        if verbose {
            logger.debug(
                .hid,
                "QuadCast 2 S set feature \(Hex.u8(reportID)) \(report.hexDump())"
            )
        }
    }

    private func waitBeforeFirstUpdate(
        _ attributes: QuadCast2SLampArrayAttributes?
    ) {
        let microseconds = attributes?.minimumUpdateIntervalMicroseconds
            ?? QuadCast2SProtocol.minimumUpdateIntervalMicroseconds
        Thread.sleep(forTimeInterval: Double(max(1_000, microseconds)) / 1_000_000)
    }

    private func updateIntervalNanoseconds(
        _ attributes: QuadCast2SLampArrayAttributes
    ) -> UInt64 {
        let microseconds = max(
            UInt32(1_000),
            attributes.minimumUpdateIntervalMicroseconds
        )
        return UInt64(microseconds) * 1_000
    }
}
