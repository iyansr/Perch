import Foundation
import Security

/// Downloads, authenticates and installs a Perch update.
///
/// Lifecycle (all owned by the caller, nothing here terminates the app):
/// 1. `stage` downloads and verifies the release into a private `stage-<uuid>` directory and returns the
///    staged `Perch.app`. Cancelling the calling task, or any failure, removes that directory.
/// 2. Either `discard(stagedApp:)` (user dismissed the update) or `prepareRelaunch` (user chose to install)
///    follows. `discard` must not be called once a prepared token was committed: the helper then owns the
///    staging directory and deletes it.
/// 3. `prepareRelaunch` (async, off the main actor) returns a `PreparedRelaunch` once the detached helper
///    is running and waiting for this process to exit. The caller re-checks its busy gate, then either
///    `commit()`s the token and terminates normally (`NSApp.terminate`, so `applicationWillTerminate`
///    cleanup runs) or `cancel()`s it. Without a commit the helper installs nothing when the app exits.
///    The helper replaces the bundle at the same path, relaunches it and restores the old bundle on failure.
///    A failed install leaves a message that `takeFailureReport()` returns on the next launch.
///
/// `prepareRelaunch` verifies signatures, so it must not run on the main actor; it is `@concurrent`.
nonisolated enum UpdateInstaller {
    // MARK: - Trust anchors (keep in sync with Scripts/verify-signature.sh)

    static let bundleIdentifier = "id.iyansr.perch"
    /// SHA-1 of the "Perch Self-Signed" certificate. The designated requirement pins it.
    static let certificateSHA1 = "1F2AA6E84584DD5185AD1C42626BD2A148C810E8"
    static let appRequirement = "identifier \"\(bundleIdentifier)\" and certificate leaf = H\"\(certificateSHA1)\""
    static let signerRequirement = "certificate leaf = H\"\(certificateSHA1)\""

    // MARK: - Limits

    static let maxArchiveBytes: Int64 = 512 * 1024 * 1024
    static let maxExpandedBytes: Int64 = 1024 * 1024 * 1024
    static let maxArchiveEntries = 20_000
    static let maxTreeEntries = 50_000
    static let extractionTimeout: TimeInterval = 300
    /// How long the helper waits for this process to exit before it gives up and leaves the app untouched.
    static let quitWaitSeconds = 90
    static let helperHandshakeTimeout: TimeInterval = 5

    static let appName = "Perch.app"
    static let executableName = "Perch"
    static let cliPath = "Contents/Helpers/perch"
    static let adapterFrameworkPath = "Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
    static let adapterBinaryPath = adapterFrameworkPath + "/Versions/A/MediaRemoteAdapter"

    // MARK: - Public API

    /// Downloads `release`, extracts it and returns the verified staged `Perch.app`.
    /// `progress` reports the download as 0...1 and is called from an arbitrary queue.
    @concurrent
    static func stage(
        _ release: UpdateRelease,
        bundleURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard release.downloadURL.scheme?.lowercased() == "https" else {
            throw UpdateInstallError.downloadFailed("The download address is not HTTPS.")
        }
        guard release.size > 0, release.size <= maxArchiveBytes else {
            throw UpdateInstallError.badArchive("The release reports an unusable size (\(release.size) bytes).")
        }
        try checkInstallTarget(bundleURL)

        let updates = try updatesDirectory()
        pruneStaleStages(in: updates)
        let root = updates.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
        try createPrivateDirectory(root)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: root) } }

        try checkFreeSpace(at: root, needed: release.size * 4)

        progress(0)
        let archive = root.appendingPathComponent("update.zip")
        try await ArchiveDownload(destination: archive, expectedSize: release.size, progress: progress)
            .run(from: release.downloadURL)
        try Task.checkCancellation()

        try ZipInspector.inspect(archive, size: release.size)

        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        try createPrivateDirectory(expanded)
        let extraction = try await ToolRunner.run(
            "/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path], timeout: extractionTimeout)
        try Task.checkCancellation()
        guard extraction.status == 0, !extraction.timedOut else {
            throw UpdateInstallError.extractionFailed(
                extraction.timedOut ? "Extraction timed out." : extraction.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let app = try finalizeLayout(expanded)
        try sanitizePermissions(app)
        try validate(app, release: release, installedApp: bundleURL)
        try? FileManager.default.removeItem(at: archive)
        try Task.checkCancellation()

        succeeded = true
        progress(1)
        return app
    }

    /// Verifies `stagedApp` end to end: layout, seal across all architectures and nested code, pinned
    /// certificate, bundle id, version equal to `release`, and a strictly newer version and build than the
    /// installed app. Throws on the first failure.
    static func validate(_ stagedApp: URL, release: UpdateRelease, installedApp: URL) throws {
        let candidate = try inspect(stagedApp)
        guard let signedVersion = UpdateVersion(candidate.shortVersion), signedVersion == release.version else {
            throw UpdateInstallError.verificationFailed(
                "The update is version \(candidate.shortVersion), not the announced \(release.version).")
        }
        try checkNewer(candidate, than: installedApp)
    }

    /// Re-verifies the staged app, then starts the detached installer that waits for this process to exit,
    /// verifies the candidate again, swaps it into `bundleURL` (same path), relaunches it and rolls back on
    /// failure. Returns only after the helper confirmed it is running; the caller must then either terminate
    /// the app normally or call `cancel()` on the returned token (for example when new work appeared while
    /// preparing). Once the app has exited the helper is no longer cancellable. After a successful return and
    /// no cancellation, the helper owns the staging directory. After `cancel()` the staged app is untouched
    /// and still belongs to the caller (`discard` it or prepare again).
    /// If this throws, the helper (if it started at all) is cancelled and the staging directory stays.
    @concurrent
    static func prepareRelaunch(stagedApp: URL, bundleURL: URL) async throws -> PreparedRelaunch {
        let root = try stagingRoot(of: stagedApp)
        let updates = try updatesDirectory()
        try checkInstallTarget(bundleURL)
        let candidate = try inspect(stagedApp)
        try checkNewer(candidate, than: bundleURL)
        try Task.checkCancellation()

        let fm = FileManager.default
        let token = PreparedRelaunch(id: UUID().uuidString, stagingRoot: root)
        let script = root.appendingPathComponent("install-\(token.id).sh")
        do {
            try Data(InstallerScript.source.utf8).write(to: script, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            throw UpdateInstallError.helperFailed("Could not write the installer: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            bundleURL.standardizedFileURL.path,
            stagedApp.standardizedFileURL.path,
            root.path,
            updates.path,
            candidate.shortVersion,
            String(candidate.build),
            appRequirement,
            signerRequirement,
            bundleIdentifier,
            String(quitWaitSeconds),
            token.id,
        ]
        process.environment = ToolRunner.environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.helperFailed("Could not start the installer: \(error.localizedDescription)")
        }

        let started = token.startedMarker
        let deadline = ContinuousClock.now + .seconds(helperHandshakeTimeout)
        while ContinuousClock.now < deadline {
            if fm.fileExists(atPath: started.path) { return token }
            if !process.isRunning { break }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                try? token.cancel()
                throw error
            }
        }
        if fm.fileExists(atPath: started.path) { return token }
        try? token.cancel()
        if process.isRunning {
            process.terminate()
            throw UpdateInstallError.helperFailed("The installer did not start in time.")
        }
        throw UpdateInstallError.helperFailed("The installer exited immediately (status \(process.terminationStatus)).")
    }

    /// Removes the staging directory of `stagedApp`. Only ever deletes a `stage-<uuid>` directory directly
    /// inside the updates cache; anything else is ignored. Never call after a successful `prepareRelaunch`.
    static func discard(stagedApp: URL) {
        guard let root = try? stagingRoot(of: stagedApp) else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Message from a failed or rolled-back install of the previous run, if any. Reading it clears it.
    static func takeFailureReport() -> String? {
        guard let updates = try? updatesDirectory() else { return nil }
        let file = updates.appendingPathComponent(InstallerScript.failureFileName)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    // MARK: - Install target

    /// The running bundle must be replaceable in place: not translocated, not on a read-only volume, not a
    /// symlink, and in a directory the user can write to (no administrator prompt is ever shown).
    static func checkInstallTarget(_ bundleURL: URL) throws {
        let url = bundleURL.standardizedFileURL
        let path = url.path
        guard path.hasSuffix(".app") else {
            throw UpdateInstallError.unsupportedLocation("Perch is not running from an app bundle.")
        }
        guard !path.contains("/AppTranslocation/") else {
            throw UpdateInstallError.unsupportedLocation(
                "Perch is running from a temporary quarantined location. Move it to Applications, open it once, then update.")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory else {
            throw UpdateInstallError.unsupportedLocation("The Perch app at \(path) is not a plain bundle directory.")
        }
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard values?.volumeIsReadOnly != true else {
            throw UpdateInstallError.unsupportedLocation(
                "Perch is running from a read-only volume. Copy it to Applications first.")
        }
        let parent = url.deletingLastPathComponent().path
        guard access(parent, W_OK | X_OK) == 0 else {
            throw UpdateInstallError.unsupportedLocation(
                "\(parent) is not writable by your account, so Perch cannot replace itself there.")
        }
    }

    // MARK: - Staging directories

    static func updatesDirectory() throws -> URL {
        let fm = FileManager.default
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let type = try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else {
            throw UpdateInstallError.unsupportedLocation("The updates cache at \(directory.path) is not a directory.")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    /// `<updates>/stage-<uuid>/expanded/Perch.app` -> `<updates>/stage-<uuid>`, or throws if the shape differs.
    private static func stagingRoot(of stagedApp: URL) throws -> URL {
        let app = stagedApp.standardizedFileURL
        let expanded = app.deletingLastPathComponent()
        let root = expanded.deletingLastPathComponent()
        let updates = try updatesDirectory().standardizedFileURL
        guard app.lastPathComponent == appName,
              expanded.lastPathComponent == "expanded",
              root.lastPathComponent.hasPrefix("stage-"),
              root.lastPathComponent.count > "stage-".count,
              root.deletingLastPathComponent().standardizedFileURL.path == updates.path
        else {
            throw UpdateInstallError.badArchive("\(stagedApp.path) is not a staged Perch update.")
        }
        return root
    }

    /// Staging directories older than a few hours belong to a run that crashed or was abandoned.
    private static func pruneStaleStages(in updates: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: updates, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for entry in entries where entry.lastPathComponent.hasPrefix("stage-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: entry) }
        }
    }

    private static func checkFreeSpace(at url: URL, needed: Int64) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
            throw UpdateInstallError.insufficientSpace(needed: needed)
        }
    }

    /// `expanded` must hold exactly `Perch.app` (a `__MACOSX` sidecar folder is dropped).
    private static func finalizeLayout(_ expanded: URL) throws -> URL {
        let fm = FileManager.default
        let sidecar = expanded.appendingPathComponent("__MACOSX")
        if fm.fileExists(atPath: sidecar.path) { try? fm.removeItem(at: sidecar) }
        let names = try fm.contentsOfDirectory(atPath: expanded.path)
        guard names == [appName] else {
            throw UpdateInstallError.badArchive("The archive must contain only \(appName); it contains \(names.sorted()).")
        }
        let app = expanded.appendingPathComponent(appName, isDirectory: true)
        let type = try fm.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else {
            throw UpdateInstallError.badArchive("\(appName) in the archive is not a directory.")
        }
        return app
    }

    // MARK: - Verification

    nonisolated struct Candidate: Sendable {
        let shortVersion: String
        let build: UInt64
    }

    /// Signature and metadata checks that need no release or installed app.
    static func inspect(_ app: URL) throws -> Candidate {
        let root = app.standardizedFileURL
        try checkTree(root)

        let appCode = try staticCode(at: root)
        try checkSeal(appCode, requirement: appRequirement, label: appName)
        let info = try signingInformation(appCode, label: appName)

        guard info[kSecCodeInfoIdentifier as String] as? String == bundleIdentifier else {
            throw UpdateInstallError.verificationFailed("The update is signed with a different identifier.")
        }
        try requireHardenedRuntime(info, label: appName)
        try rejectDebuggable(info, label: appName)

        guard let plist = info[kSecCodeInfoPList as String] as? [String: Any] else {
            throw UpdateInstallError.verificationFailed("The update has no signed Info.plist.")
        }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateInstallError.verificationFailed("The update is not Perch (bundle identifier mismatch).")
        }
        guard plist["CFBundleExecutable"] as? String == executableName else {
            throw UpdateInstallError.verificationFailed("The update has an unexpected main executable.")
        }
        guard let shortVersion = plist["CFBundleShortVersionString"] as? String, UpdateVersion(shortVersion) != nil else {
            throw UpdateInstallError.verificationFailed("The update has no valid version.")
        }
        guard let buildText = plist["CFBundleVersion"] as? String, let build = parseBuild(buildText) else {
            throw UpdateInstallError.verificationFailed("The update has no numeric build number.")
        }

        // Every Mach-O must carry both slices.
        for path in ["Contents/MacOS/" + executableName, cliPath, adapterBinaryPath] {
            try requireUniversal(root.appendingPathComponent(path), label: path)
        }

        // The CLI and the MediaRemote adapter are checked explicitly rather than trusting nested-code discovery.
        let cli = try staticCode(at: root.appendingPathComponent(cliPath))
        try checkSeal(cli, requirement: signerRequirement, label: cliPath)
        let cliInfo = try signingInformation(cli, label: cliPath)
        try requireHardenedRuntime(cliInfo, label: cliPath)
        try rejectDebuggable(cliInfo, label: cliPath)

        let adapter = try staticCode(at: root.appendingPathComponent(adapterFrameworkPath))
        try checkSeal(adapter, requirement: signerRequirement, label: adapterFrameworkPath)
        try requireHardenedRuntime(try signingInformation(adapter, label: adapterFrameworkPath), label: adapterFrameworkPath)

        return Candidate(shortVersion: shortVersion, build: build)
    }

    private static func checkNewer(_ candidate: Candidate, than installedApp: URL) throws {
        let plistURL = installedApp.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier,
              let installedVersionText = plist["CFBundleShortVersionString"] as? String,
              let installedVersion = UpdateVersion(installedVersionText),
              let installedBuildText = plist["CFBundleVersion"] as? String,
              let installedBuild = parseBuild(installedBuildText)
        else {
            throw UpdateInstallError.unsupportedLocation("The installed Perch has no readable Perch version information.")
        }
        guard let version = UpdateVersion(candidate.shortVersion), version > installedVersion else {
            throw UpdateInstallError.verificationFailed(
                "Version \(candidate.shortVersion) is not newer than the installed \(installedVersionText).")
        }
        guard candidate.build > installedBuild else {
            throw UpdateInstallError.verificationFailed(
                "Build \(candidate.build) is not newer than the installed build \(installedBuild).")
        }
    }

    private static func parseBuild(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(text)
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code)
        guard status == errSecSuccess, let code else {
            throw UpdateInstallError.verificationFailed("Cannot read the signature of \(url.lastPathComponent) (\(status)).")
        }
        return code
    }

    private static func checkSeal(_ code: SecStaticCode, requirement text: String, label: String) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement
        else {
            throw UpdateInstallError.verificationFailed("Internal error: the signing requirement is invalid.")
        }
        let flags = SecCSFlags(
            rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSStrictValidate))
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            var detail = "status \(status)"
            if let cfError = error?.takeRetainedValue() { detail = CFErrorCopyDescription(cfError) as String }
            throw UpdateInstallError.verificationFailed(
                "\(label) is not signed by Perch's certificate or its seal is broken (\(detail)).")
        }
    }

    private static func signingInformation(_ code: SecStaticCode, label: String) throws -> [String: Any] {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information)
        guard status == errSecSuccess, let dictionary = information as? [String: Any] else {
            throw UpdateInstallError.verificationFailed("Cannot read signing information of \(label) (\(status)).")
        }
        return dictionary
    }

    private static func requireHardenedRuntime(_ info: [String: Any], label: String) throws {
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard flags & SecCodeSignatureFlags.runtime.rawValue != 0 else {
            throw UpdateInstallError.verificationFailed("\(label) does not use the hardened runtime.")
        }
    }

    private static func rejectDebuggable(_ info: [String: Any], label: String) throws {
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        if entitlements?["com.apple.security.get-task-allow"] as? Bool == true {
            throw UpdateInstallError.verificationFailed("\(label) allows debugger attachment (get-task-allow).")
        }
    }

    private static func requireUniversal(_ url: URL, label: String) throws {
        let architectures = try MachO.architectures(of: url)
        for required in ["arm64", "x86_64"] where !architectures.contains(required) {
            throw UpdateInstallError.verificationFailed(
                "\(label) has no \(required) slice (has \(architectures.sorted().joined(separator: ", ")))." )
        }
    }

    /// Rejects anything but regular files, directories and symlinks that resolve inside the bundle;
    /// also setuid/setgid files, group/other-writable entries (symlink modes are meaningless) and ACLs.
    /// `sanitizePermissions` normalizes freshly extracted trees first.
    private static func checkTree(_ root: URL) throws {
        let fm = FileManager.default
        let rootPath = root.path
        guard let realRoot = realPath(rootPath),
              try fm.attributesOfItem(atPath: rootPath)[.type] as? FileAttributeType == .typeDirectory,
              let walker = fm.enumerator(atPath: rootPath)
        else {
            throw UpdateInstallError.badArchive("The staged app is not a plain directory.")
        }
        let rootAttributes = try fm.attributesOfItem(atPath: rootPath)
        guard ((rootAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o6022 == 0, !hasACL(rootPath) else {
            throw UpdateInstallError.badArchive("The app folder has unsafe permissions.")
        }
        var count = 0
        while let relative = walker.nextObject() as? String {
            count += 1
            guard count <= maxTreeEntries else { throw UpdateInstallError.badArchive("The app has too many files.") }
            let path = rootPath + "/" + relative
            let attributes = try fm.attributesOfItem(atPath: path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let type = attributes[.type] as? FileAttributeType
            guard permissions & 0o6000 == 0 else {
                throw UpdateInstallError.badArchive("\(relative) is setuid or setgid.")
            }
            if type != .typeSymbolicLink {
                guard permissions & 0o022 == 0 else {
                    throw UpdateInstallError.badArchive("\(relative) is writable by group or others.")
                }
            }
            guard !hasACL(path) else {
                throw UpdateInstallError.badArchive("\(relative) carries an access control list.")
            }
            if type == .typeDirectory || type == .typeRegular { continue }
            guard type == .typeSymbolicLink else {
                throw UpdateInstallError.badArchive("\(relative) is a special file.")
            }
            let target = try fm.destinationOfSymbolicLink(atPath: path)
            guard !target.hasPrefix("/"), let resolved = realPath(path),
                  resolved == realRoot || resolved.hasPrefix(realRoot + "/")
            else {
                throw UpdateInstallError.badArchive("\(relative) is a symlink that leaves the app.")
            }
        }
    }

    /// The archive is untrusted, so modes and ACLs from extraction are too: clear group/other write and the
    /// sticky bit everywhere, keep executable bits, and keep the owner able to read (and enter directories)
    /// so the tree can still be cleaned up. Refuses setuid/setgid files, special files and ACLs.
    /// Directories are normalized before they are listed, and symlinks are never followed.
    private static func sanitizePermissions(_ root: URL) throws {
        let fm = FileManager.default
        var visited = 0

        func normalize(_ path: String) throws -> FileAttributeType? {
            visited += 1
            guard visited <= maxTreeEntries else { throw UpdateInstallError.badArchive("The app has too many files.") }
            if visited & 0x3FF == 0 { try Task.checkCancellation() }
            let attributes = try fm.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            guard !hasACL(path) else { throw UpdateInstallError.badArchive("\(path) carries an access control list.") }
            if type == .typeSymbolicLink { return type }
            guard type == .typeDirectory || type == .typeRegular else {
                throw UpdateInstallError.badArchive("\(path) is a special file.")
            }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard mode & 0o6000 == 0 else { throw UpdateInstallError.badArchive("\(path) is setuid or setgid.") }
            let wanted = (mode & 0o777 & ~0o022) | (type == .typeDirectory ? 0o700 : 0o600)
            if wanted != mode & 0o7777 {
                try fm.setAttributes([.posixPermissions: wanted], ofItemAtPath: path)
            }
            return type
        }

        guard try normalize(root.path) == .typeDirectory else {
            throw UpdateInstallError.badArchive("The staged app is not a plain directory.")
        }
        var pending = [root.path]
        while let directory = pending.popLast() {
            for name in try fm.contentsOfDirectory(atPath: directory) {
                let path = directory + "/" + name
                if try normalize(path) == .typeDirectory { pending.append(path) }
            }
        }
    }

    private static func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Relaunch token

/// Handle for one `prepareRelaunch` attempt. Its helper only installs after `commit()`, and gives up
/// without touching anything after `cancel()` (while the app has not yet quit). Markers are unique per
/// attempt, so a quick retry can never be affected by an older helper's markers.
nonisolated struct PreparedRelaunch: Sendable {
    let id: String
    let stagingRoot: URL

    var startedMarker: URL { stagingRoot.appendingPathComponent("started-" + id) }
    private var cancelMarker: URL { stagingRoot.appendingPathComponent("cancel-" + id) }
    private var commitMarker: URL { stagingRoot.appendingPathComponent("commit-" + id) }

    /// Authorizes the helper to install once this process exits. Call right before terminating.
    func commit() throws {
        do {
            try Data().write(to: commitMarker)
        } catch {
            throw UpdateInstallError.helperFailed("Could not authorize the installer: \(error.localizedDescription)")
        }
    }

    /// Stops the helper before the app exits; the staged app stays in place for the caller.
    func cancel() throws {
        do {
            try Data().write(to: cancelMarker)
        } catch {
            throw UpdateInstallError.helperFailed("Could not cancel the installer: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

nonisolated enum UpdateInstallError: LocalizedError, Sendable {
    case unsupportedLocation(String)
    case insufficientSpace(needed: Int64)
    case downloadFailed(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case badArchive(String)
    case extractionFailed(String)
    case verificationFailed(String)
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocation(let message): message
        case .insufficientSpace(let needed):
            "Not enough free disk space to stage the update (\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed)."
        case .downloadFailed(let message): "The update could not be downloaded. \(message)"
        case .sizeMismatch(let expected, let actual):
            "The download is \(actual) bytes but the release lists \(expected)."
        case .badArchive(let message): "The update archive is not acceptable. \(message)"
        case .extractionFailed(let message): "The update could not be extracted. \(message)"
        case .verificationFailed(let message): "The update failed verification and was not installed. \(message)"
        case .helperFailed(let message): message
        }
    }
}

// MARK: - Download

/// One cancellable, size-bounded HTTPS download to a file.
nonisolated final class ArchiveDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var abortError: Error?
    private var moveError: Error?
    private var received = false
    private var checkedResponse = false
    private var lastProgress = -1.0

    init(destination: URL, expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
        super.init()
    }

    func run(from url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.downloadTask(with: URLRequest(url: url))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    self.task = task
                    return cancelled
                }
                task.resume()
                if alreadyCancelled { task.cancel() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    private func abort(_ error: Error) {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            if abortError == nil { abortError = error }
            return self.task
        }
        task?.cancel()
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            abort(UpdateInstallError.downloadFailed("The server redirected to a non-HTTPS address."))
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let problem = lock.withLock { () -> UpdateInstallError? in
            if !checkedResponse, let status {
                checkedResponse = true
                if status != 200 { return .downloadFailed("The server answered HTTP \(status).") }
            }
            if totalBytesWritten > expectedSize {
                return .sizeMismatch(expected: expectedSize, actual: totalBytesWritten)
            }
            return nil
        }
        if let problem {
            abort(problem)
            return
        }
        let fraction = min(1, Double(totalBytesWritten) / Double(expectedSize))
        let shouldReport = lock.withLock { () -> Bool in
            guard fraction - lastProgress >= 0.005 else { return false }
            lastProgress = fraction
            return true
        }
        if shouldReport { progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            guard status == 200 else {
                throw UpdateInstallError.downloadFailed("The server answered HTTP \(status ?? 0).")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard actual == expectedSize else {
                throw UpdateInstallError.sizeMismatch(expected: expectedSize, actual: actual)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { received = true }
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Result<Void, Error> = lock.withLock {
            if let abortError { return .failure(abortError) }
            if cancelled { return .failure(CancellationError()) }
            if let error { return .failure(UpdateInstallError.downloadFailed(error.localizedDescription)) }
            if let moveError { return .failure(moveError) }
            if !received { return .failure(UpdateInstallError.downloadFailed("No data was received.")) }
            return .success(())
        }
        finish(outcome)
    }
}

// MARK: - ZIP central directory

/// Reads the central directory of an archive without extracting and rejects hostile layouts before
/// `ditto` touches the disk: paths outside `Perch.app`, traversal, odd or oversized names, encryption,
/// ZIP64, special files, duplicate or case/normalization-colliding names, entries written below an
/// archived symlink or file, and local headers that disagree with the central directory (the local
/// header is what extraction reads) or whose data overlaps or runs into the directory.
nonisolated enum ZipInspector {
    static let maxPathBytes = 1024
    static let maxComponentBytes = 255
    static let maxDepth = 128

    /// One node per distinct (parent, case/normalization-folded component), so two names that the
    /// case-insensitive, normalization-insensitive volume would merge are the same node.
    private struct NodeKey: Hashable {
        let parent: Int
        let name: String
    }

    static func inspect(_ url: URL, size: Int64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let tailLength = Int(min(size, 65_557))
        try handle.seek(toOffset: UInt64(size) - UInt64(tailLength))
        let tail = [UInt8](try handle.read(upToCount: tailLength) ?? Data())
        guard tail.count == tailLength, tail.count >= 22 else { throw bad("The file is too short to be a ZIP archive.") }

        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06,
               index + 22 + u16(tail, index + 20) == tail.count {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { throw bad("The ZIP end record is missing.") }
        let diskNumber = u16(tail, eocd + 4), directoryDisk = u16(tail, eocd + 6)
        let entriesOnDisk = u16(tail, eocd + 8), entryCount = u16(tail, eocd + 10)
        let directorySize = u32(tail, eocd + 12), directoryOffset = u32(tail, eocd + 16)
        guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == entryCount else {
            throw bad("Multi-part ZIP archives are not supported.")
        }
        guard entryCount != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw bad("ZIP64 archives are not supported.")
        }
        guard entryCount > 0, entryCount <= UpdateInstaller.maxArchiveEntries,
              Int64(directoryOffset) + Int64(directorySize) <= size
        else { throw bad("The ZIP directory is invalid.") }

        try handle.seek(toOffset: UInt64(directoryOffset))
        let directory = [UInt8](try handle.read(upToCount: directorySize) ?? Data())
        guard directory.count == directorySize else { throw bad("The ZIP directory is truncated.") }

        var cursor = 0
        var expanded: Int64 = 0
        var sawApp = false
        // Path trie over folded components. Node 0 is the root.
        var nodes: [NodeKey: Int] = [:]
        var parentOf = [0]
        var isLeaf = [false]      // regular file or symlink: nothing may live below it
        var isEntry = [false]
        var entryNodes: [Int] = []
        var spans: [(start: Int, end: Int)] = []

        for entryIndex in 0..<entryCount {
            if entryIndex & 0x3F == 0 { try Task.checkCancellation() }
            guard cursor + 46 <= directory.count, u32(directory, cursor) == 0x0201_4B50 else {
                throw bad("A ZIP directory entry is malformed.")
            }
            let madeBy = u16(directory, cursor + 4)
            let flags = u16(directory, cursor + 8)
            let method = u16(directory, cursor + 10)
            let compressed = u32(directory, cursor + 20)
            let uncompressed = u32(directory, cursor + 24)
            let nameLength = u16(directory, cursor + 28)
            let extraLength = u16(directory, cursor + 30)
            let commentLength = u16(directory, cursor + 32)
            let attributes = u32(directory, cursor + 38)
            let localOffset = u32(directory, cursor + 42)
            let nameStart = cursor + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= directory.count else { throw bad("A ZIP directory entry is truncated.") }
            cursor = next

            guard flags & 0x1 == 0 else { throw bad("The archive is encrypted.") }
            guard method == 0 || method == 8 else { throw bad("The archive uses an unsupported compression method.") }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw bad("ZIP64 entries are not supported.")
            }
            guard method != 0 || compressed == uncompressed else { throw bad("A stored entry has inconsistent sizes.") }
            expanded += Int64(uncompressed)
            guard expanded <= UpdateInstaller.maxExpandedBytes else { throw bad("The archive expands to too much data.") }
            guard nameLength > 0, nameLength <= maxPathBytes else { throw bad("An entry name has an unusable length.") }

            guard let name = String(bytes: directory[nameStart..<nameStart + nameLength], encoding: .utf8) else {
                throw bad("An entry name is not valid UTF-8.")
            }
            let parts = try components(of: name)
            let isDirectory = name.hasSuffix("/")
            guard !isDirectory || uncompressed == 0 else { throw bad("A directory entry has data.") }

            // The local header is what extraction actually reads: it must agree with the central entry.
            let localStart = localOffset
            guard localStart + 30 + nameLength <= directoryOffset else { throw bad("A local header lies outside the archive body.") }
            try handle.seek(toOffset: UInt64(localStart))
            let local = [UInt8](try handle.read(upToCount: 30 + nameLength) ?? Data())
            guard local.count == 30 + nameLength, u32(local, 0) == 0x0403_4B50 else {
                throw bad("A local header is missing or malformed.")
            }
            let localFlags = u16(local, 6)
            guard localFlags & 0x1 == 0, u16(local, 8) == method, u16(local, 26) == nameLength,
                  local[30..<30 + nameLength].elementsEqual(directory[nameStart..<nameStart + nameLength])
            else { throw bad("A local header does not match its directory entry (\(name)).") }
            if localFlags & 0x8 == 0 {
                guard u32(local, 18) == compressed, u32(local, 22) == uncompressed else {
                    throw bad("A local header disagrees with its directory entry about sizes.")
                }
            }
            let dataEnd = localStart + 30 + nameLength + u16(local, 28) + compressed
            guard dataEnd <= directoryOffset else { throw bad("An entry's data runs into the ZIP directory.") }
            spans.append((localStart, dataEnd))

            // Unix mode lives in the high half of the external attributes when the host is Unix (3).
            var isSymlinkEntry = false
            var isRegular = !isDirectory
            if madeBy >> 8 == 3 {
                let kind = (attributes >> 16) & 0o170000
                switch kind {
                case 0, 0o100000, 0o040000: break
                case 0o120000:
                    guard parts[0] == "Perch.app" else { throw bad("A symlink sits outside Perch.app.") }
                    isSymlinkEntry = true
                default:
                    throw bad("The archive contains a special file (\(name)).")
                }
                if kind == 0o040000 { isRegular = false }
            }

            var node = 0
            for part in parts {
                let key = NodeKey(parent: node, name: fold(part))
                if let existing = nodes[key] {
                    node = existing
                } else {
                    let created = parentOf.count
                    nodes[key] = created
                    parentOf.append(node)
                    isLeaf.append(false)
                    isEntry.append(false)
                    node = created
                }
            }
            guard !isEntry[node] else { throw bad("Two entries name the same path (\(name)).") }
            isEntry[node] = true
            isLeaf[node] = isSymlinkEntry || isRegular
            entryNodes.append(node)
            if parts[0] == "Perch.app" { sawApp = true }
        }
        guard cursor == directory.count else { throw bad("The ZIP directory has trailing data.") }
        guard sawApp else { throw bad("The archive does not contain Perch.app.") }

        // Entry data must not overlap.
        spans.sort { $0.start < $1.start }
        for pair in zip(spans, spans.dropFirst()) where pair.1.start < pair.0.end {
            throw bad("Entries overlap inside the archive.")
        }

        // Nothing may be written below an archived symlink or file.
        for (position, node) in entryNodes.enumerated() {
            if position & 0x3FF == 0 { try Task.checkCancellation() }
            var ancestor = parentOf[node]
            while ancestor != 0 {
                guard !isLeaf[ancestor] else { throw bad("An entry is written below a file or symlink.") }
                ancestor = parentOf[ancestor]
            }
        }
    }

    private static func fold(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func components(of name: String) throws -> [String] {
        guard !name.isEmpty, !name.hasPrefix("/"),
              name.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F && $0 != 0x5C })
        else { throw bad("An entry has an unsafe name.") }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if name.hasSuffix("/") { parts.removeLast() }
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw bad("An entry path is not normalized (\(name)).")
        }
        guard parts.count <= maxDepth, !parts.contains(where: { $0.utf8.count > maxComponentBytes }) else {
            throw bad("An entry path is too deep or has a component that is too long.")
        }
        switch parts[0] {
        case "Perch.app": break
        case "__MACOSX":
            guard parts.count == 1 || parts[1] == "Perch.app" else {
                throw bad("An entry lies outside Perch.app (\(name)).")
            }
        default: throw bad("An entry lies outside Perch.app (\(name)).")
        }
        return parts
    }

    private static func bad(_ message: String) -> UpdateInstallError { .badArchive(message) }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }
}

// MARK: - Mach-O

nonisolated enum MachO {
    private static let arm64: UInt32 = 0x0100_000C
    private static let x86_64: UInt32 = 0x0100_0007

    /// Architectures present in a thin or fat Mach-O file.
    static func architectures(of url: URL) throws -> Set<String> {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw UpdateInstallError.verificationFailed("\(url.lastPathComponent) is missing from the update.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 8), header.count == 8 else {
            throw UpdateInstallError.verificationFailed("\(url.lastPathComponent) is not a Mach-O file.")
        }
        let bytes = [UInt8](header)
        let bigEndianMagic = be32(bytes, 0)
        if bigEndianMagic == 0xCAFE_BABE || bigEndianMagic == 0xCAFE_BABF {
            let count = Int(be32(bytes, 4))
            let stride = bigEndianMagic == 0xCAFE_BABE ? 20 : 32
            guard count > 0, count <= 16,
                  let table = try handle.read(upToCount: count * stride), table.count == count * stride
            else { throw UpdateInstallError.verificationFailed("\(url.lastPathComponent) has a bad fat header.") }
            let entries = [UInt8](table)
            return Set((0..<count).compactMap { name(cpu: be32(entries, $0 * stride)) })
        }
        // Thin 64-bit little-endian Mach-O (0xFEEDFACF).
        guard bytes[0] == 0xCF, bytes[1] == 0xFA, bytes[2] == 0xED, bytes[3] == 0xFE else {
            throw UpdateInstallError.verificationFailed("\(url.lastPathComponent) is not a Mach-O file.")
        }
        let cpu = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        return Set([name(cpu: cpu)].compactMap { $0 })
    }

    private static func name(cpu: UInt32) -> String? {
        switch cpu {
        case arm64: "arm64"
        case x86_64: "x86_64"
        default: nil
        }
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

// MARK: - Child processes

/// Runs a fixed system executable with an explicit argv (never a shell string), killing it on task
/// cancellation or timeout.
nonisolated enum ToolRunner {
    nonisolated struct Outcome: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    static let environment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "LANG": "en_US.UTF-8",
    ]

    private nonisolated final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var launched = false
        private var cancelled = false
        private(set) var timedOut = false

        init(_ process: Process) { self.process = process }

        func launch() throws {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                try process.run()
                launched = true
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if launched, process.isRunning { process.terminate() }
            }
        }

        func timeout() {
            lock.withLock {
                timedOut = true
                if launched, process.isRunning { process.terminate() }
            }
        }
    }

    private nonisolated final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = Collector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { collector.append(chunk) }
        }
        let gate = Gate(process)
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            gate.timeout()
        }
        defer { timer.cancel() }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try gate.launch()
                    // The parent's copy of the write end must close or the reader never sees EOF.
                    try? pipe.fileHandleForWriting.close()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            gate.cancel()
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collector.append(rest) }
        try Task.checkCancellation()
        return Outcome(status: status, output: collector.text, timedOut: gate.timedOut)
    }
}

