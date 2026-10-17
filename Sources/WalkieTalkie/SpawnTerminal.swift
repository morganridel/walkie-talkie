import AppKit
import Foundation

/// Creates a prompted CLI chat, reusing an untouched idle Walkie terminal first.
/// Prompts are staged privately and never typed into a shell or an existing TUI.
enum SpawnTerminal {

    /// Scratch space for the two files above — beside the shots, and in Caches
    /// for the same reason they are: it is a staging area, not an archive, and
    /// what any of it is *for* is over within the turn that reads it. The
    /// outbox already keeps the durable copy of every word here.
    static let dir = Outbox.cacheRoot.deletingLastPathComponent()
        .appendingPathComponent("spawn")

    /// What opening one did — the same shape `TerminalBinding.Outcome` has, and
    /// for the same reason: the caller's only job with a failure is to say it out
    /// loud, since the outbox already has the words.
    enum Outcome {
        case opened(tty: String)
        case reused(CodexBridge.Conversation)
        case failed(String)
    }

    struct OpenDescriptor: Equatable {
        let tty: String
        let windowID: Int
        let windowLines: [String]
    }

    enum OpenDescriptorResult: Equatable {
        case descriptor(OpenDescriptor)
        case malformed(String)
    }

    /// Open the window, and say which tty it landed on so the relay can point
    /// itself at the session it just created.
    ///
    /// `near` is the pointer, in Cocoa screen coordinates — see
    /// `board(preferring:)` for what it buys. The caller latches it at the
    /// microphone's close, because that is the moment the original author means by *the
    /// screen I am on*; by the time this runs, seconds later, his hand has
    /// moved on.
    ///
    /// Runs subprocesses — call it off the main thread.
    static func launchClaude(prompt: String, directory: String, near: CGPoint? = nil) -> Outcome {
        do {
            if directory == NewChatFolder.workspace.path {
                try FileManager.default.createDirectory(at: NewChatFolder.workspace, withIntermediateDirectories: true)
            }
            let chat = try CodexBridge.createBackground(prompt: prompt, directory: directory)
            return .reused(chat)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Attach a view to an existing chat, without replaying its prompt or binding it.
    /// The caller verifies the current owner through prepare-open first.
    static func openChat(session: String, directory: String, near: CGPoint? = nil) -> Outcome {
        if let reason = resumeDirectoryFailure(directory) { return .failed(reason) }
        if let chat = try? CodexBridge.conversation(session), let tty = chat.terminalTTY,
           CodexBridge.resolve(tty: tty)?.id == session {
            return .reused(chat)
        }
        let requestFile = dir.appendingPathComponent("attach-\(Self.stamp()).json")
        defer { try? FileManager.default.removeItem(at: requestFile) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONSerialization.data(withJSONObject: [
                "resume": session, "directory": directory, "prompt": "", "images": [String]()
            ])
            try data.write(to: requestFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestFile.path)
            guard let helper = CodexBridge.launcherPath else { throw reuseFailure("Codex launcher is unavailable") }
            let result = TerminalBinding.runOutcome("/usr/bin/python3", [helper, "--reuse-request", requestFile.path], timeout: 110)
            guard case .ok(let output) = result,
                  let data = output.data(using: .utf8),
                  let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw reuseFailure("Terminal attachment outcome is unknown; it was not retried")
            }
            switch reply["status"] as? String {
            case "unavailable": break
            case "reused":
                guard reply["threadId"] as? String == session,
                      let chat = try CodexBridge.conversation(session) else {
                    throw reuseFailure("Terminal attachment could not be verified")
                }
                return .reused(chat)
            default: throw reuseFailure(reply["error"] as? String ?? "Terminal attachment outcome is unknown")
            }
        } catch { return .failed(error.localizedDescription) }
        return open(resumeScript(session: session, directory: directory),
                    stamp: Self.stamp(), directory: directory, near: near, what: "Codex chat")
    }

    private static func reuseFailure(_ message: String) -> NSError {
        NSError(domain: "SpawnTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// **A session that already exists, opened again in a window of its own** —
    /// what ⏎ does on a row of `RebindPanel` whose terminal has been closed.
    ///
    /// The search finds the session by something said in it, which is just as
    /// likely to be a session from Tuesday as one still on screen; for the ones
    /// still on screen there is a tty to point at, and for the rest there was
    /// nothing to offer until now. `claude --resume <id>` is the whole of it, and
    /// the window it opens is spawned, tiled, flown to and bound exactly like the
    /// one ⇧ + wheel opens — a resumed session is a destination that did not
    /// exist a second ago, which is the same sentence.
    ///
    /// **The directory matters and is not decoration.** A session id is scoped to
    /// the project folder Claude Code filed it under, so the launcher `cd`s there
    /// first; resumed from anywhere else the id is simply not found.
    ///
    /// Runs subprocesses — call it off the main thread.
    static func resumeClaude(session: String, directory: String, near: CGPoint? = nil) -> Outcome {
        if let reason = resumeDirectoryFailure(directory) { return .failed(reason) }
        return open(resumeScript(session: session, directory: directory),
                    stamp: Self.stamp(), directory: directory, near: near,
                    what: "resumed session \(session.prefix(8))")
    }

    /// Search rows deliberately do not touch their recorded project paths while
    /// the panel is drawing. The explicit resume is the authoritative boundary:
    /// it already runs off-main and can fail before staging or opening anything.
    static func resumeDirectoryFailure(_ directory: String) -> String? {
        var isDirectory: ObjCBool = false
        guard !directory.isEmpty,
              FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            let folder = (directory as NSString).lastPathComponent
            return "could not resume — \(folder.isEmpty ? "project folder" : folder) is unavailable"
        }
        return nil
    }

    private static func stamp() -> String {
        "\(Int(Date().timeIntervalSince1970))-\(UInt32.random(in: 0..<0xFFFF))"
    }

    /// **Everything both of them do once the launcher exists**: open the window,
    /// find out which tty it landed on, and tile it without activating Terminal.
    ///
    /// The two callers differ only in the script they stage — one starts a
    /// session with a prompt in its `argv`, the other reopens one by id — and the
    /// whole of the rest, which is where every trap in this file lives, is shared
    /// rather than copied.
    private static func open(_ body: String, stamp: String,
                             directory: String, near: CGPoint?, what: String) -> Outcome {
        let launcher = dir.appendingPathComponent("start-\(stamp).sh")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        } catch {
            return .failed("could not stage the new session — \(error.localizedDescription)")
        }

        // **Where it opens is not where Terminal would have put it.** See
        // `board(preferring:)` and `slot(for:on:avoiding:)`: tiled across the
        // displays around the Retina one, the one the pointer is on first, and
        // otherwise opened behind.
        let screens = board(preferring: near)
        // A cold launch must also stay behind the current application.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty {
            // Launch hidden and without activation before sending Apple events.
            let launch = TerminalBinding.runOutcome("/usr/bin/open", ["-g", "-j", "-b", "com.apple.Terminal"])
            guard case .ok = launch else { return .failed("Could not launch Terminal in the background") }
        }

        // `do script` with no `in` clause opens a **new window**, which is the
        // whole request: a second session beside the one he is in, not a line
        // typed into it. The tab it returns is how the relay finds the tty
        // without going back and guessing which window is in front — and by the
        // time an answer came back from that guess, the original author's hand may well have
        // moved on.
        //
        // **It also reports every window Terminal has**, in one round trip, since
        // the slot is chosen by *what is already there* and a second `osascript`
        // to ask would be a second launch of the interpreter for a list the first
        // one was already holding. `front window` is Terminal's own front, not
        // the screen's, so it names the window just created whether or not this
        // app was activated.
        //
        // **And it does not activate Terminal** (the original author, 2026-09-08: *"când
        // pornești un terminal nou… toate terminalele sar în față, inclusiv cele
        // de pe retina… nu ar trebui să apară nimic nou în față pe retina"*).
        // `activate` is an **application**-level raise: it lifts every window
        // Terminal owns, on every display, so tiling one new window onto a side
        // monitor also threw the four sessions he keeps on the built-in screen
        // over whatever he was reading there. It was in the first version of this
        // and never had a reason beyond "the new window should be seen" — which
        // the tiling now does properly, by putting it where nothing else is.
        //
        // Nothing is lost by dropping it: `front window` above is Terminal's own
        // ordering, so the new tab is still identified, and delivery is
        // `do script … in <tab>`, which never needed a window in front.
        let osa = Self.openAppleScript(launcherPath: launcher.path)
        let result = TerminalBinding.runOutcome("/usr/bin/osascript", ["-e", osa])
        let descriptor: OpenDescriptor
        switch result {
        case .ok(let reply):
            switch Self.parseOpenDescriptor(reply) {
            case .descriptor(let parsed): descriptor = parsed
            case .malformed(let reason):
                return .failed("Terminal returned an invalid session descriptor: \(reason)")
            }
        default:
            return .failed(Self.appleScriptFailure(result))
        }
        let tty = descriptor.tty
        let mine = descriptor.windowID

        var windows: [(id: Int, box: Box)] = []
        for line in descriptor.windowLines {
            let n = line.split(separator: " ").compactMap { Int($0) }
            guard n.count == 5 else { continue }
            windows.append((id: n[0], box: Box(x: n[1], y: n[2], w: n[3] - n[1], h: n[4] - n[2])))
        }

        var placed = "behind, no display but the Retina one"
        if !screens.isEmpty, let window = windows.first(where: { $0.id == mine }) {
            let taken = windows.filter { $0.id != mine }.map { $0.box }
            let target = slot(for: window.box, on: screens, avoiding: taken)
            let tileResult = TerminalBinding.runOutcome("/usr/bin/osascript", ["-e", Self.tileAppleScript(
                windowID: mine, x: target.x, y: target.y, width: target.w, height: target.h)])
            if case .ok = tileResult {
                placed = "tiled at \(target.x),\(target.y) \(target.w)×\(target.h)"
            } else {
                Log.error("✨ spawn window placement failed: \(Self.appleScriptFailure(tileResult))")
            }
        }

        Log.info("✨ \(what) in \(directory) on \((tty as NSString).lastPathComponent) — \(placed)")
        return .opened(tty: tty)
    }

