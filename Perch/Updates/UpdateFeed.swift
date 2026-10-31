import Foundation

/// A strict `MAJOR.MINOR.PATCH[-prerelease]` version with full Semantic Versioning 2.0 precedence.
///
/// Strict on purpose: anything the release workflow could not have produced is rejected rather than
/// guessed at, so a malformed tag can never look newer than the running app. No `v` prefix, no
/// `+build` metadata, no leading zeros in numeric parts, no whitespace, and every numeric part must
/// fit an `Int` (an overflowing part is malformed, not clamped).
nonisolated struct UpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// One dot-separated prerelease identifier. Numeric identifiers sort below alphanumeric ones.
    nonisolated enum Identifier: Hashable, Sendable {
        case numeric(Int)
        case alphanumeric(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    /// Empty for a stable version.
    let prerelease: [Identifier]

    var isPrerelease: Bool { !prerelease.isEmpty }

    init?(_ string: String) {
        // Everything after the first hyphen is the prerelease; it may contain hyphens itself.
        let core: Substring
        let tail: Substring?
        if let hyphen = string.firstIndex(of: "-") {
            core = string[..<hyphen]
            tail = string[string.index(after: hyphen)...]
        } else {
            core = string[...]
            tail = nil
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Self.number(parts[0]),
              let minor = Self.number(parts[1]),
              let patch = Self.number(parts[2])
        else { return nil }

        var identifiers: [Identifier] = []
        if let tail {
            for part in tail.split(separator: ".", omittingEmptySubsequences: false) {
                guard let identifier = Self.identifier(part) else { return nil }
                identifiers.append(identifier)
            }
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = identifiers
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard isPrerelease else { return core }
        let tail = prerelease.map { identifier in
            switch identifier {
            case .numeric(let value): String(value)
            case .alphanumeric(let text): text
            }
        }
        return core + "-" + tail.joined(separator: ".")
    }

    static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A prerelease sorts below the release it precedes.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (left, right) {
            case (.numeric(let a), .numeric(let b)): return a < b
            case (.numeric, .alphanumeric): return true
            case (.alphanumeric, .numeric): return false
            case (.alphanumeric(let a), .alphanumeric(let b)): return a.utf8.lexicographicallyPrecedes(b.utf8)
            }
        }
        // All shared identifiers are equal: the longer set has higher precedence.
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// ASCII digits only, no leading zero (except `0` itself), fits `Int`.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy(isDigit) else { return nil }
        if text.utf8.count > 1, text.utf8.first == 0x30 { return nil }
        return Int(text)
    }

    private static func identifier(_ text: Substring) -> Identifier? {
        guard !text.isEmpty else { return nil }
        let isAlphanumeric: (UInt8) -> Bool = { byte in
            isDigit(byte) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
        }
        guard text.utf8.allSatisfy(isAlphanumeric) else { return nil }
        if text.utf8.allSatisfy(isDigit) {
            return number(text).map(Identifier.numeric)
        }
        return .alphanumeric(String(text))
    }
}

/// A stable release Perch can update to. Every field has already passed `UpdateFeed` validation, but
/// `notes` is untrusted author-controlled text.
nonisolated struct UpdateRelease: Sendable, Equatable {
    let version: UpdateVersion
    let tag: String
    let notes: String
    let downloadURL: URL
    let size: Int64
}

/// Discovers the latest stable GitHub Release of Perch.
///
/// Network: unauthenticated `GET /repos/iyansr/Perch/releases/latest`. The stable endpoint ignores
/// drafts and prereleases, so a pile of newer betas can never hide the stable release the way a
/// paged listing could. No token is sent or bundled; the repository is public.
///
/// Validation is the first layer only. A release is offered when its tag is `v<version>` with a stable
/// version, and it carries exactly `Perch-<version>.zip` (non-empty, uploaded) at the immutable
/// `https://github.com/iyansr/Perch/releases/download/<tag>/Perch-<version>.zip` URL. The downloaded
/// app is still authenticated by its code signature in `UpdateInstaller`; the feed is not trusted.
nonisolated enum UpdateFeed {
    static let repository = "iyansr/Perch"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/iyansr/Perch/releases/latest")!

    nonisolated enum FeedError: Error, Equatable, LocalizedError {
        /// The response was not HTTP.
        case invalidResponse
        /// GitHub refused the request because the unauthenticated rate limit is used up.
        case rateLimited
        case http(status: Int)
        /// The body is not a GitHub release object.
        case malformed
        /// The stable endpoint returned a tag that is not `v<MAJOR.MINOR.PATCH>`.
        case invalidTag(String)
        /// A stable release (not flagged prerelease) whose tag carries a prerelease version.
        case prereleaseTag(String)
        case missingAsset(name: String, tag: String)
        case invalidAsset(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "GitHub returned a response that was not HTTP."
            case .rateLimited:
                "GitHub rate-limited the update check. Try again later."
            case .http(let status):
                "GitHub returned HTTP \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))."
            case .malformed:
                "GitHub returned a release Perch could not read."
            case .invalidTag(let tag):
                "The latest release tag \"\(tag)\" is not a version like v1.2.3."
            case .prereleaseTag(let tag):
                "The latest stable release \"\(tag)\" has a prerelease version."
            case .missingAsset(let name, let tag):
                "Release \(tag) has no \(name)."
            case .invalidAsset(let name, let reason):
                "Release asset \(name) is not usable: \(reason)."
            }
        }
    }

    // MARK: Network

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// The newest stable release if it is strictly newer than `currentVersion`; `nil` when there is none
    /// (no releases yet, nothing newer, or the latest is not a stable release). Throws for transport
    /// failures, HTTP errors and a latest release that is malformed or lacks the update ZIP.
    static func latest(currentVersion: UpdateVersion) async throws -> UpdateRelease? {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Perch/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedError.invalidResponse }
        switch http.statusCode {
        case 200:
            return try release(in: data, newerThan: currentVersion)
        case 404:
            return nil // The repository has no published release yet.
        case 403, 429:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.statusCode == 429 {
                throw FeedError.rateLimited
            }
            throw FeedError.http(status: http.statusCode)
        default:
            throw FeedError.http(status: http.statusCode)
        }
    }

    // MARK: Decoding and selection

    /// `decode(_:)` filtered to releases strictly newer than `currentVersion`.
    static func release(in data: Data, newerThan currentVersion: UpdateVersion) throws -> UpdateRelease? {
        guard let release = try decode(data), release.version > currentVersion else { return nil }
        return release
    }

    /// Decodes one GitHub release object. Returns `nil` for a draft or a release flagged prerelease (not
    /// stable, so never offered); throws a `FeedError` naming the first problem with anything else.
    static func decode(_ data: Data) throws -> UpdateRelease? {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw FeedError.malformed
        }
        if payload.draft || payload.prerelease { return nil }

        // The workflow tags `v<version>`; a tag that does not round-trip through the version is rejected.
        guard payload.tagName.hasPrefix("v"),
              let version = UpdateVersion(String(payload.tagName.dropFirst())),
              payload.tagName == "v\(version)"
        else { throw FeedError.invalidTag(payload.tagName) }
        guard !version.isPrerelease else { throw FeedError.prereleaseTag(payload.tagName) }

        let tag = payload.tagName
        let assetName = "Perch-\(version).zip"
        guard let asset = payload.assets.first(where: { $0.name == assetName }) else {
            throw FeedError.missingAsset(name: assetName, tag: tag)
        }
        guard asset.size > 0 else {
            throw FeedError.invalidAsset(name: assetName, reason: "its size is \(asset.size)")
        }
        if let state = asset.state, state != "uploaded" {
            throw FeedError.invalidAsset(name: assetName, reason: "its upload state is \(state)")
        }
        let expectedPath = "/\(repository)/releases/download/\(tag)/\(assetName)"
        guard let downloadURL = verifiedDownloadURL(asset.browserDownloadURL, expectedPath: expectedPath) else {
            throw FeedError.invalidAsset(
                name: assetName,
                reason: "its URL is not https://github.com\(expectedPath)"
            )
        }

        return UpdateRelease(
            version: version,
            tag: tag,
            notes: (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            downloadURL: downloadURL,
            size: asset.size
        )
    }

    /// Only the exact immutable release-asset URL on github.com: HTTPS, no credentials, port, query or
    /// fragment, and the path of this repository, tag and file.
    private static func verifiedDownloadURL(_ string: String, expectedPath: String) -> URL? {
        guard let components = URLComponents(string: string),
              components.scheme == "https",
              components.host == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == expectedPath
        else { return nil }
        return components.url
    }

    private nonisolated struct Payload: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
        let assets: [Asset]

        nonisolated struct Asset: Decodable {
            let name: String
            let size: Int64
            let state: String?
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name, size, state
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, body, assets
        }
    }
}
