//
//  MediaKeyInterceptor.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-23.

import Foundation
import AppKit
import ApplicationServices
import Defaults
import AVFoundation

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()

    private enum NXKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case keyboardBrightnessUp = 21
        case keyboardBrightnessDown = 22
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let step: Float = 1.0 / 16.0
    private var audioPlayer: AVAudioPlayer?

    private init() {}

    private var isTapActive: Bool {
        eventTap != nil && runLoopSource != nil
    }

    // MARK: - Accessibility (via XPC)

    func requestAccessibilityAuthorization() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
    }

    func ensureAccessibilityAuthorization(promptIfNeeded: Bool = false) async -> Bool {
        await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: promptIfNeeded)
    }

    // MARK: - Event Tap

    func start(promptIfNeeded: Bool = false) async {
        osdTrace("start() osdReplacement=\(Defaults[.osdReplacement]) brightness=\(Defaults[.osdBrightnessSource].rawValue) volume=\(Defaults[.osdVolumeSource].rawValue)")

        // Ensure OSD replacement is enabled
        guard Defaults[.osdReplacement] else {
            osdTrace("skip: osdReplacement=false")
            stop()
            return
        }

        // Only require Accessibility if any selected source uses the built-in controls
        let needsAccessibility = Defaults[.osdBrightnessSource] == .builtin || Defaults[.osdVolumeSource] == .builtin
        if needsAccessibility {
            let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
            osdTrace("accessibility authorized=\(authorized) promptIfNeeded=\(promptIfNeeded)")
            if !authorized {
                if promptIfNeeded {
                    let granted = await ensureAccessibilityAuthorization(promptIfNeeded: true)
                    osdTrace("accessibility after prompt=\(granted)")
                    guard granted else { return }
                } else {
                    return
                }
            }
        }

        if let eventTap, isTapActive {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }

        if eventTap != nil || runLoopSource != nil {
            stop()
        }

        // macOS 27（本机 27.3 / 26C5035r，23:26 实测）把亮度键从 NX_SYSDEFINED
        // 挪走了：按 F1/F2 时 `.cgSessionEventTap` 一条都收不到，只有最上游的
        // `.cghidEventTap` 能看到它以 keyDown keyCode 144（+）/145（-）出现。
        // 会话层能看到音量（keyCode 0/1/7，仍是 NX_SYSDEFINED），亮度完全不行。
        // 所以 tap 放 HID 层；HID 层建不起来时回落会话层，至少保住音量。
        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tapCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passRetained(cgEvent) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                guard AXIsProcessTrusted() else {
                    DispatchQueue.main.async {
                        interceptor.stop()
                    }
                    return nil
                }
                interceptor.reenableEventTap(after: type)
                return nil
            }

            return interceptor.handleEvent(cgEvent)
        }

        let tapUserInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var tapPoint = "hid"
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: tapUserInfo
        )
        if eventTap == nil {
            tapPoint = "session"
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: tapUserInfo
            )
        }

        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            osdTrace("tap created OK point=\(tapPoint)")
        } else {
            osdTrace("tap create FAILED")
            Log.osd.error("⚠️ [MediaKeyInterceptor] Failed to create media-key event tap")
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        runLoopSource = nil
        eventTap = nil
    }

    private func reenableEventTap(after type: CGEventType) {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)

        let reason: String
        switch type {
        case .tapDisabledByTimeout:
            reason = "timeout"
        case .tapDisabledByUserInput:
            reason = "user input"
        default:
            reason = "unknown reason"
        }

        Log.osd.debug("ℹ️ [MediaKeyInterceptor] Re-enabled media-key event tap after \(reason)")
    }

    // MARK: - Event Handling

    private func handleEvent(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // Ensure the CGEvent has a valid type before converting to NSEvent
        guard cgEvent.type != .null else {
            return Unmanaged.passUnretained(cgEvent)
        }

        // macOS 27：亮度键不再发 NX_SYSDEFINED，只在 HID 层以普通 keyDown
        // 出现（144 = 亮度+，145 = 亮度-）。必须在这里吞掉，系统原生亮度条
        // 才不会抢在我们前面弹出来。非内建亮度源（BetterDisplay/Lunar）放行。
        if cgEvent.type == .keyDown || cgEvent.type == .keyUp {
            let hidKeyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
            guard hidKeyCode == 144 || hidKeyCode == 145 else {
                return Unmanaged.passUnretained(cgEvent)
            }
            let brightnessSource = Defaults[.osdBrightnessSource]
            guard brightnessSource == .builtin else {
                osdTrace("hid brightness passthrough source=\(brightnessSource.rawValue)")
                return Unmanaged.passUnretained(cgEvent)
            }
            if cgEvent.type == .keyDown {
                let flags = cgEvent.flags
                let option = flags.contains(.maskAlternate)
                let shift = flags.contains(.maskShift)
                let command = flags.contains(.maskCommand)
                let stepDivisor: Float = (option && shift) ? 4.0 : 1.0
                // 144 = 亮度+（F2），145 = 亮度-（F1）。反向会变成按亮变暗。
                let delta = (hidKeyCode == 144 ? step : -step) / stepDivisor
                let keyType: NXKeyType = hidKeyCode == 144 ? .brightnessUp : .brightnessDown
                osdTrace("hid brightness keyCode=\(hidKeyCode) delta=\(delta) option=\(option) shift=\(shift) command=\(command)")
                if option && !shift {
                    Task { @MainActor in
                        _ = self.handleOptionAction(for: keyType, command: command)
                    }
                } else if command {
                    // ⌘ + 亮度键 = 键盘背光，与旧的 NX_SYSDEFINED 路径一致
                    // （handleKeyPress 里 `.brightnessUp` 的 keyboard 判据也是 command）。
                    Task { @MainActor in
                        KeyboardBacklightManager.shared.setRelative(delta: delta)
                    }
                } else {
                    Task { @MainActor in
                        BrightnessManager.shared.setRelative(delta: delta)
                    }
                }
            }
            return nil
        }

        guard let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let stateByte = ((data1 & 0xFF00) >> 8)
        osdTrace("event keyCode=\(keyCode) state=\(String(format: "%02X", stateByte))")

        // 0xA = key down, 0xB = key up. Only handle key down.
        guard stateByte == 0xA,
              let keyType = NXKeyType(rawValue: keyCode) else {
            osdTrace("passthrough: not keyDown / unknown keyCode")
            return Unmanaged.passUnretained(cgEvent)
        }

        // Determine which source is selected for this control (brightness/volume/keyboard)
        let selectedSource: OSDControlSource = {
            switch keyType {
            case .soundUp, .soundDown, .mute:
                return Defaults[.osdVolumeSource]
            case .brightnessUp, .brightnessDown:
                return Defaults[.osdBrightnessSource]
            case .keyboardBrightnessUp, .keyboardBrightnessDown:
                return .builtin
            }
        }()

        let flags = nsEvent.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)

        // If an external source is selected and available, allow the event to pass through (external app will emit OSD notifications)
        switch selectedSource {
        case .betterDisplay:
            if BetterDisplayManager.shared.isBetterDisplayAvailable {
                if (keyType == .brightnessUp || keyType == .brightnessDown) && command {
                    break
                }
                osdTrace("passthrough: source=BetterDisplay")
                return Unmanaged.passUnretained(cgEvent)
            }
        case .lunar:
            if LunarManager.shared.isLunarAvailable {
                if (keyType == .brightnessUp || keyType == .brightnessDown) && command {
                    break
                }
                osdTrace("passthrough: source=Lunar")
                return Unmanaged.passUnretained(cgEvent)
            }
        case .builtin:
            break
        }

        // Handle option key action (without shift)
        if option && !shift {
            if handleOptionAction(for: keyType, command: command) {
                return nil
            }
        }

        // Handle normal key press
        osdTrace("consumed keyCode=\(keyCode) type=\(keyType) source=\(selectedSource.rawValue) option=\(option) shift=\(shift) command=\(command)")
        handleKeyPress(keyType: keyType, option: option, shift: shift, command: command)
        return nil
    }

    private func handleOptionAction(for keyType: NXKeyType, command: Bool) -> Bool {
        let action = Defaults[.optionKeyAction]

        switch action {
        case .openSettings:
            openSystemSettings(for: keyType, command: command)
            return true
        case .showOSD:
            showOSD(for: keyType, command: command)
            return true
        case .none:
            return true
        }
    }

    private func prepareAudioPlayerIfNeeded() {
        guard audioPlayer == nil else { return }

        let defaultPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        if FileManager.default.fileExists(atPath: defaultPath) {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: defaultPath))
                Log.osd.debug("🔊 [MediaKeyInterceptor] Loaded default Bezel audio from: \(defaultPath)")
            } catch {
                Log.osd.error("⚠️ [MediaKeyInterceptor] Failed to init AVAudioPlayer with default path \(defaultPath): \(error.localizedDescription)")
            }
        } else {
            Log.osd.error("⚠️ [MediaKeyInterceptor] Default bezel audio not found at: \(defaultPath)")
        }

        if let player = audioPlayer {
            player.volume = 1.0
            player.numberOfLoops = 0
            player.prepareToPlay()
        }
    }

    private func playFeedbackSound() {
        // Single-key lookup — persistentDomain(forName:) materialized the
        // entire NSGlobalDomain on every volume key press.
        let feedback = CFPreferencesCopyAppValue(
            "com.apple.sound.beep.feedback" as CFString,
            kCFPreferencesAnyApplication
        ) as? Int
        guard feedback == 1 else { return }

        prepareAudioPlayerIfNeeded()
        guard let player = audioPlayer else {
            Log.osd.error("⚠️ [MediaKeyInterceptor] No audio player available to play feedback sound")
            return
        }
        if let url = player.url {
            Log.osd.debug("🔊 [MediaKeyInterceptor] Playing feedback sound from: \(url.path)")
        } else {
            Log.osd.debug("🔊 [MediaKeyInterceptor] Playing feedback sound (no url available for AVAudioPlayer)")
        }
        if player.isPlaying {
            player.stop()
            player.currentTime = 0
        }
        player.play()
    }

    private func handleKeyPress(keyType: NXKeyType, option: Bool, shift: Bool, command: Bool) {
        let stepDivisor: Float = (option && shift) ? 4.0 : 1.0

        switch keyType {
        case .soundUp:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.increase(stepDivisor: stepDivisor)
            }
        case .soundDown:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.decrease(stepDivisor: stepDivisor)
            }
        case .mute:
            Task { @MainActor in
                VolumeManager.shared.toggleMuteAction()
            }
        case .brightnessUp, .keyboardBrightnessUp:
            let delta = step / stepDivisor
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessUp || command)
        case .brightnessDown, .keyboardBrightnessDown:
            let delta = -(step / stepDivisor)
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessDown || command)
        }
    }

    private func adjustBrightness(delta: Float, keyboard: Bool) {
        Task { @MainActor in
            if keyboard {
                KeyboardBacklightManager.shared.setRelative(delta: delta)
            } else {
                BrightnessManager.shared.setRelative(delta: delta)
            }
        }
    }

    private func showOSD(for keyType: NXKeyType, command: Bool) {
        Task { @MainActor in
            switch keyType {
            case .soundUp, .soundDown, .mute:
                let v = VolumeManager.shared.rawVolume
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(v))
            case .brightnessUp, .brightnessDown:
                if command {
                    let v = KeyboardBacklightManager.shared.rawBrightness
                    BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
                } else {
                    let v = BrightnessManager.shared.rawBrightness
                    let target = await BrightnessManager.shared.brightnessTargetUUID()
                    BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(v), targetScreenUUID: target)
                }
            case .keyboardBrightnessUp, .keyboardBrightnessDown:
                let v = KeyboardBacklightManager.shared.rawBrightness
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
            }
        }
    }

    private func openSystemSettings(for keyType: NXKeyType, command: Bool) {
        let urlString: String

        switch keyType {
        case .soundUp, .soundDown, .mute:
            urlString = "x-apple.systempreferences:com.apple.preference.sound"
        case .brightnessUp, .brightnessDown:
            if command {
                urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
            } else {
                urlString = "x-apple.systempreferences:com.apple.preference.displays"
            }
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
        }

        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 媒体键链路取证（11-15 23:20）

/// 沙箱里 `log show` 直接报 `Cannot run while sandboxed`，os_log 拿不到，
/// 所以媒体键这条链路单独落一个文件：`~/bn-osd.log`。
/// 每次按键写 2~3 行，超过 256KB 自动清空重写，不会无限长。
fileprivate func osdTrace(_ message: String) {
    let path = NSHomeDirectory() + "/bn-osd.log"
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }

    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: path),
       let size = attrs[.size] as? Int, size > 262_144 {
        try? data.write(to: URL(fileURLWithPath: path))
        return
    }

    if let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
