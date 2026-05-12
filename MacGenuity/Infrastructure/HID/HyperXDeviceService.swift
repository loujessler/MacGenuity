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

    /// User-selected device. When set, `ensureTransport` only considers
    /// candidates with matching VID:PID. When `nil` the service auto-picks
    /// the highest-scoring available device (legacy behaviour).
    private var preferredVendorID: Int?
    private var preferredProductID: Int?

    /// Number of consecutive HID errors against the cached transport.
    /// macOS does not always return a clean "device gone" code after a
    /// physical replug — sometimes it surfaces as `kIOReturnBadArgument`,
    /// sometimes as `kIOReturnUnsupported`. The error byte alone isn't
    /// always trustworthy, so we also count consecutive failures and
    /// drop the handle once the threshold is reached. Next call to
    /// `ensureTransport` rediscovers the device.
    private var consecutiveFailures = 0
    private let consecutiveFailureThreshold = 3

    /// Long-lived manager used purely for the device-removal callback so
    /// we can drop the cached transport synchronously when the user yanks
    /// the receiver. Keeping a single manager scheduled on the main run
    /// loop is the recommended pattern; opening it does not require Input
    /// Monitoring permission.
    private let removalManager: IOHIDManager
    private var removalContext: Unmanaged<HyperXDeviceService>?

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
        IOHIDManagerUnscheduleFromRunLoop(removalManager,
                                          CFRunLoopGetMain(),
                                          CFRunLoopMode.defaultMode.rawValue)
        removalContext?.release()
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
        let unmanaged = Unmanaged.passRetained(self)
        removalContext = unmanaged
        IOHIDManagerRegisterDeviceRemovalCallback(
            removalManager,
            { context, _, _, device in
                guard let context else { return }
                let service = Unmanaged<HyperXDeviceService>
                    .fromOpaque(context).takeUnretainedValue()
                Task { await service.handleDeviceRemoved(device) }
            },
            unmanaged.toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(removalManager,
                                        CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        // Open the manager — tolerated even without Input Monitoring,
        // because we never read input reports through it.
        IOHIDManagerOpen(removalManager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard let active = activeFingerprint else { return }
        let removedVID = HIDDeviceFinder.propertyInt(device, kIOHIDVendorIDKey)
        let removedPID = HIDDeviceFinder.propertyInt(device, kIOHIDProductIDKey)
        guard removedVID == active.vendorID, removedPID == active.productID else { return }
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

        var info: MouseInfo?
        var firstError: HIDError?

        if profile.capabilities.contains(.info) {
            // Profiles that advertise `.info` but don't actually have an
            // info command to send (QuadCast family — info is exposed via
            // USB descriptors / CoreAudio, not HID) return an empty list.
            // Treat that as "no info available" instead of looping over
            // zero packets and surfacing a misleading readTimeout error.
            let requests = profile.infoRequests()
            if !requests.isEmpty {
                do {
                    info = try executeRequest(requests,
                                              transport: transport,
                                              parse: profile.parseInfo)
                } catch let error as HIDError {
                    firstError = error
                    logger.warning(.hid, "probe: info failed: \(error.localizedDescription)")
                }
            }
        }

        if profile.capabilities.contains(.battery) {
            let requests = profile.batteryRequests()
            if !requests.isEmpty {
                do {
                    let battery = try executeRequest(requests,
                                                     transport: transport,
                                                     parse: profile.parseBattery)
                    return DeviceSnapshot(info: info, battery: battery, error: firstError)
                } catch let error as HIDError {
                    logger.warning(.hid, "probe: battery failed: \(error.localizedDescription)")
                    return DeviceSnapshot(info: info, battery: nil, error: error)
                }
            }
        }

        return DeviceSnapshot(info: info, battery: nil, error: firstError)
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
                       includeHasteProbe: Bool) async throws
    {
        try ensureTransport()
        guard let transport, let profile = activeProfile else {
            throw HIDError.deviceNotFound
        }

        if profile.capabilities.contains(.lighting) {
            for packet in profile.lightingPackets(target: target, effect: effect,
                                                  color: color,
                                                  brightness: brightness, speed: speed) {
                try send(packet, transport: transport)
            }
        }

        if includeHasteProbe, profile.capabilities.contains(.hasteDirect) {
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
        guard active.capabilities.contains(.dpiProfiles) else { return }

        let packets = active.dpiPackets(profile: profile, dpi: dpi,
                                        dpiColor: dpiColor(for: profile))
        for packet in packets {
            try send(packet, transport: transport)
        }
        // CRITICAL: NGENUITY ends every DPI batch with `DE 03 00`. Without
        // it the device accepts writes but does not apply them — this was
        // the cause of "DPI does not change when command is sent".
        if let commit = active.commitPacket() {
            try send(commit, transport: transport)
        }
    }

    func selectDPIProfile(_ profile: Int) async throws {
        try ensureTransport()
        guard let transport, let active = self.activeProfile else {
            throw HIDError.deviceNotFound
        }
        guard active.capabilities.contains(.dpiProfiles) else { return }

        let oneBased = UInt8(max(1, min(5, profile)))
        var bytes = Data(count: HIDTransport.packetSize)
        bytes[0] = 0xD3; bytes[3] = 0x01; bytes[4] = oneBased
        let select = ProfilePacket(bytes: bytes,
                                   send: .output, receive: .none,
                                   label: "selectDPIProfile (live) p=\(profile)")
        try send(select, transport: transport)
        if let commit = active.commitPacket() {
            try send(commit, transport: transport)
        }
    }

    nonisolated func availableDevices() -> [DeviceFingerprint] {
        // Discovery is non-isolated and only enumerates — safe to call
        // from any thread without permission.
        let candidates = HIDDeviceFinder.discoverCandidates(logger: FileLogger.shared)

        // De-duplicate by VID:PID; pick the candidate that best matches
        // a registered profile as the representative for each device.
        var bestPerVidPid: [String: (DeviceFingerprint, Double)] = [:]
        for candidate in candidates {
            let key = String(format: "%04X:%04X",
                             candidate.fingerprint.vendorID,
                             candidate.fingerprint.productID)
            let score = ProfileRegistry.shared
                .resolve(for: candidate)?.match(candidate.fingerprint) ?? 0
            if let existing = bestPerVidPid[key] {
                if score > existing.1 {
                    bestPerVidPid[key] = (candidate.fingerprint, score)
                }
            } else {
                bestPerVidPid[key] = (candidate.fingerprint, score)
            }
        }
        return bestPerVidPid.values
            .map { $0.0 }
            .sorted { $0.product < $1.product }
    }

    func setActiveDevice(_ fingerprint: DeviceFingerprint?) async {
        if let fp = fingerprint {
            preferredVendorID = fp.vendorID
            preferredProductID = fp.productID
            logger.info(.hid, "user selected device VID=\(Hex.u16(fp.vendorID)) PID=\(Hex.u16(fp.productID)) (\(fp.product))")
        } else {
            preferredVendorID = nil
            preferredProductID = nil
            logger.info(.hid, "user cleared device selection — auto-pick")
        }
        // Drop the cached transport so the next call rediscovers.
        resetTransport()
    }

    func applyDPIBatch(levels: [DPILevel], activeProfile: Int) async throws {
        try ensureTransport()
        guard let transport, let active = self.activeProfile else {
            throw HIDError.deviceNotFound
        }
        guard active.capabilities.contains(.dpiProfiles) else { return }

        let packets = active.dpiBatchPackets(levels: levels, activeProfile: activeProfile)
        for packet in packets {
            try send(packet, transport: transport)
        }
        if let commit = active.commitPacket() {
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
        guard active.capabilities.contains(.buttons) else { return }

        for assignment in assignments {
            for packet in active.buttonAssignmentPackets(assignment) {
                try send(packet, transport: transport)
            }
        }
        // Same `DE 03 00` commit used after DPI batches — the device
        // accepts the writes but doesn't apply them on the next click
        // without it.
        if let commit = active.commitPacket() {
            try send(commit, transport: transport)
        }
    }

    func sendHasteDirectFrame(_ color: RGBColor) async throws {
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
    nonisolated func diagnosticsCandidates() -> [DiagnosticsCandidate] {
        let candidates = HIDDeviceFinder.discoverCandidates(logger: FileLogger.shared)
        return candidates.map { c in
            let resolved = ProfileRegistry.shared.resolve(for: c)
            return DiagnosticsCandidate(
                fingerprint: c.fingerprint,
                summary: c.summary,
                resolvedProfile: resolved?.identifier
            )
        }
    }

    /// Send an arbitrary 64-byte packet. Used by the diagnostics window
    /// to probe new packet shapes without writing code first.
    func sendRawPacket(_ bytes: Data,
                       sendKind: ProfilePacket.SendKind,
                       receiveKind: ProfilePacket.ReceiveKind) async throws -> Data?
    {
        try ensureTransport()
        guard let transport else { throw HIDError.deviceNotFound }

        let packet = ProfilePacket(bytes: bytes,
                                   send: sendKind,
                                   receive: receiveKind,
                                   label: "diagnostics")
        return try transmit(packet, transport: transport)
    }

    func disconnect() async {
        if let transport {
            transport.close()
            self.transport = nil
        }
        self.activeProfile = nil
        self.activeFingerprint = nil
    }

    // MARK: - Internals

    private func ensureTransport() throws {
        switch HIDPermission.currentState() {
        case .denied:
            self.transport?.close()
            self.transport = nil
            self.activeProfile = nil
            self.activeFingerprint = nil
            throw HIDError.notPermitted
        case .unknown, .granted:
            break
        }

        if transport != nil { return }

        var candidates = HIDDeviceFinder.discoverCandidates(logger: logger)
        if let vid = preferredVendorID, let pid = preferredProductID {
            let filtered = candidates.filter {
                $0.fingerprint.vendorID == vid && $0.fingerprint.productID == pid
            }
            if !filtered.isEmpty {
                candidates = filtered
            } else {
                logger.warning(.hid, "preferred device VID=\(Hex.u16(vid)) PID=\(Hex.u16(pid)) not present — falling back to auto-pick")
            }
        }
        guard let pick = registry.selectBestCandidate(candidates, logger: logger) else {
            throw HIDError.deviceNotFound
        }

        let transport = HIDTransport(device: pick.0.device, logger: logger)
        try transport.open()
        self.transport = transport
        self.activeProfile = pick.1
        self.activeFingerprint = pick.0.fingerprint
        logger.info(.hid, "active profile=\(pick.1.identifier) capabilities=\(pick.1.capabilities.labels.joined(separator: ","))")
    }

    private func executeRequest<T>(_ packets: [ProfilePacket],
                                   transport: HIDTransport,
                                   parse: (Data) throws -> T) throws -> T
    {
        var lastError: Error?
        for packet in packets {
            do {
                guard let response = try transmit(packet, transport: transport),
                      let command = packet.bytes.first else {
                    throw HIDError.unexpectedResponse
                }
                _ = try PacketUtils.validate(response, command: command)
                return try parse(response)
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
    /// Constants from `IOKit/IOReturn.h`. After replugging a HyperX
    /// receiver into a different USB port macOS has been observed to
    /// return `kIOReturnBadArgument` (0xE00002C2) and `kIOReturnUnsupported`
    /// (0xE00002C7) for writes against the stale handle, in addition to
    /// the more obviously-fatal codes — so both are included here.
    private static func isFatalIOReturn(_ code: Int32) -> Bool {
        let unsigned = UInt32(bitPattern: code)
        switch unsigned {
        case 0xe00002c0,  // kIOReturnNoDevice
             0xe00002c2,  // kIOReturnBadArgument (observed after replug)
             0xe00002c7,  // kIOReturnUnsupported  (observed after replug)
             0xe00002cc,  // kIOReturnNotOpen
             0xe00002d1,  // kIOReturnNotConnected
             0xe00002eb,  // kIOReturnAborted
             0xe00002fc,  // kIOReturnOffline
             0xe000020f,  // kIOReturnNotResponding
             0xe00002ed:  // kIOReturnTimeout
            return true
        default:
            return false
        }
    }

    /// Called by `transmit` on every send/receive failure. Drops the
    /// transport once the threshold is reached so the next call rediscovers
    /// the device — a robust catch-all for flaky / changed-port hardware
    /// where the specific error code is not deterministic.
    private func recordTransportFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= consecutiveFailureThreshold {
            logger.warning(.hid,
                "transport: \(consecutiveFailures) consecutive failures — dropping cached handle")
            resetTransport()
        }
    }

    private func recordTransportSuccess() {
        consecutiveFailures = 0
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
            // For receive .input we await an interrupt input report.
            do {
                let response: Data?
                if packet.receive == .input {
                    response = try transport.sendAndAwaitInputReport(
                        packet.bytes, as: sendKind,
                        expectingCommand: command, timeoutMs: 1500
                    )
                } else if packet.receive == .feature {
                    try transport.send(packet.bytes, as: sendKind, verbose: verbose)
                    response = try transport.pollReport(
                        expectingCommand: command, as: .feature,
                        attempts: 5, timeoutMs: 1500
                    )
                } else {
                    try transport.send(packet.bytes, as: sendKind, verbose: verbose)
                    response = nil
                }
                recordTransportSuccess()
                return response
            } catch HIDError.notPermitted {
                resetTransport()
                throw HIDError.notPermitted
            } catch let HIDError.writeFailed(code) where Self.isFatalIOReturn(code) {
                resetTransport()
                throw HIDError.deviceNotFound
            } catch let HIDError.readFailed(code) where Self.isFatalIOReturn(code) {
                resetTransport()
                throw HIDError.deviceNotFound
            } catch let HIDError.openFailed(code) where Self.isFatalIOReturn(code) {
                resetTransport()
                throw HIDError.deviceNotFound
            } catch {
                lastError = error
                recordTransportFailure()
                if packet.retryWithReportID, sendKind == .feature, transport === self.transport {
                    do {
                        let prefixed = PacketUtils.withLeadingReportID(packet.bytes)
                        try transport.send(prefixed, as: .feature, verbose: verbose)
                        if packet.receive == .feature {
                            let response = try transport.pollReport(
                                expectingCommand: command, as: .feature,
                                attempts: 5, timeoutMs: 1500
                            )
                            recordTransportSuccess()
                            return response
                        }
                        recordTransportSuccess()
                        return nil
                    } catch {
                        lastError = error
                    }
                }
                // If the heuristic threshold tripped during this attempt,
                // resetTransport() was called and our local `transport`
                // ref is stale — bail out instead of re-attempting on a
                // dead handle.
                if self.transport == nil {
                    throw HIDError.deviceNotFound
                }
            }
        }
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
        "\(fingerprint.vendorID)-\(fingerprint.productID)-\(fingerprint.usagePage)-\(fingerprint.usage)"
    }
    let fingerprint: DeviceFingerprint
    let summary: String
    let resolvedProfile: String?
}
