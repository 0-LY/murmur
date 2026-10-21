import Foundation

enum TalkMode: String, Codable, CaseIterable, Identifiable {
    case hold, toggle

    var id: String { rawValue }
    var name: String { self == .hold ? "Hold to talk" : "Press to start and stop" }
}

enum InsertMode: String, Codable, CaseIterable, Identifiable {
    case paste, copy

    var id: String { rawValue }
    var name: String { self == .paste ? "Type it where the cursor is" : "Copy to the clipboard" }
}

enum CleanupMode: String, Codable, CaseIterable, Identifiable {
    case off, quick, smart

    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: "Off"
        case .quick: "Quick"
        case .smart: "Smart"
        }
    }
    var detail: String {
        switch self {
        case .off: "The text is pasted exactly as heard."
        case .quick: "Instant: fixes spacing, capitals, filler words and names."
        case .smart: "Apple's on-device AI also fixes wording. Slower; falls back to Quick after 1.5 s."
        }
    }

    static func decode(_ raw: String?) -> CleanupMode? {
        guard let raw else { return nil }
        if raw == "light" { return .quick }
        return CleanupMode(rawValue: raw)
    }
}

enum MainVoiceSensitivity: String, Codable, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }
    var name: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
    var similarity: Float {
        switch self {
        case .low: 0.55
        case .medium: 0.62
        case .high: 0.7
        }
    }
    var quieterDb: Double {
        switch self {
        case .low: 6
        case .medium: 4.5
        case .high: 3
        }
    }
    var detail: String {
        switch self {
        case .low: "Drops only much quieter voices."
        case .medium: "Drops quieter background voices."
        case .high: "Drops more; may cut your words."
        }
    }
}

enum WritingMode: String, Codable, CaseIterable, Identifiable {
    case final, live

    var id: String { rawValue }
    var name: String { short }
    var short: String { self == .final ? "Final only" : "Live typing" }
    var detail: String {
        switch self {
        case .final: "The cleaned text is pasted when you let go."
        case .live: "Words appear in the text field as you speak."
        }
    }

    static func decode(_ raw: String?) -> WritingMode? {
        guard let raw else { return nil }
        if raw == "preview" { return .final }
        return WritingMode(rawValue: raw)
    }
}

enum TalkKey: String, Codable, CaseIterable, Identifiable {
    case rightOption, fn, doubleCommand, custom

    var id: String { rawValue }
    var name: String {
        switch self {
        case .rightOption: "Hold Right ⌥"
        case .fn: "Hold 🌐 fn"
        case .doubleCommand: "Double-tap Right ⌘"
        case .custom: "Custom shortcut"
        }
    }
    var short: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .fn: "🌐 fn"
        case .doubleCommand: "⌘ ⌘"
        case .custom: "Custom"
        }
    }
}

enum SoundVolume {
    static let steps = 1...5
    static let standard = 3
    static let levels: [Float] = [0.16, 0.26, 0.4, 0.62, 1.0]

    static func clamp(_ step: Int) -> Int { min(steps.upperBound, max(steps.lowerBound, step)) }
    static func level(_ step: Int) -> Float { levels[clamp(step) - 1] }

    static func name(_ step: Int) -> String {
        switch clamp(step) {
        case 1: "Very soft"
        case 2: "Soft"
        case 3: "Medium"
        case 4: "Loud"
        default: "Very loud"
        }
    }

    static func migrate(legacy: String?) -> Int? {
        switch legacy {
        case "soft": 2
        case "normal": 3
        default: nil
        }
    }
}

enum SpeechLanguage: String, Codable, CaseIterable, Identifiable {
    case auto, en, uk

    var id: String { rawValue }
    var name: String {
        switch self {
        case .auto: "Automatic"
        case .en: "English"
        case .uk: "Ukrainian"
        }
    }
}

struct Config: Codable, Equatable {
    private enum LegacyKeys: String, CodingKey { case startSoundOn, stopSoundOn, soundVolume, hudText }

