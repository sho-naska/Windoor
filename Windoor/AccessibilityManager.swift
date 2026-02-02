import Cocoa
import ApplicationServices

class AccessibilityManager {
    static let shared = AccessibilityManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // キーボード用 Event Tap（ショートカットのビープ音抑制 & 押下状態の追跡）
    private var keyboardEventTap: CFMachPort?
    private var keyboardRunLoopSource: CFRunLoopSource?
    
    // 握りつぶしたキーでも押下判定できるように自前で保持
    private var pressedKeyCodes: Set<Int> = []
    
    private var targetedElement: AXUIElement?
    private var startDragLocation: CGPoint?
    private var startWindowPosition: CGPoint?
    private var startWindowSize: CGSize?
    
    // パフォーマンス対策
    private var lastUpdateTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 0.016
    
    var settings: SettingsModel?

    func startMonitoring() {
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.leftMouseDragged.rawValue) |
                        (1 << CGEventType.leftMouseUp.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDragged.rawValue) |
                        (1 << CGEventType.rightMouseUp.rawValue) |
                        (1 << CGEventType.otherMouseDown.rawValue) |
                        (1 << CGEventType.otherMouseDragged.rawValue) |
                        (1 << CGEventType.otherMouseUp.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                return AccessibilityManager.shared.handle(event: event, type: type)
            },
            userInfo: nil
        ) else {
            print("イベントタップ作成失敗")
            return
        }

        self.eventTap = eventTap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource = self.runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)

        // キーボード（keyDown / keyUp）を監視して、設定ショートカットに一致する入力だけを握りつぶす。
        // その際、押下状態を自前で追跡することで、キーイベントを抑止しても移動/リサイズ判定が動作するようにする。
        let keyMask = (1 << CGEventType.keyDown.rawValue) |
                      (1 << CGEventType.keyUp.rawValue)

        if let keyboardTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(keyMask),
            callback: { (_, type, event, _) -> Unmanaged<CGEvent>? in
                return AccessibilityManager.shared.handleKeyboard(event: event, type: type)
            },
            userInfo: nil
        ) {
            self.keyboardEventTap = keyboardTap
            self.keyboardRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyboardTap, 0)
            if let keyboardRunLoopSource = self.keyboardRunLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), keyboardRunLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: keyboardTap, enable: true)
        } else {
            // 失敗してもマウス機能は継続する（ビープ音抑制のみ無効）
            print("キーボードイベントタップ作成失敗（ビープ音抑制は無効）")
        }
    }

    private func handleKeyboard(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // 押下状態の追跡（Event Tap でイベントを握りつぶす場合でも判定できるようにする）
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            pressedKeyCodes.insert(keyCode)
        } else if type == .keyUp {
            pressedKeyCodes.remove(keyCode)
        }

        guard let settings = settings,
              !settings.isRecording,
              !settings.hasConflict
        else {
            return Unmanaged.passUnretained(event)
        }

        // 「修飾キー + 通常キー」の設定に一致した場合だけ、前面アプリに届かないよう握りつぶしてビープ音を防ぐ
        let flags = event.flags

        let shouldSwallowMove =
            settings.isMoveEnabled &&
            settings.moveSetting.keyCode >= 0 &&
            settings.moveSetting.matches(eventFlags: flags, eventKeyCode: Int64(keyCode))

        let shouldSwallowResize =
            settings.isResizeEnabled &&
            settings.resizeSetting.keyCode >= 0 &&
            settings.resizeSetting.matches(eventFlags: flags, eventKeyCode: Int64(keyCode))

        if shouldSwallowMove || shouldSwallowResize {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard let settings = settings,
              !settings.isRecording,
              !settings.hasConflict
        else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        
        let isMoveActive = shouldActivate(setting: settings.moveSetting, flags: flags, isEnabled: settings.isMoveEnabled, eventType: type, event: event)
        let isResizeActive = shouldActivate(setting: settings.resizeSetting, flags: flags, isEnabled: settings.isResizeEnabled, eventType: type, event: event)

        // マウスダウン処理
        if isMouseDown(type) {
            if isMoveActive || isResizeActive {
                let location = event.location
                if let element = getElementAtLocation(location) {
                    
                    if isResizeActive && !isResizable(element) {
                        if let pos = getPosition(element), let size = getSize(element) {
                            VisualEffectManager.shared.showEffect(frame: CGRect(origin: pos, size: size), mode: .error)
                        }
                        return nil
                    }

                    self.targetedElement = element
                    self.startDragLocation = location
                    self.startWindowPosition = getPosition(element)
                    self.startWindowSize = getSize(element)
                    self.lastUpdateTime = 0
                    
                    if let startPos = startWindowPosition, let startSize = startWindowSize {
                        let currentFrame = CGRect(origin: startPos, size: startSize)
                        let mode: InteractionMode = isMoveActive ? .move : .resize
                        VisualEffectManager.shared.showEffect(frame: currentFrame, mode: mode)
                    }
                    
                    return nil
                }
            }
        }
        
        // ドラッグ処理
        else if isMouseDragged(type) {
            if let element = targetedElement, let startLocation = startDragLocation,
               let startPos = startWindowPosition, let startSize = startWindowSize {
                
                // スロットリング
                let currentTime = Date().timeIntervalSince1970
                if currentTime - lastUpdateTime < updateInterval {
                    return nil
                }
                lastUpdateTime = currentTime
                
                let location = event.location
                let deltaX = location.x - startLocation.x
                let deltaY = location.y - startLocation.y
                
                // 移動処理
                if shouldActivate(setting: settings.moveSetting, flags: flags, isEnabled: settings.isMoveEnabled, eventType: type, event: event, checkButtonOnly: true) {
                    let newPoint = CGPoint(x: startPos.x + deltaX, y: startPos.y + deltaY)
                    setPosition(element, position: newPoint)
                    
                    // セット後に実際のウィンドウ位置を取得して枠線に反映（ズレ防止）
                    if let actualPos = getPosition(element), let actualSize = getSize(element) {
                        let actualRect = CGRect(origin: actualPos, size: actualSize)
                        VisualEffectManager.shared.updateFrame(actualRect)
                    }
                }
                // リサイズ処理
                else if shouldActivate(setting: settings.resizeSetting, flags: flags, isEnabled: settings.isResizeEnabled, eventType: type, event: event, checkButtonOnly: true) {
                    let newSize = CGSize(width: startSize.width + deltaX, height: startSize.height + deltaY)
                    setSize(element, size: newSize)
                    
                    // セット後に実際のウィンドウサイズを取得して枠線に反映（ズレ防止）
                    // ウィンドウが最小/最大サイズ制限で止まった場合、ここでの取得値も止まるため枠線も止まる
                    if let actualPos = getPosition(element), let actualSize = getSize(element) {
                        let actualRect = CGRect(origin: actualPos, size: actualSize)
                        VisualEffectManager.shared.updateFrame(actualRect)
                    }
                } else {
                    endAction()
                    return Unmanaged.passUnretained(event)
                }
                
                return nil
            }
        }
        
        // マウスアップ処理
        else if isMouseUp(type) {
            if targetedElement != nil {
                endAction()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }
    
    private func endAction() {
        targetedElement = nil
        startDragLocation = nil
        startWindowPosition = nil
        startWindowSize = nil
        VisualEffectManager.shared.hideEffect()
    }
    
    private func shouldActivate(setting: ShortcutSetting, flags: CGEventFlags, isEnabled: Bool, eventType: CGEventType, event: CGEvent, checkButtonOnly: Bool = false) -> Bool {
        guard isEnabled else { return false }
        
        let buttonMatches: Bool
        switch setting.mouseButton {
        case .left:
            buttonMatches = (eventType == .leftMouseDown || eventType == .leftMouseDragged)
        case .right:
            buttonMatches = (eventType == .rightMouseDown || eventType == .rightMouseDragged)
        case .center:
            buttonMatches = (eventType == .otherMouseDown || eventType == .otherMouseDragged)
        }
        
        if !buttonMatches { return false }
        
        if setting.keyCode >= 0 {
            let isKeyPressed = pressedKeyCodes.contains(setting.keyCode) ||
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(setting.keyCode))
            return isKeyPressed && setting.matches(eventFlags: flags, eventKeyCode: Int64(setting.keyCode))
        } else {
            return setting.matches(eventFlags: flags, eventKeyCode: nil)
        }
    }

    private func isMouseDown(_ type: CGEventType) -> Bool {
        return type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }
    
    private func isMouseDragged(_ type: CGEventType) -> Bool {
        return type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
    }
    
    private func isMouseUp(_ type: CGEventType) -> Bool {
        return type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
    }
    
    private func getElementAtLocation(_ location: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &element)
        if result == .success, let element = element {
            return getWindow(from: element)
        }
        return nil
    }

    private func getWindow(from element: AXUIElement) -> AXUIElement? {
        var currentElement = element
        while true {
            var role: AnyObject?
            AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &role)
            if let role = role as? String, role == kAXWindowRole { return currentElement }
            var parent: AnyObject?
            let result = AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parent)
            if result == .success, let parentElement = parent {
                currentElement = (parentElement as! AXUIElement)
            } else { break }
        }
        return nil
    }
    
    private func getPosition(_ element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        var point = CGPoint.zero
        if let value = value {
            AXValueGetValue(value as! AXValue, .cgPoint, &point)
            return point
        }
        return nil
    }
    
    private func getSize(_ element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        var size = CGSize.zero
        if let value = value {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
            return size
        }
        return nil
    }
    
    private func setPosition(_ element: AXUIElement, position: CGPoint) {
        var position = position
        if let value = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }
    
    private func setSize(_ element: AXUIElement, size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }
    
    private func isResizable(_ element: AXUIElement) -> Bool {
        var writable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &writable)
        return writable.boolValue
    }
}