    /// Terminal's scripting dictionary is addressed by its installed bundle ID,
    /// and the returned tab is an AppleScript command expression. Parentheses
    /// are required when assigning that command's result (`set t to (do script …)`).
    /// Keep this source isolated so the exact script can be syntax-checked without
    /// sending an Apple event or opening Terminal.
    static func openAppleScript(launcherPath: String) -> String {
        """
        tell application id "com.apple.Terminal"
            set t to (do script "\(escape(launcherPath))")
            set out to (tty of t) & linefeed & (id of front window as string)
            repeat with x in windows
                try
                    if visible of x then
                        set b to bounds of x
                        set out to out & linefeed & (id of x as string) & " " & (item 1 of b as string) & " " & (item 2 of b as string) & " " & (item 3 of b as string) & " " & (item 4 of b as string)
                    end if
                end try
            end repeat
            return out
        end tell
        """
    }

    static func tileAppleScript(windowID: Int, x: Int, y: Int, width: Int, height: Int) -> String {
        """
        tell application id "com.apple.Terminal" to set bounds of (first window whose id is \(windowID)) \
            to {\(x), \(y), \(x + width), \(y + height)}
        """
    }

    /// A rectangle in **AppleScript's** coordinates: origin at the top-left of
    /// the primary screen, y growing downwards. Everything below speaks these,
    /// because the only thing any of it is for is `set bounds of window`.
    private struct Box {
        var x: Int, y: Int, w: Int, h: Int
        var right: Int { x + w }
        var bottom: Int { y + h }
    }

