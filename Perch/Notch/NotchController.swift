import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the panel and drives state transitions: hover → glance, click/hotkey → open, any exit → idle.
final class NotchController {
    let model: NotchModel
    private let panel: NotchPanel
    private let screens = ScreenManager()
    private var monitors: [Any] = []
    /// App that was frontmost when the panel opened; gets the keyboard back on close.
    private var previousApp: NSRunningApplication?

    init(activities: ActivityCenter, search: SearchEngine) {
        model = NotchModel(geometry: screens.geometry, activities: activities, search: search)
        panel = NotchPanel(frame: screens.geometry.windowFrame)
        search.index.onUpdate = { [weak self] in self?.model.refreshResults() }
        search.files.onUpdate = { [weak self] in self?.model.refreshResults() }
    }

    func start() {
        let hostingView = FirstMouseHostingView(rootView: NotchRootView(model: model, controller: self))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.orderFrontRegardless()

        screens.onChange = { [weak self] geometry in
            guard let self else { return }
            model.geometry = geometry
            panel.setFrame(geometry.windowFrame, display: true)
            updateHover()
        }

        HotkeyManager.shared.onPress = { [weak self] in self?.toggle() }
        observeHotkey()

        installEventMonitors()

        if !AppSettings.shared.onboardingDone { beginFirstRun() }
    }

