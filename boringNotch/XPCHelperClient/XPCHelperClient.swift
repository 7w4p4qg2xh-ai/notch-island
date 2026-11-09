import Foundation
import Cocoa
import AsyncXPCConnection

/// Why a helper call failed. Methods still degrade to false/nil for
/// backward compatibility, but never silently: every transport failure —
/// a thrown XPC error or a dropped connection — is recorded in `lastError`
/// (interruption/invalidation record `.unavailable`), and connection loss
/// also flips `helperAvailable` for Settings to surface. A helper that
/// answers, even with false/nil, is a result, not an error, and leaves
/// `lastError` untouched.
enum XPCHelperError: Error {
    /// The XPC service could not be reached (crashed or restarting).
    case unavailable
    /// The helper refused the request (e.g. accessibility not granted).
    case declined
    /// Connection dropped mid-call.
    case transport(underlying: Error)
}

@MainActor
final class XPCHelperClient: NSObject, ObservableObject {
    nonisolated static let shared = XPCHelperClient()

    override nonisolated private init() {
        super.init()
    }

    private let serviceName = "com.notchisland.app.xpchelper"

    /// Coarse, UI-friendly view of helper connectivity. Flips to false from
    /// the connection's interruption/invalidation handlers so a crashed
    /// helper is visible in Settings instead of features silently degrading;
    /// flips back to true when a live connection is (re)established.
    @MainActor @Published private(set) var helperAvailable = true
    @MainActor private(set) var lastError: XPCHelperError?

    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    /// Set by the interruption/invalidation hops, cleared when a fresh
    private var lastKnownAuthorization: Bool?
    private let notificationDelegate = NotificationXPCDelegate()
    @MainActor private var activationObserver: (any NSObjectProtocol)?
    /// Repeating probe so a permission granted in System Settings is picked
    /// up without waiting for the app to become active (menu-bar agents
    /// rarely do) or for a relaunch.
    @MainActor private var authorizationPollTask: Task<Void, Never>?
    /// Mirrors the notification watcher across a connection rebuild — see
    /// `handleConnectionLoss()`.
    @MainActor private var wantsNotificationWatching = false
    @MainActor private var lastWatchingResume: Date = .distantPast
    @MainActor private var wakeObserver: (any NSObjectProtocol)?
    private var lunarListener: BoringNotchXPCHelperLunarListener?

    // MARK: - Connection Management (Main Actor Isolated)

    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        // Always reuse a live connection — never tear one down to attach a
        // listener. The exported object below serves *both* callback
        // protocols from the moment the connection is created, so there's
        // nothing to re-negotiate.
        //
        // This previously invalidated and rebuilt the connection whenever
        // Lunar/OSD asked for a listener. The helper captures its callback
        // proxy once, when notification watching starts; invalidating that
        // connection left it holding a dead proxy, so banners kept being
        // captured in the helper and silently never arrived in the app.
        if let existing = remoteService {
            notificationDelegate.lunarListener = lunarListener
            helperAvailable = true
            return existing
        }

        let conn = NSXPCConnection(serviceName: serviceName)

        // One exported object serves both callback protocols.
        notificationDelegate.lunarListener = lunarListener
        conn.exportedInterface = makeAppDelegateInterface()
        conn.exportedObject = notificationDelegate

        conn.interruptionHandler = { [weak self, weak conn] in
            Task { @MainActor in
                // Ignore stale handlers: an interruption from a deallocated
                // connection must not nil a freshly-built one.
                guard let self, let conn, self.connection === conn else { return }
                self.connection = nil
                self.remoteService = nil
                self.helperAvailable = false
                self.lastError = .unavailable
                self.handleConnectionLoss()
            }
        }

