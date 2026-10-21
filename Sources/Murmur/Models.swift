import Combine
import CryptoKit
import Darwin
import FluidAudio
import Foundation
import WhisperKit

enum EngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case parakeetUltra = "parakeet-ultra"
    case parakeetRedux = "parakeet-redux"
    case whisperTurbo = "whisper-turbo"

    var id: String { rawValue }
}

struct ModelInfo: Identifiable, Equatable, Sendable {
    let id: EngineID
    let name: String
    let summary: String
    let languages: String
    let approxBytes: Int64
    let credit: String

    var builtIn: Bool { id == .apple }

    static let all: [ModelInfo] = [
        ModelInfo(id: .apple, name: "Apple", summary: "Built into macOS. Ready right away, nothing to download.",
                  languages: "English, Ukrainian and more", approxBytes: 0, credit: "Apple Speech framework"),
        ModelInfo(id: .parakeetUltra, name: "Parakeet Ultra", summary: "Most accurate. Fast on Apple silicon.",
                  languages: "25 European languages, incl. English and Ukrainian", approxBytes: 640_000_000,
                  credit: "NVIDIA Parakeet TDT 0.6B v3, post-trained by Moondream (CC-BY-4.0), via FluidAudio"),
        ModelInfo(id: .parakeetRedux, name: "Parakeet Redux", summary: "Smallest download, still accurate.",
                  languages: "25 European languages, incl. English and Ukrainian", approxBytes: 230_000_000,
                  credit: "NVIDIA Parakeet TDT 0.6B v3, ternary retraining by Moondream (CC-BY-4.0), via FluidAudio"),
        ModelInfo(id: .whisperTurbo, name: "Whisper Turbo", summary: "Good with mixed languages and names.",
                  languages: "About 100 languages", approxBytes: 640_000_000,
                  credit: "OpenAI Whisper large-v3-turbo (MIT), Core ML build by Argmax via WhisperKit"),
    ]

    static func info(_ id: EngineID) -> ModelInfo { all.first { $0.id == id }! }

    static var downloadable: [ModelInfo] { all.filter { !$0.builtIn } }
}

enum ModelState: Equatable, Sendable {
    case missing
    case downloading(Double)
    case ready(Int64)
    case failed(String)

    var isReady: Bool { if case .ready = self { true } else { false } }
    var isDownloading: Bool { if case .downloading = self { true } else { false } }
}

struct ModelMarker: Codable, Equatable {
    var id: String
    var bytes: Int64
    var path: String
}

enum ModelLifecycle {
    static func canStart(_ state: ModelState) -> Bool {
        switch state {
        case .missing, .failed: true
        case .downloading, .ready: false
        }
    }

    static func enoughSpace(available: Int64?, needed: Int64) -> Bool {
        guard let available else { return true }
        return available >= needed + needed / 5 + 50_000_000
    }

    static func stateAfterCancel(_ state: ModelState) -> ModelState {
        state.isDownloading ? .missing : state
    }

    static func clamp(_ p: Double) -> Double { min(1, max(0, p.isFinite ? p : 0)) }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

protocol ModelFetcher: Sendable {
    func fetch(_ id: EngineID, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

struct LibraryFetcher: ModelFetcher {
    static let whisperVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"

    static func parakeetVersion(_ id: EngineID) -> AsrModelVersion? {
        switch id {
        case .parakeetUltra: .ultra
        case .parakeetRedux: .redux
        default: nil
        }
    }

    static func parakeetFolder(_ id: EngineID, in dir: URL) -> URL? {
        guard let v = parakeetVersion(id) else { return nil }
        return dir.appendingPathComponent(AsrModels.defaultCacheDirectory(for: v).lastPathComponent, isDirectory: true)
    }

    static func layout(_ id: EngineID, in dir: URL) -> URL? {
        if let folder = parakeetFolder(id, in: dir) { return folder }
        guard id == .whisperTurbo else { return nil }
        return dir.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(whisperVariant, isDirectory: true)
    }

    static func validate(_ id: EngineID, folder: URL, root: URL) async -> Bool {
        if let version = parakeetVersion(id) {
            return (try? await AsrModels.load(from: folder, version: version)) != nil
        }
        guard id == .whisperTurbo else { return false }
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: root, verbose: false,
                                      logLevel: .error, prewarm: false, load: true, download: false)
        return (try? await WhisperKit(config)) != nil
    }

    func fetch(_ id: EngineID, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let version = Self.parakeetVersion(id), let folder = Self.parakeetFolder(id, in: dir) {
            let url = try await AsrModels.download(to: folder, version: version) { p in
                progress(ModelLifecycle.clamp(p.fractionCompleted) * 0.95)
            }
            try Task.checkCancellation()
            _ = try await AsrModels.load(from: url, version: version)
            progress(1)
            return url
        }
        if id == .whisperTurbo {
            let folder = try await WhisperKit.download(variant: Self.whisperVariant, downloadBase: dir) { p in
                progress(ModelLifecycle.clamp(p.fractionCompleted) * 0.9)
            }
            try Task.checkCancellation()
            let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: dir, verbose: false,
                                          logLevel: .error, prewarm: false, load: true, download: false)
            _ = try await WhisperKit(config)
            progress(1)
            return folder
        }
        throw CocoaError(.featureUnsupported)
    }
}

struct ReuseFirst: ModelFetcher {
    let base: ModelFetcher
    var roots: @Sendable (EngineID) -> [URL] = { ModelReuse.searchRoots($0) }
    var layout: @Sendable (EngineID, URL) -> URL? = { LibraryFetcher.layout($0, in: $1) }
    var validate: @Sendable (EngineID, URL, URL) async -> Bool = { await LibraryFetcher.validate($0, folder: $1, root: $2) }
    var expected: @Sendable (EngineID) -> [String: FileStamp]? = { _ in nil }

