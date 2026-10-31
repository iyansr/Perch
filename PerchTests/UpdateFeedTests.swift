import Foundation
import Testing
@testable import Perch

private func version(_ string: String) throws -> UpdateVersion {
    try #require(UpdateVersion(string), "\(string) should parse")
}

private let goodURL = "https://github.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip"

/// A GitHub release object shaped like the REST API's, with every field overridable.
private func releaseJSON(
    tag: String = "v1.2.3",
    draft: Bool = false,
    prerelease: Bool = false,
    body: Any = "Fixes things.",
    assets: [[String: Any]]? = nil
) throws -> Data {
    let defaultAssets: [[String: Any]] = [
        asset(name: "Perch-1.2.3.dmg", url: "https://github.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.dmg"),
        asset(name: "Perch-1.2.3.zip", url: goodURL),
    ]
    let object: [String: Any] = [
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "body": body,
        "assets": assets ?? defaultAssets,
    ]
    return try JSONSerialization.data(withJSONObject: object)
}

private func asset(name: String = "Perch-1.2.3.zip", size: Any = 4_096, state: String? = "uploaded", url: String = goodURL) -> [String: Any] {
    var asset: [String: Any] = ["name": name, "size": size, "browser_download_url": url]
    if let state { asset["state"] = state }
    return asset
}

struct UpdateVersionTests {
    @Test func parsesAndPrintsCanonically() throws {
        let stable = try version("1.20.300")
        #expect(stable.major == 1 && stable.minor == 20 && stable.patch == 300)
        #expect(!stable.isPrerelease)
        #expect(stable.description == "1.20.300")
        #expect(try version("0.0.0").description == "0.0.0")
        #expect(try version("0.2.0-beta.1").description == "0.2.0-beta.1")
        #expect(try version("1.0.0-x-y.2").description == "1.0.0-x-y.2") // hyphens inside the prerelease stay
        #expect(try version("1.0.0-beta.1").isPrerelease)
    }

    @Test func comparesCoreNumerically() throws {
        #expect(try version("1.2.3") < version("1.2.4"))
        #expect(try version("1.2.9") < version("1.10.0")) // 9 < 10, not "9" > "10"
        #expect(try version("1.9.9") < version("2.0.0"))
        #expect(try version("0.9.0") < version("0.10.0"))
        #expect(try version("1.2.3") == version("1.2.3"))
        #expect(!(try version("1.2.3") < version("1.2.3")))
    }

    @Test func followsTheSemverPrecedenceExample() throws {
        // semver.org §11: each is lower than the next.
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ]
        let versions = try ordered.map(version)
        for (lower, higher) in zip(versions, versions.dropFirst()) {
            #expect(lower < higher, "\(lower) should be below \(higher)")
            #expect(!(higher < lower), "\(higher) should not be below \(lower)")
        }
        #expect(versions.sorted() == versions)
        #expect(versions.reversed().sorted() == versions)
    }

    @Test func prereleaseOfTheNextVersionIsStillAboveTheCurrentRelease() throws {
        #expect(try version("1.2.3") < version("1.2.4-beta.1"))
        #expect(try version("1.2.3-beta.9") < version("1.2.3"))
    }

    @Test func numericIdentifiersCompareByValueAndSortBelowAlphanumeric() throws {
        #expect(try version("1.0.0-2") < version("1.0.0-10"))
        #expect(try version("1.0.0-99") < version("1.0.0-a"))
        #expect(try version("1.0.0-1.1") < version("1.0.0-1.a"))
        #expect(try version("1.0.0-A") < version("1.0.0-a")) // ASCII order: uppercase first
        #expect(try version("1.0.0-beta") < version("1.0.0-beta.0")) // a shorter set loses a tie
    }

    @Test func rejectsMalformedVersions() {
        let malformed = [
            "", " ", "1", "1.2", "1.2.3.4", "1..3", ".2.3", "1.2.", "v1.2.3", "V1.2.3",
            "1.2.3 ", " 1.2.3", "1.2.3\n", "1.2.x", "a.b.c", "-1.2.3", "1.-2.3", "+1.2.3",
            "01.2.3", "1.02.3", "1.2.03", "1.2.3-", "1.2.3-.", "1.2.3-beta.", "1.2.3-.beta",
            "1.2.3-beta..1", "1.2.3-01", "1.2.3-beta.01", "1.2.3-be_ta", "1.2.3-beta 1",
            "1.2.3+build", "1.2.3-beta+build", "1.2.3-é", "١.٢.٣", "1,2,3",
        ]
        for string in malformed {
            #expect(UpdateVersion(string) == nil, "\(string.debugDescription) should be rejected")
        }
    }

    @Test func rejectsOverflowingNumbers() {
        let tooBig = "99999999999999999999" // above Int.max
        #expect(UpdateVersion("\(tooBig).0.0") == nil)
        #expect(UpdateVersion("0.\(tooBig).0") == nil)
        #expect(UpdateVersion("0.0.\(tooBig)") == nil)
        #expect(UpdateVersion("1.0.0-\(tooBig)") == nil)
        #expect(UpdateVersion("1.0.0-beta.\(tooBig)") == nil)
        #expect(UpdateVersion("\(Int.max).0.0")?.major == Int.max)
        #expect(UpdateVersion("0.0.0-beta.\(tooBig)a")?.prerelease.last == .alphanumeric("\(tooBig)a"))
    }
}