    /// **The displays a spawned window is allowed to land on, left to right.**
    /// Added 2026-09-04 on the original author's ask: *"the terminal should be placed outside
    /// of the Retina screen if there is any other screen connected"*, and then
    /// *"tile them somehow so that they don't overlap with others… use all the
    /// monitors you have around"*.
    ///
    /// A spawn is by definition the one window he never pointed at: it appears on
    /// its own while his eyes are elsewhere. It used to `activate` and land
    /// wherever Terminal felt like, which in practice is on top of what he is
    /// reading on the built-in display.
    ///
    /// "Retina" is `backingScaleFactor >= 2` — the same test the
    /// `come-back-when-done` skill uses, and deliberately neither a size nor a
    /// name, so it holds whatever is plugged in. An empty result means there is
    /// nowhere to move a window to, and the caller opens it **behind** instead:
    /// the window still exists and `adoptSpawnedWindow` still binds it, since
    /// delivery is `do script … in <tab>` and never needs a window in front.
    ///
    /// **The lateral displays only, since 2026-09-09** — the original author's ask: *"start
    /// the terminals on the lateral screens, not on the screen above"*. At home
    /// he has three identical Dells around the built-in one: two beside it and
    /// **one stacked directly above** it, and the third was getting a third of
    /// the spawns. A screen above the laptop is the one place on that desk he
    /// has to lift his eyes off the keyboard to read, so a session that opens
    /// there is a session he has to go and find — which is exactly the failure
    /// the tiling was written to remove, moved from the Retina display to the
    /// one over it.
    ///
    /// "Lateral" is measured, not named: a screen is **stacked** when it shares
    /// more than half of its own width with the primary's horizontal span, and
    /// stacked screens are dropped. The primary itself is never stacked, so a
    /// desk of nothing but external monitors still tiles across all of them.
    /// Overlapping by a sliver — two monitors set side by side but nudged — is
    /// beside, not above, which is why this is a share of the width and not a
    /// test for any overlap at all.
    ///
    /// **The screen the pointer is on leads the list, since 2026-09-16** —
    /// the original author's ask: *"această fereastră să apară pe ecranul pe care am mouse-ul
    /// la momentul când închid dictarea… dacă sunt pe retina, îl pui pe un ecran
    /// extern, lateral"*. `slot(for:on:avoiding:)` reads left to right and takes
    /// the first empty cell it finds, so *first in this list* is *where the
    /// window lands* whenever that display has room — and when it has not, the
    /// scoring behind it falls through to the others exactly as before.
    ///
    /// It is a **preference, not a rule**, and that is the whole of the Retina
    /// clause: a pointer on the built-in display (or on a stacked one) matches
    /// nothing here, because neither is in the list at all, so the order is left
    /// to right as it has been since 2026-09-09 and the window still opens off
    /// the screen he is reading. There is no branch for it — the filter above is
    /// the branch.
    ///
    /// `frame`, not `visibleFrame`, for the containment test only: a pointer
    /// parked in a menu bar is still on that display.
    ///
    /// `visibleFrame`, not `frame`, so a menu bar or a Dock on a display is not
    /// tiled over.
    private static func board(preferring pointer: CGPoint?) -> [Box] {
        var found: [Box] = []
        let read = {
            let screens = NSScreen.screens
            guard !screens.isEmpty else { return }
            // The pivot for the y flip is the primary screen — the one at Cocoa
            // origin — wherever it sits in the list.
            let primary = screens.first { $0.frame.origin == .zero } ?? screens[0]
            let pivot = primary.frame.maxY
            // Above or below the primary rather than beside it — see the note.
            let stacked = { (screen: NSScreen) -> Bool in
                guard screen !== primary else { return false }
                let shared = min(screen.frame.maxX, primary.frame.maxX)
                           - max(screen.frame.minX, primary.frame.minX)
                return shared > screen.frame.width / 2
            }
            let lateral = screens.filter { $0.backingScaleFactor < 2 && !stacked($0) }
            let under = pointer.flatMap { p in lateral.first { $0.frame.contains(p) } }
            found = lateral
                // The pointer's screen is the minimum and everything else keeps
                // its left-to-right order behind it — one comparator rather than
                // a partition, so a nil pointer costs nothing and reads as the
                // same sort it always was.
                .sorted { a, b in
                    if (a === under) != (b === under) { return a === under }
                    return a.frame.minX < b.frame.minX
                }
                .map { screen -> Box in
                    let f = screen.visibleFrame
                    return Box(x: Int(f.minX.rounded()),
                               y: Int((pivot - f.maxY).rounded()),
                               w: Int(f.width.rounded()),
                               h: Int(f.height.rounded()))
                }
        }
        // `launchClaude` runs off the main thread by contract, and `NSScreen` is
        // main-thread state. The hop is a hop, not a deadlock, precisely because
        // of that contract.
        if Thread.isMainThread { read() } else { DispatchQueue.main.sync(execute: read) }
        return found
    }

