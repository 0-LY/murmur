import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Murmur

@Suite struct StableCommitTests {
    @Test func commitsOnlyWordsTwoHypothesesAgreeOn() {
        var c = StableCommitter()
        #expect(c.update("Please") == "")
        #expect(c.update("Please move") == "Please")
        #expect(c.update("Please move the") == " move")
        #expect(c.update("Please move the Linear") == " the")
        #expect(c.typedText == "Please move the")
    }

    @Test func recordedSequenceNeverDeletesAndEndsWithFinal() {
        let hyps = ["Please", "Please moved", "Please move the", "Please move the linear", "Please move the Linear ticket",
                    "Please move the Linear ticket to", "Please move the Linear ticket to done"]
        var c = StableCommitter()
        var typed = ""
        var previous: [String] = []
        for h in hyps {
            typed += c.update(h)
            #expect(Array(c.typed.prefix(previous.count)) == previous)
            previous = c.typed
        }
        typed += c.flush("Please move the Linear ticket to done.")
        #expect(typed == "Please move the Linear ticket to done.")
        #expect(c.typedText == typed)
    }

    @Test func finalizedWordsCommitImmediately() {
        var c = StableCommitter()
        #expect(c.update("Hello there", finalWords: 2) == "Hello there")
        #expect(c.update("Hello there friend", finalWords: 2) == "")
        #expect(c.flush("Hello there friend.") == " friend.")
    }

    @Test func changedMindBeforeCommitDoesNotDuplicate() {
        var c = StableCommitter()
        _ = c.update("I think we")
        _ = c.update("I think we")
        #expect(c.typedText == "I think")
        _ = c.update("I think we should ship")
        _ = c.update("I think we should ship")
        #expect(c.typedText == "I think we should")
        #expect(c.flush("I think we should ship the beta on Friday.") == " ship the beta on Friday.")
    }

    @Test func divergentEarlierWordIsKeptAndTailAligned() {
        var c = StableCommitter()
        _ = c.update("Open fig ma and")
        _ = c.update("Open fig ma and share")
        #expect(c.typedText == "Open fig ma and")
        let tail = c.flush("Open Figma and share the new design.")
        #expect(tail == " share the new design.")
    }

    @Test func flushWithNothingTypedTypesAll() {
        var c = StableCommitter()
        #expect(c.flush("Привіт, я працюю з дому.") == "Привіт, я працюю з дому.")
        #expect(c.flush("Привіт, я працюю з дому.") == "")
    }

    @Test func alignmentPicksEndOfTypedWords() {
        #expect(LiveWords.alignEnd(typed: ["a", "b"], in: ["a", "b", "c", "d"]) == 2)
        #expect(LiveWords.alignEnd(typed: [], in: ["a"]) == 0)
        #expect(LiveWords.alignEnd(typed: ["Hello,", "world"], in: ["hello", "world!", "again"]) == 2)
    }
}

@Suite struct LiveRuleTests {
    @Test func focusChangeAborts() {
        #expect(LiveSupport.shouldAbort(samePid: true, sameField: true, ownAppFront: false) == false)
        #expect(LiveSupport.shouldAbort(samePid: false, sameField: true, ownAppFront: false))
        #expect(LiveSupport.shouldAbort(samePid: true, sameField: false, ownAppFront: false))
        #expect(LiveSupport.shouldAbort(samePid: true, sameField: true, ownAppFront: true))
    }

    @Test func modeFallbacks() {
        #expect(LiveSupport.effectiveMode(.live, engine: .parakeetUltra, trusted: true, insert: .paste) == .live)
        #expect(LiveSupport.effectiveMode(.live, engine: .apple, trusted: true, insert: .paste) == .live)
        #expect(LiveSupport.effectiveMode(.live, engine: .whisperTurbo, trusted: true, insert: .paste) == .final)
        #expect(LiveSupport.effectiveMode(.live, engine: .apple, trusted: false, insert: .paste) == .final)
        #expect(LiveSupport.effectiveMode(.live, engine: .apple, trusted: true, insert: .copy) == .final)
        #expect(LiveSupport.effectiveMode(.final, engine: .apple, trusted: true, insert: .paste) == .final)
    }

    @Test func restAfterAbortIsUntypedTail() {
        #expect(LiveSupport.rest(after: ["Please", "move"], in: "Please move the ticket.") == "the ticket.")
        #expect(LiveSupport.rest(after: [], in: "All of it") == "All of it")
    }

    @Test func terminalTypingIsFlat() {
        let shaped = LiveSupport.shapeForTyping("ls\n-la\u{1b}[31m", bundleId: "com.googlecode.iterm2")
        #expect(!shaped.contains("\n"))
        #expect(!shaped.unicodeScalars.contains { $0.value == 0x1b })
        #expect(LiveSupport.shapeForTyping("a\nb", bundleId: "com.apple.TextEdit") == "a\nb")
    }

    @Test func leadingSpaceOnlyAfterText() {
        #expect(LiveSupport.needsSpace(before: "Hello", cursor: 5))
        #expect(!LiveSupport.needsSpace(before: "Hello ", cursor: 6))
        #expect(!LiveSupport.needsSpace(before: "", cursor: 0))
        #expect(!LiveSupport.needsSpace(before: "(", cursor: 1))
    }

}