struct UpdateFeedDecodingTests {
    @Test func decodesAStableRelease() throws {
        let release = try #require(try UpdateFeed.decode(releaseJSON(body: "  ## Notes\n- one\n\n")))
        #expect(release.version == (try version("1.2.3")))
        #expect(release.tag == "v1.2.3")
        #expect(release.notes == "## Notes\n- one")
        #expect(release.size == 4_096)
        #expect(release.downloadURL.absoluteString == goodURL)
    }

    @Test func nullBodyBecomesEmptyNotes() throws {
        let release = try #require(try UpdateFeed.decode(releaseJSON(body: NSNull())))
        #expect(release.notes == "")
    }

    @Test func draftsAndPrereleaseFlagsAreNeverOffered() throws {
        #expect(try UpdateFeed.decode(releaseJSON(draft: true)) == nil)
        #expect(try UpdateFeed.decode(releaseJSON(prerelease: true)) == nil)
        // Flagged releases are skipped before anything else is inspected, even a missing ZIP or odd tag.
        #expect(try UpdateFeed.decode(releaseJSON(tag: "nightly", prerelease: true, assets: [])) == nil)
        #expect(try UpdateFeed.decode(releaseJSON(tag: "v1.2.3-beta.1", draft: true)) == nil)
    }

    @Test func aPrereleaseVersionNotFlaggedPrereleaseIsAnAuthoringError() throws {
        let data = try releaseJSON(
            tag: "v1.3.0-beta.1",
            assets: [asset(name: "Perch-1.3.0-beta.1.zip", url: "https://github.com/iyansr/Perch/releases/download/v1.3.0-beta.1/Perch-1.3.0-beta.1.zip")]
        )
        #expect(throws: UpdateFeed.FeedError.prereleaseTag("v1.3.0-beta.1")) { try UpdateFeed.decode(data) }
    }

    @Test func rejectsTagsThatAreNotVPlusAVersion() throws {
        for tag in ["1.2.3", "V1.2.3", "v1.2", "v01.2.3", "v1.2.3+5", "release-1.2.3", "vv1.2.3", "v1.2.3 ", ""] {
            let data = try releaseJSON(tag: tag)
            #expect(throws: UpdateFeed.FeedError.invalidTag(tag), "tag \(tag.debugDescription)") { try UpdateFeed.decode(data) }
        }
    }

