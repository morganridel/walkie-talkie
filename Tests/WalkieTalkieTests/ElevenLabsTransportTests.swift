import Foundation
import XCTest
@testable import WalkieTalkie

/// Exercises the real multipart/parser/retry path. Every request is intercepted
/// by URLProtocol; these tests open no microphone, read no key and use no network.
final class ElevenLabsTransportTests: XCTestCase {
    private let success = Data(#"{"text":"  Hello world.  ","language_code":"en","language_probability":0.98,"words":[{"text":"Hello","start":0.1,"end":0.4,"type":"word"},{"text":" ","start":0.4,"end":0.5,"type":"spacing"},{"text":"world.","start":0.5,"end":0.9,"type":"word"},{"text":"invalid"}]}"#.utf8)

    private func withFixture(_ steps: [CloudFixtureProtocol.Step],
                             _ body: (URL, URLSession) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("empty-public-fixture.wav")
        // Valid empty 16 kHz mono PCM header: no audio and no cost-ledger update.
        var data = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ n: T) {
            var little = n.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        integer(UInt32(36)); data.append(Data("WAVEfmt ".utf8))
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(16_000)); integer(UInt32(32_000))
        integer(UInt16(2)); integer(UInt16(16)); data.append(Data("data".utf8)); integer(UInt32(0))
        try data.write(to: wav)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let oldFault = ElevenLabsSource.fault
        ElevenLabsSource.fault = nil
        CloudFixtureProtocol.prepare(steps)
        defer {
            session.invalidateAndCancel()
            ElevenLabsSource.fault = oldFault
            try? FileManager.default.removeItem(at: folder)
        }
        try body(wav, session)
    }

    private func transcribe(_ wav: URL, _ session: URLSession,
                            upload: ElevenLabsSource.Upload? = nil) -> ElevenLabsSource.Outcome? {
        let done = DispatchSemaphore(value: 0)
        var outcome: ElevenLabsSource.Outcome?
        ElevenLabsSource.transcribe(wav: wav, key: "offline-fixture-key", upload: upload, session: session) {
            outcome = $0
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "Expected a bounded upload result")
        return outcome
    }

