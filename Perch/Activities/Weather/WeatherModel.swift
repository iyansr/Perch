import Foundation

/// Temperature unit for the forecast request and the pill.
nonisolated enum WeatherUnit: String, Equatable {
    case celsius, fahrenheit

    /// Fahrenheit only where the region's measurement system is the US one; the UK system uses Celsius.
    init(measurementSystem: Locale.MeasurementSystem) {
        self = measurementSystem == .us ? .fahrenheit : .celsius
    }

    static var current: WeatherUnit {
        WeatherUnit(measurementSystem: Locale.current.measurementSystem)
    }

    /// Open-Meteo's `temperature_unit` query value.
    var queryValue: String { rawValue }

    /// Matches the `current_units.temperature_2m` string Open-Meteo sends back.
    init?(responseSymbol: String) {
        switch responseSymbol {
        case "°C": self = .celsius
        case "°F": self = .fahrenheit
        default: return nil
        }
    }
}

/// WMO weather interpretation codes (the `weather_code` Open-Meteo returns) as text and SF Symbols.
nonisolated enum WeatherCondition {
    static func description(code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51: "Light drizzle"
        case 53: "Drizzle"
        case 55: "Heavy drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71: "Light snow"
        case 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80: "Light showers"
        case 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "Unknown"
        }
    }

    /// Filled SF Symbol; clear and partly cloudy skies switch to a moon after dark.
    static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95: "cloud.bolt.fill"
        case 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

/// Current conditions plus today's range, in the unit the response carries.
nonisolated struct WeatherReport: Equatable {
    var temperature: Double
    var code: Int
    var isDay: Bool
    var high: Double?
    var low: Double?
    var unit: WeatherUnit

    var symbol: String { WeatherCondition.symbol(code: code, isDay: isDay) }
    var summary: String { WeatherCondition.description(code: code) }

    /// "18°" — the pill's text. Rounded; never "-0°".
    var temperatureText: String { Self.degrees(temperature) }

    /// "Partly cloudy · H 20° L 11°", for tooltips.
    var detailText: String {
        var parts = [summary]
        if let high, let low { parts.append("H \(Self.degrees(high)) L \(Self.degrees(low))") }
        return parts.joined(separator: " · ")
    }

    static func degrees(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }
}

/// A geocoded city.
nonisolated struct WeatherPlace: Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
}

nonisolated enum WeatherAPI {
    static let forecastEndpoint = "https://api.open-meteo.com/v1/forecast"
    static let geocodingEndpoint = "https://geocoding-api.open-meteo.com/v1/search"

    static func forecastURL(latitude: Double, longitude: Double, unit: WeatherUnit) -> URL? {
        var components = URLComponents(string: forecastEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: unit.queryValue),
        ]
        return components?.url
    }

    static func geocodingURL(city: String) -> URL? {
        var components = URLComponents(string: geocodingEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "name", value: city.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    enum ParseError: Error, Equatable {
        case malformed
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Units: Decodable {
            let temperature_2m: String
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
        }
        let current: Current
        let current_units: Units?
        let daily: Daily?
    }

    /// Parses a `/v1/forecast` response. `fallbackUnit` applies when the response names none.
    static func parseForecast(_ data: Data, fallbackUnit: WeatherUnit = .celsius) throws -> WeatherReport {
        guard let forecast = try? JSONDecoder().decode(Forecast.self, from: data) else { throw ParseError.malformed }
        return WeatherReport(
            temperature: forecast.current.temperature_2m,
            code: forecast.current.weather_code,
            isDay: forecast.current.is_day != 0,
            high: forecast.daily?.temperature_2m_max.first.flatMap { $0 },
            low: forecast.daily?.temperature_2m_min.first.flatMap { $0 },
            unit: forecast.current_units.flatMap { WeatherUnit(responseSymbol: $0.temperature_2m) } ?? fallbackUnit
        )
    }

    private struct Geocoding: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
        }
        let results: [Result]?
    }

    /// Parses a `/v1/search` response: the first hit, or nil when the city is unknown (the key is absent then).
    static func parseGeocoding(_ data: Data) throws -> WeatherPlace? {
        guard let decoded = try? JSONDecoder().decode(Geocoding.self, from: data) else { throw ParseError.malformed }
        return decoded.results?.first.map { WeatherPlace(name: $0.name, latitude: $0.latitude, longitude: $0.longitude) }
    }
}

/// When to fetch next.
nonisolated enum WeatherSchedule {
    /// Between refreshes while all goes well.
    static let refreshInterval: TimeInterval = 30 * 60
    /// First retry after a failure; doubles up to `refreshInterval`.
    static let retryBase: TimeInterval = 60
    /// No fetch starts sooner than this after the previous one began, whatever asked for it.
    static let minimumGap: TimeInterval = 60
    /// A reading this old is dropped instead of shown.
    static let staleAfter: TimeInterval = 3 * 3600

    /// Delay before retrying after `failures` consecutive failures (1 → 60 s, 2 → 120 s, … capped at 30 min).
    static func retryDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return refreshInterval }
        let doubled = retryBase * pow(2, Double(min(failures - 1, 16)))
        return min(doubled, refreshInterval)
    }

    /// A wake refetches only when the reading is a full interval old or the last attempt failed.
    static func shouldRefreshOnWake(lastSuccess: Date?, failures: Int, now: Date) -> Bool {
        guard let lastSuccess, failures == 0 else { return true }
        return now.timeIntervalSince(lastSuccess) >= refreshInterval
    }

    static func isStale(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= staleAfter
    }

    /// How long to wait so a fetch starts at least `minimumGap` after `lastAttempt`.
    static func delayToRespectGap(lastAttempt: Date?, now: Date) -> TimeInterval {
        guard let lastAttempt else { return 0 }
        return max(0, minimumGap - now.timeIntervalSince(lastAttempt))
    }
}
