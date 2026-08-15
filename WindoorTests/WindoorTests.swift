//
//  WindoorTests.swift
//  WindoorTests
//
//  Created by naska. on 2025/12/02.
//

import AppKit
import Foundation
import Testing
@testable import Windoor

@MainActor
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

    @Test func menuBarIconVisibilityDefaultsOnAndPersists() throws {
        let defaults = UserDefaults.standard
        let key = "showMenuBarIcon"
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
        #expect(settings.showMenuBarIcon)

        settings.showMenuBarIcon = false
        let data = try #require(defaults.data(forKey: key))
        #expect(try JSONDecoder().decode(Bool.self, from: data) == false)
        #expect(SettingsModel().showMenuBarIcon == false)
    }

    @Test func addingModifierAfterLeftClickOnlyAutomaticallyEnablesFeature() {
        let defaults = UserDefaults.standard
        let keys = ["moveSetting", "resizeSetting", "isMoveEnabled", "isResizeEnabled"]
        let originalValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = originalValues[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let leftClickOnly = ShortcutSetting(
            keyCode: -1,
            flags: 0,
            mouseButton: .left,
            allowModifierOnly: true
        )
        let commandLeftClick = ShortcutSetting(
            keyCode: -1,
            flags: NSEvent.ModifierFlags.command.rawValue,
            mouseButton: .left,
            allowModifierOnly: true
        )

        let settings = SettingsModel()
        settings.moveSetting = leftClickOnly
        settings.resizeSetting = leftClickOnly
        #expect(!settings.isMoveEnabled)
        #expect(!settings.isResizeEnabled)

        settings.moveSetting = commandLeftClick
        settings.resizeSetting = commandLeftClick
        #expect(settings.isMoveEnabled)
        #expect(settings.isResizeEnabled)
    }

    @Test func newJapaneseSettingsLabelsAreAvailable() {
        let localization = LocalizationManager.shared
        #expect(localization.text("showMenuBarIcon", language: .japanese) == "メニューバーアイコンを表示")
        #expect(localization.text("leftClickOnlyWarning", language: .japanese) == "左クリックのみに設定することはできません")
    }

}
