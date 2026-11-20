//  BrightnessManager.swift
//  boringNotch
//
//  Created by JeanLouis on 08/22/24.

import AppKit

final class BrightnessManager: ObservableObject {
	static let shared = BrightnessManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var animatedBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared

	/// Key repeats arriving while an XPC call is in flight accumulate here so
	/// no press is lost — each press used to trigger its own 3-RPC sequence
	/// (adjust + read + display lookup), and they would queue behind each other.
	private var pendingDelta: Float = 0
	private var pendingFollowFocus = false
	private var flushTask: Task<Void, Never>?

	/// Synchronous running estimate used for the optimistic OSD while a DDC
	/// write is still in flight. `rawBrightness` is published through the main
	/// queue asynchronously, so two rapid presses would otherwise both read the
	/// same stale base and the number would appear to stall.
	private var optimisticValue: Float?
	/// Which display the estimate belongs to; reset when focus moves so the OSD
	/// does not open on the previous screen's brightness.
	private var optimisticDisplayID: CGDirectDisplayID?

	/// The brightness target display only changes with the display set.
	private var cachedTargetUUID: String?
	private var screenParametersObserver: (any NSObjectProtocol)?

	private init() {
		refresh()
		screenParametersObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.cachedTargetUUID = nil
		}
	}

	/// Determine which screen UUID should be used for brightness OSDs
	/// when the built‑in source is selected.  This mirrors the logic in the
	/// XPC helper, which chooses the menu-bar display if it supports brightness and
	/// otherwise falls back to an internal panel.
	/// Cached; invalidated when the display configuration changes.
	func brightnessTargetUUID() async -> String? {
		if let cachedTargetUUID { return cachedTargetUUID }
		var resolved: String?
		if let displayID = await client.displayIDForBrightness() {
			resolved = NSScreen.screens.first(where: { $0.cgDisplayID == displayID })?.displayUUID
		}
		resolved = resolved ?? NSScreen.main?.displayUUID
		cachedTargetUUID = resolved
		return resolved
	}

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentScreenBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		applyRelative(delta: delta, followFocus: false)
	}

	/// F1/F2 path: adjust the display under the mouse cursor. Built-in panel is
	/// handled by the helper via IOKit, external via DDC — one code path for both
	/// screens so "明亮哪块就调哪块" holds without MonitorControl.
	@MainActor func setRelativeOnFocusedScreen(delta: Float) {
		applyRelative(delta: delta, followFocus: true)
	}

	@MainActor private func applyRelative(delta: Float, followFocus: Bool) {
		// A DDC write on an external panel costs ~150 ms (one m1ddc process).
		// Waiting for the helper's reply before touching the OSD made every key
		// press feel dead for a beat, so publish an optimistic value on key-down
		// and let the authoritative value correct it when the helper answers.
		let focusScreen = NSScreen.screenWithMouse ?? NSScreen.menuBarScreen
		// Focus moved to another panel: drop the estimate so the first press on
		// the new screen starts from that screen's own brightness.
		if followFocus, optimisticDisplayID != focusScreen?.cgDisplayID {
			optimisticValue = nil
			optimisticDisplayID = focusScreen?.cgDisplayID
		}
		let optimistic = max(0, min(1, (optimisticValue ?? rawBrightness) + delta))
		optimisticValue = optimistic
		publish(brightness: optimistic, touchDate: true)
		NotchUIEventBus.events.send(
			.sneakPeek(
				type: .brightness,
				value: CGFloat(optimistic),
				targetScreenUUID: followFocus ? focusScreen?.displayUUID : nil
			)
		)

		pendingDelta += delta
		pendingFollowFocus = pendingFollowFocus || followFocus
		guard flushTask == nil else { return }
		flushTask = Task { @MainActor in
			defer { flushTask = nil }
			while pendingDelta != 0 {
				// One m1ddc process costs the same whether it writes +6 or +36,
				// so give a burst of repeats a 40 ms window to merge into a
				// single DDC write instead of queueing one write per press.
				try? await Task.sleep(nanoseconds: 40_000_000)
				let delta = pendingDelta
				let followFocus = pendingFollowFocus
				pendingDelta = 0
				pendingFollowFocus = false

				var current: Float?
				var targetUUID: String?
				if followFocus {
					let focusScreen = NSScreen.screenWithMouse ?? NSScreen.menuBarScreen
					if let displayID = focusScreen?.cgDisplayID {
						current = await client.adjustBrightness(displayID: displayID, delta: delta)
						targetUUID = focusScreen?.displayUUID
					}
					if current == nil {
						// Fallback to the legacy built-in/main-display path.
						current = await client.adjustScreenBrightness(by: delta)
						targetUUID = await brightnessTargetUUID()
					}
				} else {
					current = await client.adjustScreenBrightness(by: delta)
					targetUUID = await brightnessTargetUUID()
				}

				guard let current else {
					// Helper could not report a value (DDC glitch). Keep the
					// optimistic figure on screen rather than blanking the HUD,
					// then resync from the hardware.
					refresh()
					continue
				}
				// Repeats may have arrived during the write; show them too so the
				// OSD number keeps up instead of snapping back to a stale value.
				let shown = pendingDelta == 0 ? current : max(0, min(1, current + pendingDelta))
				optimisticValue = shown
				publish(brightness: shown, touchDate: true)
				NotchUIEventBus.events.send(.sneakPeek(type: .brightness, value: CGFloat(shown), targetScreenUUID: targetUUID))
			}
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setScreenBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
                // optionally show peek when user uses slider/controls
                let targetUUID = await brightnessTargetUUID()
                NotchUIEventBus.events.send(.sneakPeek(type: .brightness, value: CGFloat(clamped), targetScreenUUID: targetUUID))
			} else {
				refresh()
			}
		}
	}

	private func publish(brightness: Float, touchDate: Bool) {
		// Defensive: a bogus reading (DisplayServices answers -1.0 on panels it
		// cannot read) must never become the number in the OSD.
		let value = max(0, min(1, brightness))
		DispatchQueue.main.async {
			if self.rawBrightness != value || touchDate {
				if touchDate { self.lastChangeAt = Date() }
				self.rawBrightness = value
				self.animatedBrightness = value
			}
		}
	}
}

// (DisplayServices helpers moved into XPC helper)

// MARK: - Keyboard Backlight Controller
final class KeyboardBacklightManager: ObservableObject {
	static let shared = KeyboardBacklightManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared

	/// Deltas accumulate while a read or set call is in flight so key repeats
	/// are coalesced into the next adjustment.
	private var pendingDelta: Float = 0
	private var flushTask: Task<Void, Never>?

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentKeyboardBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		pendingDelta += delta
		guard flushTask == nil else { return }
		flushTask = Task { @MainActor in
			defer { flushTask = nil }
			while pendingDelta != 0 {
				let delta = pendingDelta
				pendingDelta = 0
				// Include changes made outside the app in every adjustment.
				guard let current = await client.currentKeyboardBrightness() else {
					refresh()
					return
				}
				let target = max(0, min(1, current + delta))
				let ok = await client.setKeyboardBrightness(target)
				if ok {
					publish(brightness: target, touchDate: true)
				} else {
					refresh()
					return
				}
				NotchUIEventBus.events.send(.sneakPeek(type: .backlight, value: CGFloat(target)))
			}
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setKeyboardBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	@MainActor private func publish(brightness: Float, touchDate: Bool) {
		if rawBrightness != brightness || touchDate {
			if touchDate { lastChangeAt = Date() }
			rawBrightness = brightness
		}
	}
}
