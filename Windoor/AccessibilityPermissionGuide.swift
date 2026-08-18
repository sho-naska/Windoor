import ApplicationServices
import AppKit
import Combine
import SwiftUI

enum AccessibilityPermissionGuideLayout {
    private static let accessibilityPageTitles = [
        "accessibility",
        "アクセシビリティ",
        "bedienungshilfen",
        "accessibilité",
        "accesibilidad",
        "손쉬운 사용",
        "辅助功能",
        "輔助使用",
        "acessibilidade",
        "универсальный доступ"
    ]

    static func panelOrigin(
        following settingsFrame: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let proposedOrigin = CGPoint(
            x: settingsFrame.midX - panelSize.width / 2,
            y: settingsFrame.minY - panelSize.height + 20
        )
        return CGPoint(
            x: min(
                max(proposedOrigin.x, visibleFrame.minX + 8),
                visibleFrame.maxX - panelSize.width - 8
            ),
            y: min(
                max(proposedOrigin.y, visibleFrame.minY + 8),
                visibleFrame.maxY - panelSize.height - 8
            )
        )
    }

    static func isAccessibilityPage(
        title: String,
        localizedAccessibilityTitle: String? = nil
    ) -> Bool {
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var candidateTitles = accessibilityPageTitles
        if let localizedAccessibilityTitle {
            let normalizedLocalizedTitle = localizedAccessibilityTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !normalizedLocalizedTitle.isEmpty {
                candidateTitles.append(normalizedLocalizedTitle)
            }
        }
        return candidateTitles.contains { normalizedTitle.contains($0) }
    }
}

@MainActor
final class AccessibilityPermissionCoordinator: ObservableObject {
    @Published private(set) var isTrusted: Bool

    private let accessibilityManager: AccessibilityManager
    private let languageProvider: () -> AppLanguage
    private let onPermissionMissing: () -> Void
    private let permissionCheckQueue = DispatchQueue(
        label: "com.naska.Windoor.accessibility-permission-check",
        qos: .utility
    )
    private var permissionTimer: Timer?
    private var permissionCheckInFlight = false
    private var permissionCheckGeneration: UInt = 0
    private var isPermissionMonitoringActive = false
    private var previousTrustState: Bool?
    private var guideRequested = false
    private lazy var guideController = AccessibilityPermissionGuideController(
        languageProvider: languageProvider,
        onGuideEnded: { [weak self] in
            self?.guideRequested = false
        }
    )

    init(
        accessibilityManager: AccessibilityManager,
        languageProvider: @escaping () -> AppLanguage,
        onPermissionMissing: @escaping () -> Void = {}
    ) {
        // TCC may briefly block while System Settings changes permission. Keep the
        // initial main-thread state conservative and obtain the real value from the
        // dedicated background checker in `start()`.
        self.isTrusted = false
        self.accessibilityManager = accessibilityManager
        self.languageProvider = languageProvider
        self.onPermissionMissing = onPermissionMissing
    }

    func start() {
        stopTimer()
        isPermissionMonitoringActive = true
        permissionCheckGeneration &+= 1
        permissionCheckInFlight = false
        requestPermissionCheck()

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestPermissionCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func stop() {
        stopTimer()
        isPermissionMonitoringActive = false
        permissionCheckGeneration &+= 1
        permissionCheckInFlight = false
        guideRequested = false
        guideController.stop()
        accessibilityManager.stopMonitoring()
    }

    func refreshPermissionState() {
        requestPermissionCheck()
    }

    func openAccessibilitySettings() {
        guard !isTrusted,
              let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
              )
        else { return }

        guideRequested = true
        guideController.start()
        NSWorkspace.shared.open(url)
    }

    func languageDidChange() {
        guard guideRequested, !isTrusted else { return }
        guideController.languageDidChange()
    }

    private func requestPermissionCheck() {
        guard isPermissionMonitoringActive,
              !permissionCheckInFlight
        else { return }

        permissionCheckInFlight = true
        let generation = permissionCheckGeneration
        permissionCheckQueue.async { [weak self] in
            // This is the only work performed off-main: no AppKit, coordinator, or
            // manager state is read until the result is delivered to MainActor.
            let currentTrustState = AXIsProcessTrusted()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.applyPermissionCheckResult(
                        currentTrustState,
                        generation: generation
                    )
                }
            }
        }
    }

    private func applyPermissionCheckResult(
        _ currentTrustState: Bool,
        generation: UInt
    ) {
        // A result from before stop/restart must not recreate taps or reopen UI.
        guard isPermissionMonitoringActive,
              generation == permissionCheckGeneration
        else { return }

        permissionCheckInFlight = false
        accessibilityManager.updateAccessibilityPermissionState(currentTrustState)

        if currentTrustState {
            if !accessibilityManager.isMonitoring {
                _ = accessibilityManager.startMonitoring()
            }
            if isTrusted != currentTrustState {
                isTrusted = currentTrustState
            }
            guideRequested = false
            guideController.stop()
        } else {
            // Disable the active filter before publishing the UI state. Combine
            // subscribers can run synchronously, so this ordering keeps revocation
            // fail-open even during view updates.
            if accessibilityManager.isMonitoring || previousTrustState != false {
                accessibilityManager.stopMonitoring()
            }
            if isTrusted != currentTrustState {
                isTrusted = currentTrustState
            }
            if previousTrustState == true {
                onPermissionMissing()
            }
            if guideRequested {
                guideController.start()
            } else {
                guideController.stop()
            }
        }

        previousTrustState = currentTrustState
    }

    private func stopTimer() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}

