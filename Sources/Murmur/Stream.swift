import AVFoundation
import Foundation
import os

enum Segmenter {
    static let endSilence = 0.6
    static let maxSegment = 20.0
    static let pad = 0.15
    static let minVoiced = 0.15
    static let softer = 6.0

    struct Scan: Equatable {
        var segments: [Range<Int>]
        var next: Int
    }

    static func scan(_ samples: [Float], from: Int, threshold: Double, final: Bool, rate: Double = Recording.sampleRate) -> Scan {
        let start = max(0, min(from, samples.count))
        guard start < samples.count else { return Scan(segments: [], next: start) }
        let size = max(1, Int(rate * VoiceGate.frameSeconds))
        let levels = VoiceGate.frameLevels(Array(samples[start...]), rate: rate)
        let silenceFrames = Int((endSilence / VoiceGate.frameSeconds).rounded())
        let maxFrames = Int((maxSegment / VoiceGate.frameSeconds).rounded())
        let minFrames = Int((minVoiced / VoiceGate.frameSeconds).rounded())
        let padSamples = Int(rate * pad)
        var out: [Range<Int>] = []
        var next = start
        var segStart: Int?
        var lastSpeech = -1
        var voiced = 0
        func close(through last: Int, cutAt: Int? = nil) {
            guard let s = segStart else { return }
            if voiced >= minFrames {
                let lo = max(next, start + s * size - padSamples)
                let hiFrame = cutAt ?? (last + 1)
                let hi = min(samples.count, start + hiFrame * size + (cutAt == nil ? padSamples : 0))
                if lo < hi {
                    out.append(lo..<hi)
                    next = hi
                }
            }
            segStart = nil
            voiced = 0
        }
        for i in levels.indices {
            if levels[i] >= threshold {
                if segStart == nil { segStart = i }
                lastSpeech = i
                voiced += 1
                if let s = segStart, i - s + 1 >= maxFrames { close(through: i, cutAt: i + 1) }
            } else if segStart != nil, i - lastSpeech >= silenceFrames {
                close(through: lastSpeech)
            }
        }
        if final {
            if segStart != nil { close(through: lastSpeech) }
            next = samples.count
        } else if segStart == nil {
            next = max(next, min(samples.count, start + levels.count * size - padSamples))
        }
        return Scan(segments: out, next: next)
    }

    static let keepCapital: Set<String> = ["I", "I'm", "I've", "I'll", "I'd", "OK"]

    static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            var part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = out.last, !".!?…:\n".contains(last), let first = part.first, first.isUppercase {
                let word = String(part.prefix { !$0.isWhitespace && $0 != "," })
                let restLower = word.dropFirst().allSatisfy { !$0.isUppercase }
                if restLower, !keepCapital.contains(word) { part = first.lowercased() + part.dropFirst() }
            }
            out += out.isEmpty ? part : " " + part
        }
        return out
    }
}

@MainActor
final class FinalStreamer {
    static let logger = Logger(subsystem: Identity.bundleId, category: "stream")

    struct Piece {
        var range: Range<Int>
        var task: Task<String, Error>
    }

    let threshold: Double
    let precomputeVoices: Bool
    private let transcribe: ([Float]) async throws -> String
    private let live: LiveSession?
    let cache = EmbeddingCache()
    private(set) var buffer: [Float] = []
    private(set) var pieces: [Piece] = []
    private var cursor = 0
    private var startTask: Task<Bool, Never>?

    init(threshold: Double, precomputeVoices: Bool, live: LiveSession? = nil,
         transcribe: @escaping ([Float]) async throws -> String) {
        self.threshold = threshold
        self.precomputeVoices = precomputeVoices
        self.live = live
        self.transcribe = transcribe
    }

    var usesLive: Bool { live != nil }

    func start() async {
        guard let live else { return }
        if let startTask { _ = await startTask.value; return }
        let task = Task { @MainActor () -> Bool in
            do {
                try await live.start()
                return true
            } catch {
                Self.logger.error("stream: live start failed")
                return false
            }
        }
        startTask = task
        _ = await task.value
    }

    func append(_ fresh: [Float]) {
        guard !fresh.isEmpty else { return }
        buffer += fresh
        live?.feed(fresh)
        if live == nil || precomputeVoices { advance(final: false) }
    }

    private func advance(final: Bool) {
        let result = Segmenter.scan(buffer, from: cursor, threshold: threshold - Segmenter.softer, final: final)
        cursor = result.next
        for r in result.segments { enqueue(r) }
    }

    private func enqueue(_ range: Range<Int>) {
        let slice = Array(buffer[range])
        let previous = pieces.last?.task
        let voices = precomputeVoices
        let threshold = self.threshold
        let cache = self.cache
        let run = transcribe
        let transcribes = live == nil
        let task = Task { @MainActor () -> String in
            _ = await previous?.result
            if voices { await VoiceStore.shared.precompute(slice, offset: range.lowerBound, threshold: threshold, into: cache) }
            return transcribes ? try await run(slice) : ""
        }
        pieces.append(Piece(range: range, task: task))
    }

    func finish(_ samples: [Float]) async throws -> String {
        if samples.count > buffer.count { append(Array(samples[buffer.count...])) }
        advance(final: true)
        if let live {
            let ok = await startTask?.value ?? false
            let text = ok ? ((try? await live.finish()) ?? "") : ""
            for p in pieces { _ = await p.task.result }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            Self.logger.notice("stream: live result empty, transcribing the recording")
            guard let speech = VoiceGate.trim(samples, threshold: threshold) else { return "" }
            return try await transcribe(speech)
        }
        var parts: [String] = []
        for p in pieces { parts.append(try await p.task.value) }
        return Segmenter.join(parts)
    }

    func text(for ranges: [Range<Int>]) async -> [Range<Int>: String] {
        var out: [Range<Int>: String] = [:]
        for p in pieces where ranges.contains(p.range) { out[p.range] = try? await p.task.value }
        return out
    }

    func retranscribe(dropping dropped: [Range<Int>], samples: [Float]) async throws -> String {
        guard live == nil else {
            return try await transcribe(MainVoice.assemble(samples, drop: dropped))
        }
        var parts: [String] = []
        for p in pieces {
            let local = dropped.compactMap { d -> Range<Int>? in
                let lo = max(d.lowerBound, p.range.lowerBound), hi = min(d.upperBound, p.range.upperBound)
                return lo < hi ? (lo - p.range.lowerBound)..<(hi - p.range.lowerBound) : nil
            }
            if local.isEmpty {
                parts.append(try await p.task.value)
                continue
            }
            let kept = MainVoice.assemble(Array(samples[p.range]), drop: local)
            if VoiceGate.hasSpeech(kept, threshold: threshold) { parts.append(try await transcribe(kept)) }
        }
        return Segmenter.join(parts)
    }

    func cancel() {
        live?.cancel()
        for p in pieces { p.task.cancel() }
        pieces.removeAll()
    }
}
