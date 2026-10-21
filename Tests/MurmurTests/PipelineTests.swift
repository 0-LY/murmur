import Foundation
import Testing
@testable import Murmur

enum PipelineFixtures {
    static func tone(seconds: Double, dbfs: Double, rate: Double = Recording.sampleRate) -> [Float] {
        let amp = Float(pow(10, dbfs / 20) * 2.squareRoot())
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = Float(0.6 + 0.4 * sin(2 * .pi * 3 * t))
            return amp * env * Float(sin(2 * .pi * 220 * t) + 0.3 * sin(2 * .pi * 660 * t)) / 1.3
        }
    }

    static func padded(_ s: [Float], silence: Double, rate: Double = Recording.sampleRate) -> [Float] {
        let z = [Float](repeating: 0.00002, count: Int(silence * rate))
        return z + s + z
    }

    static func scaled(_ s: [Float], db: Double) -> [Float] {
        let k = Float(pow(10, db / 20))
        return s.map { $0 * k }
    }
}

@MainActor @Suite struct PipelineRegressionTests {
    var cfg: Config {
        var c = Config()
        c.cleanup = .off
        return c
    }

    @Test func normalSpeechReachesTheEngine() async throws {
        let audio = PipelineFixtures.padded(PipelineFixtures.tone(seconds: 1.2, dbfs: -24), silence: 0.4)
        var called = false
        let r = try await DictationPipeline.run(audio, duration: 2.0, cfg: cfg, filter: { $0 },
                                                transcribe: { _ in called = true; return "hello there" })
        #expect(called)
        #expect(r == .text("hello there"))
    }

    @Test func voiceProcessingAttenuationStillCountsAsSpeech() async throws {
        let quiet = PipelineFixtures.scaled(PipelineFixtures.tone(seconds: 1.2, dbfs: -24), db: -14)
        let audio = PipelineFixtures.padded(quiet, silence: 0.4)
        for threshold in [-45.0, -42.0] {
            var c = cfg
            c.speechThreshold = threshold
            let r = try await DictationPipeline.run(audio, duration: 2.0, cfg: c, filter: { $0 }, transcribe: { _ in "ok" })
            #expect(r == .text("ok"))
        }
    }

    @Test func silentInputIsReportedAsMicOffNotTranscribed() async throws {
        let r = try await DictationPipeline.run([Float](repeating: 0, count: 32_000), duration: 2.0, cfg: cfg,
                                                filter: { $0 }, transcribe: { _ in Issue.record("should not transcribe"); return "" })
        #expect(r == .micOff)
    }

    @Test func roomNoiseOnlyIsNoSpeech() async throws {
        let noise = PipelineFixtures.tone(seconds: 2, dbfs: -60)
        let r = try await DictationPipeline.run(noise, duration: 2.0, cfg: cfg, filter: { $0 }, transcribe: { _ in "x" })
        #expect(r == .noSpeech)
    }

    @Test func mainVoiceOffIsANoOp() async throws {
        var c = cfg
        c.mainVoice = false
        let audio = PipelineFixtures.padded(PipelineFixtures.tone(seconds: 1, dbfs: -24), silence: 0.3)
        #expect(await VoiceStore.shared.focus(audio, cfg: c) == audio)
    }

    @Test func emptyEngineTextIsReported() async throws {
        let audio = PipelineFixtures.padded(PipelineFixtures.tone(seconds: 1, dbfs: -24), silence: 0.3)
        let r = try await DictationPipeline.run(audio, duration: 1.6, cfg: cfg, filter: { $0 }, transcribe: { _ in "   " })
        #expect(r == .emptyText)
    }

    @Test func shortTapIsIgnored() async throws {
        let r = try await DictationPipeline.run(PipelineFixtures.tone(seconds: 0.1, dbfs: -24), duration: 0.1, cfg: cfg,
                                                filter: { $0 }, transcribe: { _ in "x" })
        #expect(r == .tooShort)
    }
}

@Suite struct DeadlineTests {
    @Test func slowWorkTimesOut() async {
        await #expect(throws: TimedOut.self) {
            try await Deadline.run(0.2, "Slow") { try await Task.sleep(nanoseconds: 3_000_000_000); return 1 }
        }
    }

    @Test func fastWorkReturns() async throws {
        #expect(try await Deadline.run(2, "Fast") { 7 } == 7)
    }
}

