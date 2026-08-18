import CoreGraphics
import Foundation

enum DragAxisConstraint: Equatable {
    case none
    case horizontal
    case vertical
}

/// A concrete corner resolved from the user's resize-anchor preference.
enum ResizeAnchorCorner: Equatable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    init(
        selection: ResizeAnchorPoint,
        windowFrame: CGRect,
        cursorLocation: CGPoint
    ) {
        switch selection {
        case .topLeft:
            self = .topLeft
        case .topRight:
            self = .topRight
        case .bottomLeft:
            self = .bottomLeft
        case .bottomRight:
            self = .bottomRight
        case .nearest, .farthest:
            let nearest = Self.nearest(to: cursorLocation, in: windowFrame)
            self = selection == .nearest ? nearest : nearest.opposite
        }
    }

    private var opposite: Self {
        switch self {
        case .topLeft: .bottomRight
        case .topRight: .bottomLeft
        case .bottomLeft: .topRight
        case .bottomRight: .topLeft
        }
    }

    private static func nearest(to cursorLocation: CGPoint, in windowFrame: CGRect) -> Self {
        let corners: [(corner: Self, location: CGPoint)] = [
            (.topLeft, CGPoint(x: windowFrame.minX, y: windowFrame.minY)),
            (.topRight, CGPoint(x: windowFrame.maxX, y: windowFrame.minY)),
            (.bottomLeft, CGPoint(x: windowFrame.minX, y: windowFrame.maxY)),
            (.bottomRight, CGPoint(x: windowFrame.maxX, y: windowFrame.maxY))
        ]

        return corners.min { lhs, rhs in
            let lhsDeltaX = lhs.location.x - cursorLocation.x
            let lhsDeltaY = lhs.location.y - cursorLocation.y
            let rhsDeltaX = rhs.location.x - cursorLocation.x
            let rhsDeltaY = rhs.location.y - cursorLocation.y
            let lhsDistance = lhsDeltaX * lhsDeltaX + lhsDeltaY * lhsDeltaY
            let rhsDistance = rhsDeltaX * rhsDeltaX + rhsDeltaY * rhsDeltaY
            return lhsDistance < rhsDistance
        }!.corner
    }
}

/// Reflects the axes whose far edge is fixed so the interaction engine can always
/// operate as if the top-left corner were fixed.
struct ResizeAnchorTransform {
    let anchor: ResizeAnchorCorner

    /// AXSize preserves the top-left origin. Anchors on the right or bottom also
    /// require AXPosition to move the origin after each size change.
    var requiresPositionUpdate: Bool {
        reflectsHorizontally || reflectsVertically
    }

    private var reflectsHorizontally: Bool {
        anchor == .topRight || anchor == .bottomRight
    }

    private var reflectsVertically: Bool {
        anchor == .bottomLeft || anchor == .bottomRight
    }

    func enginePoint(from screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: reflectsHorizontally ? -screenPoint.x : screenPoint.x,
            y: reflectsVertically ? -screenPoint.y : screenPoint.y
        )
    }

    func engineFrame(from screenFrame: CGRect) -> CGRect {
        CGRect(
            x: reflectsHorizontally ? -screenFrame.maxX : screenFrame.minX,
            y: reflectsVertically ? -screenFrame.maxY : screenFrame.minY,
            width: screenFrame.width,
            height: screenFrame.height
        )
    }

    func screenFrame(from engineFrame: CGRect) -> CGRect {
        CGRect(
            x: reflectsHorizontally ? -engineFrame.maxX : engineFrame.minX,
            y: reflectsVertically ? -engineFrame.maxY : engineFrame.minY,
            width: engineFrame.width,
            height: engineFrame.height
        )
    }
}

struct EdgeResistanceConfiguration: Equatable {
    /// Pointer speeds above this value pass through neighboring edges without resistance.
    var slowVelocityThreshold: CGFloat = 500
    /// Additional pointer travel required to push through an edge once resistance starts.
    var releaseDistance: CGFloat = 28
    /// Prevents the edge that was just crossed from immediately catching the window again.
    var releaseClearance: CGFloat = 2
    /// Tiny corner contacts should not create edge resistance.
    var minimumOverlap: CGFloat = 18
    /// Remaining correction retained per drag update while the window catches the cursor.
    var catchUpRetention: CGFloat = 0.55

