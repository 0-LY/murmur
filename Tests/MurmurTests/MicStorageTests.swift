import AppKit
import Compression
import CoreAudio
import Foundation
import Testing
@testable import Murmur

enum Synth {
    static let rate = Recording.sampleRate

    static func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(rate * seconds)) }

    static func noise(_ seconds: Double, amp: Float, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<Int(rate * seconds)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(Double(state >> 11) / Double(1 << 53))
            return (u * 2 - 1) * amp
        }
    }

    static func tone(_ seconds: Double, amp: Float, hz: Double = 220) -> [Float] {
        (0..<Int(rate * seconds)).map { i in
            let t = Double(i) / rate
            let env = Float(min(1, min(t, seconds - t) * 20))
            return Float(sin(2 * .pi * hz * t)) * amp * env
        }
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        (0..<max(a.count, b.count)).map { i in (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0) }
    }

    static func speech(amp: Float, floor: Float = 0.0003, lead: Double = 0.6, talk: Double = 1.2, tail: Double = 0.6) -> [Float] {
        let body = silence(lead) + tone(talk, amp: amp) + silence(tail)
        return mix(body, noise(lead + talk + tail, amp: floor))
    }
}

@Suite struct VoiceGateTests {
    @Test func trimDropsSilenceAndKeepsPadding() {
        let s = Synth.speech(amp: 0.2)
        let trimmed = VoiceGate.trim(s, threshold: -45)
        #expect(trimmed != nil)
        let seconds = Double(trimmed!.count) / Synth.rate
        #expect(seconds > 1.2 && seconds < 1.75)
    }

    @Test func noSpeechReturnsNil() {
        #expect(VoiceGate.trim(Synth.noise(1.5, amp: 0.0005), threshold: -45) == nil)
        #expect(!VoiceGate.hasSpeech(Synth.noise(1.5, amp: 0.0005), threshold: -45))
        #expect(VoiceGate.hasSpeech(Synth.speech(amp: 0.2), threshold: -45))
    }

    @Test func gateFollowsThreshold() {
        let quiet = Synth.speech(amp: 0.004)
        #expect(VoiceGate.trim(quiet, threshold: -30) == nil)
        #expect(VoiceGate.trim(quiet, threshold: -58) != nil)
    }

    @Test func silentInputDetected() {
        #expect(VoiceGate.isSilentInput(Synth.silence(1)))
        #expect(VoiceGate.isSilentInput([]))
        #expect(!VoiceGate.isSilentInput(Synth.noise(1, amp: 0.001)))
    }

    @Test func noiseFloorAndSuggestion() {
        let floor = VoiceGate.noiseFloor(Synth.noise(3, amp: 0.003))
        #expect(floor > -60 && floor < -45)
        let s = VoiceGate.suggestedThreshold(noiseFloor: floor)
        #expect(s == (floor + 12).rounded() || s == VoiceGate.thresholdRange.lowerBound)
        #expect(VoiceGate.suggestedThreshold(noiseFloor: -100) == VoiceGate.thresholdRange.lowerBound)
        #expect(VoiceGate.suggestedThreshold(noiseFloor: 0) == VoiceGate.thresholdRange.upperBound)
    }

    @Test func sensitivityRoundTrip() {
        for db in stride(from: -60.0, through: -25.0, by: 5) {
            #expect(VoiceGate.threshold(forSensitivity: VoiceGate.sensitivity(forThreshold: db)) == db)
        }
        #expect(VoiceGate.sensitivity(forThreshold: -60) == 1)
        #expect(VoiceGate.sensitivity(forThreshold: -25) == 0)
        #expect(VoiceGate.clampThreshold(.nan) == VoiceGate.defaultThreshold)
    }

    @Test func peaksForWaveform() {
        let p = VoiceGate.peaks(Synth.speech(amp: 0.5), bars: 64)
        #expect(p.count == 64)
        #expect(p.max()! > 0.4 && p.first! < 0.05)
        #expect(VoiceGate.peaks([], bars: 8) == Array(repeating: 0, count: 8))
    }
}

@Suite struct MicQualityTests {
    @Test func normalSpeechIsGood() {
        #expect(MicQuality.rate(Synth.speech(amp: 0.2), threshold: -45) == .good)
    }

