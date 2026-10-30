import CoreBluetooth
import IOBluetooth
import IOKit
import SwiftUI

/// A 4 s battery card when a Bluetooth device connects. AirPods report per-part charge through
/// IOBluetoothDevice's (private) battery properties; Magic Keyboard/Mouse/Trackpad report through
/// the `AppleDeviceManagementHIDEventService` IORegistry entry instead, so both are read.
final class BluetoothBatterySource: NSObject, ActivitySource, CBCentralManagerDelegate {
    static let id = "deviceBattery"
    static let info = ActivitySourceInfo(
        title: "Bluetooth Battery",
        detail: "AirPods, keyboard and mouse charge when they connect.",
        symbol: "airpods",
        tint: .green,
        permission: .bluetooth
    )

    static let duration: Duration = .seconds(4)
    /// AirPods publish their charge a moment after the connection itself.
    private static let readDelay: TimeInterval = 2
    /// Connect notifications also fire for devices already connected at registration; those stay quiet.
    private static let startupGrace: TimeInterval = 1.5

    /// IOBluetoothDevice selectors (UInt8 percent) mapped to the IORegistry key names the parser reads.
    private static let deviceKeys = [
        "batteryPercentLeft": "BatteryPercentLeft",
        "batteryPercentRight": "BatteryPercentRight",
        "batteryPercentCase": "BatteryPercentCase",
        "batteryPercentCombined": "BatteryPercentCombined",
        "batteryPercentSingle": "BatteryPercentSingle",
    ]

    private weak var center: ActivityCenter?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var connected: [String: IOBluetoothDevice] = [:]
    private var startedAt = Date.distantPast
    /// Asks for Bluetooth access; its state callback starts monitoring once granted.
    private var authorization: CBCentralManager?

    func start(center: ActivityCenter) {
        self.center = center
        switch CBManager.authorization {
        case .allowedAlways:
            beginMonitoring()
        case .notDetermined:
            authorization = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        default:
            break // denied: Settings shows the "Open System Settings" row
        }
    }

    func stop() {
        authorization = nil
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        connected.removeAll()
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard authorization != nil, CBManager.authorization == .allowedAlways else { return }
            authorization = nil
            beginMonitoring()
        }
    }

    private func beginMonitoring() {
        guard connectNotification == nil else { return }
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let rawAddress = device.addressString else { return }
        let address = DeviceBattery.normalize(address: rawAddress)
        connected[address] = device
        disconnectNotifications[address] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        guard Date().timeIntervalSince(startedAt) > Self.startupGrace else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readDelay) { [weak self] in
            self?.announce(address)
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let rawAddress = device.addressString else { return }
        let address = DeviceBattery.normalize(address: rawAddress)
        notification.unregister()
        disconnectNotifications.removeValue(forKey: address)
        connected.removeValue(forKey: address)
    }

    /// Flashes the device that just connected, with every other connected device listed after it.
    private func announce(_ address: String) {
        let hidBatteries = Self.hidBatteries()
        let batteries = connected.compactMap { address, device in battery(for: device, address: address, hid: hidBatteries) }
            .sorted { $0.address == address ? true : $1.address == address ? false : $0.name < $1.name }
        guard let device = batteries.first, device.address == address, let level = device.level else { return }
        var activity = Activity(
            id: UUID(),
            kind: .deviceBattery(address: address),
            symbol: device.symbol,
            title: device.name,
            detail: device.summary,
            status: .running,
            progress: .level(level),
            updatedAt: Date(),
            presentation: .transient(Self.duration)
        )
        activity.batteries = batteries
        center?.flash(activity)
    }

    private func battery(for device: IOBluetoothDevice, address: String, hid: [String: [String: Any]]) -> DeviceBattery? {
        var properties = hid[address] ?? [:]
        for (selector, key) in Self.deviceKeys where device.responds(to: NSSelectorFromString(selector)) {
            if let value = device.value(forKey: selector) { properties[key] = value }
        }
        let components = DeviceBattery.components(from: properties)
        guard !components.isEmpty else { return nil }
        let name = device.name ?? "Bluetooth device"
        return DeviceBattery(
            address: address,
            name: name,
            symbol: DeviceBattery.symbol(name: name, majorClass: device.deviceClassMajor),
            components: components
        )
    }

    /// IORegistry properties of every Apple HID accessory, keyed by normalised Bluetooth address.
    private static func hidBatteries() -> [String: [String: Any]] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator)
            == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: [String: Any]] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any],
               let address = dictionary["DeviceAddress"] as? String {
                result[DeviceBattery.normalize(address: address)] = dictionary
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }
}
