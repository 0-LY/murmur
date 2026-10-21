import AppKit
import Foundation
import Testing
@testable import Murmur

struct FileFetcher: ModelFetcher {
    let source: URL
    var chunk = 64 * 1024
    var delayNanos: UInt64 = 0

    func fetch(_ id: EngineID, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let folder = dir.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appendingPathComponent("weights.bin")
        let partial = folder.appendingPathComponent("weights.bin.partial")
        let total = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? input.close(); try? output.close() }
        var done = Int(try output.seekToEnd())
        try input.seek(toOffset: UInt64(done))
        while done < total {
            try Task.checkCancellation()
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            done += data.count
            progress(Double(done) / Double(max(1, total)))
            if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        }
        try output.close()
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: partial, to: final)
        return folder
    }
}

func scratch(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MurmurTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func source(bytes: Int, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("source.bin")
    try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
    return url
}

@MainActor @Suite(.serialized) struct ModelStoreTests {
    @Test func downloadReachesReadyWithMarker() async throws {
        let base = try scratch("dl")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = try source(bytes: 600_000, in: base)
        let store = ModelStore(root: base.appendingPathComponent("models"), fetcher: FileFetcher(source: src))
        var seen: [ModelState] = []
        store.onChange = { _, s in seen.append(s) }
        #expect(store.state(.parakeetRedux) == .missing)
        store.download(.parakeetRedux)
        #expect(store.state(.parakeetRedux).isDownloading)
        await store.waitUntilSettled(.parakeetRedux)
        #expect(store.isReady(.parakeetRedux))
        #expect(store.folder(.parakeetRedux)?.lastPathComponent == "model")
        #expect(seen.contains { if case .downloading(let p) = $0 { return p > 0 && p < 1 }; return false })
        let again = ModelStore(root: base.appendingPathComponent("models"), fetcher: FileFetcher(source: src))
        #expect(again.isReady(.parakeetRedux))
    }

    @Test func cancelReturnsToMissingAndResumeFinishes() async throws {
        let base = try scratch("cancel")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = try source(bytes: 2_000_000, in: base)
        let root = base.appendingPathComponent("models")
        let slow = FileFetcher(source: src, chunk: 50_000, delayNanos: 20_000_000)
        let store = ModelStore(root: root, fetcher: slow)
        store.download(.whisperTurbo)
        try await Task.sleep(nanoseconds: 200_000_000)
        store.cancel(.whisperTurbo)
        #expect(store.state(.whisperTurbo) == .missing)
        try await Task.sleep(nanoseconds: 100_000_000)
        let partial = root.appendingPathComponent("whisper-turbo/model/weights.bin.partial")
        let partSize = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int) ?? 0
        #expect(partSize > 0 && partSize < 2_000_000)
        let fast = ModelStore(root: root, fetcher: FileFetcher(source: src))
        #expect(fast.state(.whisperTurbo) == .missing)
        fast.download(.whisperTurbo)
        await fast.waitUntilSettled(.whisperTurbo)
        #expect(fast.isReady(.whisperTurbo))
        let final = root.appendingPathComponent("whisper-turbo/model/weights.bin")
        #expect(try Data(contentsOf: final) == Data(contentsOf: src))
    }

    @Test func deleteRemovesFilesAndAppleStaysReady() async throws {
        let base = try scratch("del")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = try source(bytes: 100_000, in: base)
        let store = ModelStore(root: base.appendingPathComponent("models"), fetcher: FileFetcher(source: src))
        store.download(.parakeetUltra)
        await store.waitUntilSettled(.parakeetUltra)
        #expect(store.isReady(.parakeetUltra))
        store.delete(.parakeetUltra)
        #expect(store.state(.parakeetUltra) == .missing)
        #expect(!FileManager.default.fileExists(atPath: store.dir(.parakeetUltra).path))
        store.delete(.apple)
        #expect(store.isReady(.apple))
    }

    @Test func failureIsReportedAndRetryable() async throws {
        let base = try scratch("fail")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ModelStore(root: base.appendingPathComponent("models"),
                               fetcher: FileFetcher(source: base.appendingPathComponent("missing.bin")))
        store.download(.parakeetRedux)
        await store.waitUntilSettled(.parakeetRedux)
        guard case .failed = store.state(.parakeetRedux) else { Issue.record("expected failure"); return }
        #expect(ModelLifecycle.canStart(store.state(.parakeetRedux)))
    }

    @Test func lifecycleRules() {
        #expect(ModelLifecycle.canStart(.missing))
        #expect(!ModelLifecycle.canStart(.downloading(0.3)))
        #expect(!ModelLifecycle.canStart(.ready(10)))
        #expect(ModelLifecycle.stateAfterCancel(.downloading(0.5)) == .missing)
        #expect(ModelLifecycle.stateAfterCancel(.ready(5)) == .ready(5))
        #expect(!ModelLifecycle.enoughSpace(available: 500_000_000, needed: 640_000_000))
        #expect(ModelLifecycle.enoughSpace(available: 2_000_000_000, needed: 640_000_000))
        #expect(ModelLifecycle.enoughSpace(available: nil, needed: 640_000_000))
        #expect(ModelLifecycle.clamp(.nan) == 0)
        #expect(ModelLifecycle.clamp(1.4) == 1)
    }

    @Test func relativePaths() {
        let base = URL(fileURLWithPath: "/tmp/a/b")
        #expect(ModelStore.relativePath(of: URL(fileURLWithPath: "/tmp/a/b/models/x"), in: base) == "models/x")
        #expect(ModelStore.relativePath(of: URL(fileURLWithPath: "/tmp/a/b"), in: base) == ".")
        #expect(ModelStore.relativePath(of: URL(fileURLWithPath: "/elsewhere"), in: base) == ".")
    }

    @Test func effectiveEngineFallsBackToApple() {
        #expect(EngineHub.effective(.parakeetUltra) { _ in false } == .apple)
        #expect(EngineHub.effective(.parakeetUltra) { $0 == .parakeetUltra } == .parakeetUltra)
        #expect(EngineHub.effective(.apple) { _ in false } == .apple)
    }

    @Test func pendingEngineReactions() {
        #expect(PendingEngine.react(id: .parakeetUltra, state: .ready(1), pending: "parakeet-ultra", current: "apple") == .use)
        #expect(PendingEngine.react(id: .parakeetUltra, state: .missing, pending: nil, current: "parakeet-ultra") == .fallBack)
        #expect(PendingEngine.react(id: .parakeetRedux, state: .ready(1), pending: "parakeet-ultra", current: "apple") == .nothing)
    }
}

