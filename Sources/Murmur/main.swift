import AppKit
import ServiceManagement
import SwiftUI

enum SingleInstance {
    static func others(bundleId: String, own: pid_t) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { $0.processIdentifier != own && !$0.isTerminated }
    }

    static func shouldExit(otherPIDs: [pid_t], own: pid_t) -> Bool {
        otherPIDs.contains { $0 != own }
    }
}

enum WaveMark {
    static let heights: [CGFloat] = [0.36, 0.72, 1.0, 0.58, 0.82, 0.42]

    static func template(size: CGFloat = 18, recording: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let k = size / 18
            let bar = 2.1 * k
            let gap = 0.9 * k
            let total = CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap
            var x = (size - total) / 2
            NSColor.black.setFill()
            for h in heights {
                let height = max(bar, h * 14 * k)
                let rect = NSRect(x: x, y: (size - height) / 2, width: bar, height: height)
                NSBezierPath(roundedRect: rect, xRadius: bar / 2, yRadius: bar / 2).fill()
                x += bar + gap
            }
            if recording {
                NSBezierPath(ovalIn: NSRect(x: size - 5.4 * k, y: size - 5.4 * k, width: 5 * k, height: 5 * k)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = Identity.appName
        return image
    }
}

enum Credits {
    static var text: NSAttributedString {
        let lines = [
            "Speech models run on this Mac.",
            "Parakeet: NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0), Ultra and Redux by Moondream, via FluidAudio (Apache-2.0).",
            "Whisper large-v3-turbo: OpenAI (MIT), Core ML build by Argmax, via WhisperKit (MIT).",
            "Updates: Sparkle (MIT).",
        ]
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return NSAttributedString(string: lines.joined(separator: "\n"),
                                  attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p])
    }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsWindow()
    private let setup = SetupWindow()
    private var fresh = false
    private var statusItem: NSStatusItem?
    private var launchedAtLogin = false
    private var axWatch: Timer?
    private var axAsked = false
    private var axWarned: TalkKey?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Migration.run()
        VoiceStore.removeLegacyVoicePrint()
        Config.dropLegacyKeys()
        fresh = !FileManager.default.fileExists(atPath: Config.fileURL.path)
        launchedAtLogin = Self.isLoginLaunch()
        let me = ProcessInfo.processInfo.processIdentifier
        let others = SingleInstance.others(bundleId: Identity.bundleId, own: me)
        guard SingleInstance.shouldExit(otherPIDs: others.map(\.processIdentifier), own: me) else { return }
        let quiet = launchedAtLogin || CommandLine.arguments.contains("--background")
        if !quiet, let other = others.first, let url = other.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
            return
        }
        exit(0)
    }

    private static func isLoginLaunch() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 300
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard !SingleInstance.shouldExit(otherPIDs: SingleInstance.others(bundleId: Identity.bundleId, own: me).map(\.processIdentifier), own: me) else { return }
        NSApp.setActivationPolicy(.accessory)
        AudioFiles.cleanLeftovers()
        Updates.shared.start()
        settings.model.onChange = { [weak self] in self?.apply() }
        settings.model.runSetup = { [weak self] in self?.openSetup() }
        HotKey.shared.onPress = { Dictation.shared.press() }
        HotKey.shared.onRelease = { Dictation.shared.release() }
        TalkKeyMonitor.shared.onPress = { Dictation.shared.press() }
        TalkKeyMonitor.shared.onRelease = { Dictation.shared.release() }
        TalkKeyMonitor.shared.onCancel = { Dictation.shared.cancelChord() }
        TalkKeyMonitor.shared.onToggle = { Dictation.shared.toggleFromMenu() }
        Dictation.shared.onStateChange = { [weak self] in self?.updateIcon() }
        ModelStore.shared.onChange = { [weak self] id, state in self?.modelChanged(id, state) }
        MicInput.shared.onChange = { Dictation.shared.inputChanged() }
        MicInput.shared.start()
        NSApp.mainMenu = MainMenu.make(app: self, name: Identity.appName)
        apply()
        let args = CommandLine.arguments
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.launchedAtLogin, !args.contains("--background") else { return }
            if MurmurSetup.shouldOfferSetup(fresh: self.fresh, background: false) {
                self.openSetup()
            } else {
                self.settings.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioFiles.cleanLeftovers()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    private func modelChanged(_ id: EngineID, _ state: ModelState) {
        var cfg = Config.load()
        switch PendingEngine.react(id: id, state: state, pending: PendingEngine.value, current: cfg.engine) {
        case .use:
            PendingEngine.value = nil
            cfg.engine = id.rawValue
        case .fallBack:
            cfg.engine = EngineID.apple.rawValue
        case .nothing:
            return
        }
        Config.save(cfg)
        settings.model.cfg = cfg
        apply()
    }

    private func apply() {
        let cfg = Config.load()
        let trusted = Access.trusted
        switch TalkKeySetup.plan(key: cfg.talkKey, trusted: trusted, hotkey: cfg.hotkey) {
        case .carbon:
            TalkKeyMonitor.shared.stop()
            HotKey.shared.register(cfg.hotkey)
        case .modifier:
            HotKey.shared.unregister()
            TalkKeyMonitor.shared.use(cfg.talkKey)
        case .modifierWithFallback:
            TalkKeyMonitor.shared.use(cfg.talkKey)
            HotKey.shared.register(cfg.hotkey)
        }
        watchAccessibility(cfg, trusted: trusted)
        Dictation.shared.prewarm()
        let svc = SMAppService.mainApp
        if cfg.launchAtLogin {
            if svc.status != .enabled { try? svc.register() }
        } else if svc.status == .enabled {
            try? svc.unregister()
        }
        if cfg.showMenuBarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.delegate = self
                item.menu = menu
                statusItem = item
            }
            updateIcon()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        if let id = EngineID(rawValue: cfg.engine), id != .apple, ModelStore.shared.isReady(id) {
            EngineHub.shared.warm(id)
        }
    }

    private func watchAccessibility(_ cfg: Config, trusted: Bool) {
        guard TalkKeyMonitor.needsAccessibility(cfg.talkKey), !trusted else {
            axWatch?.invalidate()
            axWatch = nil
            axWarned = nil
            return
        }
        if axWarned != cfg.talkKey {
            axWarned = cfg.talkKey
            DictationLog.logger.notice("talk key needs accessibility: \(cfg.talkKey.rawValue, privacy: .public)")
            HUD.shared.begin(anchor: nil)
            HUD.shared.show(.failed(HUDText.allowAccessibility(TalkKeyText.keyName(cfg))), hideAfter: 4)
            if !axAsked {
                axAsked = true
                Access.request()
            }
        }
        guard axWatch == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Access.trusted else { return }
                self.axWatch?.invalidate()
                self.axWatch = nil
                self.apply()
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        axWatch = t
    }

    private func updateIcon() {
        statusItem?.button?.image = WaveMark.template(recording: Dictation.shared.isListening)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = Config.current
        let listening = Dictation.shared.isListening
        menu.addItem(withTitle: listening ? "Stop Listening" : "Start Listening", action: #selector(toggleListening), keyEquivalent: "").target = self
        if let text = TalkKeyText.hint(cfg) {
            let hint = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        let wanted = EngineID(rawValue: cfg.engine) ?? .apple
        let used = EngineHub.effective(wanted) { ModelStore.shared.isReady($0) }
        let engine = NSMenuItem(title: "Model: \(ModelInfo.info(used).name)", action: nil, keyEquivalent: "")
        engine.isEnabled = false
        menu.addItem(engine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Set Up \(Identity.appName)…", action: #selector(openSetup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(Identity.appName)", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func toggleListening(_ sender: Any? = nil) { Dictation.shared.toggleFromMenu() }
    @objc private func openSettings(_ sender: Any? = nil) { settings.show() }
    @objc private func openSetup(_ sender: Any? = nil) {
        setup.onFinish = { [weak self] in self?.setupFinished() }
        setup.show()
    }

    private func setupFinished() {
        apply()
        let fresh = Config.load()
        if settings.model.cfg != fresh { settings.model.cfg = fresh }
    }

    @objc private func checkUpdates(_ sender: Any? = nil) { Updates.shared.checkNow() }

    @objc private func showAbout(_ sender: Any? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Credits.text])
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
    @objc private func quit() { NSApp.terminate(nil) }
}

enum PendingEngine {
    enum Reaction: Equatable { case use, fallBack, nothing }

    static let key = "useWhenReady"

    static var value: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func react(id: EngineID, state: ModelState, pending: String?, current: String) -> Reaction {
        if state.isReady, pending == id.rawValue { return .use }
        if state == .missing, current == id.rawValue { return .fallBack }
        return .nothing
    }
}

enum MainMenu {
    static func make(app target: AnyObject, name: String) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: name)
        add(appMenu, "About \(name)", "showAbout", "", target)
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", "openSettings", ",", target)
        add(appMenu, "Set Up \(name)…", "openSetup", "", target)
        add(appMenu, "Check for Updates…", "checkUpdates", "", target)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        attach(appMenu, to: main, title: name)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        attach(file, to: main, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        attach(edit, to: main, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        attach(window, to: main, title: "Window")
        NSApp.windowsMenu = window
        return main
    }

    private static func add(_ menu: NSMenu, _ title: String, _ selector: String, _ key: String, _ target: AnyObject) {
        menu.addItem(withTitle: title, action: NSSelectorFromString(selector + ":"), keyEquivalent: key).target = target
    }

    private static func attach(_ menu: NSMenu, to main: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}

if CommandLine.arguments.contains("--login-off") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller
    app.run()
}
