//
//  WindoorTests.swift
//  WindoorTests
//
//  Created by naska. on 2025/12/02.
//

import Foundation
import Testing
@testable import Windoor

struct WindoorTests {

    @Test func resizeAnchorPointDefaultsToTopLeftAndPersists() throws {
        let defaults = UserDefaults.standard
        let key = "resizeAnchorPoint"
        let originalValue = defaults.object(forKey: key)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let settings = SettingsModel()
        #expect(settings.resizeAnchorPoint == .topLeft)

        settings.resizeAnchorPoint = .farthest
        let data = try #require(defaults.data(forKey: key))
        let storedValue = try JSONDecoder().decode(ResizeAnchorPoint.self, from: data)
        #expect(storedValue == .farthest)

        let reloadedSettings = SettingsModel()
        #expect(reloadedSettings.resizeAnchorPoint == .farthest)
    }

    @Test func resizeAnchorPointJapaneseLabelsMatchSettingsChoices() {
        #expect(ResizeAnchorPoint.topLeft.localizedName(lang: .japanese) == "左上")
        #expect(ResizeAnchorPoint.topRight.localizedName(lang: .japanese) == "右上")
        #expect(ResizeAnchorPoint.bottomLeft.localizedName(lang: .japanese) == "左下")
        #expect(ResizeAnchorPoint.bottomRight.localizedName(lang: .japanese) == "右下")
        #expect(ResizeAnchorPoint.nearest.localizedName(lang: .japanese) == "近い角")
        #expect(ResizeAnchorPoint.farthest.localizedName(lang: .japanese) == "遠い角")
    }

}
