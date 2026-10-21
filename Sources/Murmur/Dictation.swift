import AppKit
import AVFoundation
import os

enum DictationLog {
    static let logger = Logger(subsystem: Identity.bundleId, category: "dictation")

    enum Reason: String {
        case tooShort = "too short"
        case micOff = "mic silent"
        case noSpeech = "no speech above threshold"
        case otherVoice = "speaker filter removed all speech"
        case emptyText = "engine returned no text"
        case engineError = "engine error"
        case copied = "copied instead of pasted"
        case micDenied = "microphone not allowed"
        case micStart = "microphone failed to start"
        case cancelled = "cancelled"
    }

    static func nothingInserted(_ reason: Reason, detail: String = "") {
        logger.notice("dictation ended without insert: \(reason.rawValue, privacy: .public) \(detail, privacy: .public)")
    }

    static func finished(releaseMs: Double, streamed: Bool, engine: String, seconds: Double) {
        logger.notice("dictation done: release→text \(releaseMs, format: .fixed(precision: 0), privacy: .public) ms streamed \(streamed, privacy: .public) engine \(engine, privacy: .public) audio \(seconds, format: .fixed(precision: 1), privacy: .public) s")
    }

    static func started(pressToCaptureMs: Double, engineMs: Double) {
        logger.notice("capture started: press→capture \(pressToCaptureMs, format: .fixed(precision: 1), privacy: .public) ms, engine start \(engineMs, format: .fixed(precision: 1), privacy: .public) ms")
    }
}

enum DictationRules {
    static let minimumDuration: TimeInterval = 0.3
    static let maximumDuration: TimeInterval = 120
    static let minimumVoiced: TimeInterval = 0.4
    static let soundTail: TimeInterval = 0.08
    static let fillers: Set<String> = ["oh", "ooh", "oo", "uh", "um", "umm", "ah", "ahh", "mm", "mmm", "hmm", "hm", "eh", "er", "erm",
                                       "о", "ой", "ем", "е", "а", "ну", "м", "мм", "гм", "ага", "ох", "ах", "ух"]

    static func muteCount(elapsed: TimeInterval, sound: TimeInterval, rate: Double = Recording.sampleRate) -> Int {
        guard sound > 0 else { return 0 }
        return Int(((max(0, elapsed) + sound + soundTail) * rate).rounded(.up))
    }

    static func muted(_ samples: [Float], count: Int) -> [Float] {
        guard count > 0, !samples.isEmpty else { return samples }
        var out = samples
        for i in 0..<min(count, out.count) { out[i] = 0 }
        return out
    }

    static func voicedSeconds(_ samples: [Float], threshold: Double) -> TimeInterval {
        Double(VoiceGate.speechFrames(VoiceGate.frameLevels(samples), threshold: threshold).count) * VoiceGate.frameSeconds
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    static func isFillerOnly(_ text: String) -> Bool {
        let w = words(text)
        return w.isEmpty || w.allSatisfy { fillers.contains($0) }
    }

    static func shouldTranscribe(duration: TimeInterval) -> Bool { duration >= minimumDuration }

    enum Outcome: Equatable {
        case transcribe([Float])
        case micOff
        case noSpeech
        case tooShort
    }

    static func prepare(_ samples: [Float], duration: TimeInterval, threshold: Double, muted: Int = 0) -> Outcome {
        guard shouldTranscribe(duration: duration), !samples.isEmpty else { return .tooShort }
        if VoiceGate.isSilentInput(samples) { return .micOff }
        let clean = Self.muted(samples, count: muted)
        guard voicedSeconds(clean, threshold: threshold) >= minimumVoiced,
              let trimmed = VoiceGate.trim(clean, threshold: threshold) else { return .noSpeech }
        return .transcribe(trimmed)
    }

    static func engineLabel(wanted: EngineID, used: EngineID) -> String {
        let name = ModelInfo.info(used).name
        return wanted == used ? name : "\(name) · \(ModelInfo.info(wanted).name) not downloaded"
    }

}

struct TimedOut: Error, LocalizedError {
    let what: String
    var errorDescription: String? { "\(what) took too long" }
}

enum Deadline {
    static let transcribe: TimeInterval = 30
    static let cleanup: TimeInterval = 3

    static func run<T: Sendable>(_ seconds: TimeInterval, _ what: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut(what: what)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut(what: what) }
            return first
        }
    }
}