@Suite struct HotkeyTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    @Test func holdStartsAndStopsOnRelease() {
        var g = TalkGesture()
        #expect(g.press(mode: .hold, at: t0) == .start)
        #expect(g.release(mode: .hold, at: t0.addingTimeInterval(1.2)) == .stop)
        #expect(!g.listening)
    }

    @Test func quickTapLatchesUntilNextPress() {
        var g = TalkGesture()
        #expect(g.press(mode: .hold, at: t0) == .start)
        #expect(g.release(mode: .hold, at: t0.addingTimeInterval(0.1)) == .none)
        #expect(g.listening)
        #expect(g.press(mode: .hold, at: t0.addingTimeInterval(3)) == .stop)
        #expect(g.release(mode: .hold, at: t0.addingTimeInterval(3.1)) == .none)
        #expect(!g.listening)
    }

    @Test func toggleIgnoresRelease() {
        var g = TalkGesture()
        #expect(g.press(mode: .toggle, at: t0) == .start)
        #expect(g.release(mode: .toggle, at: t0.addingTimeInterval(2)) == .none)
        #expect(g.press(mode: .toggle, at: t0.addingTimeInterval(4)) == .stop)
    }

    @Test func repeatPressWhileHoldingDoesNothing() {
        var g = TalkGesture()
        _ = g.press(mode: .hold, at: t0)
        #expect(g.press(mode: .hold, at: t0.addingTimeInterval(0.5)) == .none)
        g.cancel()
        #expect(!g.listening)
        #expect(g.release(mode: .hold, at: t0.addingTimeInterval(1)) == .none)
    }

    @Test func hotkeyTable() {
        #expect(hotkeyName("ctrl-opt-v") == "⌃⌥V")
        #expect(hotkeyName("nonsense") == "⌃⌥V")
        #expect(Set(hotkeys.map(\.id)).count == hotkeys.count)
        #expect(Config().hotkey == "ctrl-opt-v")
    }
}