@Suite struct TalkKeyTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    @Test func rightOptionHoldPressesAndReleases() {
        var g = ModifierGesture(key: .rightOption)
        #expect(g.flagsChanged(code: 61, flags: 0x80040, at: t0) == .press)
        #expect(g.flagsChanged(code: 61, flags: 0x80040, at: t0) == .none)
        #expect(g.flagsChanged(code: 61, flags: 0, at: t0.addingTimeInterval(1)) == .release)
    }

    @Test func leftOptionIsIgnored() {
        var g = ModifierGesture(key: .rightOption)
        #expect(g.flagsChanged(code: 58, flags: 0x80020, at: t0) == .none)
        #expect(g.flagsChanged(code: 61, flags: 0x80020, at: t0) == .none)
    }

    @Test func chordWithOtherKeyCancels() {
        var g = ModifierGesture(key: .rightOption)
        #expect(g.flagsChanged(code: 61, flags: 0x80040, at: t0) == .press)
        #expect(g.otherKey(at: t0.addingTimeInterval(0.1)) == .cancel)
        #expect(g.flagsChanged(code: 61, flags: 0, at: t0.addingTimeInterval(0.3)) == .none)
        #expect(g.otherKey() == .none)
    }

    @Test func fnHold() {
        var g = ModifierGesture(key: .fn)
        let fn = NSEvent.ModifierFlags.function.rawValue
        #expect(g.flagsChanged(code: 63, flags: fn, at: t0) == .press)
        #expect(g.flagsChanged(code: 63, flags: 0, at: t0.addingTimeInterval(0.8)) == .release)
    }

    @Test func doubleTapRightCommandToggles() {
        var g = ModifierGesture(key: .doubleCommand)
        #expect(g.flagsChanged(code: 54, flags: 0x100010, at: t0) == .none)
        #expect(g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(0.1)) == .none)
        #expect(g.flagsChanged(code: 54, flags: 0x100010, at: t0.addingTimeInterval(0.25)) == .toggle)
        #expect(g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(0.33)) == .none)
    }

    @Test func doubleTapStopsOnSecondKeyDownToo() {
        var g = ModifierGesture(key: .doubleCommand)
        _ = g.flagsChanged(code: 54, flags: 0x100010, at: t0)
        _ = g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(0.1))
        #expect(g.flagsChanged(code: 54, flags: 0x100010, at: t0.addingTimeInterval(0.2)) == .toggle)
        _ = g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(0.28))
        _ = g.flagsChanged(code: 54, flags: 0x100010, at: t0.addingTimeInterval(3.0))
        _ = g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(3.1))
        #expect(g.flagsChanged(code: 54, flags: 0x100010, at: t0.addingTimeInterval(3.2)) == .toggle)
    }

    @Test func slowTapsDoNotToggle() {
        var g = ModifierGesture(key: .doubleCommand)
        _ = g.flagsChanged(code: 54, flags: 0x100010, at: t0)
        _ = g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(0.1))
        _ = g.flagsChanged(code: 54, flags: 0x100010, at: t0.addingTimeInterval(0.9))
        #expect(g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(1.0)) == .none)
    }

    @Test func commandShortcutBetweenTapsDoesNotToggle() {
        var g = ModifierGesture(key: .doubleCommand)
        _ = g.flagsChanged(code: 54, flags: 0x100010, at: t0)
        _ = g.otherKey(at: t0.addingTimeInterval(0.05))
        _ = g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(0.1))
        _ = g.flagsChanged(code: 54, flags: 0x100010, at: t0.addingTimeInterval(0.2))
        #expect(g.flagsChanged(code: 54, flags: 0, at: t0.addingTimeInterval(0.25)) == .none)
    }

    @Test func leftCommandIsIgnored() {
        var g = ModifierGesture(key: .doubleCommand)
        for i in 0..<4 {
            #expect(g.flagsChanged(code: 55, flags: i % 2 == 0 ? 0x100008 : 0, at: t0.addingTimeInterval(Double(i) * 0.1)) == .none)
        }
    }
}

@Suite struct ShortcutTests {
    @Test func needsModifierUnlessFunctionKey() {
        #expect(ShortcutRules.check(RecordedShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [])) == .needsModifier)
        #expect(ShortcutRules.check(RecordedShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: .shift)) == .needsModifier)
        #expect(ShortcutRules.check(RecordedShortcut(keyCode: UInt16(kVK_F5), modifiers: [])) == .ok)
        #expect(ShortcutRules.check(RecordedShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])) == .ok)
    }

