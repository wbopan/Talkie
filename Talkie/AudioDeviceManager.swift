//
//  AudioDeviceManager.swift
//  Seedling
//
//  CoreAudio device enumeration for microphone selection
//

import Foundation
import CoreAudio
import Combine
import OSLog

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String          // Persistent identifier for storage
    let name: String
}

/// Manages audio input device enumeration and selection
class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    @Published private(set) var inputDevices: [AudioInputDevice] = []

    private init() {
        refreshDevices()
    }

    /// Refresh the list of available input devices
    func refreshDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get size of device list
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            log(.error, "Failed to get audio devices size: \(status)")
            return
        }

        // Get device IDs
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            log(.error, "Failed to get audio devices: \(status)")
            return
        }

        // Filter to input devices and get their info
        var devices: [AudioInputDevice] = []

        for deviceID in deviceIDs {
            // Check if device has input channels
            guard hasInputChannels(deviceID: deviceID) else { continue }

            // Get device UID
            guard let uid = getDeviceUID(deviceID: deviceID) else { continue }

            // Get device name
            guard let name = getDeviceName(deviceID: deviceID) else { continue }

            devices.append(AudioInputDevice(id: deviceID, uid: uid, name: name))
        }

        inputDevices = devices
        log(.info, "Found \(devices.count) input devices")
    }

    /// Get AudioDeviceID for a given UID
    /// Returns nil if device not found (allows fallback to system default)
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        return inputDevices.first { $0.uid == uid }?.id
    }

    /// Static function to look up a device ID by UID
    /// This directly queries CoreAudio without needing the singleton's cached list
    /// Safe to call from any isolation context
    nonisolated static func lookupDeviceID(forUID uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get size of device list
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { return nil }

        // Get device IDs
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return nil }

        // Find device with matching UID
        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceUID: Unmanaged<CFString>?
            var uidDataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

            let uidStatus = AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &uidDataSize,
                &deviceUID
            )

            if uidStatus == noErr, let uidRef = deviceUID?.takeRetainedValue(), (uidRef as String) == uid {
                return deviceID
            }
        }

        return nil
    }

    // MARK: - Private Helpers

    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }

        let result = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            bufferListPointer
        )

        guard result == noErr else { return false }

        let bufferList = bufferListPointer.pointee
        return bufferList.mNumberBuffers > 0 && bufferList.mBuffers.mNumberChannels > 0
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let uidRef = uid?.takeRetainedValue() else { return nil }
        return uidRef as String
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &name
        )

        guard status == noErr, let nameRef = name?.takeRetainedValue() else { return nil }
        return nameRef as String
    }
}