        conn.invalidationHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.connection = nil
                self.remoteService = nil
                self.helperAvailable = false
                self.lastError = .unavailable
                self.handleConnectionLoss()
            }
        }

        conn.resume()

        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )

        connection = conn
        remoteService = service
        helperAvailable = true
        lastError = nil
        return service
    }

    /// A rebuilt connection hands the helper a *new* callback proxy, but it
    /// keeps the one it captured when watching started — and that proxy
    /// belongs to the dead connection. The helper then goes on capturing
    /// banners and delivers them nowhere, which looks exactly like "the notch
    /// stopped showing notifications" while everything is still running.
    /// Re-arm the watcher on every connection loss.
    @MainActor
    private func handleConnectionLoss() {
        guard wantsNotificationWatching else { return }
        let now = Date()
        guard now.timeIntervalSince(lastWatchingResume) > 4 else { return }
        lastWatchingResume = now

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.wantsNotificationWatching else { return }
            _ = await self.startNotificationWatching()
        }
    }

    /// Sleep/wake is the other way the observer goes deaf: the connection
    /// survives, so no handler fires, but the accessibility attachments made
    /// before the sleep can stop delivering. Re-arm once the machine is back
    /// up. Idempotent — safe to call on every start.
    @MainActor
    private func startWakeRecovery() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsNotificationWatching else { return }
                try? await Task.sleep(for: .seconds(3))
                guard self.wantsNotificationWatching else { return }
                _ = await self.startNotificationWatching()
            }
        }
    }

    private func makeAppDelegateInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: (any BoringNotchXPCAppDelegate).self)
        interface.setClasses(
            NSSet(array: [BNLunarBrightnessEvent.self]) as! Set<AnyHashable>,
            for: #selector(BoringNotchXPCHelperLunarListener.lunarEventDidUpdate(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        return interface
    }

    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring

    /// AX trust has no public change notification. Check once at startup and
    /// whenever the app becomes active after a permission change in System
    /// Settings, plus a light repeating probe — a menu-bar agent like this
    /// one almost never becomes active, so without the probe a permission
    /// granted mid-session used to go unnoticed until the next relaunch.
    func startMonitoringAccessibilityAuthorization() {
        stopMonitoringAccessibilityAuthorization()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { _ = await self?.isAccessibilityAuthorized() }
        }
        authorizationPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self = self, !Task.isCancelled else { return }
                _ = await self.isAccessibilityAuthorized()
            }
        }
        // Initial probe so observers get the current state without waiting
        // for the first activation.
        Task { _ = await isAccessibilityAuthorized() }
    }

    func stopMonitoringAccessibilityAuthorization() {
        guard activationObserver != nil || authorizationPollTask != nil else { return }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        authorizationPollTask?.cancel()
        authorizationPollTask = nil
    }

    // MARK: - Accessibility

    func migrateLegacyAppBundle(from source: URL, to destination: URL) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.migrateLegacyAppBundle(
                    from: source.path,
                    to: destination.path
                ) { migrated in
                    continuation.resume(returning: migrated)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    // Fire-and-forget: callers invoke this from non-isolated contexts, and the work
    // itself hops onto the main actor.
    nonisolated func requestAccessibilityAuthorization() {
        Task { @MainActor in
            let service = ensureRemoteService()
            do {
                try await service.withService { service in
                    service.requestAccessibilityAuthorization()
                }
            } catch {
                lastError = .transport(underlying: error)
            }
        }
    }

    func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = ensureRemoteService()
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            notifyAuthorizationChange(result)
            return result
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = ensureRemoteService()
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            notifyAuthorizationChange(result)
            return result
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    // MARK: - Keyboard Brightness

    func currentKeyboardBrightness() async -> Float? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            lastError = .transport(underlying: error)
            return nil
        }
    }

    func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    // MARK: - Screen Brightness

    func currentScreenBrightness() async -> Float? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            lastError = .transport(underlying: error)
            return nil
        }
    }

    func displayIDForBrightness() async -> CGDirectDisplayID? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.displayIDForBrightness(with: { value in
                    continuation.resume(returning: value)
                })
            }
            guard let num = result else { return nil }
            return CGDirectDisplayID(num.uint32Value)
        } catch {
            lastError = .transport(underlying: error)
            return nil
        }
    }

    func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }
    /// Returns the resulting brightness, or nil on failure.
    func adjustScreenBrightness(by value: Float) async -> Float? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.adjustScreenBrightness(by: value) { result in
                    continuation.resume(returning: result?.floatValue)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return nil
        }
    }

    // MARK: - Lunar Events

    func isLunarAvailable() async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.isLunarAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    func startLunarEventStream(listener: BoringNotchXPCHelperLunarListener) async -> Bool {
        lunarListener = listener
        // Register on the shared exported object too: the connection may
        // already exist (it isn't rebuilt for listeners any more), in
        // which case this is the only path that hooks Lunar events up.
        notificationDelegate.lunarListener = listener
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.startLunarEventStream { started in
                    continuation.resume(returning: started)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    func stopLunarEventStream() async {
        do {
            let service = ensureRemoteService()
            try await service.withService { service in
                service.stopLunarEventStream()
            }
        } catch {
            lastError = .transport(underlying: error)
            return
        }
    }

    func setLunarOSDHidden(_ hide: Bool) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setLunarOSDHidden(hide) { ok in
                    continuation.resume(returning: ok)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }
}

// MARK: - Notification Center banners

/// The app's single exported XPC object. Banner pushes are republished as local
/// notifications; Lunar events are forwarded to whichever listener the OSD code
/// registered, since both callbacks share one connection.
final class NotificationXPCDelegate: NSObject, BoringNotchXPCAppDelegate {
    /// Written on the MainActor (connection setup, `startLunarEventStream`),
    /// read on the XPC connection's private delivery queue. The lock
    /// synchronizes cross-thread publication; the listener itself is still
    /// invoked on the delivery queue — no per-event actor hop on this hot
    /// path.
    private let lunarListenerLock = NSLock()
    private var _lunarListener: BoringNotchXPCHelperLunarListener?

    var lunarListener: BoringNotchXPCHelperLunarListener? {
        get {
            lunarListenerLock.lock()
            defer { lunarListenerLock.unlock() }
            return _lunarListener
        }
        set {
            lunarListenerLock.lock()
            _lunarListener = newValue
            lunarListenerLock.unlock()
        }
    }

    func lunarEventDidUpdate(_ event: BNLunarBrightnessEvent) {
        lunarListener?.lunarEventDidUpdate(event)
    }

    func lunarStreamDidStop(_ reason: String?) {
        lunarListener?.lunarStreamDidStop(reason)
    }

    func notificationDidAppear(_ payload: [String: String]) {
        NotificationCenter.default.post(
            name: .systemNotificationDidAppear, object: nil, userInfo: payload
        )
    }
}

extension XPCHelperClient {
    nonisolated func startNotificationWatching() async -> Bool {
        await MainActor.run {
            self.wantsNotificationWatching = true
            self.startWakeRecovery()
        }
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.startNotificationWatching { started in
                    continuation.resume(returning: started)
                }
            }
        } catch {
            await MainActor.run { self.lastError = .transport(underlying: error) }
            return false
        }
    }

    nonisolated func setNotificationFilter(bundleIDs: Set<String>, allApps: Bool) {
        Task {
            let service = await MainActor.run { ensureRemoteService() }
            do {
                try await service.withService {
                    $0.setNotificationFilter(Array(bundleIDs), allApps: allApps)
                }
            } catch {
                await MainActor.run { self.lastError = .transport(underlying: error) }
            }
        }
    }

    /// Performs a button of the system banner the notch mirrored. Returns false
    /// when the helper could not reach the banner — it then hands the banner
    /// back to the screen, so the user can finish there.
    nonisolated func performNotificationAction(token: String, actionTitle: String) async -> Bool {
        let service = await MainActor.run { ensureRemoteService() }
        do {
            return try await service.withContinuation { service, continuation in
                service.performNotificationAction(token, actionTitle: actionTitle) { performed in
                    continuation.resume(returning: performed)
                }
            }
        } catch {
            await MainActor.run { self.lastError = .transport(underlying: error) }
            return false
        }
    }

    /// Hands a mirrored banner back to the screen — the escape hatch for a
    /// notification the notch cannot act on.
    nonisolated func revealNotification(token: String) async -> Bool {
        let service = await MainActor.run { ensureRemoteService() }
        do {
            return try await service.withContinuation { service, continuation in
                service.revealNotification(token) { revealed in
                    continuation.resume(returning: revealed)
                }
            }
        } catch {
            await MainActor.run { self.lastError = .transport(underlying: error) }
            return false
        }
    }

    nonisolated func setNotificationPassthrough(_ enabled: Bool) {
        Task {
            let service = await MainActor.run { ensureRemoteService() }
            do {
                try await service.withService { $0.setNotificationPassthrough(enabled) }
            } catch {
                await MainActor.run { self.lastError = .transport(underlying: error) }
            }
        }
    }

    nonisolated func stopNotificationWatching() {
        Task {
            await MainActor.run { self.wantsNotificationWatching = false }
            let service = await MainActor.run { ensureRemoteService() }
            do {
                try await service.withService { $0.stopNotificationWatching() }
            } catch {
                await MainActor.run { self.lastError = .transport(underlying: error) }
            }
        }
    }
}

extension Notification.Name {
    static let systemNotificationDidAppear = Notification.Name("systemNotificationDidAppear")
}