    @Test func quietSpeech() {
        #expect(MicQuality.rate(Synth.speech(amp: 0.012, floor: 0.0001), threshold: -50) == .tooQuiet)
    }

    @Test func noisyRoom() {
        let s = Synth.mix(Synth.speech(amp: 0.08), Synth.noise(2.4, amp: 0.05, seed: 3))
        #expect(MicQuality.rate(s, threshold: -45) == .tooNoisy)
    }

    @Test func clipping() {
        let s = Synth.speech(amp: 1.4).map { max(-1, min(1, $0)) }
        #expect(MicQuality.rate(s, threshold: -45) == .clipping)
    }

    @Test func silenceAndNoSpeech() {
        #expect(MicQuality.rate(Synth.silence(2), threshold: -45) == .silent)
        #expect(MicQuality.rate(Synth.noise(2, amp: 0.0004), threshold: -45) == .noSpeech)
    }

    @Test func everyRatingHasTip() {
        for q in [MicQuality.good, .tooQuiet, .tooNoisy, .clipping, .noSpeech, .silent] {
            #expect(!q.title.isEmpty && !q.tip.isEmpty)
        }
    }
}

@Suite struct DictationPrepareTests {
    @Test func outcomes() {
        #expect(DictationRules.prepare(Synth.speech(amp: 0.2), duration: 0.1, threshold: -45) == .tooShort)
        #expect(DictationRules.prepare(Synth.silence(2), duration: 2, threshold: -45) == .micOff)
        #expect(DictationRules.prepare(Synth.noise(2, amp: 0.0004), duration: 2, threshold: -45) == .noSpeech)
        let input = Synth.speech(amp: 0.2, lead: 1.5, tail: 1.5)
        guard case .transcribe(let out) = DictationRules.prepare(input, duration: 4.2, threshold: -45) else {
            Issue.record("expected speech")
            return
        }
        #expect(out.count < input.count / 2)
    }
}

@Suite @MainActor struct MicInputTests {
    final class FakeAudio {
        var current: AudioDeviceID? = 10
        var names: [AudioDeviceID: String] = [10: "MacBook Microphone", 11: "AirPods"]
        var notify: () -> Void = {}
    }

    @Test func followsTheSystemDefaultInput() {
        let fake = FakeAudio()
        let input = MicInput(defaultID: { fake.current }, nameOf: { $0.flatMap { fake.names[$0] } },
                             observe: { fake.notify = $0 })
        var changes = 0
        input.onChange = { changes += 1 }
        input.start()
        #expect(input.displayName == "MacBook Microphone")
        fake.current = 11
        fake.notify()
        #expect(input.displayName == "AirPods")
        #expect(input.device == 11)
        #expect(changes == 1)
        fake.notify()
        #expect(changes == 1)
        fake.current = nil
        fake.notify()
        #expect(input.displayName == "No microphone")
        #expect(changes == 2)
    }

    @Test func recorderRebuildsWhenTheDefaultInputChanges() {
        let r = Recorder()
        var dev: AudioDeviceID? = 10
        r.defaultInput = { dev }
        let before = r.currentKey
        #expect(RecorderPlan.decide(current: before, wanted: r.currentKey, running: true) == .reuseRunning)
        dev = 11
        #expect(RecorderPlan.decide(current: before, wanted: r.currentKey, running: true) == .rebuild)
    }

    @Test func settingsHaveNoDeviceOrVoiceProcessingFields() throws {
        let json = String(data: try JSONEncoder().encode(Config()), encoding: .utf8) ?? ""
        for key in ["micUID", "autoSwitchMic", "voiceFocus"] { #expect(!json.contains(key)) }
        let old = #"{"micUID":"usb","autoSwitchMic":true,"voiceFocus":true,"volume":4}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: old)
        #expect(c.volume == 4)
        let saved = String(data: try JSONEncoder().encode(c), encoding: .utf8) ?? ""
        #expect(!saved.contains("voiceFocus") && !saved.contains("micUID"))
    }

    @Test func soundSettingsLinkPointsAtSound() {
        #expect(MacMic.soundInputURL.absoluteString.contains("com.apple.Sound-Settings.extension"))
    }
}

@Suite struct HUDLogicTests {
    @Test func previewLoops() {
        #expect(HUDPreviewPlan.phase(at: 0.5) == .listening)
        #expect(HUDPreviewPlan.phase(at: HUDPreviewPlan.listen + 0.2) == .working)
        #expect(HUDPreviewPlan.phase(at: HUDPreviewPlan.listen + HUDPreviewPlan.write + 0.2) == .done("Done"))
        #expect(HUDPreviewPlan.phase(at: HUDPreviewPlan.period + 0.5) == .listening)
        #expect(HUDPreviewPlan.level(at: HUDPreviewPlan.listen + 0.5) == 0)
        let levels = stride(from: 0.0, to: HUDPreviewPlan.listen, by: 0.05).map { HUDPreviewPlan.level(at: $0) }
        #expect(levels.allSatisfy { $0 >= 0 && $0 <= 1 } && levels.max()! > 0.6)
    }

