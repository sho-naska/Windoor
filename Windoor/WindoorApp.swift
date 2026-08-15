import SwiftUI

@main
struct WindoorApp: App {
    @StateObject private var settings: SettingsModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // 設定ウィンドウとして定義（空ウィンドウの自動表示を防ぐ）
        Settings {
            EmptyView()
        }
    }
    
    init() {
        let settingsModel = SettingsModel()
        _settings = StateObject(wrappedValue: settingsModel)
        AccessibilityManager.shared.settings = settingsModel
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow? // ウィンドウの参照を保持
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AccessibilityManager.shared.startMonitoring()
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            let icon = NSImage(named: "WindoorMenuBarIcon")
            icon?.isTemplate = true
            icon?.size = NSSize(width: 18, height: 18)
            button.image = icon
        }
        
        updateMenu()
        
        // 言語変更通知を受け取る
        NotificationCenter.default.addObserver(self, selector: #selector(updateMenu), name: .languageDidChange, object: nil)
    }
    
    // メニューの更新（多言語対応のため都度作り直す）
    @objc func updateMenu() {
        let settings = AccessibilityManager.shared.settings ?? SettingsModel()
        let lang = settings.language
        
        let menu = NSMenu()
        
        let settingsTitle = LocalizationManager.shared.text("menuSettings", language: lang)
        let settingsItem = NSMenuItem(title: settingsTitle, action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)

        let restartTitle = LocalizationManager.shared.text("menuRestart", language: lang)
        let restartItem = NSMenuItem(title: restartTitle, action: #selector(restartApp), keyEquivalent: "r")
        if let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil) {
            restartItem.image = image.windoorMenuIcon()
        }
        menu.addItem(restartItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitTitle = LocalizationManager.shared.text("menuQuit", language: lang)
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(terminateApp), keyEquivalent: "q")
        if let image = NSImage(systemSymbolName: "power", accessibilityDescription: nil) {
            quitItem.image = image.windoorMenuIcon()
        }
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc func openSettings() {
        // 既にウィンドウが存在する場合は表示するだけ
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // 新しく作成
        let settings = AccessibilityManager.shared.settings ?? SettingsModel()
        let hostingController = NSHostingController(rootView: SettingsView(settings: settings))
        
        let window = NSWindow(contentViewController: hostingController)
        let title = LocalizationManager.shared.text("windowTitle", language: settings.language)
        window.title = title
        
        window.setContentSize(NSSize(
            width: WindoorDesign.Layout.settingsWidth,
            height: WindoorDesign.Layout.settingsHeight
        ))
        
        // リサイズ不可、閉じた時にメモリ解放せず保持する
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false
        
        // 閉じた時のデリゲート処理（もし必要なら）だが、isReleasedWhenClosed = falseなので参照は残る
        
        self.settingsWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func terminateApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func restartApp() {
        AppRestartManager.restart()
    }
}
