import Foundation

/// A connected Bluetooth device and the charge of each of its parts.
nonisolated struct DeviceBattery: Equatable, Identifiable {
    struct Component: Equatable {
        enum Part: Equatable {
            /// One battery: a keyboard, a mouse, or AirPods' combined figure.
            case main
            case left, right, `case`

            var label: String? {
                switch self {
                case .main: nil
                case .left: "L"
                case .right: "R"
                case .case: "Case"
                }
            }
        }

        let part: Part
        let percent: Int
    }

    /// Normalised Bluetooth address, `aa-bb-cc-dd-ee-ff`.
    let address: String
    let name: String
    let symbol: String
    let components: [Component]

    var id: String { address }

    /// Lowest charge among the parts in use (the case is not worn, so it only counts alone).
    var level: Double? {
        let worn = components.filter { $0.part != .case }
        return (worn.isEmpty ? components : worn).map(\.percent).min().map { Double($0) / 100 }
    }

    /// "L 80% · R 75% · Case 50%", or "64%".
    var summary: String {
        components
            .map { component in component.part.label.map { "\($0) \(component.percent)%" } ?? "\(component.percent)%" }
            .joined(separator: " · ")
    }

    // MARK: Parsing

    /// Reads battery keys from an IORegistry entry or from IOBluetoothDevice's battery properties
    /// mapped to the same names. AirPods report left/right/case; HID devices (Magic Keyboard, Mouse,
    /// Trackpad) report a single `BatteryPercent`. Zero means "not reported" and is skipped.
    static func components(from properties: [String: Any]) -> [Component] {
        func percent(_ key: String) -> Int? {
            guard let value = (properties[key] as? NSNumber)?.intValue, (1...100).contains(value) else { return nil }
            return value
        }
        let parts: [Component] = [
            percent("BatteryPercentLeft").map { Component(part: .left, percent: $0) },
            percent("BatteryPercentRight").map { Component(part: .right, percent: $0) },
            percent("BatteryPercentCase").map { Component(part: .case, percent: $0) },
        ].compactMap { $0 }
        if !parts.isEmpty { return parts }
        let single = percent("BatteryPercentCombined") ?? percent("BatteryPercentSingle") ?? percent("BatteryPercent")
        return single.map { [Component(part: .main, percent: $0)] } ?? []
    }

    /// `C0:44:42:DA:AD:0A`, `c0-44-42-da-ad-0a` → `c0-44-42-da-ad-0a`.
    static func normalize(address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    /// SF Symbol from the device name, then its Bluetooth major class (0x04 audio, 0x05 peripheral).
    static func symbol(name: String, majorClass: UInt32) -> String {
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if name.contains("mouse") { return "magicmouse.fill" }
        switch majorClass {
        case 0x04: return "headphones"
        case 0x05: return "keyboard"
        default: return "battery.75percent"
        }
    }
}