    @Test func scales() {
        #expect(HUD.scale(for: "off") == nil)
        #expect(HUD.scale(for: "small")! < HUD.scale(for: "medium")!)
        #expect(HUD.scale(for: "large")! > HUD.scale(for: "medium")!)
    }

    @Test func placement() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 200, height: 60)
        let field = CGRect(x: 400, y: 300, width: 300, height: 20)
        let above = HUDPlacement.origin(size: size, anchor: field, mouse: .zero, screens: [screen])
        #expect(above.y == field.maxY + 2 && above.x == field.minX - 6)
        let top = CGRect(x: 400, y: 860, width: 300, height: 20)
        #expect(HUDPlacement.origin(size: size, anchor: top, mouse: .zero, screens: [screen]).y < top.minY)
        let mouse = HUDPlacement.origin(size: size, anchor: nil, mouse: NSPoint(x: 700, y: 400), screens: [screen])
        #expect(mouse == NSPoint(x: 600, y: 416))
        let edge = HUDPlacement.origin(size: size, anchor: nil, mouse: NSPoint(x: 5, y: 5), screens: [screen])
        #expect(edge.x >= 4 && edge.y >= 4)
    }

    @Test func configDefaultsAndValidation() throws {
        let d = Config()
        #expect(d.hudSize == "medium")
        #expect(d.speechThreshold == VoiceGate.defaultThreshold)
        let bad = #"{"hudSize":"huge","orb":"nope","speechThreshold":12}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: bad)
        #expect(c.hudSize == "medium" && c.speechThreshold == VoiceGate.thresholdRange.upperBound)
        let off = try JSONDecoder().decode(Config.self, from: #"{"hudSize":"off"}"#.data(using: .utf8)!)
        #expect(off.hudSize == "off")
    }
}

func fakeModel(_ id: EngineID, at folder: URL, payload: String = "weights") throws {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ModelReuse.required(id) {
        let url = folder.appendingPathComponent(name)
        if name.hasSuffix(".mlmodelc") {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data((payload + name).utf8).write(to: url.appendingPathComponent("coremldata.bin"))
            try Data(repeating: 7, count: 4096).write(to: url.appendingPathComponent("weight.bin"))
        } else {
            try Data((payload + name).utf8).write(to: url)
        }
    }
}

struct CountingFetcher: ModelFetcher {
    let inner: FileFetcher
    let calls: CallBox

    func fetch(_ id: EngineID, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        calls.bump()
        return try await inner.fetch(id, into: dir, progress: progress)
    }
}

final class CallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

func inode(_ url: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64) ?? 0
}

@MainActor @Suite(.serialized) struct StorageTests {
    @Test func freeUpKeepsEntryAndDeleteAllForgets() async throws {
        let base = try scratch("free")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = try source(bytes: 200_000, in: base)
        let root = base.appendingPathComponent("models")
        let store = ModelStore(root: root, fetcher: FileFetcher(source: src))
        store.download(.parakeetRedux)
        await store.waitUntilSettled(.parakeetRedux)
        #expect(store.isReady(.parakeetRedux))
        #expect(store.totalBytes > 0)
        #expect(store.library.entries["parakeet-redux"]?.downloadedAt != nil)
        store.markUsed(.parakeetRedux)
        #expect(store.lastUsed(.parakeetRedux) != nil)
        store.freeUp(.parakeetRedux)
        #expect(store.state(.parakeetRedux) == .missing)
        #expect(store.isOffloaded(.parakeetRedux))
        #expect(!FileManager.default.fileExists(atPath: store.dir(.parakeetRedux).path))
        let reloaded = ModelStore(root: root, fetcher: FileFetcher(source: src))
        #expect(reloaded.isOffloaded(.parakeetRedux))
        reloaded.download(.parakeetRedux)
        await reloaded.waitUntilSettled(.parakeetRedux)
        #expect(reloaded.isReady(.parakeetRedux) && !reloaded.isOffloaded(.parakeetRedux))
        reloaded.deleteAll()
        #expect(reloaded.state(.parakeetRedux) == .missing && !reloaded.isOffloaded(.parakeetRedux))
        #expect(reloaded.totalBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".library.json").path))
    }

