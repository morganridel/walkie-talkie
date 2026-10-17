import Foundation

/// Same-user file IPC for sandboxed reply helpers. The temporary directory is
/// already writable to ordinary Codex commands, so replies need no network
/// exception. Requests are claimed once; a crash never replays a claimed reply.
final class ReplyInbox {
    let directory: URL
    private let descriptor: URL
    private let handler: ([String: Any]) -> (Int, [String: Any])
    private var timer: DispatchSourceTimer?

    init(home: URL, temporary: URL = FileManager.default.temporaryDirectory,
         handler: @escaping ([String: Any]) -> (Int, [String: Any])) throws {
        directory = temporary.appendingPathComponent("walkie-replies-\(UUID().uuidString)", isDirectory: true)
        descriptor = home.appendingPathComponent("reply-inbox.json")
        self.handler = handler
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "directory": directory.path])
        try data.write(to: descriptor, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor.path)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "walkie.reply-inbox"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func poll() {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var processed = 0
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  (try? files.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType) == .typeDirectory else { continue }
            let request = entry.appendingPathComponent("request.json")
            guard let attributes = try? files.attributesOfItem(atPath: request.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let claimed = entry.appendingPathComponent("processing.json")
            // Moving the ready file is the commit point. Never retry it after
            // calling the UI handler, including when writing the receipt fails.
            do { try files.moveItem(at: request, to: claimed) } catch { continue }
            processed += 1
            let result: (Int, [String: Any])
            if ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) > 512 * 1024 {
                result = (413, ["ok": false, "error": "reply too large"])
            } else if let data = try? Data(contentsOf: claimed),
                      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                result = handler(body)
            } else {
                result = (400, ["ok": false, "error": "invalid reply"])
            }
            do {
                let receipt = try JSONSerialization.data(withJSONObject: ["status": result.0, "body": result.1])
                try receipt.write(to: entry.appendingPathComponent("response.json"), options: .atomic)
            } catch {
                Log.error("💬 reply inbox could not write its receipt: \(error.localizedDescription)")
            }
            if processed == 32 { break }
        }
    }
}
