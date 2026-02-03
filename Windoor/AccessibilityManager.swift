import Cocoa
import ApplicationServices

private let axMinSizeAttribute: CFString = "AXMinSize" as CFString
private let axMaxSizeAttribute: CFString = "AXMaxSize" as CFString

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
    private var activeMode: InteractionMode = .none
    private var activeMouseButton: MouseButton?
    private var minWindowSize: CGSize?
    private var maxWindowSize: CGSize?
    
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
            tap: .cgSessionEventTap,
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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyboardEventTap = keyboardEventTap {
                CGEvent.tapEnable(tap: keyboardEventTap, enable: true)
            }
            pressedKeyCodes.removeAll()
            return nil
        }
        
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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            endAction()
            return nil
        }
        
        guard let settings = settings,
              !settings.isRecording,
              !settings.hasConflict
        else {
            return Unmanaged.passUnretained(event)
        }

        // マウスダウン処理
        if isMouseDown(type) {
            let flags = event.flags
            let isMoveActive = shouldActivate(setting: settings.moveSetting, flags: flags, isEnabled: settings.isMoveEnabled, eventType: type)
            let isResizeActive = shouldActivate(setting: settings.resizeSetting, flags: flags, isEnabled: settings.isResizeEnabled, eventType: type)
            
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
                    self.activeMode = isMoveActive ? .move : .resize
                    self.activeMouseButton = isMoveActive ? settings.moveSetting.mouseButton : settings.resizeSetting.mouseButton
                    self.minWindowSize = isResizeActive ? getMinSize(element) : nil
                    self.maxWindowSize = isResizeActive ? getMaxSize(element) : nil
                    self.lastUpdateTime = 0
                    
                    if let startPos = startWindowPosition, let startSize = startWindowSize {
                        let currentFrame = CGRect(origin: startPos, size: startSize)
                        VisualEffectManager.shared.showEffect(frame: currentFrame, mode: activeMode)
                    } else {
                        endAction()
                    }
                    
                    return nil
                }
            }
        }
        
        // ドラッグ処理
        else if isMouseDragged(type) {
            if let element = targetedElement, let startLocation = startDragLocation,
               let startPos = startWindowPosition, let startSize = startWindowSize {
                
                guard activeMode != .none, dragEventMatchesActiveButton(type) else {
                    return Unmanaged.passUnretained(event)
                }
                
                // スロットリング
                let currentTime = Date().timeIntervalSince1970
                if currentTime - lastUpdateTime < updateInterval {
                    return nil
                }
                lastUpdateTime = currentTime
                
                let location = event.location
                let deltaX = location.x - startLocation.x
                let deltaY = location.y - startLocation.y
                
                switch activeMode {
                case .move:
                    let newPoint = CGPoint(x: startPos.x + deltaX, y: startPos.y + deltaY)
                    if setPosition(element, position: newPoint) {
                        let newFrame = CGRect(origin: newPoint, size: startSize)
                        VisualEffectManager.shared.updateFrame(newFrame)
                    }
                case .resize:
                    let rawSize = CGSize(width: startSize.width + deltaX, height: startSize.height + deltaY)
                    let newSize = clampSize(rawSize)
                    if setSize(element, size: newSize) {
                        let newFrame = CGRect(origin: startPos, size: newSize)
                        VisualEffectManager.shared.updateFrame(newFrame)
                    }
                default:
                    break
                }
                
                return nil
            }
        }
        
        // マウスアップ処理
        else if isMouseUp(type) {
            if targetedElement != nil && mouseUpMatchesActiveButton(type) {
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
        activeMode = .none
        activeMouseButton = nil
        minWindowSize = nil
        maxWindowSize = nil
        VisualEffectManager.shared.hideEffect()
    }
    
    private func shouldActivate(setting: ShortcutSetting, flags: CGEventFlags, isEnabled: Bool, eventType: CGEventType) -> Bool {
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
    
    private func setPosition(_ element: AXUIElement, position: CGPoint) -> Bool {
        var position = position
        if let value = AXValueCreate(.cgPoint, &position) {
            return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
        }
        return false
    }
    
    private func setSize(_ element: AXUIElement, size: CGSize) -> Bool {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
        }
        return false
    }
    
    private func isResizable(_ element: AXUIElement) -> Bool {
        var writable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &writable)
        return writable.boolValue
    }

    private func dragEventMatchesActiveButton(_ type: CGEventType) -> Bool {
        guard let button = activeMouseButton else { return false }
        switch button {
        case .left:
            return type == .leftMouseDragged
        case .right:
            return type == .rightMouseDragged
        case .center:
            return type == .otherMouseDragged
        }
    }

    private func mouseUpMatchesActiveButton(_ type: CGEventType) -> Bool {
        guard let button = activeMouseButton else { return true }
        switch button {
        case .left:
            return type == .leftMouseUp
        case .right:
            return type == .rightMouseUp
        case .center:
            return type == .otherMouseUp
        }
    }

    private func getMinSize(_ element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, axMinSizeAttribute, &value)
        guard result == .success, let value = value else { return nil }
        var size = CGSize.zero
        if AXValueGetValue(value as! AXValue, .cgSize, &size) {
            if size.width <= 0 || size.height <= 0 { return nil }
            return size
        }
        return nil
    }

    private func getMaxSize(_ element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, axMaxSizeAttribute, &value)
        guard result == .success, let value = value else { return nil }
        var size = CGSize.zero
        if AXValueGetValue(value as! AXValue, .cgSize, &size) {
            if size.width <= 0 || size.height <= 0 { return nil }
            return size
        }
        return nil
    }

    private func clampSize(_ size: CGSize) -> CGSize {
        var clamped = size
        if let minSize = minWindowSize {
            clamped.width = max(clamped.width, minSize.width)
            clamped.height = max(clamped.height, minSize.height)
        } else {
            clamped.width = max(clamped.width, 1)
            clamped.height = max(clamped.height, 1)
        }
        if let maxSize = maxWindowSize {
            clamped.width = min(clamped.width, maxSize.width)
            clamped.height = min(clamped.height, maxSize.height)
        }
        return clamped
    }

}
