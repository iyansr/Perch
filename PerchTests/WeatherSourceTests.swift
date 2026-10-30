import AppKit
import Foundation
import Testing
@testable import Perch

private final class WeatherFixtureToken {}

/// Fixtures are real Open-Meteo responses captured on Oct 30, 2026 (reformatted with indentation).
private func weatherFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: WeatherFixtureToken.self).url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

struct WeatherParsingTests {
    @Test func parsesDaytimeCelsiusForecast() throws {
        let report = try WeatherAPI.parseForecast(weatherFixture("weather-forecast-berlin-celsius"))
        #expect(report.temperature == 9.0)
        #expect(report.code == 3)
        #expect(report.isDay)
        #expect(report.high == 9.2)
        #expect(report.low == 7.1)
        #expect(report.unit == .celsius)
        #expect(report.temperatureText == "9°")
        #expect(report.symbol == "cloud.fill")
        #expect(report.detailText == "Overcast · H 9° L 7°")
    }

    @Test func parsesFahrenheitForecastAndReadsTheUnitFromTheResponse() throws {
        // Asked for as Celsius by default, but the response says °F, so the response wins.
        let report = try WeatherAPI.parseForecast(weatherFixture("weather-forecast-newyork-fahrenheit"))
        #expect(report.unit == .fahrenheit)
        #expect(report.temperature == 70.6)
        #expect(report.temperatureText == "71°")
        #expect(report.code == 0)
        #expect(report.symbol == "sun.max.fill")
    }

    @Test func parsesNighttimeForecast() throws {
        let report = try WeatherAPI.parseForecast(weatherFixture("weather-forecast-sydney-celsius"))
        #expect(!report.isDay)
        #expect(report.code == 2)
        #expect(report.symbol == "cloud.moon.fill")
        #expect(report.temperatureText == "16°")
    }

    @Test func missingDailyBlockStillGivesCurrentConditions() throws {
        let json = #"{"current_units":{"temperature_2m":"°C"},"current":{"temperature_2m":-0.4,"weather_code":71,"is_day":0}}"#
        let report = try WeatherAPI.parseForecast(Data(json.utf8))
        #expect(report.high == nil && report.low == nil)
        #expect(report.temperatureText == "0°") // never "-0°"
        #expect(report.detailText == "Light snow")
    }

    @Test func malformedForecastThrows() {
        #expect(throws: WeatherAPI.ParseError.malformed) { try WeatherAPI.parseForecast(Data("{}".utf8)) }
        #expect(throws: WeatherAPI.ParseError.malformed) {
            try WeatherAPI.parseForecast(Data(#"{"error":true,"reason":"Latitude must be in range of -90 to 90°."}"#.utf8))
        }
        #expect(throws: WeatherAPI.ParseError.malformed) { try WeatherAPI.parseForecast(Data("not json".utf8)) }
    }

    @Test func parsesGeocodingHit() throws {
        let place = try #require(try WeatherAPI.parseGeocoding(weatherFixture("weather-geocode-berlin")))
        #expect(place.name == "Berlin")
        #expect(place.latitude == 52.52437)
        #expect(place.longitude == 13.41053)
    }

    @Test func unknownCityIsNilNotAnError() throws {
        // Open-Meteo omits "results" entirely when nothing matches.
        #expect(try WeatherAPI.parseGeocoding(weatherFixture("weather-geocode-none")) == nil)
        #expect(try WeatherAPI.parseGeocoding(Data(#"{"results":[]}"#.utf8)) == nil)
        #expect(throws: WeatherAPI.ParseError.malformed) { try WeatherAPI.parseGeocoding(Data("<html>".utf8)) }
    }

    @Test func urlsCarryTheRightQuery() throws {
        let forecast = try #require(WeatherAPI.forecastURL(latitude: 52.52, longitude: -13.405, unit: .fahrenheit))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: forecast, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(forecast.host == "api.open-meteo.com")
        #expect(items["latitude"] == "52.5200")
        #expect(items["longitude"] == "-13.4050")
        #expect(items["current"] == "temperature_2m,weather_code,is_day")
        #expect(items["temperature_unit"] == "fahrenheit")
        #expect(items["timezone"] == "auto")

        let geocode = try #require(WeatherAPI.geocodingURL(city: "  São Paulo "))
        let name = URLComponents(url: geocode, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
        #expect(geocode.host == "geocoding-api.open-meteo.com")
        #expect(name == "São Paulo")
    }
}

struct WeatherConditionTests {
    @Test func descriptionsCoverEveryWMOCode() {
        let codes = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99]
        for code in codes {
            #expect(WeatherCondition.description(code: code) != "Unknown", "code \(code)")
        }
        #expect(WeatherCondition.description(code: 12) == "Unknown")
        #expect(WeatherCondition.description(code: 95) == "Thunderstorm")
    }

    @Test func symbolsSwitchBetweenDayAndNight() {
        #expect(WeatherCondition.symbol(code: 0, isDay: true) == "sun.max.fill")
        #expect(WeatherCondition.symbol(code: 0, isDay: false) == "moon.stars.fill")
        #expect(WeatherCondition.symbol(code: 1, isDay: true) == "cloud.sun.fill")
        #expect(WeatherCondition.symbol(code: 2, isDay: false) == "cloud.moon.fill")
        #expect(WeatherCondition.symbol(code: 81, isDay: false) == "cloud.moon.rain.fill")
        #expect(WeatherCondition.symbol(code: 65, isDay: true) == "cloud.heavyrain.fill")
        #expect(WeatherCondition.symbol(code: 99, isDay: true) == "cloud.bolt.rain.fill")
        #expect(WeatherCondition.symbol(code: 1234, isDay: true) == "cloud.fill")
    }

    @Test func everySymbolExistsOnThisSystem() {
        let codes = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99, 1234]
        for code in codes {
            for isDay in [true, false] {
                let symbol = WeatherCondition.symbol(code: code, isDay: isDay)
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) for \(code)")
            }
        }
    }
}

