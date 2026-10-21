import AppKit
import SwiftUI

enum HUDPhase: Equatable {
    case hidden
    case listening
    case working
    case done(String)
    case failed(String)
}

struct HUDSizeOption: Identifiable {
    let id: String
    let name: String
}

let hudSizes = [
    HUDSizeOption(id: "off", name: "Off"),
    HUDSizeOption(id: "small", name: "Small"),
    HUDSizeOption(id: "medium", name: "Medium"),
    HUDSizeOption(id: "large", name: "Large"),
]

enum HUDText {
    static let listening = "Listening"
    static let writing = "Writing"
    static let noSpeech = "No speech heard"
    static let micOff = "Microphone off"
    static let modelMissing = "Model not downloaded"
    static let otherVoice = "Didn't hear your voice"
    static let allowMic = "Allow Microphone"
    static func allowAccessibility(_ key: String) -> String { "Allow Accessibility" }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var shown = false
    @Published var leaving = false
    @Published var level: Float = 0
    @Published var levels: [Float] = Array(repeating: 0, count: HUDModel.bars)
    @Published var engine = ""
    @Published var scale: CGFloat = 1

    nonisolated static let bars = 24
    var threshold: Double = VoiceGate.defaultThreshold
    private var smoothed: Float = 0
    private var last = Date()

    func push(_ value: Float) {
        let now = Date()
        let dt = min(0.25, max(0.001, now.timeIntervalSince(last)))
        last = now
        let target = LevelDisplay.gated(value, threshold: threshold)
        smoothed = LevelDisplay.smooth(smoothed, toward: target, dt: dt)
        level = smoothed
        levels.removeFirst()
        levels.append(smoothed)
    }

    func resetLevels() {
        level = 0
        smoothed = 0
        last = Date()
        levels = Array(repeating: 0, count: Self.bars)
    }
}

enum LevelDisplay {
    static let attack = 0.04
    static let release = 0.2
    static let meterRange: ClosedRange<Double> = -60 ... -10

    static func db(normalized l: Float) -> Double {
        Double(min(1, max(0, l))) * 50 - 55
    }

    static func gated(_ normalized: Float, threshold: Double) -> Float {
        let d = db(normalized: normalized)
        guard d >= threshold, normalized > 0 else { return 0 }
        let top = meterRange.upperBound
        let span = max(1, top - threshold)
        return Float(min(1, max(0.08, (d - threshold) / span)))
    }

    static func smooth(_ current: Float, toward target: Float, dt: Double) -> Float {
        let tau = target > current ? attack : release
        let a = Float(1 - exp(-dt / tau))
        return current + (target - current) * a
    }

    static func meterFraction(db d: Double) -> Double {
        let r = meterRange
        return min(1, max(0, (d - r.lowerBound) / (r.upperBound - r.lowerBound)))
    }
}

struct Waveform: View {
    let levels: [Float]
    var active = true
    var barWidth: CGFloat = 3
    var spacing: CGFloat? = nil
    var maxHeight: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: spacing ?? barWidth * 0.8) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(active ? 0.85 : 0.35))
                    .frame(width: barWidth, height: 4 + CGFloat(levels[i]) * maxHeight)
            }
        }
        .frame(height: maxHeight + 4)
        .animation(.easeOut(duration: 0.06), value: levels)
    }
}

struct ShimmerBars: View {
    var count = HUDModel.bars
    var barWidth: CGFloat = 3
    var spacing: CGFloat? = nil
    var maxHeight: CGFloat = 20
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing ?? barWidth * 0.8) {
                ForEach(0..<count, id: \.self) { i in
                    let x = Double(i) / Double(max(1, count - 1))
                    let head = (t * 0.9).truncatingRemainder(dividingBy: 1.4) - 0.2
                    let glow = max(0, 1 - abs(x - head) * 5)
                    Capsule()
                        .fill(Color.primary.opacity(0.28 + 0.55 * glow))
                        .frame(width: barWidth, height: 4 + maxHeight * (0.12 + 0.18 * glow))
                }
            }
            .frame(height: maxHeight + 4)
        }
    }
}

enum HUDLabel {
    static func text(for phase: HUDPhase) -> String? {
        switch phase {
        case .done(let t): t == "Done" ? nil : t
        case .failed(let t): t
        default: nil
        }
    }
}

enum HUDGeometry {
    static let contentWidth: CGFloat = 132
    static let iconSize: CGFloat = 22
    static let height: CGFloat = 40

