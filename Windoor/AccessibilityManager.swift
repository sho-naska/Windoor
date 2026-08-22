import Cocoa
import ApplicationServices

private let axMinSizeAttribute: CFString = "AXMinSize" as CFString
private let axMaxSizeAttribute: CFString = "AXMaxSize" as CFString

private struct CGWindowTarget {
    let processIdentifier: pid_t
    let frame: CGRect
}

private struct PendingWindowUpdate {
    let element: AXUIElement
    let frame: CGRect
    let mode: InteractionMode
    let generation: UInt
}

class AccessibilityManager {
    static let shared = AccessibilityManager()

    private let permissionCheckInterval: TimeInterval = 0.25
    private var permissionCheckTimer: Timer?
    private var isEventTapDeactivationScheduled = false
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // キーボード用 Event Tap（ショートカットのビープ音抑制 & 押下状態の追跡）
    private var keyboardEventTap: CFMachPort?
    private var keyboardRunLoopSource: CFRunLoopSource?
    
    // 握りつぶしたキーでも押下判定できるように自前で保持
    private var pressedKeyCodes: Set<Int> = []
    
    private var targetedElement: AXUIElement?
    private var activeMode: InteractionMode = .none
    private var activeMouseButton: MouseButton?
    private var activeResizeAnchorCorner: ResizeAnchorCorner = .topLeft
    private var minWindowSize: CGSize?
    private var maxWindowSize: CGSize?
    private var interactionEngine: WindowInteractionEngine?
    private var lastDragLocation: CGPoint?
    private var isCatchUpTickScheduled = false

    // AXへの書き込みをイベントごとに積まず、最新フレームだけにまとめる。
    private var pendingWindowUpdate: PendingWindowUpdate?
    private var isWindowUpdateScheduled = false
    private var interactionGeneration: UInt = 0
    private let updateInterval: TimeInterval = 1.0 / 120.0
    
    var settings: SettingsModel?

    func startMonitoring() {
        if permissionCheckTimer == nil {
            let timer = Timer(timeInterval: permissionCheckInterval, repeats: true) { [weak self] _ in
                self?.refreshMonitoringForAccessibilityPermission()
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionCheckTimer = timer
        }

        refreshMonitoringForAccessibilityPermission()
    }

    func stopMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        deactivateEventTaps()
    }

    private func refreshMonitoringForAccessibilityPermission() {
        if AXIsProcessTrusted() {
            guard eventTap == nil, keyboardEventTap == nil else { return }
            installEventTaps()
        } else {
            failOpenForAccessibilityPermissionLoss()
        }
    }