    @Test func checksumsRecordedAfterDownload() async throws {
        let base = try scratch("sum")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = try source(bytes: 150_000, in: base)
        let store = ModelStore(root: base.appendingPathComponent("models"), fetcher: FileFetcher(source: src))
        store.download(.parakeetUltra)
        await store.waitUntilSettled(.parakeetUltra)
        var files: [String: FileStamp]?
        for _ in 0..<100 {
            files = store.library.entries["parakeet-ultra"]?.files
            if files != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(files?["model/weights.bin"]?.size == 150_000)
        #expect(files?["model/weights.bin"]?.sha256.count == 64)
        #expect(Checksums.matches(store.dir(.parakeetUltra), files ?? [:]))
    }

    @Test func adviceOnlyWhenLowAndUnused() {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let recent = now.addingTimeInterval(-2 * 86_400)
        let states: [EngineID: ModelState] = [.parakeetUltra: .ready(600), .parakeetRedux: .ready(200), .whisperTurbo: .ready(600)]
        let entries = ["parakeet-ultra": LibraryEntry(downloadedAt: old, lastUsed: old),
                       "parakeet-redux": LibraryEntry(downloadedAt: old, lastUsed: recent),
                       "whisper-turbo": LibraryEntry(downloadedAt: old, lastUsed: nil)]
        #expect(StorageAdvice.suggest(states: states, entries: entries, inUse: .apple, available: 10_000_000_000, now: now).isEmpty)
        let low = StorageAdvice.suggest(states: states, entries: entries, inUse: .whisperTurbo, available: 2_000_000_000, now: now)
        #expect(low == [.parakeetUltra])
        let all = StorageAdvice.suggest(states: states, entries: entries, inUse: .apple, available: 2_000_000_000, now: now)
        #expect(Set(all) == [.parakeetUltra, .whisperTurbo])
        #expect(StorageAdvice.total(states) == 1400)
    }

    @Test func reuseClonesInsteadOfDownloading() async throws {
        let base = try scratch("reuse")
        defer { try? FileManager.default.removeItem(at: base) }
        let other = base.appendingPathComponent("elsewhere/parakeet-ultra", isDirectory: true)
        try fakeModel(.parakeetUltra, at: other)
        let calls = CallBox()
        let src = try source(bytes: 1000, in: base)
        let fetcher = ReuseFirst(base: CountingFetcher(inner: FileFetcher(source: src), calls: calls),
                                 roots: { _ in [other] },
                                 layout: { id, dir in LibraryFetcher.layout(id, in: dir) },
                                 validate: { _, _, _ in true })
        let store = ModelStore(root: base.appendingPathComponent("models"), fetcher: fetcher)
        store.download(.parakeetUltra)
        await store.waitUntilSettled(.parakeetUltra)
        #expect(store.isReady(.parakeetUltra))
        #expect(calls.count == 0)
        let folder = try #require(store.folder(.parakeetUltra))
        #expect(ModelReuse.isComplete(folder, for: .parakeetUltra))
        let a = other.appendingPathComponent("Encoder.mlmodelc/weight.bin")
        let b = folder.appendingPathComponent("Encoder.mlmodelc/weight.bin")
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
        #expect(inode(a) != inode(b))
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func incompleteOrMismatchedCopyIsNotReused() async throws {
        let base = try scratch("noreuse")
        defer { try? FileManager.default.removeItem(at: base) }
        let partial = base.appendingPathComponent("elsewhere/parakeet-redux", isDirectory: true)
        try fakeModel(.parakeetRedux, at: partial)
        try FileManager.default.removeItem(at: partial.appendingPathComponent("Decoder.mlmodelc"))
        #expect(!ModelReuse.isComplete(partial, for: .parakeetRedux))
        let calls = CallBox()
        let src = try source(bytes: 1000, in: base)
        let first = ReuseFirst(base: CountingFetcher(inner: FileFetcher(source: src), calls: calls),
                               roots: { _ in [partial] }, layout: { LibraryFetcher.layout($0, in: $1) },
                               validate: { _, _, _ in true })
        let store = ModelStore(root: base.appendingPathComponent("m1"), fetcher: first)
        store.download(.parakeetRedux)
        await store.waitUntilSettled(.parakeetRedux)
        #expect(calls.count == 1)

        let full = base.appendingPathComponent("full/parakeet-redux", isDirectory: true)
        try fakeModel(.parakeetRedux, at: full, payload: "other")
        let expected = ["parakeet-redux/Encoder.mlmodelc/coremldata.bin": FileStamp(size: 1, sha256: String(repeating: "0", count: 64))]
        let strict = ReuseFirst(base: CountingFetcher(inner: FileFetcher(source: src), calls: calls),
                                roots: { _ in [full] }, layout: { LibraryFetcher.layout($0, in: $1) },
                                validate: { _, _, _ in true }, expected: { _ in expected })
        let store2 = ModelStore(root: base.appendingPathComponent("m2"), fetcher: strict)
        store2.download(.parakeetRedux)
        await store2.waitUntilSettled(.parakeetRedux)
        #expect(calls.count == 2)

        let failing = ReuseFirst(base: CountingFetcher(inner: FileFetcher(source: src), calls: calls),
                                 roots: { _ in [full] }, layout: { LibraryFetcher.layout($0, in: $1) },
                                 validate: { _, _, _ in false })
        let store3 = ModelStore(root: base.appendingPathComponent("m3"), fetcher: failing)
        store3.download(.parakeetRedux)
        await store3.waitUntilSettled(.parakeetRedux)
        #expect(calls.count == 3)
    }

    @Test func cloneDereferencesHubSymlinks() throws {
        let base = try scratch("hub")
        defer { try? FileManager.default.removeItem(at: base) }
        let blobs = base.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: blobs.appendingPathComponent("b1"))
        let snap = base.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snap.appendingPathComponent("A.mlmodelc"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: snap.appendingPathComponent("A.mlmodelc/coremldata.bin"),
                                                   withDestinationURL: blobs.appendingPathComponent("b1"))
        let out = base.appendingPathComponent("out", isDirectory: true)
        try ModelReuse.clone(snap, to: out)
        let copied = out.appendingPathComponent("A.mlmodelc/coremldata.bin")
        let attrs = try FileManager.default.attributesOfItem(atPath: copied.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: copied, encoding: .utf8) == "abc")
    }

