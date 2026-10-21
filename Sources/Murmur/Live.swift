import AppKit
import AVFoundation
import CoreMedia
import Speech

enum LiveWords {
    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func join(_ words: [String]) -> String { words.joined(separator: " ") }

    static func key(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func alignEnd(typed: [String], in words: [String]) -> Int {
        let n = typed.count, m = words.count
        guard n > 0 else { return 0 }
        guard m > 0 else { return 0 }
        let t = typed.map(key), w = words.map(key)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = t[i - 1] == w[j - 1] ? 0 : 1
                cur[j] = min(prev[j - 1] + cost, prev[j] + 1, cur[j - 1] + 1)
            }
            swap(&prev, &cur)
        }
        var best = 0
        var bestCost = Int.max
        for j in 0...m where prev[j] <= bestCost {
            if prev[j] < bestCost || j > best {
                best = j
                bestCost = prev[j]
            }
        }
        return best
    }
}

struct StableCommitter {
    static let agreement = 2

    private(set) var typed: [String] = []
    private var history: [[String]] = []

    var typedText: String { LiveWords.join(typed) }

    mutating func update(_ hypothesis: String, finalWords: Int = 0) -> String {
        let words = LiveWords.split(hypothesis)
        history.append(words)
        if history.count > Self.agreement { history.removeFirst(history.count - Self.agreement) }
        var stable = 0
        if history.count >= Self.agreement {
            let lcp = Self.commonPrefix(history)
            stable = min(lcp, max(0, words.count - 1))
        }
        stable = max(stable, min(finalWords, words.count))
        return commit(words, upTo: stable)
    }

    mutating func flush(_ final: String) -> String {
        let words = LiveWords.split(final)
        return commit(words, upTo: words.count)
    }

    private mutating func commit(_ words: [String], upTo stable: Int) -> String {
        let start = LiveWords.alignEnd(typed: typed, in: Array(words.prefix(max(stable, 0))))
        guard stable > start else { return "" }
        let fresh = Array(words[start..<stable])
        let text = (typed.isEmpty ? "" : " ") + LiveWords.join(fresh)
        typed += fresh
        return text
    }

    static func commonPrefix(_ list: [[String]]) -> Int {
        guard let first = list.first else { return 0 }
        var n = 0
        while n < first.count, list.allSatisfy({ n < $0.count && $0[n] == first[n] }) { n += 1 }
        return n
    }
}

enum LiveSupport {
    static func supports(_ id: EngineID) -> Bool { id != .whisperTurbo }

    static func effectiveMode(_ wanted: WritingMode, engine: EngineID, trusted: Bool, insert: InsertMode) -> WritingMode {
        guard wanted != .final, supports(engine) else { return .final }
        if !trusted || insert == .copy { return .final }
        return wanted
    }

    static func shouldAbort(samePid: Bool, sameField: Bool, ownAppFront: Bool) -> Bool {
        !samePid || !sameField || ownAppFront
    }

    static func needsSpace(before text: String, cursor: Int) -> Bool {
        let units = Array(text.utf16)
        guard cursor > 0, cursor <= units.count else { return false }
        guard let scalar = Unicode.Scalar(units[cursor - 1]) else { return false }
        let c = Character(scalar)
        return !(c.isWhitespace || "([{\"'“‘«".contains(c))
    }

    static func rest(after typed: [String], in final: String) -> String {
        let words = LiveWords.split(final)
        let start = LiveWords.alignEnd(typed: typed, in: words)
        return LiveWords.join(Array(words[start...]))
    }

    static func shapeForTyping(_ text: String, bundleId: String?) -> String {
        guard TextShape.terminals.contains(bundleId ?? "") else { return text }
        let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let kept = flat.unicodeScalars.filter { u in
            if u.value < 0x20 || u.value == 0x7f { return false }
            if (0x80...0x9f).contains(u.value) { return false }
            return true
        }
        return String(String.UnicodeScalarView(kept))
    }
}

enum Typer {
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if i > 0 { lineBreak() }
            typeChars(String(line))
        }
    }

    static func lineBreak() {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down) else { continue }
            e.flags = .maskShift
            e.post(tap: .cghidEventTap)
        }
    }

    static func typeChars(_ text: String) {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(units.count, i + 16)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[i..<end])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
            i = end
        }
    }
}

struct LiveHypothesis: Equatable, Sendable {
    var text: String
    var finalWords: Int
}

