//
//  CoreAudioMicrophoneService.swift
//  MacGenuity
//
//  Enumerates HyperX-branded input devices via CoreAudio.
//  CoreAudio types stay confined to this file.
//
//  Push notifications:
//    The service installs CoreAudio property listeners on the system
//    device list AND on each tracked HyperX mic's `Mute` / `Volume`
//    properties. Whenever any of those flip — including via the
//    on-device tap-to-mute pad of a QuadCast / SoloCast — the service
//    posts `Notification.Name.microphoneStateChanged` on the main
//    queue. The ViewModel subscribes and triggers an immediate
//    `refresh()` so the UI reflects hardware changes without waiting
//    for the next 60-second poll tick.
//

import CoreAudio
import Foundation

extension Notification.Name {
    /// Fired by `CoreAudioMicrophoneService` when CoreAudio reports a
    /// change on any tracked HyperX mic (device list / mute / volume).
    /// Always delivered on the main queue.
    static let microphoneStateChanged = Notification.Name("MacGenuity.microphoneStateChanged")
}

final class CoreAudioMicrophoneService: AudioService {
    private let logger: LoggerType

    /// One listener block per `(device, address)` so we can remove the
    /// exact pair when the device disconnects. CoreAudio's remove API
    /// requires the same block reference that was passed to add.
    private struct InstalledListener {
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// `kAudioHardwarePropertyDevices` listener — fires when devices
    /// are plugged / unplugged.
    private var deviceListListener: InstalledListener?

    /// Per-device listeners (mute + volume). Keyed by AudioObjectID so
    /// we can deregister precisely when that device vanishes.
    private var deviceListeners: [AudioObjectID: [InstalledListener]] = [:]

    init(logger: LoggerType = FileLogger.shared) {
        self.logger = logger
        installDeviceListListener()
        // Install per-device listeners for whatever's already attached.
        refreshDeviceListeners()
    }

    deinit {
        removeAllListeners()
    }

    func connectedMicrophones() -> [MicrophoneInfo] {
        let devices = allAudioDevices()
        let defaultInput = defaultInputDevice()

        let microphones = devices.compactMap { device -> MicrophoneInfo? in
            let streamCount = inputStreamCount(for: device)
            guard streamCount > 0 else { return nil }

            let name = stringProperty(kAudioObjectPropertyName, for: device) ?? ""
            let manufacturer = stringProperty(kAudioObjectPropertyManufacturer, for: device) ?? ""
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: device) ?? ""
            let haystack = "\(name) \(manufacturer) \(uid)".lowercased()

            guard haystack.contains("hyperx")
                || haystack.contains("solocast")
                || haystack.contains("quadcast")
                || haystack.contains("duocast") else { return nil }

            return MicrophoneInfo(
                id: device,
                name: name,
                manufacturer: manufacturer,
                uid: uid,
                sampleRate: doubleProperty(kAudioDevicePropertyNominalSampleRate, for: device),
                inputStreamCount: streamCount,
                volumePercent: volumePercent(for: device),
                isMuted: muteState(for: device),
                isDefaultInput: device == defaultInput
            )
        }

        logger.info(.audio, "found \(microphones.count) HyperX input device(s)")
        for mic in microphones {
            logger.debug(.audio, "name='\(mic.name)' streams=\(mic.inputStreamCount) sampleRate=\(mic.sampleRate ?? 0) muted=\(mic.isMuted.map(String.init) ?? "?") default=\(mic.isDefaultInput)")
        }
        return microphones
    }

    // MARK: - Property listeners (push updates)

