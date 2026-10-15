import XCTest
@testable import WalkieTalkie

final class SpawnTerminalTests: XCTestCase {
    func testResumeDirectoryValidationAcceptsDirectoryAndRejectsFileOrMissingPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("walkie-resume-validation-\(UUID().uuidString)")
        let file = root.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(SpawnTerminal.resumeDirectoryFailure(root.path))
        XCTAssertNotNil(SpawnTerminal.resumeDirectoryFailure(file.path))
        XCTAssertNotNil(SpawnTerminal.resumeDirectoryFailure(root.appendingPathComponent("missing").path))
        XCTAssertNotNil(SpawnTerminal.resumeDirectoryFailure(""))
    }

    func testOpenDescriptorParsesTTYWindowAndVisibleWindowRows() {
        let result = SpawnTerminal.parseOpenDescriptor(
            "/dev/ttys013\n42\n42 0 25 900 700\n43 900 25 1800 700\n")

        XCTAssertEqual(result, .descriptor(.init(
            tty: "/dev/ttys013", windowID: 42,
            windowLines: ["42 0 25 900 700", "43 900 25 1800 700"])))
    }

    func testMalformedOpenDescriptorIsDistinctAndDoesNotEchoRawOutput() {
        let output = "PROMPT_CONTENT_MUST_NOT_APPEAR\n42\n"

        let result = SpawnTerminal.parseOpenDescriptor(output)

        XCTAssertEqual(result, .malformed("TTY is not a device path"))
        if case .malformed(let reason) = result {
            XCTAssertFalse(reason.contains("PROMPT_CONTENT_MUST_NOT_APPEAR"))
        } else {
            XCTFail("expected malformed descriptor")
        }
    }

    func testMissingTTYAndWindowIDHaveSeparateDescriptorErrors() {
        XCTAssertEqual(SpawnTerminal.parseOpenDescriptor(""), .malformed("missing TTY"))
        XCTAssertEqual(SpawnTerminal.parseOpenDescriptor("/dev/ttys013"),
                       .malformed("missing Terminal window ID"))
        XCTAssertEqual(SpawnTerminal.parseOpenDescriptor("/dev/ttys013\nfront"),
                       .malformed("invalid Terminal window ID"))
    }

    func testAppleScriptFailurePreservesExitStatusAndBoundedDiagnostic() {
        let stderr = "Not authorized to send Apple events to Terminal. (-1743)"

        let reason = SpawnTerminal.appleScriptFailure(.failed(status: 1, stderr: stderr))

        XCTAssertEqual(reason, "Terminal automation failed (osascript exit 1): \(stderr)")
        XCTAssertFalse(reason.contains("PROMPT_CONTENT_MUST_NOT_APPEAR"))
    }

    func testAppleScriptLaunchAndTimeoutFailuresRemainDistinct() {
        XCTAssertEqual(SpawnTerminal.appleScriptFailure(.couldNotRun("permission denied")),
                       "Could not start osascript: permission denied")
        XCTAssertEqual(SpawnTerminal.appleScriptFailure(.timedOut(5)),
                       "Terminal automation timed out after 5 seconds")
    }

    func testTerminalAutomationScriptsCompileWithoutSendingAppleEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("walkie-terminal-applescript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scripts = [
            SpawnTerminal.openAppleScript(launcherPath: "/tmp/Walkie Talkie/start-123.sh"),
            SpawnTerminal.tileAppleScript(windowID: 42, x: -900, y: 25, width: 900, height: 700),
        ]
        for (index, source) in scripts.enumerated() {
            let input = root.appendingPathComponent("script-\(index).applescript")
            let output = root.appendingPathComponent("script-\(index).scpt")
            try source.write(to: input, atomically: true, encoding: .utf8)

            // osacompile parses and compiles only; this deliberately never invokes
            // osascript or sends an Apple event to Terminal.
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            compiler.arguments = ["-l", "AppleScript", "-o", output.path, input.path]
            let errors = Pipe()
            compiler.standardError = errors
            try compiler.run()
            compiler.waitUntilExit()
            let diagnostic = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            XCTAssertEqual(compiler.terminationStatus, 0, diagnostic)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }
}