@Suite struct InsertTests {
    @Test func pasteOnlyWhenSafe() {
        #expect(InsertDecision.decide(mode: .paste, trusted: true, sameApp: true, sameField: true, ownAppFront: false) == .paste)
        #expect(InsertDecision.decide(mode: .paste, trusted: false, sameApp: true, sameField: true, ownAppFront: false) == .copy("Copied · allow Accessibility"))
        #expect(InsertDecision.decide(mode: .paste, trusted: true, sameApp: false, sameField: true, ownAppFront: false) == .copy("Copied — app changed"))
        #expect(InsertDecision.decide(mode: .paste, trusted: true, sameApp: true, sameField: true, ownAppFront: false, editable: false) == .copy("Copied"))
        #expect(Focus.isEditable(nil) == false)
        #expect(InsertDecision.decide(mode: .paste, trusted: true, sameApp: true, sameField: false, ownAppFront: false) == .copy("Copied — field changed"))
        #expect(InsertDecision.decide(mode: .copy, trusted: true, sameApp: true, sameField: true, ownAppFront: false) == .copy("Copied"))
        #expect(InsertDecision.decide(mode: .paste, trusted: true, sameApp: true, sameField: true, ownAppFront: true) == .copy("Copied"))
    }

    @Test func focusComparison() {
        let a = AXUIElementCreateApplication(1)
        #expect(Focus.same(nil, nil))
        #expect(!Focus.same(a, nil))
        #expect(Focus.same(a, AXUIElementCreateApplication(1)))
        #expect(!Focus.same(a, AXUIElementCreateApplication(2)))
    }

    @Test func terminalsGetSafeText() {
        #expect(TextShape.forTarget("ls -la\n", bundleId: "com.apple.Terminal") == "ls -la")
        #expect(TextShape.forTarget("a\u{1b}[31mb", bundleId: "com.googlecode.iterm2") == "a[31mb")
        #expect(TextShape.forTarget("Hello\n", bundleId: "com.apple.TextEdit") == "Hello\n")
    }

