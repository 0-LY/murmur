import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

enum VoiceGate {
    static let frameSeconds = 0.02
    static let padSeconds = 0.2
    static let minSpeechSeconds = 0.06
    static let defaultThreshold: Double = -45
    static let thresholdRange: ClosedRange<Double> = -60 ... -25
    static let silentPeak: Float = 1e-5

    static func clampThreshold(_ db: Double) -> Double {
        guard db.isFinite else { return defaultThreshold }
        return min(thresholdRange.upperBound, max(thresholdRange.lowerBound, db))
    }

    static func dbfs(_ rms: Float) -> Double {
        20 * log10(Double(max(rms, 1e-7)))
    }

    static func frameLevels(_ samples: [Float], rate: Double = Recording.sampleRate) -> [Double] {
        let size = max(1, Int(rate * frameSeconds))
        guard !samples.isEmpty else { return [] }
        var out: [Double] = []
        out.reserveCapacity(samples.count / size + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + size)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            out.append(dbfs((sum / Float(end - i)).squareRoot()))
            i = end
        }
        return out
    }

    static func speechFrames(_ levels: [Double], threshold: Double) -> [Int] {
        levels.indices.filter { levels[$0] >= threshold }
    }

    static func hasSpeech(_ samples: [Float], threshold: Double, rate: Double = Recording.sampleRate) -> Bool {
        let frames = speechFrames(frameLevels(samples, rate: rate), threshold: threshold)
        return Double(frames.count) * frameSeconds >= minSpeechSeconds
    }

    static func trimRange(_ samples: [Float], threshold: Double, rate: Double = Recording.sampleRate) -> Range<Int>? {
        let levels = frameLevels(samples, rate: rate)
        let frames = speechFrames(levels, threshold: threshold)
        guard Double(frames.count) * frameSeconds >= minSpeechSeconds, let first = frames.first, let last = frames.last else { return nil }
        let size = max(1, Int(rate * frameSeconds))
        let pad = Int(rate * padSeconds)
        let start = max(0, first * size - pad)
        let end = min(samples.count, (last + 1) * size + pad)
        guard start < end else { return nil }
        return start..<end
    }

    static func trim(_ samples: [Float], threshold: Double, rate: Double = Recording.sampleRate) -> [Float]? {
        trimRange(samples, threshold: threshold, rate: rate).map { Array(samples[$0]) }
    }

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    static func loudestFrame(_ samples: [Float], rate: Double = Recording.sampleRate) -> Double {
        frameLevels(samples, rate: rate).max() ?? -120
    }

    static func isSilentInput(_ samples: [Float]) -> Bool {
        samples.isEmpty || peak(samples) < silentPeak
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return -120 }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * min(1, max(0, p))).rounded())
        return sorted[idx]
    }

    static func noiseFloor(_ samples: [Float], rate: Double = Recording.sampleRate) -> Double {
        percentile(frameLevels(samples, rate: rate), 0.5)
    }

    static func suggestedThreshold(noiseFloor: Double) -> Double {
        clampThreshold((noiseFloor + 12).rounded())
    }

    static func sensitivity(forThreshold db: Double) -> Double {
        let r = thresholdRange
        return (r.upperBound - clampThreshold(db)) / (r.upperBound - r.lowerBound)
    }

    static func threshold(forSensitivity s: Double) -> Double {
        let r = thresholdRange
        return clampThreshold((r.upperBound - min(1, max(0, s)) * (r.upperBound - r.lowerBound)).rounded())
    }

    static func peaks(_ samples: [Float], bars: Int) -> [Float] {
        guard bars > 0, !samples.isEmpty else { return Array(repeating: 0, count: max(0, bars)) }
        let step = max(1, samples.count / bars)
        return (0..<bars).map { b in
            let start = b * step
            guard start < samples.count else { return 0 }
            let end = min(samples.count, start + step)
            var m: Float = 0
            for i in start..<end { m = max(m, abs(samples[i])) }
            return min(1, m)
        }
    }
}