@MainActor
protocol LiveSession: AnyObject {
    var onHypothesis: (LiveHypothesis) -> Void { get set }
    func start() async throws
    func feed(_ samples: [Float])
    func finish() async throws -> String
    func cancel()
}

@MainActor
final class AppleLiveSession: LiveSession {
    var onHypothesis: (LiveHypothesis) -> Void = { _ in }
    private let request: TranscriptionRequest
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Error>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var finalized = ""
    private var volatile = ""
    private var pending: [Float] = []
    private var ready = false

    init(request: TranscriptionRequest) {
        self.request = request
    }

    func start() async throws {
        let supported = await DictationTranscriber.supportedLocales
        let locale = LanguageChoice.appleLocale(for: request.language, keyboard: request.keyboardLanguages, supported: supported)
        let t = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await install.downloadAndInstall()
        }
        let a = SpeechAnalyzer(modules: [t])
        if !request.vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = request.vocabulary
            try? await a.setContext(context)
        }
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) ?? AudioFiles.format16k
        format = best
        if best != AudioFiles.format16k { converter = AVAudioConverter(from: AudioFiles.format16k, to: best) }
        try await a.prepareToAnalyze(in: best)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont
        transcriber = t
        analyzer = a
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await r in t.results {
                    guard let self else { return }
                    let text = String(r.text.characters)
                    if r.isFinal {
                        self.finalized += text
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    let finalWords = LiveWords.split(self.finalized).count
                    self.onHypothesis(LiveHypothesis(text: (self.finalized + self.volatile).trimmingCharacters(in: .whitespaces), finalWords: finalWords))
                }
            } catch {}
        }
        analyzeTask = Task { _ = try await a.analyzeSequence(stream) }
        ready = true
        if !pending.isEmpty {
            let p = pending
            pending.removeAll()
            feed(p)
        }
    }

    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard ready, let continuation else {
            pending += samples
            return
        }
        guard let buf = Self.buffer(samples) else { return }
        if let converter, let format {
            let ratio = format.sampleRate / AudioFiles.format16k.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard error == nil, out.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: out))
        } else {
            continuation.yield(AnalyzerInput(buffer: buf))
        }
    }

    func finish() async throws -> String {
        continuation?.finish()
        continuation = nil
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        _ = try? await analyzeTask?.value
        await resultsTask?.value
        return (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        analyzeTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: AudioFiles.format16k, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buf
    }
}

@MainActor
final class ParakeetLiveSession: LiveSession {
    var onHypothesis: (LiveHypothesis) -> Void = { _ in }
    private let engine: ParakeetTranscriber
    private let request: TranscriptionRequest
    private var samples: [Float] = []
    private var processed = 0
    private var loop: Task<Void, Never>?
    private var running = false
    private var cancelled = false
    static let minNew = Int(Recording.sampleRate * 0.25)

    init(engine: ParakeetTranscriber, request: TranscriptionRequest) {
        self.engine = engine
        self.request = request
    }

    func start() async throws {
        try await engine.prepare()
        running = true
        loop = Task { @MainActor [weak self] in
            var interval: Double = 0.45
            while let self, self.running, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard self.running else { return }
                guard self.samples.count - self.processed >= Self.minNew else { continue }
                let snapshot = self.samples
                self.processed = snapshot.count
                let t0 = Date()
                guard let text = try? await self.engine.text(snapshot, language: self.request.language), self.running else { continue }
                let cost = Date().timeIntervalSince(t0)
                interval = min(1.5, max(0.35, cost * 3))
                self.onHypothesis(LiveHypothesis(text: text, finalWords: 0))
            }
        }
    }

    func feed(_ samples: [Float]) {
        self.samples += samples
    }

    func finish() async throws -> String {
        running = false
        loop?.cancel()
        guard !cancelled else { return "" }
        return try await engine.text(samples, language: request.language)
    }

    func cancel() {
        cancelled = true
        running = false
        loop?.cancel()
    }
}

@MainActor
enum LiveSessions {
    static func make(_ id: EngineID, request: TranscriptionRequest, hub: EngineHub? = nil) -> LiveSession? {
        let hub = hub ?? .shared
        switch id {
        case .apple:
            return AppleLiveSession(request: request)
        case .parakeetUltra, .parakeetRedux:
            guard let t = try? hub.transcriber(id) as? ParakeetTranscriber else { return nil }
            return ParakeetLiveSession(engine: t, request: request)
        case .whisperTurbo:
            return nil
        }
    }
}
