import Cocoa
import ApplicationServices

private let axMinSizeAttribute: CFString = "AXMinSize" as CFString
private let axMaxSizeAttribute: CFString = "AXMaxSize" as CFString

/// A window from `CGWindowListCopyWindowInfo`, which is already ordered front-to-back.
struct WindowHitTestCandidate {
    let processIdentifier: pid_t
    let frame: CGRect
    let layer: Int
    let alpha: CGFloat
    let identifier: CGWindowID

    init(
        processIdentifier: pid_t,
        frame: CGRect,
        layer: Int,
        alpha: CGFloat,
        identifier: CGWindowID = kCGNullWindowID
    ) {
        self.processIdentifier = processIdentifier
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.identifier = identifier
    }
}

enum WindowHitTester {
    static func frontmostCandidate(
        at location: CGPoint,
        candidates: [WindowHitTestCandidate],
        displayFrames: [CGRect] = []
    ) -> WindowHitTestCandidate? {
        candidates.first { candidate in
            candidate.alpha > 0 &&
                !isDisplaySizedOverlay(candidate, displayFrames: displayFrames) &&
                candidate.frame.contains(location)
        }
    }

    static func framesLikelyMatch(_ accessibilityFrame: CGRect, _ windowServerFrame: CGRect) -> Bool {
        guard accessibilityFrame.width > 0,
              accessibilityFrame.height > 0,
              windowServerFrame.width > 0,
              windowServerFrame.height > 0
        else { return false }

        let edgeDifference = abs(accessibilityFrame.minX - windowServerFrame.minX) +
            abs(accessibilityFrame.minY - windowServerFrame.minY) +
            abs(accessibilityFrame.width - windowServerFrame.width) +
            abs(accessibilityFrame.height - windowServerFrame.height)
        if edgeDifference <= 64 { return true }

        let intersection = accessibilityFrame.intersection(windowServerFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return false }

        let accessibilityArea = accessibilityFrame.width * accessibilityFrame.height
        let windowServerArea = windowServerFrame.width * windowServerFrame.height
        let smallerArea = min(accessibilityArea, windowServerArea)
        let widthRatio = min(accessibilityFrame.width, windowServerFrame.width) /
            max(accessibilityFrame.width, windowServerFrame.width)
        let heightRatio = min(accessibilityFrame.height, windowServerFrame.height) /
            max(accessibilityFrame.height, windowServerFrame.height)
        let overlapRatio = intersection.width * intersection.height / smallerArea

        // A large parent window may fully contain a small floating panel. Requiring
        // comparable dimensions prevents that parent from being selected through it.
        return widthRatio >= 0.65 && heightRatio >= 0.65 && overlapRatio >= 0.75
    }

    private static func isDisplaySizedOverlay(
        _ candidate: WindowHitTestCandidate,
        displayFrames: [CGRect]
    ) -> Bool {
        guard candidate.layer != 0 else { return false }

        return displayFrames.contains { displayFrame in
            abs(candidate.frame.minX - displayFrame.minX) <= 1 &&
                abs(candidate.frame.minY - displayFrame.minY) <= 1 &&
                abs(candidate.frame.width - displayFrame.width) <= 1 &&
                abs(candidate.frame.height - displayFrame.height) <= 1
        }
    }
}

enum EventTapCallbackDecision: Equatable {
    case passThrough
    case ignoreDisabledNotification
    case permissionLost
    case rebuild
    case handle
}

enum EventTapCallbackPolicy {
    static func decision(
        callbackGeneration: UInt,
        currentGeneration: UInt,
        acceptsEvents: Bool,
        isTrusted: Bool,
        isDisabledNotification: Bool
    ) -> EventTapCallbackDecision {
        guard callbackGeneration == currentGeneration, acceptsEvents else {
            return isDisabledNotification ? .ignoreDisabledNotification : .passThrough
        }
        guard isTrusted else { return .permissionLost }
        return isDisabledNotification ? .rebuild : .handle
    }
}

enum WindowFrontingPolicy {
    static func shouldRetry(frontmostResult: AXError, raiseResult: AXError) -> Bool {
        shouldRetry(error: frontmostResult) || shouldRetry(error: raiseResult)
    }

    static func shouldRetry(error: AXError) -> Bool {
        error == .cannotComplete || error == .failure
    }
}

private struct PendingWindowUpdate {
    let target: WindowTarget
    let frame: CGRect
    let mode: InteractionMode
    let resizePosition: CGPoint
    let requiresResizePositionUpdate: Bool
    let generation: UInt
}

private enum WindowTarget {
    case accessibility(AXUIElement)
    case native(NSWindow)
}

private struct ResolvedWindowTarget {
    let target: WindowTarget
    let frame: CGRect
    let processIdentifier: pid_t
}

private struct AXQueryBudget {
    private let deadline: TimeInterval
    private var remainingQueries: Int

    init(duration: TimeInterval, maximumQueries: Int) {
        deadline = ProcessInfo.processInfo.systemUptime + duration
        remainingQueries = maximumQueries
    }

    mutating func take() -> Bool {
        guard remainingQueries > 0,
              ProcessInfo.processInfo.systemUptime < deadline
        else { return false }
        remainingQueries -= 1
        return true
    }
}

private final class ActiveTapWatchdogToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false

    func finish() {
        lock.lock()
        isFinished = true
        lock.unlock()
    }

    func claimIfPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        return true
    }
}

private final class EventTapContext {
    weak var manager: AccessibilityManager?
    let generation: UInt

    init(manager: AccessibilityManager, generation: UInt) {
        self.manager = manager
        self.generation = generation
    }
}

class AccessibilityManager {
    static let shared = AccessibilityManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // キーボード用の受動 Event Tap（ショートカット押下状態の追跡）
    private var keyboardEventTap: CFMachPort?
    private var keyboardRunLoopSource: CFRunLoopSource?
    private var mouseTapContext: EventTapContext?
    private var keyboardTapContext: EventTapContext?
    private var retiredTapContexts: [EventTapContext] = []
    private var monitoringRunLoop: CFRunLoop?
    private var keyboardRetryWorkItem: DispatchWorkItem?
    private var keyboardRetryAttempt = 0
    private let callbackWatchdogQueue = DispatchQueue(
        label: "com.naska.Windoor.event-tap-watchdog",
        qos: .userInteractive
    )
    private var timeoutRecoveryWorkItem: DispatchWorkItem?
    private var timeoutRecoveryToken: UInt = 0
    private var timeoutRecoveryAttempt = 0
    private var isRecoveringFromTapTimeout = false
    private var monitoringStartedAt: TimeInterval?
    private var monitoringGeneration: UInt = 0
    private var acceptsEvents = false
    
