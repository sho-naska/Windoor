import AppKit

enum AppRestartManager {
    static func restart() {
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            // 失敗しても既存アプリは終了処理へ進む
        }
        NSApplication.shared.terminate(nil)
    }
}
