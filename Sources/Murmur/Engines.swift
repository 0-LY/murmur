import AVFoundation
import FluidAudio
import Foundation
import Speech
import WhisperKit

struct TranscriptionRequest: Sendable {
    var language: SpeechLanguage
    var vocabulary: [String]
    var keyboardLanguages: [String] = []
}

protocol Transcriber: AnyObject {
    func prepare() async throws
    func transcribe(_ recording: Recording, _ request: TranscriptionRequest) async throws -> String
}

enum EngineError: LocalizedError {
    case modelMissing(String)
    case languageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name): "\(name) isn't downloaded yet."
        case .languageUnavailable(let name): "Apple speech doesn't support \(name) on this Mac."
        }
    }
}

enum LanguageChoice {
    static func appleLocale(for language: SpeechLanguage, keyboard: [String], supported: [Locale]) -> Locale {
        let supportedIDs = supported.map { $0.identifier(.bcp47).lowercased() }
        func pick(_ code: String) -> Locale? {
            if let i = supportedIDs.firstIndex(where: { $0 == code || $0.hasPrefix(code + "-") }) {
                if code == "en", let us = supported.first(where: { $0.identifier(.bcp47).lowercased() == "en-us" }) { return us }
                return supported[i]
            }
            return nil
        }
        switch language {
        case .en: return pick("en") ?? Locale(identifier: "en_US")
        case .uk: return pick("uk") ?? Locale(identifier: "uk_UA")
        case .auto:
            for code in keyboard { if let l = pick(code.lowercased()) { return l } }
            return pick("en") ?? Locale(identifier: "en_US")
        }
    }

    static func parakeetHint(for language: SpeechLanguage) -> Language? {
        switch language {
        case .auto: nil
        case .en: .english
        case .uk: .ukrainian
        }
    }

    static func whisperCode(for language: SpeechLanguage) -> String? {
        switch language {
        case .auto: nil
        case .en: "en"
        case .uk: "uk"
        }
    }
}

final class AppleTranscriber: Transcriber {
    func prepare() async throws {}