    static let standard = EdgeResistanceConfiguration()
}

/// Pure geometry/state engine for a Windoor drag. It intentionally does not know about AXUIElement,
/// so edge resistance and axis constraints can be tested without controlling another application.
struct WindowInteractionEngine {
    private enum Axis {
        case horizontal
        case vertical
    }

    private struct ResistanceLock {
        let obstacleEdge: CGFloat
        let lockedValue: CGFloat
        let pointerAtContact: CGFloat
        let direction: CGFloat
    }

    private struct SuppressedEdge {
        let value: CGFloat
        let direction: CGFloat
    }

    private struct AxisState {
        var resistance: ResistanceLock?
        var suppressedEdge: SuppressedEdge?
        var consumedPointerTravel: CGFloat = 0
        var catchUpOffset: CGFloat = 0
    }

    let mode: InteractionMode
    let initialFrame: CGRect
    let initialPointer: CGPoint
    let obstacleFrames: [CGRect]
    let configuration: EdgeResistanceConfiguration

    private var horizontalState = AxisState()
    private var verticalState = AxisState()
    private var lastPointer: CGPoint
    private var lastTimestamp: TimeInterval
    private(set) var currentFrame: CGRect

    var needsCatchUp: Bool {
        abs(horizontalState.catchUpOffset) > 0.25 || abs(verticalState.catchUpOffset) > 0.25
    }

    init(
        mode: InteractionMode,
        initialFrame: CGRect,
        initialPointer: CGPoint,
        obstacleFrames: [CGRect],
        timestamp: TimeInterval,
        configuration: EdgeResistanceConfiguration = .standard
    ) {
        self.mode = mode
        self.initialFrame = initialFrame
        self.initialPointer = initialPointer
        self.obstacleFrames = obstacleFrames
        self.configuration = configuration
        self.lastPointer = initialPointer
        self.lastTimestamp = timestamp
        self.currentFrame = initialFrame
    }

    mutating func frame(
        for pointer: CGPoint,
        timestamp: TimeInterval,
        constraint: DragAxisConstraint
    ) -> CGRect {
        let elapsed = timestamp - lastTimestamp
        let pointerDistance = hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y)
        let velocity: CGFloat
        if elapsed > 0, elapsed < 0.25 {
            velocity = pointerDistance / CGFloat(elapsed)
        } else {
            velocity = 0
        }

        var pointerDelta = CGPoint(
            x: pointer.x - initialPointer.x,
            y: pointer.y - initialPointer.y
        )
        switch constraint {
        case .horizontal:
            pointerDelta.y = 0
        case .vertical:
            pointerDelta.x = 0
        case .none:
            break
        }

        var proposed = initialFrame
        switch mode {
        case .move:
            proposed.origin.x += pointerDelta.x - horizontalState.consumedPointerTravel
            proposed.origin.y += pointerDelta.y - verticalState.consumedPointerTravel
        case .resize:
            proposed.size.width += pointerDelta.x - horizontalState.consumedPointerTravel
            proposed.size.height += pointerDelta.y - verticalState.consumedPointerTravel
        case .error, .none:
            return currentFrame
        }

        proposed = applyResistance(
            axis: .horizontal,
            proposedFrame: proposed,
            pointer: pointer,
            velocity: velocity
        )
        proposed = applyResistance(
            axis: .vertical,
            proposedFrame: proposed,
            pointer: pointer,
            velocity: velocity
        )

