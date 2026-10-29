import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the panel and drives state transitions: hover → glance, click → home, hotkey → open, any exit → idle.
final class NotchController {
    let model: NotchModel
    private let panel: NotchPanel
    private let screens = ScreenManager()
    private var monitors: [Any] = []
    /// App that was frontmost when the panel opened; gets the keyboard back on close.
    private var previousApp: NSRunningApplication? {
        didSet { model.pasteTargetName = previousApp?.localizedName }
    }
    /// Runs the conversion the user picks from the drop zone's action list.
    let converter: ImageConverter
    let dropZone: DropZoneController

    init(activities: ActivityCenter, search: SearchEngine) {
        model = NotchModel(geometry: screens.geometry, activities: activities, search: search)
        panel = NotchPanel(frame: screens.geometry.windowFrame)
        converter = ImageConverter(activities: activities)
        dropZone = DropZoneController(model: model, panel: panel, converter: converter)
        search.index.onUpdate = { [weak self] in self?.model.refreshResults() }
        search.files.onUpdate = { [weak self] in self?.model.refreshResults() }
    }

    func start() {
        let hostingView = FirstMouseHostingView(rootView: NotchRootView(model: model, controller: self))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        hostingView.dropTarget = dropZone
        dropZone.refreshPointer = { [weak self] in self?.updateHover() }
        dropZone.releaseKeyboard = { [weak self] in self?.returnKeyboardFocus() }
        dropZone.capturePreviousApp = { [weak self] in
            let frontmost = NSWorkspace.shared.frontmostApplication
            self?.previousApp = frontmost == .current ? nil : frontmost
        }
        panel.orderFrontRegardless()

        screens.onChange = { [weak self] geometry in
            guard let self else { return }
            model.geometry = geometry
            panel.setFrame(geometry.windowFrame, display: true)
            updateHover()
        }
        screens.holdsPosition = { [weak self] in
            guard let self else { return true }
            return model.state != .idle || model.isHovering
        }
        screens.refresh() // first extras scan, now that changes reach the panel

        HotkeyManager.shared.onPress = { [weak self] in self?.toggle() }
        observeHotkey()
        observeClipboard()

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
        case .dropZone: dropZone.cancelChoosing(restoreFocus: true)
        case .idle, .glance, .home: open()
        }
    }

    /// Click on the notch or island: the Home modules. The hotkey still goes straight to search.
    func openHome() {
        guard model.state == .idle || model.state == .glance else { return }
        model.hint = nil
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
        // Key, so typing in Home reaches handleHomeKey; no text field has focus yet.
        panel.makeKeyAndOrderFront(nil)
        model.homePage = .modules
        withAnimation(NotchMotion.expand) {
            model.state = .home
            model.isHovering = false
        }
        updateHover()
    }

    func showHomePage(_ page: HomePage) {
        guard model.state == .home else { return }
        withAnimation(NotchMotion.homePage) { model.homePage = page }
    }

    /// Opens the command panel. From Home it keeps the app captured when Home opened and remembers to return there.
    func open(scope: SearchScope = .all) {
        guard model.state != .open, model.state != .onboarding, model.state != .dropZone else { return }
        model.searchReturnsHome = model.state == .home
        model.hint = nil
        model.search.index.refreshIfStale()
        ClipboardPanelState.shared.reset()
        model.resetSearch()
        model.scope = scope
        if !model.searchReturnsHome {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
        }
        panel.makeKeyAndOrderFront(nil)
        withAnimation(NotchMotion.expand) { model.state = .open }
        focusSearchField()
        updateHover()
    }

    /// Esc from a search that Home opened: back to the module grid, keyboard still in Perch.
    private func returnHome() {
        panel.makeFirstResponder(nil) // typing goes to handleHomeKey again, not the old field
        model.homePage = .modules
        withAnimation(NotchMotion.expand) { model.state = .home }
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
        guard model.state == .open || model.state == .home else { return }
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
        if model.state != .open, model.state != .home {
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
            guard let self, model.state == .idle || model.state == .glance, panel.isKeyWindow else { return }
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
        case let .clip(item):
            runClip(item, .paste)
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

    // MARK: Clipboard

    /// Filter popover and the clipboard list react to the store; `ClipboardPanelState` owns the UI state.
    private func observeClipboard() {
        let state = ClipboardPanelState.shared
        state.onFilterChange = { [weak self] in self?.model.refreshResults() }
        state.observeStore { [weak self] in
            guard let self, model.state == .open, model.scope == .clipboard else { return }
            model.refreshResults(keepingSelection: true)
        }
    }

    /// ⌘P filter popover, ↵ chords and ⌘. while the Clipboard chip is showing. Returns true when consumed.
    private func handleClipboardKey(_ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        let state = ClipboardPanelState.shared
        let chord = modifiers.intersection([.command, .control, .option, .shift])
        let code = Int(event.keyCode)

        if code == kVK_ANSI_P, chord == .command {
            state.toggleFilter()
            return true
        }
        if state.isFilterOpen {
            switch code {
            case kVK_Escape: state.isFilterOpen = false
            case kVK_DownArrow: state.moveFilterCursor(by: 1)
            case kVK_UpArrow: state.moveFilterCursor(by: -1)
            case kVK_Return, kVK_ANSI_KeypadEnter: state.apply(ClipFilter.allCases[state.filterCursor])
            default: return false // typing keeps going to the search field
            }
            return true
        }
        if state.isConfirmingClear, code == kVK_Escape {
            state.isConfirmingClear = false
            return true
        }

        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard case let .clip(item)? = model.selectedResult else { return true }
            switch chord {
            case []: runClip(item, .paste)
            case .command: runClip(item, .copy)
            case [.control, .command]: runClip(item, .plainPaste)
            case .option: runClip(item, .keepOpen)
            default: return false
            }
            return true
        case kVK_ANSI_Period where chord == .command:
            if case let .clip(item)? = model.selectedResult { togglePin(item) }
            return true
        default:
            return false
        }
    }

    func togglePin(_ item: ClipboardItem) {
        if item.isPinned { ClipboardStore.shared.unpin(item.id) } else { ClipboardStore.shared.pin(item.id) }
    }

    /// Writes the row to the pasteboard, then (depending on `requested`) pastes it into the app that was frontmost.
    func runClip(_ item: ClipboardItem, _ requested: ClipAction) {
        let paster = Paster.shared
        let store = ClipboardStore.shared
        let state = ClipboardPanelState.shared
        // An image has no plain form: ⌃⌘↵ falls back to ⌘↵.
        let action: ClipAction = requested == .plainPaste && item.kind == .image ? .copy : requested

        if action != .copy, paster.isDoublePaste() { return }
        if case let .missing(message) = paster.write(item, plain: action == .plainPaste) {
            state.showNotice(message) // the row stays
            return
        }

        // ⌥↵ never promotes, even when it degrades to a copy. The marker hides our write from the poller,
        // so promotion is explicit; pinned rows keep their place.
        let promotes = !item.isPinned && action != .keepOpen
        switch action {
        case .copy:
            if promotes { store.promote(item.id) }
            close()
        case .paste, .plainPaste, .keepOpen:
            guard paster.canPaste else {
                if promotes { store.promote(item.id) }
                close()
                flashHint("Copied — enable paste in Settings")
                return
            }
            if action == .keepOpen {
                guard let target = previousApp, !target.isTerminated else {
                    state.showNotice("Copied")
                    return
                }
                paster.postPaste(to: target, direct: true, prepare: {}, completion: {})
                return
            }
            let target = previousApp
            close()
            paster.postPaste(to: target, direct: false, prepare: { [weak self] in self?.releaseKeyStatus() }) {
                if promotes { store.promote(item.id) }
            }
        }
    }

    /// A non-activating panel can stay key after `close()`; the synthetic ⌘V would then land in Perch's own search field.
    private func releaseKeyStatus() {
        guard model.state != .open, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Short message in the collapsed pill; 2 s on screen after the 0.6 s collapse morph.
    private func flashHint(_ text: String) {
        withAnimation(NotchMotion.collapse) { model.hint = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, model.hint == text else { return }
            withAnimation(NotchMotion.collapse) { self.model.hint = nil }
        }
    }

    // MARK: Events

    private func installEventMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseUp, .keyDown],
            handler: { [weak self] event in
                guard let self else { return event }
                return handleLocal(event)
            }
        ) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp],
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
        case .leftMouseUp:
            dropZone.handleMouseUp()
            updateHover()
            return event
        case .leftMouseDown, .rightMouseDown:
            if model.state == .open || model.state == .home, !isMouseInside {
                close()
                return nil
            }
            if model.state == .dropZone, !isMouseInside {
                dropZone.cancelChoosing(restoreFocus: true)
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
            dropZone.cancelChoosing(restoreFocus: false)
        case .leftMouseDragged:
            dropZone.handleDragEvent()
            updateHover()
        case .leftMouseUp:
            dropZone.handleMouseUp()
            updateHover()
        default:
            updateHover()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if model.state == .dropZone { return dropZone.handleKeyDown(event) }
        if model.state == .home, event.window === panel { return handleHomeKey(event) }
        guard model.state == .open, event.window === panel else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if model.scope == .clipboard, handleClipboardKey(event, modifiers) { return nil }

        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.searchReturnsHome { returnHome() } else { close() }
            return nil
        case kVK_DownArrow where model.showsResults:
            model.moveSelection(by: 1)
            return nil
        case kVK_UpArrow where model.showsResults:
            model.moveSelection(by: -1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Nothing to run until the results panel is on screen.
            if model.showsResults, let result = model.selectedResult {
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

    /// Home owns the keyboard. Esc steps back (detail → grid → closed); the first typed character
    /// opens search and the same event is passed on to the now-focused field, so it is not lost.
    private func handleHomeKey(_ event: NSEvent) -> NSEvent? {
        if Int(event.keyCode) == kVK_Escape {
            if model.homePage == .modules { close() } else { showHomePage(.modules) }
            return nil
        }
        // ⌘/⌃ chords keep their menu meaning.
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return event }
        // Arrow and function keys arrive as private-use characters (U+F700…U+F8FF); they do not start a search.
        let typesText = event.characters?.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
                && !(0xF700...0xF8FF).contains(scalar.value)
        } ?? false
        guard typesText else { return nil } // swallowed: no first responder would only beep
        open()
        return event
    }

    private var isMouseInside: Bool {
        model.geometry.screenRect(fromWindowRect: model.interactiveRect).contains(NSEvent.mouseLocation)
    }

    /// Mouse passes through the transparent panel except over the surface itself.
    /// Also called by the view when the open layout changes under a still cursor (results panel appearing, resizing).
    func updateHover() {
        let inside = isMouseInside
        // Even while open, clicks outside the surface fall through to the app underneath;
        // the global monitor then closes the panel and the click still lands where the user aimed.
        panel.ignoresMouseEvents = !inside

        switch model.state {
        case .open, .home, .onboarding, .dropZone:
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
