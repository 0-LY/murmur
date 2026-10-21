import Foundation
import Testing
@testable import Murmur

enum Tones {
    static let words: [Double: String] = [220: "alpha", 330: "bravo", 440: "charlie", 550: "delta"]

    static func word(_ s: [Float]) -> String {
        let f = VoiceFixtures.frequency(s.filter { abs($0) > 0.001 })
        return words.min { abs($0.key - f) < abs($1.key - f) }?.value ?? "?"
    }

    static func transcript(_ s: [Float], threshold: Double = -45) -> String {
        let scan = Segmenter.scan(s, from: 0, threshold: threshold, final: true)
        return Segmenter.join(scan.segments.map { word(Array(s[$0])) })
    }
}

@Suite struct SegmenterTests {
    let t = -45.0
    let rate = Recording.sampleRate

    @Test func completedSegmentIsReturnedAfterAPause() {
        let s = VoiceFixtures.voice(220, seconds: 1, dbfs: -20) + VoiceFixtures.gap(0.8) + VoiceFixtures.voice(330, seconds: 1, dbfs: -20) + VoiceFixtures.gap(0.2)
        let open = Segmenter.scan(s, from: 0, threshold: t, final: false)
        #expect(open.segments.count == 1)
        #expect(open.next <= Int(2.0 * rate))
        let rest = Segmenter.scan(s, from: open.next, threshold: t, final: true)
        #expect(rest.segments.count == 1)
        #expect(rest.next == s.count)
    }

    @Test func shortPausesStayInOneSegment() {
        let s = VoiceFixtures.voice(220, seconds: 1, dbfs: -20) + VoiceFixtures.gap(0.3) + VoiceFixtures.voice(220, seconds: 1, dbfs: -20)
        #expect(Segmenter.scan(s, from: 0, threshold: t, final: true).segments.count == 1)
    }

    @Test func longSpeechIsCut() {
        let s = VoiceFixtures.voice(220, seconds: Segmenter.maxSegment + 2, dbfs: -20)
        let scan = Segmenter.scan(s, from: 0, threshold: t, final: true)
        #expect(scan.segments.count == 2)
        #expect(scan.segments.allSatisfy { Double($0.count) / rate <= Segmenter.maxSegment + 0.2 })
    }

    @Test func segmentsNeverOverlapAndCoverAllSpeech() {
        var s: [Float] = []
        for f in [220.0, 330, 440, 550] { s += VoiceFixtures.voice(f, seconds: 0.8, dbfs: -22) + VoiceFixtures.gap(0.7) }
        var next = 0
        var segs: [Range<Int>] = []
        var i = 0
        while i < s.count {
            i = min(s.count, i + Int(0.1 * rate))
            let scan = Segmenter.scan(Array(s[..<i]), from: next, threshold: t, final: i == s.count)
            segs += scan.segments
            next = scan.next
        }
        #expect(segs.count == 4)
        for (a, b) in zip(segs, segs.dropFirst()) { #expect(a.upperBound <= b.lowerBound) }
        #expect(Segmenter.join(segs.map { Tones.word(Array(s[$0])) }) == "alpha bravo charlie delta")
    }

    @Test func joinLowercasesMidSentenceStarts() {
        #expect(Segmenter.join(["Move it to done and", "Ping me later."]) == "Move it to done and ping me later.")
        #expect(Segmenter.join(["It is done.", "Ping me later."]) == "It is done. Ping me later.")
        #expect(Segmenter.join(["Send it and", "I will check"]) == "Send it and I will check")
        #expect(Segmenter.join(["Ask the", "NASA team"]) == "Ask the NASA team")
        #expect(Segmenter.join(["", "  hello "]) == "hello")
    }

    @Test func blipsAreIgnored() {
        let s = VoiceFixtures.gap(0.5) + VoiceFixtures.voice(220, seconds: 0.05, dbfs: -20) + VoiceFixtures.gap(1)
        #expect(Segmenter.scan(s, from: 0, threshold: t, final: true).segments.isEmpty)
    }
}

@MainActor
final class StubLive: LiveSession {
    var onHypothesis: (LiveHypothesis) -> Void = { _ in }
    var result: String
    var fails: Bool
    var fed = 0
    init(result: String, fails: Bool = false) { self.result = result; self.fails = fails }
    func start() async throws { if fails { throw URLError(.cancelled) } }
    func feed(_ samples: [Float]) { fed += samples.count }
    func finish() async throws -> String { result }
    func cancel() {}
}

@MainActor @Suite(.serialized) struct StreamerTests {
    let t = -45.0
    let rate = Recording.sampleRate

    func speech() -> [Float] {
        var s: [Float] = []
        for f in [220.0, 330, 440] { s += VoiceFixtures.voice(f, seconds: 1, dbfs: -22) + VoiceFixtures.gap(0.8) }
        return s
    }

    @Test func segmentsAreTranscribedWhileRecording() async throws {
        var calls = 0
        let streamer = FinalStreamer(threshold: t, precomputeVoices: false) { s in
            calls += 1
            return Tones.word(s)
        }
        let s = speech()
        let chunk = Int(0.1 * rate)
        var i = 0
        while i < s.count - Int(0.9 * rate) {
            let end = min(s.count, i + chunk)
            streamer.append(Array(s[i..<end]))
            i = end
        }
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(calls >= 2)
        let text = try await streamer.finish(s)
        #expect(text == "alpha bravo charlie")
        #expect(calls == 3)
    }

