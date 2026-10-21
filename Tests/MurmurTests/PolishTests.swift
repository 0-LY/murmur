import AppKit
import FluidAudio
import Foundation
import SwiftUI
import Testing
@testable import Murmur

struct WritingAndSoundTests {
    @Test func previewModeIsGoneAndMigratesToFinal() throws {
        #expect(WritingMode.allCases == [.final, .live])
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"writing":"preview"}"#.utf8))
        #expect(c.writing == .final)
        let live = try JSONDecoder().decode(Config.self, from: Data(#"{"writing":"live"}"#.utf8))
        #expect(live.writing == .live)
    }

    @Test func showTextIsGone() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"hudText":true,"hudSize":"small"}"#.utf8))
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!json.contains("hudText"))
        #expect(c.hudSize == "small")
    }

    @Test func volumeStepsMapAndMigrate() throws {
        #expect(SoundVolume.clamp(0) == 1 && SoundVolume.clamp(9) == 5)
        #expect(SoundVolume.migrate(legacy: "soft") == 2)
        #expect(SoundVolume.migrate(legacy: "normal") == 3)
        #expect(SoundVolume.migrate(legacy: "loud") == nil)
        let levels = SoundVolume.steps.map { SoundVolume.level($0) }
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 < $1 })
        let soft = try JSONDecoder().decode(Config.self, from: Data(#"{"soundVolume":"soft"}"#.utf8))
        #expect(soft.volume == 2)
        let fresh = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(fresh.volume == 3)
        let wild = try JSONDecoder().decode(Config.self, from: Data(#"{"volume":42}"#.utf8))
        #expect(wild.volume == 5)
    }

    @Test func loudnessTargets() throws {
        let peak = try SoundSet.allCases.map { set in
            try SoundFileTests.samples(set.file(start: true)).data.map(abs).max() ?? 0
        }.max() ?? 0
        let oldNormal: Float = 0.8 * 0.2
        #expect(SoundVolume.level(3) * peak > oldNormal)
        let loudest = 20 * log10(Double(SoundVolume.level(5) * peak))
        #expect(loudest <= -6.0 + 0.05)
    }

    @Test func startAndStopSwitches() {
        var c = Config()
        #expect(Sounds.plays(c, start: true) && Sounds.plays(c, start: false))
        c.startSound = false
        #expect(!Sounds.plays(c, start: true) && Sounds.plays(c, start: false))
        c.sounds = false
        #expect(!Sounds.plays(c, start: false))
    }

    @Test func bothSwitchesOffMeansSoundsOff() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"sounds":true,"startSound":false,"stopSound":false}"#.utf8))
        #expect(!c.sounds && c.startSound && c.stopSound)
    }

    @Test func bubbleNeverShowsSpokenText() {
        #expect(HUDLabel.text(for: .listening) == nil)
        #expect(HUDLabel.text(for: .working) == nil)
        #expect(HUDLabel.text(for: .done("Done")) == nil)
        #expect(HUDLabel.text(for: .done("Copied")) == "Copied")
        #expect(HUDLabel.text(for: .failed(HUDText.noSpeech)) == HUDText.noSpeech)
    }

    @Test func setupMergeKeepsOtherSettings() {
        let start = Config()
        var changes = start
        changes.speechThreshold = -40
        var current = Config()
        current.volume = 5
        let out = MurmurSetup.merge(changes: changes, since: start, into: current)
        #expect(out.speechThreshold == -40 && out.volume == 5)
    }

    @Test func writingNoteForWhisper() {
        #expect(WritingNote.text(.live, engine: .whisperTurbo).contains("can't write live"))
        #expect(WritingNote.text(.final, engine: .whisperTurbo) == WritingMode.final.detail)
    }
}

@MainActor final class FrameBox {
    var frames: [String: CGRect] = [:]
}

