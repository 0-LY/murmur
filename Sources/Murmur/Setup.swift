import AppKit
import SwiftUI

enum MurmurSetup {
    static func merge(changes: Config, since start: Config, into current: Config) -> Config {
        var out = current
        if changes.hotkey != start.hotkey { out.hotkey = changes.hotkey }
        if changes.mode != start.mode { out.mode = changes.mode }
        if changes.engine != start.engine { out.engine = changes.engine }
        if changes.speechThreshold != start.speechThreshold { out.speechThreshold = changes.speechThreshold }
        if changes.talkKey != start.talkKey { out.talkKey = changes.talkKey }
        if changes.writing != start.writing { out.writing = changes.writing }
        return out
    }

    static func shouldOfferSetup(fresh: Bool, background: Bool) -> Bool {
        fresh && !background
    }
}

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, microphone, accessibility, engine, hotkey }

    @Published var step = 0
    @Published var forward = true
    @Published var celebrating = false
    @Published var cfg = Config()
    @Published var frames = SetupFrames()
    @Published var micGranted = MicAccess.granted
    @Published var axTrusted = Access.trusted
    @Published var useUltraWhenReady = true
    let mic = MicTester()
    var input = MicInput.shared
    var permissions: () -> (mic: Bool, ax: Bool) = { (MicAccess.granted, Access.trusted) }
    var save: (Config) -> Void = { Config.save($0) }
    var load: () -> Config = { Config.load() }
    var onFinish: () -> Void = {}
    private var start = Config()
    private var poller: Timer?

    static let count = Step.allCases.count

    var current: Step { Step(rawValue: step) ?? .welcome }

    func reset(_ start: Config) {
        self.start = start
        cfg = start
        step = 0
        forward = true
        celebrating = false
        refresh()
    }

    func refresh() {
        let p = permissions()
        micGranted = p.mic
        axTrusted = p.ax
    }

    func startPolling() {
        refresh()
        guard poller == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        poller = t
    }

    func stopPolling() {
        poller?.invalidate()
        poller = nil
    }

    func page(_ s: Int) -> SetupPage {
        let name = Identity.appName
        switch Step(rawValue: s) ?? .welcome {
        case .welcome:
            return SetupPage(title: "Welcome to \(name)",
                             subtitle: "Hold a key, say it, let go. Your words appear where your cursor is.",
                             primary: "Get Started")
        case .microphone:
            return SetupPage(title: micGranted ? "Check your microphone" : "Let \(name) hear you",
                             subtitle: micGranted ? "Check the room and say one test sentence."
                                                  : "It listens only while you hold the hotkey. Audio never leaves this Mac.",
                             primary: micGranted ? "Continue" : "Allow Microphone", back: true)
        case .accessibility:
            return SetupPage(title: "Type where your cursor is",
                             subtitle: "Accessibility lets \(name) paste the text into any app.",
                             primary: axTrusted ? "Continue" : "Allow Accessibility", back: true,
                             link: axTrusted ? nil : "Skip for now")
        case .engine:
            return SetupPage(title: "Choose how it listens",
                             subtitle: "Apple works right away. Parakeet Ultra is more accurate after a one-time download.",
                             primary: "Continue", back: true)
        case .hotkey:
            return SetupPage(title: "Pick your talk key", subtitle: "You can change these any time in Settings.",
                             primary: "Finish", back: true)
        }
    }

    func primary() {
        switch current {
        case .microphone where !micGranted:
            if MicAccess.status == .notDetermined {
                Task { _ = await MicAccess.request(); refresh() }
            } else {
                MicAccess.openSettings()
            }
        case .accessibility where !axTrusted:
            Access.request()
            Access.openSettings()
        case .hotkey:
            finish()
        default:
            go(1)
        }
    }

    func link() {
        if current == .accessibility { go(1) }
    }

    func go(_ delta: Int) {
        if current == .microphone { mic.stop() }
        forward = delta > 0
        step = max(0, min(Self.count - 1, step + delta))
    }

    func finish() {
        stopPolling()
        mic.reset()
        var changes = cfg
        if useUltraWhenReady, ModelStore.shared.isReady(.parakeetUltra), changes.engine == start.engine {
            changes.engine = EngineID.parakeetUltra.rawValue
        }
        if useUltraWhenReady, ModelStore.shared.state(.parakeetUltra).isDownloading {
            PendingEngine.value = EngineID.parakeetUltra.rawValue
        }
        save(MurmurSetup.merge(changes: changes, since: start, into: load()))
        celebrating = true
        onFinish()
    }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel
    @ObservedObject var store: ModelStore
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SetupScaffold(step: m.step, count: SetupModel.count, forward: m.forward, celebrating: m.celebrating,
                      page: { m.page($0) },
                      onPrimary: primary, onBack: { m.go(-1) }, onLink: { m.link() },
                      report: { m.frames.set($0, $1) }) { s in
            switch SetupModel.Step(rawValue: s) ?? .welcome {
            case .welcome: welcomeContent
            case .microphone:
                if m.micGranted {
                    SetupMicContent(m: m, tester: m.mic, input: m.input)
                } else {
                    statusContent(granted: false, symbol: "mic.fill", yes: "Microphone allowed", no: "Not allowed yet")
                }
            case .accessibility: statusContent(granted: m.axTrusted, symbol: "keyboard",
                                               yes: "Accessibility allowed", no: "Without it, text is copied instead")
            case .engine: engineContent
            case .hotkey: hotkeyContent
            }
        }
        .ignoresSafeArea()
        .onAppear { m.startPolling() }
        .onDisappear { m.stopPolling() }
    }

    private func primary() {
        let finishing = m.current == .hotkey
        m.primary()
        if finishing {
            DispatchQueue.main.asyncAfter(deadline: .now() + SetupHost.celebrationDuration(reduceMotion: reduceMotion)) { close() }
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            SetupBox {
                VStack(spacing: 0) {
                    feature("keyboard", "Hold the talk key", "\(TalkKeyText.keyName(m.cfg)) by default. Talk while you hold it.")
                    Divider().padding(.leading, 56)
                    feature("waveform", "Say it", "English, Ukrainian and more. Esc cancels.")
                    Divider().padding(.leading, 56)
                    feature("text.cursor", "Let go", "The text appears where your cursor is.")
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private func statusContent(granted: Bool, symbol: String, yes: String, no: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(.quaternary.opacity(0.6)).frame(width: 104, height: 104)
                Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: granted ? 54 : 40, weight: .medium))
                    .foregroundStyle(granted ? Color.green : Color(nsColor: .controlAccentColor))
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(granted ? yes : no).font(.callout.weight(.medium)).foregroundStyle(granted ? .primary : .secondary)
            Spacer(minLength: 0)
        }
    }

    private var engineContent: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            SetupBox {
                VStack(spacing: 0) {
                    engineRow(.apple)
                    Divider().padding(.leading, 14)
                    engineRow(.parakeetUltra)
                }
            }
            Toggle("Use Parakeet Ultra once it's downloaded", isOn: $m.useUltraWhenReady)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(!store.isReady(.parakeetUltra) && !store.state(.parakeetUltra).isDownloading)
            SetupWritingBlock(writing: $m.cfg.writing, engine: EngineID(rawValue: m.cfg.engine) ?? .apple)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }

    private func engineRow(_ id: EngineID) -> some View {
        let info = ModelInfo.info(id)
        let state = store.state(id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.body.weight(.medium))
                Text(info.builtIn ? "Ready now · nothing to download" : "\(info.summary) ≈ \(ModelLifecycle.sizeText(info.approxBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if info.builtIn {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                switch state {
                case .missing, .failed:
                    Button(state == .missing ? "Download" : "Retry") { store.download(id) }
                case .downloading(let p):
                    HStack(spacing: 6) {
                        ProgressView(value: p).frame(width: 80)
                        Button { store.cancel(id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
    }

    private var customShortcut: Binding<RecordedShortcut?> {
        Binding(get: { hotkeyShortcut(m.cfg.hotkey) }, set: { m.cfg.hotkey = $0?.storageID ?? "off" })
    }

    private var hotkeyContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            SetupTalkKeyBlock(cfg: $m.cfg, custom: customShortcut)
            Spacer(minLength: 0)
        }
    }
}

enum SetupColumn {
    static let width = SetupLayout.contentWidth
    static let detailHeight: CGFloat = 34
}

struct SetupWritingBlock: View {
    @Binding var writing: WritingMode
    let engine: EngineID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Words appear").font(.headline)
            EqualSegments(options: WritingMode.allCases.map { ($0, $0.short) }, selection: $writing)
                .frame(width: SetupColumn.width)
                .probe("writing")
            Text(WritingNote.text(writing, engine: engine))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .frame(width: SetupColumn.width, height: SetupColumn.detailHeight, alignment: .topLeading)
                .probe("writingDetail")
            Text("Say “comma”, “question mark” or “new line” for punctuation.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: SetupColumn.width, alignment: .leading)
        }
        .frame(width: SetupColumn.width, alignment: .leading)
    }
}