    func testSuccessPreservesTimedWordsAndSpacing() throws {
        try withFixture([.init(status: 200, data: success)]) { wav, session in
            guard case .success(let result)? = transcribe(wav, session) else {
                return XCTFail("Expected the intercepted successful response")
            }
            XCTAssertEqual(result.text, "Hello world.")
            XCTAssertEqual(result.language, "en")
            XCTAssertEqual(result.languageProbability, 0.98)
            XCTAssertEqual(result.words.map(\.text), ["Hello", " ", "world."])
            XCTAssertEqual(result.words.map(\.isSpacing), [false, true, false])
            XCTAssertEqual(CloudFixtureProtocol.requests.count, 1)
            let request = CloudFixtureProtocol.requests.first
            XCTAssertEqual(request?.httpMethod, "POST")
            XCTAssertEqual(request?.value(forHTTPHeaderField: "xi-api-key"), "offline-fixture-key")
            XCTAssertTrue(request?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        }
    }

    func testAuthenticationAndRequestFailuresAreNotRetried() throws {
        for code in [401, 422] {
            try withFixture([.init(status: code, data: Data("bad request".utf8))]) { wav, session in
                guard case .failure(let message)? = transcribe(wav, session) else {
                    return XCTFail("Expected HTTP failure")
                }
                XCTAssertTrue(message.contains("HTTP \(code)"))
                XCTAssertEqual(CloudFixtureProtocol.requests.count, 1)
            }
        }
    }

    func testRateLimitRetriesOnceThenReturnsFailure() throws {
        try withFixture([.init(status: 429), .init(status: 429)]) { wav, session in
            guard case .failure(let message)? = transcribe(wav, session) else {
                return XCTFail("Expected rate-limit failure")
            }
            XCTAssertTrue(message.contains("HTTP 429"))
            XCTAssertEqual(CloudFixtureProtocol.requests.count, 2)
        }
    }

    func testServerFailureRetriesThroughTheSameInterceptedSession() throws {
        try withFixture([.init(status: 503), .init(status: 200, data: success)]) { wav, session in
            guard case .success(let result)? = transcribe(wav, session) else {
                return XCTFail("Expected retry success")
            }
            XCTAssertEqual(result.text, "Hello world.")
            XCTAssertEqual(CloudFixtureProtocol.requests.count, 2)
        }
    }

    func testTimeoutReturnsWithoutRetry() throws {
        try withFixture([.init(error: URLError(.timedOut))]) { wav, session in
            guard case .failure? = transcribe(wav, session) else { return XCTFail("Expected timeout") }
            XCTAssertEqual(CloudFixtureProtocol.requests.count, 1)
        }
    }

    func testTransportFailureRetriesOnce() throws {
        try withFixture([.init(error: URLError(.notConnectedToInternet)), .init(status: 200, data: success)]) { wav, session in
            guard case .success? = transcribe(wav, session) else { return XCTFail("Expected retry success") }
            XCTAssertEqual(CloudFixtureProtocol.requests.count, 2)
        }
    }

    func testMalformedAndEmptyProviderRepliesStayDistinct() throws {
        try withFixture([.init(status: 200, data: Data("not JSON".utf8))]) { wav, session in
            guard case .failure(let message)? = transcribe(wav, session) else { return XCTFail("Expected parse failure") }
            XCTAssertEqual(message, "unreadable reply from ElevenLabs")
        }
        try withFixture([.init(status: 200, data: Data(#"{"text":"  ","words":[]}"#.utf8))]) { wav, session in
            guard case .success(let result)? = transcribe(wav, session) else { return XCTFail("Expected an empty transcript") }
            XCTAssertEqual(result.text, "")
        }
    }

    func testCancelPendingRequestDropsItsLateAnswer() throws {
        try withFixture([.init(status: 200, data: success, delay: 0.25)]) { wav, session in
            let upload = ElevenLabsSource.Upload(wav: wav, duration: 1)
            let answered = DispatchSemaphore(value: 0)
            ElevenLabsSource.transcribe(wav: wav, key: "offline-fixture-key", upload: upload, session: session) { _ in answered.signal() }
            XCTAssertTrue(CloudFixtureProtocol.waitForRequests(1))
            upload.cancel()
            XCTAssertEqual(answered.wait(timeout: .now() + 0.4), .timedOut)
            XCTAssertEqual(CloudFixtureProtocol.requests.count, 1)
        }
    }

    func testCancelDuringBackoffPreventsTheRetry() throws {
        try withFixture([.init(status: 429), .init(status: 200, data: success)]) { wav, session in
            let upload = ElevenLabsSource.Upload(wav: wav, duration: 1)
            let answered = DispatchSemaphore(value: 0)
            ElevenLabsSource.transcribe(wav: wav, key: "offline-fixture-key", upload: upload, session: session) { _ in answered.signal() }
            XCTAssertTrue(CloudFixtureProtocol.waitForRequests(1))
            upload.cancel()
            XCTAssertEqual(answered.wait(timeout: .now() + 1), .timedOut)
            XCTAssertEqual(CloudFixtureProtocol.requests.count, 1)
        }
    }

    func testDelayedFaultUsesTheInterceptedSession() throws {
        try withFixture([.init(status: 200, data: success)]) { wav, session in
            ElevenLabsSource.fault = .init(spec: "delay", delayMs: 10, once: true, lang: nil)
            guard case .success? = transcribe(wav, session) else { return XCTFail("Expected the delayed request") }
            XCTAssertEqual(CloudFixtureProtocol.requests.count, 1)
        }
    }
}

private final class CloudFixtureProtocol: URLProtocol {
    struct Step {
        var status: Int = 200
        var data: Data = Data()
        var error: URLError?
        var delay: TimeInterval = 0
    }
    private static let lock = NSLock()
    private static var steps: [Step] = []
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }
    static func prepare(_ newSteps: [Step]) { lock.withLock { steps = newSteps; captured = [] } }
    static func waitForRequests(_ count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if requests.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let stateLock = NSLock()
    private var stopped = false
    override func startLoading() {
        let step: Step? = Self.lock.withLock {
            Self.captured.append(request)
            return Self.steps.isEmpty ? nil : Self.steps.removeFirst()
        }
        // Unplanned attempts also stay in memory; they can never reach a server.
        let response = step ?? Step(error: URLError(.resourceUnavailable))
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [weak self] in
            guard let self, !self.stateLock.withLock({ self.stopped }) else { return }
            if let error = response.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let http = HTTPURLResponse(url: self.request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: response.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}
