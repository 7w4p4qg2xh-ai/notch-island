//
//  SystemNotificationManager.swift
//  boringNotch
//
import AppKit
import Combine
import Defaults

/// One button the mirrored banner offered ("Open", "Accept"…). The notch draws
/// these so the notification stays actionable after the real banner was hidden.
struct NotificationAction: Identifiable, Equatable, Codable {
    /// Position in the banner's button list — what the helper presses.
    let index: Int
    let title: String

    var id: Int { index }
}

struct SystemNotification: Identifiable, Equatable {
    let id: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    let receivedAt: Date
    var actions: [NotificationAction] = []
}

@MainActor
final class SystemNotificationManager: ObservableObject {
    static let shared = SystemNotificationManager()

    @Published private(set) var activeNotification: SystemNotification?
    @Published private(set) var queuedNotifications: [SystemNotification] = []

    private let queueLimit = 5
    /// Keep in sync with `ContentView.notificationPeekSeconds`. 8s was too
    /// short to read a full card, especially when it lands on the other
    /// display; 12s matches the automatic peek countdown.
    private let displayDuration: TimeInterval = 12
    private var dismissTask: Task<Void, Never>?
    private var notificationObserver: NSObjectProtocol?
    private var isUserPresent = false

    private init() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .systemNotificationDidAppear, object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = note.userInfo as? [String: String] else { return }
            Task { @MainActor in self?.add(payload) }
        }
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
    }

    func start() async {
        guard await XPCHelperClient.shared.isAccessibilityAuthorized() else { return }
        updateFilter()
        _ = await XPCHelperClient.shared.startNotificationWatching()
    }

    func stop() {
        XPCHelperClient.shared.stopNotificationWatching()
        queuedNotifications.removeAll()
        isUserPresent = false
        dismissActive()
    }

    func holdActive() {
        isUserPresent = true
        dismissTask?.cancel()
        dismissTask = nil
    }

    func resumeDismiss(after delay: TimeInterval = 2) {
        isUserPresent = false
        queuedNotifications.removeAll()
        guard let notification = activeNotification else { return }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: notification.id)
        }
    }

    func dismissActive(token: String? = nil) {
        guard token == nil || activeNotification?.id == token else { return }
        dismissTask?.cancel()
        dismissTask = nil
        activeNotification = nil
        if isUserPresent {
            promoteNext()
        } else {
            queuedNotifications.removeAll()
        }
    }

    func showNextQueued() {
        guard isUserPresent, let next = queuedNotifications.first else { return }
        if let activeNotification {
            queuedNotifications.append(activeNotification)
        }
        queuedNotifications.removeFirst()
        show(next)
    }

    func open(_ notification: SystemNotification) async -> Bool {
        let workspace = NSWorkspace.shared

        for bundleID in candidateBundleIDs(for: notification) {
            let running = workspace.runningApplications.first { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }

            if let running {
                if running.activate(options: [.activateAllWindows]) {
                    return true
                }
                if let appURL = running.bundleURL,
                   await launchApplication(at: appURL) {
                    return true
                }
            }

            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID),
               await launchApplication(at: appURL) {
                return true
            }
        }

        return false
    }

    private func add(_ payload: [String: String]) {
        guard let token = payload["token"], !token.isEmpty else { return }
        bnDebugLog(
            "recv token=\(token.prefix(6)) app=\(payload["appName"] ?? "-")"
            + " title=\(payload["title"] ?? "-") active=\(activeNotification == nil ? "none" : "busy")"
            + " userPresent=\(isUserPresent)"
        )
        let appName = nonEmpty(payload["appName"])
        var bundleID = nonEmpty(payload["bundleID"]).map {
            normalizeBundleIdentifier($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The helper only has the banner's display name and can miss when the
        // source is a helper process or is no longer running. Re-resolve here
        // so both the icon and launch action get the real application.
        if bundleID.map(isLaunchable) != true,
           let appName,
           let resolved = BundleIDResolver.shared.bundleID(forAppNamed: appName) {
            let resolved = normalizeBundleIdentifier(resolved)
            bundleID = resolved
        }

        let notification = SystemNotification(
            id: token,
            appName: appName,
            bundleID: bundleID,
            title: nonEmpty(payload["title"]),
            subtitle: nonEmpty(payload["subtitle"]),
            body: nonEmpty(payload["body"]),
            receivedAt: Date(),
            actions: Self.decodeActions(payload["actions"])
        )
        guard isAllowed(notification) else { return }
        guard activeNotification == nil else {
            guard isUserPresent else {
                show(notification)
                return
            }
            guard !queuedNotifications.contains(where: { $0.id == notification.id }) else { return }
            queuedNotifications.append(notification)
            if queuedNotifications.count > queueLimit {
                queuedNotifications.removeFirst()
            }
            return
        }
        show(notification)
    }

    private func show(_ notification: SystemNotification) {
        bnDebugLog("show token=\(notification.id.prefix(6)) app=\(notification.appName ?? "-")")
        dismissTask?.cancel()
        activeNotification = notification
        scheduleDismiss(for: notification.id)
    }

    private func scheduleDismiss(for token: String) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.displayDuration ?? 12))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: token)
        }
    }

    private func promoteNext() {
        guard activeNotification == nil, !queuedNotifications.isEmpty else { return }
        show(queuedNotifications.removeFirst())
    }

    func updateFilter() {
        XPCHelperClient.shared.setNotificationFilter(
            bundleIDs: Defaults[.notificationAllowedApps],
            allApps: Defaults[.notificationsFromAllApps]
        )
        // Same round trip: a notification that needs typing must be left to the
        // system banner, which is a policy the helper enforces at capture time.
        XPCHelperClient.shared.setNotificationPassthrough(Defaults[.notificationPassthroughActions])
    }

    /// Press a button of the banner this notification came from.
    ///
    /// The banner sits off screen, so the tap cannot be delivered by clicking —
    /// the helper presses the real element. The notch entry is cleared first so
    /// the tap always produces a visible response, whether or not the system
    /// honours the press (on refusal the helper puts the banner back on screen).
    func performAction(_ action: NotificationAction, on notification: SystemNotification) {
        let token = notification.id
        dismissActive(token: token)
        Task {
            _ = await XPCHelperClient.shared.performNotificationAction(
                token: token,
                actionTitle: action.title
            )
        }
    }

    /// Hand this notification back to the system banner.
    ///
    /// Every mirrored notification gets this, because mirroring can always hit
    /// something the notch cannot do — an incoming call to answer, a button
    /// that refused to press. It beats guessing from the text.
    func reveal(_ notification: SystemNotification) {
        let token = notification.id
        dismissActive(token: token)
        Task {
            _ = await XPCHelperClient.shared.revealNotification(token: token)
        }
    }

    nonisolated static func decodeActions(_ raw: String?) -> [NotificationAction] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([NotificationAction].self, from: data)) ?? []
    }

    private func isAllowed(_ notification: SystemNotification) -> Bool {
        if Defaults[.notificationsFromAllApps] { return true }
        if let bundleID = notification.bundleID {
            return Defaults[.notificationAllowedApps].contains(bundleID)
        }
        guard let appName = notification.appName.map(BundleIDResolver.normalizedAppName),
              !appName.isEmpty else {
            return false
        }
        return Defaults[.notificationAllowedApps].contains { bundleID in
            guard let lastComponent = bundleID.split(separator: ".").last else { return false }
            return appName == BundleIDResolver.normalizedAppName(String(lastComponent))
        }
    }

    private func candidateBundleIDs(for notification: SystemNotification) -> [String] {
        let resolved: String?
        if let bundleID = notification.bundleID, isLaunchable(bundleID) {
            resolved = nil
        } else {
            resolved = notification.appName.flatMap {
                BundleIDResolver.shared.bundleID(forAppNamed: $0)
            }
        }
        return Self.bundleIDCandidates(for: notification, resolvedBundleID: resolved)
    }

    nonisolated static func bundleIDCandidates(
        for notification: SystemNotification,
        resolvedBundleID: String? = nil
    ) -> [String] {
        var result: [String] = []
        for candidate in [notification.bundleID, resolvedBundleID].compactMap({ $0 }) {
            let normalized = normalizeBundleIdentifier(candidate)
            guard !normalized.isEmpty, !result.contains(normalized) else { continue }
            result.append(normalized)
        }
        return result
    }

    private func isLaunchable(_ bundleID: String) -> Bool {
        let workspace = NSWorkspace.shared
        return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
            || workspace.runningApplications.contains { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }
    }

    private func launchApplication(at appURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
