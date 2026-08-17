import AppKit
import CoreGraphics
import Testing
@testable import Windoor

@MainActor
struct WindowHitTestingTests {
    @Test func frontmostOnscreenCandidateWinsAcrossWindowLayers() {
        let point = CGPoint(x: 100, y: 100)
        let candidates = [
            WindowHitTestCandidate(
                processIdentifier: 101,
                frame: CGRect(x: 80, y: 80, width: 40, height: 40),
                layer: 3,
                alpha: 1
            ),
            WindowHitTestCandidate(
                processIdentifier: 202,
                frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                layer: 0,
                alpha: 1
            )
        ]

        let selected = WindowHitTester.frontmostCandidate(
            at: point,
            candidates: candidates
        )

        #expect(selected?.processIdentifier == 101)
    }

    @Test func ignoresInvisibleWindowButKeepsFrontmostWindowFromWindoorProcess() {
        let point = CGPoint(x: 100, y: 100)
        let candidates = [
            WindowHitTestCandidate(
                processIdentifier: 101,
                frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                layer: 3,
                alpha: 0
            ),
            WindowHitTestCandidate(
                processIdentifier: 999,
                frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                layer: 3,
                alpha: 1
            ),
            WindowHitTestCandidate(
                processIdentifier: 202,
                frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                layer: 0,
                alpha: 1
            )
        ]

        let selected = WindowHitTester.frontmostCandidate(
            at: point,
            candidates: candidates
        )

        #expect(selected?.processIdentifier == 999)
    }

    @Test func ignoresDisplaySizedSystemOverlayButKeepsSmallElevatedPanels() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        let point = CGPoint(x: 600, y: 400)
        let candidates = [
            WindowHitTestCandidate(
                processIdentifier: 101,
                frame: displayFrame,
                layer: 20,
                alpha: 1
            ),
            WindowHitTestCandidate(
                processIdentifier: 202,
                frame: CGRect(x: 500, y: 300, width: 240, height: 220),
                layer: 3,
                alpha: 1
            ),
            WindowHitTestCandidate(
                processIdentifier: 303,
                frame: CGRect(x: 200, y: 100, width: 1000, height: 700),
                layer: 0,
                alpha: 1
            )
        ]

        let selected = WindowHitTester.frontmostCandidate(
            at: point,
            candidates: candidates,
            displayFrames: [displayFrame]
        )

        #expect(selected?.processIdentifier == 202)
    }

    @Test func matchesDecoratedAccessibilityFrameToWindowServerPanel() {
        let windowServerFrame = CGRect(x: 300, y: 180, width: 260, height: 210)
        let accessibilityFrame = CGRect(x: 298, y: 176, width: 264, height: 218)

        #expect(WindowHitTester.framesLikelyMatch(accessibilityFrame, windowServerFrame))
    }

    @Test func doesNotMatchLargeUnderlyingParentToSmallFrontPanel() {
        let frontPanel = CGRect(x: 520, y: 340, width: 220, height: 180)
        let underlyingParent = CGRect(x: 200, y: 100, width: 1000, height: 760)

        #expect(!WindowHitTester.framesLikelyMatch(underlyingParent, frontPanel))
    }

    @Test func accessibilityGuideTracksSystemSettingsWindow() {
        let panelSize = CGSize(width: 440, height: 184)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let initialSettingsFrame = CGRect(x: 500, y: 520, width: 720, height: 550)
        let movedSettingsFrame = initialSettingsFrame.offsetBy(dx: 70, dy: -45)

        let initialOrigin = AccessibilityPermissionGuideLayout.panelOrigin(
            following: initialSettingsFrame,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        let movedOrigin = AccessibilityPermissionGuideLayout.panelOrigin(
            following: movedSettingsFrame,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        #expect(movedOrigin.x - initialOrigin.x == 70)
        #expect(movedOrigin.y - initialOrigin.y == -45)
    }
}
