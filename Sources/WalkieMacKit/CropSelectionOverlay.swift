import AppKit

/// Text and options for a crop overlay. Kept configurable so each host can
/// localise the gesture instructions without changing the selection behavior.
public struct CropSelectionStyle {
    public let hint: String
    public let movingSuffix: String
    public let centeredSuffix: String
    public let allowsMove: Bool
    public let moveToSuffix: String

    public init(hint: String, movingSuffix: String, centeredSuffix: String,
                allowsMove: Bool = false, moveToSuffix: String = "") {
        self.hint = hint
        self.movingSuffix = movingSuffix
        self.centeredSuffix = centeredSuffix
        self.allowsMove = allowsMove
        self.moveToSuffix = moveToSuffix
    }
}

/// A screen-space selection. `movedTo` is populated when the user locks the
/// source rectangle and draws a destination for it.
public struct CropSelectionOverlay {
    public struct Selection {
        public let rect: NSRect
        public let screen: NSScreen
        public let movedTo: NSRect?

        fileprivate init(rect: NSRect, screen: NSScreen, movedTo: NSRect?) {
            self.rect = rect
            self.screen = screen
            self.movedTo = movedTo
        }
    }

    public enum Phase { case selecting, locked, parked, drawing, done }
    public enum Button { case middle }
    public typealias Completion = (Selection?) -> Void

    public static var log: ((String) -> Void)?
    public static var onAwaitingDestination: ((Bool) -> Void)?
    public static var onPhase: ((Phase) -> Void)?

    private final class State {
        var panels: [NSPanel] = []
        var views: [CropView] = []
        var screen: NSScreen!
        var style: CropSelectionStyle!
        var completion: Completion?
        var geometry: CropSelectionGeometry!
        var destinationStart: NSPoint?
        var destinationCurrent: NSPoint?
        var locked = false
        var parked = false
        var drawing = false
        var lifecycle = CropSelectionLifecycle()
        var monitor: Any?
    }

    private static var state: State?

