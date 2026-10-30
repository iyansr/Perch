import Foundation

/// Finds a video-call join link in a calendar event.
nonisolated enum MeetingLink {
    enum Service: Equatable {
        case zoom, meet, teams, webex, other

        var title: String {
            switch self {
            case .zoom: "Zoom"
            case .meet: "Google Meet"
            case .teams: "Teams"
            case .webex: "Webex"
            case .other: "Link"
            }
        }
    }

    private static let patterns: [(Service, String)] = [
        (.zoom, #"https://[\w.-]*zoom\.us/(?:j|my|w)/[^\s<>"')]+"#),
        (.meet, #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<>"')]*"#),
        (.teams, #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"')]+"#),
        (.webex, #"https://[\w.-]*webex\.com/[^\s<>"')]+"#),
    ]

    /// The event URL when it is a call link, then the first call link in the notes, then the location.
    static func find(url: URL?, notes: String?, location: String?) -> (service: Service, url: URL)? {
        if let url, let service = service(of: url.absoluteString) { return (service, url) }
        for text in [notes, location].compactMap({ $0 }) {
            for (service, pattern) in patterns {
                guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                      let found = URL(string: String(text[range]))
                else { continue }
                return (service, found)
            }
        }
        return nil
    }

    static func service(of text: String) -> Service? {
        patterns.first { text.range(of: "^" + $0.1, options: [.regularExpression, .caseInsensitive]) != nil }?.0
    }

    /// `https://us02web.zoom.us/j/123?pwd=abc` → `zoommtg://zoom.us/join?confno=123&pwd=abc`, which opens
    /// the Zoom app directly instead of a browser tab. nil for links that are not `/j/<number>`.
    static func zoomAppURL(for url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.hasSuffix("zoom.us") == true
        else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "j", parts[1].allSatisfy(\.isNumber) else { return nil }
        var app = URLComponents()
        app.scheme = "zoommtg"
        app.host = "zoom.us"
        app.path = "/join"
        app.queryItems = [URLQueryItem(name: "confno", value: String(parts[1]))]
            + (components.queryItems?.filter { $0.name == "pwd" } ?? [])
        return app.url
    }
}
