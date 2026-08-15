import AppKit
import CoreGraphics
import Testing
@testable import Windoor

@MainActor
struct WindowInteractionEngineTests {
    @Test func slowMoveResistsThenKeepsShiftedGrabOffset() {
        var engine = WindowInteractionEngine(
            mode: .move,
            initialFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            initialPointer: CGPoint(x: 50, y: 50),
            obstacleFrames: [CGRect(x: 150, y: 0, width: 100, height: 100)],
            timestamp: 0
        )

        let contact = engine.frame(for: CGPoint(x: 105, y: 50), timestamp: 0.2, constraint: .none)
        #expect(contact.minX == 50)

        let resisted = engine.frame(for: CGPoint(x: 125, y: 50), timestamp: 0.3, constraint: .none)
        #expect(resisted.minX == 50)

        let released = engine.frame(for: CGPoint(x: 140, y: 50), timestamp: 0.4, constraint: .none)
        #expect(released.minX == 50)

        let followsNewOffset = engine.frame(for: CGPoint(x: 145, y: 50), timestamp: 0.5, constraint: .none)
        #expect(followsNewOffset.minX == 55)
    }

    @Test func fastMoveIgnoresResistance() {
        var engine = WindowInteractionEngine(
            mode: .move,
            initialFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            initialPointer: CGPoint(x: 50, y: 50),
            obstacleFrames: [CGRect(x: 150, y: 0, width: 100, height: 100)],
            timestamp: 0
        )

        let frame = engine.frame(for: CGPoint(x: 120, y: 50), timestamp: 0.02, constraint: .none)
        #expect(frame.minX == 70)
    }

    @Test func moderatelyFastMoveAlsoIgnoresResistance() {
        var engine = WindowInteractionEngine(
            mode: .move,
            initialFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            initialPointer: CGPoint(x: 50, y: 50),
            obstacleFrames: [CGRect(x: 150, y: 0, width: 100, height: 100)],
            timestamp: 0
        )

        let frame = engine.frame(for: CGPoint(x: 110, y: 50), timestamp: 0.1, constraint: .none)
        #expect(frame.minX == 60)
    }

    @Test func resizeCatchUpKeepsPointerInsideAfterBreakthrough() {
        var engine = WindowInteractionEngine(
            mode: .resize,
            initialFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            initialPointer: CGPoint(x: 99, y: 99),
            obstacleFrames: [CGRect(x: 150, y: 0, width: 100, height: 100)],
            timestamp: 0
        )

        _ = engine.frame(for: CGPoint(x: 154, y: 99), timestamp: 0.2, constraint: .none)
        let released = engine.frame(for: CGPoint(x: 190, y: 99), timestamp: 0.3, constraint: .none)

        #expect(released.maxX > 150)
        #expect(released.maxX < 191)

        var previous = released
        for step in 1...8 {
            let next = engine.frame(
                for: CGPoint(x: 190, y: 99),
                timestamp: 0.3 + Double(step) * 0.02,
                constraint: .none
            )
            #expect(next.maxX >= previous.maxX)
            previous = next
        }
        #expect(previous.maxX == 191)
        #expect(previous.contains(CGPoint(x: 190, y: 99)))
    }

    @Test func movingFromInsideAnObstacleToOutsideHasNoResistance() {
        var engine = WindowInteractionEngine(
            mode: .move,
            initialFrame: CGRect(x: 120, y: 0, width: 50, height: 100),
            initialPointer: CGPoint(x: 140, y: 50),
            obstacleFrames: [CGRect(x: 100, y: 0, width: 100, height: 100)],
            timestamp: 0
        )

        let frame = engine.frame(for: CGPoint(x: 180, y: 50), timestamp: 0.2, constraint: .none)
        #expect(frame.minX == 160)
        #expect(frame.maxX == 210)
    }

    @Test func resizeResistsOnlyWhenApproachingFromOutside() {
        var growing = WindowInteractionEngine(
            mode: .resize,
            initialFrame: CGRect(x: 0, y: 0, width: 50, height: 100),
            initialPointer: CGPoint(x: 49, y: 50),
            obstacleFrames: [CGRect(x: 100, y: 0, width: 100, height: 100)],
            timestamp: 0
        )
        let contact = growing.frame(
            for: CGPoint(x: 109, y: 50),
            timestamp: 0.2,
            constraint: .none
        )
        #expect(contact.width == 100)

        var shrinkingOut = WindowInteractionEngine(
            mode: .resize,
            initialFrame: CGRect(x: 0, y: 0, width: 150, height: 100),
            initialPointer: CGPoint(x: 149, y: 50),
            obstacleFrames: [CGRect(x: 100, y: 0, width: 100, height: 100)],
            timestamp: 0
        )
        let outside = shrinkingOut.frame(
            for: CGPoint(x: 89, y: 50),
            timestamp: 0.2,
            constraint: .none
        )
        #expect(outside.width == 90)
    }

