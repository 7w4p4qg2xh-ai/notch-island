//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

enum BoringNotchAppBundleNames {
    static let legacy = "boringNotch.app"
    static let current = "Notch Island.app"
}

@objc protocol BoringNotchXPCHelperLunarListener {
    func lunarEventDidUpdate(_ event: BNLunarBrightnessEvent)
    func lunarStreamDidStop(_ reason: String?)
}

@objc(BNLunarBrightnessEvent)
final class BNLunarBrightnessEvent: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let brightness: Double
    let display: Int

    init(brightness: Double, display: Int) {
        self.brightness = brightness
        self.display = display
        super.init()
    }

    required init?(coder: NSCoder) {
        brightness = coder.decodeDouble(forKey: "brightness")
        display = coder.decodeInteger(forKey: "display")
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(brightness, forKey: "brightness")
        coder.encode(display, forKey: "display")
    }
}

@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func migrateLegacyAppBundle(from sourcePath: String, to destinationPath: String, with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    func displayIDForBrightness(with reply: @escaping (NSNumber?) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    func adjustScreenBrightness(by value: Float, with reply: @escaping (NSNumber?) -> Void)
    /// Adjust brightness on a specific display by a normalized delta (0...1).
    /// Built-in displays use DisplayServices/IOKit; external displays use DDC (`m1ddc`).
    /// Returns the resulting normalized brightness, or nil on failure.
    func adjustBrightness(displayID: NSNumber, delta: Float, with reply: @escaping (NSNumber?) -> Void)
    func isLunarAvailable(with reply: @escaping (Bool) -> Void)
    func startLunarEventStream(with reply: @escaping (Bool) -> Void)
    func stopLunarEventStream()
    func setLunarOSDHidden(_ hide: Bool, with reply: @escaping (Bool) -> Void)
    func startNotificationWatching(with reply: @escaping (Bool) -> Void)
    func stopNotificationWatching()
    func setNotificationFilter(_ bundleIDs: [String], allApps: Bool)
    func performNotificationAction(_ token: String, actionTitle: String, with reply: @escaping (Bool) -> Void)
    func clearNotificationBanner(_ token: String, with reply: @escaping (Bool) -> Void)
    func revealNotification(_ token: String, with reply: @escaping (Bool) -> Void)
    func setNotificationPassthrough(_ enabled: Bool)
    /// Told by the app while the Siri panel is open.
    ///
    /// 🔴 The Siri panel (`com.apple.SiriNCService`) is positioned relative to
    /// the NotificationCenter host window, so parking that host off-screen
    /// drags the panel off-screen too — clicking the menu-bar Siri icon then
    /// shows nothing at all. While Siri is up the host has to stay put, so the
    /// helper gives every parked window back and stops parking.
    ///
    /// The *detection* has to live in the app: `CGWindowListCopyWindowInfo`
    /// returns nil inside this sandboxed helper (measured 2026-11-22), while
    /// the same call works in the app.
    func setSiriYield(_ yielding: Bool)
}

@objc protocol BoringNotchXPCHelperDelegate {
    func notificationDidAppear(_ payload: [String: String])
}

@objc protocol BoringNotchXPCAppDelegate: BoringNotchXPCHelperLunarListener, BoringNotchXPCHelperDelegate {}