@Suite struct TalkKeyReadinessTests {
    @Test func modifierKeysNeedAccessibility() {
        #expect(TalkKeyMonitor.needsAccessibility(.rightOption))
        #expect(TalkKeyMonitor.needsAccessibility(.fn))
        #expect(TalkKeyMonitor.needsAccessibility(.doubleCommand))
        #expect(!TalkKeyMonitor.needsAccessibility(.custom))
    }

    @Test func untrustedModifierKeyFallsBackToShortcut() {
        #expect(TalkKeySetup.plan(key: .rightOption, trusted: false, hotkey: "ctrl-opt-v") == .modifierWithFallback)
        #expect(TalkKeySetup.plan(key: .doubleCommand, trusted: false, hotkey: "off") == .modifier)
        #expect(TalkKeySetup.plan(key: .doubleCommand, trusted: true, hotkey: "ctrl-opt-v") == .modifier)
        #expect(TalkKeySetup.plan(key: .custom, trusted: false, hotkey: "ctrl-opt-v") == .carbon)
        #expect(!TalkKeySetup.usable(key: .fn, trusted: false))
        #expect(TalkKeySetup.usable(key: .custom, trusted: false))
    }

    @Test func howToTalkHidesOnlyForDoubleTap() {
        #expect(TalkModeRow.hidesControl(.doubleCommand))
        #expect(!TalkModeRow.hidesControl(.rightOption))
        #expect(!TalkModeRow.hidesControl(.custom))
    }
}

@Suite struct RecorderPlanTests {
    let a = RecorderKey(device: 7)

    @Test func firstPressBuilds() {
        #expect(RecorderPlan.decide(current: nil, wanted: a, running: false) == .rebuild)
    }

    @Test func preparedEngineJustStarts() {
        #expect(RecorderPlan.decide(current: a, wanted: a, running: false) == .startPrepared)
    }

    @Test func warmEngineIsReusedWithoutRestart() {
        #expect(RecorderPlan.decide(current: a, wanted: a, running: true) == .reuseRunning)
    }

    @Test func defaultInputChangeRebuilds() {
        #expect(RecorderPlan.decide(current: a, wanted: RecorderKey(device: 8), running: true) == .rebuild)
        #expect(RecorderPlan.decide(current: a, wanted: RecorderKey(device: nil), running: false) == .rebuild)
    }

    @Test func sinkOnlyKeepsAudioWhileCapturing() throws {
        let f = AudioFiles.format16k
        let sink = SampleSink(input: f)
        let buf = AVAudioPCMBufferFixture.make(frames: 1600, value: 0.1)
        #expect(sink.append(buf) == nil)
        #expect(sink.count == 0)
        sink.begin()
        #expect(sink.append(buf) != nil)
        #expect(sink.count > 0)
        let taken = sink.take()
        #expect(!taken.isEmpty)
        #expect(sink.append(buf) == nil)
        #expect(sink.count == 0)
    }
}

import AVFoundation

enum AVAudioPCMBufferFixture {
    static func make(frames: Int, value: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: AudioFiles.format16k, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { b.floatChannelData![0][i] = value }
        return b
    }
}

@MainActor @Suite struct PipelineEndToEndTests {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_E2E"] == "1"

    @Test(.enabled(if: PipelineEndToEndTests.enabled), .timeLimit(.minutes(5)))
    func appleEngineThroughTheTalkKeyPipeline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let phrase = BenchPhrase(text: "Please move the Linear ticket to done and ping me on Slack.", language: .en, voice: "Samantha")
        let url = try Bench.synth(phrase, index: 0, dir: dir)
        let samples = PipelineFixtures.padded(try AudioFiles.readSamples(url), silence: 0.5)
        let duration = Double(samples.count) / Recording.sampleRate
        var cfg = Config()
        cfg.language = .en
        cfg.cleanup = .quick
        cfg.mainVoice = true
        let request = TranscriptionRequest(language: .en, vocabulary: cfg.vocabularyWords, keyboardLanguages: ["en"])
        for gain in [0.0, -14.0] {
            let input = PipelineFixtures.scaled(samples, db: gain)
            let r = try await DictationPipeline.run(input, duration: duration, cfg: cfg,
                filter: { await VoiceStore.shared.focus($0, cfg: cfg) },
                transcribe: { try await EngineHub.shared.transcribe(.apple, $0, request) })
            guard case .text(let text) = r else {
                Issue.record("gain \(gain): \(r)")
                continue
            }
            let wer = Bench.wer(reference: phrase.text, hypothesis: text)
            print("E2E gain \(gain) dB: WER \(String(format: "%.1f", wer * 100))%")
            #expect(wer < 0.25)
        }
    }
}