    /// **Where this window goes so that it covers as little as possible of what
    /// is already open.**
    ///
    /// **Each display is cut into the original author Addons' four quadrants** (2026-10-04,
    /// the original author: *"să le așezi în modul de tile pe care îl pune default Mac OS
    /// addons. Nu rulat tile efectiv, dar … în colțuri"*) — the same rectangles
    /// as its `TerminalTileLayout.quadrants`: halves of the visible frame, 2 pt
    /// in from the outer edges, none between them, and the window takes the
    /// quadrant's size. The other windows are not touched; ⌘⌃A is still the tile.
    /// Until that day the cells were the size of the window itself, centred,
    /// which put two default-size terminals side by side in the middle. Every
    /// cell on every display is scored by how many square points of *other*
    /// Terminal windows it would sit on, and the first cell with the lowest
    /// score wins — TL, TR, BL, BR.
    ///
    /// **Scored rather than filtered**, so it degrades instead of failing: with
    /// every slot taken — six terminals across three monitors — the answer is the
    /// least-covered one rather than no answer at all, and the windows stack in
    /// the same order they were opened rather than piling on the first cell.
    /// Reading left to right across the displays is what makes a second spawn
    /// land beside the first instead of on it.
    ///
    /// Only Terminal's own windows are avoided. They are what this is laying out,
    /// they are what the question was about, and they are the only rectangles the
    /// same `osascript` was already holding — asking the window server about every
    /// app's windows would price a browser off these monitors on displays that are
    /// there to hold browsers.
    private static func slot(for window: Box, on screens: [Box], avoiding taken: [Box]) -> Box {
        var best: (cover: Int, box: Box)?
        for screen in screens {
            let hw = screen.w / 2, hh = screen.h / 2
            guard hw > quadrantMargin, hh > quadrantMargin else { continue }
            for row in 0..<2 {
                for col in 0..<2 {
                    let x = col == 0 ? screen.x + quadrantMargin : screen.x + hw
                    let y = row == 0 ? screen.y + quadrantMargin : screen.y + hh
                    let cell = Box(x: x, y: y, w: hw - quadrantMargin, h: hh - quadrantMargin)
                    let cover = taken.reduce(0) { $0 + overlap(cell, $1) }
                    // Strictly less, so ties go to the earlier cell and the order
                    // of the grid is the order windows fill it in.
                    if best == nil || cover < best!.cover { best = (cover, cell) }
                    // Nothing beats an empty cell; stop looking for a better one.
                    if cover == 0 { return cell }
                }
            }
        }
        return best?.box ?? window
    }

