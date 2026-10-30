import AppKit

/// Hides Apple's volume/brightness bezel by pausing `OSDUIHelper`, the agent that draws it.
/// `kickstart -k` respawns it first, so the stop lands on the instance launchd will keep using.
/// macOS can restart the agent after sleep, so `HUDSource` re-applies on wake. Resumed on quit;
/// after a crash the bezel returns at the next login.
enum SystemHUDSuppressor {
    private static var service: String { "gui/\(getuid())/com.apple.OSDUIHelper" }

    static func suppress() {
        let service = service
        DispatchQueue.global(qos: .utility).async {
            launchctl(["kickstart", "-k", service])
            // Give launchd a moment to spawn the fresh instance before stopping it.
            Thread.sleep(forTimeInterval: 0.5)
            launchctl(["kill", "SIGSTOP", service])
        }
    }

    /// Synchronous so it completes during app termination.
    static func restore() {
        launchctl(["kill", "SIGCONT", service])
    }

    private nonisolated static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Perch: launchctl \(arguments.joined(separator: " ")) failed: \(error)")
        }
    }
}
