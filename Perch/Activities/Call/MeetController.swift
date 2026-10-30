import AppKit
import Synchronization

/// Reads and drives Google Meet in a Chromium browser by running JavaScript in the meeting tab through
/// AppleScript. Chrome must have View → Developer → Allow JavaScript from Apple Events turned on
/// (Edge has the same item; Arc's is unverified), and macOS asks once to let Perch
/// control the browser (Automation). Controls are found by their English `aria-label`s.
@MainActor
final class MeetController {
    enum Poll: Equatable {
        /// No browser running, or no Meet tab in a call.
        case none
        case call(url: String, state: CallState)
        /// A Meet meeting tab is open but the browser refuses scripted JavaScript.
        case javaScriptDisabled
    }

    struct Browser {
        let bundleID: String
    }

    static let browsers = [
        Browser(bundleID: "com.google.Chrome"),
        Browser(bundleID: "com.microsoft.edgemac"),
        Browser(bundleID: "company.thebrowser.Browser")
    ]

    /// Browsers Perch was refused automation for; not asked again this session, so no repeated prompts.
    private var denied: Set<String> = []
    private var polling = false
    /// The last queued script run. Polls and presses run one after another, so a poll started after a
    /// press reads the state the press left, and two quick presses cannot interleave.
    private var lastScript: Task<Void, Never>?

    var anyBrowserRunning: Bool {
        Self.browsers.contains { isRunning($0.bundleID) }
    }

    func poll(_ completion: @escaping @MainActor (Poll) -> Void) {
        guard !polling else { return }
        let browsers = Self.browsers.filter { isRunning($0.bundleID) && !denied.contains($0.bundleID) }
        guard !browsers.isEmpty else {
            completion(.none)
            return
        }
        polling = true
        enqueue { [weak self] in
            let (result, newlyDenied) = await Self.scan(browsers)
            guard let self else { return }
            polling = false
            denied.formUnion(newlyDenied)
            completion(result)
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = lastScript
        lastScript = Task {
            await previous?.value
            await work()
        }
    }

    @concurrent private static func scan(_ browsers: [Browser]) async -> (Poll, [String]) {
        var result = Poll.none
        var newlyDenied: [String] = []
        for browser in browsers {
            let output = run(script(bundleID: browser.bundleID, javascript: stateJS))
            if output.status != 0 {
                if CallLogic.isAutomationDenied(stderr: output.stderr) { newlyDenied.append(browser.bundleID) }
                if CallLogic.isJavaScriptDisabled(stderr: output.stderr) { result = .javaScriptDisabled }
                continue
            }
            if let tab = CallLogic.meetTab(report: output.stdout) {
                result = .call(url: tab.url, state: tab.state)
                break
            }
        }
        return (result, newlyDenied)
    }

    @concurrent private static func press(_ browsers: [Browser], javascript: String) async {
        for browser in browsers {
            _ = run(script(bundleID: browser.bundleID, javascript: javascript))
        }
    }

    func perform(_ actionID: String) {
        let javascript: String
        switch actionID {
        case CallActionID.mute: javascript = Self.clickJS(pattern: "microphone")
        case CallActionID.camera: javascript = Self.clickJS(pattern: "camera")
        case CallActionID.leave: javascript = Self.clickJS(pattern: "^leave call")
        default: return
        }
        let browsers = Self.browsers.filter { isRunning($0.bundleID) && !denied.contains($0.bundleID) }
        enqueue { await Self.press(browsers, javascript: javascript) }
    }

    /// Lets a user who fixed the permission or setting retry.
    func resetDenials() {
        denied.removeAll()
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Scripts

    /// JSON array of every button's aria-label, empty unless the page has a leave button.
    nonisolated static let stateJS =
        "JSON.stringify(Array.from(document.querySelectorAll('button[aria-label]')).map(function(b){return b.getAttribute('aria-label')}))"

    /// Clicks the first button whose aria-label matches `pattern`, only on a page that is in a call.
    nonisolated static func clickJS(pattern: String) -> String {
        "(function(){var bs=Array.from(document.querySelectorAll('button[aria-label]'));"
            + "if(!bs.some(function(b){return /^leave call/i.test(b.getAttribute('aria-label'))}))return 'no';"
            + "var b=bs.find(function(b){return /\(pattern)/i.test(b.getAttribute('aria-label'))});"
            + "if(b){b.click();return 'ok'}return 'none'})()"
    }

    /// Runs `javascript` in every Meet tab of the browser and prints `url<TAB>result` per tab.
    nonisolated static func script(bundleID: String, javascript: String) -> String {
        let escaped = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        set out to ""
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u contains "meet.google.com/" then
                        set r to execute t javascript "\(escaped)"
                        set out to out & u & tab & r & linefeed
                    end if
                end repeat
            end repeat
        end tell
        return out
        """
    }

    private nonisolated static func run(_ script: String) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (-1, "", "\(error)")
        }
        // Drain stderr on a side thread so a full pipe cannot stall osascript.
        let errData = Mutex(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errData.withLock { $0 = data }
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData.withLock { $0 }, encoding: .utf8) ?? ""
        )
    }
}