    // 握りつぶしたキーでも押下判定できるように自前で保持
    private var pressedKeyCodes: Set<Int> = []
    
    private var targetedWindow: WindowTarget?
    private var startDragLocation: CGPoint?
    private var activeMode: InteractionMode = .none
    private var activeMouseButton: MouseButton?
    private var minWindowSize: CGSize?
    private var maxWindowSize: CGSize?
    private var interactionEngine: WindowInteractionEngine?
    private var resizeAnchorTransform: ResizeAnchorTransform?
    private var lastDragLocation: CGPoint?
    private var isCatchUpTickScheduled = false

    // AXへの書き込みをイベントごとに積まず、最新フレームだけにまとめる。
    private var pendingWindowUpdate: PendingWindowUpdate?
    private var isWindowUpdateScheduled = false
    private var interactionGeneration: UInt = 0
    private let updateInterval: TimeInterval = 1.0 / 120.0
    private let accessibilityMessagingTimeout: Float = 0.04
    private let accessibilityResolutionBudget: TimeInterval = 0.18
    private let maximumMouseDownAXQueries = 40
    private let maximumApplicationWindowCandidates = 24
    private let maximumParentDepth = 8
    private var cachedCGWindowInfo: [[CFString: Any]] = []
    private var cachedCGWindowInfoTimestamp: TimeInterval = 0
    private var cachedAccessibilityPermissionState = false
    
    var settings: SettingsModel?

    /// Called on the main thread by the permission coordinator after its
    /// background TCC check completes. Event-tap and deferred AX paths must only
    /// consult this cached value; a synchronous TCC call can stall the main run
    /// loop while the active mouse tap is withholding input.
    func updateAccessibilityPermissionState(_ isTrusted: Bool) {
        precondition(Thread.isMainThread)
        cachedAccessibilityPermissionState = isTrusted
    }

    var isMonitoring: Bool {
        // During a timeout cooldown, report the manager as owned/recovering so the
        // permission poller cannot bypass the circuit breaker by recreating the tap.
        if isRecoveringFromTapTimeout { return true }
        guard acceptsEvents,
              let eventTap,
              CFMachPortIsValid(eventTap)
        else { return false }
        // The keyboard tap is deliberately passive and optional. It has its own
        // retry path and must never cause the active mouse filter to churn.
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    func startMonitoring() -> Bool {
        precondition(Thread.isMainThread)
        guard !isRecoveringFromTapTimeout else { return false }
        stopMonitoringInternal(cancelTimeoutRecovery: false)
        // The coordinator performs the TCC query on its dedicated utility queue
        // and updates this cache before starting monitoring. Re-querying TCC here
        // can block the main run loop while macOS is applying a permission change.
        guard cachedAccessibilityPermissionState else { return false }

        // The system-wide element sets the default timeout for every AX element
        // used by this process. Without this, one hung target application can hold
        // the active event-tap callback (and therefore system input) for seconds.
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(
            systemWide,
            accessibilityMessagingTimeout
        ) == .success else { return false }

        guard let runLoop = CFRunLoopGetCurrent() else { return false }
        monitoringRunLoop = runLoop
        let generation = monitoringGeneration
        let mouseContext = EventTapContext(manager: self, generation: generation)
        mouseTapContext = mouseContext

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
            callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<EventTapContext>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return context.manager?.handle(
                    event: event,
                    type: type,
                    generation: context.generation
                ) ?? Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(mouseContext).toOpaque()
        ) else {
            print("イベントタップ作成失敗")
            mouseTapContext = nil
            return false
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            retiredTapContexts.append(mouseContext)
            mouseTapContext = nil
            monitoringRunLoop = nil
            return false
        }
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        acceptsEvents = true
        monitoringStartedAt = ProcessInfo.processInfo.systemUptime
        CGEvent.tapEnable(tap: eventTap, enable: true)

        // キーボード（keyDown / keyUp）は受動監視し、押下状態だけを追跡する。
        if !createKeyboardTap(generation: generation, runLoop: runLoop) {
            // 失敗してもマウス機能は継続し、CGEventSourceの状態を利用する。
            print("キーボードイベントタップ作成失敗（キー状態はシステム値を使用）")
            scheduleKeyboardTapRetry(generation: generation)
        }
        return true
    }

    func stopMonitoring() {
        stopMonitoringInternal(cancelTimeoutRecovery: true)
    }

    private func stopMonitoringInternal(cancelTimeoutRecovery: Bool) {
        precondition(Thread.isMainThread)
        if cancelTimeoutRecovery {
            timeoutRecoveryToken &+= 1
            timeoutRecoveryWorkItem?.cancel()
            timeoutRecoveryWorkItem = nil
            isRecoveringFromTapTimeout = false
            timeoutRecoveryAttempt = 0
        }
        acceptsEvents = false
        monitoringGeneration &+= 1
        interactionGeneration &+= 1
        keyboardRetryWorkItem?.cancel()
        keyboardRetryWorkItem = nil
        keyboardRetryAttempt = 0
        pendingWindowUpdate = nil
        isWindowUpdateScheduled = false
        pressedKeyCodes.removeAll()
        endAction()

        if let runLoopSource, let monitoringRunLoop {
            CFRunLoopRemoveSource(monitoringRunLoop, runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let keyboardRunLoopSource, let monitoringRunLoop {
            CFRunLoopRemoveSource(monitoringRunLoop, keyboardRunLoopSource, .commonModes)
        }
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: false)
            CFMachPortInvalidate(keyboardEventTap)
        }

        if let mouseTapContext {
            retiredTapContexts.append(mouseTapContext)
        }
        if let keyboardTapContext {
            retiredTapContexts.append(keyboardTapContext)
        }
        runLoopSource = nil
        eventTap = nil
        keyboardRunLoopSource = nil
        keyboardEventTap = nil
        mouseTapContext = nil
        keyboardTapContext = nil
        monitoringRunLoop = nil
        monitoringStartedAt = nil
    }