enum MicQuality: Equatable {
    case good
    case tooQuiet
    case tooNoisy
    case clipping
    case noSpeech
    case silent

    var title: String {
        switch self {
        case .good: "Good"
        case .tooQuiet: "Too quiet"
        case .tooNoisy: "Too noisy"
        case .clipping: "Clipping"
        case .noSpeech: "No speech heard"
        case .silent: "Microphone sends no sound"
        }
    }

    var tip: String {
        switch self {
        case .good: "Sounds clear. You're ready to talk."
        case .tooQuiet: "Speak a little louder, move closer, or raise the input volume in System Settings → Sound."
        case .tooNoisy: "There's a lot of background noise. Try a headset mic or a quieter spot."
        case .clipping: "It's too loud and distorts. Move back a little or lower the input volume."
        case .noSpeech: "Say a sentence while the test is recording, or make Sensitivity higher."
        case .silent: "Check the mute switch, the input volume, and the input chosen in System Settings → Sound."
        }
    }

    var ok: Bool { self == .good }

    static let clipLevel: Float = 0.985
    static let clipFraction = 0.001
    static let quietSpeech: Double = -36
    static let minSNR: Double = 15

    static func rate(_ samples: [Float], threshold: Double, rate: Double = Recording.sampleRate) -> MicQuality {
        if VoiceGate.isSilentInput(samples) { return .silent }
        let levels = VoiceGate.frameLevels(samples, rate: rate)
        let speech = VoiceGate.speechFrames(levels, threshold: threshold)
        guard Double(speech.count) * VoiceGate.frameSeconds >= VoiceGate.minSpeechSeconds else { return .noSpeech }
        let clipped = samples.reduce(0) { $0 + (abs($1) >= clipLevel ? 1 : 0) }
        if Double(clipped) / Double(samples.count) > clipFraction { return .clipping }
        let speechLevel = VoiceGate.percentile(speech.map { levels[$0] }, 0.9)
        if speechLevel < quietSpeech { return .tooQuiet }
        let noise = VoiceGate.percentile(levels, 0.1)
        if speechLevel - noise < minSNR { return .tooNoisy }
        return .good
    }
}

enum CoreAudioMics {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func name(of id: AudioDeviceID?) -> String? {
        guard let id else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func observe(_ block: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultInputDevice] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in block() }
        }
    }
}

@MainActor
final class MicInput: ObservableObject {
    static let shared = MicInput()

    @Published private(set) var name = ""
    @Published private(set) var device: AudioDeviceID?
    private var started = false
    private let defaultID: () -> AudioDeviceID?
    private let nameOf: (AudioDeviceID?) -> String?
    private let observe: (@escaping () -> Void) -> Void
    var onChange: () -> Void = {}

    init(defaultID: @escaping () -> AudioDeviceID? = { CoreAudioMics.defaultInput() },
         nameOf: @escaping (AudioDeviceID?) -> String? = { CoreAudioMics.name(of: $0) },
         observe: @escaping (@escaping () -> Void) -> Void = { CoreAudioMics.observe($0) }) {
        self.defaultID = defaultID
        self.nameOf = nameOf
        self.observe = observe
    }

    var displayName: String { name.isEmpty ? "No microphone" : name }

