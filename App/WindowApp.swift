import AppKit
import QuartzCore
import SwiftUI
import WidgetKit
import Combine
import ServiceManagement
import WindowCore

@main
@MainActor
final class WindowApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let panel = KeyablePanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var showPanelWhenReady = false
    private var showAlertSettingsWhenReady = false
    private var ready = false
    private var fixture: TarasRulerModel.PanelSnapshot?
    private let controller = TarasLiveController()
    private var observation: AnyCancellable?
    private let lifecycle = TarasPanelLifecycle()
    private var trackingMenu = false
    // Leave room in the transparent window for the custom SwiftUI shadow.
    private let shadowInset: CGFloat = 96

    static func main() {
        let application = NSApplication.shared
        let delegate = WindowApp()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        do { try WidgetSnapshot.writeFixtureIfRequested() }
        catch { NSLog("Window widget fixture: %@", error.localizedDescription) }
        #endif

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setContentSize(NSSize(width: 360 + 2 * shadowInset, height: 401 + shadowInset))
        #if DEBUG
        if let flag = CommandLine.arguments.firstIndex(of: "--fixture"),
           CommandLine.arguments.indices.contains(flag + 1) {
            let name = CommandLine.arguments[flag + 1]
            if let fixture = TarasPanelFixtures.all.first(where: { $0.name == name }) {
                self.fixture = fixture.snapshot
                showPanelWhenReady = true
            } else {
                NSLog("Unknown Window fixture: %@", name)
            }
        }
        #endif
        installPanelContent()
        assert(panel.canBecomeKey && !panel.isOpaque && !panel.hasShadow)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.rulerGlyph()
            button.imagePosition = .imageLeading
            button.toolTip = "Open Window to check departure times"
            button.title = fixture?.menuTitle ?? controller.presentation.menuTitle
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            updateStatusItem(title: button.title)
            button.target = self
            button.action = #selector(togglePanel)
        }
        NSApp.mainMenu = mainMenu()
        controller.onOpen = { [weak self] in self?.showPanel() }
        if fixture == nil {
            observation = controller.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.syncLiveState() }
            controller.startRuntime()
            syncLiveState()
        }
        ready = true
        if showAlertSettingsWhenReady {
            showAlertSettingsWhenReady = false
            settings()
        } else if showPanelWhenReady || (fixture == nil && !UserDefaults.standard.bool(forKey: "window.menuBarIntroduced")) {
            showPanel()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "window" && $0.host == "alerts" }) {
            if ready { settings() } else { showAlertSettingsWhenReady = true }
        } else if urls.contains(where: { $0.scheme == "window" && $0.host == "panel" }) {
            showPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        closePanel()
        if fixture == nil {
            controller.shutdown()
            syncLiveState()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if fixture == nil { controller.becameActive() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !trackingMenu, !controller.requestingAlertPermission else { return }
        closePanel()
    }

    func showPanel() {
        guard ready else { showPanelWhenReady = true; return }
        showPanelWhenReady = false
        if lifecycle.phase == .open { panel.makeKeyAndOrderFront(nil); return }
        let wasClosed = lifecycle.phase == .closed
        if wasClosed { installPanelContent(); panel.alphaValue = 0 }
        let button = statusItem?.button
        let buttonWindow = button?.window
        let buttonScreen = buttonWindow?.screen
        var buttonFrame: NSRect?
        if let button, let buttonWindow {
            buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        }
        guard let screen = buttonScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            NSLog("Window panel placement: no screen available")
            return
        }
        let placement = TarasPanelPlacement.resolve(buttonFrame: buttonFrame, screenFrame: buttonScreen?.frame,
                                                    visibleFrame: screen.visibleFrame)
        NSLog("Window panel placement: %@", placement.path.rawValue)
        if wasClosed { panel.setFrameOrigin(NSPoint(x: placement.origin.x - shadowInset, y: placement.origin.y - shadowInset)) }
        if fixture == nil && !UserDefaults.standard.bool(forKey: "window.menuBarIntroduced") {
            UserDefaults.standard.set(true, forKey: "window.menuBarIntroduced")
        }
        let generation = lifecycle.fade.open()
        NSApp.activate()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        statusItem?.button?.highlight(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TarasMotion.openDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.lifecycle.fade.complete(generation) }
        }

        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, !self.trackingMenu, !self.controller.requestingAlertPermission else { return event }
            let point = NSEvent.mouseLocation
            let contentFrame = NSRect(x: self.panel.frame.minX + self.shadowInset, y: self.panel.frame.minY + self.shadowInset, width: 360, height: 401)
            let statusFrame = self.statusItem?.button?.window?.frame
            if !contentFrame.contains(point) && statusFrame?.contains(point) != true {
                self.closePanel()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, !self.trackingMenu, !self.controller.requestingAlertPermission else { return }
            self.closePanel()
        }
    }

    private func installPanelContent() {
        panel.contentView = NSHostingView(rootView: Group {
            if let fixture {
                TarasPanelView(snapshot: fixture, action: { [weak self] action in
                    if action == .close { self?.closePanel() }
                })
            } else {
                TarasLivePanel(controller: controller, lifecycle: lifecycle,
                               gear: { [weak self] in self?.showGearMenu() },
                               close: { [weak self] in self?.closePanel() })
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 48, x: 0, y: 24)
        .padding([.horizontal, .bottom], shadowInset)
        .frame(width: 360 + 2 * shadowInset, height: 401 + shadowInset, alignment: .top))
    }

    private func syncLiveState() {
        updateStatusItem(title: controller.presentation.menuTitle)
        do { try WidgetSnapshot.write(controller.planSnapshot(), now: controller.now) }
        catch { NSLog("Window widget snapshot: %@", error.localizedDescription) }
    }

    private func updateStatusItem(title: String) {
        guard let button = statusItem?.button else { return }
        if button.title != title { button.title = title }
        let words = title.trimmingCharacters(in: .whitespaces)
        let sentence = words.hasPrefix("Leave ") && words != "Leave now"
            ? "leave at " + words.dropFirst(6) : words.lowercased()
        let label = sentence.isEmpty ? "Window" : "Window, " + sentence
        let alertsOff = controller.presentation.snapshot.alertsOff
        let spokenLabel = alertsOff && words != "Alerts off" ? label + ", alerts off" : label
        if button.accessibilityLabel() != spokenLabel { button.setAccessibilityLabel(spokenLabel) }
    }

    private func showGearMenu() {
        let menu = NSMenu()
        for (title, selector) in [("Edit Journey…", #selector(editJourney)), ("Watch Details…", #selector(details)),
                                  ("Settings…", #selector(settings)), ("I’m leaving", #selector(leaving)),
                                  ("Stop watching", #selector(stopWatching))] {
            if selector == #selector(leaving) { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: selector == #selector(settings) ? "," : "")
            item.target = self
            item.isEnabled = selector == #selector(leaving) ? controller.canLeave
                : selector == #selector(stopWatching) ? controller.active : true
        }
        if controller.canUndoStop {
            let undo = menu.addItem(withTitle: "Undo Stop Watching", action: #selector(undoStopWatching), keyEquivalent: "z")
            undo.target = self
        }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let about = menu.addItem(withTitle: "About Window", action: #selector(about), keyEquivalent: "")
        about.target = self
        menu.addItem(withTitle: "Quit Window", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        trackingMenu = true
        defer { trackingMenu = false }
        // Open just under the gear (36 pt circle, 12 pt in from the footer's left and bottom edges).
        guard let content = panel.contentView else { return }
        let gearBottom: CGFloat = content.isFlipped ? 401 - 12 : shadowInset + 12
        let below = NSPoint(x: shadowInset + 12, y: content.isFlipped ? gearBottom + 4 : gearBottom - 4)
        menu.popUp(positioning: nil, at: below, in: content)
    }
    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Window open at login: %@", error.localizedDescription)
        }
        // macOS can hold a new login item for approval; send the person to the one place that grants it.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc private func about() {
        closePanel()
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func details() { closePanel(); controller.showDetails() }
    @objc private func leaving() { closePanel(); controller.leave() }
    @objc private func stopWatching() { controller.stop() }
    @objc private func undoStopWatching() { controller.undoStop() }
    @objc private func editJourney() { closePanel(); controller.editJourney() }
    @objc private func settings() { closePanel(); controller.showSettings() }

    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu()
        let settingsItem = app.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
        settingsItem.target = self
        app.addItem(withTitle: "Quit Window", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                     ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        for submenu in [app, file, edit] { let item = NSMenuItem(); item.submenu = submenu; menu.addItem(item) }
        return menu
    }

    private static func rulerGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.labelColor.setFill()
            for (x, top, height) in [(1.5, 9.0, 5.0), (4.5, 9.0, 5.0), (7.3, 2.0, 12.0),
                                     (10.1, 9.0, 5.0), (13.1, 9.0, 5.0)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 16 - top - height, width: 1.4, height: height),
                             xRadius: 0.7, yRadius: 0.7).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Window"
        return image
    }

    @objc func togglePanel() {
        if panel.isVisible && lifecycle.phase != .closing {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func closePanel() {
        guard let generation = lifecycle.fade.close() else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TarasMotion.closeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.lifecycle.fade.complete(generation) else { return }
                self.panel.orderOut(nil)
                self.statusItem?.button?.highlight(false)
                self.installPanelContent()
                if let localMonitor = self.localMonitor { NSEvent.removeMonitor(localMonitor) }
                if let globalMonitor = self.globalMonitor { NSEvent.removeMonitor(globalMonitor) }
                self.localMonitor = nil
                self.globalMonitor = nil
            }
        }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onClose: (() -> Void)?
    override func performClose(_ sender: Any?) { onClose?() }
}

@MainActor
private final class TarasPanelLifecycle: ObservableObject {
    @Published var fade = TarasPanelFade()
    var phase: TarasPanelFade.Phase { fade.phase }
}

// 2026-11-08, GPT-6: avoid the Xcode 27 State macro in the restricted build.
private typealias LivePanelState<Value> = SwiftUI.State<Value>

private struct TarasLivePanel: View {
    @ObservedObject var controller: TarasLiveController
    @ObservedObject var lifecycle: TarasPanelLifecycle
    let gear: () -> Void
    let close: () -> Void
    @LivePanelState private var displayed: TarasLivePresentation
    @LivePanelState private var queued: TarasLivePresentation?

    init(controller: TarasLiveController, lifecycle: TarasPanelLifecycle,
         gear: @escaping () -> Void, close: @escaping () -> Void) {
        self.controller = controller
        self.lifecycle = lifecycle
        self.gear = gear
        self.close = close
        _displayed = LivePanelState(initialValue: controller.presentation)
    }

    var body: some View {
        let presentation = displayed
        TarasPanelView(snapshot: presentation.snapshot, action: { action in
            switch action {
            case .settings: gear()
            case .editJourney: close(); controller.editJourney()
            case .primary:
                if presentation.snapshot.capsule == "I'M LEAVING" {
                    close()
                    controller.leave()
                } else { controller.primary(presentation) }
            case .useSample(let date): controller.useSample(date, from: presentation)
            case .delay: controller.delay()
            case .refresh: controller.recheck()
            case .scope: break
            case .close: close()
            }
        }, change: presentation.change)
        .onReceive(controller.objectWillChange) { _ in
            guard lifecycle.phase == .open else {
                queued = controller.presentation
                return
            }
            displayed = controller.presentation
        }
        .onChange(of: lifecycle.phase) { _, phase in
            if phase == .open, let queued {
                displayed = queued
                self.queued = nil
            }
        }
    }
}
