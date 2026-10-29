import Foundation

/// Inline unit conversion: `5 km to mi`, `72f in c`, `2.5 kg to lb`.
nonisolated enum UnitConverter {
    struct Result: Equatable {
        let value: Double
        let symbol: String
    }

    private static let units: [String: Dimension] = [
        // Length
        "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters,
        "km": UnitLength.kilometers, "in": UnitLength.inches, "ft": UnitLength.feet,
        "yd": UnitLength.yards, "mi": UnitLength.miles, "nmi": UnitLength.nauticalMiles,
        // Mass
        "mg": UnitMass.milligrams, "g": UnitMass.grams, "kg": UnitMass.kilograms,
        "oz": UnitMass.ounces, "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "st": UnitMass.stones,
        // Temperature
        "c": UnitTemperature.celsius, "°c": UnitTemperature.celsius,
        "f": UnitTemperature.fahrenheit, "°f": UnitTemperature.fahrenheit, "k": UnitTemperature.kelvin,
        // Volume
        "ml": UnitVolume.milliliters, "l": UnitVolume.liters, "gal": UnitVolume.gallons,
        "floz": UnitVolume.fluidOunces, "cup": UnitVolume.cups, "cups": UnitVolume.cups,
        // Speed
        "kph": UnitSpeed.kilometersPerHour, "km/h": UnitSpeed.kilometersPerHour, "kmh": UnitSpeed.kilometersPerHour,
        "mph": UnitSpeed.milesPerHour, "m/s": UnitSpeed.metersPerSecond, "kn": UnitSpeed.knots,
        // Data
        "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes,
        "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
    ]

    static func convert(_ query: String) -> Result? {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard let separator = text.range(of: " to ") ?? text.range(of: " in ") else { return nil }

        let source = text[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let targetKey = text[separator.upperBound...].trimmingCharacters(in: .whitespaces)

        let numberEnd = source.firstIndex { !($0.isNumber || $0 == "." || $0 == "-") } ?? source.endIndex
        guard let value = Double(source[..<numberEnd]),
              let from = units[source[numberEnd...].trimmingCharacters(in: .whitespaces)],
              let to = units[targetKey],
              type(of: from) == type(of: to)
        else { return nil }

        let converted = Measurement(value: value, unit: from).converted(to: to)
        return Result(value: converted.value, symbol: to.symbol)
    }
}
