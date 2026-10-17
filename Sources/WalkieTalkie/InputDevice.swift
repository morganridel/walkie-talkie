import AVFoundation
import CoreAudio

/// Microphone discovery and selection. Device UIDs survive reconnects; numeric
/// CoreAudio IDs do not. Automatic follows the macOS default input. The named
/// roster supplies icons and preserves choices saved by older versions.
enum InputDevice {

    struct Known {
        let id: String
        let glyph: String
        let short: String
        let label: String
        let needles: [String]
    }

    static let known: [Known] = [
        Known(id: "xlr",  glyph: "🎙️", short: "XLR", label: "Elgato Wave XLR",
              needles: ["wave xlr", "elgato"]),
        // **One DJI row, and it is the receiver** (2026-09-23, the original author: *"vom
        // scoate DJI mic mini tx din lista. pastram doar RX pt moment cu emoji =
        // 🎤"*). The transmitter paired over Bluetooth had its own row for a day
        // (`tx`, 16 kHz HFP); it is gone, and the receiver took the microphone
        // glyph. The needles stay off a bare `dji mic`: the transmitter is named
        // `DJI Mic Mini-B83BBE` and would be pulled straight back in by it. The
        // receiver's brand is only in the manufacturer string
        // (`DJI Technology Co., Ltd.`), which is part of the haystack.
        Known(id: "rx",   glyph: "🎤", short: "DJI", label: "DJI",
              needles: ["wireless mic rx", "wireless mic", "dji technology"]),
        // **The room's own microphone** (2026-09-22). It was only ever in
        // the original author Addons' list, which is how the two menus came to disagree:
        // addons ranked it *second*, above the XLR, because in a hall a
        // far-field speakerphone with AGC beats a condenser pointed at one
        // chair. That reasoning survives, the rank does not — the original author's order is
        // `XLR>DJI>BOSE>MAC` (2026-09-19) and the speakerphone slots in below
        // the lavaliers, which are on his collar wherever he walks.
        Known(id: "stage", glyph: "🏛️", short: "Stage", label: "Stage Speakerphone",
              needles: ["room speakerphone", "speakerphone"]),
        Known(id: "bose", glyph: "🎧", short: "Bose", label: "Bose",
              needles: ["bose"]),
        Known(id: "mac",  glyph: "💻", short: "Mac", label: "Mac microphone",
              needles: ["macbook", "built-in microph"]),
    ]

    static let neverRecord: [String] = []

    static func isNeverRecord(_ device: Device) -> Bool {
        let name = device.name.lowercased()
        return neverRecord.contains { name.contains($0) }
    }

    /// Legacy roster IDs and stable `uid:` selections share the same preference.
    static let preferenceKey = "micDevice"

