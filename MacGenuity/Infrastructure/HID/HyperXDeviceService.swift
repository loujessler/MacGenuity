//
//  HyperXDeviceService.swift
//  MacGenuity
//
//  Drives an `HIDTransport` through a resolved `DeviceProfile`. Knows
//  nothing about specific packet bytes — that's the profile's job.
//

import Foundation
import IOKit
import IOKit.hid

actor HyperXDeviceService: DeviceService {
    private let logger: LoggerType
    private let registry: ProfileRegistry
    private var transport: HIDTransport?
    private(set) var activeProfile: DeviceProfile?
    private(set) var activeFingerprint: DeviceFingerprint?

    private var preferredDevice: DeviceFingerprint?

    /// Number of consecutive HID errors against the cached transport.
    /// macOS does not always return a clean "device gone" code after a
    /// physical replug — sometimes it surfaces as `kIOReturnBadArgument`,
    /// sometimes as `kIOReturnUnsupported`. The error byte alone isn't
    /// always trustworthy, so we also count consecutive failures and
    /// drop the handle once the threshold is reached. Next call to
    /// `ensureTransport` rediscovers the device.
    private var consecutiveFailures = 0
    private let consecutiveFailureThreshold = 3

    /// Long-lived manager for receiver attachment and removal events.
    /// Keeping a single manager scheduled on the main run
    /// loop delivers device notifications without opening input interfaces.
    private let removalManager: IOHIDManager
    private var removalContext: Unmanaged<DeviceRemovalContext>?

    init(logger: LoggerType = FileLogger.shared,
         registry: ProfileRegistry = .shared)
    {
        self.logger = logger
        self.registry = registry
        self.removalManager = IOHIDManagerCreate(kCFAllocatorDefault,
                                                 IOOptionBits(kIOHIDOptionsTypeNone))
        Task { await scheduleRemovalCallback() }
    }

    deinit {
        let manager = removalManager
        let context = removalContext
        DispatchQueue.main.async(execute: DispatchWorkItem {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(),
                                              CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            context?.release()
        })
    }

    /// Wires the manager up so it fires `onDeviceRemoved` whenever any
    /// HyperX-vendor HID device disappears. Cheap; the manager is
    /// permanently scheduled on the main run loop.
    private func scheduleRemovalCallback() {
        // Match by HyperX vendor IDs only — narrows the firehose.
        let matching: [CFDictionary] = HIDDeviceFinder.hyperxVendorIDs.map { vid in
            [kIOHIDVendorIDKey as String: vid] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(removalManager, matching as CFArray)
        let unmanaged = Unmanaged.passRetained(DeviceRemovalContext(service: self))
        removalContext = unmanaged
        IOHIDManagerRegisterDeviceMatchingCallback(
            removalManager,
            { _, _, _, _ in
                NotificationCenter.default.post(name: .hidDevicesChanged, object: nil)
            },
            nil
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            removalManager,
            { context, _, _, device in
                guard let context else { return }
                guard let service = Unmanaged<DeviceRemovalContext>
                    .fromOpaque(context).takeUnretainedValue().service else { return }
                Task {
                    await service.handleDeviceRemoved(device)
                    NotificationCenter.default.post(name: .hidDevicesChanged, object: nil)
                }
            },
            unmanaged.toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(removalManager,
                                        CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)
        // Matching and removal notifications only need a scheduled manager.
        // Opening it would also open the receiver's keyboard and mouse interfaces.
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard let active = activeFingerprint else { return }
        let removedVID = HIDDeviceFinder.propertyInt(device, kIOHIDVendorIDKey)
        let removedPID = HIDDeviceFinder.propertyInt(device, kIOHIDProductIDKey)
        guard removedVID == active.vendorID, removedPID == active.productID else { return }
        if let activeID = active.registryEntryID, let removedID = HIDDeviceFinder.registryEntryID(for: device),
           activeID != removedID { return }
        logger.info(.hid, "device removed (VID=\(Hex.u16(removedVID)) PID=\(Hex.u16(removedPID))) — dropping transport")
        resetTransport()
    }

    // MARK: - Permission

    nonisolated func currentAccessState() -> HIDAccessState {
        HIDPermission.currentState()
    }

    func requestAccess() async -> HIDAccessState {
        let state = HIDPermission.requestAccess()
        logger.info(.hid, "requestAccess result=\(state)")
        return state
    }

    // MARK: - Probe

    func probe() async throws -> DeviceSnapshot {
        try ensureTransport()
        guard let transport, let profile = activeProfile else {
            throw HIDError.deviceNotFound
        }

        var firstError: HIDError?
        func readValue<T>(_ operation: () throws -> T) throws -> T? {
            do {
                return try operation()
            } catch HIDError.notPermitted {
                throw HIDError.notPermitted
            } catch HIDError.deviceNotFound {
                throw HIDError.deviceNotFound
            } catch let error as HIDError {
                firstError = firstError ?? error
                logger.warning(.hid, "probe: \(error.localizedDescription)")
                return nil
            }
        }

        let infoRequests = profile.infoRequests()
        var info: MouseInfo?
        if profile.capabilities.contains(.info), !infoRequests.isEmpty {
            info = try readValue { try executeRequest(infoRequests, transport: transport, parse: profile.parseInfo) }
        }
        let haste = activeFingerprint?.isPulsefireHasteWireless == true
        if haste, activeFingerprint?.productID == 0x028E {
            let linked = try readValue {
                try executeRequest([PulsefireHasteProfile.linkRequest], transport: transport, parse: PulsefireHasteProfile.isLinked)
            }
            guard linked == true else {
                return DeviceSnapshot(info: info, battery: nil, error: linked == false ? .mouseAsleep : firstError)
            }
            if info != nil {
                info?.pairedMouseFirmware = try readValue {
                    try executeRequest([PulsefireHasteProfile.pairedMouseInfoRequest], transport: transport,
                                       parse: profile.parseInfo).firmware
                }
            }
        }
        var battery: BatteryState?
        let batteryRequests = profile.batteryRequests()
        if profile.capabilities.contains(.battery), !batteryRequests.isEmpty {
            battery = try readValue { try executeRequest(batteryRequests, transport: transport, parse: profile.parseBattery) }
        }
        var dpi: DeviceDPIState?
        var wheelColour: WheelColour?
        if haste, battery != nil {
            dpi = try readValue {
                try executeRequest([PulsefireHasteProfile.dpiRequest], transport: transport, parse: PulsefireHasteProfile.parseDPI)
            }
            wheelColour = try readValue {
                try PulsefireHasteProfile.readWheelColour { packet in
                    try executeRequest([packet], transport: transport, parse: { $0 })
                }
            }
        }
        return DeviceSnapshot(info: info, battery: battery, error: firstError, dpi: dpi, wheelColour: wheelColour)
    }

    // MARK: - Info accessors for UI

    func snapshotProfile() -> ActiveProfileSnapshot? {
        guard let profile = activeProfile, let fp = activeFingerprint else { return nil }
        return ActiveProfileSnapshot(
            identifier: profile.identifier,
            displayName: profile.displayName,
            author: profile.author,
            capabilities: profile.capabilities,
            fingerprint: fp
        )
    }

    // MARK: - Lighting / DPI

    func applyLighting(target: LEDTarget,
                       effect: LEDEffect,
                       color: RGBColor,
                       brightness: Int,
                       speed: Int,
                       includeHasteProbe: Bool, persist: Bool) async throws
    {
        try Task.checkCancellation()
        try ensureTransport()
        guard let transport, let profile = activeProfile else {
            throw HIDError.deviceNotFound
        }

        guard profile.capabilities.contains(.lighting) else {
            throw HIDError.unsupportedOperation("Lighting")
        }
        for packet in profile.lightingPackets(target: target, effect: effect, color: color,
                                              brightness: brightness, speed: speed) {
            try send(packet, transport: transport)
        }

        // Preview frames stay in RAM; commit only the settled user selection.
        if persist, let commit = profile.commitPacket(for: .lighting) {
            try Task.checkCancellation()
            try send(commit, transport: transport)
        }

        if includeHasteProbe, effect == .staticColor, profile.capabilities.contains(.hasteDirect) {
            if let setup = profile.hasteSetupPacket() {
                try send(setup, transport: transport)
            }
            if let frame = profile.hasteDirectFrame(color) {
                try send(frame, transport: transport)
            }
        }
    }

    func applyDPI(profile: Int, dpi: Int) async throws {
        try ensureTransport()
        guard let transport, let active = activeProfile else {
            throw HIDError.deviceNotFound
        }
        guard active.capabilities.contains(.dpiProfiles) else {
            throw HIDError.unsupportedOperation("DPI")
        }

        let packets = active.dpiPackets(profile: profile, dpi: dpi,
                                        dpiColor: dpiColor(for: profile))
        for packet in packets {
            try send(packet, transport: transport)
        }
        // CRITICAL: NGENUITY ends every DPI batch with `DE 03 00`. Without
        // it the device accepts writes but does not apply them — this was
        // the cause of "DPI does not change when command is sent".
        if let commit = active.commitPacket(for: .dpi) {
            try send(commit, transport: transport)
        }
    }

    func selectDPIProfile(_ profile: Int) async throws {
        try ensureTransport()
        guard let transport, let active = self.activeProfile else {
            throw HIDError.deviceNotFound
        }
        guard active.capabilities.contains(.dpiProfiles) else {
            throw HIDError.unsupportedOperation("DPI")
        }

        try send(active.selectDPIPacket(profile), transport: transport)
        if let commit = active.commitPacket(for: .dpi) {
            try send(commit, transport: transport)
        }
    }

    func availableDevices() -> [DeviceFingerprint] {
        // Keep synchronous IOKit enumeration off the UI actor.
        let devices = HIDDeviceFinder.discoverCandidates(logger: logger).map(\.fingerprint)
        return registry.representativeDevices(in: devices)
    }

    func setActiveDevice(_ fingerprint: DeviceFingerprint?) async {
        preferredDevice = fingerprint
        if let fp = fingerprint {
            logger.info(.hid, "selected device VID=\(Hex.u16(fp.vendorID)) PID=\(Hex.u16(fp.productID)) (\(fp.product))")
        } else {
            logger.info(.hid, "cleared device selection — auto-pick")
        }
        // Drop the cached transport so the next call rediscovers.
        resetTransport()
    }

    func applyDPIBatch(levels: [DPILevel], activeProfile: Int) async throws {
        try ensureTransport()
        guard let transport, let active = self.activeProfile else {
            throw HIDError.deviceNotFound
        }
        guard active.capabilities.contains(.dpiProfiles) else {
            throw HIDError.unsupportedOperation("DPI")
        }

        let packets = active.dpiBatchPackets(levels: levels, activeProfile: activeProfile)
        for packet in packets {
            try send(packet, transport: transport)
        }
        if let commit = active.commitPacket(for: .dpi) {
            try send(commit, transport: transport)
        }
    }

    // MARK: - Button assignments

    func applyButtonAssignment(_ assignment: ButtonAssignment) async throws {
        try await applyButtonAssignments([assignment])
    }

    func applyButtonAssignments(_ assignments: [ButtonAssignment]) async throws {
        guard !assignments.isEmpty else { return }
        try ensureTransport()
        guard let transport, let active = self.activeProfile else {
            throw HIDError.deviceNotFound
        }
        guard active.capabilities.contains(.buttons) else {
            throw HIDError.unsupportedOperation("Button assignments")
        }

        let packets = try assignments.flatMap { assignment -> [ProfilePacket] in
            let packets = active.buttonAssignmentPackets(assignment)
            guard !packets.isEmpty else { throw HIDError.unsupportedOperation(assignment.action.title) }
            return packets
        }
        for packet in packets {
            try send(packet, transport: transport)
        }
        if let commit = active.commitPacket(for: .buttons) {
            try send(commit, transport: transport)
        }
    }

    func sendHasteDirectFrame(_ color: RGBColor) async throws {
        try Task.checkCancellation()
        try ensureTransport()
        guard let transport, let profile = activeProfile,
              profile.capabilities.contains(.hasteDirect),
              let packet = profile.hasteDirectFrame(color) else {
            throw HIDError.deviceNotFound
        }
        try send(packet, transport: transport, verbose: false)
    }

    // MARK: - Diagnostics

    /// Discover candidates without opening anything. Used by the diagnostics
    /// window so contributors can see all HyperX-shaped HID interfaces and
    /// pick which one their profile should match.
    func diagnosticsCandidates() -> [DiagnosticsCandidate] {
        let candidates = HIDDeviceFinder.discoverCandidates(logger: logger)
        return candidates.map { c in
            let resolved = registry.resolve(for: c.fingerprint)
            return DiagnosticsCandidate(
                fingerprint: c.fingerprint,
                summary: c.summary,
                resolvedProfile: resolved?.identifier
            )
        }
    }

    /// Send an arbitrary 64-byte packet. Used by the diagnostics window
    /// to probe new packet shapes without writing code first.
    func sendRawPacket(_ bytes: Data, to fingerprint: DeviceFingerprint,
                       sendKind: ProfilePacket.SendKind,
                       receiveKind: ProfilePacket.ReceiveKind) async throws -> Data?
    {
        guard preferredDevice == fingerprint else { throw HIDError.deviceNotFound }
        try ensureTransport()
        guard let transport else { throw HIDError.deviceNotFound }

        let packet = ProfilePacket(bytes: bytes,
                                   send: sendKind,
                                   receive: receiveKind,
                                   label: "diagnostics")
        return try transmit(packet, transport: transport)
    }

    func disconnect() async {
        resetTransport()
    }

    // MARK: - Internals

    private func ensureTransport() throws {
        // Finish all report fallbacks on the current handle before rediscovery.
        if consecutiveFailures >= consecutiveFailureThreshold {
            logger.warning(.hid, "Repeated transport failures; reopening the receiver")
            resetTransport()
        }
        if let activeFingerprint, transport != nil {
            try checkAccess(for: activeFingerprint)
            return
        }

        var candidates = HIDDeviceFinder.discoverCandidates(logger: logger)
        if let preferredDevice {
            let filtered = candidates.filter { preferredDevice.matchesAttachment($0.fingerprint) }
            // A command for a disconnected selection must not reach another mouse.
            guard !filtered.isEmpty else { throw HIDError.deviceNotFound }
            candidates = filtered
        }
        guard let fp = registry.preferredInterface(in: candidates.map(\.fingerprint)),
              let profile = registry.resolve(for: fp),
              let candidate = candidates.first(where: { $0.fingerprint == fp }) else {
            throw HIDError.deviceNotFound
        }

        try checkAccess(for: fp)
        let transport = HIDTransport(device: candidate.device, logger: logger)
        try transport.open()
        self.transport = transport
        self.activeProfile = profile
        self.activeFingerprint = fp
        logger.info(.hid, "active profile=\(profile.identifier) capabilities=\(profile.capabilities.labels.joined(separator: ","))")
    }

    private func checkAccess(for fingerprint: DeviceFingerprint) throws {
        guard fingerprint.isVendorControlInterface || HIDPermission.currentState() == .granted else {
            resetTransport()
            throw HIDError.notPermitted
        }
    }

    private func executeRequest<T>(_ packets: [ProfilePacket],
                                   transport: HIDTransport,
                                   parse: (Data) throws -> T) throws -> T
    {
        var lastError: Error?
        let requests = activeFingerprint?.probeRequests(packets) ?? packets
        for packet in requests {
            do {
                guard let response = try transmit(packet, transport: transport) else {
                    throw HIDError.unexpectedResponse
                }
                return try parse(response)
            } catch HIDError.deviceNotFound {
                throw HIDError.deviceNotFound
            } catch HIDError.notPermitted {
                resetTransport()
                throw HIDError.notPermitted
            } catch let HIDError.writeFailed(code) where Self.isFatalIOReturn(code) {
                resetTransport()
                throw HIDError.deviceNotFound
            } catch let HIDError.readFailed(code) where Self.isFatalIOReturn(code) {
                resetTransport()
                throw HIDError.deviceNotFound
            } catch {
                lastError = error
                logger.debug(.hid, "request '\(packet.label)' failed: \(error.localizedDescription)")
            }
        }
        throw lastError ?? HIDError.readTimeout
    }

    /// Some IOReturn codes mean the device handle is permanently dead —
    /// the only recovery is to drop it and rediscover.
    ///
    /// Unsupported report types must still reach the feature-report
    /// fallback. Repeated failures are handled by the retry threshold.
    private static func isFatalIOReturn(_ code: Int32) -> Bool {
        switch code {
        case kIOReturnNoDevice, kIOReturnNotOpen, kIOReturnNotAttached,
             kIOReturnAborted, kIOReturnOffline:
            return true
        default:
            return false
        }
    }

    private func resetTransport() {
        transport?.close()
        transport = nil
        activeProfile = nil
        activeFingerprint = nil
        consecutiveFailures = 0
    }

    /// Sends a single profile packet. If `receive == .none`, returns nil.
    @discardableResult
    private func transmit(_ packet: ProfilePacket,
                          transport: HIDTransport,
                          verbose: Bool = true) throws -> Data?
    {
        // Decide the actual send transport. `nil` means "try output, then feature".
        let sendKinds: [HIDTransport.ReportKind] = packet.send.map { [transportKind($0)] }
            ?? [.output, .feature]

        guard let command = packet.bytes.first else {
            throw HIDError.invalidPacketSize(0)
        }

        var lastError: Error?
        for sendKind in sendKinds {
            let reports = sendKind == .feature && packet.retryWithReportID
                ? [packet.bytes, PacketUtils.withLeadingReportID(packet.bytes)]
                : [packet.bytes]
            for report in reports {
                do {
                    let response: Data?
                    switch packet.receive {
                    case .input:
                        response = try transport.sendAndAwaitInputReport(
                            report, as: sendKind, expectingCommand: command, reportID: packet.reportID,
                            responsePrefix: packet.responsePrefix, timeoutMs: 1500)
                    case .feature:
                        try transport.send(report, as: sendKind, verbose: verbose)
                        response = try transport.pollReport(
                            expectingCommand: command, as: .feature, attempts: 5, timeoutMs: 1500)
                    case .none:
                        try transport.send(report, as: sendKind, verbose: verbose)
                        response = nil
                    }
                    consecutiveFailures = 0
                    return response
                } catch HIDError.notPermitted {
                    resetTransport()
                    throw HIDError.notPermitted
                } catch let error as HIDError {
                    switch error {
                    case .writeFailed(let code), .readFailed(let code), .openFailed(let code):
                        if Self.isFatalIOReturn(code) {
                            resetTransport()
                            throw HIDError.deviceNotFound
                        }
                    default:
                        break
                    }
                    lastError = error
                }
            }
        }
        consecutiveFailures += 1
        throw lastError ?? HIDError.readTimeout
    }

    @discardableResult
    private func send(_ packet: ProfilePacket,
                      transport: HIDTransport,
                      verbose: Bool = true) throws -> Data?
    {
        try transmit(packet, transport: transport, verbose: verbose)
    }

    private func transportKind(_ kind: ProfilePacket.SendKind) -> HIDTransport.ReportKind {
        switch kind {
        case .output:  return .output
        case .feature: return .feature
        }
    }

    private nonisolated func dpiColor(for profile: Int) -> RGBColor {
        switch profile {
        case 1: return PresetColor.red.rgb
        case 2: return PresetColor.blue.rgb
        case 3: return PresetColor.yellow.rgb
        case 4: return PresetColor.green.rgb
        default: return PresetColor.white.rgb
        }
    }
}

private final class DeviceRemovalContext {
    weak var service: HyperXDeviceService?

    init(service: HyperXDeviceService) {
        self.service = service
    }
}

/// Snapshot exposed to the UI without leaking the profile object itself.
struct ActiveProfileSnapshot: Equatable {
    let identifier: String
    let displayName: String
    let author: String
    let capabilities: DeviceCapabilities
    let fingerprint: DeviceFingerprint
}

/// Diagnostics-friendly view of a discovered candidate.
struct DiagnosticsCandidate: Identifiable {
    var id: String {
        fingerprint.attachmentKey
    }
    let fingerprint: DeviceFingerprint
    let summary: String
    let resolvedProfile: String?
}
