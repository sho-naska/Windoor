import Foundation
import Combine
import Cocoa

// マウスボタンの種類
enum MouseButton: String, Codable, CaseIterable, Identifiable {
    case left = "leftClick"   // 翻訳キー
    case right = "rightClick"
    case center = "centerClick"
    
    var id: String { self.rawValue }
    
    // 表示用テキストを動的に取得
    func localizedName(lang: AppLanguage) -> String {
        return LocalizationManager.shared.text(self.rawValue, language: lang)
    }
}

// リサイズ時に固定するウィンドウの角
enum ResizeAnchorPoint: String, Codable, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case nearest
    case farthest

    var id: String { self.rawValue }

    private var localizationKey: String {
        switch self {
        case .topLeft: return "anchorTopLeft"
        case .topRight: return "anchorTopRight"
        case .bottomLeft: return "anchorBottomLeft"
        case .bottomRight: return "anchorBottomRight"
        case .nearest: return "anchorNearest"
        case .farthest: return "anchorFarthest"
        }
    }

    func localizedName(lang: AppLanguage) -> String {
        LocalizationManager.shared.text(localizationKey, language: lang)
    }
}

// ショートカット設定
struct ShortcutSetting: Codable, Equatable {
    var keyCode: Int = -1
    var flags: UInt = 0
    var mouseButton: MouseButton
    var allowModifierOnly: Bool = true
    
    var keyDisplayString: String {
        var parts: [String] = []
        
        let eventFlags = NSEvent.ModifierFlags(rawValue: flags)
        if eventFlags.contains(.control) { parts.append("⌃") }
        if eventFlags.contains(.option) { parts.append("⌥") }
        if eventFlags.contains(.shift) { parts.append("⇧") }
        if eventFlags.contains(.command) { parts.append("⌘") }
        
        if keyCode >= 0, let char = key(keyCode) {
            parts.append(char)
        } else if keyCode == -1 && parts.isEmpty {
            return "None"
        }
        
        return parts.joined(separator: "")
    }
    
    private func key(_ code: Int) -> String? {
        switch code {
        case 29: return "0"; case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 23: return "5"; case 22: return "6"; case 26: return "7"
        case 28: return "8"; case 25: return "9"; case 0: return "A"; case 11: return "B"
        case 8: return "C"; case 2: return "D"; case 14: return "E"; case 3: return "F"
        case 5: return "G"; case 4: return "H"; case 34: return "I"; case 38: return "J"
        case 40: return "K"; case 37: return "L"; case 46: return "M"; case 45: return "N"
        case 31: return "O"; case 35: return "P"; case 12: return "Q"; case 15: return "R"
        case 1: return "S"; case 17: return "T"; case 32: return "U"; case 9: return "V"
        case 13: return "W"; case 7: return "X"; case 16: return "Y"; case 6: return "Z"
        case 49: return "Space"; case 36: return "Return"; case 48: return "Tab"
        case 51: return "Delete"; case 53: return "Esc"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default: return nil
        }
    }
    
    func matches(eventFlags: CGEventFlags, eventKeyCode: Int64?) -> Bool {
        let targetFlags = NSEvent.ModifierFlags(rawValue: flags)
        let requiredMask: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        
        let relevantTarget = targetFlags.intersection(requiredMask)
        
        var matchesFlags = true
        if relevantTarget.contains(.command) && !eventFlags.contains(.maskCommand) { matchesFlags = false }
        if relevantTarget.contains(.shift) && !eventFlags.contains(.maskShift) { matchesFlags = false }
        if relevantTarget.contains(.control) && !eventFlags.contains(.maskControl) { matchesFlags = false }
        if relevantTarget.contains(.option) && !eventFlags.contains(.maskAlternate) { matchesFlags = false }
        
        if keyCode >= 0 {
            guard let code = eventKeyCode else { return false }
            return matchesFlags && (Int(code) == keyCode)
        } else {
            if relevantTarget.isEmpty { return false }
            return matchesFlags
        }
    }
    
    var isEmpty: Bool {
        return !hasKeyboardTrigger
    }

    var hasKeyboardTrigger: Bool {
        if keyCode >= 0 { return true }
        let modifierMask: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        return !NSEvent.ModifierFlags(rawValue: flags).intersection(modifierMask).isEmpty
    }

    func isHeld(eventFlags: CGEventFlags, pressedKeyCodes: Set<Int>) -> Bool {
        guard !isEmpty else { return false }
        if keyCode >= 0 {
            let isKeyPressed = pressedKeyCodes.contains(keyCode) ||
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
            guard isKeyPressed else { return false }
            return matches(eventFlags: eventFlags, eventKeyCode: Int64(keyCode))
        }
        return matches(eventFlags: eventFlags, eventKeyCode: nil)
    }
}

// 言語変更通知用の名前
extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
}

class SettingsModel: ObservableObject {
    @Published var isMoveEnabled: Bool {
        didSet {
            if isMoveEnabled && !moveSetting.hasKeyboardTrigger {
                isMoveEnabled = false
            }
            save(isMoveEnabled, key: "isMoveEnabled")
        }
    }
    
    @Published var isResizeEnabled: Bool {
        didSet {
            if isResizeEnabled && !resizeSetting.hasKeyboardTrigger {
                isResizeEnabled = false
            }
            save(isResizeEnabled, key: "isResizeEnabled")
        }
    }
    
