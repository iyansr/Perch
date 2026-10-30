import AppKit
import CoreLocation
import MapKit
import Observation
import os
import SwiftUI

/// Current temperature and sky condition, ambient beside the notch when nothing else is showing.
///
/// Where: the city typed in Settings (`AppSettings.weatherCity`), geocoded through Open-Meteo's own
/// geocoding API (same provider and no key, no second permission, and Apple's geocoder is rate-limited),
/// or the Mac's location when that setting is empty. Conditions come from
/// Open-Meteo every 30 minutes and after wake; failures back off (1, 2, 4 … 30 min).
final class WeatherSource: ActivitySource {
    static let id = "weather"
    static let info = ActivitySourceInfo(
        title: "Weather",
        detail: "Temperature and sky condition beside the notch. Uses the city set below, or your Mac's location when it is empty.",
        symbol: "cloud.sun.fill",
        tint: .cyan,
        permission: nil // Location is asked for only when no city is set.
    )

    static let weatherBundleID = "com.apple.weather"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Perch", category: "Weather")

    private let activityID = UUID()
    private let settings = AppSettings.shared
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private weak var center: ActivityCenter?
    private var isRunning = false
    /// Bumped whenever the target changes or the source stops; results from an older one are dropped.
    private var generation = 0
    private var scheduled: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    /// The trimmed city setting the current state belongs to.
    private var activeCity = ""
    private var geocoded: (city: String, place: WeatherPlace)?
    /// A city the geocoder returned nothing for; not retried until the setting changes.
    private var unresolvedCity: String?
    private var locationName: (location: CLLocation, name: String)?

    private var failures = 0
    private var lastSuccess: Date?
    private var lastAttempt: Date?

    func start(center: ActivityCenter) {
        self.center = center
        isRunning = true
        activeCity = Self.trimmed(settings.weatherCity)
        observeCity()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        schedule(after: 0)
    }

    func stop() {
        isRunning = false
        generation += 1
        scheduled?.cancel()
        fetchTask?.cancel()
        scheduled = nil
        fetchTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        geocoded = nil
        unresolvedCity = nil
        locationName = nil
        failures = 0
        lastSuccess = nil
        lastAttempt = nil
        center?.dismiss(activityID)
    }

    // MARK: Triggers

    private func observeCity() {
        withObservationTracking {
            _ = settings.weatherCity
        } onChange: { [weak self] in
            Task { @MainActor in self?.cityChanged() }
        }
    }

    /// Fires per keystroke while the city is typed, so the fetch waits a second for the typing to stop.
    private func cityChanged() {
        guard isRunning else { return }
        observeCity()
        let city = Self.trimmed(settings.weatherCity)
        guard city != activeCity else { return }
        activeCity = city
        generation += 1
        geocoded = nil
        unresolvedCity = nil
        failures = 0
        schedule(after: 1)
    }

    private func handleWake() {
        let now = Date()
        guard isRunning, unresolvedCity == nil,
              WeatherSchedule.shouldRefreshOnWake(lastSuccess: lastSuccess, failures: failures, now: now)
        else { return }
        // Wi-Fi is usually not back yet at the wake notification.
        schedule(after: max(5, WeatherSchedule.delayToRespectGap(lastAttempt: lastAttempt, now: now)))
    }