    @Test func requiresTheExactZipName() throws {
        let wrongNames = [
            "Perch.zip", "Perch-1.2.4.zip", "Perch-v1.2.3.zip", "perch-1.2.3.zip", "Perch-1.2.3.ZIP",
            "Perch-1.2.3.zip.sha256", "Perch-1.2.3-universal.zip", "Perch-1.2.3.dmg", "Perch-1.2.3.zip ",
        ]
        for name in wrongNames {
            let data = try releaseJSON(assets: [asset(name: name)])
            #expect(
                throws: UpdateFeed.FeedError.missingAsset(name: "Perch-1.2.3.zip", tag: "v1.2.3"),
                "asset \(name.debugDescription)"
            ) { try UpdateFeed.decode(data) }
        }
        let none = try releaseJSON(assets: [])
        #expect(throws: UpdateFeed.FeedError.missingAsset(name: "Perch-1.2.3.zip", tag: "v1.2.3")) { try UpdateFeed.decode(none) }
    }

    @Test func rejectsEmptyOrNegativeSizesAndUnfinishedUploads() throws {
        for size in [0, -1] {
            let data = try releaseJSON(assets: [asset(size: size)])
            #expect(throws: UpdateFeed.FeedError.self) {
                try UpdateFeed.decode(data)
            }
        }
        let unfinished = try releaseJSON(assets: [asset(state: "starter")])
        #expect(throws: UpdateFeed.FeedError.self) {
            try UpdateFeed.decode(unfinished)
        }
        // The API always sends `state`; its absence is not a reason to refuse an otherwise valid asset.
        #expect(try UpdateFeed.decode(releaseJSON(assets: [asset(state: nil)])) != nil)
    }

    @Test func acceptsOnlyTheImmutableGitHubReleaseAssetURL() throws {
        let bad = [
            "http://github.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip", // not HTTPS
            "https://evil.example/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip", // other host
            "https://github.com.evil.example/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip",
            "https://evil.example@github.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip", // credentials
            "https://github.com:8443/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip", // port
            "https://github.com/someone/Perch/releases/download/v1.2.3/Perch-1.2.3.zip", // other owner
            "https://github.com/iyansr/Perch-fork/releases/download/v1.2.3/Perch-1.2.3.zip", // other repo
            "https://github.com/iyansr/perch/releases/download/v1.2.3/Perch-1.2.3.zip", // case differs
            "https://github.com/iyansr/Perch/releases/download/v1.2.2/Perch-1.2.3.zip", // other tag
            "https://github.com/iyansr/Perch/releases/latest/download/Perch-1.2.3.zip", // moving alias
            "https://github.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.4.zip", // other file
            "https://github.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip?token=x",
            "https://github.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip#frag",
            "https://github.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip/",
            "https://github.com/iyansr/Perch/releases/download/v1.2.3/../v1.2.3/Perch-1.2.3.zip",
            "https://github.com//iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip",
            "https://api.github.com/repos/iyansr/Perch/releases/assets/1",
            "https://objects.githubusercontent.com/iyansr/Perch/releases/download/v1.2.3/Perch-1.2.3.zip",
            "file:///tmp/Perch-1.2.3.zip", "Perch-1.2.3.zip", "",
        ]
        for url in bad {
            let data = try releaseJSON(assets: [asset(url: url)])
            #expect(throws: UpdateFeed.FeedError.self, "url \(url.debugDescription)") { try UpdateFeed.decode(data) }
        }
    }

    @Test func acceptsMultiDigitVersionsInTagAndAssetPath() throws {
        let url = "https://github.com/iyansr/Perch/releases/download/v10.0.0/Perch-10.0.0.zip"
        let data = try releaseJSON(tag: "v10.0.0", assets: [asset(name: "Perch-10.0.0.zip", url: url)])
        #expect(try UpdateFeed.decode(data)?.downloadURL.absoluteString == url)
    }

    @Test func malformedPayloadsThrow() {
        let payloads = [
            "", "not json", "[]", "{}", #"{"message":"Not Found"}"#,
            #"{"tag_name":"v1.2.3","draft":false,"prerelease":false}"#, // no assets
            #"{"tag_name":1,"draft":false,"prerelease":false,"assets":[]}"#,
            #"{"tag_name":"v1.2.3","draft":"no","prerelease":false,"assets":[]}"#,
            #"{"tag_name":"v1.2.3","draft":false,"prerelease":false,"assets":[{"name":"Perch-1.2.3.zip"}]}"#,
            #"{"tag_name":"v1.2.3","draft":false,"prerelease":false,"assets":[{"name":"Perch-1.2.3.zip","size":1.5,"browser_download_url":"x"}]}"#,
        ]
        for payload in payloads {
            #expect(throws: UpdateFeed.FeedError.malformed, "payload \(payload.debugDescription)") {
                try UpdateFeed.decode(Data(payload.utf8))
            }
        }
    }
}

struct UpdateFeedSelectionTests {
    @Test func offersOnlyStrictlyNewerReleases() throws {
        let data = try releaseJSON()
        #expect(try UpdateFeed.release(in: data, newerThan: version("1.2.2"))?.tag == "v1.2.3")
        #expect(try UpdateFeed.release(in: data, newerThan: version("0.9.0"))?.tag == "v1.2.3")
        #expect(try UpdateFeed.release(in: data, newerThan: version("1.2.3")) == nil) // same
        #expect(try UpdateFeed.release(in: data, newerThan: version("1.2.4")) == nil) // downgrade
        #expect(try UpdateFeed.release(in: data, newerThan: version("2.0.0")) == nil)
    }

    @Test func aRunningPrereleaseUpdatesToItsStableRelease() throws {
        let data = try releaseJSON()
        #expect(try UpdateFeed.release(in: data, newerThan: version("1.2.3-beta.4")) != nil)
        #expect(try UpdateFeed.release(in: data, newerThan: version("1.3.0-beta.1")) == nil)
    }

    @Test func prereleasesAreNeverSelectedRegardlessOfVersion() throws {
        let data = try releaseJSON(tag: "v9.9.9", prerelease: true, assets: [])
        #expect(try UpdateFeed.release(in: data, newerThan: version("1.0.0")) == nil)
    }

    @Test func malformedReleasesSurfaceAsErrorsNotSilentSkips() throws {
        let data = try releaseJSON(assets: [])
        #expect(throws: UpdateFeed.FeedError.missingAsset(name: "Perch-1.2.3.zip", tag: "v1.2.3")) {
            try UpdateFeed.release(in: data, newerThan: version("1.0.0"))
        }
    }

}