    /// Put a dimmed, screen-recording-excluded overlay over every display.
    /// Drag positions are supplied by the host's event tap, which can continue
    /// to own the physical mouse events while the panels remain noninteractive.
    public static func begin(button: Button, from anchor: NSPoint,
                             style: CropSelectionStyle,
                             completion: @escaping Completion) {
        cancel()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main else {
            completion(nil)
            return
        }
        let s = State()
        s.screen = screen
        s.style = style
        s.completion = completion
        s.geometry = CropSelectionGeometry(anchor: anchor)
        state = s

        for display in NSScreen.screens {
            let panel = NSPanel(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false, screen: display)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.sharingType = .none
            panel.animationBehavior = .none
            let view = CropView(frame: NSRect(origin: .zero, size: display.frame.size))
            view.state = s
            view.screenOrigin = display.frame.origin
            panel.contentView = view
            s.panels.append(panel)
            s.views.append(view)
            panel.orderFrontRegardless()
        }
        s.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == 53 else { return event }
            cancel()
            return nil
        }
        onPhase?(.selecting)
        log?("crop overlay opened on \(screen.localizedName)")
    }

    /// Update the active box from a global Quartz event coordinate (origin at
    /// the top-left of the primary display).
    public static func dragMoved(toCG point: CGPoint) {
        guard let s = state else { return }
        let p = cocoaPoint(point)
        if s.drawing {
            s.destinationCurrent = p
        } else {
            let flags = NSEvent.modifierFlags
            s.geometry.update(to: p, command: flags.contains(.command),
                              option: flags.contains(.option), allowsMove: s.style.allowsMove)
            let shift = flags.contains(.shift)
            if s.style.allowsMove && shift != s.locked {
                s.locked = shift
                onPhase?(shift ? .locked : .selecting)
            }
        }
        redraw(s)
    }

    /// Called by the mouse tap when the original wheel press is released.
    /// A locked source waits for another wheel drag to mark its destination.
    public static func endDrag() {
        guard let s = state else { return }
        if s.drawing {
            guard let start = s.destinationStart, let end = s.destinationCurrent,
                  let drawnDestination = normalized(start, end, minimum: 6) else {
                cancel()
                return
            }
            let destination = drawnDestination.intersection(s.screen.frame)
            guard destination.width >= 6, destination.height >= 6 else {
                cancel()
                return
            }
            finish(s, rect: s.geometry.rect(minimum: 6, within: s.screen.frame) ?? .zero,
                   movedTo: destination)
            return
        }
        guard let rect = s.geometry.rect(minimum: 6, within: s.screen.frame) else {
            cancel()
            return
        }
        if s.locked {
            s.parked = true
            onAwaitingDestination?(true)
            onPhase?(.parked)
            log?("crop source locked; waiting for destination")
            redraw(s)
        } else {
            finish(s, rect: rect, movedTo: nil)
        }
    }

    /// Start the destination box from a second wheel press.
    public static func destinationPressed(atCG point: CGPoint) {
        guard let s = state, s.parked else { return }
        let p = cocoaPoint(point)
        s.drawing = true
        s.destinationStart = p
        s.destinationCurrent = p
        onAwaitingDestination?(false)
        onPhase?(.drawing)
        redraw(s)
    }

    /// A right click while selecting toggles whether release parks the source
    /// and waits for a destination. The toggle is intentionally sticky.
    public static func toggleMoveLock() {
        guard let s = state, !s.parked, !s.drawing, s.style.allowsMove else { return }
        s.locked.toggle()
        onPhase?(s.locked ? .locked : .selecting)
        redraw(s)
    }

    /// End a parked selection when its dictation has ended.
    public static func cancelIfParked() {
        guard state?.parked == true else { return }
        cancel()
    }

    /// Called by the host's event tap so Escape works even while another app
    /// remains frontmost during the nonactivating overlay.
    @discardableResult
    public static func escapePressed() -> Bool {
        guard state != nil else { return false }
        if Thread.isMainThread {
            cancel()
        } else {
            DispatchQueue.main.async { cancel() }
        }
        return true
    }

    /// Clear panels and complete with nil. Safe to call repeatedly.
    public static func cancel() {
        guard let s = state, s.lifecycle.cancel() else { return }
        state = nil
        tearDown(s)
        onAwaitingDestination?(false)
        onPhase?(.done)
        s.completion?(nil)
        log?("crop selection cancelled")
    }

    private static func finish(_ s: State, rect: NSRect, movedTo: NSRect?) {
        guard state === s, s.lifecycle.complete() else { return }
        state = nil
        tearDown(s)
        onAwaitingDestination?(false)
        onPhase?(.done)
        s.completion?(Selection(rect: rect, screen: s.screen, movedTo: movedTo))
    }

    private static func tearDown(_ s: State) {
        if let monitor = s.monitor { NSEvent.removeMonitor(monitor) }
        s.panels.forEach { $0.orderOut(nil) }
        s.panels.removeAll()
    }

    private static func redraw(_ s: State) { s.views.forEach { $0.needsDisplay = true } }

    private static func cocoaPoint(_ point: CGPoint) -> NSPoint {
        let primary = NSScreen.screens.first(where: { $0.frame.minY == 0 }) ?? NSScreen.screens[0]
        return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    private static func normalized(_ a: NSPoint, _ b: NSPoint, minimum: CGFloat) -> NSRect? {
        let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard rect.width >= minimum, rect.height >= minimum else { return nil }
        return rect
    }

    private final class CropView: NSView {
        weak var state: State?
        var screenOrigin = NSPoint.zero

        override var isFlipped: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            guard let s = state else { return }
            NSColor.black.withAlphaComponent(0.38).setFill()
            bounds.fill()
            let source = s.geometry.rect(minimum: 0, within: s.screen.frame) ?? .zero
            let sourceLocal = source.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            let box = NSBezierPath(roundedRect: sourceLocal, xRadius: 5, yRadius: 5)
            NSColor.systemYellow.setStroke()
            box.lineWidth = 2
            box.stroke()
            NSColor.systemYellow.withAlphaComponent(0.12).setFill()
            box.fill()
            if let start = s.destinationStart, let end = s.destinationCurrent,
               let destination = normalized(start, end, minimum: 0) {
                let local = destination.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
                let target = NSBezierPath(roundedRect: local, xRadius: 5, yRadius: 5)
                NSColor.systemTeal.setStroke()
                target.lineWidth = 2
                target.setLineDash([6, 4], count: 2, phase: 0)
                target.stroke()
            }
            drawLabel(s, source: sourceLocal)
        }

        private func drawLabel(_ s: State, source: NSRect) {
            var parts = [s.style.hint]
            if s.geometry.isMoving { parts.append(s.style.movingSuffix) }
            if s.geometry.isCentered { parts.append(s.style.centeredSuffix) }
            if s.locked { parts.append(s.style.moveToSuffix) }
            let text = parts.joined(separator: "  ·  ")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let rect = NSRect(x: source.minX, y: source.minY - size.height - 10,
                              width: size.width + 20, height: size.height + 12)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            (text as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 6), withAttributes: attrs)
        }
    }
}
