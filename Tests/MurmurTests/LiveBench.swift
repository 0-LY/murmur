import Foundation
import Testing
@testable import Murmur

enum LiveBench {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_LIVE_BENCH"] == "1"
}

@Suite(.serialized) struct LiveBenchTests {
    @MainActor @Test(.enabled(if: LiveBench.enabled), .timeLimit(.minutes(30)))
    func streaming() async throws {
        let base = Bench.out
        let audioDir = base.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let store = ModelStore(root: base.appendingPathComponent("models", isDirectory: true))
        store.refresh()
        let hub = EngineHub(store: store)
        let phrases = Bench.phrases
        let audio = try phrases.enumerated().map { i, p in try AudioFiles.readSamples(try Bench.synth(p, index: i, dir: audioDir)) }
        var lines = ["engine\tphrase\tlang\taudio_s\tfirst_word_s\tfinal_after_end_s\ttyped_wer\treference\ttyped"]
        let engines: [EngineID] = [.apple, .parakeetUltra, .parakeetRedux]
        for id in engines {
            guard id == .apple || store.isReady(id) else {
                lines.append("\(id.rawValue)\tSKIPPED (model not in scratch store)")
                continue
            }
            if id != .apple { try await hub.transcriber(id).prepare() }
            for (i, p) in phrases.enumerated() {
                let req = TranscriptionRequest(language: p.language, vocabulary: [], keyboardLanguages: ["en", "uk"])
                guard let session = LiveSessions.make(id, request: req, hub: hub) else { continue }
                var committer = StableCommitter()
                var typed = ""
                var first: Double?
                let t0 = Date()
                session.onHypothesis = { h in
                    let piece = committer.update(h.text, finalWords: h.finalWords)
                    if !piece.isEmpty {
                        typed += piece
                        if first == nil { first = Date().timeIntervalSince(t0) }
                    }
                }
                try await session.start()
                let samples = audio[i] + [Float](repeating: 0, count: Int(Recording.sampleRate * 0.3))
                let chunk = Int(Recording.sampleRate * 0.1)
                var start = 0
                let feedStart = Date()
                while start < samples.count {
                    let end = min(samples.count, start + chunk)
                    session.feed(Array(samples[start..<end]))
                    start = end
                    let due = feedStart.addingTimeInterval(Double(start) / Recording.sampleRate)
                    let wait = due.timeIntervalSinceNow
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                }
                let endAudio = Date()
                let final = try await session.finish()
                typed += committer.flush(final)
                let after = Date().timeIntervalSince(endAudio)
                let duration = Double(audio[i].count) / Recording.sampleRate
                let firstWord = first.map { String(format: "%.2f", $0) } ?? "none"
                lines.append([id.rawValue, "\(i + 1)", p.language.rawValue, String(format: "%.1f", duration), firstWord,
                              String(format: "%.2f", after), String(format: "%.3f", Bench.wer(reference: p.text, hypothesis: typed)),
                              p.text, typed].joined(separator: "\t"))
            }
            hub.unload(id)
        }
        try lines.joined(separator: "\n").write(to: base.appendingPathComponent("live.tsv"), atomically: true, encoding: .utf8)
    }
}
