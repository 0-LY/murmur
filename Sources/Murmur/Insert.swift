import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Access {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

enum Focus {
    static func element() -> AXUIElement? {
        guard Access.trusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func isEditable(_ el: AXUIElement?) -> Bool {
        guard let el else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        let r = role as? String ?? ""
        if Self.editableRoles.contains(r) { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           !Self.nonTextRoles.contains(r) {
            return true
        }
        return false
    }

    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let nonTextRoles: Set<String> = ["AXSlider", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                           "AXScrollBar", "AXIncrementor", "AXColorWell", "AXDateField"]

    static func anchorRect() -> CGRect? {
        guard Access.trusted else { return nil }
        if let app = NSWorkspace.shared.frontmostApplication {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let element = element() else { return nil }
        if let r = selectionBounds(element).flatMap(toCocoa) { return r }
        if let r = frame(element), r.height < 400, let c = toCocoa(r) { return c }
        return nil
    }

    private static func selectionBounds(_ el: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.height > 0, rect.height < 2000, rect.width < 5000 else { return nil }
        return rect
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func toCocoa(_ r: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let c = CGRect(x: r.minX, y: primary.frame.height - r.maxY, width: r.width, height: r.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(c.insetBy(dx: -1, dy: -1)) }) else { return nil }
        return c
    }

    static func needsLeadingSpace() -> Bool {
        guard let el = element() else { return false }
        var value: CFTypeRef?, range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range, CFGetTypeID(range) == AXValueGetTypeID() else { return false }
        var r = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &r) else { return false }
        return LiveSupport.needsSpace(before: text, cursor: r.location)
    }

    static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): CFEqual(x, y)
        default: false
        }
    }
}

enum Clip {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    @discardableResult
    static func write(_ text: String, _ pb: NSPasteboard, private hidden: Bool = true) -> Int {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if hidden {
            item.setData(Data(), forType: transient)
            item.setData(Data(), forType: concealed)
        }
        pb.writeObjects([item])
        return pb.changeCount
    }

    static func save(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }

    static func restore(_ snap: Snapshot, _ pb: NSPasteboard) {
        pb.clearContents()
        let items = snap.map { d -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, v) in d { item.setData(v, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

enum Keys {
    static func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    static func waitForModifiersUp(timeout: Double = 0.8, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            let f = CGEventSource.flagsState(.combinedSessionState)
            let held = f.contains(.maskControl) || f.contains(.maskAlternate) || f.contains(.maskShift) || f.contains(.maskCommand)
            if !held || Date() > deadline { then() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
    }
}

struct InsertTarget {
    let pid: pid_t?
    let bundleId: String?
    let focus: AXUIElement?

    @MainActor static func capture() -> InsertTarget {
        let app = NSWorkspace.shared.frontmostApplication
        return InsertTarget(pid: app?.processIdentifier, bundleId: app?.bundleIdentifier, focus: Focus.element())
    }
}

enum InsertDecision: Equatable {
    case paste
    case copy(String)

    static func decide(mode: InsertMode, trusted: Bool, sameApp: Bool, sameField: Bool, ownAppFront: Bool,
                       editable: Bool = true) -> InsertDecision {
        guard mode == .paste else { return .copy("Copied") }
        guard trusted else { return .copy("Copied · allow Accessibility") }
        guard !ownAppFront else { return .copy("Copied") }
        guard editable else { return .copy("Copied") }
        guard sameApp else { return .copy("Copied — app changed") }
        guard sameField else { return .copy("Copied — field changed") }
        return .paste
    }
}

enum TextShape {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]

    static func terminalSafe(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let kept = normalized.unicodeScalars.filter { u in
            if u == "\n" || u == "\t" { return true }
            if u.value < 0x20 || u.value == 0x7f { return false }
            if (0x80...0x9f).contains(u.value) { return false }
            return true
        }
        var out = String(String.UnicodeScalarView(kept))
        while let last = out.last, last.isNewline || last == " " || last == "\t" { out.removeLast() }
        return out
    }

    static func forTarget(_ text: String, bundleId: String?) -> String {
        terminals.contains(bundleId ?? "") ? terminalSafe(text) : text
    }
}

@MainActor
enum Inserter {
    static func insert(_ text: String, into target: InsertTarget, config: Config) -> String {
        let pb = NSPasteboard.general
        let saved = Clip.save(pb)
        let now = NSWorkspace.shared.frontmostApplication
        let shaped = TextShape.forTarget(text, bundleId: target.bundleId)
        let decision = InsertDecision.decide(mode: config.insert, trusted: Access.trusted,
                                             sameApp: now?.processIdentifier == target.pid,
                                             sameField: Focus.same(target.focus, Focus.element()),
                                             ownAppFront: now?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                                             editable: Focus.isEditable(Focus.element()))
        switch decision {
        case .copy(let label):
            Clip.write(shaped, pb, private: false)
            return label
        case .paste:
            let ours = Clip.write(shaped, pb)
            Keys.waitForModifiersUp {
                Keys.paste()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if !config.keepInClipboard, pb.changeCount == ours { Clip.restore(saved, pb) }
                }
            }
            return "Done"
        }
    }
}