    private func installEventTaps() {
        // Permission can change between the periodic check and tap creation.
        guard AXIsProcessTrusted() else {
            failOpenForAccessibilityPermissionLoss()
            return
        }

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
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
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
                CFRunLoopAddSource(CFRunLoopGetMain(), keyboardRunLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: keyboardTap, enable: true)
        } else {
            // 失敗してもマウス機能は継続する（ビープ音抑制のみ無効）
            print("キーボードイベントタップ作成失敗（ビープ音抑制は無効）")
        }
    }

    /// Accessibility can be revoked while an active event tap is filtering input.
    /// Disable both taps immediately so the system input stream is never held up,
    /// then tear their run-loop sources down after the current callback returns.
    private func failOpenForAccessibilityPermissionLoss() {
        let hadEventTaps = eventTap != nil || keyboardEventTap != nil
        let hadPendingInteraction = targetedElement != nil || pendingWindowUpdate != nil
        guard hadEventTaps || hadPendingInteraction else { return }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: false)
        }
        cancelPendingInteraction()

        guard hadEventTaps, !isEventTapDeactivationScheduled
        else { return }

        isEventTapDeactivationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deactivateEventTaps()
            self.isEventTapDeactivationScheduled = false
        }
    }

    private func deactivateEventTaps() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: false)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let keyboardRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardRunLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(keyboardRunLoopSource)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let keyboardEventTap {
            CFMachPortInvalidate(keyboardEventTap)
        }

        eventTap = nil
        runLoopSource = nil
        keyboardEventTap = nil
        keyboardRunLoopSource = nil
        cancelPendingInteraction()
    }

    private func cancelPendingInteraction() {
        interactionGeneration &+= 1
        pendingWindowUpdate = nil
        isWindowUpdateScheduled = false
        pressedKeyCodes.removeAll()
        endAction()
    }

    private func handleKeyboard(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard AXIsProcessTrusted() else {
            failOpenForAccessibilityPermissionLoss()
            return Unmanaged.passUnretained(event)
        }

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
        guard AXIsProcessTrusted() else {
            failOpenForAccessibilityPermissionLoss()
            return Unmanaged.passUnretained(event)
        }

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
                if let element = getElementAtLocation(location),
                   let startPosition = getPosition(element),
                   let startSize = getSize(element) {
                    
                    if isResizeActive && !isResizable(element) {
                        if let pos = getPosition(element), let size = getSize(element) {
                            VisualEffectManager.shared.showEffect(frame: CGRect(origin: pos, size: size), mode: .error)
                        }
                        return nil
                    }

                    self.targetedElement = element
                    self.lastDragLocation = location
                    self.activeMode = isMoveActive ? .move : .resize
                    self.activeMouseButton = isMoveActive ? settings.moveSetting.mouseButton : settings.resizeSetting.mouseButton
                    self.minWindowSize = isResizeActive
                        ? protectedMinimumSize(for: element, windowFrame: CGRect(origin: startPosition, size: startSize))
                        : nil
                    self.maxWindowSize = isResizeActive ? getMaxSize(element) : nil
                    self.interactionGeneration &+= 1

                    let currentFrame = CGRect(origin: startPosition, size: startSize)
                    let resizeAnchorCorner = settings.resizeAnchorPoint.resolvedCorner(
                        in: currentFrame,
                        pointer: location
                    )
                    self.activeResizeAnchorCorner = resizeAnchorCorner
                    self.interactionEngine = WindowInteractionEngine(
                        mode: activeMode,
                        initialFrame: currentFrame,
                        initialPointer: location,
                        obstacleFrames: obstacleFrames(excluding: currentFrame, target: element),
                        timestamp: timestamp(of: event),
                        resizeAnchorCorner: resizeAnchorCorner
                    )

                    if !settings.preserveWindowOrder {
                        bringWindowToFront(element)
                    }

                    VisualEffectManager.shared.showEffect(frame: currentFrame, mode: activeMode)
                    
                    return nil
                }
            }
        }
        
        // ドラッグ処理
        else if isMouseDragged(type) {
            if let element = targetedElement,
               var engine = interactionEngine {
                
                guard activeMode != .none, dragEventMatchesActiveButton(type) else {
                    return Unmanaged.passUnretained(event)
                }
                
                let location = event.location
                var newFrame = engine.frame(
                    for: location,
                    timestamp: timestamp(of: event),
                    constraint: .none
                )
                interactionEngine = engine
                lastDragLocation = location

                if activeMode == .resize {
                    newFrame = activeResizeAnchorCorner.frame(
                        size: clampSize(newFrame.size),
                        anchoredIn: engine.initialFrame
                    )
                }
                scheduleWindowUpdate(
                    element: element,
                    frame: newFrame,
                    mode: activeMode
                )
                scheduleCatchUpTickIfNeeded(element: element)
                
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
        activeMode = .none
        activeMouseButton = nil
        activeResizeAnchorCorner = .topLeft
        minWindowSize = nil
        maxWindowSize = nil
        interactionEngine = nil
        lastDragLocation = nil
        isCatchUpTickScheduled = false
        VisualEffectManager.shared.hideEffect()
    }

    private func timestamp(of event: CGEvent) -> TimeInterval {
        TimeInterval(event.timestamp) / 1_000_000_000
    }

    private func scheduleWindowUpdate(
        element: AXUIElement,
        frame: CGRect,
        mode: InteractionMode
    ) {
        pendingWindowUpdate = PendingWindowUpdate(
            element: element,
            frame: frame,
            mode: mode,
            generation: interactionGeneration
        )
        guard !isWindowUpdateScheduled else { return }

        isWindowUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + updateInterval) { [weak self] in
            self?.applyPendingWindowUpdate()
        }
    }

    private func applyPendingWindowUpdate() {
        isWindowUpdateScheduled = false
        guard AXIsProcessTrusted() else {
            failOpenForAccessibilityPermissionLoss()
            return
        }
        guard let update = pendingWindowUpdate else { return }
        pendingWindowUpdate = nil
        guard update.generation == interactionGeneration else { return }

        let succeeded: Bool
        switch update.mode {
        case .move:
            succeeded = setPosition(update.element, position: update.frame.origin)
        case .resize:
            let resized = setSize(update.element, size: update.frame.size)
            // Some cross-platform apps move their frame origin while handling AXSize.
            // Restore the origin derived from the selected fixed anchor afterwards.
            _ = setPosition(update.element, position: update.frame.origin)
            succeeded = resized
        case .error, .none:
            succeeded = false
        }

        if succeeded, targetedElement != nil, update.generation == interactionGeneration {
            VisualEffectManager.shared.updateFrame(update.frame)
        }

        if pendingWindowUpdate != nil {
            isWindowUpdateScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + updateInterval) { [weak self] in
                self?.applyPendingWindowUpdate()
            }
        }
    }

    private func scheduleCatchUpTickIfNeeded(element: AXUIElement) {
        guard interactionEngine?.needsCatchUp == true, !isCatchUpTickScheduled else { return }
        let generation = interactionGeneration
        isCatchUpTickScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + updateInterval) { [weak self] in
            guard let self else { return }
            guard generation == self.interactionGeneration else { return }
            self.isCatchUpTickScheduled = false
            guard self.targetedElement != nil,
                  let location = self.lastDragLocation,
                  var engine = self.interactionEngine,
                  engine.needsCatchUp
            else { return }

            var frame = engine.frame(
                for: location,
                timestamp: ProcessInfo.processInfo.systemUptime,
                constraint: .none
            )
            self.interactionEngine = engine
            if self.activeMode == .resize {
                frame = self.activeResizeAnchorCorner.frame(
                    size: self.clampSize(frame.size),
                    anchoredIn: engine.initialFrame
                )
            }
            self.scheduleWindowUpdate(
                element: element,
                frame: frame,
                mode: self.activeMode
            )
            self.scheduleCatchUpTickIfNeeded(element: element)
        }
    }
    
    private func shouldActivate(setting: ShortcutSetting, flags: CGEventFlags, isEnabled: Bool, eventType: CGEventType) -> Bool {
        guard isEnabled, setting.hasKeyboardTrigger else { return false }
        
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
        guard let frontmostWindow = frontmostCGWindow(at: location) else { return nil }

        let application = AXUIElementCreateApplication(frontmostWindow.processIdentifier)
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            application,
            Float(location.x),
            Float(location.y),
            &element
        )
        if result == .success,
           let element,
           let window = getWindow(from: element),
           matchesFrontmostWindow(window, target: frontmostWindow) {
            return window
        }

        return applicationWindow(
            processIdentifier: frontmostWindow.processIdentifier,
            at: location,
            matching: frontmostWindow.frame
        )
    }

    private func getWindow(from element: AXUIElement) -> AXUIElement? {
        if let window = copyElementAttribute(kAXWindowAttribute as CFString, from: element) {
            return window
        }
        if let topLevel = copyElementAttribute(kAXTopLevelUIElementAttribute as CFString, from: element),
           role(of: topLevel) == kAXWindowRole as String {
            return topLevel
        }

        var currentElement = element
        for _ in 0..<64 {
            if role(of: currentElement) == kAXWindowRole as String {
                return currentElement
            }
            var parent: AnyObject?
            let result = AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parent)
            guard result == .success, let parent else { break }
            currentElement = parent as! AXUIElement
        }
        return nil
    }

    private func role(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private func applicationWindow(
        processIdentifier: pid_t,
        at location: CGPoint,
        matching preferredFrame: CGRect?
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }

        let candidates = windows.compactMap { window -> (AXUIElement, CGRect)? in
            guard let position = getPosition(window), let size = getSize(window) else { return nil }
            let frame = CGRect(origin: position, size: size)
            guard frame.insetBy(dx: -2, dy: -2).contains(location) else { return nil }
            return (window, frame)
        }

        if let preferredFrame {
            guard let closest = candidates.min(by: { lhs, rhs in
                frameDistance(lhs.1, preferredFrame) < frameDistance(rhs.1, preferredFrame)
            }), framesReferToSameWindow(closest.1, preferredFrame)
            else { return nil }
            return closest.0
        }
        return candidates.min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }

    private func matchesFrontmostWindow(_ element: AXUIElement, target: CGWindowTarget) -> Bool {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == target.processIdentifier,
              let position = getPosition(element),
              let size = getSize(element)
        else { return false }
        return framesReferToSameWindow(CGRect(origin: position, size: size), target.frame)
    }

    private func framesReferToSameWindow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let originTolerance: CGFloat = 12
        let sizeTolerance: CGFloat = 24
        return abs(lhs.minX - rhs.minX) <= originTolerance &&
            abs(lhs.minY - rhs.minY) <= originTolerance &&
            abs(lhs.width - rhs.width) <= sizeTolerance &&
            abs(lhs.height - rhs.height) <= sizeTolerance
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY) +
            abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func frontmostCGWindow(at location: CGPoint) -> CGWindowTarget? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }

        for window in windows {
            guard let processIdentifierValue = window[kCGWindowOwnerPID] as? NSNumber,
                  let layer = (window[kCGWindowLayer] as? NSNumber)?.intValue,
                  layer >= NSWindow.Level.normal.rawValue,
                  layer <= NSWindow.Level.modalPanel.rawValue,
                  let alpha = (window[kCGWindowAlpha] as? NSNumber)?.doubleValue,
                  alpha > 0,
                  let frame = cgWindowFrame(from: window),
                  frame.width > 0,
                  frame.height > 0,
                  frame.contains(location)
            else { continue }
            return CGWindowTarget(
                processIdentifier: processIdentifierValue.int32Value,
                frame: frame
            )
        }
        return nil
    }

    private func cgWindowFrame(from window: [CFString: Any]) -> CGRect? {
        guard let bounds = window[kCGWindowBounds] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as! CFDictionary)
    }
    
    private func getPosition(_ element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
    
    private func getSize(_ element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func bringWindowToFront(_ element: AXUIElement) {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           let application = NSRunningApplication(processIdentifier: pid) {
            application.activate()
        }

        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    private func obstacleFrames(excluding targetFrame: CGRect, target: AXUIElement) -> [CGRect] {
        var targetPID: pid_t = 0
        _ = AXUIElementGetPid(target, &targetPID)

        var frames: [CGRect] = []
        if let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] {
            for window in windows {
                guard let layer = (window[kCGWindowLayer] as? NSNumber)?.intValue, layer == 0,
                      let frame = cgWindowFrame(from: window),
                      frame.width >= 40,
                      frame.height >= 24
                else { continue }

                let ownerPID = (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value
                if ownerPID == getpid() { continue }
                if ownerPID == targetPID, frameDistance(frame, targetFrame) < 4 { continue }
                if frameDistance(frame, targetFrame) < 1 { continue }
                frames.append(frame)
            }
        }

        return frames
    }

    private func protectedMinimumSize(for element: AXUIElement, windowFrame: CGRect) -> CGSize? {
        var result = getMinSize(element) ?? .zero
        let controlAttributes: [CFString] = [
            kAXCloseButtonAttribute as CFString,
            kAXMinimizeButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXFullScreenButtonAttribute as CFString
        ]

        var foundTrafficLight = false
        for attribute in controlAttributes {
            guard let button = copyElementAttribute(attribute, from: element),
                  let position = getPosition(button),
                  let size = getSize(button)
            else { continue }

            foundTrafficLight = true
            let localMaximumX = position.x + size.width - windowFrame.minX
            let localMaximumY = position.y + size.height - windowFrame.minY
            result.width = max(result.width, localMaximumX + 12)
            result.height = max(result.height, localMaximumY + 12)
        }

        if foundTrafficLight {
            result.width = max(result.width, 96)
            result.height = max(result.height, 48)
        }
        return result == .zero ? nil : result
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
        if let maxSize = maxWindowSize {
            clamped.width = min(clamped.width, maxSize.width)
            clamped.height = min(clamped.height, maxSize.height)
        }
        if let minSize = minWindowSize {
            clamped.width = max(clamped.width, minSize.width)
            clamped.height = max(clamped.height, minSize.height)
        } else {
            clamped.width = max(clamped.width, 1)
            clamped.height = max(clamped.height, 1)
        }
        return clamped
    }

}