struct WeatherUnitTests {
    @Test func fahrenheitOnlyForTheUSSystem() {
        #expect(WeatherUnit(measurementSystem: .us) == .fahrenheit)
        #expect(WeatherUnit(measurementSystem: .metric) == .celsius)
        #expect(WeatherUnit(measurementSystem: .uk) == .celsius)
    }

    @Test func responseSymbolsMapBack() {
        #expect(WeatherUnit(responseSymbol: "°C") == .celsius)
        #expect(WeatherUnit(responseSymbol: "°F") == .fahrenheit)
        #expect(WeatherUnit(responseSymbol: "K") == nil)
    }

    @Test func temperatureRounding() {
        #expect(WeatherReport.degrees(17.5) == "18°")
        #expect(WeatherReport.degrees(-3.6) == "-4°")
        #expect(WeatherReport.degrees(-0.2) == "0°")
    }
}

struct WeatherScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func retriesBackOffUpToTheRefreshInterval() {
        #expect(WeatherSchedule.retryDelay(failures: 1) == 60)
        #expect(WeatherSchedule.retryDelay(failures: 2) == 120)
        #expect(WeatherSchedule.retryDelay(failures: 3) == 240)
        #expect(WeatherSchedule.retryDelay(failures: 6) == 1800)
        #expect(WeatherSchedule.retryDelay(failures: 500) == 1800)
        #expect(WeatherSchedule.retryDelay(failures: 0) == WeatherSchedule.refreshInterval)
    }

    @Test func wakeRefetchesOnlyWhenStaleOrFailing() {
        #expect(!WeatherSchedule.shouldRefreshOnWake(lastSuccess: now.addingTimeInterval(-600), failures: 0, now: now))
        #expect(WeatherSchedule.shouldRefreshOnWake(lastSuccess: now.addingTimeInterval(-1800), failures: 0, now: now))
        #expect(WeatherSchedule.shouldRefreshOnWake(lastSuccess: now.addingTimeInterval(-60), failures: 2, now: now))
        #expect(WeatherSchedule.shouldRefreshOnWake(lastSuccess: nil, failures: 0, now: now))
    }

    @Test func staleReadingsAreDropped() {
        #expect(!WeatherSchedule.isStale(lastSuccess: now.addingTimeInterval(-3600), now: now))
        #expect(WeatherSchedule.isStale(lastSuccess: now.addingTimeInterval(-3 * 3600), now: now))
        #expect(WeatherSchedule.isStale(lastSuccess: nil, now: now))
    }

    @Test func attemptsKeepAMinimumGap() {
        #expect(WeatherSchedule.delayToRespectGap(lastAttempt: nil, now: now) == 0)
        #expect(WeatherSchedule.delayToRespectGap(lastAttempt: now.addingTimeInterval(-20), now: now) == 40)
        #expect(WeatherSchedule.delayToRespectGap(lastAttempt: now.addingTimeInterval(-120), now: now) == 0)
    }
}
