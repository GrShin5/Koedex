import Foundation
import CoreAudio
import AudioToolbox

struct MicrophoneDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum MicrophoneDeviceManager {
    private static let transientDefaultAggregateUIDPrefix = "CADefaultDeviceAggregate-"

    static func inputDevices() -> [MicrophoneDevice] {
        devices().compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName),
                  !isTransientDefaultAggregateUID(uid) else {
                return nil
            }
            return MicrophoneDevice(id: deviceID, uid: uid, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultInputDevice() -> MicrophoneDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, selector: kAudioObjectPropertyName),
              !isTransientDefaultAggregateUID(uid) else {
            return nil
        }
        return MicrophoneDevice(id: deviceID, uid: uid, name: name)
    }

    static func device(forUID uid: String) -> MicrophoneDevice? {
        guard !uid.isEmpty else { return nil }
        return inputDevices().first { $0.uid == uid }
    }

    /// CoreAudioが内部で生成する既定入力aggregateはユーザー選択肢にしない。
    /// BlackHole等、ユーザーが作成した仮想入力はUIDが異なるため維持する。
    static func isTransientDefaultAggregateUID(_ uid: String) -> Bool {
        uid.hasPrefix(transientDefaultAggregateUIDPrefix)
    }

    static func normalizedPreferredInputUID(_ uid: String) -> String {
        isTransientDefaultAggregateUID(uid) ? "" : uid
    }

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = Array(repeating: AudioDeviceID(), count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        )
        return status == noErr ? ids : []
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
