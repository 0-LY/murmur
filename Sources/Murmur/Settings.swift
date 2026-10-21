import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsModel: ObservableObject {
    @Published var cfg = Config.load()
    @Published var micGranted = MicAccess.granted
    @Published var micStatus = MicAccess.status
    @Published var axTrusted = Access.trusted
    @Published var visible = false
    @Published var activeTab = "general"
    let mic = MicTester()
    var input = MicInput.shared
    var permissions: () -> (mic: AVAuthorizationStatus, ax: Bool) = { (MicAccess.status, Access.trusted) }
    var onChange: () -> Void = {}
    var runSetup: () -> Void = {}
    private var saver: AnyCancellable?
    private var poller: Timer?

    init() {
        saver = $cfg.dropFirst().removeDuplicates().sink { [weak self] new in
            DispatchQueue.main.async {
                guard let self, self.cfg == new else { return }
                Config.save(new)
                self.onChange()
            }
        }
    }

    func refreshPermissions() {
        let p = permissions()
        micStatus = p.mic
        micGranted = p.mic == .authorized
        axTrusted = p.ax
    }

    func startPolling() {
        refreshPermissions()
        guard poller == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        poller = t
    }

    func stopPolling() {
        poller?.invalidate()
        poller = nil
    }

    func allowMicrophone() {
        if micStatus == .notDetermined {
            Task { _ = await MicAccess.request(); refreshPermissions() }
        } else {
            MicAccess.openSettings()
        }
    }

    func allowAccessibility() {
        Access.request()
        Access.openSettings()
    }
}

struct TryResult: Identifiable, Equatable {
    let id: EngineID
    var text: String
    var seconds: Double?
    var running: Bool
}

@MainActor
final class TryModel: ObservableObject {
    @Published var results: [TryResult] = []
    @Published var recording = false
    @Published var busy = false
    @Published var source = ""
    @Published var level: Float = 0
    private let recorder = Recorder()

    init() {
        recorder.onLevel = { [weak self] in self?.level = $0 }
    }

    func toggleRecording() {
        if recording {
            let samples = recorder.stop()
            recording = false
            level = 0
            guard samples.count > Int(Recording.sampleRate * DictationRules.minimumDuration) else { return }
            guard let rec = try? AudioFiles.recording(from: samples) else { return }
            source = String(format: "Your recording · %.1f s", rec.duration)
            run(rec)
        } else {
            guard MicAccess.granted else {
                Task {
                    if await MicAccess.request() { toggleRecording() } else { MicAccess.openSettings() }
                }
                return
            }
            do {
                try recorder.start()
                recording = true
            } catch {
                recording = false
            }
        }
    }

    func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        p.prompt = "Transcribe"
        guard p.runModal() == .OK, let url = p.url, let rec = try? AudioFiles.load(url) else { return }
        source = String(format: "%@ · %.1f s", url.lastPathComponent, rec.duration)
        run(rec)
    }

    func stop() {
        if recording { _ = recorder.stop() }
        recording = false
        level = 0
    }

    private func run(_ rec: Recording) {
        let cfg = Config.current
        let engines = ModelInfo.all.map(\.id).filter { ModelStore.shared.isReady($0) }
        results = engines.map { TryResult(id: $0, text: "", seconds: nil, running: true) }
        busy = true
        Task { @MainActor in
            defer { rec.discard(); busy = false }
            let request = TranscriptionRequest(language: cfg.language, vocabulary: cfg.vocabularyWords,
                                               keyboardLanguages: keyboardLanguages())
            for id in engines {
                let t0 = Date()
                var text: String
                do {
                    let raw = try await EngineHub.shared.transcribe(id, rec, request)
                    text = await Cleaner.clean(raw, mode: cfg.cleanup, vocabulary: cfg.vocabularyWords)
                    if text.isEmpty { text = "—" }
                } catch {
                    text = (error as? LocalizedError)?.errorDescription ?? "Failed"
                }
                if let i = results.firstIndex(where: { $0.id == id }) {
                    results[i] = TryResult(id: id, text: text, seconds: Date().timeIntervalSince(t0), running: false)
                }
            }
        }
    }
}

var appVersion: String { "\(Identity.appName) \(Identity.version)" }

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var compact = false
    var urgent = false
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: action)
                    .tint(urgent ? .red : nil)
            }
        } label: {
            Text(title).foregroundStyle(urgent ? .red : .primary)
            if !compact || !granted { Text(detail).foregroundStyle(urgent ? .red : .secondary) }
        }
        .help(detail)
    }
}

