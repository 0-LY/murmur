import AppKit
import Foundation
import Testing
@testable import Murmur

@Suite struct SpokenPunctuationTests {
    func p(_ s: String) -> String { SpokenPunctuation.apply(s) }

    @Test func everyEnglishCommand() {
        #expect(p("are you ready question mark") == "are you ready?")
        #expect(p("wow exclamation mark") == "wow!")
        #expect(p("wow exclamation point") == "wow!")
        #expect(p("note colon buy milk") == "note: buy milk")
        #expect(p("first semicolon second") == "first; second")
        #expect(p("first semi colon second") == "first; second")
        #expect(p("apples comma pears") == "apples, pears")
        #expect(p("this is done period") == "this is done.")
        #expect(p("this is done full stop") == "this is done.")
        #expect(p("this is done dot") == "this is done.")
        #expect(p("wait dash what") == "wait — what")
        #expect(p("well hyphen known") == "well-known")
        #expect(p("she said open quote hello close quote") == "she said “hello”")
        #expect(p("she said quote hi quote") == "she said “hi”")
        #expect(p("call me open bracket later close bracket") == "call me (later)")
        #expect(p("call me open parenthesis later close parenthesis") == "call me (later)")
        #expect(p("line one new line line two") == "line one\nLine two")
        #expect(p("part one new paragraph part two") == "part one\n\nPart two")
        #expect(p("and then ellipsis") == "and then…")
    }

    @Test func everyUkrainianCommand() {
        #expect(p("ти готовий знак питання") == "ти готовий?")
        #expect(p("ура знак оклику") == "ура!")
        #expect(p("список двокрапка молоко") == "список: молоко")
        #expect(p("перше крапка з комою друге") == "перше; друге")
        #expect(p("яблука кома груші") == "яблука, груші")
        #expect(p("готово крапка") == "готово.")
        #expect(p("стоп тире що") == "стоп — що")
        #expect(p("темно дефіс синій") == "темно-синій")
        #expect(p("він сказав відкрити лапки привіт закрити лапки") == "він сказав «привіт»")
        #expect(p("подзвони відкрити дужку пізніше закрити дужку") == "подзвони (пізніше)")
        #expect(p("рядок один новий рядок рядок два") == "рядок один\nРядок два")
        #expect(p("рядок один з нового рядка рядок два") == "рядок один\nРядок два")
        #expect(p("частина один новий абзац частина два") == "частина один\n\nЧастина два")
        #expect(p("і далі три крапки") == "і далі…")
    }

    @Test func capitalizesAfterSentenceEnd() {
        #expect(p("done period next one") == "done. Next one")
        #expect(p("ready question mark yes exclamation mark go") == "ready? Yes! Go")
    }

    @Test func phraseUseStaysWords() {
        #expect(p("the colon of the text") == "the colon of the text")
        #expect(p("кома в реченні") == "кома в реченні")
        #expect(p("add a dash of salt") == "add a dash of salt")
        #expect(p("there is a question mark over it") == "there is a question mark over it")
        #expect(p("a period of time") == "a period of time")
        #expect(p("go to example dot com") == "go to example dot com")
    }

    @Test func enginePunctuationIsReplaced() {
        #expect(p("How are you, question mark.") == "How are you?")
        #expect(p("Hello. Comma. World") == "Hello, World")
        #expect(p("Ready. Question mark? Yes.") == "Ready? Yes.")
        #expect(p("Done. New line. Next.") == "Done\nNext.")
    }

    @Test func multipleCommandsInARow() {
        #expect(p("really question mark exclamation mark") == "really?!")
        #expect(p("end period new line") == "end.\n")
        #expect(p("wait dot dot") == "wait dot.")
    }

    @Test func mixedLanguages() {
        #expect(p("check the Linear ticket кома потім Figma question mark") == "check the Linear ticket, потім Figma?")
    }

    @Test func untouchedWithoutCommands() {
        let s = "Nothing to change here, really."
        #expect(p(s) == s)
    }

    @Test func pipelineAppliesWhenOnAndSkipsWhenOff() async throws {
        let audio = PipelineFixtures.padded(PipelineFixtures.tone(seconds: 1.2, dbfs: -24), silence: 0.4)
        var cfg = Config()
        cfg.cleanup = .off
        let on = try await DictationPipeline.run(audio, duration: 2.0, cfg: cfg, filter: { $0 },
                                                 transcribe: { _ in "are you ready question mark" })
        #expect(on == .text("are you ready?"))
        cfg.spokenPunctuation = false
        let off = try await DictationPipeline.run(audio, duration: 2.0, cfg: cfg, filter: { $0 },
                                                  transcribe: { _ in "are you ready question mark" })
        #expect(off == .text("are you ready question mark"))
    }

    @Test func pipelineKeepsTrailingLineBreakThroughCleanup() async throws {
        let audio = PipelineFixtures.padded(PipelineFixtures.tone(seconds: 1.2, dbfs: -24), silence: 0.4)
        var cfg = Config()
        cfg.cleanup = .off
        let r = try await DictationPipeline.run(audio, duration: 2.0, cfg: cfg, filter: { $0 },
                                                transcribe: { _ in "first item new line" })
        #expect(r == .text("first item\n"))
    }

    @Test func cleanupRejectsOutputThatDropsSymbols() {
        #expect(!CleanupRules.accept(input: "Ready? Go: now", output: "Ready question mark go now"))
        #expect(CleanupRules.accept(input: "ready? go: now", output: "Ready? Go: now."))
        #expect(!CleanupRules.accept(input: "one\ntwo three four", output: "One two three four."))
    }