@MainActor
func probeFrames<V: View>(_ view: V, size: CGSize) async -> [String: CGRect] {
    let box = FrameBox()
    let root = view
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named("probe"))
        .environment(\.layoutReport, { id, r in box.frames[id] = r })
    let host = NSHostingView(rootView: root)
    let w = InertWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    w.ignoresMouseEvents = true
    w.contentView = host
    for _ in 0..<12 {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    w.contentView = nil
    return box.frames
}

@MainActor @Suite(.serialized) struct LayoutStabilityTests {
    let ids = ["talkKey", "talkDetail", "talkMode"]

    @Test func setupTalkKeyBlockDoesNotMove() async {
        var seen: [[String: CGRect]] = []
        for key in TalkKey.allCases {
            var cfg = Config()
            cfg.talkKey = key
            cfg.hotkey = defaultCustomShortcut.storageID
            let view = SetupTalkKeyBlock(cfg: .constant(cfg), custom: .constant(defaultCustomShortcut))
            seen.append(await probeFrames(view, size: CGSize(width: SetupLayout.contentWidth, height: SetupLayout.contentHeight)))
        }
        for id in ids {
            let frames = seen.compactMap { $0[id] }
            #expect(frames.count == TalkKey.allCases.count, "missing \(id)")
            #expect(Set(frames.map { "\($0)" }).count == 1, "\(id) moved: \(frames)")
        }
    }

    @Test func setupWritingBlockDoesNotMove() async {
        var seen: [[String: CGRect]] = []
        for mode in WritingMode.allCases {
            for engine in [EngineID.apple, .whisperTurbo] {
                let view = SetupWritingBlock(writing: .constant(mode), engine: engine)
                seen.append(await probeFrames(view, size: CGSize(width: SetupLayout.contentWidth, height: 120)))
            }
        }
        for id in ["writing", "writingDetail"] {
            let frames = seen.compactMap { $0[id] }
            #expect(frames.count == WritingMode.allCases.count * 2, "missing \(id)")
            #expect(Set(frames.map { "\($0)" }).count == 1, "\(id) moved: \(frames)")
        }
    }

    @Test func settingsTalkKeyRowsDoNotMove() async {
        var seen: [[String: CGRect]] = []
        for key in TalkKey.allCases {
            var cfg = Config()
            cfg.talkKey = key
            cfg.hotkey = defaultCustomShortcut.storageID
            let view = Form { Section { TalkKeyRows(cfg: .constant(cfg), custom: .constant(defaultCustomShortcut)) } }
                .formStyle(.grouped)
                .controlSize(.small)
            seen.append(await probeFrames(view, size: CGSize(width: 480, height: 260)))
        }
        for id in ids {
            let frames = seen.compactMap { $0[id] }
            #expect(frames.count == TalkKey.allCases.count, "missing \(id)")
            #expect(Set(frames.map { "\(Int($0.minY)) \(Int($0.height))" }).count == 1, "\(id) moved: \(frames)")
        }
    }

    @Test func settingsWritingRowDoesNotMove() async {
        var seen: [[String: CGRect]] = []
        for mode in WritingMode.allCases {
            for engine in [EngineID.apple, .whisperTurbo] {
                let view = Form { Section { WritingModeRow(mode: .constant(mode), engine: engine) } }
                    .formStyle(.grouped)
                    .controlSize(.small)
                seen.append(await probeFrames(view, size: CGSize(width: 480, height: 160)))
            }
        }
        for id in ["writing", "writingDetail"] {
            let frames = seen.compactMap { $0[id] }
            #expect(frames.count == WritingMode.allCases.count * 2, "missing \(id)")
            #expect(Set(frames.map { "\($0)" }).count == 1, "\(id) moved: \(frames)")
        }
    }
}

enum SpeakerBench {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_SPEAKER"] == "1"
    static var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MURMUR_SPEAKER_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)
    }

    static func say(_ voice: String, _ text: String, to url: URL) throws -> [Float] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, text]
        try p.run()
        p.waitUntilExit()
        return try AudioFiles.readSamples(url)
    }
}