enum TalkModeRow {
    static let note = "Double-tap starts and stops."
    static func hidesControl(_ key: TalkKey) -> Bool { key == .doubleCommand }
}

struct TalkKeyRows: View {
    @Binding var cfg: Config
    var custom: Binding<RecordedShortcut?>
    var compact = false
    private var siblings: [(RecordedShortcut, String)] { SiblingShortcuts.read() }

    var body: some View {
        Group {
            Picker("Talk key", selection: $cfg.talkKey) {
                ForEach(TalkKey.allCases) { Text($0.name).tag($0) }
            }
            .probe("talkKey")
            LabeledContent {
                TalkKeyControl(key: cfg.talkKey, custom: custom, siblings: siblings)
            } label: {
                Text(TalkKeyText.detailTitle(cfg.talkKey))
                Text(TalkKeyText.detail(cfg.talkKey)).lineLimit(2, reservesSpace: true)
            }
            .frame(minHeight: 47)
            .probe("talkDetail")
            LabeledContent("Talk") {
                ZStack(alignment: .trailing) {
                    Picker("Talk", selection: $cfg.mode) {
                        ForEach(TalkMode.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .opacity(TalkModeRow.hidesControl(cfg.talkKey) ? 0 : 1)
                    .allowsHitTesting(!TalkModeRow.hidesControl(cfg.talkKey))
                    .accessibilityHidden(TalkModeRow.hidesControl(cfg.talkKey))
                    if TalkModeRow.hidesControl(cfg.talkKey) {
                        Text(TalkModeRow.note).foregroundStyle(.secondary)
                    }
                }
            }
            .help("Hold: talk while you hold the key. A quick tap also starts; tap again to stop. Esc cancels.")
            .probe("talkMode")
        }
    }
}

struct TalkKeyControl: View {
    let key: TalkKey
    var custom: Binding<RecordedShortcut?>
    var siblings: [(RecordedShortcut, String)] = []

    var body: some View {
        ZStack(alignment: .trailing) {
            switch key {
            case .custom:
                ShortcutRecorder(shortcut: custom, defaultShortcut: defaultCustomShortcut, conflicts: siblings)
            case .fn:
                Button("Keyboard Settings…") { TalkKeyText.openKeyboardSettings() }
            case .rightOption, .doubleCommand:
                Color.clear
            }
        }
        .frame(width: TalkKeyControl.width, height: 24, alignment: .trailing)
    }

    static let width: CGFloat = 170
}

struct GlassRoundButton: View {
    let symbol: String
    var help = ""
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }
}

struct VolumeDots: View {
    @Binding var step: Int
    var onPick: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(SoundVolume.steps), id: \.self) { i in
                    Button {
                        step = i
                        onPick(i)
                    } label: {
                        Circle()
                            .fill(i <= step ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.18))
                            .frame(width: 8 + CGFloat(i) * 2, height: 8 + CGFloat(i) * 2)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(SoundVolume.name(i))
                }
            }
            Text(SoundVolume.name(step))
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue(SoundVolume.name(step))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: step = SoundVolume.clamp(step + 1); onPick(step)
            case .decrement: step = SoundVolume.clamp(step - 1); onPick(step)
            @unknown default: break
            }
        }
    }
}

struct SoundRows: View {
    @Binding var cfg: Config

