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
        return flags == 0 && keyCode == -1
    }
}

// 言語変更通知用の名前
extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
}

class SettingsModel: ObservableObject {
    @Published var isMoveEnabled: Bool {
        didSet { save(isMoveEnabled, key: "isMoveEnabled") }
    }
    
    @Published var isResizeEnabled: Bool {
        didSet { save(isResizeEnabled, key: "isResizeEnabled") }
    }
    
    @Published var isRecording: Bool = false
    
    @Published var recordingTimeout: Double {
        didSet { save(recordingTimeout, key: "recordingTimeout") }
    }
    
    @Published var language: AppLanguage {
        didSet {
            save(language, key: "language")
            // 言語が変更されたら通知を送る（メニューバー更新用）
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }
    
    @Published var moveSetting: ShortcutSetting {
        didSet { save(moveSetting, key: "moveSetting") }
    }
    
    @Published var resizeSetting: ShortcutSetting {
        didSet { save(resizeSetting, key: "resizeSetting") }
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
        self.isMoveEnabled = UserDefaults.standard.object(forKey: "isMoveEnabled") as? Bool ?? true
        self.isResizeEnabled = UserDefaults.standard.object(forKey: "isResizeEnabled") as? Bool ?? true
        self.recordingTimeout = UserDefaults.standard.object(forKey: "recordingTimeout") as? Double ?? 1.5
        
        if let langData = UserDefaults.standard.data(forKey: "language"),
           let lang = try? JSONDecoder().decode(AppLanguage.self, from: langData) {
            self.language = lang
        } else {
            self.language = .system
        }
        
        let defaultMove = ShortcutSetting(keyCode: -1, flags: NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.command.rawValue, mouseButton: .left, allowModifierOnly: true)
        let defaultResize = ShortcutSetting(keyCode: -1, flags: NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.command.rawValue, mouseButton: .left, allowModifierOnly: true)
        
        self.moveSetting = SettingsModel.load(key: "moveSetting", type: ShortcutSetting.self) ?? defaultMove
        self.resizeSetting = SettingsModel.load(key: "resizeSetting", type: ShortcutSetting.self) ?? defaultResize
        
        // launchAtLogin 初期値: 保存済みがあればそれを使用、なければシステム状態から取得
        if let stored = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool {
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
}