    /// the original author Addons' `TerminalTileLayout.margin` — kept equal by hand, the
    /// two apps share no code for it.
    private static let quadrantMargin = 2

    /// Square points two rectangles share, or zero.
    private static func overlap(_ a: Box, _ b: Box) -> Int {
        let w = min(a.right, b.right) - max(a.x, b.x)
        let h = min(a.bottom, b.bottom) - max(a.y, b.y)
        return w > 0 && h > 0 ? w * h : 0
    }

    /// **A login shell is what runs this, so `claude` is normally on the PATH
    /// already** — Terminal starts `zsh -l`, `.zshrc` is read, and this script
    /// is its child. The three directories are prepended anyway because the one
    /// failure mode here is silent and expensive: a window that opens, prints
    /// `command not found` and leaves the sentence nowhere. `~/.local/bin` is
    /// where the Claude Code installer puts it on this machine.
    ///
    /// **The prompt file is removed by the script that reads it**, not by this
    /// app: nothing else knows when it has been read, and a sweeper that ran on
    /// a timer would be racing the shell. The launcher itself stays — zsh reads
    /// a script incrementally, and deleting it out from under `exec` is a class
    /// of flake not worth the few hundred bytes it saves.
    private static func script(prompt: String, directory: String) -> String {
        let words = (try? String(contentsOfFile: prompt, encoding: .utf8)) ?? ""
        let images = CodexBridge.attachmentPaths(in: words).map { " --image " + quote($0) }.joined()
        return """
        #!/bin/zsh
        # Written by Walkie Talkie — shift + wheel, a dictation with no destination yet.
        PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd \(quote(directory)) 2>/dev/null || cd "$HOME"
        prompt="$(cat \(quote(prompt)))"
        rm -f \(quote(prompt))
        if [[ ! -x \(quote(CodexBridge.binaryPath ?? "")) ]]; then
          echo "walkie: Codex executable is unavailable — the dictation is in the outbox"
          echo "$prompt"
          exec /bin/zsh -l
        fi
        exec /usr/bin/python3 \(quote(CodexBridge.launcherPath ?? "")) --managed --cd \(quote(directory))\(images) -- "$prompt"
        """
    }