    func transcribe(_ recording: Recording, _ request: TranscriptionRequest) async throws -> String {
        let supported = await DictationTranscriber.supportedLocales
        let locale = LanguageChoice.appleLocale(for: request.language, keyboard: request.keyboardLanguages, supported: supported)
        let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let context = AnalysisContext()
        if !request.vocabulary.isEmpty { context.contextualStrings[.general] = request.vocabulary }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try? await analyzer.setContext(context)
        let collector = Task { () -> String in
            var parts: [String] = []
            for try await result in transcriber.results {
                parts.append(String(result.text.characters))
            }
            return parts.joined()
        }
        let file = try AVAudioFile(forReading: recording.url)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class ParakeetTranscriber: Transcriber {
    let id: EngineID
    let folder: URL
    private var manager: AsrManager?

    init(id: EngineID, folder: URL) {
        self.id = id
        self.folder = folder
    }

    func prepare() async throws {
        guard manager == nil, let version = LibraryFetcher.parakeetVersion(id) else { return }
        let models = try await AsrModels.load(from: folder, version: version)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
    }

    func transcribe(_ recording: Recording, _ request: TranscriptionRequest) async throws -> String {
        try await text(recording.samples, language: request.language)
    }

    func text(_ input: [Float], language: SpeechLanguage) async throws -> String {
        try await prepare()
        guard let manager else { throw EngineError.modelMissing(ModelInfo.info(id).name) }
        var samples = input
        let minimum = Int(Recording.sampleRate)
        if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state,
                                                  language: LanguageChoice.parakeetHint(for: language))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class WhisperTranscriber: Transcriber {
    let folder: URL
    let tokenizer: URL
    private var kit: WhisperKit?

    init(folder: URL, tokenizer: URL) {
        self.folder = folder
        self.tokenizer = tokenizer
    }

    func prepare() async throws {
        guard kit == nil else { return }
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: tokenizer, verbose: false,
                                      logLevel: .error, prewarm: false, load: true, download: false)
        kit = try await WhisperKit(config)
    }

    func transcribe(_ recording: Recording, _ request: TranscriptionRequest) async throws -> String {
        try await text(recording.samples, request)
    }

    func text(_ samples: [Float], _ request: TranscriptionRequest) async throws -> String {
        try await prepare()
        guard let kit else { throw EngineError.modelMissing(ModelInfo.info(.whisperTurbo).name) }
        let code = LanguageChoice.whisperCode(for: request.language)
        var options = DecodingOptions(language: code, temperature: 0, usePrefillPrompt: code != nil,
                                      detectLanguage: code == nil, skipSpecialTokens: true, withoutTimestamps: true)
        if !request.vocabulary.isEmpty, let tok = kit.tokenizer {
            let prompt = " " + request.vocabulary.joined(separator: ", ")
            options.promptTokens = tok.encode(text: prompt).filter { $0 < tok.specialTokens.specialTokenBegin }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class EngineHub {
    static let shared = EngineHub()

    private var loaded: [EngineID: Transcriber] = [:]
    private var lastUse: [EngineID: Date] = [:]
    private var reaper: Timer?
    let store: ModelStore
    static let idleUnload: TimeInterval = 180

    init(store: ModelStore? = nil) {
        self.store = store ?? .shared
    }

    func transcriber(_ id: EngineID) throws -> Transcriber {
        if let t = loaded[id] { return t }
        let t: Transcriber
        switch id {
        case .apple:
            t = AppleTranscriber()
        case .parakeetUltra, .parakeetRedux:
            guard let folder = store.folder(id) else { throw EngineError.modelMissing(ModelInfo.info(id).name) }
            t = ParakeetTranscriber(id: id, folder: folder)
        case .whisperTurbo:
            guard let folder = store.folder(id) else { throw EngineError.modelMissing(ModelInfo.info(id).name) }
            t = WhisperTranscriber(folder: folder, tokenizer: store.dir(id))
        }
        loaded[id] = t
        scheduleReaper()
        return t
    }

    static func effective(_ wanted: EngineID, ready: (EngineID) -> Bool) -> EngineID {
        wanted == .apple || ready(wanted) ? wanted : .apple
    }

    func warm(_ id: EngineID) {
        guard id != .apple, let t = try? transcriber(id) else { return }
        lastUse[id] = Date()
        Task { try? await t.prepare() }
    }

    func transcribe(_ id: EngineID, _ recording: Recording, _ request: TranscriptionRequest) async throws -> String {
        let t = try transcriber(id)
        lastUse[id] = Date()
        defer { lastUse[id] = Date() }
        return try await t.transcribe(recording, request)
    }

    func transcribeSamples(_ id: EngineID, _ samples: [Float], _ request: TranscriptionRequest) async throws -> String {
        let t = try transcriber(id)
        lastUse[id] = Date()
        defer { lastUse[id] = Date() }
        if let p = t as? ParakeetTranscriber { return try await p.text(samples, language: request.language) }
        if let w = t as? WhisperTranscriber { return try await w.text(samples, request) }
        let recording = try AudioFiles.recording(from: samples)
        defer { recording.discard() }
        return try await t.transcribe(recording, request)
    }

    func streamer(_ id: EngineID, request: TranscriptionRequest, threshold: Double, voices: Bool) -> FinalStreamer {
        let live: LiveSession? = id == .apple ? AppleLiveSession(request: request) : nil
        return FinalStreamer(threshold: threshold, precomputeVoices: voices, live: live) { [weak self] samples in
            guard let self else { return "" }
            return try await self.transcribeSamples(id, samples, request)
        }
    }

    func unload(_ id: EngineID) {
        loaded[id] = nil
        lastUse[id] = nil
    }

    func unloadAll() {
        loaded.removeAll()
        lastUse.removeAll()
    }

    private func scheduleReaper() {
        guard reaper == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reap() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        reaper = t
    }

    private func reap() {
        let now = Date()
        for (id, date) in lastUse where id != .apple && now.timeIntervalSince(date) > Self.idleUnload {
            loaded[id] = nil
            lastUse[id] = nil
        }
        if loaded.keys.allSatisfy({ $0 == .apple }) {
            reaper?.invalidate()
            reaper = nil
        }
    }
}
