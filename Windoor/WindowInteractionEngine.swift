import CoreGraphics
import Foundation

enum DragAxisConstraint: Equatable {
    case none
    case horizontal
    case vertical
}

enum ResizeAnchorCorner: CaseIterable, Equatable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var opposite: ResizeAnchorCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }

    func point(in frame: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    func frame(size: CGSize, anchoredIn frame: CGRect) -> CGRect {
        let origin: CGPoint
        switch self {
        case .topLeft:
            origin = CGPoint(x: frame.minX, y: frame.minY)
        case .topRight:
            origin = CGPoint(x: frame.maxX - size.width, y: frame.minY)
        case .bottomLeft:
            origin = CGPoint(x: frame.minX, y: frame.maxY - size.height)
        case .bottomRight:
            origin = CGPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        }
        return CGRect(origin: origin, size: size)
    }

    fileprivate func anchorsMinimumEdge(on axis: WindowInteractionEngine.Axis) -> Bool {
        switch (self, axis) {
        case (.topLeft, _): return true
        case (.topRight, .horizontal): return false
        case (.topRight, .vertical): return true
        case (.bottomLeft, .horizontal): return true
        case (.bottomLeft, .vertical): return false
        case (.bottomRight, _): return false
        }
    }
}

extension ResizeAnchorPoint {
    func resolvedCorner(in frame: CGRect, pointer: CGPoint) -> ResizeAnchorCorner {
        switch self {
        case .topLeft:
            return .topLeft
        case .topRight:
            return .topRight
        case .bottomLeft:
            return .bottomLeft
        case .bottomRight:
            return .bottomRight
        case .nearestCorner, .farthestCorner:
            let nearest = ResizeAnchorCorner.allCases.min { lhs, rhs in
                let lhsPoint = lhs.point(in: frame)
                let rhsPoint = rhs.point(in: frame)
                let lhsDistance = hypot(pointer.x - lhsPoint.x, pointer.y - lhsPoint.y)
                let rhsDistance = hypot(pointer.x - rhsPoint.x, pointer.y - rhsPoint.y)
                return lhsDistance < rhsDistance
            } ?? .topLeft
            return self == .nearestCorner ? nearest : nearest.opposite
        }
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
    fileprivate enum Axis {
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
    let resizeAnchorCorner: ResizeAnchorCorner

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
        resizeAnchorCorner: ResizeAnchorCorner = .topLeft,
        configuration: EdgeResistanceConfiguration = .standard
    ) {
        self.mode = mode
        self.initialFrame = initialFrame
        self.initialPointer = initialPointer
        self.obstacleFrames = obstacleFrames
        self.configuration = configuration
        self.resizeAnchorCorner = resizeAnchorCorner
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
            setValue(
                value(in: initialFrame, axis: .horizontal) +
                    pointerDelta.x - horizontalState.consumedPointerTravel,
                in: &proposed,
                axis: .horizontal
            )
            setValue(
                value(in: initialFrame, axis: .vertical) +
                    pointerDelta.y - verticalState.consumedPointerTravel,
                in: &proposed,
                axis: .vertical
            )
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
                lockedValue = edge
            }
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
            if resizeAnchorCorner.anchorsMinimumEdge(on: axis) {
                return axis == .horizontal ? frame.maxX : frame.maxY
            }
            return axis == .horizontal ? frame.minX : frame.minY
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
        return movingEdge(of: frame, axis: axis, direction: 0)
    }

    private func setValue(_ value: CGFloat, in frame: inout CGRect, axis: Axis) {
        if mode == .move {
            if axis == .horizontal { frame.origin.x = value } else { frame.origin.y = value }
        } else {
            let fixedPoint = resizeAnchorCorner.point(in: initialFrame)
            let anchorsMinimumEdge = resizeAnchorCorner.anchorsMinimumEdge(on: axis)
            if axis == .horizontal {
                if anchorsMinimumEdge {
                    frame.origin.x = fixedPoint.x
                    frame.size.width = max(1, value - fixedPoint.x)
                } else {
                    frame.size.width = max(1, fixedPoint.x - value)
                    frame.origin.x = fixedPoint.x - frame.size.width
                }
            } else if anchorsMinimumEdge {
                frame.origin.y = fixedPoint.y
                frame.size.height = max(1, value - fixedPoint.y)
            } else {
                frame.size.height = max(1, fixedPoint.y - value)
                frame.origin.y = fixedPoint.y - frame.size.height
            }
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