enum PipelineResult: Equatable {
    case text(String)
    case tooShort
    case micOff
    case noSpeech
    case otherVoice
    case emptyText
}

@MainActor
enum DictationPipeline {
    static func run(_ samples: [Float], duration: TimeInterval, cfg: Config, muted: Int = 0,
                    filter: ([Float]) async -> [Float],
                    transcribe: (Recording) async throws -> String) async throws -> PipelineResult {
        let speech: [Float]
        switch DictationRules.prepare(samples, duration: duration, threshold: cfg.speechThreshold, muted: muted) {
        case .tooShort: return .tooShort
        case .micOff: return .micOff
        case .noSpeech: return .noSpeech
        case .transcribe(let s): speech = s
        }
        let mine = await filter(speech)
        guard !mine.isEmpty, VoiceGate.hasSpeech(mine, threshold: cfg.speechThreshold) else { return .otherVoice }
        let recording = try AudioFiles.recording(from: mine)
        defer { recording.discard() }
        return await finishText(try await transcribe(recording), cfg: cfg)
    }

    static func stream(_ samples: [Float], duration: TimeInterval, cfg: Config, muted: Int = 0, streamer: FinalStreamer,
                       voices: ([Float]) async -> MainVoice.Outcome?) async throws -> PipelineResult {
        switch DictationRules.prepare(samples, duration: duration, threshold: cfg.speechThreshold, muted: muted) {
        case .tooShort: return .tooShort
        case .micOff: return .micOff
        case .noSpeech: return .noSpeech
        case .transcribe: break
        }
        let clean = DictationRules.muted(samples, count: muted)
        var raw = try await streamer.finish(clean)
        if let o = await voices(clean), !o.dropped.isEmpty {
            guard VoiceGate.hasSpeech(o.samples, threshold: cfg.speechThreshold) else { return .otherVoice }
            raw = try await streamer.retranscribe(dropping: o.dropped, samples: clean)
        }
        return await finishText(raw, cfg: cfg)
    }

    static func finishText(_ raw: String, cfg: Config) async -> PipelineResult {
        if DictationRules.isFillerOnly(raw) { return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyText : .noSpeech }
        let spoken = cfg.spokenPunctuation ? SpokenPunctuation.apply(raw) : raw
        let breaks = SpokenPunctuation.trailingBreaks(spoken)
        let vocabulary = cfg.vocabularyWords
        let mode = cfg.cleanup
        var text = (try? await Deadline.run(Deadline.cleanup, "Cleanup") {
            await Cleaner.clean(spoken, mode: mode, vocabulary: vocabulary)
        }) ?? CleanupRules.quick(spoken.trimmingCharacters(in: .whitespacesAndNewlines), vocabulary: vocabulary)
        if text.isEmpty, breaks.isEmpty { return .emptyText }
        if !breaks.isEmpty, !text.hasSuffix(breaks) { text = text.trimmingCharacters(in: .whitespaces) + breaks }
        return DictationRules.isFillerOnly(text) ? .noSpeech : .text(text)
    }
}

@MainActor
final class Dictation {
    static let shared = Dictation()

    private let recorder = Recorder()
    private var gesture = TalkGesture()
    private var target: InsertTarget?
    private var started = Date()
    private var busy = false
    private var limit: DispatchWorkItem?
    private var live: LiveSession?
    private var stream: FinalStreamer?
    private var liveMode: WritingMode = .final
    private var committer = StableCommitter()
    private var punctuator = LivePunctuator()
    private var livePunctuation = false
    private var fed = 0
    private var feeder: Timer?
    private var typingAborted = false
    private var needsSpace = false
    private var pressedAt = Date()
    private var muteSamples = 0
    private var soundUntil = Date.distantPast
    var onStateChange: () -> Void = {}

    var isListening: Bool { recorder.running }

    init() {
        recorder.onLevel = { [weak self] level in
            let quiet = (self?.soundUntil ?? .distantPast) > Date()
            HUD.shared.model.push(quiet ? 0 : level)
        }
    }

    func prewarm() {
        recorder.prepare()
    }

    func releaseAudio() {
        recorder.invalidate()
    }

    func inputChanged() {
        recorder.invalidate()
        prewarm()
    }

    func press() {
        pressedAt = Date()
        switch gesture.press(mode: Config.current.mode) {
        case .start: begin()
        case .stop: finish()
        case .none: break
        }
    }

    func release() {
        if gesture.release(mode: Config.current.mode) == .stop { finish() }
    }