    func fetch(_ id: EngineID, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let target = layout(id, dir), let found = ModelReuse.find(id, roots: roots(id)),
           found.standardizedFileURL.path != target.standardizedFileURL.path {
            do {
                try ModelReuse.clone(found, to: target)
                progress(0.9)
                let prefix = ModelStore.relativePath(of: target, in: dir)
                let wanted = expected(id).map { all in
                    all.filter { $0.key.hasPrefix(prefix + "/") }.reduce(into: [String: FileStamp]()) {
                        $0[String($1.key.dropFirst(prefix.count + 1))] = $1.value
                    }
                }
                let sameFiles = wanted.map { $0.isEmpty || Checksums.matches(target, $0) } ?? true
                if sameFiles, await validate(id, target, dir) {
                    progress(1)
                    return target
                }
            } catch {}
            try? FileManager.default.removeItem(at: target)
        }
        return try await base.fetch(id, into: dir, progress: progress)
    }
}

@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var states: [EngineID: ModelState] = [:]
    @Published private(set) var library = ModelLibrary()
    let root: URL
    private let fetcher: ModelFetcher
    private var tasks: [EngineID: Task<Void, Never>] = [:]
    var onChange: (EngineID, ModelState) -> Void = { _, _ in }

    nonisolated(unsafe) static var overrideRoot: URL?

    nonisolated static var defaultRoot: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Identity.appName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    init(root: URL? = nil, fetcher: ModelFetcher? = nil) {
        let r = root ?? Self.defaultRoot
        self.root = r
        let libURL = r.appendingPathComponent(".library.json")
        self.fetcher = fetcher ?? ReuseFirst(base: LibraryFetcher(), expected: { id in
            ModelLibrary.load(libURL).entries[id.rawValue]?.files
        })
        library = ModelLibrary.load(libURL)
        refresh()
    }

    private var libraryURL: URL { root.appendingPathComponent(".library.json") }

    private func updateLibrary(_ id: EngineID, _ change: (inout LibraryEntry) -> Void) {
        var entry = library.entries[id.rawValue] ?? LibraryEntry()
        change(&entry)
        library.entries[id.rawValue] = entry
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        library.save(libraryURL)
    }

    func isOffloaded(_ id: EngineID) -> Bool {
        state(id) == .missing && library.entries[id.rawValue]?.offloaded == true
    }

    var totalBytes: Int64 { StorageAdvice.total(states) }

    func suggestions(inUse: EngineID) -> [EngineID] {
        StorageAdvice.suggest(states: states, entries: library.entries, inUse: inUse, available: Self.availableBytes(at: root))
    }

    func markUsed(_ id: EngineID) {
        guard id != .apple else { return }
        let last = library.entries[id.rawValue]?.lastUsed ?? .distantPast
        guard Date().timeIntervalSince(last) > 3600 else { return }
        updateLibrary(id) { $0.lastUsed = Date() }
    }

    func lastUsed(_ id: EngineID) -> Date? { library.entries[id.rawValue]?.lastUsed }

    func dir(_ id: EngineID) -> URL { root.appendingPathComponent(id.rawValue, isDirectory: true) }
    private func markerURL(_ id: EngineID) -> URL { dir(id).appendingPathComponent(".complete.json") }

    func state(_ id: EngineID) -> ModelState {
        if id == .apple { return .ready(0) }
        return states[id] ?? .missing
    }

    func isReady(_ id: EngineID) -> Bool { state(id).isReady }

