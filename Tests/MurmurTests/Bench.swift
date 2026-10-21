import Foundation
import Testing
@testable import Murmur

struct BenchPhrase {
    let text: String
    let language: SpeechLanguage
    let voice: String
}

enum Bench {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_BENCH"] == "1"
    static var out: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MURMUR_BENCH_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
    }

    static let phrases: [BenchPhrase] = [
        BenchPhrase(text: "Please move the Linear ticket to done and ping me on Slack.", language: .en, voice: "Samantha"),
        BenchPhrase(text: "Open Figma and share the new design with the team.", language: .en, voice: "Samantha"),
        BenchPhrase(text: "Drop the report on Stash so I can send it later.", language: .en, voice: "Samantha"),
        BenchPhrase(text: "The meeting starts after lunch, so let's keep it short.", language: .en, voice: "Samantha"),
        BenchPhrase(text: "Can you check whether the export finished last night?", language: .en, voice: "Samantha"),
        BenchPhrase(text: "I think we should ship the beta on Friday.", language: .en, voice: "Samantha"),
        BenchPhrase(text: "Привіт, я сьогодні працюю з дому.", language: .uk, voice: "Lesya"),
        BenchPhrase(text: "Будь ласка, надішли мені звіт до вечора.", language: .uk, voice: "Lesya"),
        BenchPhrase(text: "Нагадай мені завтра зателефонувати лікарю.", language: .uk, voice: "Lesya"),
        BenchPhrase(text: "Зустріч перенесли на наступний тиждень.", language: .uk, voice: "Lesya"),
    ]

    static func words(_ s: String) -> [String] {
        let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
        let cleaned = lowered.unicodeScalars.map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(cleaned).split(separator: " ").map(String.init)
    }

    static func wer(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var d = Array(0...h.count)
        for i in 1...r.count {
            var prev = d[0]
            d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let cur = d[j]
                d[j] = r[i - 1] == h[j - 1] ? prev : min(prev, d[j], d[j - 1]) + 1
                prev = cur
            }
        }
        return Double(d[h.count]) / Double(r.count)
    }

    static func synth(_ p: BenchPhrase, index: Int, dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("phrase-\(index).aiff")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = ["-v", p.voice, "-o", url.path, p.text]
        try proc.run()
        proc.waitUntilExit()
        return url
    }
}

@Suite(.serialized) struct BenchTests {
    @Test func wordErrorRate() {
        #expect(Bench.wer(reference: "Open Figma now.", hypothesis: "open figma now") == 0)
        #expect(Bench.wer(reference: "a b c d", hypothesis: "a x c") == 0.5)
    }

    @MainActor @Test(.enabled(if: Bench.enabled), .timeLimit(.minutes(90)))
    func engines() async throws {
        let base = Bench.out
        let audioDir = base.appendingPathComponent("audio", isDirectory: true)
        let modelsDir = base.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let recordings = try Bench.phrases.enumerated().map { i, p in try AudioFiles.load(try Bench.synth(p, index: i, dir: audioDir)) }
        defer { recordings.forEach { $0.discard() } }
        let store = ModelStore(root: modelsDir)
        let hub = EngineHub(store: store)
        let only = ProcessInfo.processInfo.environment["MURMUR_BENCH_ENGINES"].map { Set($0.split(separator: ",").map(String.init)) }
        var lines = ["engine\tdownload_s\tsize_bytes\tcold_load_s\tphrase\tlang\tlatency_s\twer\treference\thypothesis"]
        for info in ModelInfo.all where only?.contains(info.id.rawValue) ?? true {
            var downloadTime = 0.0
            if !info.builtIn {
                let t0 = Date()
                store.download(info.id)
                await store.waitUntilSettled(info.id)
                downloadTime = Date().timeIntervalSince(t0)
                guard store.isReady(info.id) else {
                    lines.append("\(info.id.rawValue)\tFAILED\t\(store.state(info.id))")
                    continue
                }
            }
            let size = { if case .ready(let b) = store.state(info.id) { return b }; return 0 }()
            let t1 = Date()
            try await hub.transcriber(info.id).prepare()
            let cold = Date().timeIntervalSince(t1)
            for (i, p) in Bench.phrases.enumerated() {
                let req = TranscriptionRequest(language: p.language, vocabulary: [], keyboardLanguages: ["en", "uk"])
                let t2 = Date()
                var text: String
                do { text = try await hub.transcribe(info.id, recordings[i], req) } catch { text = "ERROR: \(error)" }
                let latency = Date().timeIntervalSince(t2)
                let w = Bench.wer(reference: p.text, hypothesis: text)
                lines.append([info.id.rawValue, String(format: "%.1f", downloadTime), "\(size)", String(format: "%.2f", cold), "\(i + 1)",
                              p.language.rawValue, String(format: "%.3f", latency), String(format: "%.3f", w), p.text, text]
                    .joined(separator: "\t"))
            }
            hub.unload(info.id)
        }
        try lines.joined(separator: "\n").write(to: base.appendingPathComponent("bench.tsv"), atomically: true, encoding: .utf8)
    }
}
