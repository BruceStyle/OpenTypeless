import XCTest
@testable import OpenTypeless
import OpenTypelessCore

final class AudioInputDeviceTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: "stable-built-in", name: "MacBook 麦克风", deviceID: 10)
    private let headset = AudioInputDevice(id: "stable-headset", name: "蓝牙耳机", deviceID: 20)

    func testSystemDefaultAndExplicitDeviceAreDifferentChoices() throws {
        let devices = [builtIn, headset]
        XCTAssertEqual(try AudioInputSelection.resolve(uid: nil, devices: devices, defaultID: 20), headset)
        XCTAssertEqual(try AudioInputSelection.resolve(uid: builtIn.id, devices: devices, defaultID: 20), builtIn)
        XCTAssertThrowsError(try AudioInputSelection.resolve(uid: headset.id, devices: [builtIn], defaultID: 10),
                             "A disconnected selection must not silently switch microphones")
        XCTAssertThrowsError(try AudioInputSelection.resolve(uid: nil, devices: [], defaultID: 0))
    }
    func testStableUIDSurvivesDeviceNumberChanges() throws {
        let reconnected = AudioInputDevice(id: headset.id, name: headset.name, deviceID: 77)
        XCTAssertEqual(try AudioInputSelection.resolve(uid: headset.id, devices: [builtIn, reconnected], defaultID: 10), reconnected)
    }
    func testMicrophoneChoicePersistsAndOldSettingsFollowSystem() throws {
        var settings = AppSettings(); settings.microphoneUID = headset.id
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).microphoneUID, headset.id)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json.removeValue(forKey: "microphoneUID")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.microphoneUID)
        XCTAssertEqual(old.transcriptionModel, settings.transcriptionModel)
    }
}
