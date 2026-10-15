// swift-tools-version: 5.9
import PackageDescription
import Foundation

let usesLocalXCTest = ProcessInfo.processInfo.environment["WALKIE_CORELIBS_XCTEST"] == "1"
let localToolchainDirectory = ProcessInfo.processInfo.environment["WALKIE_SWIFT_TOOLCHAIN_DIR"] ?? "\(NSHomeDirectory())/Library/Caches/WalkieTalkie/Swift6.2.3"
var packageDependencies: [Package.Dependency] = []
var testDependencies: [Target.Dependency] = ["WalkieTalkie", "ObjCTry", "WalkieMacKit"]
if usesLocalXCTest {
    packageDependencies.append(.package(path: "\(localToolchainDirectory)/swift-corelibs-xctest"))
    testDependencies.append(.product(name: "XCTest", package: "swift-corelibs-xctest"))
}

let package = Package(
    name: "WalkieTalkie",
    platforms: [.macOS(.v13)],
    dependencies: packageDependencies,
    targets: [
        // **projectM 4.1.7, statically linked** (the `projectm` branch, 2026-09-21):
        // the engine behind the native MilkDrop halo (`ProjectMHalo`). The
        // library is prebuilt into `vendor/projectm/lib` from the upstream
        // tarball plus `vendor/projectm/target-fbo.patch` (see
        // `vendor/projectm/README.md` for the exact build); its C headers are
        // under `include/projectM-4`, and `pmhalo.cpp` is our GL glue.
        .target(
            name: "CProjectM",
            path: "Sources/CProjectM",
            cxxSettings: [.define("PROJECTM_STATIC_DEFINE")],
            linkerSettings: [
                .unsafeFlags(["-L", "\(Context.packageDirectory)/vendor/projectm/lib"]),
                .linkedLibrary("projectM-4"),
                .linkedLibrary("projectM_eval"),
                .linkedLibrary("c++"),
                .linkedFramework("OpenGL"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // `@try` for the Objective-C exceptions `AVAudioEngine` raises at runtime
        // (2026-09-30): Swift cannot catch one, and one uncaught kills the relay
        // mid-sentence. `WTTry { … }` answers it as an `NSError`.
        .target(
            name: "ObjCTry",
            path: "Sources/ObjCTry"
        ),
        .target(
            name: "WalkieMacKit",
            path: "Sources/WalkieMacKit"
        ),
        .executableTarget(
            name: "WalkieTalkie",
            dependencies: ["WalkieMacKit", "CProjectM", "ObjCTry"]
        ),
        // `swift test` — the pure parts only (2026-09-23: the transcription
        // estimate and the rewind's timeline). Everything that needs the running
        // relay is still a `/test/…` route.
        .testTarget(
            name: "WalkieTalkieTests",
            dependencies: testDependencies
        ),
    ]
)
