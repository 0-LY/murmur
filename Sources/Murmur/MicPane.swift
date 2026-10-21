import AppKit
import SwiftUI

struct LevelBar: View {
    let fraction: Float
    let threshold: Double

    private var marker: CGFloat { CGFloat(LevelDisplay.meterFraction(db: threshold)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, fraction)))))
                    .animation(.easeOut(duration: 0.06), value: fraction)
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: geo.size.height + 4)
                    .offset(x: geo.size.width * marker - 1)
                    .help("Speech starts above this line")
            }
        }
        .frame(height: 8)
    }
}

enum MicPaneWidths {
    static let button: CGFloat = 100
    static let smallButton: CGFloat = 80
    static let bar: CGFloat = 96
}

struct PaneRow<Controls: View>: View {
    let title: String
    let detail: String
    var reserveLines = 1
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(reserveLines, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls.fixedSize().padding(.top, 4)
        }
    }
}

struct FixedButton: View {
    let title: String
    var width: CGFloat = MicPaneWidths.button
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(width: width)
        }
    }
}

struct WaveStrip: View {
    let peaks: [Float]
    var color: Color = .primary

    var body: some View {
        GeometryReader { geo in
            let n = max(1, peaks.count)
            let w = geo.size.width / CGFloat(n)
            HStack(alignment: .center, spacing: 0) {
                ForEach(peaks.indices, id: \.self) { i in
                    Capsule()
                        .fill(color.opacity(0.75))
                        .frame(width: max(1.5, w * 0.6), height: max(2, geo.size.height * CGFloat(peaks[i])))
                        .frame(width: w)
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 34)
    }
}

struct QualityBadge: View {
    let quality: MicQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(quality.title, systemImage: quality.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(quality.ok ? Color.green : Color.orange)
            Text(quality.tip).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct InputRows: View {
    @ObservedObject var input: MicInput
    @ObservedObject var modes: MicModeController = .shared

    var body: some View {
        PaneRow(title: "Input: \(input.displayName)", detail: "Mode: \(modes.modeName)") {
            HStack(spacing: 8) {
                FixedButton(title: "Sound Settings…", width: 92) { MacMic.openSoundSettings() }
                    .help("Choose the microphone in System Settings → Sound → Input.")
                MicModeButton(modes: modes)
            }
        }
        .help("Voice Isolation in Mic Mode helps in noisy rooms.")
        .onDisappear { modes.stop() }
    }
}

struct MicModeButton: View {
    @ObservedObject var modes: MicModeController
    var width: CGFloat = 82

    var body: some View {
        Button { modes.show() } label: {
            MicModeLabel(listening: modes.listening, level: modes.level, width: width)
        }
        .help("Turns the mic on and opens macOS mic modes, like Voice Isolation.")
        .popover(isPresented: Binding(get: { modes.showHint }, set: { modes.showHint = $0 }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick a mic mode").font(.headline)
                Text("Choose Voice Isolation in the menu that opened. Nothing opened? Open Control Center → Mic Mode while Murmur is listening.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Current: \(modes.modeName)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { modes.stop() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
    }
}

struct MicModeLabel: View {
    let listening: Bool
    let level: Float
    var width: CGFloat = 82

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .scaleEffect(listening ? 0.7 + CGFloat(min(1, level)) * 0.6 : 1)
                .opacity(listening ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: level)
            Text(listening ? "Listening…" : "Mic Mode…").lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(width: width, height: 16)
        .probe("micMode")
    }
}

struct CheckMicRow: View {
    @ObservedObject var tester: MicTester
    let threshold: Double
    let granted: Bool
    let apply: (Double) -> Void

    var body: some View {
        PaneRow(title: "Check Mic", detail: Self.detail(tester.phase, result: tester.check), reserveLines: 2) {
            HStack(spacing: 10) {
                LevelBar(fraction: tester.meter, threshold: threshold)
                    .frame(width: MicPaneWidths.bar)
                    .probe("level")
                FixedButton(title: Self.title(tester.phase, countdown: tester.countdown)) { tester.checkMic(apply: apply) }
                    .disabled(!granted || (tester.busy && !tester.checking))
                    .probe("checkMic")
            }
        }
    }

    static func title(_ phase: MicTester.Phase, countdown: Double) -> String {
        switch phase {
        case .quiet: "Stay quiet…"
        case .speak: "Say something…"
        default: "Check Mic"
        }
    }

    static func detail(_ phase: MicTester.Phase, result: CheckMic.Result?) -> String {
        switch phase {
        case .quiet: return "Measuring the room. Stay quiet."
        case .speak: return "Now say something in your normal voice."
        default:
            if let r = result { return CheckMic.summary(r) }
            return "Measures the room and your voice, then sets Sensitivity."
        }
    }
}

enum MainVoiceConfirm {
    static let title = "Focus on main voice is experimental"
    static let message = "It can cut some of your own words. Use the sensitivity slider below if it does."

    static func needsConfirm(old: Bool, new: Bool) -> Bool { new && !old }

    @MainActor static var ask: () -> Bool = {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor static func resolve(old: Bool, new: Bool) -> Bool {
        guard needsConfirm(old: old, new: new) else { return new }
        return ask()
    }

    @MainActor static func binding(_ base: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { base.wrappedValue }, set: { new in
            let value = resolve(old: base.wrappedValue, new: new)
            if value != base.wrappedValue { base.wrappedValue = value }
        })
    }
}

struct MainVoiceRow: View {
    @Binding var on: Bool
    @Binding var sensitivity: MainVoiceSensitivity
    @ObservedObject var store: VoiceStore = .shared

    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: MainVoiceConfirm.binding($on)) {
                Text("Focus on main voice")
                Text(detail).lineLimit(2, reservesSpace: true).frame(height: 30, alignment: .topLeading)
            }
            .toggleStyle(.switch)
            .onChange(of: on) { _, new in
                if new, !store.ready { Task { _ = await store.downloadModel() } }
            }
            .probe("mainVoice")
            if on {
                Divider().padding(.vertical, 6)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sensitivity")
                        Text(sensitivity.detail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Sensitivity", selection: $sensitivity) {
                        ForEach(MainVoiceSensitivity.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .layoutPriority(1)
                }
                .probe("mainVoiceSensitivity")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: on)
    }

    private var detail: String {
        guard on else { return "Off: every voice the mic hears is written down." }
        switch store.model {
        case .downloading: return String(format: "Getting the voice model (%.0f%% of ≈ %@)…",
                                         store.downloadFraction * 100, ModelLifecycle.sizeText(MainVoice.approxBytes))
        case .failed(let msg): return msg
        default: return "Experimental: drops quieter voices that sound different from the main one."
        }
    }
}

struct MicPane: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var tester: MicTester
    @ObservedObject var input: MicInput

    var body: some View {
        Form {
            if !m.micGranted {
                Section {
                    PermissionRow(title: "Microphone", detail: "\(Identity.appName) needs it to hear you.",
                                  granted: false, action: m.allowMicrophone)
                }
            }
            Section {
                InputRows(input: input)
            }
            Section {
                MainVoiceRow(on: $m.cfg.mainVoice, sensitivity: $m.cfg.mainVoiceSensitivity)
            }
            Section {
                CheckMicRow(tester: tester, threshold: m.cfg.speechThreshold, granted: m.micGranted) {
                    m.cfg.speechThreshold = $0
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { VoiceGate.sensitivity(forThreshold: m.cfg.speechThreshold) },
                                              set: { m.cfg.speechThreshold = VoiceGate.threshold(forSensitivity: $0) }))
                            .frame(width: 150)
                        Text(String(format: "%.0f dB", m.cfg.speechThreshold)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                } label: {
                    Text("Sensitivity")
                    Text("Higher hears quieter speech.")
                }
            }
            Section {
                HStack(spacing: 10) {
                    Button {
                        tester.testRecording(config: m.cfg)
                    } label: {
                        Label(tester.phase == .recording ? String(format: "Stop · %.0f s", tester.countdown.rounded(.up)) : "Test Recording",
                              systemImage: tester.phase == .recording ? "stop.circle.fill" : "mic.circle")
                            .frame(width: 130)
                    }
                    .disabled(!m.micGranted || (tester.busy && tester.phase != .recording))
                    FixedButton(title: "Play Again", width: MicPaneWidths.smallButton) { tester.replay() }
                        .disabled(tester.busy || !tester.canReplay)
                        .opacity(tester.canReplay ? 1 : 0)
                    Spacer()
                    if tester.phase == .transcribing { ProgressView().controlSize(.small) }
                }
                if tester.phase == .recording {
                    Waveform(levels: tester.levels, barWidth: 3, maxHeight: 22)
                        .frame(maxWidth: .infinity)
                } else if !tester.waveform.isEmpty {
                    WaveStrip(peaks: tester.waveform)
                }
                if let q = tester.quality { QualityBadge(quality: q) }
                if !tester.transcript.isEmpty {
                    Text(tester.transcript).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if tester.quality == nil, tester.phase != .recording {
                    Text("Say one sentence (up to 6 seconds). You'll hear it back, see how it was heard, and get a quality check.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if tester.silentWarning {
                Section {
                    Label("No sound from the microphone. Check the mute switch and the input volume in System Settings → Sound.",
                          systemImage: "mic.slash.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            input.reload()
            m.startPolling()
        }
        .onDisappear {
            tester.stop()
            m.stopPolling()
        }
    }
}