    var body: some View {
        Group {
            Toggle(isOn: $cfg.sounds) {
                Text("Sounds")
                Text("A soft sound when listening starts and stops.")
            }
            .probe("soundsToggle")
            if cfg.sounds {
            LabeledContent("Sound") {
                HStack(spacing: 8) {
                    Picker("", selection: $cfg.soundSet) {
                        ForEach(SoundSet.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                    GlassRoundButton(symbol: "play.fill", help: "Play the start and stop sounds") {
                        Sounds.preview(cfg.soundSet, volume: cfg.volume)
                    }
                    Menu {
                        Toggle("Start sound", isOn: $cfg.startSound)
                            .disabled(cfg.startSound && !cfg.stopSound)
                        Toggle("Stop sound", isOn: $cfg.stopSound)
                            .disabled(cfg.stopSound && !cfg.startSound)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose which sounds play")
                }
            }
            .transition(.opacity)
            LabeledContent("Volume") {
                VolumeDots(step: $cfg.volume) { Sounds.play(cfg.soundSet, start: true, volume: $0) }
            }
            .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: cfg.sounds)
        .onChange(of: cfg.soundSet) { _, new in Sounds.preview(new, volume: cfg.volume) }
    }
}

struct WritingModeRow: View {
    @Binding var mode: WritingMode
    let engine: EngineID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Words appear", selection: $mode) {
                ForEach(WritingMode.allCases) { Text($0.short).tag($0) }
            }
            .pickerStyle(.segmented)
            .probe("writing")
            Text(note).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .probe("writingDetail")
        }
    }

    private var note: String { WritingNote.text(mode, engine: engine) }
}

enum WritingNote {
    static func text(_ mode: WritingMode, engine: EngineID) -> String {
        if mode == .live, !LiveSupport.supports(engine) {
            return "\(ModelInfo.info(engine).name) can't write live, so it pastes the final result."
        }
        return mode.detail
    }
}

struct ModelRow: View {
    let info: ModelInfo
    @ObservedObject var store: ModelStore
    @Binding var selection: String

