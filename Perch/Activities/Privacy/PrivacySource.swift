import AppKit
import CoreAudio
import CoreMediaIO
import SwiftUI

/// Camera and microphone chips while any app uses them, from CoreMediaIO / CoreAudio
/// "is running somewhere" properties; neither needs a permission. Which app holds the sensor is not
/// exposed by either API, so the chip names only the sensor. Screen recording has no public signal.
final class PrivacySource: ActivitySource {
    static let id = "privacy"
    static let info = ActivitySourceInfo(
        title: "Camera & Microphone",
        detail: "A green or orange dot beside the notch while any app uses the camera or microphone.",
        symbol: "video.fill",
        tint: .green,
        permission: nil
    )

    private weak var center: ActivityCenter?
    private let cameraID = UUID()
    private let microphoneID = UUID()
    private var cameraListeners: [(CMIOObjectID, CMIOObjectPropertyListenerBlock)] = []
    private var microphoneListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var cameraListListener: CMIOObjectPropertyListenerBlock?
    private var audioListListener: AudioObjectPropertyListenerBlock?

    private static var cameraRunningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
    )
    private static var cameraListAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    private static var micRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var audioListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start(center: ActivityCenter) {
        self.center = center
        let cameraList: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.attachCameras() }
        }
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &Self.cameraListAddress, .main, cameraList)
        cameraListListener = cameraList
        let audioList: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachMicrophones() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.audioListAddress, .main, audioList)
        audioListListener = audioList
        attachCameras()
        attachMicrophones()
    }

    func stop() {
        detachCameras()
        detachMicrophones()
        if let cameraListListener {
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &Self.cameraListAddress, .main, cameraListListener)
        }
        if let audioListListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.audioListAddress, .main, audioListListener)
        }
        cameraListListener = nil
        audioListListener = nil
        center?.dismiss(cameraID)
        center?.dismiss(microphoneID)
    }

    // MARK: Camera

    private func attachCameras() {
        detachCameras()
        for device in Self.cameraDevices() {
            let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshCamera() }
            }
            CMIOObjectAddPropertyListenerBlock(device, &Self.cameraRunningAddress, .main, listener)
            cameraListeners.append((device, listener))
        }
        refreshCamera()
    }

    private func detachCameras() {
        for (device, listener) in cameraListeners {
            CMIOObjectRemovePropertyListenerBlock(device, &Self.cameraRunningAddress, .main, listener)
        }
        cameraListeners.removeAll()
    }

    private func refreshCamera() {
        let running = cameraListeners.contains { Self.isCameraRunning($0.0) }
        set(.camera, id: cameraID, active: running)
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var size = UInt32(0)
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &cameraListAddress, 0, nil, &size) == 0,
              size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used = UInt32(0)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &cameraListAddress, 0, nil, size, &used, &devices) == 0
        else { return [] }
        return devices
    }

    private static func isCameraRunning(_ device: CMIOObjectID) -> Bool {
        var running = UInt32(0)
        var used = UInt32(0)
        let status = CMIOObjectGetPropertyData(device, &cameraRunningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
        return status == 0 && running != 0
    }

    // MARK: Microphone

    private func attachMicrophones() {
        detachMicrophones()
        for device in Self.inputDevices() {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshMicrophone() }
            }
            AudioObjectAddPropertyListenerBlock(device, &Self.micRunningAddress, .main, listener)
            microphoneListeners.append((device, listener))
        }
        refreshMicrophone()
    }

    private func detachMicrophones() {
        for (device, listener) in microphoneListeners {
            AudioObjectRemovePropertyListenerBlock(device, &Self.micRunningAddress, .main, listener)
        }
        microphoneListeners.removeAll()
    }

    private func refreshMicrophone() {
        let running = microphoneListeners.contains { device, _ in
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &Self.micRunningAddress, 0, nil, &size, &running) == noErr && running != 0
        }
        set(.microphone, id: microphoneID, active: running)
    }

    /// Devices with at least one input stream.
    private static func inputDevices() -> [AudioObjectID] {
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &audioListAddress, 0, nil, &size) == noErr
        else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &audioListAddress, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices.filter { device in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize = UInt32(0)
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    // MARK: Activity

    private func set(_ sensor: Activity.PrivacySensor, id: UUID, active: Bool) {
        guard let center else { return }
        let showing = center.items.contains { $0.id == id }
        if !active {
            if showing { center.dismiss(id) }
            return
        }
        guard !showing else { return }
        center.show(Activity(
            id: id,
            kind: .privacy(sensor),
            symbol: sensor == .camera ? "video.fill" : "mic.fill",
            title: sensor == .camera ? "Camera" : "Microphone",
            detail: "In use",
            status: .running,
            progress: .indeterminate,
            updatedAt: Date()
        ))
    }
}
