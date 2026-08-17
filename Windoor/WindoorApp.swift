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
    private var permissionCoordinator: AccessibilityPermissionCoordinator?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Windoor monitors window interactions while its user interface is hidden."
        )
        permissionCoordinator = AccessibilityPermissionCoordinator(
            accessibilityManager: AccessibilityManager.shared,
            languageProvider: {
                AccessibilityManager.shared.settings?.language ?? .system
            }
        )

        // 言語変更通知を受け取る
        NotificationCenter.default.addObserver(self, selector: #selector(updateMenu), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updatePermissionGuideLanguage),
            name: .languageDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusItemVisibility),
            name: .menuBarIconVisibilityDidChange,
            object: nil
        )

        updateStatusItemVisibility()
        openSettings()
        permissionCoordinator?.start()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        openSettings()
        permissionCoordinator?.presentGuideIfNeeded()
        return true
    }

    @objc private func updateStatusItemVisibility() {
        guard let settings = AccessibilityManager.shared.settings else { return }

        if settings.showMenuBarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                if let button = item.button {
                    let icon = NSImage(named: "WindoorMenuBarIcon")
                    icon?.isTemplate = true
                    icon?.size = NSSize(width: 16, height: 16)
                    button.image = icon
                    button.imagePosition = .imageOnly
                    button.imageScaling = .scaleProportionallyUpOrDown
                }
                statusItem = item
            }
            updateMenu()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }
    
    // メニューの更新（多言語対応のため都度作り直す）
    @objc func updateMenu() {
        guard let settings = AccessibilityManager.shared.settings,
              let statusItem
        else { return }
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
        
        statusItem.menu = menu
    }
    
    @objc func openSettings() {
        NSApp.setActivationPolicy(.regular)

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
        window.delegate = self
        
        self.settingsWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === settingsWindow
        else { return }

        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionCoordinator?.stop()
    }

    @objc private func updatePermissionGuideLanguage() {
        permissionCoordinator?.languageDidChange()
    }
    
    @objc func terminateApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func restartApp() {
        AppRestartManager.restart()
    }
}