    @Test func axisConstraintUsesOriginalDragOrigin() {
        var engine = WindowInteractionEngine(
            mode: .move,
            initialFrame: CGRect(x: 20, y: 30, width: 100, height: 100),
            initialPointer: CGPoint(x: 50, y: 60),
            obstacleFrames: [],
            timestamp: 0
        )

        let horizontal = engine.frame(for: CGPoint(x: 90, y: 120), timestamp: 0.1, constraint: .horizontal)
        #expect(horizontal.origin == CGPoint(x: 60, y: 30))

        let vertical = engine.frame(for: CGPoint(x: 90, y: 120), timestamp: 0.2, constraint: .vertical)
        #expect(vertical.origin == CGPoint(x: 20, y: 90))
    }

    @Test func nearestAndFarthestAnchorsResolveToDiagonalCorners() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)

        #expect(
            ResizeAnchorCorner(
                selection: .nearest,
                windowFrame: frame,
                cursorLocation: CGPoint(x: 120, y: 225)
            ) == .topLeft
        )
        #expect(
            ResizeAnchorCorner(
                selection: .farthest,
                windowFrame: frame,
                cursorLocation: CGPoint(x: 120, y: 225)
            ) == .bottomRight
        )
        #expect(
            ResizeAnchorCorner(
                selection: .nearest,
                windowFrame: frame,
                cursorLocation: CGPoint(x: 485, y: 480)
            ) == .bottomRight
        )
        #expect(
            ResizeAnchorCorner(
                selection: .farthest,
                windowFrame: frame,
                cursorLocation: CGPoint(x: 485, y: 480)
            ) == .topLeft
        )
    }

    @Test func resizeAnchorTransformKeepsTheSelectedCornerFixed() {
        let initialFrame = CGRect(x: 100, y: 200, width: 300, height: 400)
        let initialPointer = CGPoint(x: 250, y: 400)
        let cases: [(ResizeAnchorCorner, CGPoint, CGPoint)] = [
            (.topLeft, CGPoint(x: 270, y: 430), CGPoint(x: 100, y: 200)),
            (.topRight, CGPoint(x: 230, y: 430), CGPoint(x: 400, y: 200)),
            (.bottomLeft, CGPoint(x: 270, y: 370), CGPoint(x: 100, y: 600)),
            (.bottomRight, CGPoint(x: 230, y: 370), CGPoint(x: 400, y: 600))
        ]

        for (anchor, draggedPointer, fixedCorner) in cases {
            let transform = ResizeAnchorTransform(anchor: anchor)
            var engine = WindowInteractionEngine(
                mode: .resize,
                initialFrame: transform.engineFrame(from: initialFrame),
                initialPointer: transform.enginePoint(from: initialPointer),
                obstacleFrames: [],
                timestamp: 0
            )

            let resizedFrame = transform.screenFrame(
                from: engine.frame(
                    for: transform.enginePoint(from: draggedPointer),
                    timestamp: 0.2,
                    constraint: .none
                )
            )

            #expect(resizedFrame.size == CGSize(width: 320, height: 430))
            switch anchor {
            case .topLeft:
                #expect(resizedFrame.origin == fixedCorner)
            case .topRight:
                #expect(CGPoint(x: resizedFrame.maxX, y: resizedFrame.minY) == fixedCorner)
            case .bottomLeft:
                #expect(CGPoint(x: resizedFrame.minX, y: resizedFrame.maxY) == fixedCorner)
            case .bottomRight:
                #expect(CGPoint(x: resizedFrame.maxX, y: resizedFrame.maxY) == fixedCorner)
            }
        }
    }

    @Test func mouseOnlyShortcutIsNotAKeyboardTrigger() {
        let mouseOnly = ShortcutSetting(
            keyCode: -1,
            flags: 0,
            mouseButton: .left,
            allowModifierOnly: true
        )
        let shiftOnly = ShortcutSetting(
            keyCode: -1,
            flags: NSEvent.ModifierFlags.shift.rawValue,
            mouseButton: .left,
            allowModifierOnly: true
        )
        let keyOnly = ShortcutSetting(
            keyCode: 0,
            flags: 0,
            mouseButton: .left,
            allowModifierOnly: false
        )

        #expect(!mouseOnly.hasKeyboardTrigger)
        #expect(mouseOnly.isLeftClickOnly)
        #expect(!mouseOnly.isValidTrigger)
        #expect(shiftOnly.hasKeyboardTrigger)
        #expect(shiftOnly.isValidTrigger)
        #expect(keyOnly.hasKeyboardTrigger)
        #expect(keyOnly.isValidTrigger)

        let rightClickOnly = ShortcutSetting(
            keyCode: -1,
            flags: 0,
            mouseButton: .right,
            allowModifierOnly: true
        )
        #expect(!rightClickOnly.hasKeyboardTrigger)
        #expect(!rightClickOnly.isLeftClickOnly)
        #expect(rightClickOnly.isValidTrigger)
    }
}
