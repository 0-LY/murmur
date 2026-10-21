import FluidAudio
import Foundation
import os

enum MainVoice {
    static let approxBytes: Int64 = 17_000_000
    static let minVoiced = 2.0
    static let pieceSeconds = 1.5
    static let minPieceSeconds = 0.6
    static let mergeGapSeconds = 0.3
    static let padSeconds = 0.1
    static let similarity: Float = MainVoiceSensitivity.low.similarity
    static let quieterDb: Double = MainVoiceSensitivity.low.quieterDb
    static let maxDropShare = 0.4

    struct Piece: Equatable {
        var range: Range<Int>
        var voiced: Double
        var loudness: Double
    }

    struct Report: Equatable {
        var pieces = 0
        var clusters = 1
        var kept = 0
        var dropped = 0
        var reason = ""
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return dot / max((na.squareRoot() * nb.squareRoot()), 1e-9)
    }

    static func runs(_ levels: [Double], threshold: Double) -> [Range<Int>] {
        let gap = Int((mergeGapSeconds / VoiceGate.frameSeconds).rounded())
        var out: [Range<Int>] = []
        var start: Int?
        var lastVoiced = -1
        for i in levels.indices where levels[i] >= threshold {
            if let s = start, i - lastVoiced - 1 <= gap {
                start = s
            } else {
                if let s = start { out.append(s..<(lastVoiced + 1)) }
                start = i
            }
            lastVoiced = i
        }
        if let s = start { out.append(s..<(lastVoiced + 1)) }
        return out
    }

    static func split(_ run: Range<Int>) -> [Range<Int>] {
        let maxFrames = Int((pieceSeconds / VoiceGate.frameSeconds).rounded())
        guard run.count > maxFrames else { return [run] }
        let parts = Int((Double(run.count) / Double(maxFrames)).rounded(.up))
        let size = Int((Double(run.count) / Double(parts)).rounded(.up))
        return stride(from: run.lowerBound, to: run.upperBound, by: size).map { $0..<min(run.upperBound, $0 + size) }
    }

    static func pieces(_ samples: [Float], threshold: Double, rate: Double = Recording.sampleRate) -> [Piece] {
        let levels = VoiceGate.frameLevels(samples, rate: rate)
        let size = max(1, Int(rate * VoiceGate.frameSeconds))
        let pad = Int(rate * padSeconds)
        var out: [Piece] = []
        for run in runs(levels, threshold: threshold) {
            for part in split(run) {
                let voicedFrames = part.filter { levels[$0] >= threshold }
                guard !voicedFrames.isEmpty else { continue }
                let lo = max(0, part.lowerBound * size - pad)
                let hi = min(samples.count, part.upperBound * size + pad)
                guard lo < hi else { continue }
                let power = voicedFrames.map { pow(10, levels[$0] / 10) }.reduce(0, +) / Double(voicedFrames.count)
                out.append(Piece(range: lo..<hi, voiced: Double(voicedFrames.count) * VoiceGate.frameSeconds,
                                 loudness: power.squareRoot()))
            }
        }
        return out
    }

    static func cluster(_ embeddings: [[Float]], threshold: Float = similarity) -> [Int] {
        var groups: [[Int]] = embeddings.indices.map { [$0] }
        func link(_ a: [Int], _ b: [Int]) -> Float {
            var total: Float = 0
            for i in a { for j in b { total += cosine(embeddings[i], embeddings[j]) } }
            return total / Float(a.count * b.count)
        }
        while groups.count > 1 {
            var best: (Int, Int, Float) = (0, 0, -2)
            for i in groups.indices {
                for j in groups.indices where j > i {
                    let s = link(groups[i], groups[j])
                    if s > best.2 { best = (i, j, s) }
                }
            }
            guard best.2 >= threshold else { break }
            groups[best.0] += groups[best.1]
            groups.remove(at: best.1)
        }
        var labels = [Int](repeating: 0, count: embeddings.count)
        for (g, members) in groups.enumerated() { for m in members { labels[m] = g } }
        return labels
    }

    static func assign(labels: [Int?], pieces: [Piece]) -> [Int] {
        let known = labels.indices.compactMap { i in labels[i].map { (i, $0) } }
        return labels.indices.map { i in
            if let l = labels[i] { return l }
            let nearest = known.min { a, b in
                distance(pieces[a.0].range, pieces[i].range) < distance(pieces[b.0].range, pieces[i].range)
            }
            return nearest?.1 ?? 0
        }
    }

    private static func distance(_ a: Range<Int>, _ b: Range<Int>) -> Int {
        if a.overlaps(b) { return 0 }
        return a.upperBound <= b.lowerBound ? b.lowerBound - a.upperBound : a.lowerBound - b.upperBound
    }

