import AppKit

/// **The sound of the microphone opening.** It was a falling "womp" for one
/// morning (2026-10-01); the original author then asked for it out — *"înlocuiește-l cu un
/// hârâit ca de transmisie (white noise scurt), debifat by default în meniu"* —
/// and it plays only while the `Radio Squelch` row is ticked. Synthesised white
/// noise until 2026-10-05, when he picked a real one from youtu.be/nt71N59hydQ
/// and cut it himself (*"Am pus clipul pe care îl doresc în Downloads tăiat
/// frumos. Pune-l pe ăla la volum mic"*): `assets/start-squelch.wav` is his
/// 0.26 s mp3, mono 44.1 kHz, −15 dB (peak −19 dBFS), led by 150 ms of silence —
/// `play()` was starting and he heard nothing, because the built-in speakers
/// wake late and swallowed the whole short clip, where the old 0.32 s hiss
/// outlasted the wake.
/// The silence goes on **both** channels before the mono mix (`adelay=150:all=1`):
/// on the left alone it summed two copies 150 ms apart — *"să hârâie o singură
/// dată, nu de 2 ori"*.
enum StartChime {

    /// `UserDefaults` beside `autosend`: a preference, not data. Absent = off.
    static let defaultsKey = "startSquelch"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// The menu row's title.
    static let menuTitle = "Radio Squelch"

    private static let sound: NSSound? = url().flatMap { NSSound(contentsOf: $0, byReference: false) }

    static func play() {
        guard isOn else { return }
        guard let sound else { Log.error("📻 radio squelch: no start-squelch.wav loaded — silent"); return }
        if sound.isPlaying { sound.stop() }
        let ok = sound.play()
        Log.info(String(format: "📻 radio squelch: play() %@, %.2f s, volume %.2f", ok ? "started" : "REFUSED", sound.duration, sound.volume))
    }

    /// `Resources/start-squelch.wav` installed, `assets/start-squelch.wav` from a
    /// `.build` binary; nil (silence) when neither is there.
    private static func url() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourcePath { candidates.append(URL(fileURLWithPath: res).appendingPathComponent("start-squelch.wav")) }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<4 { candidates.append(dir.appendingPathComponent("assets/start-squelch.wav")); dir = dir.deletingLastPathComponent() }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