@MainActor
private final class AccessibilityPermissionGuideController {
    private struct SystemSettingsWindow {
        let identifier: CGWindowID
        let frame: CGRect
        let title: String?
    }

    private let languageProvider: () -> AppLanguage
    private let onGuideEnded: () -> Void
    private var panel: NSPanel?
    private var followTimer: Timer?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var displayedLanguage: AppLanguage?
    private var cachedWindowIdentifier: CGWindowID?
    private var hasReachedAccessibilityPage = false
    private var confirmedAccessibilityPageTitle: String?
    private var isGuiding = false
    private let panelSize = CGSize(width: 440, height: 136)

    init(
        languageProvider: @escaping () -> AppLanguage,
        onGuideEnded: @escaping () -> Void
    ) {
        self.languageProvider = languageProvider
        self.onGuideEnded = onGuideEnded
    }

    func start() {
        guard !isGuiding else { return }
        isGuiding = true
        hasReachedAccessibilityPage = false
        confirmedAccessibilityPageTitle = nil
        cachedWindowIdentifier = nil

        let language = languageProvider()
        if panel == nil || displayedLanguage != language {
            configurePanel(language: language)
        }
        startObservingWorkspaceActivation()
        updateFollowingStateForFrontmostApplication()
    }

    func stop() {
        isGuiding = false
        hasReachedAccessibilityPage = false
        confirmedAccessibilityPageTitle = nil
        cachedWindowIdentifier = nil
        stopFollowingSystemSettings()
        stopObservingWorkspaceActivation()
        hidePanel()
    }

    func languageDidChange() {
        guard isGuiding else { return }
        configurePanel(language: languageProvider())
        updatePanelVisibilityAndPosition()
    }

    private func finishGuide() {
        guard isGuiding else { return }
        stop()
        onGuideEnded()
    }

    private func configurePanel(language: AppLanguage) {
        displayedLanguage = language
        let appURL = Bundle.main.bundleURL
        let rootView = AccessibilityPermissionGuideView(
            language: language,
            appURL: appURL
        )
        let hostingController = NSHostingController(rootView: rootView)

        let panel: NSPanel
        if let existingPanel = self.panel {
            panel = existingPanel
            panel.contentViewController = hostingController
        } else {
            panel = NSPanel(
                contentRect: CGRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentViewController = hostingController
            self.panel = panel
        }
        panel.setContentSize(panelSize)
    }

    private func startFollowingSystemSettings() {
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePanelVisibilityAndPosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowingSystemSettings() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func startObservingWorkspaceActivation() {
        guard workspaceActivationObserver == nil else { return }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateFollowingStateForFrontmostApplication()
            }
        }
    }

    private func stopObservingWorkspaceActivation() {
        guard let workspaceActivationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        self.workspaceActivationObserver = nil
    }

    private func updateFollowingStateForFrontmostApplication() {
        guard isGuiding else {
            stopFollowingSystemSettings()
            hidePanel()
            return
        }

        guard isSystemSettingsFrontmost else {
            stopFollowingSystemSettings()
            hidePanel()
            return
        }

        startFollowingSystemSettings()
        updatePanelVisibilityAndPosition()
    }

