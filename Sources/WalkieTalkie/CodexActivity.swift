import AppKit

/// A small summary of work, separate from recording and delivery state.
struct CodexActivitySummary: Equatable {
    var boundWorking = false
    var boundWaiting = false
    var runningCount = 0
    var waitingCount = 0
    var boundError = false
    var errorCount = 0
    var unavailable = false

    init() {}
    init(_ payload: [String: Any], boundID: String?) {
        var seen: Set<String> = []
        for thread in payload["threads"] as? [[String: Any]] ?? [] {
            guard let id = thread["id"] as? String, seen.insert(id).inserted else { continue }
            let state = thread["state"] as? String ?? thread["status"] as? String ?? ""
            let waiting = state == "waitingOnApproval" || state == "waitingOnUserInput"
            let working = thread["busy"] as? Bool == true || state == "active" || waiting
            let failed = state == "error" || state == "systemError"
            if working { runningCount += 1 }
            if waiting { waitingCount += 1 }
            if failed { errorCount += 1 }
            if id == boundID {
                boundWorking = working
                boundWaiting = waiting
                boundError = failed
            }
        }
    }

    var description: String {
        if unavailable { return "Codex activity unavailable" }
        let bound = boundError ? "Bound chat needs attention" : boundWaiting ? "Bound chat needs your input" :
            boundWorking ? "Bound chat is working" : "Bound chat is idle"
        return "\(bound) · \(runningCount) running" +
            (waitingCount > 0 ? " · \(waitingCount) waiting for you" : "") +
            (errorCount > 0 ? " · \(errorCount) need attention" : "")
    }
}

/// Polls a read-only broker endpoint; the broker, not this UI, owns submitted turns.
final class CodexActivityMonitor {
    private var timer: Timer?
    private var polling = false
    private var boundID: (() -> String?)?
    private var summary = CodexActivitySummary()
    private let badge = CodexActivityBadge()
    private let startedAt = Date().timeIntervalSince1970
    private var completions: Set<String> = []

    func start(boundID: @escaping () -> String?) {
        self.boundID = boundID
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        guard !polling else { return }
        polling = true
        let bound = boundID?()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try CodexBridge.invoke(["background-status"] +
                (bound.map { ["--thread", $0] } ?? []), timeout: 10) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                // The binding can change while the subprocess reads status.
                let currentBound = self.boundID?()
                switch result {
                case .success(let payload):
                    self.summary = CodexActivitySummary(payload, boundID: currentBound)
                    self.summary.unavailable = payload["problem"] as? [String: Any] != nil
                    var completed = false
                    for event in payload["completions"] as? [[String: Any]] ?? [] {
                        guard let id = event["id"] as? String,
                              let timestamp = event["timestamp"] as? Double,
                              event["status"] as? String == "completed" else { continue }
                        if self.completions.insert(id).inserted, timestamp >= self.startedAt { completed = true }
                    }
                    self.badge.update(self.summary, completed: completed)
                case .failure:
                    // Keep known work visible, but never claim an unobserved idle state.
                    if self.summary.runningCount > 0 || currentBound != nil {
                        self.summary.unavailable = true
                        self.badge.update(self.summary, completed: false)
                    }
                }
            }
        }
    }

    func describe() -> [String: Any] {
        ["boundWorking": summary.boundWorking, "boundWaiting": summary.boundWaiting,
         "runningCount": summary.runningCount, "waitingCount": summary.waitingCount,
         "boundError": summary.boundError, "errorCount": summary.errorCount,
         "unavailable": summary.unavailable]
    }
}

/// Passive, nonactivating feedback above the pointer, clear of the recording chip.
private final class CodexActivityBadge {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 25),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let symbol = NSImageView()
    private let count = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var timer: Timer?
    private var summary = CodexActivitySummary()
    private var checkUntil = Date.distantPast

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 64, height: 25))
        root.material = .hudWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        panel.contentView = root
        progress.style = .spinning
        progress.controlSize = .small
        progress.frame = NSRect(x: 7, y: 5, width: 15, height: 15)
        symbol.frame = progress.frame
        symbol.contentTintColor = .labelColor
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        count.frame = NSRect(x: 28, y: 4, width: 31, height: 17)
        root.addSubview(symbol)
        root.addSubview(progress)
        root.addSubview(count)
    }

    func update(_ summary: CodexActivitySummary, completed: Bool) {
        self.summary = summary
        if completed { checkUntil = Date().addingTimeInterval(2.5) }
        draw()
        guard timer == nil, summary.runningCount > 0 || summary.errorCount > 0 || summary.unavailable || Date() < checkUntil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.draw() }
    }

    private func draw() {
        let check = Date() < checkUntil
        guard summary.runningCount > 0 || summary.errorCount > 0 || summary.unavailable || check else {
            panel.orderOut(nil)
            timer?.invalidate()
            timer = nil
            progress.stopAnimation(nil)
            return
        }
        let spin = summary.boundWorking && !summary.boundWaiting && !summary.unavailable && !check
        progress.isHidden = !spin
        if spin { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        symbol.isHidden = spin
        let name = check ? "checkmark" : summary.unavailable || summary.errorCount > 0 ? "exclamationmark.triangle" :
            summary.waitingCount > 0 ? "questionmark.bubble" : "bubble.left.and.bubble.right"
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        count.stringValue = summary.runningCount > 0 ? String(summary.runningCount) : ""
        panel.contentView?.setAccessibilityLabel(check ? "Codex result received. " + summary.description : summary.description)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = max(screen.minX, min(pointer.x + 18, screen.maxX - panel.frame.width))
        let y = max(screen.minY, min(pointer.y + 22, screen.maxY - panel.frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