    static func size(k: CGFloat) -> CGSize {
        CGSize(width: (12 + iconSize + 10 + contentWidth + 14) * k, height: height * k)
    }

    static func barWidth(k: CGFloat) -> CGFloat { 3 * k }

    static func spacing(k: CGFloat) -> CGFloat {
        let bars = CGFloat(HUDModel.bars)
        return max(1, (contentWidth * k - bars * barWidth(k: k)) / (bars - 1))
    }
}

enum HUDStateKey: Equatable {
    case listening, working, done, failed

    init(_ phase: HUDPhase) {
        switch phase {
        case .listening, .hidden: self = .listening
        case .working: self = .working
        case .done: self = .done
        case .failed: self = .failed
        }
    }
}

struct MicPill: View {
    let phase: HUDPhase
    var levels: [Float] = Array(repeating: 0, count: HUDModel.bars)
    var k: CGFloat = 1
    var paused = false

    private var key: HUDStateKey { HUDStateKey(phase) }

    var body: some View {
        let size = HUDGeometry.size(k: k)
        HStack(spacing: 10 * k) {
            ZStack {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14 * k, weight: .semibold))
                    .foregroundStyle(key == .listening ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .symbolEffect(.pulse, options: .repeating, isActive: key == .listening && !paused)
                    .opacity(key == .listening || key == .working ? 1 : 0)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17 * k)).foregroundStyle(.green)
                    .opacity(key == .done ? 1 : 0)
                Image(systemName: "xmark.circle.fill").font(.system(size: 17 * k)).foregroundStyle(.red)
                    .opacity(key == .failed ? 1 : 0)
            }
            .frame(width: HUDGeometry.iconSize * k, height: HUDGeometry.iconSize * k)
            ZStack(alignment: .leading) {
                Waveform(levels: levels, barWidth: HUDGeometry.barWidth(k: k), spacing: HUDGeometry.spacing(k: k),
                         maxHeight: 20 * k)
                    .opacity(key == .listening ? 1 : 0)
                ShimmerBars(barWidth: HUDGeometry.barWidth(k: k), spacing: HUDGeometry.spacing(k: k),
                            maxHeight: 20 * k, paused: paused || key != .working)
                    .opacity(key == .working ? 1 : 0)
                Text(HUDLabel.text(for: phase) ?? "")
                    .font(.system(size: 13 * k, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
                    .opacity(key == .done || key == .failed ? 1 : 0)
            }
            .frame(width: HUDGeometry.contentWidth * k, alignment: .leading)
        }
        .padding(.leading, 12 * k)
        .padding(.trailing, 14 * k)
        .frame(width: size.width, height: size.height)
        .glassEffect(.regular, in: Capsule())
        .animation(.easeInOut(duration: 0.2), value: key)
        .probe("bubble")
    }
}

struct HUDBubble: View {
    let phase: HUDPhase
    var level: Float = 0
    var levels: [Float] = Array(repeating: 0, count: HUDModel.bars)
    var k: CGFloat = 1
    var paused = false

    var body: some View {
        MicPill(phase: phase, levels: levels, k: k, paused: paused)
    }
}

enum HUDMotion {
    static let appearScale: CGFloat = 0.88
    static let leaveScale: CGFloat = 0.94
    static let fadeOut: TimeInterval = 0.3
    static let crossfade: TimeInterval = 0.2

    static var appear: Animation { .spring(response: 0.25, dampingFraction: 0.82) }
    static var disappear: Animation { .easeOut(duration: fadeOut) }
    static var state: Animation { .easeInOut(duration: crossfade) }

    static func scale(shown: Bool, leaving: Bool, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, !shown else { return 1 }
        return leaving ? leaveScale : appearScale
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let content = model.phase == .hidden ? HUDPhase.listening : model.phase
        HUDBubble(phase: content, level: model.level, levels: model.levels,
                  k: model.scale, paused: !model.shown)
            .scaleEffect(HUDMotion.scale(shown: model.shown, leaving: model.leaving, reduceMotion: reduceMotion))
            .opacity(model.shown ? 1 : 0)
            .padding(6)
            .fixedSize()
    }
}

enum HUDPreviewPlan {
    static let listen = 2.6
    static let write = 1.6
    static let done = 1.3
    static var period: Double { listen + write + done }

    static func phase(at t: Double) -> HUDPhase {
        let x = t.truncatingRemainder(dividingBy: period)
        if x < listen { return .listening }
        if x < listen + write { return .working }
        return .done("Done")
    }

