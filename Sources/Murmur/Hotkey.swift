import AppKit
import Carbon.HIToolbox

struct HotkeyOption: Identifiable {
    let id: String
    let name: String
    let code: Int
    let mods: Int
}

let hotkeys = [
    HotkeyOption(id: "ctrl-opt-v", name: "⌃⌥V", code: kVK_ANSI_V, mods: controlKey | optionKey),
    HotkeyOption(id: "ctrl-opt-m", name: "⌃⌥M", code: kVK_ANSI_M, mods: controlKey | optionKey),
    HotkeyOption(id: "ctrl-shift-space", name: "⌃⇧Space", code: kVK_Space, mods: controlKey | shiftKey),
    HotkeyOption(id: "opt-cmd-m", name: "⌥⌘M", code: kVK_ANSI_M, mods: optionKey | cmdKey),
    HotkeyOption(id: "off", name: "Off", code: 0, mods: 0),
]

func hotkeyName(_ id: String) -> String {
    if let s = RecordedShortcut(storageID: id) { return s.display }
    return hotkeys.first { $0.id == id }?.name ?? "⌃⌥V"
}

func hotkeyShortcut(_ id: String) -> RecordedShortcut? {
    if let s = RecordedShortcut(storageID: id) { return s }
    guard let o = hotkeys.first(where: { $0.id == id }), id != "off" else { return nil }
    var f: NSEvent.ModifierFlags = []
    if o.mods & controlKey != 0 { f.insert(.control) }
    if o.mods & optionKey != 0 { f.insert(.option) }
    if o.mods & cmdKey != 0 { f.insert(.command) }
    if o.mods & shiftKey != 0 { f.insert(.shift) }
    return RecordedShortcut(keyCode: UInt16(o.code), modifiers: f)
}

let defaultCustomShortcut = RecordedShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.control, .option])

struct TalkGesture {
    enum Action: Equatable { case start, stop, none }

    static let tapThreshold: TimeInterval = 0.35

    var listening = false
    var pressedAt: Date?
    var latched = false

    mutating func press(mode: TalkMode, at time: Date = Date()) -> Action {
        if listening {
            if mode == .toggle || latched {
                listening = false
                latched = false
                pressedAt = nil
                return .stop
            }
            return .none
        }
        listening = true
        latched = false
        pressedAt = time
        return .start
    }

    mutating func release(mode: TalkMode, at time: Date = Date()) -> Action {
        guard listening, mode == .hold, !latched else { return .none }
        if let pressedAt, time.timeIntervalSince(pressedAt) < Self.tapThreshold {
            latched = true
            return .none
        }
        listening = false
        pressedAt = nil
        return .stop
    }

    mutating func cancel() {
        listening = false
        latched = false
        pressedAt = nil
    }
}

final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var escapeRef: EventHotKeyRef?
    private var handlerInstalled = false
    static let mainID: UInt32 = 1
    static let escapeID: UInt32 = 2

    private func installHandler() {
        guard !handlerInstalled else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hk.id
            DispatchQueue.main.async {
                if id == HotKey.escapeID {
                    if pressed { HotKey.shared.onEscape?() }
                } else if pressed {
                    HotKey.shared.onPress?()
                } else {
                    HotKey.shared.onRelease?()
                }
            }
            return noErr
        }, 2, &specs, nil, nil)
        handlerInstalled = true
    }

    func register(_ id: String) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard id != "off" else { return }
        let code: Int
        let mods: Int
        if let s = RecordedShortcut(storageID: id) {
            code = Int(s.keyCode)
            mods = s.carbonModifiers
        } else if let option = hotkeys.first(where: { $0.id == id }) ?? hotkeys.first {
            code = option.code
            mods = option.mods
        } else { return }
        installHandler()
        let hotID = EventHotKeyID(signature: OSType(0x5350_4B31), id: Self.mainID)
        RegisterEventHotKey(UInt32(code), UInt32(mods), hotID, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    func captureEscape(_ on: Bool) {
        if on {
            guard escapeRef == nil else { return }
            installHandler()
            let hotID = EventHotKeyID(signature: OSType(0x5350_4B32), id: Self.escapeID)
            RegisterEventHotKey(UInt32(kVK_Escape), 0, hotID, GetApplicationEventTarget(), 0, &escapeRef)
        } else if let escapeRef {
            UnregisterEventHotKey(escapeRef)
            self.escapeRef = nil
        }
    }
}