    func cancelChord() {
        guard recorder.running else { return }
        limit?.cancel()
        stopLive()
        _ = recorder.stop()
        gesture.cancel()
        HotKey.shared.captureEscape(false)
        HUD.shared.hide()
        onStateChange()
    }

    func toggleFromMenu() {
        pressedAt = Date()
        if recorder.running {
            gesture.cancel()
            finish()
        } else {
            gesture.cancel()
            _ = gesture.press(mode: .toggle)
            begin()
        }
    }

    private func begin() {
        guard !busy, !recorder.running else { gesture.cancel(); return }
        switch MicAccess.status {
        case .authorized:
            break
        case .notDetermined:
            gesture.cancel()
            DictationLog.nothingInserted(.micDenied, detail: "asking")
            HUD.shared.show(.failed(HUDText.allowMic), hideAfter: 3)
            Task {
                if await MicAccess.request() {
                    self.prewarm()
                    HUD.shared.show(.done("Microphone allowed — press again to talk"), hideAfter: 2.2)
                }
            }
            return
        default:
            gesture.cancel()
            DictationLog.nothingInserted(.micDenied)
            HUD.shared.show(.failed(HUDText.allowMic), hideAfter: 3)
            MicAccess.openSettings()
            return
        }
        let cfg = Config.current
        do {
            try recorder.start()
        } catch {
            gesture.cancel()
            DictationLog.nothingInserted(.micStart)
            HUD.shared.show(.failed("Couldn't start the microphone"), hideAfter: 2.5)
            return
        }
        started = Date()
        DictationLog.started(pressToCaptureMs: started.timeIntervalSince(pressedAt) * 1000,
                             engineMs: recorder.lastStartMillis)
        let sound = Sounds.start(cfg)
        let elapsed = Date().timeIntervalSince(started)
        muteSamples = DictationRules.muteCount(elapsed: elapsed, sound: sound)
        soundUntil = sound > 0 ? Date().addingTimeInterval(sound + DictationRules.soundTail) : .distantPast
        target = InsertTarget.capture()
        HUD.shared.begin(anchor: Focus.anchorRect())
        let wanted = EngineID(rawValue: cfg.engine) ?? .apple
        let used = EngineHub.effective(wanted) { ModelStore.shared.isReady($0) }
        HUD.shared.show(.listening, engine: ModelInfo.info(used).name)
        startLive(engine: used, cfg: cfg)
        if liveMode == .final { startStream(engine: used, cfg: cfg) }
        HotKey.shared.captureEscape(true)
        HotKey.shared.onEscape = { [weak self] in self?.cancel() }
        let work = DispatchWorkItem { [weak self] in
            self?.gesture.cancel()
            self?.finish()
        }
        limit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationRules.maximumDuration, execute: work)
        EngineHub.shared.warm(used)
        onStateChange()
    }

    func cancel() {
        guard recorder.running else { return }
        limit?.cancel()
        stopLive()
        _ = recorder.stop()
        gesture.cancel()
        HotKey.shared.captureEscape(false)
        DictationLog.nothingInserted(.cancelled)
        HUD.shared.show(.failed("Cancelled"), hideAfter: 1.0)
        onStateChange()
    }

    private func startLive(engine: EngineID, cfg: Config) {
        committer = StableCommitter()
        punctuator = LivePunctuator()
        livePunctuation = cfg.spokenPunctuation
        fed = 0
        typingAborted = false
        live = nil
        liveMode = LiveSupport.effectiveMode(cfg.writing, engine: engine, trusted: Access.trusted, insert: cfg.insert)
        if liveMode == .live, let t = target {
            let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if now == ProcessInfo.processInfo.processIdentifier || t.pid == nil || !Focus.isEditable(t.focus) { liveMode = .final }
        }
        guard liveMode != .final else { return }
        let request = TranscriptionRequest(language: cfg.language, vocabulary: cfg.vocabularyWords,
                                           keyboardLanguages: keyboardLanguages())
        guard let session = LiveSessions.make(engine, request: request) else {
            liveMode = .final
            return
        }
        needsSpace = liveMode == .live && Focus.needsLeadingSpace()
        session.onHypothesis = { [weak self] h in self?.hypothesis(h) }
        live = session
        Task { @MainActor in
            do { try await session.start() } catch {
                if self.live === session { self.live = nil; self.liveMode = .final }
            }
        }
        startFeeder()
    }

    private func startFeeder() {
        guard feeder == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        feeder = t
    }

    private func startStream(engine: EngineID, cfg: Config) {
        stream?.cancel()
        let request = TranscriptionRequest(language: cfg.language, vocabulary: cfg.vocabularyWords,
                                           keyboardLanguages: keyboardLanguages())
        let s = EngineHub.shared.streamer(engine, request: request, threshold: cfg.speechThreshold,
                                          voices: cfg.mainVoice && VoiceStore.shared.ready)
        stream = s
        fed = 0
        Task { @MainActor in await s.start() }
        startFeeder()
    }

    private func pump() {
        guard recorder.running, live != nil || stream != nil else { return }
        var fresh = recorder.samples(from: fed)
        guard !fresh.isEmpty else { return }
        if fed < muteSamples {
            for i in 0..<min(fresh.count, muteSamples - fed) { fresh[i] = 0 }
        }
        fed += fresh.count
        live?.feed(fresh)
        stream?.append(fresh)
    }

    private func stopLive() {
        feeder?.invalidate()
        feeder = nil
        live?.cancel()
        live = nil
        stream?.cancel()
        stream = nil
    }

    private func hypothesis(_ h: LiveHypothesis) {
        guard live != nil else { return }
        let piece = committer.update(h.text, finalWords: h.finalWords)
        typeLive(livePunctuation ? punctuator.feed(committer.typed) : piece)
    }

    private func typeLive(_ piece: String) {
        guard !piece.isEmpty, !typingAborted, let target else { return }
        let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if LiveSupport.shouldAbort(samePid: now == target.pid, sameField: Focus.same(target.focus, Focus.element()),
                                   ownAppFront: now == ProcessInfo.processInfo.processIdentifier) {
            typingAborted = true
            return
        }
        var text = piece
        if needsSpace {
            text = " " + text.drop(while: { $0 == " " })
            needsSpace = false
        }
        Typer.type(LiveSupport.shapeForTyping(text, bundleId: target.bundleId))
    }

    private func finish() {
        guard recorder.running else { return }
        limit?.cancel()
        feeder?.invalidate()
        feeder = nil
        pump()
        let samples = recorder.stop()
        HotKey.shared.captureEscape(false)
        onStateChange()
        let duration = Date().timeIntervalSince(started)
        let cfg = Config.current
        if let session = live, liveMode != .final {
            finishLive(session, samples: samples, duration: duration, cfg: cfg)
            return
        }
        live = nil
        let streamer = stream
        stream = nil
        let muted = muteSamples
        if case .tooShort = DictationRules.prepare(samples, duration: duration, threshold: cfg.speechThreshold, muted: muted) {
            streamer?.cancel()
            DictationLog.nothingInserted(.tooShort, detail: String(format: "%.2fs", duration))
            HUD.shared.hide()
            Sounds.stop(cfg)
            return
        }
        let wanted = EngineID(rawValue: cfg.engine) ?? .apple
        let used = EngineHub.effective(wanted) { ModelStore.shared.isReady($0) }
        let target = self.target
        let device = recorder.deviceName
        busy = true
        HUD.shared.show(.working, engine: ModelInfo.info(used).name)
        let released = Date()
        Task { @MainActor in
            defer {
                self.busy = false
                self.onStateChange()
                Sounds.stop(cfg)
            }
            let request = TranscriptionRequest(language: cfg.language, vocabulary: cfg.vocabularyWords,
                                               keyboardLanguages: keyboardLanguages())
            do {
                let result: PipelineResult
                if let streamer {
                    result = try await Deadline.run(Deadline.transcribe, "Transcription") {
                        try await DictationPipeline.stream(samples, duration: duration, cfg: cfg, muted: muted, streamer: streamer,
                                                           voices: { await VoiceStore.shared.outcome($0, cfg: cfg, cache: streamer.cache) })
                    }
                } else {
                    result = try await DictationPipeline.run(samples, duration: duration, cfg: cfg, muted: muted,
                        filter: { await VoiceStore.shared.focus($0, cfg: cfg) },
                        transcribe: { rec in
                            try await Deadline.run(Deadline.transcribe, "Transcription") {
                                try await EngineHub.shared.transcribe(used, rec, request)
                            }
                        })
                }
                DictationLog.finished(releaseMs: Date().timeIntervalSince(released) * 1000, streamed: streamer != nil,
                                      engine: used.rawValue, seconds: duration)
                switch result {
                case .tooShort:
                    DictationLog.nothingInserted(.tooShort, detail: String(format: "%.2fs", duration))
                    HUD.shared.hide()
                case .micOff:
                    DictationLog.nothingInserted(.micOff, detail: "samples \(samples.count) device \(device)")
                    HUD.shared.show(.failed(HUDText.micOff), hideAfter: 2.2)
                case .noSpeech:
                    DictationLog.nothingInserted(.noSpeech, detail: String(format: "loudest %.1f dBFS threshold %.0f",
                                                                          VoiceGate.loudestFrame(samples), cfg.speechThreshold))
                    HUD.shared.show(.failed(HUDText.noSpeech), hideAfter: 1.8)
                case .otherVoice:
                    DictationLog.nothingInserted(.otherVoice)
                    HUD.shared.show(.failed(HUDText.otherVoice), hideAfter: 1.8)
                case .emptyText:
                    ModelStore.shared.markUsed(used)
                    DictationLog.nothingInserted(.emptyText, detail: used.rawValue)
                    HUD.shared.show(.failed(HUDText.noSpeech), hideAfter: 1.8)
                case .text(let text):
                    ModelStore.shared.markUsed(used)
                    let label = target.map { Inserter.insert(text, into: $0, config: cfg) } ?? "Copied"
                    if label != "Done" { DictationLog.nothingInserted(.copied, detail: label) }
                    let suffix = used == wanted ? "" : " · \(ModelInfo.info(used).name)"
                    HUD.shared.show(.done(label + suffix), hideAfter: 1.4)
                }
            } catch {
                DictationLog.nothingInserted(.engineError, detail: "\(used.rawValue) \(type(of: error))")
                let missing = used != .apple && !ModelStore.shared.isReady(used)
                HUD.shared.show(.failed(missing ? HUDText.modelMissing : ((error as? LocalizedError)?.errorDescription ?? "Couldn't turn that into text")), hideAfter: 2.8)
            }
        }
    }

    private func finishLive(_ session: LiveSession, samples: [Float], duration: TimeInterval, cfg: Config) {
        live = nil
        stream?.cancel()
        stream = nil
        defer { if !busy { Sounds.stop(cfg) } }
        let target = self.target
        let wanted = EngineID(rawValue: cfg.engine) ?? .apple
        let used = EngineHub.effective(wanted) { ModelStore.shared.isReady($0) }
        let outcome = DictationRules.prepare(samples, duration: duration, threshold: cfg.speechThreshold, muted: muteSamples)
        if committer.typed.isEmpty {
            switch outcome {
            case .tooShort: session.cancel(); HUD.shared.hide(); return
            case .micOff: session.cancel(); HUD.shared.show(.failed(HUDText.micOff), hideAfter: 2.2); return
            case .noSpeech: session.cancel(); HUD.shared.show(.failed(HUDText.noSpeech), hideAfter: 1.8); return
            case .transcribe: break
            }
        }
        busy = true
        HUD.shared.show(.working, engine: ModelInfo.info(used).name)
        Task { @MainActor in
            defer {
                self.busy = false
                self.onStateChange()
                Sounds.stop(cfg)
            }
            let raw = (try? await Deadline.run(Deadline.transcribe, "Transcription") { try await session.finish() }) ?? ""
            ModelStore.shared.markUsed(used)
            if self.typingAborted {
                let leftover = LiveSupport.rest(after: self.committer.typed, in: raw)
                let rest = self.livePunctuation ? SpokenPunctuation.apply(leftover) : leftover
                if !rest.isEmpty { Clip.write(rest, NSPasteboard.general, private: false) }
                HUD.shared.show(.done(rest.isEmpty ? "Done" : "Rest copied — field changed"), hideAfter: 2.0)
                return
            }
            let flushed = self.committer.typed.isEmpty && DictationRules.isFillerOnly(raw) ? "" : self.committer.flush(raw)
            let tail = self.livePunctuation ? self.punctuator.finish(self.committer.typed) : flushed
            self.typeLive(tail)
            if self.committer.typed.isEmpty {
                HUD.shared.show(.failed(HUDText.noSpeech), hideAfter: 1.8)
            } else if self.typingAborted {
                let rest = tail.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { Clip.write(rest, NSPasteboard.general, private: false) }
                HUD.shared.show(.done("Rest copied — field changed"), hideAfter: 2.0)
            } else {
                HUD.shared.show(.done("Done"), hideAfter: 1.2)
            }
        }
    }
}
