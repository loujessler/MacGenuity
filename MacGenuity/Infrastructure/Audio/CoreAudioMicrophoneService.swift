//
//  CoreAudioMicrophoneService.swift
//  MacGenuity
//
//  Enumerates HyperX-branded input devices via CoreAudio.
//  CoreAudio types stay confined to this file.
//

import CoreAudio
import Foundation

final class CoreAudioMicrophoneService: AudioService {
    private let logger: LoggerType

    init(logger: LoggerType = FileLogger.shared) {
        self.logger = logger
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
