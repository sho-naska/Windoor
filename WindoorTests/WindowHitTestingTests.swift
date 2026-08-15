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
}
