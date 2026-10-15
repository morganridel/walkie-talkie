import CoreGraphics

struct CropSelectionLifecycle {
    enum End { case completed, cancelled }
    private(set) var end: End?

    mutating func complete() -> Bool {
        guard end == nil else { return false }
        end = .completed
        return true
    }

    mutating func cancel() -> Bool {
        guard end == nil else { return false }
        end = .cancelled
        return true
    }
}

/// Screen-independent rectangle tracking shared by the overlay and its tests.
/// Coordinates use Cocoa's global, bottom-left origin.
public struct CropSelectionGeometry {
    private var start: CGPoint
    private var current: CGPoint
    private var lastPointer: CGPoint
    private var moving = false
    public private(set) var isMoving = false
    public private(set) var isCentered = false

    public init(anchor: CGPoint) {
        start = anchor
        current = anchor
        lastPointer = anchor
    }

    /// Updates a live drag. Command translates the current box, Option draws
    /// symmetrically around the anchor, and releasing Command resumes resizing.
    public mutating func update(to point: CGPoint, command: Bool = false,
                                option: Bool = false, allowsMove: Bool = true) {
        let shouldMove = command && allowsMove
        if shouldMove {
            let dx = point.x - lastPointer.x
            let dy = point.y - lastPointer.y
            start.x += dx
            start.y += dy
            current.x += dx
            current.y += dy
        } else if !moving {
            current = point
        }
        lastPointer = point
        moving = shouldMove
        isMoving = shouldMove
        isCentered = option
    }

    /// The current rectangle, optionally clipped to its display and checked
    /// against the gesture's minimum width and height.
    public func rect(minimum: CGFloat = 0, within bounds: CGRect? = nil) -> CGRect? {
        let raw: CGRect
        if isCentered {
            let dx = abs(current.x - start.x)
            let dy = abs(current.y - start.y)
            raw = CGRect(x: start.x - dx, y: start.y - dy, width: dx * 2, height: dy * 2)
        } else {
            raw = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                         width: abs(start.x - current.x), height: abs(start.y - current.y))
        }
        let result = bounds.map { raw.intersection($0) } ?? raw
        guard !result.isNull, result.width >= minimum, result.height >= minimum else { return nil }
        return result
    }
}