    @Test func streamingEqualsOffline() async throws {
        let s = speech()
        let streamer = FinalStreamer(threshold: t, precomputeVoices: false) { Tones.word($0) }
        var i = 0
        while i < s.count {
            let end = min(s.count, i + Int(0.25 * rate))
            streamer.append(Array(s[i..<end]))
            i = end
        }
        let streamed = try await streamer.finish(s)
        #expect(streamed == Tones.transcript(s, threshold: t - Segmenter.softer))
    }

    @Test func finishWithoutAnyStreamingStillWorks() async throws {
        let s = speech()
        let streamer = FinalStreamer(threshold: t, precomputeVoices: false) { Tones.word($0) }
        #expect(try await streamer.finish(s) == "alpha bravo charlie")
    }

    @Test func droppedRangesAreRetranscribed() async throws {
        let s = speech()
        let streamer = FinalStreamer(threshold: t, precomputeVoices: false) { Tones.word($0) }
        _ = try await streamer.finish(s)
        let second = streamer.pieces[1].range
        let text = try await streamer.retranscribe(dropping: [second], samples: s)
        #expect(text == "alpha charlie")
    }

    @Test func liveStreamerUsesTheLiveResult() async throws {
        let s = speech()
        let live = StubLive(result: "from live")
        let streamer = FinalStreamer(threshold: t, precomputeVoices: false, live: live) { _ in "offline" }
        await streamer.start()
        streamer.append(Array(s[..<16000]))
        #expect(live.fed == 16000)
        #expect(try await streamer.finish(s) == "from live")
        #expect(live.fed == s.count)
    }

    @Test func liveStreamerFallsBackWhenEmptyOrFailed() async throws {
        let s = speech()
        for live in [StubLive(result: ""), StubLive(result: "x", fails: true)] {
            let streamer = FinalStreamer(threshold: t, precomputeVoices: false, live: live) { _ in "offline" }
            await streamer.start()
            #expect(try await streamer.finish(s) == "offline")
        }
    }

    @Test func pipelineStreamProducesCleanText() async throws {
        var cfg = Config()
        cfg.cleanup = .quick
        cfg.spokenPunctuation = false
        let s = speech()
        let streamer = FinalStreamer(threshold: cfg.speechThreshold, precomputeVoices: false) { Tones.word($0) }
        let r = try await DictationPipeline.stream(s, duration: Double(s.count) / rate, cfg: cfg, streamer: streamer, voices: { _ in nil })
        #expect(r == .text("Alpha bravo charlie."))
    }

    @Test func pipelineStreamDropsOtherVoice() async throws {
        var cfg = Config()
        cfg.cleanup = .off
        cfg.spokenPunctuation = false
        let s = speech()
        let streamer = FinalStreamer(threshold: cfg.speechThreshold, precomputeVoices: false) { Tones.word($0) }
        let r = try await DictationPipeline.stream(s, duration: Double(s.count) / rate, cfg: cfg, streamer: streamer, voices: { samples in
            let drop = [Int(1.8 * Recording.sampleRate)..<Int(2.8 * Recording.sampleRate)]
            return MainVoice.Outcome(samples: MainVoice.assemble(samples, drop: drop), report: .init(), dropped: drop)
        })
        #expect(r == .text("alpha charlie"))
    }
}

@Suite struct QuickCleanupTests {
    @Test func spacingAndCapitals() {
        #expect(CleanupRules.quick("hello , world . how are you ?", vocabulary: []) == "Hello, world. How are you?")
        #expect(CleanupRules.quick("one,two;three", vocabulary: []) == "One, two; three.")
        #expect(CleanupRules.quick("( note ) is here", vocabulary: []) == "(Note) is here.")
    }

    @Test func urlsAndNumbersStay() {
        #expect(CleanupRules.quick("open example.com now", vocabulary: []) == "Open example.com now.")
        #expect(CleanupRules.quick("it costs 3.50 today", vocabulary: []) == "It costs 3.50 today.")
        #expect(CleanupRules.quick("meet at 10:30 ok", vocabulary: []) == "Meet at 10:30 ok.")
    }

    @Test func fillersAndVocabulary() {
        #expect(CleanupRules.quick("um so the linear ticket uh is done", vocabulary: ["Linear"]) == "So the Linear ticket is done.")
    }

    @Test func lineBreaksCapitalize() {
        #expect(CleanupRules.quick("first line\nsecond line", vocabulary: []) == "First line\nSecond line.")
    }

    @Test func ukrainian() {
        #expect(CleanupRules.quick("привіт , як справи ? добре", vocabulary: []) == "Привіт, як справи? Добре.")
    }

    @Test func modes() async {
        #expect(await Cleaner.clean("hello world again", mode: .off, vocabulary: []) == "hello world again")
        #expect(await Cleaner.clean("hello world again", mode: .quick, vocabulary: []) == "Hello world again.")
    }

    @Test func smartTimesOutToQuick() async {
        let t0 = Date()
        let out = await Cleaner.clean("hello world again", mode: .smart, vocabulary: [], limit: 0.2) { _, _ in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return "Never"
        }
        #expect(out == "Hello world again.")
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }

    @Test func smartUsesAIWhenFast() async {
        let out = await Cleaner.clean("hello world again", mode: .smart, vocabulary: []) { _, _ in "Hello, world, again!" }
        #expect(out == "Hello, world, again!")
    }

    @Test func legacyLightBecomesQuick() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"cleanup":"light"}"#.utf8))
        #expect(c.cleanup == .quick)
        #expect(Config().cleanup == .quick)
    }
}