struct SetupTalkKeyBlock: View {
    @Binding var cfg: Config
    var custom: Binding<RecordedShortcut?>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Talk key").font(.headline)
                EqualSegments(options: TalkKey.allCases.map { ($0, $0.short) }, selection: $cfg.talkKey)
                    .frame(width: SetupColumn.width)
                    .probe("talkKey")
                HStack(alignment: .top, spacing: 10) {
                    Text(TalkKeyText.detail(cfg.talkKey))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    TalkKeyControl(key: cfg.talkKey, custom: custom, siblings: SiblingShortcuts.read())
                }
                .frame(width: SetupColumn.width, height: SetupColumn.detailHeight, alignment: .topLeading)
                .probe("talkDetail")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("How to talk").font(.headline)
                ZStack(alignment: .leading) {
                    EqualSegments(options: TalkMode.allCases.map { ($0, $0.name) }, selection: $cfg.mode)
                        .frame(width: SetupColumn.width)
                        .opacity(TalkModeRow.hidesControl(cfg.talkKey) ? 0 : 1)
                        .allowsHitTesting(!TalkModeRow.hidesControl(cfg.talkKey))
                        .accessibilityHidden(TalkModeRow.hidesControl(cfg.talkKey))
                    if TalkModeRow.hidesControl(cfg.talkKey) {
                        Text(TalkModeRow.note)
                            .foregroundStyle(.secondary)
                            .frame(width: SetupColumn.width, alignment: .leading)
                    }
                }
                .frame(width: SetupColumn.width, alignment: .leading)
                .probe("talkMode")
                Text("Esc cancels while you talk.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
                    .frame(width: SetupColumn.width, alignment: .leading)
            }
        }
        .frame(width: SetupColumn.width, alignment: .leading)
    }
}