// MARK: - Detached installer

/// POSIX shell run as `/bin/sh install.sh <args>` after Perch quits. All data arrives as positional
/// arguments (never interpolated into source), and only absolute-path system tools are used.
nonisolated enum InstallerScript {
    static let failureFileName = "last-install-failure.txt"

    static let source = #"""
    #!/bin/sh
    # Perch update installer. Waits for Perch to quit, verifies the staged bundle again, swaps it into the
    # same path while keeping the old bundle, relaunches, and restores the old bundle if anything fails.
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    trap '' HUP

    [ "$#" -eq 12 ] || exit 64
    PID=$1; DEST=$2; STAGED=$3; ROOT=$4; UPDATES=$5; VERSION=$6; BUILD=$7
    APP_REQ=$8; SIGNER_REQ=$9; BUNDLE_ID=${10}; WAIT_SECONDS=${11}; TOKEN=${12}

    case "$TOKEN" in ''|*[!0-9A-Fa-f-]*) exit 64 ;; esac

    case "$PID" in ''|*[!0-9]*) exit 64 ;; esac
    case "$WAIT_SECONDS" in ''|*[!0-9]*) exit 64 ;; esac
    case "$BUILD" in ''|*[!0-9]*) exit 64 ;; esac
    case "$ROOT" in *..*) exit 64 ;; esac
    case "$ROOT" in "$UPDATES"/stage-?*) ;; *) exit 64 ;; esac
    case "$STAGED" in "$ROOT"/expanded/*) ;; *) exit 64 ;; esac
    case "$DEST" in /*.app) ;; *) exit 64 ;; esac
    # The kernel reports the resolved executable path (/tmp is /private/tmp), so match and replace
    # through the physical parent directory, or a symlinked location never sees the new app start.
    DEST_PARENT="$(cd -P "$(/usr/bin/dirname "$DEST")" 2>/dev/null && pwd)" || exit 64
    DEST="$DEST_PARENT/$(/usr/bin/basename "$DEST")"

    FAILURE="$UPDATES/last-install-failure.txt"
    LOG="$UPDATES/install.log"
    : >"$LOG"
    exec >>"$LOG" 2>&1
    log() { echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*"; }

    # Handshake: the app only proceeds once this token's marker exists. cancel-<token> (before the app
    # quits) and commit-<token> (required once it has quit) are written by the app.
    STARTED="$ROOT/started-$TOKEN"
    CANCEL="$ROOT/cancel-$TOKEN"
    COMMIT="$ROOT/commit-$TOKEN"
    : >"$STARTED" || exit 65

    # Created with mktemp -d (0700, guaranteed new) after Perch quit; only ever removed once we own it.
    CONTAINER=""
    NEW=""
    PREVIOUS=""
    MOVED_OLD=0    # 1 while the old bundle sits at $PREVIOUS
    RELAUNCH_OLD=0 # 1 once Perch has quit, so a failure reopens the old app
    DONE=0

    restore() {
      [ "$MOVED_OLD" = 1 ] || return 0
      if [ -e "$DEST" ]; then
        /bin/mv "$DEST" "$CONTAINER/Failed.app" || { log "cannot move the new bundle aside"; return 1; }
      fi
      /bin/mv "$PREVIOUS" "$DEST" || { log "cannot restore the previous bundle"; return 1; }
      MOVED_OLD=0
      log "previous bundle restored"
    }

    # PIDs of Perch processes running from $DEST. A function, not inline `case` inside `$(...)`:
    # /bin/sh mis-parses the unbalanced `)` of a case pattern inside command substitution.
    running_pids() {
      /bin/ps -axwwo pid=,command= | while read -r p c; do
        case "$c" in
          "$DEST/Contents/MacOS/Perch"|"$DEST/Contents/MacOS/Perch "*) echo "$p" ;;
        esac
      done
    }

    # Stop a new Perch that may already be running from $DEST before its bundle is moved away.
    stop_running() {
      [ "$MOVED_OLD" = 1 ] || return 0
      pids="$(running_pids)"
      [ -n "$pids" ] || return 0
      log "stopping the new Perch before rolling back: $pids"
      kill $pids 2>/dev/null
      n=0
      while [ "$n" -lt 50 ]; do
        alive=0
        for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
        [ "$alive" = 0 ] && return 0
        n=$((n + 1))
        /bin/sleep 0.2
      done
      kill -9 $pids 2>/dev/null
      /bin/sleep 0.5
    }

    fail() {
      log "FAILED: $1"
      DONE=1
      # Before the app quit nothing was touched and the staged app still belongs to the app.
      [ "$RELAUNCH_OLD" = 1 ] || exit 1
      stop_running
      if restore; then
        printf '%s\n' "$1" >"$FAILURE"
        /bin/rm -rf "$ROOT"
        if [ -n "$CONTAINER" ]; then /bin/rm -rf "$CONTAINER"; fi
        if [ -d "$DEST" ]; then /usr/bin/open "$DEST"; fi
      else
        printf '%s The previous Perch is kept at %s\n' "$1" "$PREVIOUS" >"$FAILURE"
      fi
      exit 1
    }

    trap 'fail "The installer was interrupted."' INT TERM
    trap 'if [ "$DONE" != 1 ]; then DONE=1; stop_running; restore; fi' EXIT

    plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

    verify_bundle() {
      /usr/bin/codesign --verify --deep --strict --test-requirement="=$APP_REQ" "$1" || return 1
      /usr/bin/codesign --verify --strict --test-requirement="=$SIGNER_REQ" "$1/Contents/Helpers/perch" || return 1
      /usr/bin/codesign --verify --deep --strict --test-requirement="=$SIGNER_REQ" \
        "$1/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework" || return 1
      [ "$(plist_value "$1" CFBundleIdentifier)" = "$BUNDLE_ID" ] || return 1
      [ "$(plist_value "$1" CFBundleShortVersionString)" = "$VERSION" ] || return 1
      [ "$(plist_value "$1" CFBundleVersion)" = "$BUILD" ] || return 1
    }

    is_running() { [ -n "$(running_pids)" ]; }

    cancelled() { [ -e "$CANCEL" ]; }
    stand_down() { DONE=1; log "$1"; exit 0; }

    log "waiting for pid $PID to exit"
    waited=0
    limit=$((WAIT_SECONDS * 5))
    while kill -0 "$PID" 2>/dev/null; do
      if cancelled; then stand_down "cancelled before Perch quit; nothing was changed"; fi
      waited=$((waited + 1))
      if [ "$waited" -gt "$limit" ]; then
        DONE=1
        log "Perch did not quit in time; nothing was changed"
        exit 1
      fi
      /bin/sleep 0.2
    done
    if cancelled; then stand_down "cancelled; nothing was changed"; fi
    if [ ! -e "$COMMIT" ]; then
      DONE=1
      log "Perch exited without an install request; nothing was changed"
      /bin/rm -rf "$ROOT"
      exit 0
    fi
    RELAUNCH_OLD=1
    log "Perch exited"

    verify_bundle "$STAGED" || fail "The downloaded update failed its signature check."

    CURRENT="$(plist_value "$DEST" CFBundleVersion)"
    case "$CURRENT" in ''|*[!0-9]*) fail "The installed Perch has no numeric build number." ;; esac
    [ "$BUILD" -gt "$CURRENT" ] || fail "The update (build $BUILD) is not newer than the installed build $CURRENT."

    CONTAINER="$(/usr/bin/mktemp -d "$(/usr/bin/dirname "$DEST")/.Perch-update.XXXXXX")" ||
      { CONTAINER=""; fail "Could not create a working folder next to Perch."; }
    NEW="$CONTAINER/Perch.app"
    PREVIOUS="$CONTAINER/Previous.app"
    /usr/bin/ditto "$STAGED" "$NEW" || fail "Could not copy the update next to Perch (is the disk full?)."
    # The installed bundle must not be writable by group or others, and carries no ACLs.
    /bin/chmod -R go-w "$NEW" || fail "Could not restrict the permissions of the update."
    /bin/chmod -RN "$NEW" || log "could not clear ACLs"
    if [ -n "$(/usr/bin/find "$NEW" ! -type l \( -perm -0020 -o -perm -0002 -o -perm -4000 -o -perm -2000 \) -print -quit)" ]; then
      fail "The update contains files with unsafe permissions."
    fi
    verify_bundle "$NEW" || fail "The copied update failed its signature check."

    # Authenticated: only now clear quarantine, on the verified copy.
    /usr/bin/xattr -dr com.apple.quarantine "$NEW"
    if /usr/bin/xattr -p com.apple.quarantine "$NEW" >/dev/null 2>&1; then
      fail "The quarantine flag could not be removed from the update."
    fi

    /bin/mv "$DEST" "$PREVIOUS" || fail "Could not move the current Perch aside."
    MOVED_OLD=1
    /bin/mv "$NEW" "$DEST" || fail "Could not move the update into place."
    verify_bundle "$DEST" || fail "The installed update failed its signature check."

    /usr/bin/open "$DEST" || fail "The updated Perch could not be opened."
    seen=0
    tries=0
    while [ "$tries" -lt 300 ]; do
      if is_running; then seen=1; break; fi
      tries=$((tries + 1))
      /bin/sleep 0.2
    done
    [ "$seen" = 1 ] || fail "The updated Perch did not start; the previous version was restored."
    /bin/sleep 4
    is_running || fail "The updated Perch quit right after launching; the previous version was restored."

    DONE=1
    log "installed version $VERSION build $BUILD"
    /bin/rm -f "$FAILURE"
    /bin/rm -rf "$ROOT" "$CONTAINER"
    exit 0
    """#
}
