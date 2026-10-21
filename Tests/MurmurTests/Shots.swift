import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Murmur

enum Shots {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_SHOTS"] == "1"
    static var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MURMUR_SHOTS_DIR"] ?? NSTemporaryDirectory(), isDirectory: true) }
}

final class InertWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct Backdrop<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
            content
        }
    }
}

@MainActor @Suite(.serialized) struct ShotTests {
    @Test(.enabled(if: Shots.enabled), .timeLimit(.minutes(10)))
    func capture() async throws {
        let base = Shots.dir
        let config = base.appendingPathComponent("config", isDirectory: true)
        Config.overrideDirectory = config
        ModelStore.overrideRoot = base.appendingPathComponent("models", isDirectory: true)
        let voiceRoot = base.appendingPathComponent("voice", isDirectory: true)
        VoiceStore.overrideRoot = voiceRoot
        for name in VoiceModelFiles.required {
            let d = VoiceStore.modelDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: d.appendingPathComponent("coremldata.bin"))
            try Data([1, 2, 3]).write(to: d.appendingPathComponent("model.mil"))
        }
        VoiceStore.shared.refresh()
        Identity.appName = "Murmur"
        Identity.version = "1.0.0 (1)"
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if let icon = NSImage(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["MURMUR_ICON"] ?? "")) {
            NSApp.applicationIconImage = icon
        }
        var cfg = Config()
        cfg.vocabulary = "Apple, Mac, Figma"
        cfg.engine = EngineID.parakeetUltra.rawValue
        cfg.speechThreshold = -46
        cfg.mainVoice = true
        Config.save(cfg)
        ModelStore.shared.refresh()

        var windows: [String: NSWindow] = [:]
        func inert(_ w: NSWindow) {
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces]
        }

        let fakeMics = MicInput(defaultID: { 1 }, nameOf: { _ in "MacBook Microphone" }, observe: { _ in })
        fakeMics.reload()
        let sample = Synth.speech(amp: 0.25)
        func fill(_ t: MicTester) {
            t.noiseDB = -58
            t.suggested = -46
            t.waveform = VoiceGate.peaks(sample, bars: 64)
            t.quality = .good
            t.transcript = "Please move the Linear ticket to done."
            t.check = CheckMic.Result(noise: -58, voice: -31, threshold: -46, verdict: .good)
            t.phase = .done
        }
        let settings = SettingsModel()
        settings.permissions = { (.authorized, true) }
        settings.input = fakeMics
        settings.refreshPermissions()
        settings.visible = true
        settings.activeTab = "animation"
        fill(settings.mic)
        let tryModel = TryModel()
        let phrase = "Please move the Linear ticket to done and ping me on Slack."
        let audio = base.appendingPathComponent("try.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", audio.path, phrase]
        try say.run(); say.waitUntilExit()
        let rec = try AudioFiles.load(audio)
        defer { rec.discard() }
        tryModel.source = String(format: "try.aiff · %.1f s", rec.duration)
        let request = TranscriptionRequest(language: .en, vocabulary: cfg.vocabularyWords, keyboardLanguages: ["en"])
        for id in ModelInfo.all.map(\.id) where ModelStore.shared.isReady(id) {
            let t0 = Date()
            let raw = (try? await EngineHub.shared.transcribe(id, rec, request)) ?? ""
            let text = await Cleaner.clean(raw, mode: .quick, vocabulary: cfg.vocabularyWords)
            tryModel.results.append(TryResult(id: id, text: text, seconds: Date().timeIntervalSince(t0), running: false))
        }

        let modelsRoot = base.appendingPathComponent("models", isDirectory: true)
        let ultra = modelsRoot.appendingPathComponent("parakeet-ultra/parakeet-ultra", isDirectory: true)
        try FileManager.default.createDirectory(at: ultra, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelMarker(id: "parakeet-ultra", bytes: 642_830_336, path: "parakeet-ultra"))
            .write(to: modelsRoot.appendingPathComponent("parakeet-ultra/.complete.json"))
        var lib = ModelLibrary()
        lib.entries["whisper-turbo"] = LibraryEntry(downloadedAt: Date(), lastUsed: nil, offloaded: true)
        lib.save(modelsRoot.appendingPathComponent(".library.json"))
        ModelStore.shared.refresh()
        settings.cfg = Config.load()

        for (index, pane) in SettingsTabs.panes.enumerated() {
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            for (id, title, symbol) in SettingsTabs.panes {
                let host = NSHostingController(rootView: SettingsView(m: settings, store: .shared, tryModel: tryModel, tab: id))
                host.sizingOptions = [.preferredContentSize]
                host.title = "Murmur — \(title)"
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.identifier = id
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let w = InertWindow(contentViewController: tabs)
            tabs.selectedTabViewItemIndex = index
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            inert(w)
            w.setFrameOrigin(NSPoint(x: 40 + CGFloat(index) * 30, y: 80))
            w.orderFrontRegardless()
            w.makeFirstResponder(nil)
            windows["settings-\(pane.0)"] = w
        }

        for step in SetupModel.Step.allCases {
            let m = SetupModel()
            m.permissions = { (true, true) }
            m.input = fakeMics
            m.reset(cfg)
            fill(m.mic)
            m.step = step.rawValue
            let w = SetupHost.makeWindow(SetupView(m: m, store: .shared, close: {}), delegate: nil)
            inert(w)
            w.setFrameOrigin(NSPoint(x: 60 + CGFloat(step.rawValue) * 30, y: 120))
            w.orderFrontRegardless()
            windows["setup-\(step.rawValue + 1)"] = w
        }

        let levels = HUDPreviewPlan.levels(at: 1.3)
        let hudView = Backdrop {
            VStack(spacing: 14) {
                HUDBubble(phase: .listening, levels: levels, paused: true)
                HUDBubble(phase: .working, paused: true)
                HUDBubble(phase: .done("Done"), paused: true)
                HUDBubble(phase: .failed(HUDText.noSpeech), paused: true)
            }
        }
        .frame(width: 560, height: 360)
        let hud = InertWindow(contentRect: NSRect(x: 200, y: 200, width: 560, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        hud.contentView = NSHostingView(rootView: hudView)
        inert(hud)
        hud.orderFrontRegardless()
        windows["in-use"] = hud


        let states: [HUDPhase] = [.listening, .working, .done("Done"), .done("Copied"),
                                  .failed(HUDText.noSpeech), .failed(HUDText.allowAccessibility("Right ⌥"))]
        let quiet = Array(repeating: Float(0), count: HUDModel.bars)
        let bubbles = Backdrop {
            VStack(alignment: .leading, spacing: 12) {
                HUDBubble(phase: .listening, levels: quiet, paused: true)
                ForEach(states.indices, id: \.self) { i in
                    HUDBubble(phase: states[i], levels: levels, paused: true)
                }
            }
        }
        .frame(width: 340, height: 420)
        let bw = InertWindow(contentRect: NSRect(x: 220, y: 160, width: 340, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        bw.contentView = NSHostingView(rootView: bubbles)
        inert(bw)
        bw.orderFrontRegardless()
        windows["check-bubbles"] = bw

        var checkRows: [NSWindow] = []
        for (i, phase) in [MicTester.Phase.idle, .quiet, .speak, .done].enumerated() {
            let t = MicTester()
            t.phase = phase
            t.countdown = 2
            t.meter = phase == .speak ? 0.62 : (phase == .quiet ? 0.08 : 0)
            if phase == .done { t.check = CheckMic.Result(noise: -55, voice: -32, threshold: -43, verdict: .good) }
            let v = Form { Section { CheckMicRow(tester: t, threshold: -45, granted: true) { _ in } } }
                .formStyle(.grouped).controlSize(.small).frame(width: 480, height: 110)
            let w = InertWindow(contentRect: NSRect(x: 260, y: 120 + CGFloat(i) * 20, width: 480, height: 110), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: v)
            inert(w)
            w.orderFrontRegardless()
            windows["check-mic-\(i)"] = w
            checkRows.append(w)
        }

        let tidyLike = RecordedShortcut(keyCode: 49, modifiers: [.control, .option])
        let active = ShortcutRecording()
        active.active = true
        let blocked = ShortcutRecording()
        blocked.problem = ShortcutCheck.system("Spotlight").message
        let recorderView = Form {
            Section {
                LabeledContent("Shortcut") { ShortcutRecorder(shortcut: .constant(defaultCustomShortcut), defaultShortcut: defaultCustomShortcut) }
                LabeledContent("Recording") { ShortcutRecorder(shortcut: .constant(nil), recording: active) }
                LabeledContent("Taken by macOS") { ShortcutRecorder(shortcut: .constant(defaultCustomShortcut), recording: blocked) }
                LabeledContent("Same as Tidy") {
                    ShortcutRecorder(shortcut: .constant(tidyLike), defaultShortcut: defaultCustomShortcut, conflicts: [(tidyLike, "Tidy")])
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .frame(width: 480, height: 250)
        let recWin = InertWindow(contentRect: NSRect(x: 240, y: 240, width: 480, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        recWin.title = "Murmur — Shortcut"
        recWin.contentView = NSHostingView(rootView: recorderView)
        inert(recWin)
        recWin.orderFrontRegardless()
        windows["recorder"] = recWin


        if ProcessInfo.processInfo.environment["MURMUR_SHOTS_DOUBLE"] == "1" {
            let m = SetupModel()
            m.permissions = { (true, true) }
            m.input = fakeMics
            var c = cfg
            c.talkKey = .doubleCommand
            m.reset(c)
            m.step = SetupModel.Step.allCases.last!.rawValue
            let w = SetupHost.makeWindow(SetupView(m: m, store: .shared, close: {}), delegate: nil)
            inert(w)
            w.setFrameOrigin(NSPoint(x: 500, y: 100))
            w.orderFrontRegardless()
            windows["check-setup-double"] = w
        }

        for (i, key) in [TalkKey.custom, TalkKey.fn, TalkKey.doubleCommand].enumerated() {
            let gm = SettingsModel()
            gm.permissions = { (.authorized, true) }
            gm.input = fakeMics
            gm.refreshPermissions()
            gm.cfg = settings.cfg
            gm.cfg.talkKey = key
            gm.cfg.hotkey = defaultCustomShortcut.storageID
            let host = NSHostingController(rootView: SettingsView(m: gm, store: .shared, tryModel: tryModel, tab: "general"))
            let w = InertWindow(contentViewController: host)
            w.styleMask = [.titled]
            w.title = "Murmur — General"
            inert(w)
            w.setFrameOrigin(NSPoint(x: 300 + CGFloat(i) * 30, y: 90))
            w.orderFrontRegardless()
            windows["check-general-\(key.rawValue)"] = w
        }

        try await Task.sleep(nanoseconds: 2_500_000_000)
        let ids = windows.mapValues { $0.windowNumber }
        let data = try JSONSerialization.data(withJSONObject: ids, options: [.sortedKeys])
        try data.write(to: base.appendingPathComponent("windows.json"))
        let doneFile = base.appendingPathComponent("captured")
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: doneFile.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        windows.values.forEach { $0.orderOut(nil) }
    }
}
