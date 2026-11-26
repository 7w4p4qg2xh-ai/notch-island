//
//  AudioOutputRouteResolver.swift
//  boringNotch
//
//  Shared output-route to icon mapping used by all OSD/HUD surfaces.
//

import CoreAudio
import CoreGraphics
import Foundation

enum AudioOutputRouteKind: Equatable {
    case builtInSpeaker
    case wiredHeadphones
    case airPods
    case airPodsPro
    case airPodsMax
    case bluetoothHeadphones
    case externalSpeaker
    case unknown
}

final class AudioOutputRouteResolver {
    static let shared = AudioOutputRouteResolver()

    private let stateQueue = DispatchQueue(label: "AudioOutputRouteResolver.state")
    private var cachedRouteKind: AudioOutputRouteKind = .unknown

    /// Symbol for the current output route, independent of volume level —
    /// for the media-output button, which shows *where* audio is going
    /// rather than how loud it is. Built-in output reads as the machine
    /// itself (a laptop), matching how macOS's own output picker shows it.
    func outputRouteSymbol() -> String {
        let routeKind = stateQueue.sync { cachedRouteKind }
        switch routeKind {
        case .airPods: return "airpods"
        case .airPodsPro: return "airpodspro"
        case .airPodsMax: return "airpodsmax"
        case .wiredHeadphones, .bluetoothHeadphones: return "headphones"
        case .externalSpeaker: return "hifispeaker"
        case .builtInSpeaker, .unknown: return "macbook"
        }
    }

    /// 当前默认输出是不是耳机类（AirPods / 头戴 / 有线耳机）。
    /// 音量 HUD 用它决定是否按蓝牙 Product ID 细分机型图标：
    /// 只有输出确实落在耳机上时才细分，扬声器场景必须保持扬声器图标，
    /// 不能因为「连着耳机但没在用」就误显示耳机。
    var currentRouteIsHeadphones: Bool {
        switch stateQueue.sync { cachedRouteKind } {
        case .airPods, .airPodsPro, .airPodsMax, .wiredHeadphones, .bluetoothHeadphones:
            return true
        case .builtInSpeaker, .externalSpeaker, .unknown:
            return false
        }
    }

    /// 音量 HUD 图标（须在 MainActor 调用）：输出落在耳机上时，改用蓝牙
    /// Product ID 识别的具体机型图标。用户的 AirPods 改过名（AP5），
    /// CoreAudio 设备名认不出机型，只有 PeripheralBatteryManager 的
    /// Product ID 表可靠。没有耳机数据 / 输出是扬声器时回落到原逻辑。
    @MainActor
    func volumeSymbolForCurrentOutput(value: CGFloat) -> String {
        let base = volumeSymbol(for: value)
        guard currentRouteIsHeadphones,
              let headphoneIcon = PeripheralBatteryManager.shared.currentHeadphoneIcon()
        else { return base }
        return headphoneIcon
    }

    /// 11-17: current default output device name. Used by the headphone
    /// connection detector to recognise a route switch to an ALREADY-known
    /// device (e.g. app relaunched with AP5 in its baseline, then the user
    /// reconnects / confirms the system bubble — CoreAudio fires but the
    /// name-diff sees no "new" device, so no card would show).
    func currentOutputDeviceName() -> String {
        let id = systemOutputDeviceID()
        guard id != kAudioObjectUnknown else { return "" }
        return readStringProperty(deviceID: id, selector: kAudioObjectPropertyName)
    }

    func volumeSymbol(for value: CGFloat) -> String {
        let clampedValue = max(0, min(1, value))
        let routeKind = stateQueue.sync { cachedRouteKind }

        switch routeKind {
        case .airPods:
            return "airpods"
        case .airPodsPro:
            return "airpodspro"
        case .airPodsMax:
            return "airpodsmax"
        case .wiredHeadphones, .bluetoothHeadphones:
            return "headphones"
        case .builtInSpeaker, .externalSpeaker, .unknown:
            return speakerSymbol(for: clampedValue)
        }
    }

    private init() {
        refreshCachedRouteKind()
        setupAudioRouteListener()
    }

    private func setupAudioRouteListener() {
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            nil
        ) { [weak self] _, _ in
            self?.refreshCachedRouteKind()
        }
    }

    private func refreshCachedRouteKind() {
        let currentRoute = currentRouteKind()
        stateQueue.sync {
            self.cachedRouteKind = currentRoute
        }
    }

    private func currentRouteKind() -> AudioOutputRouteKind {
        let deviceID = systemOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return .unknown }

        let deviceName = readStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName)
        let manufacturer = readStringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyManufacturer
        )
        let transportType = readTransportType(deviceID: deviceID)

        return classifyOutputRoute(
            deviceName: deviceName,
            manufacturer: manufacturer,
            transportType: transportType
        )
    }

    private func systemOutputDeviceID() -> AudioObjectID {
        var defaultDeviceID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )
        return status == noErr ? defaultDeviceID : kAudioObjectUnknown
    }

    private func classifyOutputRoute(
        deviceName: String,
        manufacturer _: String,
        transportType: UInt32?
    ) -> AudioOutputRouteKind {
        let normalizedName = deviceName.lowercased()

        if normalizedName.contains("airpods max") {
            return .airPodsMax
        }
        if normalizedName.contains("airpods pro") {
            return .airPodsPro
        }
        if normalizedName.contains("airpods") {
            return .airPods
        }

        let isHeadphonesLike = normalizedName.contains("headphone")
            || normalizedName.contains("headset")
            || normalizedName.contains("earbud")
            || normalizedName.contains("earphone")
            || normalizedName.contains("pods")

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return isHeadphonesLike ? .wiredHeadphones : .builtInSpeaker
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothHeadphones
        case kAudioDeviceTransportTypeUSB:
            return .wiredHeadphones
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .externalSpeaker
        default:
            if isHeadphonesLike {
                return .wiredHeadphones
            }
            if normalizedName.contains("speaker") || normalizedName.contains("display") {
                return .externalSpeaker
            }
            return .unknown
        }
    }

    private func readTransportType(deviceID: AudioObjectID) -> UInt32? {
        var transportType: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &transportType
        )

        return status == noErr ? transportType : nil
    }

    private func readStringProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var propertySize: UInt32 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &value) == noErr
        else {
            return ""
        }

        return value?.takeUnretainedValue() as String? ?? ""
    }

    private func speakerSymbol(for value: CGFloat) -> String {
        switch value {
        case 0:
            return "speaker.slash.fill"
        case 0...0.33:
            return "speaker.wave.1.fill"
        case 0.33...0.66:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }
}