    static func dominant(labels: [Int], pieces: [Piece]) -> Int {
        var score: [Int: Double] = [:]
        for (i, l) in labels.enumerated() { score[l, default: 0] += pieces[i].voiced * pieces[i].loudness }
        return score.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? 0
    }

    static func assemble(_ samples: [Float], drop: [Range<Int>]) -> [Float] {
        guard !drop.isEmpty else { return samples }
        var keep = [Bool](repeating: true, count: samples.count)
        for r in drop { for i in r where i < keep.count { keep[i] = false } }
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        for i in samples.indices where keep[i] { out.append(samples[i]) }
        return out
    }

    struct Outcome {
        var samples: [Float]
        var report: Report
        var dropped: [Range<Int>]
    }

    static func keptMask(count: Int, dropped: [Range<Int>]) -> [Bool] {
        var keep = [Bool](repeating: true, count: count)
        for r in dropped { for i in r where i < count { keep[i] = false } }
        return keep
    }

    static func decibels(_ loudness: Double) -> Double { 20 * log10(max(loudness, 1e-9)) }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -160 }
        let v = values.sorted()
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { for i in v.indices { sum[i] += v[i] } }
        return sum.map { $0 / Float(vectors.count) }
    }

    static func shouldDrop(label: Int, main: Int, vector: [Float]?, centroid: [Float], decibels: Double,
                           mainMedian: Double, similarity: Float, quieterDb: Double) -> Bool {
        guard label != main, let vector else { return false }
        guard decibels <= mainMedian - quieterDb else { return false }
        return cosine(vector, centroid) < similarity
    }

    static func capped(dropVoiced: Double, totalVoiced: Double, share: Double = maxDropShare) -> Bool {
        totalVoiced > 0 && dropVoiced / totalVoiced > share
    }

    static func run(_ samples: [Float], threshold: Double, similarity: Float = similarity, quieterDb: Double = quieterDb,
                    embedPiece: (Int, Range<Int>) async throws -> [Float]) async -> Outcome {
        let ps = pieces(samples, threshold: threshold)
        var report = Report(pieces: ps.count)
        let voiced = ps.map(\.voiced).reduce(0, +)
        guard voiced >= minVoiced else { report.reason = "under 2 s of speech"; return Outcome(samples: samples, report: report, dropped: []) }
        let minSamples = Int(minPieceSeconds * Recording.sampleRate)
        var vectors: [[Float]] = []
        var slot: [Int?] = []
        for (i, p) in ps.enumerated() {
            guard p.range.count >= minSamples, let v = try? await embedPiece(i, p.range), VoiceEmbedding.valid(v) else {
                slot.append(nil)
                continue
            }
            slot.append(vectors.count)
            vectors.append(v)
        }
        guard vectors.count >= 2 else { report.reason = "too few pieces"; return Outcome(samples: samples, report: report, dropped: []) }
        let base = cluster(vectors, threshold: similarity)
        report.clusters = Set(base).count
        guard report.clusters > 1 else {
            report.reason = "one voice"
            report.kept = ps.count
            return Outcome(samples: samples, report: report, dropped: [])
        }
        let labels = assign(labels: slot.map { $0.map { base[$0] } }, pieces: ps)
        let main = dominant(labels: labels, pieces: ps)
        let mainIdx = ps.indices.filter { labels[$0] == main }
        let mainMedian = median(mainIdx.map { decibels(ps[$0].loudness) })
        let center = centroid(mainIdx.compactMap { slot[$0].map { vectors[$0] } })
        let dropIdx = ps.indices.filter { i in
            shouldDrop(label: labels[i], main: main, vector: slot[i].map { vectors[$0] }, centroid: center,
                       decibels: decibels(ps[i].loudness), mainMedian: mainMedian,
                       similarity: similarity, quieterDb: quieterDb)
        }
        if capped(dropVoiced: dropIdx.map { ps[$0].voiced }.reduce(0, +), totalVoiced: voiced) {
            report.reason = "would drop too much"
            report.kept = ps.count
            return Outcome(samples: samples, report: report, dropped: [])
        }
        guard !dropIdx.isEmpty else {
            report.reason = "other voices too close or loud"
            report.kept = ps.count
            return Outcome(samples: samples, report: report, dropped: [])
        }
        let drop = dropIdx.map { ps[$0].range }
        report.kept = ps.count - drop.count
        report.dropped = drop.count
        report.reason = "kept main voice"
        return Outcome(samples: assemble(samples, drop: drop), report: report, dropped: drop)
    }

    static func focus(_ samples: [Float], threshold: Double, sensitivity: MainVoiceSensitivity = .low,
                      embed: (Range<Int>, [Float]) async throws -> [Float]) async -> (samples: [Float], report: Report) {
        let o = await run(samples, threshold: threshold, similarity: sensitivity.similarity, quieterDb: sensitivity.quieterDb) { _, r in
            try await embed(r, Array(samples[r]))
        }
        return (o.samples, o.report)
    }

    static func focus(_ samples: [Float], threshold: Double, sensitivity: MainVoiceSensitivity = .low,
                      embed: ([Float]) async throws -> [Float]) async -> (samples: [Float], report: Report) {
        await focus(samples, threshold: threshold, sensitivity: sensitivity) { (_: Range<Int>, piece: [Float]) in try await embed(piece) }
    }

    static func focusForBench(_ samples: [Float], threshold: Double, similarity: Float, quieterDb: Double = quieterDb,
                              vector: (Int) async throws -> [Float]) async -> Outcome {
        await run(samples, threshold: threshold, similarity: similarity, quieterDb: quieterDb) { i, _ in try await vector(i) }
    }
}