    /// Registers the configured hotkey and re-registers whenever the setting changes.
    private func observeHotkey() {
        let shortcut = withObservationTracking {
            AppSettings.shared.hotkey
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHotkey() }
        }
        if !HotkeyManager.shared.register(shortcut) {
            NSLog("Perch: \(shortcut.displayString) is already taken by another app; open Perch by clicking the notch.")
        }
    }

    // MARK: Transitions

    func toggle() {
        switch model.state {
        case .open: close()
        case .onboarding: if model.onboarding?.mode == .settings { finishOnboarding() }
        case .idle, .glance: open()
        }
    }

    func open() {
        guard model.state != .open, model.state != .onboarding else { return }
        model.hint = nil
        model.search.index.refreshIfStale()
        model.resetSearch()
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
        panel.makeKeyAndOrderFront(nil)
        withAnimation(NotchMotion.expand) { model.state = .open }
        focusSearchField()
        updateHover()
    }

    /// Renders the open state now and hands the search field first-responder status,
    /// so keystrokes typed right after the hotkey are not lost.
    private func focusSearchField() {
        guard let root = panel.contentView else { return }
        root.layoutSubtreeIfNeeded()
        var stack = [root]
        while let view = stack.popLast() {
            if let field = view as? NSTextField, field.isEditable {
                panel.makeFirstResponder(field)
                return
            }
            stack.append(contentsOf: view.subviews)
        }
    }

    /// - Parameter restoreFocus: hand keyboard focus back to the frontmost app's window.
    ///   Skip it when another app is about to take focus anyway (launch, click elsewhere).
    func close(restoreFocus: Bool = true) {
        guard model.state == .open else { return }
        withAnimation(NotchMotion.collapse) {
            model.state = .idle
            model.isHovering = false
        }
        if restoreFocus, panel.isKeyWindow {
            returnKeyboardFocus()
        }
        updateHover()
    }

    // MARK: Onboarding

    /// First launch: the pill pulses hello, then the card drops from the notch.
    private func beginFirstRun() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !AppSettings.shared.onboardingDone else { return }
            model.pulse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, !AppSettings.shared.onboardingDone else { return }
                showOnboarding(.firstRun)
            }
        }
    }

    /// Drops the onboarding card (first run) or the single settings page (pill menu → Settings…).
    func showOnboarding(_ mode: OnboardingMode) {
        guard model.state != .onboarding else { return }
        if model.state != .open {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
        }
        model.hint = nil
        model.onboarding = OnboardingState(mode: mode)
        panel.makeKeyAndOrderFront(nil)
        withAnimation(NotchMotion.expand) {
            model.state = .onboarding
            model.isHovering = false
        }
        updateHover()
    }

    /// Collapses the card. After the first run it also records completion and shows "Press <hotkey> anytime".
    func finishOnboarding() {
        guard model.state == .onboarding else { return }
        let firstRun = model.onboarding?.mode == .firstRun
        if firstRun { AppSettings.shared.onboardingDone = true }
        let hint = "Press \(AppSettings.shared.hotkey.displayString) anytime"
        withAnimation(NotchMotion.collapse) {
            model.state = .idle
            model.isHovering = false
            if firstRun { model.hint = hint }
        }
        if panel.isKeyWindow { returnKeyboardFocus() }
        updateHover()
        guard firstRun else { return }
        // 2 s on screen after the 0.6 s collapse morph.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, model.hint == hint else { return }
            withAnimation(NotchMotion.collapse) { self.model.hint = nil }
        }
    }

    /// Gives the keyboard back to the app the user was in, without hiding the panel,
    /// so the collapse morph keeps playing on screen.
    private func returnKeyboardFocus() {
        panel.makeFirstResponder(nil) // stray keys no longer reach the search field
        if let app = previousApp, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
        // Fallback if the panel is still key once the morph is done: re-ordering the
        // idle pill releases key status and is not visible at that point.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, model.state != .open, model.state != .onboarding, panel.isKeyWindow else { return }
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func run(_ result: SearchResult) {
        switch result {
        case let .app(app):
            model.search.recordLaunch(of: app)
            close(restoreFocus: false)
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        case let .answer(_, value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            close()
        case let .timer(duration):
            model.activities.startTimer(duration: duration)
            close()
        case let .file(url):
            close(restoreFocus: false)
            NSWorkspace.shared.open(url)
        case .ask:
            // The Ask AI panel arrives with task 3.4; until then the row is display-only.
            break
        case let .web(query):
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            close(restoreFocus: false)
            if let url = components?.url { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: Events

    private func installEventMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                guard let self else { return event }
                return handleLocal(event)
            }
        ) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged],
            handler: { [weak self] event in
                guard let self else { return }
                handleGlobal(event)
            }
        ) {
            monitors.append(global)
        }
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            return handleKeyDown(event)
        case .leftMouseDown, .rightMouseDown:
            if model.state == .open, !isMouseInside {
                close()
                return nil
            }
            return event
        default:
            updateHover()
            return event
        }
    }

    private func handleGlobal(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            // A click in another app: it takes focus itself.
            close(restoreFocus: false)
        default:
            updateHover()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard model.state == .open, event.window === panel else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
            return nil
        case kVK_DownArrow:
            model.moveSelection(by: 1)
            return nil
        case kVK_UpArrow:
            model.moveSelection(by: -1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let result = model.selectedResult {
                if modifiers == .command, case let .file(url) = result {
                    close(restoreFocus: false)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    run(result)
                }
            }
            return nil
        default:
            break
        }

        if modifiers == .command,
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           let scope = SearchScope(rawValue: digit - 1) {
            model.scope = scope
            return nil
        }
        return event
    }

    private var isMouseInside: Bool {
        model.geometry.screenRect(fromWindowRect: model.interactiveRect).contains(NSEvent.mouseLocation)
    }

    /// Mouse passes through the transparent panel except over the surface itself.
    private func updateHover() {
        let inside = isMouseInside
        // Even while open, clicks outside the surface fall through to the app underneath;
        // the global monitor then closes the panel and the click still lands where the user aimed.
        panel.ignoresMouseEvents = !inside

        switch model.state {
        case .open, .onboarding:
            break
        case .idle:
            guard inside != model.isHovering else { return }
            withAnimation(inside && !model.activities.items.isEmpty ? NotchMotion.expand : NotchMotion.hover) {
                model.isHovering = inside
                if inside, !model.activities.items.isEmpty { model.state = .glance }
            }
        case .glance:
            guard !inside else { return }
            withAnimation(NotchMotion.collapse) {
                model.state = .idle
                model.isHovering = false
            }
        }
    }
}