    func marker(_ id: EngineID) -> ModelMarker? {
        guard let data = try? Data(contentsOf: markerURL(id)) else { return nil }
        return try? JSONDecoder().decode(ModelMarker.self, from: data)
    }

    func folder(_ id: EngineID) -> URL? {
        guard let m = marker(id) else { return nil }
        let url = dir(id).appendingPathComponent(m.path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func refresh() {
        library = ModelLibrary.load(libraryURL)
        for info in ModelInfo.downloadable where !(states[info.id]?.isDownloading ?? false) {
            if let m = marker(info.id), folder(info.id) != nil {
                states[info.id] = .ready(m.bytes)
            } else if case .failed = states[info.id] {
                continue
            } else {
                states[info.id] = .missing
            }
        }
    }

    private func set(_ id: EngineID, _ s: ModelState) {
        states[id] = s
        onChange(id, s)
    }

    static func availableBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func download(_ id: EngineID) {
        guard id != .apple, ModelLifecycle.canStart(state(id)) else { return }
        let info = ModelInfo.info(id)
        guard ModelLifecycle.enoughSpace(available: Self.availableBytes(at: root), needed: info.approxBytes) else {
            set(id, .failed("Not enough disk space. \(info.name) needs about \(ModelLifecycle.sizeText(info.approxBytes))."))
            return
        }
        let target = dir(id)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: markerURL(id))
        set(id, .downloading(0))
        let fetcher = self.fetcher
        tasks[id] = Task { [weak self] in
            do {
                let folder = try await fetcher.fetch(id, into: target) { p in
                    Task { @MainActor in
                        guard let self, self.state(id).isDownloading else { return }
                        self.set(id, .downloading(ModelLifecycle.clamp(p)))
                    }
                }
                try Task.checkCancellation()
                let rel = Self.relativePath(of: folder, in: target)
                let bytes = Self.size(of: target)
                let marker = ModelMarker(id: id.rawValue, bytes: bytes, path: rel)
                let data = try JSONEncoder().encode(marker)
                try data.write(to: target.appendingPathComponent(".complete.json"), options: .atomic)
                await MainActor.run {
                    guard let self, self.state(id).isDownloading else { return }
                    self.tasks[id] = nil
                    self.updateLibrary(id) { $0.downloadedAt = Date(); $0.offloaded = false }
                    self.set(id, .ready(bytes))
                }
                let stamps = await Task.detached(priority: .utility) { Checksums.stamp(target) }.value
                await MainActor.run {
                    guard let self, self.state(id).isReady else { return }
                    self.updateLibrary(id) { $0.files = stamps }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.state(id).isDownloading else { return }
                    self.tasks[id] = nil
                    if error is CancellationError || Task.isCancelled {
                        self.set(id, .missing)
                    } else {
                        self.set(id, .failed(Self.describe(error)))
                    }
                }
            }
        }
    }

    func cancel(_ id: EngineID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        set(id, ModelLifecycle.stateAfterCancel(state(id)))
    }

    func delete(_ id: EngineID) {
        freeUp(id)
    }

    func freeUp(_ id: EngineID) {
        guard id != .apple else { return }
        if state(id).isDownloading { cancel(id) }
        try? FileManager.default.removeItem(at: dir(id))
        if library.entries[id.rawValue] != nil { updateLibrary(id) { $0.offloaded = true } }
        set(id, .missing)
    }

    func deleteAll() {
        for info in ModelInfo.downloadable {
            if state(info.id).isDownloading { cancel(info.id) }
            try? FileManager.default.removeItem(at: dir(info.id))
            set(info.id, .missing)
        }
        library = ModelLibrary()
        try? FileManager.default.removeItem(at: libraryURL)
    }

    func waitUntilSettled(_ id: EngineID) async {
        while state(id).isDownloading { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    nonisolated static func relativePath(of folder: URL, in base: URL) -> String {
        let f = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let b = base.standardizedFileURL.resolvingSymlinksInPath().path
        guard f.hasPrefix(b) else { return "." }
        let rest = String(f.dropFirst(b.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rest.isEmpty ? "." : rest
    }

    nonisolated static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileAllocatedSize ?? 0) }
        }
        return total
    }

    static func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if (error as NSError).domain == NSURLErrorDomain { return "Download failed. Check your connection and try again." }
        return text.isEmpty ? "Download failed." : text
    }
}

struct LibraryEntry: Codable, Equatable {
    var downloadedAt: Date?
    var lastUsed: Date?
    var offloaded = false
    var files: [String: FileStamp]?
}

struct FileStamp: Codable, Equatable {
    var size: Int64
    var sha256: String
}

struct ModelLibrary: Codable, Equatable {
    var entries: [String: LibraryEntry] = [:]