    func start() {
        reload()
        guard !started else { return }
        started = true
        observe { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    func reload() {
        device = defaultID()
        name = nameOf(device) ?? ""
    }

    func changed() {
        let before = device
        reload()
        if device != before { onChange() }
    }
}

enum CheckMic {
    static let quietSeconds = 2.0
    static let speakSeconds = 4.0

    enum Verdict: Equatable { case good, tooQuiet, tooNoisy, noVoice, silent }

    struct Result: Equatable {
        let noise: Double
        let voice: Double
        let threshold: Double
        let verdict: Verdict
    }

    static func evaluate(quiet: [Float], speech: [Float]) -> Result {
        if VoiceGate.isSilentInput(quiet) && VoiceGate.isSilentInput(speech) {
            return Result(noise: -120, voice: -120, threshold: VoiceGate.defaultThreshold, verdict: .silent)
        }
        let noise = VoiceGate.noiseFloor(quiet)
        let voice = VoiceGate.percentile(VoiceGate.frameLevels(speech), 0.9)
        let fromNoise = noise + 12
        let fromVoice = voice - 10
        let raw = voice - noise >= 14 ? min(fromNoise, fromVoice) : fromNoise
        let threshold = VoiceGate.clampThreshold(raw.rounded())
        let verdict: Verdict
        if voice - noise < 6 { verdict = noise > -45 ? .tooNoisy : .noVoice }
        else if voice < MicQuality.quietSpeech { verdict = .tooQuiet }
        else if voice - noise < 14 { verdict = .tooNoisy }
        else { verdict = .good }
        return Result(noise: noise, voice: voice, threshold: threshold, verdict: verdict)
    }

    static func summary(_ r: Result) -> String {
        switch r.verdict {
        case .silent: return "No sound from the microphone"
        case .noVoice: return String(format: "Room %.0f dB · no voice heard — try again", r.noise)
        default:
            let tag: String
            switch r.verdict {
            case .good: tag = "✓ Good"
            case .tooQuiet: tag = "Too quiet — move closer"
            case .tooNoisy: tag = "Noisy — try Voice Isolation"
            default: tag = ""
            }
            return String(format: "Room %.0f dB · Voice %.0f dB · %@", r.noise, r.voice, tag)
        }
    }
}

@MainActor
final class MicTester: ObservableObject {
    enum Phase: Equatable { case idle, quiet, speak, recording, transcribing, done }

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 28)
    @Published var waveform: [Float] = []
    @Published var quality: MicQuality?
    @Published var transcript = ""
    @Published var noiseDB: Double?
    @Published var suggested: Double?
    @Published var countdown: Double = 0
    @Published var silentWarning = false
    @Published var check: CheckMic.Result?
    @Published var meter: Float = 0

    static let noiseSeconds = 3.0
    static let testSeconds = 6.0

    private let recorder = Recorder()
    private var timer: Timer?
    private var started = Date()
    private var player: AVAudioPlayer?
    private var playback: Recording?
    private var peakSeen: Float = 0
    private var lastLevel = Date()
    private var quietEnd = 0

    init() {
        recorder.onLevel = { [weak self] l in self?.take(l) }
    }

    var busy: Bool { phase == .quiet || phase == .speak || phase == .recording || phase == .transcribing }

    var checking: Bool { phase == .quiet || phase == .speak }

    private func take(_ l: Float) {
        let now = Date()
        let dt = min(0.25, max(0.001, now.timeIntervalSince(lastLevel)))
        lastLevel = now
        level = l
        let target = Float(LevelDisplay.meterFraction(db: LevelDisplay.db(normalized: l)))
        meter = LevelDisplay.smooth(meter, toward: l > 0 ? target : 0, dt: dt)
        levels.removeFirst()
        levels.append(l)
        peakSeen = max(peakSeen, l)
    }

    func checkMic(apply: @escaping (Double) -> Void) {
        if checking { stop(); return }
        guard ensureAccess(), !busy else { return }
        stopAll()
        guard start() else { return }
        check = nil
        phase = .quiet
        tick(limit: CheckMic.quietSeconds) { [weak self] in
            guard let self, self.phase == .quiet else { return }
            self.quietEnd = self.recorder.samples(from: 0).count
            self.phase = .speak
            self.tick(limit: CheckMic.speakSeconds) { [weak self] in
                guard let self, self.phase == .speak else { return }
                let all = self.recorder.stop(keepWarm: false)
                let cut = min(self.quietEnd, all.count)
                let result = CheckMic.evaluate(quiet: Array(all[0..<cut]), speech: Array(all[cut...]))
                self.check = result
                self.noiseDB = result.noise
                self.level = 0
                self.meter = 0
                self.phase = .idle
                self.silentWarning = result.verdict == .silent
                guard result.verdict != .silent, result.verdict != .noVoice else { return }
                self.suggested = result.threshold
                apply(result.threshold)
            }
        }
    }

    func testRecording(config: Config) {
        if phase == .recording { finishTest(config: config); return }
        guard ensureAccess(), !busy else { return }
        stopAll()
        guard start() else { return }
        quality = nil
        transcript = ""
        waveform = []
        phase = .recording
        tick(limit: Self.testSeconds) { [weak self] in self?.finishTest(config: config) }
    }

    private func finishTest(config: Config) {
        guard phase == .recording else { return }
        timer?.invalidate()
        timer = nil
        let samples = recorder.stop(keepWarm: false)
        level = 0
        waveform = VoiceGate.peaks(samples, bars: 64)
        let q = MicQuality.rate(samples, threshold: config.speechThreshold)
        quality = q
        silentWarning = q == .silent
        guard !samples.isEmpty, let rec = try? AudioFiles.recording(from: samples) else { phase = .done; return }
        play(rec)
        guard q != .silent, q != .noSpeech, let trimmed = VoiceGate.trim(samples, threshold: config.speechThreshold),
              let clip = try? AudioFiles.recording(from: trimmed) else { phase = .done; return }
        phase = .transcribing
        let wanted = EngineID(rawValue: config.engine) ?? .apple
        let used = EngineHub.effective(wanted) { ModelStore.shared.isReady($0) }
        Task { @MainActor in
            defer { clip.discard() }
            let request = TranscriptionRequest(language: config.language, vocabulary: config.vocabularyWords,
                                               keyboardLanguages: keyboardLanguages())
            let raw = (try? await EngineHub.shared.transcribe(used, clip, request)) ?? ""
            let text = await Cleaner.clean(raw, mode: config.cleanup, vocabulary: config.vocabularyWords)
            self.transcript = text.isEmpty ? "—" : text
            if self.phase == .transcribing { self.phase = .done }
        }
    }

    private func play(_ rec: Recording) {
        playback?.discard()
        playback = rec
        player = try? AVAudioPlayer(contentsOf: rec.url)
        player?.play()
    }

    func replay() {
        guard let rec = playback else { return }
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: rec.url)
        player?.play()
    }