    @Test func searchRootsCoverKnownCaches() {
        let home = URL(fileURLWithPath: "/tmp/h", isDirectory: true)
        let support = URL(fileURLWithPath: "/tmp/h/Library/Application Support", isDirectory: true)
        let roots = ModelReuse.searchRoots(.parakeetUltra, home: home, appSupport: support).map(\.path)
        #expect(roots.contains { $0.hasSuffix("FluidAudio/Models/parakeet-ultra") })
        #expect(!roots.contains { $0.contains("/Documents/") || $0.contains("/Containers/") })
    }
}

enum Compressibility {
    static func lzfseRatio(_ data: Data) -> Double {
        let cap = data.count + 4096
        var dst = [UInt8](repeating: 0, count: cap)
        let n = data.withUnsafeBytes { raw -> Int in
            compression_encode_buffer(&dst, cap, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
        }
        return n == 0 ? 1 : Double(n) / Double(data.count)
    }

    static func saved(_ data: Data) -> Double { 1 - lzfseRatio(data) }
}

@Suite struct CompressibilityTests {
    @Test func measuresRandomAndRepetitive() {
        var rng = SystemRandomNumberGenerator()
        let random = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let repetitive = Data((0..<200_000).map { UInt8($0 % 16) })
        #expect(Compressibility.saved(random) < 0.02)
        #expect(Compressibility.saved(repetitive) > 0.9)
    }

    @Test func packOnlyAboveTwentyPercent() {
        #expect(!PackPolicy.shouldPack(savedFraction: 0.016))
        #expect(!PackPolicy.shouldPack(savedFraction: 0.2))
        #expect(PackPolicy.shouldPack(savedFraction: 0.21))
    }
}