    static func load(_ url: URL) -> ModelLibrary {
        guard let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder.iso.decode(ModelLibrary.self, from: data) else { return ModelLibrary() }
        return lib
    }

    func save(_ url: URL) {
        guard let data = try? JSONEncoder.iso.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

enum StorageAdvice {
    static let lowSpace: Int64 = 5_000_000_000
    static let unusedDays: Double = 30

    static func suggest(states: [EngineID: ModelState], entries: [String: LibraryEntry], inUse: EngineID,
                        available: Int64?, now: Date = Date()) -> [EngineID] {
        guard let available, available < lowSpace else { return [] }
        return ModelInfo.downloadable.map(\.id).filter { id in
            guard id != inUse, states[id]?.isReady == true else { return false }
            let e = entries[id.rawValue]
            let last = e?.lastUsed ?? e?.downloadedAt ?? .distantPast
            return now.timeIntervalSince(last) > unusedDays * 86_400
        }
    }

    static func total(_ states: [EngineID: ModelState]) -> Int64 {
        states.values.reduce(0) { sum, s in
            if case .ready(let b) = s { return sum + b }
            return sum
        }
    }
}

enum ModelReuse {
    static func required(_ id: EngineID) -> [String] {
        switch id {
        case .parakeetUltra, .parakeetRedux:
            ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_v3_vocab.json"]
        case .whisperTurbo:
            ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        case .apple:
            []
        }
    }

    static func hubRepo(_ id: EngineID) -> String? {
        switch id {
        case .parakeetUltra: "models--FluidInference--parakeet-ultra-coreml"
        case .parakeetRedux: "models--FluidInference--parakeet-redux-coreml"
        case .whisperTurbo: "models--argmaxinc--whisperkit-coreml"
        case .apple: nil
        }
    }

    static func searchRoots(_ id: EngineID, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> [URL] {
        var out: [URL] = []
        if let v = LibraryFetcher.parakeetVersion(id) {
            out.append(appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
                .appendingPathComponent(AsrModels.defaultCacheDirectory(for: v).lastPathComponent, isDirectory: true))
        }
        if let repo = hubRepo(id) {
            let snapshots = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
                .appendingPathComponent(repo, isDirectory: true).appendingPathComponent("snapshots", isDirectory: true)
            let revs = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
            for rev in revs {
                out.append(id == .whisperTurbo ? rev.appendingPathComponent(LibraryFetcher.whisperVariant, isDirectory: true) : rev)
            }
        }
        return out
    }

    static func isComplete(_ folder: URL, for id: EngineID) -> Bool {
        let fm = FileManager.default
        let names = required(id)
        guard !names.isEmpty else { return false }
        return names.allSatisfy { name in
            let url = folder.appendingPathComponent(name).resolvingSymlinksInPath()
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &dir) else { return false }
            if dir.boolValue {
                return fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").resolvingSymlinksInPath().path)
            }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return size > 0
        }
    }

    static func find(_ id: EngineID, roots: [URL]) -> URL? {
        roots.first { isComplete($0, for: id) }
    }

    static func clone(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let base = source.standardizedFileURL
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for case let url as URL in e {
            let rel = String(url.standardizedFileURL.path.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty, !rel.hasPrefix(".") else { continue }
            let resolved = url.resolvingSymlinksInPath()
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &dir) else { continue }
            let target = destination.appendingPathComponent(rel)
            if dir.boolValue {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    try clone(resolved, to: target)
                    e.skipDescendants()
                }
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if clonefile(resolved.path, target.path, 0) != 0 {
                try fm.copyItem(at: resolved, to: target)
            }
        }
    }
}

enum Checksums {
    static func stamp(_ dir: URL) -> [String: FileStamp] {
        let base = dir.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [:] }
        var out: [String: FileStamp] = [:]
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.hasPrefix("."), !rel.contains("/.") else { continue }
            guard let sha = sha256(url) else { continue }
            out[rel] = FileStamp(size: Int64(v?.fileSize ?? 0), sha256: sha)
        }
        return out
    }

    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ dir: URL, _ expected: [String: FileStamp]) -> Bool {
        !expected.isEmpty && stamp(dir) == expected
    }
}

enum PackPolicy {
    static let threshold = 0.2

    static let measuredAPFSSavings: [EngineID: Double] = [.parakeetUltra: 0.016, .parakeetRedux: 0.020, .whisperTurbo: 0.012]

    static func shouldPack(savedFraction: Double) -> Bool { savedFraction > threshold }

    static func packs(_ id: EngineID) -> Bool { shouldPack(savedFraction: measuredAPFSSavings[id] ?? 0) }
}
