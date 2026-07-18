import CoreAudio
import Foundation
import LoopKitIPC

enum AudioDevices {
  static func outputDevices() -> [LKXPCDevice] {
    let defaultUID = defaultOutputUID()
    let ids = allDeviceIDs()
    return ids.compactMap { id in
      guard hasOutputStream(id: id) else { return nil }
      guard
        let uid = propertyString(deviceID: id, selector: kAudioDevicePropertyDeviceUID),
        let name = propertyString(deviceID: id, selector: kAudioObjectPropertyName)
      else {
        return nil
      }
      return LKXPCDevice(uid: uid, name: name, isDefault: uid == defaultUID)
    }
  }

  static func inputDevices() -> [LKXPCDevice] {
    let defaultUID = defaultInputUID()
    let ids = allDeviceIDs()
    return ids.compactMap { id in
      guard hasInputStream(id: id) else { return nil }
      guard
        let uid = propertyString(deviceID: id, selector: kAudioDevicePropertyDeviceUID),
        let name = propertyString(deviceID: id, selector: kAudioObjectPropertyName)
      else {
        return nil
      }
      return LKXPCDevice(uid: uid, name: name, isDefault: uid == defaultUID)
    }
  }

  static func defaultOutputUID() -> String? {
    return defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
  }

  static func defaultInputUID() -> String? {
    return defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice)
  }

  private static func defaultDeviceUID(selector: AudioObjectPropertySelector) -> String? {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id) == noErr else {
      return nil
    }
    return propertyString(deviceID: id, selector: kAudioDevicePropertyDeviceUID)
  }

  static func outputSampleRate(uid: String) -> Double? {
    guard !uid.isEmpty else { return nil }
    return allDeviceIDs().first(where: {
      hasOutputStream(id: $0) && propertyString(deviceID: $0, selector: kAudioDevicePropertyDeviceUID) == uid
    }).flatMap {
      propertyDouble(deviceID: $0, selector: kAudioDevicePropertyNominalSampleRate)
    }
  }

  static func defaultOutputSampleRate() -> Double? {
    guard let uid = defaultOutputUID() else { return nil }
    return outputSampleRate(uid: uid)
  }

  static func inputSampleRate(uid: String) -> Double? {
    guard !uid.isEmpty else { return nil }
    return allDeviceIDs().first(where: {
      hasInputStream(id: $0) && propertyString(deviceID: $0, selector: kAudioDevicePropertyDeviceUID) == uid
    }).flatMap {
      propertyDouble(deviceID: $0, selector: kAudioDevicePropertyNominalSampleRate)
    }
  }

  static func defaultInputSampleRate() -> Double? {
    guard let uid = defaultInputUID() else { return nil }
    return inputSampleRate(uid: uid)
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
      return []
    }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
      return []
    }
    return ids
  }

  private static func hasOutputStream(id: AudioDeviceID) -> Bool {
    return hasStream(id: id, scope: kAudioObjectPropertyScopeOutput)
  }

  private static func hasInputStream(id: AudioDeviceID) -> Bool {
    return hasStream(id: id, scope: kAudioObjectPropertyScopeInput)
  }

  private static func hasStream(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )

    if !AudioObjectHasProperty(id, &address) {
      return false
    }

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else {
      return false
    }
    return size > 0
  }

  private static func propertyString(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectHasProperty(deviceID, &address) else {
      return nil
    }

    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
          let value else {
      return nil
    }
    return value.takeUnretainedValue() as String
  }

  private static func propertyDouble(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Double? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectHasProperty(deviceID, &address) else {
      return nil
    }

    var value = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.stride)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return Double(value)
  }
}
