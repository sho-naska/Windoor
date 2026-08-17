import ApplicationServices
import AppKit
import SwiftUI

enum AccessibilityPermissionGuideLayout {
    static func panelOrigin(
        following settingsFrame: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let belowWindowY = settingsFrame.minY - panelSize.height - 12
        let proposedOrigin = CGPoint(
            x: settingsFrame.midX - panelSize.width / 2,
            y: belowWindowY >= visibleFrame.minY
                ? belowWindowY
                : settingsFrame.minY + 18
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
}

@MainActor
final class AccessibilityPermissionCoordinator {
    private let accessibilityManager: AccessibilityManager
    private let languageProvider: () -> AppLanguage
    private let guideController: AccessibilityPermissionGuideController
    private var permissionTimer: Timer?
    private var previousTrustState: Bool?

    init(
        accessibilityManager: AccessibilityManager,
        languageProvider: @escaping () -> AppLanguage
    ) {
        self.accessibilityManager = accessibilityManager
        self.languageProvider = languageProvider
        self.guideController = AccessibilityPermissionGuideController(
            languageProvider: languageProvider
        )
    }

    func start() {
        stopTimer()
        refresh(openSystemSettingsWhenMissing: true)

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(openSystemSettingsWhenMissing: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func stop() {
        stopTimer()
        guideController.hide()
        accessibilityManager.stopMonitoring()
    }

    func presentGuideIfNeeded() {
        refresh(openSystemSettingsWhenMissing: true)
    }

    func languageDidChange() {
        guard previousTrustState == false else { return }
        guideController.show(openSystemSettings: false)
    }

    private func refresh(openSystemSettingsWhenMissing: Bool) {
        let isTrusted = AXIsProcessTrusted()

        if isTrusted {
            guideController.hide()
            if !accessibilityManager.isMonitoring {
                _ = accessibilityManager.startMonitoring()
            }
        } else {
            if accessibilityManager.isMonitoring || previousTrustState != false {
                accessibilityManager.stopMonitoring()
            }
            guideController.show(
                openSystemSettings: openSystemSettingsWhenMissing || previousTrustState != false
            )
        }

        previousTrustState = isTrusted
    }

    private func stopTimer() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}

@MainActor
private final class AccessibilityPermissionGuideController {
    private let languageProvider: () -> AppLanguage
    private var panel: NSPanel?
    private var followTimer: Timer?
    private var displayedLanguage: AppLanguage?
    private let panelSize = CGSize(width: 440, height: 184)

    init(languageProvider: @escaping () -> AppLanguage) {
        self.languageProvider = languageProvider
    }

    func show(openSystemSettings: Bool) {
        let language = languageProvider()
        if panel == nil || displayedLanguage != language {
            configurePanel(language: language)
        }

        guard let panel else { return }
        updatePanelPosition()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
        startFollowingSystemSettings()

        if openSystemSettings {
            openAccessibilitySettings()
        }
    }

    func hide() {
        followTimer?.invalidate()
        followTimer = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func configurePanel(language: AppLanguage) {
        displayedLanguage = language
        let appURL = Bundle.main.bundleURL
        let rootView = AccessibilityPermissionGuideView(
            language: language,
            appURL: appURL,
            openSettings: { [weak self] in self?.openAccessibilitySettings() }
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
                self?.updatePanelPosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func updatePanelPosition() {
        guard let panel else { return }
        let targetOrigin: CGPoint

        if let settingsFrame = systemSettingsWindowFrame(),
           let screen = screen(containingCGFrame: settingsFrame),
           let cocoaFrame = cocoaFrame(fromCGFrame: settingsFrame, on: screen) {
            targetOrigin = AccessibilityPermissionGuideLayout.panelOrigin(
                following: cocoaFrame,
                panelSize: panelSize,
                visibleFrame: screen.visibleFrame
            )
        } else {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            targetOrigin = CGPoint(
                x: screen.visibleFrame.midX - panelSize.width / 2,
                y: screen.visibleFrame.minY + 24
            )
        }

        if abs(panel.frame.minX - targetOrigin.x) > 0.5 ||
            abs(panel.frame.minY - targetOrigin.y) > 0.5 {
            panel.setFrameOrigin(targetOrigin)
        }
    }

    private func systemSettingsWindowFrame() -> CGRect? {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        ).first,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[CFString: Any]]
        else { return nil }

        return windows.lazy.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == application.processIdentifier,
                  (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  frame.width >= 500,
                  frame.height >= 400
            else { return nil }
            return frame
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

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct AccessibilityPermissionGuideView: View {
    let language: AppLanguage
    let appURL: URL
    let openSettings: () -> Void

    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.blue)

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
                        .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Windoor")
                            .font(.headline)
                        Text(appURL.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: "hand.draw")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                ApplicationFileDragSource(appURL: appURL)
            }
            .frame(height: 62)
            .help(t("accessibilityPermissionDragHint"))

            HStack {
                Label(t("accessibilityPermissionWaiting"), systemImage: "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(t("accessibilityPermissionOpenSettings"), action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 440, height: 184)
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
        icon.size = NSSize(width: 56, height: 56)
        let location = convert(event.locationInWindow, from: nil)
        let draggingItem = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        draggingItem.setDraggingFrame(
            NSRect(x: location.x - 28, y: location.y - 28, width: 56, height: 56),
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