    @Test func systemShortcutsBlock() {
        let spotlight = ShortcutRules.check(RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: .command))
        #expect(spotlight == .system("Spotlight"))
        #expect(spotlight.blocks)
        #expect(ShortcutRules.check(RecordedShortcut(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift])) == .system("screenshots"))
        #expect(ShortcutRules.check(RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: .control)).blocks)
    }

    @Test func siblingConflictWarnsButAllows() {
        let tidy = RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option, .shift])
        let check = ShortcutRules.check(tidy, conflicts: [(tidy, "Tidy")])
        #expect(check == .conflict("Tidy"))
        #expect(!check.blocks)
    }

    @Test func storageRoundTripAndDisplay() {
        let s = RecordedShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: [.control, .option, .capsLock])
        #expect(RecordedShortcut(storageID: s.storageID) == s)
        #expect(s.display == "⌃⌥D")
        #expect(s.carbonModifiers == controlKey | optionKey)
        #expect(RecordedShortcut(storageID: "ctrl-opt-v") == nil)
    }

    @Test func parsesSiblingConfigIds() {
        #expect(ShortcutRules.parse("ctrl-opt-space") == RecordedShortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option]))
        #expect(ShortcutRules.parse("opt-cmd-m") == RecordedShortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.option, .command]))
        #expect(ShortcutRules.parse("off") == nil)
        #expect(ShortcutRules.parse("wat-x") == nil)
    }

    @Test func siblingsReadFromConfigFiles() throws {
        let home = try scratch("siblings")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".config/tidy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"hotkey":"ctrl-opt-space"}"#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let list = SiblingShortcuts.read(home: home)
        #expect(list.count == 1)
        #expect(list.first?.1 == "Tidy")
    }

    @Test func presetHotkeysMapToShortcuts() {
        #expect(hotkeyShortcut("ctrl-opt-v") == defaultCustomShortcut)
        #expect(hotkeyShortcut("off") == nil)
        let custom = RecordedShortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .option])
        #expect(hotkeyShortcut(custom.storageID) == custom)
        #expect(hotkeyName(custom.storageID) == "⌥⌘J")
    }
}

@Suite struct NewConfigTests {
    @Test func existingHotkeyKeepsCustomAndNewInstallsGetRightOption() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"hotkey":"ctrl-opt-v","mode":"hold"}"#.utf8))
        #expect(old.talkKey == .custom)
        #expect(old.hotkey == "ctrl-opt-v")
        let fresh = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(fresh.talkKey == .rightOption)
        #expect(Config().talkKey == .rightOption)
    }

    @Test func defaultsForWritingStyleAndSounds() {
        let c = Config()
        #expect(c.writing == .final)
        #expect(c.sounds && c.startSound && c.stopSound)
        #expect(c.soundSet == .bubble)
        #expect(c.volume == 3)
        #expect(!c.mainVoice)
    }

    @Test func badSoundSetFallsBack() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"soundSet":"Nope","writing":"weird"}"#.utf8))
        #expect(c.soundSet == .bubble)
        #expect(c.writing == .final)
    }

    @Test func legacySoundSwitchesCarryOver() throws {
        let off = try JSONDecoder().decode(Config.self, from: Data(#"{"startSoundOn":false,"stopSoundOn":false,"startSound":"Tink"}"#.utf8))
        #expect(!off.sounds)
        let half = try JSONDecoder().decode(Config.self, from: Data(#"{"startSoundOn":false,"stopSoundOn":true}"#.utf8))
        #expect(half.sounds)
        let none = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(none.sounds && none.soundSet == .bubble)
        let onlyStop = try JSONDecoder().decode(Config.self, from: Data(#"{"startSoundOn":false,"stopSoundOn":true}"#.utf8))
        #expect(!onlyStop.startSound && onlyStop.stopSound)
    }

    @Test func orbStyleIsGone() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"hudStyle":"orb","orb":"weaving","hudSize":"large"}"#.utf8))
        #expect(c.hudSize == "large")
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!json.contains("orb") && !json.contains("hudStyle") && !json.contains("Tink"))
    }

    @Test func roundTripKeepsNewFields() throws {
        var c = Config()
        c.talkKey = .doubleCommand
        c.writing = .live
        c.sounds = false
        c.volume = 5
        c.startSound = false
        c.mainVoice = false
        c.soundSet = .bubble
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    @Test func setupMergesTalkKeyAndWriting() {
        let start = Config()
        var changes = start
        changes.talkKey = .fn
        changes.writing = .final
        var current = Config()
        current.soundSet = .soft
        let out = MurmurSetup.merge(changes: changes, since: start, into: current)
        #expect(out.talkKey == .fn)
        #expect(out.writing == .final)
        #expect(out.soundSet == .soft)
    }

    @Test func hintsPerTalkKey() {
        var c = Config()
        #expect(TalkKeyText.hint(c) == "Hold Right ⌥ to talk")
        c.talkKey = .doubleCommand
        #expect(TalkKeyText.hint(c) == "Double-tap Right ⌘ to talk")
        c.talkKey = .custom
        c.hotkey = "off"
        #expect(TalkKeyText.hint(c) == nil)
    }

    @Test func soundFileNames() {
        #expect(SoundSet.deep.file(start: true) == "deep-start")
        #expect(SoundSet.bubble.file(start: false) == "bubble-stop")
    }

    @Test func previewLevelsHaveBarCount() {
        #expect(HUDPreviewPlan.levels(at: 1.0).count == HUDModel.bars)
    }
}
