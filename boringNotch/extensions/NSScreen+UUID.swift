//
//  NSScreen+UUID.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-21.
//

import AppKit
import CoreGraphics

extension NSScreen {
    /// Returns a persistent UUID for this display
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        let uuidString = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
        return uuidString
    }

    var cgDisplayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// Find a screen by its UUID
    @MainActor static func screen(withUUID uuid: String) -> NSScreen? {
        return NSScreenUUIDCache.shared.screen(forUUID: uuid)
    }

    /// Get UUID to NSScreen mapping for all screens
    @MainActor static var screensByUUID: [String: NSScreen] {
        return NSScreenUUIDCache.shared.allScreens
    }

    /// The display that owns the menu bar — i.e. the one the user calls "my main
    /// screen". This is NOT `NSScreen.main`, which despite the name means "the
    /// screen containing the key window" and therefore follows keyboard focus.
    ///
    /// `NSScreen.screens[0]` is documented as the menu-bar screen, but array
    /// order is not reliable through some docks / mirroring setups, so match
    /// `CGMainDisplayID()` exactly first and only then fall back to index 0.
    @MainActor static var menuBarScreen: NSScreen? {
        let mainID = CGMainDisplayID()
        if let exact = NSScreen.screens.first(where: { $0.cgDisplayID == mainID }) {
            return exact
        }
        return NSScreen.screens.first
    }

    /// True when this screen is the one carrying the menu bar.
    @MainActor var isMenuBarScreen: Bool {
        guard let id = cgDisplayID else { return false }
        return id == CGMainDisplayID()
    }
}

/// Cache for UUID to NSScreen mappings to avoid repeated lookups
@MainActor
final class NSScreenUUIDCache {
    static let shared = NSScreenUUIDCache()

    private var cache: [String: NSScreen] = [:]
    private var observer: Any?

    private init() {
        rebuildCache()
        setupObserver()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupObserver() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildCache()
        }
    }

    private func rebuildCache() {
        var newCache: [String: NSScreen] = [:]

        for screen in NSScreen.screens {
            if let uuid = screen.displayUUID {
                newCache[uuid] = screen
            }
        }

        cache = newCache
    }

    func screen(forUUID uuid: String) -> NSScreen? {
        return cache[uuid]
    }

    var allScreens: [String: NSScreen] {
        return cache
    }
}