        currentFrame = proposed
        lastPointer = pointer
        lastTimestamp = timestamp
        return proposed
    }

    private mutating func applyResistance(
        axis: Axis,
        proposedFrame: CGRect,
        pointer: CGPoint,
        velocity: CGFloat
    ) -> CGRect {
        var frame = proposedFrame
        var state = axis == .horizontal ? horizontalState : verticalState
        let pointerValue = axis == .horizontal ? pointer.x : pointer.y

        if let resistance = state.resistance {
            let pushedDistance = (pointerValue - resistance.pointerAtContact) * resistance.direction
            if pushedDistance < -configuration.releaseClearance {
                state.resistance = nil
            } else if pushedDistance < configuration.releaseDistance {
                setValue(resistance.lockedValue, in: &frame, axis: axis)
                store(state, for: axis)
                return frame
            } else {
                // Native window dragging preserves the newly shifted grab offset after pushing through.
                // If the cursor has left the window, ease the window toward its original grab offset.
                let lockedFrame = frameBySetting(resistance.lockedValue, in: frame, axis: axis)
                if contains(pointerValue, in: lockedFrame, axis: axis) {
                    let rawMovingEdge = movingEdge(of: frame, axis: axis, direction: resistance.direction)
                    let travelPastEdge = (rawMovingEdge - resistance.obstacleEdge) * resistance.direction
                    state.consumedPointerTravel += max(0, travelPastEdge) * resistance.direction
                    setValue(resistance.lockedValue, in: &frame, axis: axis)
                } else {
                    let rawValue = value(in: frame, axis: axis)
                    state.catchUpOffset = rawValue - resistance.lockedValue
                    advanceCatchUp(state: &state, frame: &frame, axis: axis)
                }
                state.resistance = nil
                state.suppressedEdge = SuppressedEdge(
                    value: resistance.obstacleEdge,
                    direction: resistance.direction
                )
                store(state, for: axis)
                return frame
            }
        }

        if abs(state.catchUpOffset) > 0.25 {
            advanceCatchUp(state: &state, frame: &frame, axis: axis)
            store(state, for: axis)
            return frame
        }

        if let suppressed = state.suppressedEdge {
            let edge = movingEdge(of: frame, axis: axis, direction: suppressed.direction)
            if (edge - suppressed.value) * suppressed.direction > configuration.releaseClearance ||
                (edge - suppressed.value) * suppressed.direction < -configuration.releaseClearance {
                state.suppressedEdge = nil
                // The current update is the one that clears the recently crossed edge.
                // Let it pass before considering new resistance on the following update.
                store(state, for: axis)
                return frame
            }
        }

        let previousValue = value(in: currentFrame, axis: axis)
        let proposedValue = value(in: frame, axis: axis)
        let direction: CGFloat
        if proposedValue > previousValue {
            direction = 1
        } else if proposedValue < previousValue {
            direction = -1
        } else {
            store(state, for: axis)
            return frame
        }

        guard velocity <= configuration.slowVelocityThreshold,
              let contact = firstContact(
                axis: axis,
                from: currentFrame,
                to: frame,
                direction: direction,
                suppressedEdge: state.suppressedEdge?.value
              )
        else {
            store(state, for: axis)
            return frame
        }

        let previousMovingEdge = movingEdge(of: currentFrame, axis: axis, direction: direction)
        let proposedMovingEdge = movingEdge(of: frame, axis: axis, direction: direction)
        let movement = abs(proposedMovingEdge - previousMovingEdge)
        let overshoot = abs(proposedMovingEdge - contact.edge)
        let pointerAtContact: CGFloat
        if movement > 0 {
            let fractionBeforeContact = max(0, min(1, 1 - overshoot / movement))
            let previousPointerValue = axis == .horizontal ? lastPointer.x : lastPointer.y
            pointerAtContact = previousPointerValue + (pointerValue - previousPointerValue) * fractionBeforeContact
        } else {
            pointerAtContact = pointerValue
        }

        state.resistance = ResistanceLock(
            obstacleEdge: contact.edge,
            lockedValue: contact.lockedValue,
            pointerAtContact: pointerAtContact,
            direction: direction
        )
        setValue(contact.lockedValue, in: &frame, axis: axis)
        store(state, for: axis)
        return frame
    }

    private func firstContact(
        axis: Axis,
        from previousFrame: CGRect,
        to proposedFrame: CGRect,
        direction: CGFloat,
        suppressedEdge: CGFloat?
    ) -> (edge: CGFloat, lockedValue: CGFloat)? {
        let previousMovingEdge = movingEdge(of: previousFrame, axis: axis, direction: direction)
        let proposedMovingEdge = movingEdge(of: proposedFrame, axis: axis, direction: direction)

        var contacts: [(edge: CGFloat, lockedValue: CGFloat)] = []
        for obstacle in obstacleFrames where overlapsPerpendicular(proposedFrame, obstacle, axis: axis) {
            // Only the near edge can be approached from outside. Crossing the far edge means the
            // dragged edge was already inside the other window and is leaving it, so it must pass.
            let edge: CGFloat
            if axis == .horizontal {
                edge = direction > 0 ? obstacle.minX : obstacle.maxX
            } else {
                edge = direction > 0 ? obstacle.minY : obstacle.maxY
            }
            if let suppressedEdge, abs(edge - suppressedEdge) < 0.5 { continue }

            let crossed: Bool
            if direction > 0 {
                crossed = previousMovingEdge <= edge && proposedMovingEdge >= edge
            } else {
                crossed = previousMovingEdge >= edge && proposedMovingEdge <= edge
            }
            guard crossed else { continue }

            let lockedValue: CGFloat
            if mode == .move {
                let length = axis == .horizontal ? proposedFrame.width : proposedFrame.height
                lockedValue = direction > 0 ? edge - length : edge
            } else {
                let origin = axis == .horizontal ? proposedFrame.minX : proposedFrame.minY
                lockedValue = edge - origin
            }
            guard lockedValue > 0 || mode == .move else { continue }
            contacts.append((edge, lockedValue))
        }

        if direction > 0 {
            return contacts.min(by: { $0.edge < $1.edge })
        }
        return contacts.max(by: { $0.edge < $1.edge })
    }

    private func overlapsPerpendicular(_ lhs: CGRect, _ rhs: CGRect, axis: Axis) -> Bool {
        let overlap: CGFloat
        if axis == .horizontal {
            overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        } else {
            overlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
        }
        return overlap >= configuration.minimumOverlap
    }

    private func movingEdge(of frame: CGRect, axis: Axis, direction: CGFloat) -> CGFloat {
        if mode == .resize {
            return axis == .horizontal ? frame.maxX : frame.maxY
        }
        if axis == .horizontal {
            return direction > 0 ? frame.maxX : frame.minX
        }
        return direction > 0 ? frame.maxY : frame.minY
    }

    private func value(in frame: CGRect, axis: Axis) -> CGFloat {
        if mode == .move {
            return axis == .horizontal ? frame.minX : frame.minY
        }
        return axis == .horizontal ? frame.width : frame.height
    }

    private func setValue(_ value: CGFloat, in frame: inout CGRect, axis: Axis) {
        if mode == .move {
            if axis == .horizontal { frame.origin.x = value } else { frame.origin.y = value }
        } else {
            if axis == .horizontal { frame.size.width = value } else { frame.size.height = value }
        }
    }

    private func frameBySetting(_ value: CGFloat, in frame: CGRect, axis: Axis) -> CGRect {
        var result = frame
        setValue(value, in: &result, axis: axis)
        return result
    }

    private func contains(_ value: CGFloat, in frame: CGRect, axis: Axis) -> Bool {
        let range = axis == .horizontal ? frame.minX...frame.maxX : frame.minY...frame.maxY
        return range.contains(value)
    }

    private func advanceCatchUp(state: inout AxisState, frame: inout CGRect, axis: Axis) {
        state.catchUpOffset *= configuration.catchUpRetention
        if abs(state.catchUpOffset) <= 0.25 {
            state.catchUpOffset = 0
        }
        setValue(value(in: frame, axis: axis) - state.catchUpOffset, in: &frame, axis: axis)
    }

    private mutating func store(_ state: AxisState, for axis: Axis) {
        if axis == .horizontal {
            horizontalState = state
        } else {
            verticalState = state
        }
    }
}
