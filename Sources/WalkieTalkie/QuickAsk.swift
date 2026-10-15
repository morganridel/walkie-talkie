import Foundation

/// **⚡ A quick question: answered by a fast Codex model, beside the pointer.**
/// A warmed `quick-worker` process answers through the signed-in Codex CLI; it
/// uses the account session and does not need an API key. Each worker handles
/// one question, then another is started while the answer is displayed.
///
/// The first answer stays lean: a short system prompt, no tools, and a private
/// working directory. The default is `gpt-6-luna` at low effort; `WT_QUICK_MODEL`
/// and `WT_QUICK_EFFORT` can override these values in the environment or
/// `elevenlabs.env`.
///
/// **Then the answer is checked, twice**: 🔎 a second process with web access
/// confirms or corrects the answer and cites its sources, then 🧐 a third,
/// told to challenge it, reviews the answer and sources. Each one is
/// started while the stage before it runs, so its start-up is not waited for.
/// The ✕ on the pop-up, or 🔼 ←, stops whatever stage is running.
final class QuickAsk {
    static let shared = QuickAsk()

    static let systemPrompt = """
        Answer spoken questions, which may contain speech recognition mistakes; \
        answer what the speaker most likely meant. Be brief: \
        what was asked in one short sentence, plus at most one closely related fact \
        worth knowing; plain text, no markdown, no lists unless asked. \
        Answer in the language of the question.
        """
    /// **Each check writes the whole answer again**: the pop-up always holds the best answer so far, so closing
    /// it at any moment leaves him with a complete one.
    /// **Only the proven facts, in the question's language, no quotes**: the quote is written only inside the marker, for
    /// the link to select it on the page.
    static let citeFormat = """
        Reply in the language of the question, plain text, no markdown. As short as \
        possible: what was asked, in one short sentence, plus at most one closely \
        related fact worth knowing. Never quote or translate the sources in the \
        answer, and never mention the checking, the sources or what changed. Right \
        after each claim put a marker [n: "<quote>"], where the quote is a short \
        passage (under 15 words) copied character for character, in the page's own \
        language, from page n that proves the claim — it is never shown, it selects \
        that passage when the page opens. After the answer, one line per source, \
        nothing else on it: [n] <url>. Last, only if the substance of your answer \
        differs from the one you were given, a line with just: CHANGED
        """
    static let webPrompt = """
        You were given a spoken question and a quick answer to it, written \
        from memory without any checking. Search the web for evidence, writing \
        nothing before your searches are done, and write the answer again: \
        corrected where the sources say otherwise, completed where they add \
        something that matters.
        """ + " " + citeFormat
    static let reviewPrompt = """
        You are an adversarial reviewer. You get a spoken question and an \
        answer to it with quotes and sources. Assume it is wrong somewhere and try \
        to prove it: open the cited pages and check that each quote is really \
        there and really means what the answer says (out of context, outdated, \
        about something else, a weak source); look for what is missing and \
        changes the answer. Write nothing before your checks are done, then write \
        the answer again, fixed.
        """ + " " + citeFormat
    /// A question with no answer by then is given up.
    static let timeout: TimeInterval = 45
    /// **The answer as shown** (2026-10-10, the original author: *"nu mă interesează să văd
    /// URL-urile complete … pune în paranteze rotunde numele site-ului, iar la
    /// hover … URL-ul complet. La click … să mă ducă la acel site, preferabil
    /// selectând textele"*): every `[n: "quote"]` becomes a blue ↗, a
    /// link (`ReplyPanel.link`) to its page with the quote selected there by a
    /// text fragment (`#:~:text=`) — the quote itself is never shown; the
    /// `[n] url` lines and `CHANGED` go. `changed` says the answer is not the one before it in substance.
    static func cited(_ raw: String) -> (text: String, changed: Bool) {
        var urls: [String: URL] = [:]
        var lines: [String] = []
        var changed = false
        let sourceLine = try! NSRegularExpression(pattern: #"^\s*\[(\d+)\]\s*(?:\S.*?\s)?(https?://\S+?)[).,]?\s*$"#)
        for line in raw.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = sourceLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let url = URL(string: ns.substring(with: m.range(at: 2))) {
                urls[ns.substring(with: m.range(at: 1))] = url
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "CHANGED" { changed = true; continue }
            lines.append(line)
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // [n: "quote"] (any of „" “” quotes), or a bare [n].
        let marked = try! NSRegularExpression(pattern: #"\s*\[(\d+)(?::\s*[„"“](.*?)[”"“]\s*)?\]"#)
        let ns = text as NSString
        var out = "", at = 0
        for m in marked.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            at = m.range.location + m.range.length
            guard let url = urls[ns.substring(with: m.range(at: 1))] else { continue }
            let quote = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            // **Just a blue ↗** (same day, the original author: *"doar o iconiță care să arate
            // o săgeată … pe un albastru, fără subliniere"*): the site's name is
            // the hover's, with the rest of the URL.
            out += " " + ReplyPanel.link("↗", quote.isEmpty ? url : fragment(url, quote: quote))
        }
        out += ns.substring(from: at)
        text = out.replacingOccurrences(of: " +([.,;:])", with: "$1", options: .regularExpression)
        return (text, changed)
    }

    /// `url` with `quote` selected when the page opens: Chrome's text fragment.
    /// A long quote is matched by its first and last words, which survive the
    /// small differences a model makes in the middle.
    static func fragment(_ url: URL, quote: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "._~!$'()*+;=:@/?")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let words = quote.split(whereSeparator: \.isWhitespace).map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "…")) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return url }
        let directive = words.count > 8
            ? "text=" + enc(words.prefix(4).joined(separator: " ")) + "," + enc(words.suffix(4).joined(separator: " "))
            : "text=" + enc(words.joined(separator: " "))
        var s = url.absoluteString
        s += s.contains("#") ? ":~:" + directive : "#:~:" + directive
        return URL(string: s) ?? url
    }

    /// The web check and the review, each.
    static let checkTimeout: TimeInterval = 120
    /// The follow-ups of one question, after its answer. Each gets its text so
    /// far, and `done: true` once, with the last of it — or why it failed.
    struct Checks {
        var web: (_ text: String, _ done: Bool) -> Void
        var review: (_ text: String, _ done: Bool) -> Void
        /// Everything is over: answered and checked, failed, or cancelled.
        var end: () -> Void
    }

    private let queue = DispatchQueue(label: "local.walkie-talkie.quick-ask")
    private var ready: Worker?
    /// The question being answered or checked — 🔼 ← or the ✕ take it down.
    private var current: Run?
    private var failedStarts = 0

    /// One question's processes, so a cancel stops whichever is running.
    private final class Run {
        var workers: [Worker] = []
        var cancelled = false
        var checks: Checks?
    }

    var model: String {
        guard let configured = Self.setting("WT_QUICK_MODEL"),
              configured != "opus", !configured.hasPrefix("claude-") else { return "gpt-6-luna" }
        return configured
    }
    var effort: String { Self.setting("WT_QUICK_EFFORT") ?? "low" }

    private static func setting(_ key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key] ?? ElevenLabsSource.fileValue(key)
        return v?.isEmpty == false ? v : nil
    }

    /// True while a question is being answered.
    var isAnswering: Bool { queue.sync { current != nil } }

    /// Who will answer the next question: the pop-up is signed with this name
    /// before the first word. The last served model is kept across launches;
    /// `onDone` still signs with the model that answered.
    var answererName: String {
        UserDefaults.standard.string(forKey: servedKey).map(Self.displayName) ?? Self.displayName(model)
    }
    private var servedKey: String { "WTQuickServed.\(model)" }

    /// Turn a Codex model ID such as `gpt-6-luna` into a short signature.
    static func displayName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return id }
        if parts[0].lowercased() == "gpt" {
            let name = parts.dropFirst().map { part in
                Double(part) != nil ? part : part.prefix(1).uppercased() + part.dropFirst()
            }
            return "GPT" + (name.isEmpty ? "" : "-" + name.joined(separator: " "))
        }
        return id
    }

    /// Starts the next process if none is waiting. Cheap to call often.
    func warm() {
        queue.async { self.warmLocked() }
    }

    private func warmLocked() {
        if let r = ready, r.alive { return }
        guard failedStarts < 3 else { return }
        do {
            ready = try Worker()
            ready?.onExit = { [weak self] w in
                self?.queue.async {
                    guard let self, self.ready === w else { return }
                    // An idle process that died on its own: start another, but not in a loop.
                    self.ready = nil
                    self.failedStarts += 1
                    Log.error("⚡ the waiting quick-answer process exited by itself (\(self.failedStarts)/3) — \(w.stderrTail)")
                    if self.failedStarts < 3 {
                        self.queue.asyncAfter(deadline: .now() + 2) { self.warmLocked() }
                    }
                }
            }
        } catch {
            failedStarts += 1
            Log.error("⚡ could not start the quick-answer process: \(error)")
        }
    }

    /// Asks one question. `onText` gets the answer so far, as it streams;
    /// `onDone` the whole answer, or nil and why it failed, and the model that
    /// answered. Then, when `checks` is given, the 🔎 web check and
    /// the 🧐 review of it. All callbacks on main.
    func ask(_ question: String, checks: Checks? = nil, onText: @escaping (String) -> Void,
             onDone: @escaping (_ answer: String?, _ error: String?, _ firstWord: TimeInterval?, _ model: String) -> Void) {
        queue.async {
            // A new question ends whatever the last one was still doing.
            self.cancelLocked()
            self.failedStarts = 0
            self.warmLocked()
            let modelName = Self.displayName(self.model)
            guard let w = self.ready, w.alive else {
                DispatchQueue.main.async {
                    let reason = CodexBridge.helperPath == nil ? "the Codex helper is missing"
                        : CodexBridge.binaryPath == nil ? "the Codex CLI is not installed"
                        : "the quick-answer worker did not start"
                    onDone(nil, reason, nil, modelName)
                    checks?.end()
                }
                return
            }
            self.ready = nil
            let run = Run()
            run.checks = checks
            run.workers = [w]
            self.current = run
            // The web check starts now, while the answer is being written.
            let web = checks == nil ? nil : self.start(run)
            let started = CFAbsoluteTimeGetCurrent()
            var first: TimeInterval?
            self.stage(run, w, question, system: Self.systemPrompt, web: false,
                       timeout: Self.timeout, onText: { text in
                if first == nil { first = CFAbsoluteTimeGetCurrent() - started }
                DispatchQueue.main.async { onText(text) }
            }, onDone: { answer, error in
                if let served = w.servedModel { UserDefaults.standard.set(served, forKey: self.servedKey) }
                let name = w.servedModel.map(Self.displayName) ?? modelName
                DispatchQueue.main.async { onDone(answer, error, first, name) }
                guard let checks, let answer, let web else { return self.endLocked(run) }
                self.check(run, question: question, answer: answer, web: web, checks: checks)
            })
            // The next one starts now, while this one answers.
            self.warmLocked()
        }
    }

    /// 🔎 then 🧐, on `queue`.
    private func check(_ run: Run, question: String, answer: String, web: Worker?, checks: Checks) {
        guard let web else {
            DispatchQueue.main.async { checks.web("⚠️ the web check did not start", true) }
            return endLocked(run)
        }
        // The reviewer starts while the web is searched.
        let reviewer = start(run)
        let asked = "Question: \(question)\n\nQuick answer, from memory: \(answer)"
        stage(run, web, asked, system: Self.webPrompt, web: true,
              timeout: Self.checkTimeout, onText: { text in
            DispatchQueue.main.async { checks.web(text, false) }
        }, onDone: { found, error in
            DispatchQueue.main.async { checks.web(found ?? "⚠️ \(error ?? "no result")", true) }
            guard let reviewer else {
                DispatchQueue.main.async { checks.review("⚠️ the reviewer did not start", true) }
                return self.endLocked(run)
            }
            // The reviewer criticises the searched answer — or, when the
            // search failed, the quick one.
            let all = found.map { "Question: \(question)\n\nAnswer, checked on the web:\n\($0)" }
                ?? asked + "\n\n(The web check failed: \(error ?? "?"). Search yourself.)"
            self.stage(run, reviewer, all, system: Self.reviewPrompt, web: true,
                       timeout: Self.checkTimeout, onText: { text in
                DispatchQueue.main.async { checks.review(text, false) }
            }, onDone: { verdict, error in
                DispatchQueue.main.async { checks.review(verdict ?? "⚠️ \(error ?? "no review")", true) }
                self.endLocked(run)
            })
        })
    }

    /// A process for a later stage of `run`, started now; nil when it could not be.
    private func start(_ run: Run) -> Worker? {
        guard let w = try? Worker() else { return nil }
        run.workers.append(w)
        return w
    }

    /// Sends `input` to `w` and calls `onDone` once — the result, its exit, or
    /// the timeout — on `queue`, unless the run was cancelled. Stops `w` after.
    private func stage(_ run: Run, _ w: Worker, _ input: String, system: String, web: Bool,
                       timeout: TimeInterval,
                       onText: @escaping (String) -> Void, onDone: @escaping (String?, String?) -> Void) {
        var finished = false
        let finish: (String?, String?) -> Void = { text, error in
            self.queue.async {
                guard !finished, !run.cancelled else { return }
                finished = true
                w.stop()
                onDone(text, error)
            }
        }
        w.onText = { text in if !run.cancelled { onText(text) } }
        w.onResult = { text, error in finish(text, error) }
        w.onExit = { w in finish(nil, "the Codex worker exited — \(w.stderrTail)") }
        w.send(input, system: system, model: model, effort: effort, web: web)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil, "nothing in \(Int(timeout)) s") }
    }

    private func endLocked(_ run: Run) {
        guard current === run else { return }
        current = nil
        run.workers.forEach { $0.stop() }
        if let end = run.checks?.end { DispatchQueue.main.async(execute: end) }
    }

    /// 🔼 ← or the ✕ while an answer is coming or being checked: drop all of
    /// it. True when there was one.
    @discardableResult
    func cancel() -> Bool { queue.sync { cancelLocked() } }

    private func cancelLocked() -> Bool {
        guard let run = current else { return false }
        current = nil
        run.cancelled = true
        for w in run.workers {
            w.onResult = nil
            w.onText = nil
            w.stop()
        }
        return true
    }

    /// One persistent `quick-worker` process speaking JSONL both ways.
    private final class Worker {
        private let process = Process()
        private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        private var buffer = Data()
        private var text = ""
        private var requestID: String?
        private var errText = ""
        private let lock = NSLock()
        var onText: ((String) -> Void)?
        var onResult: ((String?, String?) -> Void)?
        var onExit: ((Worker) -> Void)?
        /// The model ID reported by the worker for its completed response.
        private(set) var servedModel: String?

        var alive: Bool { process.isRunning }
        var stderrTail: String {
            lock.lock(); defer { lock.unlock() }
            let t = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "no stderr" : String(t.suffix(200))
        }

        init() throws {
            guard let helper = CodexBridge.helperPath else {
                throw NSError(domain: "QuickAsk", code: 1, userInfo: [NSLocalizedDescriptionKey: "codex_bridge.py not found"])
            }
            guard let binary = CodexBridge.binaryPath else {
                throw NSError(domain: "QuickAsk", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex CLI not found"])
            }
            let dir = Outbox.home.appendingPathComponent("quick")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [helper, "quick-worker"]
            process.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["CODEX_BIN"] = binary
            process.environment = env
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.read(h.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.lock(); self.errText += String(decoding: d, as: UTF8.self); self.lock.unlock()
            }
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.stdout.fileHandleForReading.readabilityHandler = nil
                self.stderr.fileHandleForReading.readabilityHandler = nil
                self.onExit?(self)
            }
            try process.run()
        }

        func send(_ question: String, system: String, model: String, effort: String, web: Bool) {
            let id = UUID().uuidString
            requestID = id
            let line: [String: Any] = [
                "id": id,
                "text": question,
                "system": system,
                "model": model,
                "effort": effort,
                "web": web,
                "cwd": Outbox.home.appendingPathComponent("quick").path,
            ]
            guard var data = try? JSONSerialization.data(withJSONObject: line) else { return }
            data.append(0x0A)
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }

        func stop() {
            onExit = nil
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        private func read(_ data: Data) {
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                handle(obj)
            }
        }

        private func handle(_ e: [String: Any]) {
            if let expected = requestID, let actual = e["id"] as? String, actual != expected { return }
            switch e["type"] as? String {
            case "ready":
                servedModel = e["model"] as? String ?? servedModel
            case "delta":
                guard let t = e["text"] as? String else { return }
                text = t
                onText?(text)
            case "completed":
                let result = (e["text"] as? String) ?? text
                servedModel = e["model"] as? String ?? servedModel
                onResult?(result, nil)
            case "error":
                let message = e["error"] as? String ?? "the quick model failed"
                onResult?(nil, message)
            default:
                return
            }
        }
    }
}
