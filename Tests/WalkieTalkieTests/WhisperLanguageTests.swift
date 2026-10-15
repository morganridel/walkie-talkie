import XCTest
@testable import WalkieTalkie

final class WhisperLanguageTests: XCTestCase {
    func testUnconfiguredOrInvalidPreferencePreservesAutomaticDetection() {
        XCTAssertEqual(WhisperLanguage.fromStored(nil), .automatic)
        XCTAssertEqual(WhisperLanguage.fromStored("unsupported"), .automatic)
        XCTAssertNil(WhisperLanguage.automatic.request(["wav": "sample.wav"])["language"])
    }

    func testFinalAndCaptionRequestsCarryTheSameExplicitLanguage() throws {
        for option in [WhisperLanguage.english, .french] {
            let final = option.request(["wav": "sample.wav", "words": true])
            let caption = option.request(["pcm": "window.pcm", "segments": true])
            XCTAssertEqual(final["language"] as? String, option.rawValue)
            XCTAssertEqual(caption["language"] as? String, option.rawValue)
            XCTAssertEqual(final["words"] as? Bool, true)
            XCTAssertEqual(caption["segments"] as? Bool, true)
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: final))
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: caption))
        }
    }
}