    /// Watches `kAudioHardwarePropertyDevices` on the system object so
    /// we know when a HyperX mic arrives / leaves. On every change we
    /// reconcile per-device listeners and notify the ViewModel.
    private func installDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshDeviceListeners()
            self.postChange()
        }
        let result = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if result == noErr {
            deviceListListener = InstalledListener(address: address, block: block)
            logger.info(.audio, "installed device-list property listener")
        } else {
            logger.error(.audio, "failed to install device-list listener result=\(result)")
        }
    }

    /// Diff `trackedDevices` against the currently-attached HyperX mics
    /// and add/remove per-device listeners accordingly.
    private func refreshDeviceListeners() {
        let current = Set(connectedMicrophones().map { $0.id })
        let tracked = Set(deviceListeners.keys)

        for id in tracked.subtracting(current) {
            removeListeners(from: id)
        }
        for id in current.subtracting(tracked) {
            installListeners(on: id)
        }
    }

    /// Listen on mute + volume across both `Main` and legacy-element-1
    /// channels — same pair the read path probes, so we capture changes
    /// no matter which channel CoreAudio exposes for this device.
    private func installListeners(on device: AudioObjectID) {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyMute,
            kAudioDevicePropertyVolumeScalar
        ]
        let elements: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain,
            AudioObjectPropertyElement(1)
        ]

        var installed: [InstalledListener] = []
        for selector in selectors {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: element
                )
                guard AudioObjectHasProperty(device, &address) else { continue }

                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.postChange()
                }
                let result = AudioObjectAddPropertyListenerBlock(
                    device, &address, DispatchQueue.main, block
                )
                if result == noErr {
                    installed.append(InstalledListener(address: address, block: block))
                } else {
                    logger.debug(.audio, "listener add failed device=\(device) sel=\(selector) result=\(result)")
                }
            }
        }
        if !installed.isEmpty {
            deviceListeners[device] = installed
            logger.info(.audio, "installed \(installed.count) listener(s) on device=\(device)")
        }
    }

    private func removeListeners(from device: AudioObjectID) {
        guard let installed = deviceListeners[device] else { return }
        for listener in installed {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                device, &address, DispatchQueue.main, listener.block
            )
        }
        deviceListeners.removeValue(forKey: device)
    }

    private func removeAllListeners() {
        for device in Array(deviceListeners.keys) {
            removeListeners(from: device)
        }
        if let listener = deviceListListener {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener.block
            )
            deviceListListener = nil
        }
    }

    /// Notifies subscribers on the main queue. Property-listener blocks
    /// already run on `DispatchQueue.main` (we requested that queue when
    /// installing), so no extra hop is required.
    private func postChange() {
        NotificationCenter.default.post(name: .microphoneStateChanged, object: nil)
    }

    // MARK: - Setters

    @discardableResult
    func setMicrophoneMute(_ muted: Bool, deviceID: UInt32) -> Bool {
        let value: UInt32 = muted ? 1 : 0
        let written = writeInputProperty(kAudioDevicePropertyMute,
                                         value: value, for: deviceID)
        logger.info(.audio, "setMicrophoneMute(\(muted)) device=\(deviceID) ok=\(written)")
        return written
    }

    @discardableResult
    func setMicrophoneVolume(_ scalar: Float, deviceID: UInt32) -> Bool {
        let clamped = max(0, min(1, scalar))
        let written = writeInputScalar(kAudioDevicePropertyVolumeScalar,
                                       value: clamped, for: deviceID)
        logger.info(.audio, "setMicrophoneVolume(\(clamped)) device=\(deviceID) ok=\(written)")
        return written
    }

    private func writeInputProperty(_ selector: AudioObjectPropertySelector,
                                    value: UInt32,
                                    for device: AudioObjectID) -> Bool
    {
        // Try both `Main` (modern) and element 1 (legacy first-channel)
        // — same as the read path. CoreAudio rejects writes against the
        // wrong element with `kAudioHardwareUnknownPropertyError`.
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var isSettable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr,
                  isSettable.boolValue else { continue }
            var local = value
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &local) == noErr {
                return true
            }
        }
        return false
    }

    private func writeInputScalar(_ selector: AudioObjectPropertySelector,
                                  value: Float,
                                  for device: AudioObjectID) -> Bool
    {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var isSettable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr,
                  isSettable.boolValue else { continue }
            var local = Float32(value)
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &local) == noErr {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    private func allAudioDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        var actualSize = size
        let result = devices.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &actualSize, base)
        }
        guard result == noErr else {
            logger.error(.audio, "device enumeration failed result=\(result)")
            return []
        }
        return devices
    }

    private func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &device
        )
        return result == noErr && device != 0 ? device : nil
    }

    private func inputStreamCount(for device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return 0
        }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector,
                                for device: AudioObjectID) -> String?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        return result == noErr ? value as String? : nil
    }

    private func doubleProperty(_ selector: AudioObjectPropertySelector,
                                for device: AudioObjectID) -> Double?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return result == noErr ? Double(value) : nil
    }

    private func volumePercent(for device: AudioObjectID) -> Int? {
        guard let v = scalarInputProperty(kAudioDevicePropertyVolumeScalar, for: device) else {
            return nil
        }
        return Int((v * 100).rounded())
    }

    private func muteState(for device: AudioObjectID) -> Bool? {
        guard let m = uintInputProperty(kAudioDevicePropertyMute, for: device) else {
            return nil
        }
        return m != 0
    }

    private func scalarInputProperty(_ selector: AudioObjectPropertySelector,
                                     for device: AudioObjectID) -> Float?
    {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(device, &address) else { continue }

            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return Float(value)
            }
        }
        return nil
    }

    private func uintInputProperty(_ selector: AudioObjectPropertySelector,
                                   for device: AudioObjectID) -> UInt32?
    {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(device, &address) else { continue }

            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }
}