    var canReplay: Bool { playback != nil }

    private func ensureAccess() -> Bool {
        switch MicAccess.status {
        case .authorized: return true
        case .notDetermined:
            Task { _ = await MicAccess.request() }
            return false
        default:
            MicAccess.openSettings()
            return false
        }
    }

    private func start() -> Bool {
        peakSeen = 0
        silentWarning = false
        Dictation.shared.releaseAudio()
        do {
            try recorder.start()
            return true
        } catch {
            silentWarning = true
            return false
        }
    }

    private func tick(limit: Double, done: @escaping () -> Void) {
        started = Date()
        countdown = limit
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let left = limit - Date().timeIntervalSince(self.started)
                self.countdown = max(0, left)
                if left <= 0 {
                    self.timer?.invalidate()
                    self.timer = nil
                    done()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopAll() {
        timer?.invalidate()
        timer = nil
        if recorder.running { _ = recorder.stop(keepWarm: false) }
        level = 0
        meter = 0
    }

    func stop() {
        stopAll()
        player?.stop()
        if phase != .transcribing { phase = quality == nil ? .idle : .done }
        if phase == .quiet || phase == .speak { phase = .idle }
    }

    func reset() {
        stop()
        playback?.discard()
        playback = nil
        player = nil
        quality = nil
        transcript = ""
        waveform = []
        phase = .idle
    }
}
