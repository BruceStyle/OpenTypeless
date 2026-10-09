import CoreAudio
import Foundation
import Observation
import OpenTypelessCore

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: String // Stable Core Audio UID, rather than a transient device number.
    let name: String
    let deviceID: AudioDeviceID
}

enum AudioInputSelection {
    static func resolve(uid: String?, devices: [AudioInputDevice], defaultID: AudioDeviceID) throws -> AudioInputDevice {
        if let uid, !uid.isEmpty {
            guard let selected = devices.first(where: { $0.id == uid }) else {
                throw AppError.message("所选麦克风已断开。请重新连接，或在设置中选择其他麦克风。")
            }
            return selected
        }
        guard let selected = devices.first(where: { $0.deviceID == defaultID }) else {
            throw AppError.message("没有可用的麦克风，请连接输入设备后重试。")
        }
        return selected
    }
}

enum AudioDeviceDiscovery {
    struct Snapshot {
        let devices: [AudioInputDevice]
        let defaultID: AudioDeviceID
    }
    static func snapshot() -> Snapshot {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return Snapshot(devices: [], defaultID: 0)
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return Snapshot(devices: [], defaultID: 0) }
        let devices = ids.compactMap { id -> AudioInputDevice? in
            guard inputChannels(id) > 0, integer(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: uid, name: name, deviceID: id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Snapshot(devices: devices, defaultID: integer(system, kAudioHardwarePropertyDefaultInputDevice))
    }
    static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func integer(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = property(selector), value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector), value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Core Audio transfers ownership for both Name and DeviceUID.
        return value?.takeRetainedValue() as String?
    }
    private static func inputChannels(_ id: AudioDeviceID) -> UInt32 {
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + $1.mNumberChannels }
    }
}

@MainActor @Observable final class AudioInputDevices {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var defaultID: AudioDeviceID = 0
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    init() {
        refresh()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        self.listener = listener
        for selector in selectors {
            var address = AudioDeviceDiscovery.property(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }
    func refresh() {
        let snapshot = AudioDeviceDiscovery.snapshot()
        devices = snapshot.devices; defaultID = snapshot.defaultID
    }
    var defaultName: String { devices.first { $0.deviceID == defaultID }?.name ?? "暂无可用设备" }
    deinit {
        if let listener {
            for selector in selectors {
                var address = AudioDeviceDiscovery.property(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            }
        }
    }
}