    static func level(at t: Double) -> Float {
        let x = t.truncatingRemainder(dividingBy: period)
        guard x < listen else { return 0 }
        let v = 0.45 + 0.35 * sin(x * 7.3) + 0.2 * sin(x * 17.1 + 1)
        return Float(min(1, max(0, v)))
    }

    static func levels(at t: Double, count: Int = HUDModel.bars) -> [Float] {
        (0..<count).map { i in level(at: t - Double(count - 1 - i) * 0.06) }
    }
}

struct HUDPreview: View {
    let scale: CGFloat
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = HUDPreviewPlan.phase(at: t)
            HUDBubble(phase: phase, level: HUDPreviewPlan.level(at: t), levels: HUDPreviewPlan.levels(at: t),
                      k: scale, paused: paused)
                .animation(.spring(response: 0.32, dampingFraction: 0.7), value: phase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUD {
    static let shared = HUD()

    let model = HUDModel()
    private var panel: HUDPanel?
    private var host: NSHostingView<HUDView>?
    private var hideWork: DispatchWorkItem?
    private var anchor: CGRect?

    nonisolated static func scale(for size: String) -> CGFloat? {
        switch size {
        case "small": 0.72
        case "large": 1.4
        case "medium": 1
        default: nil
        }
    }

    func begin(anchor: CGRect?) {
        self.anchor = anchor
    }

    func show(_ phase: HUDPhase, engine: String? = nil, hideAfter: TimeInterval? = nil) {
        let cfg = Config.current
        guard let scale = Self.scale(for: cfg.hudSize) else {
            hide()
            return
        }
        hideWork?.cancel()
        if let engine { model.engine = engine }
        let wasHidden = !(panel?.isVisible ?? false)
        if phase == .listening && (wasHidden || !model.shown) {
            model.threshold = cfg.speechThreshold
            model.resetLevels()
        }
        model.scale = scale
        let p = panel ?? makePanel()
        panel = p
        if wasHidden {
            model.leaving = false
            model.shown = false
            model.phase = phase
            place(p)
            p.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel?.isVisible == true, !self.model.leaving else { return }
                withAnimation(HUDMotion.appear) { self.model.shown = true }
            }
        } else if !model.shown || model.leaving {
            model.leaving = false
            model.phase = phase
            withAnimation(HUDMotion.appear) { model.shown = true }
        } else {
            withAnimation(HUDMotion.state) { model.phase = phase }
        }
        if let hideAfter {
            let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
        }
    }

    func hide(animated: Bool = true) {
        hideWork?.cancel()
        guard animated, panel?.isVisible == true, model.shown else {
            model.shown = false
            model.leaving = false
            model.phase = .hidden
            panel?.orderOut(nil)
            anchor = nil
            return
        }
        model.leaving = true
        withAnimation(HUDMotion.disappear) { model.shown = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.model.phase = .hidden
            self.model.leaving = false
            self.anchor = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HUDMotion.fadeOut + 0.04, execute: work)
    }

    private func makePanel() -> HUDPanel {
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 70),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        let h = NSHostingView(rootView: HUDView(model: model))
        h.safeAreaRegions = []
        p.contentView = h
        host = h
        return p
    }

    private func place(_ p: NSPanel) {
        let bubble = HUDGeometry.size(k: model.scale)
        let size = NSSize(width: bubble.width + 12, height: bubble.height + 12)
        p.setContentSize(size)
        host?.frame = NSRect(origin: .zero, size: size)
        p.setFrameOrigin(HUDPlacement.origin(size: size, anchor: anchor, mouse: NSEvent.mouseLocation,
                                             screens: NSScreen.screens.map(\.visibleFrame)))
    }
}

enum HUDPlacement {
    static func origin(size: NSSize, anchor: CGRect?, mouse: NSPoint, screens: [CGRect]) -> NSPoint {
        let point = anchor.map { NSPoint(x: $0.minX, y: $0.midY) } ?? mouse
        let vis = screens.first { $0.insetBy(dx: -1, dy: -1).contains(point) } ?? screens.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        if let a = anchor {
            origin = NSPoint(x: a.minX - 6, y: a.maxY + 2)
            if origin.y + size.height > vis.maxY { origin.y = a.minY - size.height - 2 }
        } else {
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 16)
            if origin.y + size.height > vis.maxY { origin.y = mouse.y - size.height - 16 }
        }
        origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - size.width - 4)
        origin.y = min(max(origin.y, vis.minY + 4), vis.maxY - size.height - 4)
        return origin
    }
}
