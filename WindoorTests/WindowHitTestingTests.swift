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
            candidates: candidates,
            excludingProcessIdentifier: 999
        )

        #expect(selected?.processIdentifier == 101)
    }

    @Test func ignoresInvisibleAndOwnWindowsWithoutSkippingTheNextVisibleWindow() {
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
            candidates: candidates,
            excludingProcessIdentifier: 999
        )

        #expect(selected?.processIdentifier == 202)
    }
}