    private var state: ModelState { store.state(info.id) }
    private var inUse: Bool { selection == info.id.rawValue }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if state.isReady { selection = info.id.rawValue }
            } label: {
                Image(systemName: inUse ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(inUse ? Color(nsColor: .controlAccentColor) : (state.isReady ? .secondary : Color.secondary.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!state.isReady)
            .help(state.isReady ? "Use \(info.name)" : "Download it first")
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.name).font(.body.weight(.medium))
                    if inUse {
                        Text("In use")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(nsColor: .controlAccentColor).opacity(0.2), in: Capsule())
                    }
                }
                Text(info.summary).font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.caption).foregroundStyle(.tertiary)
                if offloaded {
                    Text("Not on this Mac — one-click download").font(.caption).foregroundStyle(.secondary)
                }
                if case .failed(let msg) = state {
                    Text(msg).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 2)
    }

    private var offloaded: Bool { store.isOffloaded(info.id) }

    private var detail: String {
        let size: String
        switch state {
        case .ready(let b) where b > 0: size = ModelLifecycle.sizeText(b)
        default: size = info.builtIn ? "Built in" : "≈ " + ModelLifecycle.sizeText(info.approxBytes)
        }
        return "\(info.languages) · \(size)"
    }

    @ViewBuilder private var controls: some View {
        if info.builtIn {
            Text("Ready").font(.caption).foregroundStyle(.secondary)
        } else {
            switch state {
            case .missing, .failed:
                Button(state == .missing ? "Download" : "Retry") { store.download(info.id) }
            case .downloading(let p):
                HStack(spacing: 6) {
                    ProgressView(value: p).frame(width: 64)
                    Button {
                        store.cancel(info.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
            case .ready:
                Button("Free Up Space") {
                    if inUse { selection = EngineID.apple.rawValue }
                    EngineHub.shared.unload(info.id)
                    store.freeUp(info.id)
                }
                .help("Removes the files. One click downloads it again.")
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel

    private var cleanupNote: String {
        if m.cfg.writing == .live { return "Live typing types words as they come, so cleanup is off." }
        if m.cfg.cleanup == .smart && !Cleaner.modelReady { return "Apple Intelligence is off, so Smart works like Quick." }
        return m.cfg.cleanup.detail
    }
    @ObservedObject var store: ModelStore
    @ObservedObject var tryModel: TryModel
    let tab: String

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case "microphone": MicPane(m: m, tester: m.mic, input: m.input)
                case "models": modelsTab
                case "language": languageTab
                case "animation": animationTab
                case "try": tryTab
                default: generalTab
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Text(appVersion)
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .controlSize(.small)
        .frame(width: 480, height: 580)
    }

    private var customShortcut: Binding<RecordedShortcut?> {
        Binding(get: { hotkeyShortcut(m.cfg.hotkey) },
                set: { m.cfg.hotkey = $0?.storageID ?? "off" })
    }

    private var generalTab: some View {
        Form {
            Section {
                TalkKeyRows(cfg: $m.cfg, custom: customShortcut)
            }
            Section {
                SoundRows(cfg: $m.cfg)
            }
            Section {
                PermissionRow(title: "Microphone", detail: "To hear you while you talk.",
                              granted: m.micGranted, compact: true, action: m.allowMicrophone)
                PermissionRow(title: "Accessibility",
                              detail: TalkKeySetup.usable(key: m.cfg.talkKey, trusted: m.axTrusted)
                                  ? "For the talk key and typing where your cursor is."
                                  : "Needed for \(TalkKeyText.keyName(m.cfg)) — it won't work until you allow it.",
                              granted: m.axTrusted, compact: true,
                              urgent: !TalkKeySetup.usable(key: m.cfg.talkKey, trusted: m.axTrusted),
                              action: m.allowAccessibility)
            }
            Section {
                Toggle("Show in menu bar", isOn: $m.cfg.showMenuBarIcon)
                    .help("When hidden, open \(Identity.appName) from Spotlight.")
                Toggle("Open at login", isOn: $m.cfg.launchAtLogin)
                LabeledContent("Setup") {
                    HStack {
                        Button("Run Setup Again") { m.runSetup() }
                        Button("Quit") { NSApp.terminate(nil) }
                    }
                }
                UpdatesRow()
            }
        }
        .formStyle(.grouped)
        .onAppear { m.startPolling() }
        .onDisappear { m.stopPolling() }
    }

    private var modelsTab: some View {
        let inUse = EngineID(rawValue: m.cfg.engine) ?? .apple
        let advice = store.suggestions(inUse: inUse)
        return Form {
            if !advice.isEmpty {
                Section {
                    Label {
                        Text("Your disk is almost full. \(advice.map { ModelInfo.info($0).name }.joined(separator: ", ")) hasn't been used in 30 days — Free Up Space gives it back.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                    }
                }
            }
            Section {
                ForEach(ModelInfo.all) { info in
                    ModelRow(info: info, store: store, selection: $m.cfg.engine)
                }
            } footer: {
                Text("Models run on this Mac and stay downloaded, so switching is instant. Apple is always there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Space used") {
                    HStack(spacing: 10) {
                        Text(store.totalBytes > 0 ? ModelLifecycle.sizeText(store.totalBytes) : "None")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Button("Delete All Models") {
                            m.cfg.engine = EngineID.apple.rawValue
                            EngineHub.shared.unloadAll()
                            store.deleteAll()
                        }
                        .disabled(store.totalBytes == 0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
    }

    private var animationTab: some View {
        Form {
            Section {
                Picker("Size", selection: $m.cfg.hudSize) {
                    ForEach(hudSizes) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .probe("hudSize")
                if let scale = HUD.scale(for: m.cfg.hudSize) {
                    ZStack {
                        LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        HUDPreview(scale: scale, paused: !(m.visible && m.activeTab == "animation"))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Text("Real size")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.3), in: Capsule())
                            .padding(8)
                    }
                    .transition(.opacity)
                }
            } footer: {
                Text(m.cfg.hudSize == "off" ? "No bubble — the text just appears."
                                            : "Shown just above the text field you're typing in. The waveform follows your voice; your words never show in it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .animation(.easeInOut(duration: 0.2), value: m.cfg.hudSize == "off")
        }
        .formStyle(.grouped)
    }

    private var languageTab: some View {
        Form {
            Section {
                WritingModeRow(mode: $m.cfg.writing, engine: EngineID(rawValue: m.cfg.engine) ?? .apple)
                Toggle(isOn: $m.cfg.spokenPunctuation) {
                    Text("Spoken punctuation")
                    Text("Say “comma”, “question mark” or “new line” to type , ? and a line break.")
                }
                .probe("spokenPunctuation")
            }
            Section {
                Picker("Language", selection: $m.cfg.language) {
                    ForEach(SpeechLanguage.allCases) { Text($0.name).tag($0) }
                }
                .help("Automatic: Parakeet and Whisper detect it; Apple uses your first keyboard language.")
                Picker("Cleanup", selection: $m.cfg.cleanup) {
                    ForEach(CleanupMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Quick is instant. Smart uses Apple's on-device AI and waits at most 1.5 s, then falls back to Quick.")
                .disabled(m.cfg.writing == .live)
                Text(cleanupNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vocabulary")
                    TextField("Vocabulary", text: $m.cfg.vocabulary, prompt: Text("Apple, Mac, Supercalifragilisticexpialidocious"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...5)
                        .textFieldStyle(.roundedBorder)
                    Text("Names and words to spell exactly like this.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Text goes", selection: $m.cfg.insert) {
                    ForEach(InsertMode.allCases) { Text($0.name).tag($0) }
                }
                if m.cfg.insert != .copy {
                    Toggle("Keep the text in the clipboard", isOn: $m.cfg.keepInClipboard)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: m.cfg.insert)
        }
        .formStyle(.grouped)
    }

    private var tryTab: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Button {
                        tryModel.toggleRecording()
                    } label: {
                        Label(tryModel.recording ? "Stop" : "Record", systemImage: tryModel.recording ? "stop.circle.fill" : "mic.circle.fill")
                    }
                    .disabled(tryModel.busy)
                    Button("Choose Audio File…") { tryModel.chooseFile() }
                        .disabled(tryModel.busy || tryModel.recording)
                    Spacer()
                    if tryModel.recording {
                        Waveform(levels: [tryModel.level, tryModel.level * 0.7, tryModel.level, tryModel.level * 0.5, tryModel.level * 0.9])
                    }
                }
                Text(tryModel.source.isEmpty ? "Record a sentence or pick an audio file. Every downloaded model transcribes it."
                                             : tryModel.source)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !tryModel.results.isEmpty {
                Section {
                    ForEach(tryModel.results) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(ModelInfo.info(r.id).name).font(.body.weight(.medium))
                                Spacer()
                                if r.running { ProgressView().controlSize(.mini) }
                                else if let s = r.seconds { Text(String(format: "%.2f s", s)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                            }
                            if !r.text.isEmpty {
                                Text(r.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { tryModel.stop() }
    }
}

struct UpdatesRow: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if updates.automaticChecks {
                    Toggle("Install", isOn: $updates.automaticDownloads).toggleStyle(.checkbox)
                        .help("Download and install updates automatically")
                        .transition(.opacity)
                    Toggle("Betas", isOn: $updates.beta).toggleStyle(.checkbox)
                        .help("Get beta updates: new features early. Betas may be less stable.")
                        .transition(.opacity)
                }
                Toggle("Automatic", isOn: $updates.automaticChecks).toggleStyle(.checkbox)
                    .help("Check for updates automatically")
                Button("Check Now") { updates.checkNow() }.disabled(!updates.canCheck)
            }
            .animation(.easeInOut(duration: 0.2), value: updates.automaticChecks)
        } label: {
            Text("Updates")
        }
        .probe("updates")
    }
}

final class SettingsTabs: NSTabViewController {
    static let lastKey = "settingsPane"
    static let panes = [("general", "General", "gearshape"), ("microphone", "Microphone", "mic"),
                        ("models", "Models", "square.stack.3d.down.right"), ("language", "Writing", "character.bubble"),
                        ("animation", "Animation", "sparkles"), ("try", "Try It", "waveform")]
    var onSelect: (String) -> Void = { _ in }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: Self.lastKey)
            onSelect(id)
        }
    }
}

final class QuietWindow: NSWindow {
    override func noResponder(for eventSelector: Selector) {}

    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    let tryModel = TryModel()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show(tab: String? = nil) {
        model.cfg = Config.load()
        model.refreshPermissions()
        ModelStore.shared.refresh()
        if window == nil {
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            tabs.onSelect = { [weak self] id in
                guard let self else { return }
                if self.model.activeTab == "microphone", id != "microphone" { self.model.mic.stop() }
                self.model.activeTab = id
            }
            for (id, title, symbol) in SettingsTabs.panes {
                let host = NSHostingController(rootView: SettingsView(m: model, store: .shared, tryModel: tryModel, tab: id))
                host.sizingOptions = [.preferredContentSize]
                host.title = "\(Identity.appName) — \(title)"
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.identifier = id
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let w = QuietWindow(contentViewController: tabs)
            let start = tab ?? CommandLine.arguments.first { $0.hasPrefix("--tab=") }.map { String($0.dropFirst(6)) }
                ?? UserDefaults.standard.string(forKey: SettingsTabs.lastKey) ?? "general"
            tabs.selectedTabViewItemIndex = SettingsTabs.panes.firstIndex { $0.0 == start } ?? 0
            model.activeTab = SettingsTabs.panes.first { $0.0 == start }?.0 ?? "general"
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.collectionBehavior = [.moveToActiveSpace]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        } else if let tab, let tabs = window?.contentViewController as? NSTabViewController,
                  let i = SettingsTabs.panes.firstIndex(where: { $0.0 == tab }) {
            tabs.selectedTabViewItemIndex = i
        }
        model.visible = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        model.visible = false
        model.stopPolling()
        model.mic.reset()
        tryModel.stop()
    }
}
