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

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow? // ウィンドウの参照を保持
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AccessibilityManager.shared.startMonitoring()

        updateStatusItemVisibility()

        // 言語・メニューバーアイコン表示設定の変更を受け取る
        NotificationCenter.default.addObserver(self, selector: #selector(updateMenu), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusItemVisibility),
            name: .menuBarIconVisibilityDidChange,
            object: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let icon = NSImage(named: "WindoorMenuBarIcon")
            let menuBarIcon = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
                icon?.draw(
                    in: NSRect(x: 1, y: 1, width: 20, height: 20),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                return true
            }
            menuBarIcon.isTemplate = true
            button.image = menuBarIcon
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        }

        updateMenu()
    }

    @objc private func updateStatusItemVisibility() {
        let shouldShow = AccessibilityManager.shared.settings?.showMenuBarIcon ?? true
        if shouldShow {
            installStatusItemIfNeeded()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AccessibilityManager.shared.stopMonitoring()
    }
    
    // メニューの更新（多言語対応のため都度作り直す）
    @objc func updateMenu() {
        guard statusItem != nil else { return }
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
        NSApp.setActivationPolicy(.regular)

        // 既にウィンドウが存在する場合は表示するだけ
        if let window = settingsWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
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
        window.delegate = self
        
        self.settingsWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        openSettings()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    @objc func terminateApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func restartApp() {
        AppRestartManager.restart()
    }
}
