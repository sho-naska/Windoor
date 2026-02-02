import Foundation
import ServiceManagement

class LoginItemManager {
    static let shared = LoginItemManager()
    
    private init() {}
    
    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                print("Failed to update login item state: \(error)")
            }
        } else {
            // macOS 13 未満では SMAppService.mainApp が使えないため、
            // ここではログ出力のみ行う（別途 Login Item Helper を用意する必要あり）
            print("Launch at login is not supported on this macOS version with SMAppService.mainApp.")
        }
    }
    
    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return false
        }
    }
}
