import XCTest
@testable import OpenTypelessCore

final class OverlayAppearanceTests: XCTestCase {
    func testExistingSettingsMigrateToSystemAppearanceWithoutLosingPreferences() throws {
        let original = customizedSettings()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "overlayAppearance")

        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.overlayAppearance, .system)
        XCTAssertEqual(migrated, original)
    }

    func testEachAppearanceSurvivesSavingAndReloading() throws {
        for appearance in OverlayAppearance.allCases {
            var settings = customizedSettings()
            settings.overlayAppearance = appearance
            let data = try JSONEncoder().encode(settings)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(json["overlayAppearance"] as? String, appearance.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
        }
    }

    func testUnrecognizedAppearanceDoesNotResetUnrelatedSettings() throws {
        let original = customizedSettings()
        for value: Any in ["future-appearance", NSNull(), 42] {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            json["overlayAppearance"] = value
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded, original)
        }
    }

    private func customizedSettings() -> AppSettings {
        var settings = AppSettings()
        settings.transcriptionModel = "custom/speech"
        settings.rewriteModel = "custom/text"
        settings.mode = .structured
        settings.shortcut = "ctrl-option-space"
        settings.autoPaste = false
        settings.saveHistory = false
        settings.historyDays = 7
        settings.dictionary = "OpenTypeless\n自定义词"
        settings.microphoneUID = "selected-microphone"
        settings.diagnosticAudioUntil = Date(timeIntervalSince1970: 1_800_000_000)
        return settings
    }
}