    @Published var isRecording: Bool = false
    
    @Published var recordingTimeout: Double {
        didSet { save(recordingTimeout, key: "recordingTimeout") }
    }

    @Published var preserveWindowOrder: Bool {
        didSet { save(preserveWindowOrder, key: "preserveWindowOrder") }
    }

    @Published var resizeAnchorPoint: ResizeAnchorPoint {
        didSet { save(resizeAnchorPoint, key: "resizeAnchorPoint") }
    }

    @Published var horizontalConstraintSetting: ShortcutSetting {
        didSet { save(horizontalConstraintSetting, key: "horizontalConstraintSetting") }
    }

    @Published var verticalConstraintSetting: ShortcutSetting {
        didSet { save(verticalConstraintSetting, key: "verticalConstraintSetting") }
    }
    
    @Published var language: AppLanguage {
        didSet {
            save(language, key: "language")
            // 言語が変更されたら通知を送る（メニューバー更新用）
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }
    
    @Published var moveSetting: ShortcutSetting {
        didSet {
            save(moveSetting, key: "moveSetting")
            if !moveSetting.hasKeyboardTrigger {
                isMoveEnabled = false
            }
        }
    }
    
    @Published var resizeSetting: ShortcutSetting {
        didSet {
            save(resizeSetting, key: "resizeSetting")
            if !resizeSetting.hasKeyboardTrigger {
                isResizeEnabled = false
            }
        }
    }
    
    // 追加: ログイン時に自動実行
    @Published var launchAtLogin: Bool {
        didSet {
            save(launchAtLogin, key: "launchAtLogin")
            LoginItemManager.shared.setLaunchAtLogin(launchAtLogin)
        }
    }
    
    var hasConflict: Bool {
        if moveSetting.isEmpty || resizeSetting.isEmpty { return false }
        
        if isMoveEnabled && isResizeEnabled {
            return moveSetting.keyCode == resizeSetting.keyCode &&
                   moveSetting.flags == resizeSetting.flags &&
                   moveSetting.mouseButton == resizeSetting.mouseButton
        }
        return false
    }
    
    init() {
        let defaultMove = ShortcutSetting(
            keyCode: -1,
            flags: NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.command.rawValue,
            mouseButton: .left,
            allowModifierOnly: true
        )
        let defaultResize = ShortcutSetting(
            keyCode: -1,
            flags: NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.command.rawValue,
            mouseButton: .left,
            allowModifierOnly: true
        )
        let loadedMove = SettingsModel.load(key: "moveSetting", type: ShortcutSetting.self) ?? defaultMove
        let loadedResize = SettingsModel.load(key: "resizeSetting", type: ShortcutSetting.self) ?? defaultResize
        let storedMoveEnabled = SettingsModel.loadBool(key: "isMoveEnabled") ?? true
        let storedResizeEnabled = SettingsModel.loadBool(key: "isResizeEnabled") ?? true

        self.isMoveEnabled = storedMoveEnabled && loadedMove.hasKeyboardTrigger
        self.isResizeEnabled = storedResizeEnabled && loadedResize.hasKeyboardTrigger
        self.recordingTimeout = SettingsModel.loadDouble(key: "recordingTimeout") ?? 1.5
        self.preserveWindowOrder = SettingsModel.loadBool(key: "preserveWindowOrder") ?? false
        self.resizeAnchorPoint = SettingsModel.load(
            key: "resizeAnchorPoint",
            type: ResizeAnchorPoint.self
        ) ?? .topLeft

        let defaultAxisConstraint = ShortcutSetting(
            keyCode: -1,
            flags: NSEvent.ModifierFlags.shift.rawValue,
            mouseButton: .left,
            allowModifierOnly: true
        )
        self.horizontalConstraintSetting = SettingsModel.load(
            key: "horizontalConstraintSetting",
            type: ShortcutSetting.self
        ) ?? defaultAxisConstraint
        self.verticalConstraintSetting = SettingsModel.load(
            key: "verticalConstraintSetting",
            type: ShortcutSetting.self
        ) ?? defaultAxisConstraint
        
        if let langData = UserDefaults.standard.data(forKey: "language"),
           let lang = try? JSONDecoder().decode(AppLanguage.self, from: langData) {
            self.language = lang
        } else {
            self.language = .system
        }
        
        self.moveSetting = loadedMove
        self.resizeSetting = loadedResize
        
        // launchAtLogin 初期値: 保存済みがあればそれを使用、なければシステム状態から取得
        if let stored = SettingsModel.loadBool(key: "launchAtLogin") {
            self.launchAtLogin = stored
        } else {
            self.launchAtLogin = LoginItemManager.shared.isLaunchAtLoginEnabled()
        }
    }
    
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    private static func load<T: Decodable>(key: String, type: T.Type) -> T? {
        if let data = UserDefaults.standard.data(forKey: key),
           let value = try? JSONDecoder().decode(type, from: data) {
            return value
        }
        return nil
    }

    private static func loadBool(key: String) -> Bool? {
        load(key: key, type: Bool.self) ?? (UserDefaults.standard.object(forKey: key) as? Bool)
    }

    private static func loadDouble(key: String) -> Double? {
        load(key: key, type: Double.self) ?? (UserDefaults.standard.object(forKey: key) as? Double)
    }
}
