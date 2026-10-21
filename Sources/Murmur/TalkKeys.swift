import AppKit

enum ModifierKey {
    static let rightOption: UInt16 = 61
    static let rightCommand: UInt16 = 54
    static let fn: UInt16 = 63

    static let rightOptionMask: UInt = 0x40
    static let rightCommandMask: UInt = 0x10

    static func code(for key: TalkKey) -> UInt16? {
        switch key {
        case .rightOption: rightOption
        case .fn: fn
        case .doubleCommand: rightCommand
        case .custom: nil
        }
    }

    static func isDown(code: UInt16, flags: UInt) -> Bool {
        switch code {
        case rightOption: flags & rightOptionMask != 0
        case rightCommand: flags & rightCommandMask != 0
        case fn: flags & NSEvent.ModifierFlags.function.rawValue != 0
        default: false
        }
    }
}

struct ModifierGesture {
    enum Action: Equatable { case press, release, cancel, toggle, none }

    static let doubleTapWindow: TimeInterval = 0.4
    static let tapMax: TimeInterval = 0.3

    let key: TalkKey
    private(set) var down = false
    private(set) var downAt: Date?
    private var lastTapEnd: Date?
    private var chorded = false
    private var swallowUp = false

    init(key: TalkKey) {
        self.key = key
    }

    var code: UInt16? { ModifierKey.code(for: key) }

    mutating func flagsChanged(code eventCode: UInt16, flags: UInt, at time: Date = Date()) -> Action {
        guard let code, eventCode == code else { return .none }
        let isDown = ModifierKey.isDown(code: code, flags: flags)
        if isDown == down { return .none }
        down = isDown
        if key == .doubleCommand {
            if isDown {
                if let prev = lastTapEnd, time.timeIntervalSince(prev) <= Self.doubleTapWindow {
                    lastTapEnd = nil
                    swallowUp = true
                    downAt = nil
                    return .toggle
                }
                downAt = time
                chorded = false
                return .none
            }
            if swallowUp {
                swallowUp = false
                return .none
            }
            defer { downAt = nil }
            guard !chorded, let start = downAt, time.timeIntervalSince(start) <= Self.tapMax else {
                lastTapEnd = nil
                return .none
            }
            lastTapEnd = time
            return .none
        }
        if isDown {
            downAt = time
            chorded = false
            return .press
        }
        downAt = nil
        if chorded {
            chorded = false
            return .none
        }
        return .release
    }

    mutating func otherKey(at time: Date = Date()) -> Action {
        lastTapEnd = nil
        guard down else { return .none }
        chorded = true
        return key == .doubleCommand ? .none : .cancel
    }

    mutating func reset() {
        down = false
        downAt = nil
        lastTapEnd = nil
        chorded = false
        swallowUp = false
    }
}

@MainActor
final class TalkKeyMonitor {
    static let shared = TalkKeyMonitor()

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}
    var onToggle: () -> Void = {}
    private var gesture: ModifierGesture?
    private var monitors: [Any] = []

    var active: Bool { gesture != nil }

    nonisolated static func needsAccessibility(_ key: TalkKey) -> Bool { key != .custom }

    func use(_ key: TalkKey) {
        stop()
        guard key != .custom else { return }
        gesture = ModifierGesture(key: key)
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(l)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        gesture = nil
    }

    private func handle(_ event: NSEvent) {
        guard var g = gesture else { return }
        let action: ModifierGesture.Action
        if event.type == .flagsChanged {
            action = g.flagsChanged(code: event.keyCode, flags: event.modifierFlags.rawValue)
        } else {
            action = g.otherKey()
        }
        gesture = g
        switch action {
        case .press: onPress()
        case .release: onRelease()
        case .cancel: onCancel()
        case .toggle: onToggle()
        case .none: break
        }
    }
}

enum TalkKeySetup: Equatable {
    case carbon
    case modifier
    case modifierWithFallback

    static func plan(key: TalkKey, trusted: Bool, hotkey: String) -> TalkKeySetup {
        if key == .custom { return .carbon }
        if trusted { return .modifier }
        return hotkey == "off" ? .modifier : .modifierWithFallback
    }

    static func usable(key: TalkKey, trusted: Bool) -> Bool {
        key == .custom || trusted
    }
}

enum TalkKeyText {
    static func hint(_ cfg: Config) -> String? {
        switch cfg.talkKey {
        case .rightOption: return cfg.mode == .hold ? "Hold Right ⌥ to talk" : "Press Right ⌥ to talk"
        case .fn: return cfg.mode == .hold ? "Hold 🌐 fn to talk" : "Press 🌐 fn to talk"
        case .doubleCommand: return "Double-tap Right ⌘ to talk"
        case .custom:
            guard cfg.hotkey != "off" else { return nil }
            return "\(cfg.mode == .hold ? "Hold" : "Press") \(hotkeyName(cfg.hotkey)) to talk"
        }
    }

    static func keyName(_ cfg: Config) -> String {
        switch cfg.talkKey {
        case .rightOption: "Right ⌥"
        case .fn: "🌐 fn"
        case .doubleCommand: "Right ⌘ twice"
        case .custom: hotkeyName(cfg.hotkey)
        }
    }

    static func detailTitle(_ key: TalkKey) -> String {
        switch key {
        case .rightOption: "Right ⌥"
        case .fn: "Set 🌐 to Do Nothing"
        case .doubleCommand: "Right ⌘ twice"
        case .custom: "Shortcut"
        }
    }

    static func detail(_ key: TalkKey) -> String {
        switch key {
        case .rightOption: "Hold it while you talk, let go to finish."
        case .fn: "Keyboard → “Press 🌐 key to”, or it opens emoji too."
        case .doubleCommand: "Double-tap to start, double-tap again to stop."
        case .custom: "Click, then press the keys you want."
        }
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

enum SiblingShortcuts {
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(RecordedShortcut, String)] {
        var out: [(RecordedShortcut, String)] = []
        for (dir, name) in [("tidy", "Tidy"), ("stash", "Stash")] {
            let url = home.appendingPathComponent(".config/\(dir)/config.json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["hotkey"] as? String, let s = ShortcutRules.parse(id) else { continue }
            out.append((s, name))
        }
        return out
    }
}
