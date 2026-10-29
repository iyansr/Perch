import AppKit

/// Finds where the menu bar extras (status icons) start, through Accessibility.
///
/// macOS keeps extras out of the hardware notch, but on a notchless display they run
/// underneath the centred island. Knowing the leftmost extra lets the island step aside.
enum MenuBarExtras {
    /// Per-app Accessibility timeout, so one hung app cannot stall the scan.
    private static let messagingTimeout: Float = 0.1

    /// What the island knows about the extras.
    enum Reading: Equatable {
        /// No Accessibility permission, so positions are unknown.
        case unreadable
        /// Screen x of the leftmost extra; nil when the menu bar has none.
        case readable(edge: CGFloat?)
    }

    struct Scan: Sendable {
        /// Left edge (screen x) of the leftmost extra on the primary screen's menu bar; nil when there are none.
        var edge: CGFloat?
        /// Processes that own an extras bar; later scans can query only these.
        var owners: [pid_t]
    }

    /// Reads the extras of `owners`, or of every running app when `owners` is nil.
    /// Nil without Accessibility permission. Blocking IPC to other apps: call it off the main thread.
    nonisolated static func scan(owners: [pid_t]?, screenFrame: CGRect, menuBarHeight: CGFloat) -> Scan? {
        guard AXIsProcessTrusted() else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Background-only processes (about half of them) cannot own status items.
        let candidates = owners ?? NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID && $0.activationPolicy != .prohibited }
            .map(\.processIdentifier)
        var result = Scan(edge: nil, owners: owners ?? [])

        for pid in candidates {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard let bar: AXUIElement = copyAttribute(element, "AXExtrasMenuBar"),
                  let items: [AXUIElement] = copyAttribute(bar, kAXChildrenAttribute)
            else { continue }
            // Only a full scan decides ownership: a busy owner missing the timeout must not drop out of the cache.
            if owners == nil { result.owners.append(pid) }

            for item in items {
                guard let frame = frame(of: item) else { continue }
                // Accessibility uses a top-left origin on the primary screen; x matches screen x.
                // Skip extras parked elsewhere (hidden by menu bar managers, other displays).
                guard frame.minY >= 0, frame.minY < menuBarHeight,
                      frame.minX >= screenFrame.minX, frame.maxX <= screenFrame.maxX
                else { continue }
                result.edge = min(result.edge ?? frame.minX, frame.minX)
            }
        }
        return result
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = copyAttribute(element, kAXPositionAttribute),
              let size: AXValue = copyAttribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    nonisolated private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