@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private let model = SetupModel()
    private var window: NSWindow?
    var onFinish: () -> Void = {}

    func show() {
        model.reset(Config.load())
        model.onFinish = { [weak self] in self?.onFinish() }
        if window == nil {
            window = SetupHost.makeWindow(SetupView(m: model, store: .shared) { [weak self] in self?.window?.close() }, delegate: self)
        }
        SetupHost.bringToFront(window)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
        model.mic.reset()
    }
}

struct SetupMicContent: View {
    @ObservedObject var m: SetupModel
    @ObservedObject var tester: MicTester
    @ObservedObject var input: MicInput

    var body: some View {
        VStack(spacing: 10) {
            SetupBox {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(input.displayName).font(.body.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8).truncationMode(.middle)
                            Text("Mode: \(MicModeController.shared.modeName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        FixedButton(title: "Sound Settings…", width: 100) { MacMic.openSoundSettings() }
                        MicModeButton(modes: .shared, width: 88)
                    }
                    .padding(.horizontal, 14).frame(height: 48)
                    Divider().padding(.leading, 14)
                    HStack(spacing: 10) {
                        LevelBar(fraction: tester.meter, threshold: m.cfg.speechThreshold)
                        FixedButton(title: CheckMicRow.title(tester.phase, countdown: tester.countdown)) { tester.checkMic { m.cfg.speechThreshold = $0 } }
                            .disabled(tester.busy && !tester.checking)
                    }
                    .padding(.horizontal, 14).frame(height: 40)
                    Divider().padding(.leading, 14)
                    Toggle(isOn: MainVoiceConfirm.binding($m.cfg.mainVoice)) {
                        Text("Focus on main voice")
                    }
                    .toggleStyle(.switch)
                    .help("Experimental: drops quieter voices that sound different from the main one. Off by default.")
                    .padding(.horizontal, 14).frame(height: 36)
                }
            }
            SetupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button {
                            tester.testRecording(config: m.cfg)
                        } label: {
                            Label(tester.phase == .recording ? String(format: "Stop · %.0f s", tester.countdown.rounded(.up)) : "Say a Test Sentence",
                                  systemImage: tester.phase == .recording ? "stop.circle.fill" : "mic.circle")
                                .frame(width: 170)
                        }
                        .disabled(tester.busy && tester.phase != .recording)
                        Spacer()
                        if tester.phase == .transcribing { ProgressView().controlSize(.small) }
                        FixedButton(title: "Play Again", width: MicPaneWidths.smallButton) { tester.replay() }
                            .disabled(tester.busy || !tester.canReplay)
                            .opacity(tester.canReplay ? 1 : 0)
                    }
                    if tester.phase == .recording {
                        Waveform(levels: tester.levels, barWidth: 3, maxHeight: 18).frame(maxWidth: .infinity)
                    } else if !tester.waveform.isEmpty {
                        WaveStrip(peaks: tester.waveform).frame(height: 26)
                    }
                    if let q = tester.quality {
                        QualityBadge(quality: q)
                    } else if tester.checking {
                        Text(tester.phase == .quiet ? "Measuring the room. Stay quiet." : "Now say something in your normal voice.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let r = tester.check {
                        Text(CheckMic.summary(r)).font(.caption).foregroundStyle(r.verdict == .good ? Color.green : Color.secondary)
                    } else {
                        Text("Optional. You'll hear it back and get a quality check.").font(.caption).foregroundStyle(.secondary)
                    }
                    if tester.silentWarning {
                        Text("No sound from the microphone. Check mute and input volume.").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .onAppear { input.reload() }
        .onDisappear { tester.stop() }
    }
}