    private var isSystemSettingsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
    }

    private func updatePanelVisibilityAndPosition() {
        guard isGuiding, let panel else {
            hidePanel()
            return
        }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        ).first,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let settingsWindow = systemSettingsWindow(
                processIdentifier: application.processIdentifier
              )
        else {
            if !isSystemSettingsFrontmost {
                stopFollowingSystemSettings()
            }
            hidePanel()
            return
        }

        guard let title = settingsWindow.title, !title.isEmpty else {
            hidePanel()
            if hasReachedAccessibilityPage {
                finishGuide()
            }
            return
        }
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let confirmedAccessibilityPageTitle {
            guard normalizedTitle == confirmedAccessibilityPageTitle else {
                hidePanel()
                finishGuide()
                return
            }
        } else {
            guard AccessibilityPermissionGuideLayout.isAccessibilityPage(
                title: title,
                localizedAccessibilityTitle: localizedAccessibilityTitle(for: application)
            ) else {
                hidePanel()
                return
            }
            hasReachedAccessibilityPage = true
            confirmedAccessibilityPageTitle = normalizedTitle
        }

        guard let screen = screen(containingCGFrame: settingsWindow.frame),
              let cocoaFrame = cocoaFrame(fromCGFrame: settingsWindow.frame, on: screen)
        else {
            hidePanel()
            return
        }

        let targetOrigin = AccessibilityPermissionGuideLayout.panelOrigin(
            following: cocoaFrame,
            panelSize: panelSize,
            visibleFrame: screen.visibleFrame
        )
        if abs(panel.frame.minX - targetOrigin.x) > 0.5 ||
            abs(panel.frame.minY - targetOrigin.y) > 0.5 {
            panel.setFrameOrigin(targetOrigin)
        }
        showPanel()
    }

    private func localizedAccessibilityTitle(
        for application: NSRunningApplication
    ) -> String? {
        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL)
        else { return nil }
        let localizedTitle = bundle.localizedString(
            forKey: "Accessibility",
            value: nil,
            table: nil
        )
        return localizedTitle == "Accessibility" ? nil : localizedTitle
    }

    private func showPanel() {
        guard let panel, !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        panel.alphaValue = 1
        panel.orderOut(nil)
    }

    private func systemSettingsWindow(processIdentifier: pid_t) -> SystemSettingsWindow? {
        if let cachedWindowIdentifier,
           let window = windowInfo(
            options: [.optionIncludingWindow],
            relativeTo: cachedWindowIdentifier,
            processIdentifier: processIdentifier
           ) {
            return window
        }

        guard let window = windowInfo(
            options: [.optionOnScreenOnly, .excludeDesktopElements],
            relativeTo: kCGNullWindowID,
            processIdentifier: processIdentifier
        ) else { return nil }
        cachedWindowIdentifier = window.identifier
        return window
    }

    private func windowInfo(
        options: CGWindowListOption,
        relativeTo windowIdentifier: CGWindowID,
        processIdentifier: pid_t
    ) -> SystemSettingsWindow? {
        guard let windows = CGWindowListCopyWindowInfo(
            options,
            windowIdentifier
        ) as? [[CFString: Any]] else { return nil }

        return windows.lazy.compactMap { window -> SystemSettingsWindow? in
            guard (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let identifier = (window[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  frame.width >= 500,
                  frame.height >= 400
            else { return nil }
            return SystemSettingsWindow(
                identifier: identifier,
                frame: frame,
                title: window[kCGWindowName] as? String
            )
        }.first
    }

    private func screen(containingCGFrame frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { screen in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return false }
            return CGDisplayBounds(displayID.uint32Value).contains(center)
        }
    }

    private func cocoaFrame(fromCGFrame frame: CGRect, on screen: NSScreen) -> CGRect? {
        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        let displayBounds = CGDisplayBounds(displayID.uint32Value)
        return CGRect(
            x: screen.frame.minX + frame.minX - displayBounds.minX,
            y: screen.frame.maxY - (frame.minY - displayBounds.minY) - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

private struct AccessibilityPermissionGuideView: View {
    let language: AppLanguage
    let appURL: URL

    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(t("accessibilityPermissionTitle"))
                        .font(.headline)
                    Text(t("accessibilityPermissionMessage"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .frame(width: 30, height: 30)

                    Text("Windoor")
                        .font(.system(size: 13, weight: .regular))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                ApplicationFileDragSource(appURL: appURL)
            }
            .frame(height: 48)
            .help(t("accessibilityPermissionDragHint"))
        }
        .padding(14)
        .frame(width: 440, height: 136)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct ApplicationFileDragSource: NSViewRepresentable {
    let appURL: URL

    func makeNSView(context: Context) -> ApplicationFileDragView {
        ApplicationFileDragView(appURL: appURL)
    }

    func updateNSView(_ nsView: ApplicationFileDragView, context: Context) {
        nsView.appURL = appURL
    }
}

private final class ApplicationFileDragView: NSView, NSDraggingSource {
    var appURL: URL
    private var draggingStarted = false

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        draggingStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !draggingStarted else { return }
        draggingStarted = true

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 40, height: 40)
        let location = convert(event.locationInWindow, from: nil)
        let draggingItem = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        draggingItem.setDraggingFrame(
            NSRect(x: location.x - 20, y: location.y - 20, width: 40, height: 40),
            contents: icon
        )
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        draggingStarted = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        draggingStarted = false
    }
}
