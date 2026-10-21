import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Murmur

enum VoiceFixtures {
    static func voice(_ hz: Double, seconds: Double, dbfs: Double, rate: Double = Recording.sampleRate) -> [Float] {
        let amp = Float(pow(10, dbfs / 20) * 2.squareRoot())
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = Float(0.7 + 0.3 * sin(2 * .pi * 4 * t))
            return amp * env * Float(sin(2 * .pi * hz * t))
        }
    }

    static func gap(_ seconds: Double, rate: Double = Recording.sampleRate) -> [Float] {
        [Float](repeating: 0.00002, count: Int(seconds * rate))
    }

    static func frequency(_ s: [Float], rate: Double = Recording.sampleRate) -> Double {
        var crossings = 0
        for i in 1..<max(1, s.count) where (s[i - 1] < 0) != (s[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(s.count) / rate)
    }

    static func embed(_ s: [Float]) async throws -> [Float] {
        var v = [Float](repeating: 0.01, count: VoiceEmbedding.dimension)
        v[frequency(s) < 275 ? 0 : 1] = 1
        return v
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

@Suite struct MainVoiceLogicTests {
    let t = -45.0

    @Test func piecesFollowSpeechAndSplitLongRuns() {
        let s = VoiceFixtures.voice(220, seconds: 1, dbfs: -24) + VoiceFixtures.gap(0.6) + VoiceFixtures.voice(220, seconds: 4, dbfs: -24)
        let ps = MainVoice.pieces(s, threshold: t)
        #expect(ps.count == 4)
        #expect(ps.allSatisfy { $0.voiced <= MainVoice.pieceSeconds + 0.001 })
        #expect(abs(ps.map(\.voiced).reduce(0, +) - 5) < 0.1)
    }

    @Test func shortGapsStayInOnePiece() {
        let s = VoiceFixtures.voice(220, seconds: 0.5, dbfs: -24) + VoiceFixtures.gap(0.2) + VoiceFixtures.voice(220, seconds: 0.5, dbfs: -24)
        #expect(MainVoice.pieces(s, threshold: t).count == 1)
    }

    @Test func clusterGroupsSimilarVectors() {
        let a: [Float] = [1, 0.1, 0], a2: [Float] = [0.95, 0.12, 0.02], b: [Float] = [0, 0.1, 1]
        let labels = MainVoice.cluster([a, b, a2])
        #expect(labels[0] == labels[2])
        #expect(labels[0] != labels[1])
        #expect(Set(MainVoice.cluster([a, a2])).count == 1)
    }

    @Test func dominantIsDurationTimesLoudness() {
        let p = { (v: Double, l: Double) in MainVoice.Piece(range: 0..<1, voiced: v, loudness: l) }
        #expect(MainVoice.dominant(labels: [0, 1], pieces: [p(2, 0.05), p(2, 0.01)]) == 0)
        #expect(MainVoice.dominant(labels: [0, 1, 1], pieces: [p(1, 0.05), p(1.5, 0.03), p(1.5, 0.03)]) == 1)
    }

    @Test func unembeddedPiecesFollowTheirNeighbour() {
        let ps = [MainVoice.Piece(range: 0..<100, voiced: 1, loudness: 1),
                  MainVoice.Piece(range: 120..<140, voiced: 0.2, loudness: 1),
                  MainVoice.Piece(range: 900..<1000, voiced: 1, loudness: 1)]
        #expect(MainVoice.assign(labels: [0, nil, 1], pieces: ps) == [0, 0, 1])
    }

    @Test func louderLongerVoiceWinsAndOtherIsDropped() async {
        let main = VoiceFixtures.voice(220, seconds: 3, dbfs: -20)
        let other = VoiceFixtures.voice(330, seconds: 1.5, dbfs: -30)
        let s = main + VoiceFixtures.gap(0.6) + other + VoiceFixtures.gap(0.6) + main
        let r = await MainVoice.focus(s, threshold: t, embed: VoiceFixtures.embed)
        #expect(r.report.clusters == 2)
        #expect(r.report.dropped > 0)
        let removed = s.count - r.samples.count
        #expect(abs(removed - other.count) < Int(0.3 * Recording.sampleRate))
        #expect(VoiceFixtures.frequency(r.samples.filter { abs($0) > 0.001 }) < 275)
    }

    @Test func equalLengthKeepsEverythingBecauseOfTheCap() async {
        let loud = VoiceFixtures.voice(220, seconds: 2, dbfs: -20)
        let quiet = VoiceFixtures.voice(330, seconds: 2, dbfs: -32)
        let s = quiet + VoiceFixtures.gap(0.6) + loud
        let r = await MainVoice.focus(s, threshold: t, embed: VoiceFixtures.embed)
        #expect(r.report.clusters == 2)
        #expect(r.samples == s)
        #expect(r.report.reason == "would drop too much")
    }

    @Test func loudOtherVoiceIsNeverDropped() async {
        let main = VoiceFixtures.voice(220, seconds: 3, dbfs: -20)
        let near = VoiceFixtures.voice(330, seconds: 1, dbfs: -22)
        let s = main + VoiceFixtures.gap(0.6) + near + VoiceFixtures.gap(0.6) + main
        for level in MainVoiceSensitivity.allCases {
            let r = await MainVoice.focus(s, threshold: t, sensitivity: level, embed: VoiceFixtures.embed)
            #expect(r.samples == s, "\(level) dropped a voice only 2 dB quieter")
        }
    }

    @Test func quieterThresholdFollowsSensitivity() async {
        let main = VoiceFixtures.voice(220, seconds: 3, dbfs: -20)
        let other = VoiceFixtures.voice(330, seconds: 1, dbfs: -24.5)
        let s = main + VoiceFixtures.gap(0.6) + other + VoiceFixtures.gap(0.6) + main
        let low = await MainVoice.focus(s, threshold: t, sensitivity: .low, embed: VoiceFixtures.embed)
        let high = await MainVoice.focus(s, threshold: t, sensitivity: .high, embed: VoiceFixtures.embed)
        #expect(low.samples == s)
        #expect(high.samples.count < s.count)
    }

    @Test func ownSpeechIsAlwaysKeptAtLowAndMedium() async {
        let mine = VoiceFixtures.voice(220, seconds: 2, dbfs: -20)
        let quietMine = VoiceFixtures.voice(220, seconds: 1, dbfs: -30)
        let other = VoiceFixtures.voice(330, seconds: 1, dbfs: -34)
        let s = mine + VoiceFixtures.gap(0.6) + quietMine + VoiceFixtures.gap(0.6) + other + VoiceFixtures.gap(0.6) + mine
        for level in [MainVoiceSensitivity.low, .medium] {
            let r = await MainVoice.focus(s, threshold: t, sensitivity: level, embed: VoiceFixtures.embed)
            let kept = r.samples.filter { abs($0) > 0.001 }
            let expected = (mine + quietMine + mine).filter { abs($0) > 0.001 }.count
            #expect(kept.count >= expected - Int(0.05 * Recording.sampleRate), "\(level) cut own speech")
        }
    }

    @Test func dropRules() {
        let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0]
        #expect(!MainVoice.shouldDrop(label: 0, main: 0, vector: b, centroid: a, decibels: -40, mainMedian: -20, similarity: 0.6, quieterDb: 6))
        #expect(!MainVoice.shouldDrop(label: 1, main: 0, vector: nil, centroid: a, decibels: -40, mainMedian: -20, similarity: 0.6, quieterDb: 6))
        #expect(!MainVoice.shouldDrop(label: 1, main: 0, vector: b, centroid: a, decibels: -24, mainMedian: -20, similarity: 0.6, quieterDb: 6))
        #expect(!MainVoice.shouldDrop(label: 1, main: 0, vector: a, centroid: a, decibels: -40, mainMedian: -20, similarity: 0.6, quieterDb: 6))
        #expect(MainVoice.shouldDrop(label: 1, main: 0, vector: b, centroid: a, decibels: -40, mainMedian: -20, similarity: 0.6, quieterDb: 6))
        #expect(MainVoice.capped(dropVoiced: 2.1, totalVoiced: 5))
        #expect(!MainVoice.capped(dropVoiced: 1.9, totalVoiced: 5))
    }

    @Test func confirmOnlyWhenTurningOn() async {
        #expect(MainVoiceConfirm.needsConfirm(old: false, new: true))
        #expect(!MainVoiceConfirm.needsConfirm(old: true, new: false))
        #expect(!MainVoiceConfirm.needsConfirm(old: true, new: true))
        await MainActor.run {
            let saved = MainVoiceConfirm.ask
            defer { MainVoiceConfirm.ask = saved }
            var asked = 0
            MainVoiceConfirm.ask = { asked += 1; return false }
            #expect(MainVoiceConfirm.resolve(old: false, new: true) == false)
            MainVoiceConfirm.ask = { asked += 1; return true }
            #expect(MainVoiceConfirm.resolve(old: false, new: true) == true)
            #expect(MainVoiceConfirm.resolve(old: true, new: false) == false)
            #expect(asked == 2)
        }
    }

    @Test func mainVoiceIsOffByDefault() throws {
        #expect(!Config().mainVoice)
        #expect(Config().mainVoiceSensitivity == .low)
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"mainVoice":true,"cleanup":"light"}"#.utf8))
        #expect(old.mainVoice)
        #expect(old.cleanup == .quick)
    }

    @Test func underTwoSecondsKeepsEverything() async {
        let s = VoiceFixtures.voice(220, seconds: 0.8, dbfs: -20) + VoiceFixtures.gap(0.6) + VoiceFixtures.voice(330, seconds: 0.8, dbfs: -30)
        let r = await MainVoice.focus(s, threshold: t, embed: VoiceFixtures.embed)
        #expect(r.samples == s)
        #expect(r.report.dropped == 0)
    }

    @Test func singleVoiceIsUnchanged() async {
        let s = VoiceFixtures.voice(220, seconds: 2, dbfs: -20) + VoiceFixtures.gap(0.6) + VoiceFixtures.voice(220, seconds: 2, dbfs: -26)
        let r = await MainVoice.focus(s, threshold: t, embed: VoiceFixtures.embed)
        #expect(r.samples == s)
        #expect(r.report.clusters == 1)
    }

    @Test func badEmbeddingsKeepEverything() async {
        let s = VoiceFixtures.voice(220, seconds: 3, dbfs: -20) + VoiceFixtures.gap(0.6) + VoiceFixtures.voice(330, seconds: 2, dbfs: -30)
        let r = await MainVoice.focus(s, threshold: t) { (_: [Float]) in [Float](repeating: .nan, count: VoiceEmbedding.dimension) }
        #expect(r.samples == s)
    }

    @Test func configMigrationDropsOldKeys() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"onlyMyVoice":true,"voiceStrictness":0.9}"#.utf8))
        #expect(!c.mainVoice)
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!json.contains("onlyMyVoice") && !json.contains("voiceStrictness"))
        let off = try JSONDecoder().decode(Config.self, from: Data(#"{"mainVoice":false}"#.utf8))
        #expect(!off.mainVoice)
    }

    @Test func legacyKeysAreDroppedFromTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)", isDirectory: true)
        Config.overrideDirectory = dir
        defer { Config.overrideDirectory = nil; try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"onlyMyVoice":true,"voiceStrictness":0.4,"volume":5}"#.utf8).write(to: Config.fileURL)
        Config.dropLegacyKeys()
        let json = try String(contentsOf: Config.fileURL, encoding: .utf8)
        #expect(!json.contains("onlyMyVoice") && !json.contains("voiceStrictness"))
        #expect(Config.load().volume == 5)
    }

    @Test @MainActor func legacyVoicePrintIsDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mv-\(UUID().uuidString)", isDirectory: true)
        VoiceStore.overrideRoot = dir
        defer { VoiceStore.overrideRoot = nil; try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: VoiceStore.legacyPrintURL)
        VoiceStore.removeLegacyVoicePrint()
        #expect(!FileManager.default.fileExists(atPath: VoiceStore.legacyPrintURL.path))
    }
}

