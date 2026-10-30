import AppKit
import Carbon.HIToolbox
import SwiftUI

/// State of one file drag, from the first drag event to the chosen conversion (or release elsewhere).
struct DropSession: Equatable {
    enum Phase: Equatable {
        /// "Drop to convert" target while the drag is still under way.
        case targeting
        /// Files were dropped; the action list is open.
        case choosing
    }

    var urls: [URL]
    /// Every dragged file is an image Perch can convert.
    var acceptsDrop: Bool
    /// The drag is over the panel.
    var isHighlighted = false
    var phase: Phase = .targeting
    var selection = 0
}

extension NotchModel {
    static let dropBandSize = CGSize(width: NotchGeometry.panelWidth, height: 120)
    private static let dropTargetWidth: CGFloat = 320

    /// Window-coordinate band along the top edge that stays interactive during a drag (PRD drag-target risk).
    static func dropBand(windowWidth: CGFloat) -> CGRect {
        CGRect(x: (windowWidth - dropBandSize.width) / 2, y: 0, width: dropBandSize.width, height: dropBandSize.height)
    }

    var dropZoneShape: ShapeMetrics {
        let notch = geometry.notchSize
        let choosing = drop?.phase == .choosing
        let swell: CGFloat = drop?.isHighlighted == true ? 24 : 0
        switch geometry.style {
        case .notch:
            if choosing {
                return ShapeMetrics(
                    size: CGSize(width: NotchGeometry.panelWidth, height: notch.height + Self.searchRowHeight),
                    top: 0, topRadius: 0, bottomRadius: 22, shoulder: Self.expandedShoulder
                )
            }
            return ShapeMetrics(
                size: CGSize(width: Self.dropTargetWidth + swell, height: notch.height + 52 + swell / 2),
                top: 0, topRadius: 0, bottomRadius: 24, shoulder: Self.expandedShoulder
            )
        case .island:
            if choosing {
                return ShapeMetrics(
                    size: CGSize(width: NotchGeometry.panelWidth, height: Self.searchRowHeight),
                    top: 8, topRadius: Self.searchRowHeight / 2, bottomRadius: Self.searchRowHeight / 2
                )
            }
            let size = CGSize(width: Self.dropTargetWidth + swell, height: 56 + swell / 2)
            return ShapeMetrics(size: size, top: 6, topRadius: size.height / 2, bottomRadius: size.height / 2)
        }
    }
}

/// Receives drag events the panel's content view forwards (`NSDraggingDestination`).
protocol FileDropTarget: AnyObject {
    func dragEntered(_ info: NSDraggingInfo) -> NSDragOperation
    func dragExited()
    func performDrop(_ info: NSDraggingInfo) -> Bool
}

/// Detects file drags system-wide, shows the "Drop to convert" target and runs the chosen conversion.
/// `NotchController` feeds it the global mouse events and routes keys while the action list is open.
final class DropZoneController: FileDropTarget {
    private let model: NotchModel
    private let panel: NotchPanel
    private let converter: ImageConverter

    /// Re-evaluates the pointer rect and `ignoresMouseEvents` (NotchController.updateHover).
    var refreshPointer: () -> Void = {}
    /// Hands the keyboard back to the previous app (NotchController.returnKeyboardFocus).
    var releaseKeyboard: () -> Void = {}
    /// Remembers the frontmost app before the panel takes the key (NotchController.previousApp).
    var capturePreviousApp: () -> Void = {}

    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var releasePoll: Timer?

    init(model: NotchModel, panel: NotchPanel, converter: ImageConverter) {
        self.model = model
        self.panel = panel
        self.converter = converter
    }

    // MARK: Drag detection

    /// Called for every global `.leftMouseDragged`. A changed drag-pasteboard count marks a new drag.
    func handleDragEvent() {
        let pasteboard = NSPasteboard(name: .drag)
        let count = pasteboard.changeCount
        guard count != lastDragChangeCount else { return }
        lastDragChangeCount = count
        guard let urls = Self.fileURLs(in: pasteboard) else { return }
        begin(urls)
    }