    /// **On disk, not in `UserDefaults`, since 2026-09-22** — see `MicChoice`
    /// for why. `UserDefaults` is still read once, as a migration, so the
    /// device picked before the file existed survives the upgrade; the file
    /// wins from the first write.
    static var chosenId: String {
        get {
            let ids = known.map(\.id)
            let onDisk = MicChoice.read(known: ids)
            if onDisk != MicChoice.automatic { return onDisk }
            // Nothing published yet: adopt the old preference and publish it,
            // so the other app sees the same device from this launch on.
            if let legacy = UserDefaults.standard.string(forKey: preferenceKey),
               ids.contains(legacy), !FileManager.default.fileExists(atPath: MicChoice.url.path) {
                MicChoice.write(legacy)
                return legacy
            }
            return MicChoice.automatic
        }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
            MicChoice.write(newValue)
        }
    }

    struct Choice {
        let id: String
        let label: String
    }

    static func selectionID(for device: Device) -> String {
        "uid:" + Data(device.uid.utf8).base64EncodedString()
    }

    /// Rebuilt whenever the menu opens, including unfamiliar USB microphones.
    static func choices(devices: [Device]) -> [Choice] {
        devices.filter { !$0.uid.isEmpty && !isNeverRecord($0) }.map { device in
            let glyph = known.first { matches(device, $0) }?.glyph ?? "🎙️"
            return Choice(id: selectionID(for: device), label: "\(glyph) \(device.name)")
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func choices() -> [Choice] { choices(devices: inputs()) }

    static func availableIds() -> Set<String> {
        let devices = inputs()
        return Set(choices(devices: devices).map(\.id))
            .union(known.filter { k in devices.contains { matches($0, k) } }.map(\.id))
    }

    /// Test-only, process-local name override; never changes the saved choice.
    /// A missing match is logged once and ignored.
    static var testOverride: String? {
        get { overrideLock.withLock { _testOverride } }
        set { overrideLock.withLock { _testOverride = newValue; overrideMissed = false } }
    }
    private static var _testOverride: String?
    private static var overrideMissed = false
    private static let overrideLock = NSLock()

    static func resolve() -> (known: Known?, device: Device?) {
        let devices = inputs()
        if let want = testOverride?.lowercased(), !want.isEmpty {
            if let device = devices.first(where: { $0.name.lowercased().contains(want) }) {
                return (known.first { matches(device, $0) }, device)
            }
            overrideLock.withLock {
                if !overrideMissed { Log.error("mic: test override \"\(want)\" matches no input — ignored"); overrideMissed = true }
            }
        }
        return resolve(devices: devices, defaultDevice: systemDefault(), choice: chosenId)
    }

    /// A missing explicit device falls back for this take; its UID stays saved
    /// so reconnecting it restores the choice without matching another unit by name.
    static func resolve(devices: [Device], defaultDevice: Device?, choice: String)
        -> (known: Known?, device: Device?) {
        let usable = devices.filter { !isNeverRecord($0) }
        let explicit: Device?
        if let uid = MicChoice.deviceUID(choice) {
            explicit = usable.first { $0.uid == uid }
        } else if let legacy = known.first(where: { $0.id == choice }) {
            explicit = usable.first { matches($0, legacy) }
        } else {
            explicit = nil
        }
        let fallback = defaultDevice.flatMap { device in usable.first { $0.id == device.id } }
        let device = explicit ?? fallback ?? usable.first
        return (device.flatMap { device in known.first { matches(device, $0) } }, device)
    }

    /// **The glyph the chip wears, or empty** — empty for a device that is none
    /// of `known`, which is the honest answer for the day he records through
    /// Loopback or a headset nobody has named yet.
    static func currentGlyph() -> String { resolve().known?.glyph ?? "" }

    /// **Wispr Flow's name for its microphone, read onto this roster**
    /// (2026-09-22) — Wispr's own `History.micDevice`, so a Wispr sentence says
    /// what *Wispr* heard it through rather than what the relay's meter is on.
    /// the original author: *"ar trebui să-i citești microfonul activ al lui Wispr … să
    /// mapezi ce știe Wispr la ceea ce avem noi, nu invers"*.
    ///
    /// Wispr's vocabulary, as it stands in 16 000 rows: a CoreAudio name with a
    /// transport suffix (`Elgato Wave XLR (USB)`), `Auto-detect (<name>)`, its
    /// own `Built-in mic (recommended)`, and `🎓 TO Wispr (Virtual)` — the
    /// `AudioBridge` loopback, whose voice is the relay's own recorder, so that
    /// one honestly is `currentGlyph()`. So is **`From Walkie`** (2026-10-01): the
    /// bridge's device since 2026-09-29, it is what Wispr names on nearly every
    /// row since, and it fell through to *none of the six* — every Wispr sentence
    /// lost its microphone off the chip. Anything else (`krisp`, a Sony headset)
    /// is none of the six and says nothing, which the chip renders as a plain
    /// `Listening...`.
    static func glyph(wisprName name: String) -> String {
        switch wisprDevice(name) {
        case .bridged: return currentGlyph()
        case .known(let k): return k.glyph
        case .other: return ""
        }
    }

    /// **The same mapping said in full**, for the prompt panel's `Mic:` line
    /// (2026-10-06): the bridge is the relay's own recorder (`label(opened:)`),
    /// a device none of `known` names keeps Wispr's own name for it.
    static func label(wisprName name: String) -> String {
        switch wisprDevice(name) {
        case .bridged: return label(opened: MicRecorder.lastOpened?.device)
        case .known(let k): return "\(k.glyph) \(k.label)"
        case .other: return name.isEmpty ? "unknown" : "🎙️ \(name)"
        }
    }

    private enum WisprDevice { case bridged, known(Known), other }

    private static func wisprDevice(_ name: String) -> WisprDevice {
        var n = name.lowercased()
        if n.contains("to wispr") || n.contains("from walkie") { return .bridged }
        if n.hasPrefix("auto-detect (") {
            n = String(n.dropFirst("auto-detect (".count))
            if n.hasSuffix(")") { n.removeLast() }
        }
        if n.hasPrefix("built-in") || n == "macbook pro" {
            return known.first { $0.id == "mac" }.map { .known($0) } ?? .other
        }
        return known.first { k in k.needles.contains { n.contains($0) } }.map { .known($0) } ?? .other
    }

    /// **The device a recording actually opened, said in full** — the CoreAudio
    /// name `MicRecorder` kept (`lastOpened`), read onto the roster. Nil, or the
    /// `select` placeholder, falls back to what would record now.
    static func label(opened name: String?) -> String {
        guard let name, !name.isEmpty, name != "the system input" else { return currentLabel() }
        let n = name.lowercased()
        if let k = known.first(where: { k in k.needles.contains { n.contains($0) } }) {
            return "\(k.glyph) \(k.label)"
        }
        return "🎙️ \(name)"
    }

    /// What the menu's **top row** says: the glyph and the short name of the
    /// device that would record right now. A device that is none of `known`
    /// gets CoreAudio's own name, which is the only name it has.
    static func currentShortLabel() -> String {
        let r = resolve()
        if let k = r.known { return "\(k.glyph) \(k.short)" }
        return r.device?.name ?? "the system input"
    }

    /// The same device said in full, for a log line and for the harness.
    static func currentLabel() -> String {
        let r = resolve()
        if let k = r.known { return "\(k.glyph) \(k.label)" }
        return r.device?.name ?? "the system input"
    }

    private static func matches(_ device: Device, _ k: Known) -> Bool {
        let haystack = "\(device.name) \(device.manufacturer)".lowercased()
        return k.needles.contains { haystack.contains($0) }
    }

    /// Point `input` at the microphone this recording should use and return a
    /// human name for the log.
    ///
    /// Always sets a device, even when the choice is the default one: the audio
    /// unit holds whatever device it was last told about, so a recording made
    /// after the receiver was unplugged would otherwise still be aimed at a
    /// device that is gone.
    ///
    /// - Returns: nil when the only input left is a `neverRecord` one — the
    ///   caller refuses to record rather than open it (2026-09-23).
    static func select(on input: AVAudioInputNode) -> String? {
        guard let chosen = resolve().device else {
            if let fallback = systemDefault(), isNeverRecord(fallback) {
                Log.error("mic: the only input is \(fallback.name), which is never recorded through — refusing")
                return nil
            }
            return "the system input"
        }

        guard let unit = input.audioUnit else { return chosen.name }
        var id = chosen.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            // Not fatal: the engine still has whatever device it had, which is
            // very likely the right one anyway. Worth a line, because it is the
            // only explanation for a recording that sounds like the built-in
            // microphone with the receiver plugged in.
            Log.error("mic: could not switch to \(chosen.name) — OSStatus \(status)")
            if let fallback = systemDefault(), isNeverRecord(fallback) { return nil }
            return "the system input"
        }
        return chosen.name
    }

    // MARK: - CoreAudio

    struct Device {
        let id: AudioDeviceID
        let name: String
        let manufacturer: String
        var uid: String = ""
    }

    /// Every device that can actually record. Outputs and the input-less halves
    /// of duplex devices are dropped here rather than at the match, so "first
    /// one that looks like a DJI" cannot land on a speaker.
    // MARK: - The system's default input, for the harness

    /// **The name of the system's chosen input**, so a test can put it back.
    static func systemDefaultName() -> String? { systemDefault()?.name }

    /// **Point the whole system's input at a device, by name.**
    ///
    /// This exists for `tools/wispr-test.sh` and nothing else. Wispr Flow's
    /// microphone is chosen in Wispr's own UI and stored as a Chromium
    /// `MediaDeviceInfo.deviceId` — a per-origin salted hash that cannot be
    /// computed from a device name and is rewritten by Wispr's own process, so
    /// it is not scriptable. What *is* scriptable is the system default, and
    /// Wispr follows it when its microphone is set to **Auto-detect**. That one
    /// setting is what turns "flip a preference by hand before and after every
    /// run" into a scripted end-to-end test.
    ///
    /// Substring, case-insensitive: CoreAudio names carry emoji and trailing
    /// model numbers, and asking a caller to type one exactly is asking for a
    /// typo that looks like *Wispr heard nothing*.
    ///
    /// - Returns: the name it actually selected, or nil if nothing matched.
    @discardableResult
    static func setSystemDefault(matching needle: String) -> String? {
        let wanted = needle.lowercased()
        guard let device = inputs().first(where: { $0.name.lowercased().contains(wanted) && !isNeverRecord($0) })
        else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        guard status == noErr else {
            Log.error("input: could not make \(device.name) the default (OSStatus \(status))")
            return nil
        }
        Log.info("🎚️ system default input → \(device.name)")
        return device.name
    }

    /// Every input this Mac can see, for a harness that has to say what it
    /// looked at when nothing matched.
    static func inputNames() -> [String] { inputs().map(\.name) }

    private static func inputs() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.filter { inputChannels($0) > 0 }.map {
            Device(id: $0,
                   name: string($0, kAudioObjectPropertyName) ?? "input \($0)",
                   manufacturer: string($0, kAudioObjectPropertyManufacturer) ?? "",
                   uid: string($0, kAudioDevicePropertyDeviceUID) ?? "")
        }
    }

    private static func systemDefault() -> Device? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return Device(id: id,
                      name: string(id, kAudioObjectPropertyName) ?? "the system input",
                      manufacturer: string(id, kAudioObjectPropertyManufacturer) ?? "",
                      uid: string(id, kAudioDevicePropertyDeviceUID) ?? "")
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    /// The channel counts live in a variable-length `AudioBufferList`, so the
    /// buffer has to be sized by the same call that fills it — a fixed struct
    /// would truncate a device with several input streams.
    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