@MainActor @Suite struct OwnSoundTests {
    var cfg: Config {
        var c = Config()
        c.cleanup = .off
        return c
    }

    func bubble() throws -> [Float] {
        try AudioFiles.readSamples(VoiceFixtures.repoRoot.appendingPathComponent("Resources/Sounds/bubble-start.caf"))
    }

    @Test func fillerOnlyDetection() {
        for t in ["Ooh.", "Oh, oh!", "uh", "Hmm…", "Ой.", "ну", "", "  ."] { #expect(DictationRules.isFillerOnly(t), "\(t)") }
        for t in ["Okay.", "Oh hello", "Ну добре", "a cup of tea"] { #expect(!DictationRules.isFillerOnly(t), "\(t)") }
    }

    @Test func muteWindowCoversSoundPlusTail() {
        #expect(DictationRules.muteCount(elapsed: 0.01, sound: 0) == 0)
        let n = DictationRules.muteCount(elapsed: 0.01, sound: 0.3)
        #expect(n == Int(((0.01 + 0.3 + 0.08) * Recording.sampleRate).rounded(.up)))
        let s = [Float](repeating: 0.5, count: 100)
        let m = DictationRules.muted(s, count: 40)
        #expect(m[0..<40].allSatisfy { $0 == 0 } && m[40...].allSatisfy { $0 == 0.5 })
    }

    @Test func onlyOurStartSoundPastesNothing() async throws {
        let sound = try bubble()
        #expect(!sound.isEmpty)
        let soundSeconds = Double(sound.count) / Recording.sampleRate
        let samples = sound + VoiceFixtures.gap(1.5)
        let duration = Double(samples.count) / Recording.sampleRate
        let muted = DictationRules.muteCount(elapsed: 0.01, sound: soundSeconds)
        var called = false
        let r = try await DictationPipeline.run(samples, duration: duration, cfg: cfg, muted: muted, filter: { $0 },
                                                transcribe: { _ in called = true; return "Ooh." })
        #expect(r == .noSpeech)
        #expect(!called)
    }

    @Test func oohFromTheEngineIsRejected() async throws {
        let audio = PipelineFixtures.padded(PipelineFixtures.tone(seconds: 1, dbfs: -24), silence: 0.3)
        let r = try await DictationPipeline.run(audio, duration: 1.6, cfg: cfg, filter: { $0 }, transcribe: { _ in "Ooh." })
        #expect(r == .noSpeech)
    }

    @Test func underPointFourSecondsOfSpeechIsNoSpeech() async throws {
        let audio = PipelineFixtures.padded(PipelineFixtures.tone(seconds: 0.25, dbfs: -24), silence: 0.4)
        let r = try await DictationPipeline.run(audio, duration: 1.05, cfg: cfg, filter: { $0 }, transcribe: { _ in "hello" })
        #expect(r == .noSpeech)
    }

    @Test func realSpeechAfterTheSoundStillWorks() async throws {
        let sound = try bubble()
        let samples = sound + VoiceFixtures.gap(0.2) + PipelineFixtures.tone(seconds: 1.2, dbfs: -24) + VoiceFixtures.gap(0.3)
        let muted = DictationRules.muteCount(elapsed: 0.01, sound: Double(sound.count) / Recording.sampleRate)
        let r = try await DictationPipeline.run(samples, duration: Double(samples.count) / Recording.sampleRate, cfg: cfg,
                                                muted: muted, filter: { $0 }, transcribe: { _ in "Send it now." })
        #expect(r == .text("Send it now."))
    }
}

@MainActor @Suite(.serialized) struct HideWhenOffTests {
    @Test func motionScales() {
        #expect(HUDMotion.scale(shown: true, leaving: false, reduceMotion: false) == 1)
        #expect(HUDMotion.scale(shown: false, leaving: false, reduceMotion: false) == HUDMotion.appearScale)
        #expect(HUDMotion.scale(shown: false, leaving: true, reduceMotion: false) == HUDMotion.leaveScale)
        #expect(HUDMotion.scale(shown: false, leaving: true, reduceMotion: true) == 1)
        #expect(HUDMotion.appearScale == 0.88 && HUDMotion.leaveScale == 0.94 && HUDMotion.fadeOut == 0.3)
    }

    @Test func soundsSwitchDoesNotMoveRowsAbove() async {
        var seen: [[String: CGRect]] = []
        for on in [true, false] {
            var cfg = Config()
            cfg.sounds = on
            let view = Form {
                Section { Text("Above").probe("above") }
                Section { SoundRows(cfg: .constant(cfg)) }
            }
            .formStyle(.grouped)
            .controlSize(.small)
            seen.append(await probeFrames(view, size: CGSize(width: 480, height: 320)))
        }
        for id in ["above", "soundsToggle"] {
            let frames = seen.compactMap { $0[id] }
            #expect(frames.count == 2, "missing \(id)")
            #expect(Set(frames.map { "\(Int($0.minY)) \(Int($0.height))" }).count == 1, "\(id) moved: \(frames)")
        }
    }

    @Test func mainVoiceSwitchDoesNotMove() async {
        var seen: [[String: CGRect]] = []
        for on in [true, false] {
            let view = Form {
                Section { Text("Above").probe("above") }
                Section { MainVoiceRow(on: .constant(on), sensitivity: .constant(.low)) }
            }
            .formStyle(.grouped)
            .controlSize(.small)
            seen.append(await probeFrames(view, size: CGSize(width: 480, height: 220)))
        }
        for id in ["above", "mainVoice"] {
            let frames = seen.compactMap { $0[id] }
            #expect(frames.count == 2, "missing \(id)")
            #expect(Set(frames.map { "\(Int($0.minY)) \(Int($0.height))" }).count == 1, "\(id) moved: \(frames)")
        }
    }
}

@MainActor @Suite(.serialized) struct MainVoiceAudioTests {
    @Test(.enabled(if: SpeakerBench.enabled), .timeLimit(.minutes(20)))
    func keepsTheMainVoice() async throws {
        let base = SpeakerBench.dir
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        VoiceStore.overrideRoot = base.appendingPathComponent("voice", isDirectory: true)
        defer { VoiceStore.overrideRoot = nil }
        let store = VoiceStore()
        #expect(await store.downloadModel())
        let say = { (voice: String, text: String, name: String) in try SpeakerBench.say(voice, text, to: base.appendingPathComponent("\(name).aiff")) }
        let gap = VoiceFixtures.gap(0.5)
        let mine = ["Please move the Linear ticket to done and ping the team about the release.",
                    "Can you send the report to Anna before noon tomorrow and copy me in."]
        let theirs = ["I think we should order pizza for lunch.", "Has anyone seen my keys."]
        struct Case { var name: String; var samples: [Float]; var label: [Bool]; var expectChange: Bool }
        var cases: [Case] = []
        for other in ["Daniel", "Fred", "Rishi", "Karen"] {
            for (i, m) in mine.enumerated() {
                let a = try say("Samantha", m, "a")
                let b = try say(other, theirs[i], "b").map { $0 * 0.5 }
                let samples = a + gap + b + gap
                let label = Array(repeating: true, count: a.count) + Array(repeating: false, count: gap.count + b.count + gap.count)
                cases.append(Case(name: "longer+louder vs \(other)", samples: samples, label: label, expectChange: true))
                let c = try say(other, theirs[i], "c").map { $0 * 0.25 }
                cases.append(Case(name: "much quieter \(other)", samples: a + gap + c + gap,
                                  label: Array(repeating: true, count: a.count) + Array(repeating: false, count: gap.count + c.count + gap.count),
                                  expectChange: true))
            }
            let x = try say("Samantha", "Let's meet at three and go over the plan.", "x")
            let y = try say(other, "Let's meet at four and go over it again.", "y").map { $0 * 0.5 }
            cases.append(Case(name: "equal length vs \(other)", samples: x + gap + y,
                              label: Array(repeating: true, count: x.count) + Array(repeating: false, count: gap.count + y.count),
                              expectChange: true))
        }
        let short = try say("Samantha", "Okay, thanks.", "s")
        cases.append(Case(name: "under 2 s", samples: short, label: Array(repeating: true, count: short.count), expectChange: false))
        let single = try say("Samantha", mine[0] + " " + mine[1], "single")
        cases.append(Case(name: "single voice", samples: single, label: Array(repeating: true, count: single.count), expectChange: false))

        var embeddings: [String: [[Float]]] = [:]
        var report = ["sensitivity | case | kept mine | dropped theirs | unchanged"]
        for level in MainVoiceSensitivity.allCases {
            var keptSum = 0.0, droppedSum = 0.0, n = 0.0, unchangedOK = true
            for c in cases {
                let ps = MainVoice.pieces(c.samples, threshold: -45)
                var vecs = embeddings[c.name + "\(c.samples.count)"]
                if vecs == nil {
                    var v: [[Float]] = []
                    for p in ps { v.append((try? await store.embed(Array(c.samples[p.range]))) ?? []) }
                    vecs = v
                    embeddings[c.name + "\(c.samples.count)"] = v
                }
                let table = vecs!
                let r = await MainVoice.focusForBench(c.samples, threshold: -45, similarity: level.similarity, quieterDb: level.quieterDb) { i in table[i] }
                let keptMask = MainVoice.keptMask(count: c.samples.count, dropped: r.dropped)
                var mineTotal = 0, mineKept = 0, theirsTotal = 0, theirsDropped = 0
                for p in ps {
                    let center = (p.range.lowerBound + p.range.upperBound) / 2
                    if c.label[min(center, c.label.count - 1)] {
                        mineTotal += 1; if keptMask[center] { mineKept += 1 }
                    } else {
                        theirsTotal += 1; if !keptMask[center] { theirsDropped += 1 }
                    }
                }
                let k = Double(mineKept) / Double(max(1, mineTotal))
                let d = theirsTotal == 0 ? 1 : Double(theirsDropped) / Double(theirsTotal)
                if !c.expectChange && r.dropped.count > 0 { unchangedOK = false }
                if c.expectChange { keptSum += k; droppedSum += d; n += 1 }
                report.append(String(format: "%@ | %@ | %.0f%% | %.0f%% | %@", level.rawValue, c.name, k * 100, d * 100,
                                     c.expectChange ? "-" : (r.dropped.isEmpty ? "yes" : "NO")))
            }
            report.append(String(format: "%@ | AVERAGE | %.0f%% | %.0f%% | %@", level.rawValue, keptSum / max(1, n) * 100,
                                 droppedSum / max(1, n) * 100, unchangedOK ? "ok" : "broken"))
            #expect(unchangedOK)
            if level != .high { #expect(keptSum / max(1, n) >= 0.999, "\(level) cut own speech") }
        }
        try report.joined(separator: "\n").write(to: base.appendingPathComponent("main-voice-report.txt"), atomically: true, encoding: .utf8)
    }
}

@MainActor @Suite(.serialized) struct HUDSequenceShots {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_HUDSEQ"] == "1"
    static var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MURMUR_HUDSEQ_DIR"] ?? NSTemporaryDirectory(), isDirectory: true) }

    func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    func mark(_ name: String, _ log: inout [String], _ t0: Date) {
        log.append(String(format: "%.3f %@", Date().timeIntervalSince(t0), name))
    }

    @Test(.enabled(if: HUDSequenceShots.enabled), .timeLimit(.minutes(3)))
    func sequence() async throws {
        let base = Self.dir
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        Config.overrideDirectory = base.appendingPathComponent("config", isDirectory: true)
        var cfg = Config()
        cfg.hudSize = "large"
        Config.save(cfg)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let backdropRect = NSRect(x: 300, y: 400, width: 420, height: 180)
        let dark = ProcessInfo.processInfo.environment["MURMUR_HUDSEQ_LIGHT"] != "1"
        let back = InertWindow(contentRect: backdropRect, styleMask: [.borderless], backing: .buffered, defer: false)
        back.ignoresMouseEvents = true
        back.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        back.level = .floating
        back.orderFrontRegardless()
        let anchor = CGRect(x: 360, y: 460, width: 200, height: 20)
        let screenH = NSScreen.screens.first?.frame.height ?? 900
        let info: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier), "x": backdropRect.minX,
                                   "y": screenH - backdropRect.maxY, "w": backdropRect.width, "h": backdropRect.height]
        try JSONSerialization.data(withJSONObject: info).write(to: base.appendingPathComponent("ready.json"))
        let go = base.appendingPathComponent("go")
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: go.path), Date() < deadline { await wait(0.1) }
        await wait(0.4)
        var log: [String] = []
        let t0 = Date()
        HUD.shared.begin(anchor: anchor)
        mark("show listening", &log, t0)
        HUD.shared.show(.listening, engine: "Apple")
        for i in 0..<30 {
            HUD.shared.model.push(Float(0.55 + 0.35 * sin(Double(i) * 0.7)))
            await wait(0.04)
        }
        mark("writing", &log, t0)
        HUD.shared.show(.working)
        await wait(0.9)
        mark("done", &log, t0)
        HUD.shared.show(.done("Done"), hideAfter: 0.8)
        await wait(1.6)
        mark("silent press", &log, t0)
        HUD.shared.begin(anchor: anchor)
        HUD.shared.show(.listening, engine: "Apple")
        await wait(0.8)
        mark("failed", &log, t0)
        HUD.shared.show(.failed(HUDText.noSpeech), hideAfter: 0.9)
        await wait(1.7)
        mark("end", &log, t0)
        try log.joined(separator: "\n").write(to: base.appendingPathComponent("timeline.txt"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: base.appendingPathComponent("done").path, contents: Data())
        await wait(0.3)
        back.orderOut(nil)
    }
}