    @MainActor @Test func clipboardMarkersAndRestore() {
        let pb = NSPasteboard(name: NSPasteboard.Name("MurmurTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("before", forType: .string)
        let saved = Clip.save(pb)
        Clip.write("spoken", pb)
        #expect(pb.string(forType: .string) == "spoken")
        #expect(pb.types?.contains(Clip.transient) == true)
        #expect(pb.types?.contains(Clip.concealed) == true)
        Clip.restore(saved, pb)
        #expect(pb.string(forType: .string) == "before")
        Clip.write("visible", pb, private: false)
        #expect(pb.types?.contains(Clip.transient) == false)
    }
}

@Suite struct CleanupTests {
    @Test func instructionsCarryRulesAndVocabulary() {
        let i = CleanupRules.instructions(vocabulary: ["Linear", "Figma"])
        #expect(i.contains("Never translate"))
        #expect(i.contains("never answer questions"))
        #expect(i.contains("Linear, Figma"))
        #expect(i.contains("Never add these words"))
        #expect(!CleanupRules.instructions(vocabulary: []).contains("Spelling list"))
    }

    @Test func fillersAndVocabulary() {
        #expect(CleanupRules.removeFillers("um so we uh ship it") == "so we ship it")
        #expect(CleanupRules.removeFillers("ну давай зробимо") == "давай зробимо")
        #expect(CleanupRules.removeFillers("umbrella stays") == "umbrella stays")
        #expect(CleanupRules.applyVocabulary("open figma and linear", ["Figma", "Linear"]) == "open Figma and Linear")
        #expect(CleanupRules.tidy("um open figma now", vocabulary: ["Figma"]) == "Open Figma now.")
    }

    @Test func acceptGuards() {
        let input = "please move the ticket to done and ping me on slack"
        #expect(CleanupRules.accept(input: input, output: "Please move the ticket to done and ping me on Slack."))
        #expect(!CleanupRules.accept(input: input, output: ""))
        #expect(!CleanupRules.accept(input: input, output: "Sure! Here is a much longer answer that explains how to move tickets in great detail to everyone."))
        #expect(!CleanupRules.accept(input: "будь ласка надішли мені звіт до вечора", output: "Please send me the report by evening."))
        #expect(CleanupRules.stripPreamble("Here is the cleaned text:\nHello there.") == "Hello there.")
        let vocab = ["Apple", "Mac", "Figma"]
        #expect(!CleanupRules.accept(input: input, output: "Apple, Mac, Figma. Please move the ticket to done and ping me on Slack.", vocabulary: vocab))
        #expect(CleanupRules.accept(input: "open sigma and share it", output: "Open Figma and share it.", vocabulary: vocab))
    }

    @Test func offModeReturnsTrimmedInput() async {
        let out = await Cleaner.clean("  um hello  ", mode: .off, vocabulary: [])
        #expect(out == "um hello")
    }
}

@Suite struct LanguageTests {
    let supported = [Locale(identifier: "en_GB"), Locale(identifier: "en_US"), Locale(identifier: "uk_UA"), Locale(identifier: "de_DE")]

    @Test func appleLocalePicks() {
        #expect(LanguageChoice.appleLocale(for: .en, keyboard: [], supported: supported).identifier(.bcp47) == "en-US")
        #expect(LanguageChoice.appleLocale(for: .uk, keyboard: [], supported: supported).identifier(.bcp47) == "uk-UA")
        #expect(LanguageChoice.appleLocale(for: .auto, keyboard: ["uk", "en"], supported: supported).identifier(.bcp47) == "uk-UA")
        #expect(LanguageChoice.appleLocale(for: .auto, keyboard: ["xx"], supported: supported).identifier(.bcp47) == "en-US")
    }

    @Test func modelHints() {
        #expect(LanguageChoice.whisperCode(for: .auto) == nil)
        #expect(LanguageChoice.whisperCode(for: .uk) == "uk")
        #expect(LanguageChoice.parakeetHint(for: .en) == .english)
        #expect(LanguageChoice.parakeetHint(for: .auto) == nil)
    }
}

@Suite struct ConfigAndSetupTests {
    @Test func decodingToleratesBadValues() throws {
        let json = #"{"engine":"nope","mode":"weird","hotkey":"ctrl-opt-m","cleanup":"off"}"#
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(cfg.engine == "apple")
        #expect(cfg.mode == .hold)
        #expect(cfg.hotkey == "ctrl-opt-m")
        #expect(cfg.cleanup == .off)
        #expect(cfg.launchAtLogin == false)
    }

    @Test func vocabularyWords() {
        var cfg = Config()
        cfg.vocabulary = "Apple, Mac,\n Figma ,,"
        #expect(cfg.vocabularyWords == ["Apple", "Mac", "Figma"])
    }

    @Test func setupMergeKeepsUntouchedSettings() {
        var start = Config()
        var current = Config()
        current.vocabulary = "Linear"
        current.cleanup = .off
        var changes = start
        changes.hotkey = "ctrl-opt-m"
        start.mode = .hold
        let out = MurmurSetup.merge(changes: changes, since: start, into: current)
        #expect(out.hotkey == "ctrl-opt-m")
        #expect(out.vocabulary == "Linear")
        #expect(out.cleanup == .off)
        #expect(MurmurSetup.shouldOfferSetup(fresh: true, background: false))
        #expect(!MurmurSetup.shouldOfferSetup(fresh: true, background: true))
        #expect(!MurmurSetup.shouldOfferSetup(fresh: false, background: false))
    }

    @Test func dictationRules() {
        #expect(!DictationRules.shouldTranscribe(duration: 0.1))
        #expect(DictationRules.shouldTranscribe(duration: 0.5))
        #expect(DictationRules.engineLabel(wanted: .apple, used: .apple) == "Apple")
    }

    @Test func audioTempFilesArePrivateAndRemoved() throws {
        let rec = try AudioFiles.recording(from: [Float](repeating: 0.1, count: 16_000))
        let dirPerm = try FileManager.default.attributesOfItem(atPath: rec.dir.path)[.posixPermissions] as? Int
        let filePerm = try FileManager.default.attributesOfItem(atPath: rec.url.path)[.posixPermissions] as? Int
        #expect(dirPerm == 0o700)
        #expect(filePerm == 0o600)
        #expect(abs(rec.duration - 1.0) < 0.01)
        let loaded = try AudioFiles.load(rec.url)
        #expect(abs(loaded.samples.count - 16_000) < 64, "count \(loaded.samples.count)")
        loaded.discard()
        rec.discard()
        #expect(!FileManager.default.fileExists(atPath: rec.dir.path))
    }

    @Test func catalog() {
        #expect(ModelInfo.all.count == 4)
        #expect(ModelInfo.downloadable.count == 3)
        #expect(ModelInfo.info(.apple).builtIn)
        #expect(LibraryFetcher.parakeetVersion(.parakeetUltra) != nil)
        #expect(LibraryFetcher.parakeetVersion(.whisperTurbo) == nil)
    }
}