enum VoiceError: Error, Equatable {
    case downloadFailed
    case incomplete
    case loadFailed
    case badEmbedding
    case tooShort
    case saveFailed

    var message: String {
        switch self {
        case .downloadFailed: return "Couldn't download the voice model — check your connection and try again."
        case .incomplete: return "The voice model didn't download completely — try again."
        case .loadFailed: return "Couldn't open the voice model — try again; it will be downloaded fresh."
        case .badEmbedding: return "Couldn't tell the voices apart in that recording."
        case .tooShort: return "Not enough speech to tell voices apart."
        case .saveFailed: return "Couldn't save the voice model — check free disk space."
        }
    }

    static func from(_ error: Error) -> VoiceError {
        if let v = error as? VoiceError { return v }
        if error is URLError { return .downloadFailed }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .downloadFailed }
        return .loadFailed
    }
}

enum VoiceModelFiles {
    static let required = [ModelNames.CampPlus.preprocessorFile, ModelNames.CampPlus.modelFile]

    static func complete(at dir: URL) -> Bool {
        let fm = FileManager.default
        return required.allSatisfy { name in
            let m = dir.appendingPathComponent(name, isDirectory: true)
            let core = m.appendingPathComponent("coremldata.bin")
            guard fm.fileExists(atPath: core.path), size(core) > 0 else { return false }
            let mil = m.appendingPathComponent("model.mil")
            if fm.fileExists(atPath: mil.path) { return size(mil) > 0 }
            let items = (try? fm.contentsOfDirectory(atPath: m.path)) ?? []
            return items.contains { $0.hasPrefix("model") && $0 != "model.mil" }
        }
    }