    private func createKeyboardTap(generation: UInt, runLoop: CFRunLoop) -> Bool {
        guard generation == monitoringGeneration,
              acceptsEvents,
              keyboardEventTap == nil
        else { return false }

        let keyMask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let keyboardContext = EventTapContext(manager: self, generation: generation)
        guard let keyboardTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // A keyboard filter on the app's main run loop can withhold every key
            // while any AppKit/AX work stalls. Listening is sufficient for held-key
            // tracking and guarantees that emergency shortcuts always reach macOS.
            options: .listenOnly,
            eventsOfInterest: CGEventMask(keyMask),
            callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<EventTapContext>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return context.manager?.handleKeyboard(
                    event: event,
                    type: type,
                    generation: context.generation
                ) ?? Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(keyboardContext).toOpaque()
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            keyboardTap,
            0
        ) else {
            CFMachPortInvalidate(keyboardTap)
            retiredTapContexts.append(keyboardContext)
            return false
        }

        keyboardTapContext = keyboardContext
        keyboardEventTap = keyboardTap
        keyboardRunLoopSource = source
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: keyboardTap, enable: true)
        keyboardRetryAttempt = 0
        return true
    }

    private func scheduleKeyboardTapRetry(generation: UInt) {
        guard keyboardRetryWorkItem == nil,
              generation == monitoringGeneration,
              acceptsEvents
        else { return }

        let delay = min(pow(2.0, Double(keyboardRetryAttempt)), 30.0)
        keyboardRetryAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.keyboardRetryWorkItem = nil
            guard generation == self.monitoringGeneration,
                  self.acceptsEvents,
                  self.cachedAccessibilityPermissionState,
                  let runLoop = self.monitoringRunLoop
            else { return }
            if !self.createKeyboardTap(generation: generation, runLoop: runLoop) {
                self.scheduleKeyboardTapRetry(generation: generation)
            }
        }
        keyboardRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func recycleKeyboardTap(afterDisabledTapAt generation: UInt) {
        pressedKeyCodes.removeAll()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  generation == self.monitoringGeneration,
                  self.acceptsEvents
            else { return }

            if let source = self.keyboardRunLoopSource,
               let runLoop = self.monitoringRunLoop {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            if let tap = self.keyboardEventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let context = self.keyboardTapContext {
                self.retiredTapContexts.append(context)
            }
            self.keyboardRunLoopSource = nil
            self.keyboardEventTap = nil
            self.keyboardTapContext = nil
            self.scheduleKeyboardTapRetry(generation: generation)
        }
    }

    private func handleKeyboard(
        event: CGEvent,
        type: CGEventType,
        generation: UInt
    ) -> Unmanaged<CGEvent>? {
        let isDisabledNotification = isTapDisabledNotification(type)

        // This is a passive tap, so it never needs to consult TCC from inside the
        // callback. In particular, stale callbacks and ordinary key events must
        // remain a completely local pass-through path even if the privacy daemon
        // is busy while Accessibility permission is changing.
        guard generation == monitoringGeneration, acceptsEvents else {
            return isDisabledNotification ? nil : Unmanaged.passUnretained(event)
        }
        if isDisabledNotification {
            recycleKeyboardTap(afterDisabledTapAt: generation)
            return nil
        }

        switch EventTapCallbackPolicy.decision(
            callbackGeneration: generation,
            currentGeneration: monitoringGeneration,
            acceptsEvents: acceptsEvents,
            isTrusted: true,
            isDisabledNotification: false
        ) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .ignoreDisabledNotification:
            return nil
        case .permissionLost:
            suspendForPermissionLoss(at: generation)
            return Unmanaged.passUnretained(event)
        case .rebuild:
            recycleKeyboardTap(afterDisabledTapAt: generation)
            return nil
        case .handle:
            break
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

        // This is a listen-only tap: every ordinary key event must be returned.
        // Shortcut activation reads `pressedKeyCodes`/CGEventSource state later.
        return Unmanaged.passUnretained(event)
    }

    private func handle(
        event: CGEvent,
        type: CGEventType,
        generation: UInt
    ) -> Unmanaged<CGEvent>? {
        // Arm before policy evaluation. The policy only reads cached state now,
        // but keeping the watchdog at the outermost callback boundary guarantees
        // later changes cannot introduce an unprotected synchronous call.
        let callbackWatchdog = isMouseDown(type)
            ? armActiveTapWatchdog(generation: generation)
            : nil
        defer { callbackWatchdog?.finish() }

        let isDisabledNotification = isTapDisabledNotification(type)

        // Short-circuit retired contexts and use only the coordinator's cached
        // trust state. Event-tap callbacks must never call TCC synchronously while
        // they are holding an input event.
        let callbackIsCurrent = generation == monitoringGeneration && acceptsEvents
        let isTrusted = !callbackIsCurrent ||
            isDisabledNotification ||
            cachedAccessibilityPermissionState
        switch EventTapCallbackPolicy.decision(
            callbackGeneration: generation,
            currentGeneration: monitoringGeneration,
            acceptsEvents: acceptsEvents,
            isTrusted: isTrusted,
            isDisabledNotification: isDisabledNotification
        ) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .ignoreDisabledNotification:
            return nil
        case .permissionLost:
            suspendForPermissionLoss(at: generation)
            return Unmanaged.passUnretained(event)
        case .rebuild:
            // User-input and timeout disable notifications share the same circuit
            // breaker. Immediate recreation can otherwise enter a tight loop.
            beginTapRecovery(at: generation)
            return nil
        case .handle:
            break
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
                var axBudget = AXQueryBudget(
                    duration: accessibilityResolutionBudget,
                    maximumQueries: maximumMouseDownAXQueries
                )
                if let resolvedTarget = getTargetAtLocation(
                    location,
                    budget: &axBudget
                ) {
                    let target = resolvedTarget.target
                    let currentFrame = resolvedTarget.frame
                    let initialResizeAnchorTransform = isResizeActive
                        ? ResizeAnchorTransform(
                            anchor: ResizeAnchorCorner(
                                selection: settings.resizeAnchorPoint,
                                windowFrame: currentFrame,
                                cursorLocation: location
                            )
                        )
                        : nil
                    
                    if isResizeActive {
                        // Resizability is mandatory for claiming this click. If
                        // the shared deadline expires or AX cannot answer reliably,
                        // fail open and leave the event with the target app.
                        guard let targetIsResizable = isResizable(
                            target,
                            requiresPositionUpdate:
                                initialResizeAnchorTransform?.requiresPositionUpdate == true,
                            budget: &axBudget
                        ) else {
                            return Unmanaged.passUnretained(event)
                        }
                        if !targetIsResizable {
                            VisualEffectManager.shared.showEffect(
                                frame: currentFrame,
                                mode: .error
                            )
                            return nil
                        }
                    }

                    self.interactionGeneration &+= 1
                    let currentInteractionGeneration = self.interactionGeneration
                    self.targetedWindow = target
                    self.startDragLocation = location
                    self.lastDragLocation = location
                    self.activeMode = isMoveActive ? .move : .resize
                    self.activeMouseButton = isMoveActive ? settings.moveSetting.mouseButton : settings.resizeSetting.mouseButton

                    if !settings.preserveWindowOrder {
                        bringWindowToFront(
                            target,
                            processIdentifier: resolvedTarget.processIdentifier,
                            interactionGeneration: currentInteractionGeneration,
                            budget: &axBudget
                        )
                    }
                    // Match the original interaction order: raise the target first,
                    // then draw the outline. Showing the overlay before AXRaise makes
                    // a successful raise look visibly delayed.
                    VisualEffectManager.shared.showEffect(frame: currentFrame, mode: activeMode)

                    self.minWindowSize = isResizeActive
                        ? protectedMinimumSize(
                            for: target,
                            windowFrame: currentFrame,
                            budget: &axBudget
                        )
                        : nil
                    self.maxWindowSize = isResizeActive
                        ? getMaxSize(target, budget: &axBudget)
                        : nil

                    let resizeAnchorTransform = initialResizeAnchorTransform
                    self.resizeAnchorTransform = resizeAnchorTransform
                    self.interactionEngine = WindowInteractionEngine(
                        mode: activeMode,
                        initialFrame: resizeAnchorTransform?.engineFrame(from: currentFrame) ?? currentFrame,
                        initialPointer: resizeAnchorTransform?.enginePoint(from: location) ?? location,
                        obstacleFrames: obstacleFrames(
                            excluding: currentFrame,
                            targetProcessIdentifier: resolvedTarget.processIdentifier
                        ).map {
                            resizeAnchorTransform?.engineFrame(from: $0) ?? $0
                        },
                        timestamp: timestamp(of: event)
                    )

                    guard cachedAccessibilityPermissionState else {
                        suspendForPermissionLoss(at: generation)
                        return Unmanaged.passUnretained(event)
                    }
                    return nil
                }
            }
        }
        
        // ドラッグ処理
        else if isMouseDragged(type) {
            if let target = targetedWindow,
               let startLocation = startDragLocation,
               var engine = interactionEngine {
                
                guard activeMode != .none, dragEventMatchesActiveButton(type) else {
                    return Unmanaged.passUnretained(event)
                }
                
                let location = event.location
                let constraint = activeAxisConstraint(
                    settings: settings,
                    flags: event.flags,
                    location: location,
                    startLocation: startLocation
                )
                var newFrame = engine.frame(
                    for: resizeAnchorTransform?.enginePoint(from: location) ?? location,
                    timestamp: timestamp(of: event),
                    constraint: constraint
                )
                interactionEngine = engine
                lastDragLocation = location

                if activeMode == .resize {
                    newFrame.size = clampSize(newFrame.size)
                    newFrame = resizeAnchorTransform?.screenFrame(from: newFrame) ?? newFrame
                }
                scheduleWindowUpdate(
                    target: target,
                    frame: newFrame,
                    mode: activeMode,
                    resizePosition: newFrame.origin,
                    requiresResizePositionUpdate:
                        resizeAnchorTransform?.requiresPositionUpdate == true
                )
                scheduleCatchUpTickIfNeeded(target: target)
                
                return nil
            }
        }
        
        // マウスアップ処理
        else if isMouseUp(type) {
            if targetedWindow != nil && mouseUpMatchesActiveButton(type) {
                endAction()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func isTapDisabledNotification(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    private func armActiveTapWatchdog(
        generation: UInt
    ) -> ActiveTapWatchdogToken? {
        guard generation == monitoringGeneration,
              acceptsEvents,
              let tap = eventTap
        else { return nil }

        let token = ActiveTapWatchdogToken()
        callbackWatchdogQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard token.claimIfPending() else { return }

            // This runs independently of the main run loop. Disabling the active
            // filter here releases system input even if main is stuck in AX IPC.
            CGEvent.tapEnable(tap: tap, enable: false)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.beginTapRecovery(at: generation)
            }
        }
        return token
    }

    private func beginTapRecovery(at generation: UInt) {
        guard generation == monitoringGeneration,
              !isRecoveringFromTapTimeout
        else { return }

        if let startedAt = monitoringStartedAt,
           ProcessInfo.processInfo.systemUptime - startedAt >= 15 {
            timeoutRecoveryAttempt = 0
        }
        let delay = min(pow(2.0, Double(timeoutRecoveryAttempt)), 8.0)
        timeoutRecoveryAttempt = min(timeoutRecoveryAttempt + 1, 3)
        isRecoveringFromTapTimeout = true
        timeoutRecoveryToken &+= 1
        let recoveryToken = timeoutRecoveryToken

        acceptsEvents = false
        interactionGeneration &+= 1
        pendingWindowUpdate = nil
        isWindowUpdateScheduled = false
        pressedKeyCodes.removeAll()
        endAction()

        // Teardown is deferred until the current event-tap callback has returned.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  recoveryToken == self.timeoutRecoveryToken,
                  self.isRecoveringFromTapTimeout
            else { return }

            self.stopMonitoringInternal(cancelTimeoutRecovery: false)
            let expectedGeneration = self.monitoringGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      recoveryToken == self.timeoutRecoveryToken,
                      expectedGeneration == self.monitoringGeneration,
                      self.isRecoveringFromTapTimeout
                else { return }

                self.timeoutRecoveryWorkItem = nil
                self.isRecoveringFromTapTimeout = false
                if self.cachedAccessibilityPermissionState {
                    _ = self.startMonitoring()
                } else {
                    self.stopMonitoring()
                }
            }
            self.timeoutRecoveryWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func suspendForPermissionLoss(at generation: UInt) {
        guard generation == monitoringGeneration else { return }
        acceptsEvents = false
        interactionGeneration &+= 1
        pendingWindowUpdate = nil
        isWindowUpdateScheduled = false
        pressedKeyCodes.removeAll()
        endAction()

        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.monitoringGeneration else { return }
            self.stopMonitoring()
        }
    }

    private func endAction() {
        targetedWindow = nil
        startDragLocation = nil
        activeMode = .none
        activeMouseButton = nil
        minWindowSize = nil
        maxWindowSize = nil
        interactionEngine = nil
        resizeAnchorTransform = nil
        lastDragLocation = nil
        isCatchUpTickScheduled = false
        VisualEffectManager.shared.hideEffect()
    }

    private func timestamp(of event: CGEvent) -> TimeInterval {
        TimeInterval(event.timestamp) / 1_000_000_000
    }

    private func activeAxisConstraint(
        settings: SettingsModel,
        flags: CGEventFlags,
        location: CGPoint,
        startLocation: CGPoint
    ) -> DragAxisConstraint {
        let horizontal = settings.horizontalConstraintSetting.isHeld(
            eventFlags: flags,
            pressedKeyCodes: pressedKeyCodes
        )
        let vertical = settings.verticalConstraintSetting.isHeld(
            eventFlags: flags,
            pressedKeyCodes: pressedKeyCodes
        )

        switch (horizontal, vertical) {
        case (true, false):
            return .horizontal
        case (false, true):
            return .vertical
        case (true, true):
            // Overlapping/subset commands are valid. When both match, lock to the dominant axis.
            return abs(location.x - startLocation.x) >= abs(location.y - startLocation.y)
                ? .horizontal
                : .vertical
        case (false, false):
            return .none
        }
    }

    private func scheduleWindowUpdate(
        target: WindowTarget,
        frame: CGRect,
        mode: InteractionMode,
        resizePosition: CGPoint,
        requiresResizePositionUpdate: Bool = false
    ) {
        pendingWindowUpdate = PendingWindowUpdate(
            target: target,
            frame: frame,
            mode: mode,
            resizePosition: resizePosition,
            requiresResizePositionUpdate: requiresResizePositionUpdate,
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
        guard let update = pendingWindowUpdate else { return }
        pendingWindowUpdate = nil
        guard update.generation == interactionGeneration else { return }
        guard cachedAccessibilityPermissionState else {
            suspendForPermissionLoss(at: monitoringGeneration)
            return
        }

        let updateWatchdog: ActiveTapWatchdogToken?
        switch update.target {
        case .accessibility:
            updateWatchdog = armActiveTapWatchdog(generation: monitoringGeneration)
        case .native:
            updateWatchdog = nil
        }
        defer { updateWatchdog?.finish() }

        let succeeded: Bool
        switch update.mode {
        case .move:
            succeeded = setPosition(update.target, position: update.frame.origin)
        case .resize:
            switch update.target {
            case .native(let window):
                // Convert the complete desired AX frame once. Splitting native
                // resize into size/origin mutations causes a transient bottom-left
                // anchor and redundant screen-coordinate conversion.
                succeeded = setNativeWindowFrame(window, frame: update.frame)
            case .accessibility(let element):
                let resized = setSize(element, size: update.frame.size)
                // Some cross-platform apps move their frame origin while handling
                // AXSize. Restore the calculated origin so the anchor stays fixed.
                let repositioned = setPosition(
                    element,
                    position: update.resizePosition
                )
                succeeded = resized &&
                    (!update.requiresResizePositionUpdate || repositioned)
            }
        case .error, .none:
            succeeded = false
        }

        if succeeded, targetedWindow != nil, update.generation == interactionGeneration {
            VisualEffectManager.shared.updateFrame(update.frame)
        }

        if pendingWindowUpdate != nil {
            isWindowUpdateScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + updateInterval) { [weak self] in
                self?.applyPendingWindowUpdate()
            }
        }
    }

    private func scheduleCatchUpTickIfNeeded(target: WindowTarget) {
        guard interactionEngine?.needsCatchUp == true, !isCatchUpTickScheduled else { return }
        let generation = interactionGeneration
        isCatchUpTickScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + updateInterval) { [weak self] in
            guard let self else { return }
            guard generation == self.interactionGeneration else { return }
            self.isCatchUpTickScheduled = false
            guard self.targetedWindow != nil,
                  let settings = self.settings,
                  let startLocation = self.startDragLocation,
                  let location = self.lastDragLocation,
                  var engine = self.interactionEngine,
                  engine.needsCatchUp
            else { return }

            let constraint = self.activeAxisConstraint(
                settings: settings,
                flags: CGEventSource.flagsState(.combinedSessionState),
                location: location,
                startLocation: startLocation
            )
            var frame = engine.frame(
                for: self.resizeAnchorTransform?.enginePoint(from: location) ?? location,
                timestamp: ProcessInfo.processInfo.systemUptime,
                constraint: constraint
            )
            self.interactionEngine = engine
            if self.activeMode == .resize {
                frame.size = self.clampSize(frame.size)
                frame = self.resizeAnchorTransform?.screenFrame(from: frame) ?? frame
            }
            self.scheduleWindowUpdate(
                target: target,
                frame: frame,
                mode: self.activeMode,
                resizePosition: frame.origin,
                requiresResizePositionUpdate:
                    self.resizeAnchorTransform?.requiresPositionUpdate == true
            )
            self.scheduleCatchUpTickIfNeeded(target: target)
        }
    }
    
    private func shouldActivate(setting: ShortcutSetting, flags: CGEventFlags, isEnabled: Bool, eventType: CGEventType) -> Bool {
        guard isEnabled, setting.isValidTrigger else { return false }
        
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
        } else if setting.hasKeyboardTrigger {
            return setting.matches(eventFlags: flags, eventKeyCode: nil)
        }
        return true
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
    
    private func getTargetAtLocation(
        _ location: CGPoint,
        budget: inout AXQueryBudget
    ) -> ResolvedWindowTarget? {
        // Resolve WindowServer order first. In particular, querying this process via
        // system-wide AX while its main event-tap callback is running can deadlock
        // against our own main thread.
        let nativeFallback = frontmostEligibleNativeWindow(at: location)
        // A WindowServer snapshot failure is not equivalent to an empty screen.
        // Fail open instead of guessing and potentially targeting Windoor through
        // a visually frontmost external window.
        guard let cgWindows = currentCGWindowInfo() else { return nil }
        guard let cgWindow = frontmostCGWindow(
            at: location,
            windows: cgWindows
        ) else {
            return resolvedNativeTarget(nativeFallback)
        }

        if cgWindow.processIdentifier == getpid() {
            guard let nativeWindow = NSApp.windows.first(where: {
                CGWindowID($0.windowNumber) == cgWindow.identifier &&
                    $0.isVisible &&
                    !$0.ignoresMouseEvents
            }) else { return nil }
            return resolvedNativeTarget(nativeWindow)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        if budget.take(),
           AXUIElementCopyElementAtPosition(
            systemWide,
            Float(location.x),
            Float(location.y),
            &hitElement
        ) == .success,
           let hitElement {
            var hitProcessIdentifier: pid_t = 0
            if budget.take(),
               AXUIElementGetPid(hitElement, &hitProcessIdentifier) == .success,
               hitProcessIdentifier == cgWindow.processIdentifier,
               let hitWindow = getWindow(from: hitElement, budget: &budget),
               let frame = matchingAccessibilityFrame(
                   for: hitWindow,
                   processIdentifier: cgWindow.processIdentifier,
                   windowServerFrame: cgWindow.frame,
                   budget: &budget
               ) {
                return ResolvedWindowTarget(
                    target: .accessibility(hitWindow),
                    frame: frame,
                    processIdentifier: cgWindow.processIdentifier
                )
            }
        }

        // AX hit testing can report the underlying document for nonstandard panels.
        // Match only within the WindowServer-selected process/frame; never fall
        // through to a visually obscured window.
        return applicationWindow(
            processIdentifier: cgWindow.processIdentifier,
            at: location,
            matching: cgWindow.frame,
            budget: &budget
        ).map { candidate in
            ResolvedWindowTarget(
                target: .accessibility(candidate.element),
                frame: candidate.frame,
                processIdentifier: cgWindow.processIdentifier
            )
        }
    }

    private func resolvedNativeTarget(_ window: NSWindow?) -> ResolvedWindowTarget? {
        guard let window,
              let frame = accessibilityFrame(for: window)
        else { return nil }
        return ResolvedWindowTarget(
            target: .native(window),
            frame: frame,
            processIdentifier: getpid()
        )
    }

    private func frontmostEligibleNativeWindow(at location: CGPoint) -> NSWindow? {
        guard NSApp.isActive else { return nil }
        return NSApp.orderedWindows.first { window in
            guard window.isVisible,
                  !window.isMiniaturized,
                  window.level == .normal,
                  window.canBecomeKey,
                  !window.ignoresMouseEvents,
                  let frame = accessibilityFrame(for: window)
            else { return false }
            return frame.contains(location)
        }
    }

    private func getWindow(
        from element: AXUIElement,
        budget: inout AXQueryBudget
    ) -> AXUIElement? {
        guard budget.take() else { return nil }
        if let window = copyElementAttribute(kAXWindowAttribute as CFString, from: element) {
            return window
        }
        guard budget.take() else { return nil }
        if let topLevel = copyElementAttribute(kAXTopLevelUIElementAttribute as CFString, from: element),
           isWindowLike(topLevel, budget: &budget) {
            return topLevel
        }

        var currentElement = element
        for _ in 0..<maximumParentDepth {
            if isWindowLike(currentElement, budget: &budget) {
                return currentElement
            }
            guard budget.take() else { break }
            var parent: AnyObject?
            let result = AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parent)
            guard result == .success, let parent else { break }
            currentElement = parent as! AXUIElement
        }
        return nil
    }

    private func isWindowLike(
        _ element: AXUIElement,
        budget: inout AXQueryBudget
    ) -> Bool {
        guard budget.take(),
              let position = getPosition(element),
              budget.take(),
              let size = getSize(element),
              position.x.isFinite,
              position.y.isFinite,
              size.width > 0,
              size.height > 0
        else { return false }

        let acceptedRoles = [
            kAXWindowRole as String,
            kAXSheetRole as String
        ]
        if budget.take(),
           let role = role(of: element),
           acceptedRoles.contains(role) {
            return true
        }

        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        if budget.take() {
            AXUIElementIsAttributeSettable(
                element,
                kAXPositionAttribute as CFString,
                &positionSettable
            )
        }
        if budget.take() {
            AXUIElementIsAttributeSettable(
                element,
                kAXSizeAttribute as CFString,
                &sizeSettable
            )
        }
        return positionSettable.boolValue || sizeSettable.boolValue
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
        matching preferredFrame: CGRect?,
        budget: inout AXQueryBudget
    ) -> (element: AXUIElement, frame: CGRect)? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard budget.take() else { return nil }
        _ = AXUIElementSetMessagingTimeout(application, accessibilityMessagingTimeout)
        var windows: [AXUIElement] = []
        var value: AnyObject?
        if budget.take(), AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
           let applicationWindows = value as? [AXUIElement] {
            windows.append(contentsOf: applicationWindows)
        }

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard budget.take() else { return nil }
            if let window = copyElementAttribute(attribute as CFString, from: application) {
                windows.insert(window, at: 0)
            }
        }
        guard !windows.isEmpty else { return nil }

        var candidates: [(AXUIElement, CGRect)] = []
        for window in windows.prefix(maximumApplicationWindowCandidates) {
            guard budget.take() else { return nil }
            guard let position = getPosition(window) else { continue }
            guard budget.take() else { return nil }
            guard let size = getSize(window) else { continue }
            let frame = CGRect(origin: position, size: size)
            guard frame.insetBy(dx: -2, dy: -2).contains(location) else { continue }
            candidates.append((window, frame))
            if let preferredFrame,
               WindowHitTester.framesLikelyMatch(frame, preferredFrame) {
                return (window, frame)
            }
        }

        if let preferredFrame {
            guard let closest = candidates.min(by: { lhs, rhs in
                frameDistance(lhs.1, preferredFrame) < frameDistance(rhs.1, preferredFrame)
            }), WindowHitTester.framesLikelyMatch(closest.1, preferredFrame)
            else { return nil }
            return closest
        }
        return candidates.min { lhs, rhs in
            lhs.1.width * lhs.1.height < rhs.1.width * rhs.1.height
        }
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY) +
            abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func matchingAccessibilityFrame(
        for element: AXUIElement,
        processIdentifier expectedProcessIdentifier: pid_t,
        windowServerFrame expectedFrame: CGRect,
        budget: inout AXQueryBudget
    ) -> CGRect? {
        var processIdentifier: pid_t = 0
        guard budget.take(),
              AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == expectedProcessIdentifier,
              budget.take(),
              let position = getPosition(element),
              budget.take(),
              let size = getSize(element)
        else { return nil }
        let frame = CGRect(origin: position, size: size)
        return WindowHitTester.framesLikelyMatch(frame, expectedFrame)
            ? frame
            : nil
    }

    private func frontmostCGWindow(
        at location: CGPoint,
        windows: [[CFString: Any]]
    ) -> (processIdentifier: pid_t, frame: CGRect, identifier: CGWindowID)? {
        let candidates = windows.compactMap { window -> WindowHitTestCandidate? in
            guard let processIdentifierValue = window[kCGWindowOwnerPID] as? NSNumber,
                  let frame = cgWindowFrame(from: window),
                  let layer = (window[kCGWindowLayer] as? NSNumber)?.intValue,
                  let identifier = (window[kCGWindowNumber] as? NSNumber)?.uint32Value
            else { return nil }

            // Windoor's border/effect windows intentionally ignore the mouse. Skip
            // those native windows so they cannot hide the settings window from the
            // CG-first self-process path while an effect is fading out.
            if processIdentifierValue.int32Value == getpid(),
               let nativeWindow = NSApp.windows.first(where: {
                   CGWindowID($0.windowNumber) == identifier
               }),
               nativeWindow.ignoresMouseEvents {
                return nil
            }
            let alpha = CGFloat((window[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1)
            return WindowHitTestCandidate(
                processIdentifier: processIdentifierValue.int32Value,
                frame: frame,
                layer: layer,
                alpha: alpha,
                identifier: identifier
            )
        }

        guard let candidate = WindowHitTester.frontmostCandidate(
            at: location,
            candidates: candidates,
            displayFrames: activeDisplayFrames()
        ) else { return nil }
        return (
            candidate.processIdentifier,
            candidate.frame,
            candidate.identifier
        )
    }

    private func currentCGWindowInfo() -> [[CFString: Any]]? {
        let now = ProcessInfo.processInfo.systemUptime
        if !cachedCGWindowInfo.isEmpty,
           now - cachedCGWindowInfoTimestamp <= 1.0 / 120.0 {
            return cachedCGWindowInfo
        }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            // Reusing stale z-order can target a window that is no longer visible
            // and effectively click through the current frontmost window.
            return nil
        }
        cachedCGWindowInfo = windows
        cachedCGWindowInfoTimestamp = now
        return windows
    }

    private func activeDisplayFrames() -> [CGRect] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0
        else { return [] }

        var displayIdentifiers = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        guard CGGetActiveDisplayList(
            displayCount,
            &displayIdentifiers,
            &displayCount
        ) == .success else { return [] }

        return displayIdentifiers.prefix(Int(displayCount)).map(CGDisplayBounds)
    }

    private func cgWindowFrame(from window: [CFString: Any]) -> CGRect? {
        guard let bounds = window[kCGWindowBounds] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as! CFDictionary)
    }

    private func accessibilityFrame(for window: NSWindow) -> CGRect? {
        let cocoaFrame = window.frame
        guard let screen = window.screen ?? NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY))
        }),
              let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber
        else { return nil }
        let displayBounds = CGDisplayBounds(displayID.uint32Value)
        return CGRect(
            x: displayBounds.minX + cocoaFrame.minX - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - cocoaFrame.maxY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    private func cocoaFrame(fromAccessibilityFrame frame: CGRect) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return false }
            return CGDisplayBounds(displayID.uint32Value).contains(center)
        }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber
        else { return nil }
        let displayBounds = CGDisplayBounds(displayID.uint32Value)
        return CGRect(
            x: screen.frame.minX + frame.minX - displayBounds.minX,
            y: screen.frame.maxY - (frame.minY - displayBounds.minY) - frame.height,
            width: frame.width,
            height: frame.height
        )
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

    private func bringWindowToFront(
        _ target: WindowTarget,
        processIdentifier: pid_t,
        interactionGeneration generation: UInt,
        budget: inout AXQueryBudget
    ) {
        switch target {
        case .native(let window):
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case .accessibility(let element):
            bringAccessibilityWindowToFront(
                element,
                processIdentifier: processIdentifier,
                interactionGeneration: generation,
                budget: &budget
            )
        }
    }

    private func bringAccessibilityWindowToFront(
        _ element: AXUIElement,
        processIdentifier: pid_t,
        interactionGeneration generation: UInt,
        budget: inout AXQueryBudget
    ) {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let results = performWindowFronting(
            element: element,
            applicationElement: applicationElement,
            budget: &budget
        ) else {
            // The target PID was already resolved while hit-testing. Activate it
            // synchronously before drawing the outline even if the shared AX
            // budget is exhausted, then finish the focused-window/raise sequence
            // in the bounded retry.
            NSRunningApplication(processIdentifier: processIdentifier)?.activate()
            scheduleWindowFrontingRetry(
                element: element,
                processIdentifier: processIdentifier,
                interactionGeneration: generation,
                attempt: 1
            )
            return
        }

        // Activation is the one-shot fallback for any incomplete initial result,
        // including unsupported AX frontmost/raise attributes. Retry policy is
        // evaluated only after this immediate fallback.
        if results.frontmost != .success || results.raise != .success {
            NSRunningApplication(processIdentifier: processIdentifier)?.activate()
        }
        guard WindowFrontingPolicy.shouldRetry(
            frontmostResult: results.frontmost,
            raiseResult: results.raise
        ) else { return }

        scheduleWindowFrontingRetry(
            element: element,
            processIdentifier: processIdentifier,
            interactionGeneration: generation,
            attempt: 1
        )
    }

    private func performWindowFronting(
        element: AXUIElement,
        applicationElement: AXUIElement,
        budget: inout AXQueryBudget
    ) -> (frontmost: AXError, raise: AXError)? {
        // Keep the event-tap callback bounded even when an application is busy.
        guard budget.take() else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, accessibilityMessagingTimeout)
        guard budget.take() else { return nil }
        _ = AXUIElementSetMessagingTimeout(
            applicationElement,
            accessibilityMessagingTimeout
        )

        // Select the target before activating the application, avoiding a flash of
        // that application's previously focused window on newer macOS releases.
        guard budget.take() else { return nil }
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            element
        )
        guard budget.take() else { return nil }
        let frontmostResult = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        guard budget.take() else { return nil }
        let raiseResult = AXUIElementPerformAction(
            element,
            kAXRaiseAction as CFString
        )
        return (frontmostResult, raiseResult)
    }

    private func scheduleWindowFrontingRetry(
        element: AXUIElement,
        processIdentifier: pid_t,
        interactionGeneration generation: UInt,
        attempt: Int
    ) {
        let delay: TimeInterval = attempt == 1 ? 0.04 : 0.10
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  attempt <= 2,
                  self.acceptsEvents,
                  self.cachedAccessibilityPermissionState,
                  generation == self.interactionGeneration,
                  case .accessibility(let targetedElement)? = self.targetedWindow,
                  CFEqual(targetedElement, element)
            else { return }

            let frontingWatchdog = self.armActiveTapWatchdog(
                generation: self.monitoringGeneration
            )
            defer { frontingWatchdog?.finish() }

            var retryBudget = AXQueryBudget(duration: 0.12, maximumQueries: 8)
            let applicationElement = AXUIElementCreateApplication(processIdentifier)
            guard let results = self.performWindowFronting(
                element: element,
                applicationElement: applicationElement,
                budget: &retryBudget
            ) else {
                if attempt < 2 {
                    self.scheduleWindowFrontingRetry(
                        element: element,
                        processIdentifier: processIdentifier,
                        interactionGeneration: generation,
                        attempt: attempt + 1
                    )
                }
                return
            }

            if results.frontmost != .success || results.raise != .success {
                NSRunningApplication(processIdentifier: processIdentifier)?.activate()
            }
            if WindowFrontingPolicy.shouldRetry(
                frontmostResult: results.frontmost,
                raiseResult: results.raise
            ), attempt < 2 {
                self.scheduleWindowFrontingRetry(
                    element: element,
                    processIdentifier: processIdentifier,
                    interactionGeneration: generation,
                    attempt: attempt + 1
                )
            }
        }
    }

    private func obstacleFrames(
        excluding targetFrame: CGRect,
        targetProcessIdentifier targetPID: pid_t
    ) -> [CGRect] {
        var frames: [CGRect] = []
        guard let windows = currentCGWindowInfo() else { return [] }
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

        return frames
    }

    private func protectedMinimumSize(
        for target: WindowTarget,
        windowFrame: CGRect,
        budget: inout AXQueryBudget
    ) -> CGSize? {
        switch target {
        case .native(let window):
            let size = window.minSize
            return size.width > 0 && size.height > 0 ? size : nil
        case .accessibility(let element):
            return protectedMinimumSize(
                for: element,
                windowFrame: windowFrame,
                budget: &budget
            )
        }
    }

    private func protectedMinimumSize(
        for element: AXUIElement,
        windowFrame: CGRect,
        budget: inout AXQueryBudget
    ) -> CGSize? {
        guard budget.take() else { return nil }
        var result: CGSize = getMinSize(element) ?? .zero
        let controlAttributes: [CFString] = [
            kAXCloseButtonAttribute as CFString,
            kAXMinimizeButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXFullScreenButtonAttribute as CFString
        ]

        var foundTrafficLight = false
        for attribute in controlAttributes {
            // Minimum-size protection is optional. Do not continue with a partial
            // result after the shared mouse-down deadline has expired.
            guard budget.take() else { return nil }
            guard let button = copyElementAttribute(attribute, from: element) else { continue }
            guard budget.take() else { return nil }
            guard let position = getPosition(button) else { continue }
            guard budget.take() else { return nil }
            guard let size = getSize(button) else { continue }

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
    
    private func setPosition(_ target: WindowTarget, position: CGPoint) -> Bool {
        switch target {
        case .accessibility(let element):
            return setPosition(element, position: position)
        case .native(let window):
            guard let size = accessibilityFrame(for: window)?.size,
                  let frame = cocoaFrame(
                    fromAccessibilityFrame: CGRect(origin: position, size: size)
                  )
            else { return false }
            window.setFrameOrigin(frame.origin)
            return true
        }
    }

    private func setNativeWindowFrame(_ window: NSWindow, frame: CGRect) -> Bool {
        guard let cocoaFrame = cocoaFrame(fromAccessibilityFrame: frame) else {
            return false
        }
        window.setFrame(cocoaFrame, display: false)
        return true
    }

    private func isResizable(
        _ target: WindowTarget,
        requiresPositionUpdate: Bool,
        budget: inout AXQueryBudget
    ) -> Bool? {
        switch target {
        case .accessibility(let element):
            return isResizable(
                element,
                requiresPositionUpdate: requiresPositionUpdate,
                budget: &budget
            )
        case .native:
            // Windoor's settings window has fixed user chrome but can safely be
            // resized programmatically by Windoor itself.
            return true
        }
    }

    private func getMaxSize(
        _ target: WindowTarget,
        budget: inout AXQueryBudget
    ) -> CGSize? {
        switch target {
        case .accessibility(let element):
            guard budget.take() else { return nil }
            return getMaxSize(element)
        case .native(let window):
            let size = window.maxSize
            guard size.width.isFinite,
                  size.height.isFinite,
                  size.width > 0,
                  size.height > 0
            else { return nil }
            return size
        }
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
    
    private func isResizable(
        _ element: AXUIElement,
        requiresPositionUpdate: Bool,
        budget: inout AXQueryBudget
    ) -> Bool? {
        guard budget.take() else { return nil }
        var writable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXSizeAttribute as CFString,
            &writable
        )
        switch result {
        case .success:
            guard writable.boolValue else { return false }
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            return false
        default:
            return nil
        }

        guard requiresPositionUpdate else { return true }
        guard budget.take() else { return nil }
        writable = false
        let positionResult = AXUIElementIsAttributeSettable(
            element,
            kAXPositionAttribute as CFString,
            &writable
        )
        switch positionResult {
        case .success:
            return writable.boolValue
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            return false
        default:
            return nil
        }
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