    @Test func preambleQuotesKeptWhenDictated() {
        #expect(CleanupRules.stripPreamble("“Hello there”", input: "“hello there”") == "“Hello there”")
        #expect(CleanupRules.stripPreamble("“Hello there”", input: "hello there") == "Hello there")
    }

    @Test func defaultIsOnAndOldConfigsGetIt() throws {
        #expect(Config().spokenPunctuation)
        let old = try JSONDecoder().decode(Config.self, from: Data("{\"engine\":\"apple\"}".utf8))
        #expect(old.spokenPunctuation)
        let off = try JSONDecoder().decode(Config.self, from: Data("{\"spokenPunctuation\":false}".utf8))
        #expect(!off.spokenPunctuation)
    }
}

@Suite struct LivePunctuationTests {
    func run(_ hyps: [String], final: String) -> String {
        var c = StableCommitter()
        var lp = LivePunctuator()
        var typed = ""
        for h in hyps {
            _ = c.update(h)
            typed += lp.feed(c.typed)
        }
        _ = c.flush(final)
        typed += lp.finish(c.typed)
        return typed
    }

    func growing(_ text: String) -> [String] {
        let w = text.split(separator: " ").map(String.init)
        return (1...w.count).map { w.prefix($0).joined(separator: " ") }
    }

    @Test func liveCommitMatchesFinalConversion() {
        let cases = [
            "are you ready question mark yes exclamation mark",
            "note colon buy milk comma eggs new line call mom",
            "ти готовий знак питання так кома звісно",
            "the colon of the text stays",
            "first item new paragraph second item period",
        ]
        for s in cases {
            #expect(run(growing(s), final: s) == SpokenPunctuation.apply(s))
        }
    }

    @Test func neverTypesAHalfCommand() {
        var c = StableCommitter()
        var lp = LivePunctuator()
        var typed = ""
        for h in growing("are you ready question mark and more words here") {
            _ = c.update(h)
            typed += lp.feed(c.typed)
            #expect(!typed.hasSuffix("question"))
            #expect(!typed.contains("question mark"))
        }
    }

    @Test func liveOutputOnlyGrows() {
        var c = StableCommitter()
        var lp = LivePunctuator()
        var typed = ""
        for h in growing("one comma two comma three period four new line five") {
            _ = c.update(h)
            let before = typed
            typed += lp.feed(c.typed)
            #expect(typed.hasPrefix(before))
        }
    }

    @Test func safeCountHoldsPossibleCommandStarts() {
        #expect(LivePunctuator.safeCount(["a", "b", "c", "d"]) == 2)
        #expect(LivePunctuator.safeCount(["a", "b", "c", "question"]) == 2)
        #expect(LivePunctuator.safeCount(["a", "b", "question", "mark"]) == 1)
        #expect(LivePunctuator.safeCount(["a", "крапка", "з", "комою"]) == 0)
    }

    @Test func terminalLiveTypingFlattensBreaks() {
        let text = SpokenPunctuation.apply("ls new line pwd")
        #expect(text == "ls\nPwd")
        #expect(LiveSupport.shapeForTyping(text, bundleId: "com.apple.Terminal") == "ls Pwd")
        #expect(LiveSupport.shapeForTyping(text, bundleId: "com.apple.TextEdit") == "ls\nPwd")
    }
}

enum SpokenBench {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_SPOKEN"] == "1"
}

@Suite(.serialized) struct SpokenAudioTests {
    @MainActor @Test(.enabled(if: SpokenBench.enabled), .timeLimit(.minutes(20)))
    func generatedPhrasesThroughPipeline() async throws {
        let phrases: [(String, String, SpeechLanguage, String)] = [
            ("Samantha", "are you ready question mark", .en, "are you ready?"),
            ("Samantha", "buy milk comma eggs comma and bread period", .en, "buy milk, eggs, and bread."),
            ("Samantha", "note colon call the team new line send the report", .en, "note: call the team\nsend the report"),
            ("Samantha", "this is great exclamation mark", .en, "this is great!"),
            ("Lesya", "ти готовий знак питання", .uk, "ти готовий?"),
            ("Lesya", "купи молоко кома хліб крапка", .uk, "купи молоко, хліб."),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("murmur-spoken", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = EngineHub(store: ModelStore(root: dir.appendingPathComponent("models", isDirectory: true)))
        var lines = ["voice\tsaid\traw\tresult\texpected\tmatch"]
        for (i, ph) in phrases.enumerated() {
            let url = dir.appendingPathComponent("p\(i).aiff")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            proc.arguments = ["-v", ph.0, "-o", url.path, ph.1]
            try proc.run()
            proc.waitUntilExit()
            let samples = try AudioFiles.readSamples(url)
            var cfg = Config()
            cfg.cleanup = .off
            cfg.language = ph.2
            var raw = ""
            let r = try await DictationPipeline.run(samples + [Float](repeating: 0, count: 8000), duration: Double(samples.count) / 16_000 + 0.5,
                                                    cfg: cfg, filter: { $0 }) { rec in
                raw = try await hub.transcribe(.apple, rec, TranscriptionRequest(language: ph.2, vocabulary: [], keyboardLanguages: ["en", "uk"]))
                return raw
            }
            var result = ""
            if case .text(let t) = r { result = t }
            let norm = { (s: String) in s.lowercased().replacingOccurrences(of: "\n", with: " / ") }
            lines.append([ph.0, ph.1, norm(raw), norm(result), norm(ph.3), norm(result) == norm(ph.3) ? "yes" : "no"].joined(separator: "\t"))
        }
        let out = ProcessInfo.processInfo.environment["MURMUR_SPOKEN_OUT"] ?? NSTemporaryDirectory() + "murmur-spoken.tsv"
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}