    static func present(at dir: URL) -> Bool {
        required.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

enum VoiceEmbedding {
    static let dimension = 192

    static func valid(_ v: [Float]) -> Bool {
        guard v.count == dimension, v.allSatisfy({ $0.isFinite }) else { return false }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0.5
    }
}

final class EmbeddingCache: @unchecked Sendable {
    static let tolerance = Int(Recording.sampleRate * 0.12)
    private var entries: [(Range<Int>, [Float])] = []
    private let lock = NSLock()

    func store(_ v: [Float], for range: Range<Int>) {
        lock.lock(); defer { lock.unlock() }
        entries.append((range, v))
    }

    func vector(for range: Range<Int>) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { abs($0.0.lowerBound - range.lowerBound) <= Self.tolerance && abs($0.0.upperBound - range.upperBound) <= Self.tolerance }?.1
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

@MainActor
final class VoiceStore: ObservableObject {
    static let shared = VoiceStore()
    static let logger = Logger(subsystem: Identity.bundleId, category: "voice")

    enum ModelState: Equatable { case missing, downloading, ready, failed(String) }

    @Published private(set) var model: ModelState = .missing
    @Published private(set) var modelBytes: Int64 = 0
    @Published private(set) var downloadFraction: Double = 0

    nonisolated(unsafe) static var overrideRoot: URL?
    private var embedder: CampPlusEmbedder?
    private var downloadTask: Task<Bool, Never>?

    static var root: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Identity.appName, isDirectory: true).appendingPathComponent("Voice", isDirectory: true)
    }

    static var modelDir: URL { root.appendingPathComponent(Repo.campPlus.folderName, isDirectory: true) }
    static var legacyPrintURL: URL { root.appendingPathComponent("voice.json") }

    init() { refresh() }

    static func removeLegacyVoicePrint(fm: FileManager = .default) {
        if fm.fileExists(atPath: legacyPrintURL.path) { try? fm.removeItem(at: legacyPrintURL) }
    }

    func refresh() {
        if VoiceModelFiles.complete(at: Self.modelDir) {
            if model != .downloading { model = .ready }
            modelBytes = Self.size(of: Self.modelDir)
        } else if model == .ready {
            model = .missing
        }
    }

    var ready: Bool { model == .ready }

    func downloadModel() async -> Bool {
        do {
            try await ensureModel()
            return true
        } catch {
            return false
        }
    }

    func ensureModel() async throws {
        if VoiceModelFiles.complete(at: Self.modelDir) {
            model = .ready
            modelBytes = Self.size(of: Self.modelDir)
            return
        }
        if let downloadTask {
            if await downloadTask.value { return }
            throw lastError ?? .downloadFailed
        }
        let task = Task<Bool, Never> { @MainActor in
            do {
                try await self.fetch()
                return true
            } catch {
                self.lastError = VoiceError.from(error)
                return false
            }
        }
        downloadTask = task
        let ok = await task.value
        downloadTask = nil
        if !ok { throw lastError ?? .downloadFailed }
    }

    private var lastError: VoiceError?

    private func fetch() async throws {
        let fm = FileManager.default
        model = .downloading
        downloadFraction = 0
        lastError = nil
        Self.logger.notice("voice model: complete=false present=\(VoiceModelFiles.present(at: Self.modelDir), privacy: .public) downloading")
        do {
            try Self.lock(Self.root)
            let staging = Self.root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            try await ModelHub.download(.campPlus, to: staging) { [weak self] p in
                Task { @MainActor in self?.downloadFraction = p.fractionCompleted }
            }
            let fetched = staging.appendingPathComponent(Repo.campPlus.folderName, isDirectory: true)
            guard VoiceModelFiles.complete(at: fetched) else {
                Self.logger.error("voice model: download incomplete")
                throw VoiceError.incomplete
            }
            if fm.fileExists(atPath: Self.modelDir.path) { try fm.removeItem(at: Self.modelDir) }
            try fm.moveItem(at: fetched, to: Self.modelDir)
            embedder = nil
            model = .ready
            downloadFraction = 1
            modelBytes = Self.size(of: Self.modelDir)
            Self.logger.notice("voice model: ready \(self.modelBytes, privacy: .public) bytes")
        } catch {
            let v = VoiceError.from(error)
            Self.logger.error("voice model: download failed \(String(describing: v), privacy: .public) \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            model = .failed(v.message)
            throw v
        }
    }

    private func loadEmbedder() throws -> CampPlusEmbedder {
        if let embedder { return embedder }
        do {
            let e = CampPlusEmbedder(models: try CampPlusModels.load(from: Self.modelDir))
            embedder = e
            Self.logger.notice("voice model: loaded")
            return e
        } catch {
            Self.logger.error("voice model: load failed \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            throw VoiceError.loadFailed
        }
    }

    func embed(_ samples: [Float]) async throws -> [Float] {
        let e: CampPlusEmbedder
        do {
            e = try loadEmbedder()
        } catch {
            try? FileManager.default.removeItem(at: Self.modelDir)
            model = .missing
            try await ensureModel()
            e = try loadEmbedder()
        }
        do {
            return try await e.embed(audio: samples)
        } catch {
            Self.logger.error("voice embedding: failed \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) samples \(samples.count, privacy: .public)")
            throw VoiceError.badEmbedding
        }
    }

    nonisolated(unsafe) static var lastReport = MainVoice.Report()

    func precompute(_ samples: [Float], offset: Int, threshold: Double, into cache: EmbeddingCache) async {
        guard ready else { return }
        let minSamples = Int(MainVoice.minPieceSeconds * Recording.sampleRate)
        for p in MainVoice.pieces(samples, threshold: threshold) where p.range.count >= minSamples {
            let key = (p.range.lowerBound + offset)..<(p.range.upperBound + offset)
            guard cache.vector(for: key) == nil else { continue }
            if let v = try? await embed(Array(samples[p.range])), VoiceEmbedding.valid(v) { cache.store(v, for: key) }
        }
    }

    func outcome(_ samples: [Float], cfg: Config, cache: EmbeddingCache? = nil) async -> MainVoice.Outcome? {
        guard cfg.mainVoice else { return nil }
        guard ready else {
            if model != .downloading { Task { @MainActor in _ = await self.downloadModel() } }
            Self.logger.notice("main voice: model not ready, keeping all")
            return nil
        }
        let s = cfg.mainVoiceSensitivity
        let o = await MainVoice.run(samples, threshold: cfg.speechThreshold, similarity: s.similarity, quieterDb: s.quieterDb) { _, r in
            if let v = cache?.vector(for: r) { return v }
            return try await self.embed(Array(samples[r]))
        }
        Self.lastReport = o.report
        Self.logger.notice("main voice: \(o.report.reason, privacy: .public) pieces \(o.report.pieces, privacy: .public) clusters \(o.report.clusters, privacy: .public) dropped \(o.report.dropped, privacy: .public) sensitivity \(s.rawValue, privacy: .public)")
        return o
    }

    func focus(_ samples: [Float], cfg: Config) async -> [Float] {
        await outcome(samples, cfg: cfg)?.samples ?? samples
    }

    private static func lock(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