    var hotkey = "ctrl-opt-v"
    var mode: TalkMode = .hold
    var engine = EngineID.apple.rawValue
    var language: SpeechLanguage = .auto
    var cleanup: CleanupMode = .quick
    var vocabulary = ""
    var insert: InsertMode = .paste
    var keepInClipboard = false
    var showMenuBarIcon = true
    var launchAtLogin = false
    var hudSize = "medium"
    var speechThreshold: Double = VoiceGate.defaultThreshold
    var talkKey: TalkKey = .rightOption
    var writing: WritingMode = .final
    var sounds = true
    var startSound = true
    var stopSound = true
    var soundSet: SoundSet = .bubble
    var volume = SoundVolume.standard
    var mainVoice = false
    var mainVoiceSensitivity: MainVoiceSensitivity = .low
    var spokenPunctuation = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkey = (try? c.decodeIfPresent(String.self, forKey: .hotkey)) ?? d.hotkey
        mode = (try? c.decodeIfPresent(TalkMode.self, forKey: .mode)) ?? d.mode
        engine = (try? c.decodeIfPresent(String.self, forKey: .engine)) ?? d.engine
        language = (try? c.decodeIfPresent(SpeechLanguage.self, forKey: .language)) ?? d.language
        cleanup = CleanupMode.decode((try? c.decodeIfPresent(String.self, forKey: .cleanup)) ?? nil) ?? d.cleanup
        vocabulary = (try? c.decodeIfPresent(String.self, forKey: .vocabulary)) ?? d.vocabulary
        insert = (try? c.decodeIfPresent(InsertMode.self, forKey: .insert)) ?? d.insert
        keepInClipboard = (try? c.decodeIfPresent(Bool.self, forKey: .keepInClipboard)) ?? d.keepInClipboard
        showMenuBarIcon = (try? c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon)) ?? d.showMenuBarIcon
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        hudSize = (try? c.decodeIfPresent(String.self, forKey: .hudSize)) ?? d.hudSize
        if HUD.scale(for: hudSize) == nil, hudSize != "off" { hudSize = d.hudSize }
        speechThreshold = VoiceGate.clampThreshold((try? c.decodeIfPresent(Double.self, forKey: .speechThreshold)) ?? d.speechThreshold)
        let hadHotkey = c.contains(.hotkey)
        talkKey = (try? c.decodeIfPresent(TalkKey.self, forKey: .talkKey)) ?? (hadHotkey ? .custom : d.talkKey)
        writing = WritingMode.decode((try? c.decodeIfPresent(String.self, forKey: .writing)) ?? nil) ?? d.writing
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let startOn = (try? legacy?.decodeIfPresent(Bool.self, forKey: .startSoundOn)) ?? nil
        let stopOn = (try? legacy?.decodeIfPresent(Bool.self, forKey: .stopSoundOn)) ?? nil
        if let on = try? c.decodeIfPresent(Bool.self, forKey: .sounds) {
            sounds = on
        } else {
            sounds = (startOn == nil && stopOn == nil) ? d.sounds : ((startOn ?? false) || (stopOn ?? false))
        }
        startSound = (try? c.decodeIfPresent(Bool.self, forKey: .startSound)) ?? startOn ?? d.startSound
        stopSound = (try? c.decodeIfPresent(Bool.self, forKey: .stopSound)) ?? stopOn ?? d.stopSound
        if !startSound && !stopSound { startSound = true; stopSound = true; sounds = false }
        soundSet = (try? c.decodeIfPresent(SoundSet.self, forKey: .soundSet)) ?? d.soundSet
        let legacyVolume = (try? legacy?.decodeIfPresent(String.self, forKey: .soundVolume)) ?? nil
        volume = SoundVolume.clamp((try? c.decodeIfPresent(Int.self, forKey: .volume)) ?? SoundVolume.migrate(legacy: legacyVolume) ?? d.volume)
        mainVoice = (try? c.decodeIfPresent(Bool.self, forKey: .mainVoice)) ?? d.mainVoice
        mainVoiceSensitivity = (try? c.decodeIfPresent(MainVoiceSensitivity.self, forKey: .mainVoiceSensitivity)) ?? d.mainVoiceSensitivity
        spokenPunctuation = (try? c.decodeIfPresent(Bool.self, forKey: .spokenPunctuation)) ?? d.spokenPunctuation
        if EngineID(rawValue: engine) == nil { engine = d.engine }
    }

    var vocabularyWords: [String] {
        vocabulary.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    nonisolated(unsafe) static var overrideDirectory: URL?

    static var directory: URL {
        if let overrideDirectory { return overrideDirectory }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(Identity.configDirName, isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    nonisolated(unsafe) private static var cache: Config?

    static var current: Config {
        if let cache { return cache }
        return load()
    }

    static func load() -> Config {
        let cfg = read()
        cache = cfg
        return cfg
    }

    private static func read() -> Config {
        lockDirectory()
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        protect(fileURL)
        guard let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let backup = directory.appendingPathComponent("config.unreadable.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: fileURL, to: backup)
                protect(backup)
            }
            return Config()
        }
        return cfg
    }

    static let legacyKeys = ["onlyMyVoice", "voiceStrictness"]

    static func dropLegacyKeys() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              legacyKeys.contains(where: { obj[$0] != nil }) else { return }
        save(load())
    }

    static func save(_ cfg: Config) {
        lockDirectory()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        cache = cfg
        guard let data = try? enc.encode(cfg) else { return }
        try? data.write(to: fileURL, options: .atomic)
        protect(fileURL)
    }

    static func lockDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
