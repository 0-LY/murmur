import AppKit

enum SoundSet: String, Codable, CaseIterable, Identifiable {
    case deep, soft, bubble

    var id: String { rawValue }
    var name: String {
        switch self {
        case .deep: "Deep"
        case .soft: "Soft"
        case .bubble: "Bubble"
        }
    }

    func file(start: Bool) -> String { "\(rawValue)-\(start ? "start" : "stop")" }
}

enum Sounds {
    static func url(_ set: SoundSet, start: Bool, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: set.file(start: start), withExtension: "caf", subdirectory: "Sounds")
    }

    @MainActor private static var cache: [String: NSSound] = [:]

    @MainActor static func sound(_ set: SoundSet, start: Bool) -> NSSound? {
        let key = set.file(start: start)
        if let s = cache[key] { return s }
        guard let url = url(set, start: start), let s = NSSound(contentsOf: url, byReference: true) else { return nil }
        cache[key] = s
        return s
    }

    @MainActor @discardableResult
    static func play(_ set: SoundSet, start: Bool, volume: Int) -> TimeInterval {
        guard let s = sound(set, start: start) else { return 0 }
        s.stop()
        s.volume = SoundVolume.level(volume)
        s.play()
        return s.duration
    }

    @MainActor static func preview(_ set: SoundSet, volume: Int) {
        play(set, start: true, volume: volume)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { play(set, start: false, volume: volume) }
    }

    static func plays(_ cfg: Config, start: Bool) -> Bool {
        cfg.sounds && (start ? cfg.startSound : cfg.stopSound)
    }

    @MainActor @discardableResult
    static func start(_ cfg: Config) -> TimeInterval {
        plays(cfg, start: true) ? play(cfg.soundSet, start: true, volume: cfg.volume) : 0
    }

    @MainActor static func stop(_ cfg: Config) {
        if plays(cfg, start: false) { play(cfg.soundSet, start: false, volume: cfg.volume) }
    }
}
