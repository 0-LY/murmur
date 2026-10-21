import Foundation
import Testing
@testable import Murmur

enum LatencyBench {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_LATENCY"] == "1"

    struct Clip {
        let name: String
        let text: String
    }

    static let clips = [
        Clip(name: "5s", text: "Please move the Linear ticket to done and ping me on Slack when it is ready."),
        Clip(name: "15s", text: "I checked the export this morning and it finished without errors. [[slnc 800]] Can you send the report to the team before lunch? [[slnc 800]] Then let's meet at three and decide what goes into the next release."),
        Clip(name: "15s-nopause", text: "I checked the export this morning and it finished without errors so can you send the report to the team before lunch and then let's meet at three and decide what goes into the next release together."),
    ]

    static func synth(_ c: Clip, dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("lat-\(c.name).aiff")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Samantha", "-o", url.path, c.text]
        try p.run()
        p.waitUntilExit()
        return url
    }
}

@MainActor @Suite(.serialized) struct LatencyBenchTests {
    @Test(.enabled(if: LatencyBench.enabled), .timeLimit(.minutes(30)))
    func releaseToText() async throws {
        let base = Bench.out
        let audioDir = base.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let store = ModelStore(root: base.appendingPathComponent("models", isDirectory: true))
        store.refresh()
        let hub = EngineHub(store: store)
        var lines = ["engine\tclip\taudio_s\tmode\trelease_to_text_ms\twer\ttext"]
        for id in [EngineID.parakeetUltra, .apple] {
            guard id == .apple || store.isReady(id) else { lines.append("\(id.rawValue)\tSKIPPED"); continue }
            if id != .apple { try await hub.transcriber(id).prepare() }
            let request = TranscriptionRequest(language: .en, vocabulary: [], keyboardLanguages: ["en"])
            for warmup in [true, false] {
                for c in LatencyBench.clips {
                    let raw = try AudioFiles.readSamples(try LatencyBench.synth(c, dir: audioDir))
                    let samples = raw + [Float](repeating: 0, count: Int(Recording.sampleRate * 0.3))
                    let duration = Double(samples.count) / Recording.sampleRate
                    var oldCfg = Config()
                    oldCfg.cleanup = .smart
                    oldCfg.mainVoice = false
                    let t0 = Date()
                    let before = try await DictationPipeline.run(samples, duration: duration, cfg: oldCfg, filter: { $0 },
                                                                 transcribe: { rec in try await hub.transcribe(id, rec, request) })
                    let beforeMs = Date().timeIntervalSince(t0) * 1000
                    var newCfg = Config()
                    newCfg.mainVoice = false
                    let streamer = hub.streamer(id, request: request, threshold: newCfg.speechThreshold, voices: false)
                    await streamer.start()
                    let chunk = Int(Recording.sampleRate * 0.1)
                    let feedStart = Date()
                    var i = 0
                    while i < samples.count {
                        let end = min(samples.count, i + chunk)
                        streamer.append(Array(samples[i..<end]))
                        i = end
                        let wait = feedStart.addingTimeInterval(Double(i) / Recording.sampleRate).timeIntervalSinceNow
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    }
                    let t1 = Date()
                    let after = try await DictationPipeline.stream(samples, duration: duration, cfg: newCfg, streamer: streamer, voices: { _ in nil })
                    let afterMs = Date().timeIntervalSince(t1) * 1000
                    let pieceTexts = await streamer.text(for: streamer.pieces.map(\.range))
                    let ordered = streamer.pieces.map { "[\(pieceTexts[$0.range] ?? "")]" }.joined(separator: " ")
                    if !warmup { lines.append("\(id.rawValue)\t\(c.name)\tpieces\t\(streamer.pieces.count)\t\(ordered)") }
                    guard !warmup else { continue }
                    func text(_ r: PipelineResult) -> String { if case .text(let t) = r { return t }; return "\(r)" }
                    let ref = c.text.replacingOccurrences(of: "[[slnc 800]] ", with: "")
                    lines.append([id.rawValue, c.name, String(format: "%.1f", duration), "before (full + smart cleanup)",
                                  String(format: "%.0f", beforeMs), String(format: "%.3f", Bench.wer(reference: ref, hypothesis: text(before))), text(before)].joined(separator: "\t"))
                    lines.append([id.rawValue, c.name, String(format: "%.1f", duration), "after (streamed + quick)",
                                  String(format: "%.0f", afterMs), String(format: "%.3f", Bench.wer(reference: ref, hypothesis: text(after))), text(after)].joined(separator: "\t"))
                }
            }
        }
        try lines.joined(separator: "\n").write(to: base.appendingPathComponent("latency.tsv"), atomically: true, encoding: .utf8)
    }
}