    /// The same shell, minus the prompt: `claude --resume <id>` in the folder the
    /// session belongs to. No file is staged for it — a session id is a uuid, so
    /// there is nothing here that needs keeping out of a command line, which is
    /// the whole reason the prompt gets a file of its own.
    private static func resumeScript(session: String, directory: String) -> String {
        """
        #!/bin/zsh
        # Written by Walkie Talkie — a session picked out of the Rebind to… search.
        PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd \(quote(directory)) 2>/dev/null || cd "$HOME"
        if [[ ! -x \(quote(CodexBridge.binaryPath ?? "")) ]]; then
          echo "walkie: Codex executable is unavailable — could not resume \(session)"
          exec /bin/zsh -l
        fi
        exec /usr/bin/python3 \(quote(CodexBridge.launcherPath ?? "")) --managed --cd \(quote(directory)) --resume \(quote(session))
        """
    }

    /// Single quotes, with the one character they cannot carry spelled out —
    /// everything else inside them is literal, which is exactly what a path
    /// containing a space, a `$` or a backtick needs.
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func parseOpenDescriptor(_ output: String) -> OpenDescriptorResult {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let tty = lines.first else { return .malformed("missing TTY") }
        guard tty.hasPrefix("/dev/") else { return .malformed("TTY is not a device path") }
        guard lines.count >= 2 else { return .malformed("missing Terminal window ID") }
        guard let windowID = Int(lines[1]) else { return .malformed("invalid Terminal window ID") }
        return .descriptor(OpenDescriptor(tty: tty, windowID: windowID,
                                          windowLines: Array(lines.dropFirst(2))))
    }

    static func appleScriptFailure(_ outcome: TerminalBinding.RunOutcome) -> String {
        switch outcome {
        case .ok:
            return "Terminal automation returned success without a failure reason"
        case .failed(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Terminal automation failed (osascript exit \(status))"
                + (detail.isEmpty ? "" : ": \(String(detail.prefix(200)))")
        case .timedOut(let seconds):
            return "Terminal automation timed out after \(Int(seconds)) seconds"
        case .couldNotRun(let reason):
            return "Could not start osascript: \(reason)"
        }
    }
}