    private func schedule(after delay: TimeInterval) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.fetchTask?.cancel()
            self.fetchTask = Task { await self.refresh() }
        }
    }

    // MARK: Fetch

    private func refresh() async {
        guard isRunning, unresolvedCity != activeCity else { return }
        let token = generation
        lastAttempt = Date()
        do {
            guard let target = try await resolveTarget(), token == generation else { return }
            let unit = WeatherUnit.current
            guard let url = WeatherAPI.forecastURL(latitude: target.latitude, longitude: target.longitude, unit: unit) else { return }
            let report = try WeatherAPI.parseForecast(try await download(url), fallbackUnit: unit)
            guard token == generation else { return }
            failures = 0
            lastSuccess = Date()
            publish(report, title: target.name)
            schedule(after: WeatherSchedule.refreshInterval)
        } catch is LocationProvider.Unavailable {
            guard token == generation else { return }
            Self.log.notice("Location unavailable (denied or restricted); weather stays off. Set a city in Settings or allow Location.")
            center?.dismiss(activityID)
            schedule(after: WeatherSchedule.refreshInterval) // picks the permission up once granted
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            failures += 1
            let delay = WeatherSchedule.retryDelay(failures: failures)
            Self.log.error("Weather fetch failed (\(self.failures)x, retry in \(Int(delay)) s): \(error.localizedDescription, privacy: .public)")
            if WeatherSchedule.isStale(lastSuccess: lastSuccess, now: Date()) { center?.dismiss(activityID) }
            schedule(after: delay)
        }
    }

    private struct Target {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    /// Typed city → geocoded once and cached until the setting changes; otherwise the Mac's location.
    /// nil: the city is unknown; nothing shows.
    private func resolveTarget() async throws -> Target? {
        let city = activeCity
        let token = generation
        if !city.isEmpty {
            if let geocoded, geocoded.city == city {
                return Target(name: geocoded.place.name, latitude: geocoded.place.latitude, longitude: geocoded.place.longitude)
            }
            guard let url = WeatherAPI.geocodingURL(city: city) else { return nil }
            let place = try WeatherAPI.parseGeocoding(try await download(url))
            guard token == generation else { return nil }
            guard let place else {
                Self.log.notice("No place found for city “\(city, privacy: .public)”; weather stays off")
                unresolvedCity = city
                center?.dismiss(activityID)
                return nil
            }
            geocoded = (city, place)
            return Target(name: place.name, latitude: place.latitude, longitude: place.longitude)
        }
        let location = try await LocationProvider.currentLocation()
        return Target(name: await placeName(for: location), latitude: location.coordinate.latitude,
                      longitude: location.coordinate.longitude)
    }

    /// Reverse geocoding is rate-limited by Apple; a fix within 5 km of the last named one keeps its name.
    private func placeName(for location: CLLocation) async -> String {
        if let locationName, locationName.location.distance(from: location) < 5_000 { return locationName.name }
        let items = try? await MKReverseGeocodingRequest(location: location)?.mapItems
        let name = items?.first.flatMap { $0.addressRepresentations?.cityName ?? $0.name } ?? "Weather"
        locationName = (location, name)
        return name
    }

    private func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: Publish

    private func publish(_ report: WeatherReport, title: String) {
        guard let center else { return }
        var activity = Activity(
            id: activityID, kind: .weather, symbol: report.symbol, title: title,
            detail: report.temperatureText, status: .running, progress: .indeterminate, updatedAt: Date(),
            presentation: .ambient
        )
        activity.link = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.weatherBundleID)
            .map { ActivityLink(title: "Open Weather", url: $0) }
        center.show(activity)
    }

    private static func trimmed(_ city: String) -> String {
        city.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One-shot Mac location: the first fix from Core Location's live updates. Starting the stream makes
/// Core Location ask for authorization on the app's behalf the first time. Cancelling the awaiting task
/// ends the stream and with it location services. No fix within `timeout` fails like a Core Location
/// error, so the source backs off and retries instead of waiting forever.
/// `CLLocationUpdate.liveUpdates` has no accuracy setting, so the old reduced-accuracy request is gone;
/// weather only needs the city, so the extra precision is unused.
enum LocationProvider {
    struct Unavailable: Error {}

    static func currentLocation(timeout: Duration = .seconds(30)) async throws -> CLLocation {
        try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { try await firstFix() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CLError(.locationUnknown)
            }
            defer { group.cancelAll() }
            guard let location = try await group.next() else { throw CLError(.locationUnknown) }
            return location
        }
    }

    private static func firstFix() async throws -> CLLocation {
        for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                throw Unavailable()
            }
            if let location = update.location { return location }
        }
        try Task.checkCancellation()
        throw CLError(.locationUnknown)
    }
}