    /// Called for every `.leftMouseUp`, global or local. A drag that ends elsewhere restores idle.
    func handleMouseUp() {
        guard model.state == .dropZone, model.drop?.phase == .targeting else { return }
        stopReleasePoll()
        // A drop on the panel arrives just after the global mouse-up; give it time before
        // treating the release as "dropped elsewhere".
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.25))
            guard let self, model.state == .dropZone, model.drop?.phase == .targeting else { return }
            finish(restoreFocus: false)
        }
    }

    private func begin(_ urls: [URL]) {
        guard model.state == .idle || model.state == .glance else { return }
        model.hint = nil
        model.drop = DropSession(urls: urls, acceptsDrop: Self.acceptsAll(urls))
        withAnimation(NotchMotion.expand) {
            model.state = .dropZone
            model.isHovering = false
        }
        panel.ignoresMouseEvents = false
        startReleasePoll()
        refreshPointer()
    }

    /// Backstop for a release the event monitors never see (the drag session swallows it).
    private func startReleasePoll() {
        releasePoll?.invalidate()
        releasePoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self?.handleMouseUp()
            }
        }
    }

    private func stopReleasePoll() {
        releasePoll?.invalidate()
        releasePoll = nil
    }

    // MARK: Closing

    /// Ends the action list (esc, click outside, hotkey). No-op during the target phase.
    func cancelChoosing(restoreFocus: Bool) {
        guard model.state == .dropZone, model.drop?.phase == .choosing else { return }
        finish(restoreFocus: restoreFocus)
    }

    private func finish(restoreFocus: Bool) {
        stopReleasePoll()
        guard model.state == .dropZone else { return }
        withAnimation(NotchMotion.collapse) {
            model.state = .idle
            model.isHovering = false
        }
        if restoreFocus, panel.isKeyWindow { releaseKeyboard() }
        refreshPointer()
    }

    // MARK: Action list

    func choose(_ action: ConversionAction) {
        guard model.state == .dropZone, let drop = model.drop, drop.phase == .choosing else { return }
        converter.run(action, on: drop.urls)
        finish(restoreFocus: true)
    }

    func select(_ index: Int) {
        guard model.drop?.phase == .choosing, ConversionAction.allCases.indices.contains(index) else { return }
        model.drop?.selection = index
    }

    /// Keys while the action list is open: ↑↓ move, ↵ converts, esc closes. Everything else is swallowed.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard model.state == .dropZone, model.drop?.phase == .choosing, event.window === panel else { return event }
        let actions = ConversionAction.allCases
        let selection = model.drop?.selection ?? 0
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(restoreFocus: true)
        case kVK_DownArrow:
            select(min(selection + 1, actions.count - 1))
        case kVK_UpArrow:
            select(max(selection - 1, 0))
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if actions.indices.contains(selection) { choose(actions[selection]) }
        default:
            break
        }
        return nil
    }

    // MARK: FileDropTarget

    func dragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        if model.state != .dropZone {
            // The drag started before the global monitor noticed it.
            if let urls = Self.fileURLs(in: info.draggingPasteboard) { begin(urls) }
        }
        guard model.state == .dropZone, let drop = model.drop, drop.phase == .targeting else { return [] }
        setHighlighted(true)
        return drop.acceptsDrop ? .copy : []
    }

    func dragExited() {
        setHighlighted(false)
    }

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        guard model.state == .dropZone, model.drop?.phase == .targeting,
              let urls = Self.fileURLs(in: info.draggingPasteboard), Self.acceptsAll(urls) else { return false }
        stopReleasePoll()
        capturePreviousApp()
        panel.makeKeyAndOrderFront(nil)
        withAnimation(NotchMotion.expand) {
            model.drop = DropSession(urls: urls, acceptsDrop: true, phase: .choosing)
        }
        refreshPointer()
        return true
    }

    private func setHighlighted(_ highlighted: Bool) {
        guard model.state == .dropZone, model.drop?.phase == .targeting, model.drop?.isHighlighted != highlighted else { return }
        withAnimation(NotchMotion.hover) { model.drop?.isHighlighted = highlighted }
    }

    // MARK: Helpers

    /// File URLs on the pasteboard, nil when the drag carries none.
    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, !urls.isEmpty else { return nil }
        return urls
    }

    private static func acceptsAll(_ urls: [URL]) -> Bool {
        urls.allSatisfy { ImageConverter.isConvertibleImage($0) }
    }
}
