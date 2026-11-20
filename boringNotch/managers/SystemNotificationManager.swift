//
//  SystemNotificationManager.swift
//  boringNotch
//
import AppKit
import Combine
import CoreGraphics
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
    /// 通知在岛上的展示时长（秒）。**唯一来源**：ContentView 的自动收起
    /// 倒计时直接读这个常量。旧实现两处各写一个 12，靠注释"必须保持一致"
    /// 维生，改一处就会出现"卡片先没了、面板还开着"（docs/02 11-18）。
    /// 8s 读不完一整屏正文，12s 是一次实测后的取值。
    static let displayDuration: TimeInterval = 12
    /// 指针离开后的最短停留。旧实现固定 2 秒，读一半走开就再也看不到这条。
    static let minimumGrace: TimeInterval = 6

    /// 当前卡片还剩多少展示时间。被 hover 冻结时不再流逝，恢复时从这里续算，
    /// 而不是重新起一个倒计时——否则"看一眼再走开"会把剩余时间清零。
    private var remaining: TimeInterval = SystemNotificationManager.displayDuration
    /// 指针进入卡片的时刻；`nil` = 没人在看，倒计时正常走。
    private var heldAt: Date?
    private var dismissTask: Task<Void, Never>?
    private var notificationObserver: NSObjectProtocol?
    private var isUserPresent = false
    /// Last time each *banner* was actually shown, keyed by token + content.
    ///
    /// The helper dedups too, but its memory dies with its process; this is
    /// the second line of defence for a helper restart that re-scans a banner
    /// still sitting in Notification Center.
    ///
    /// The key deliberately includes the token. Keying on content alone meant
    /// two genuinely different notifications that happen to read the same —
    /// the same message twice, a repeated "已连接" alert — lost the second one
    /// for five minutes. A re-scanned banner keeps its AX identifier (it is
    /// the same element in the same process), so including the token costs
    /// nothing on the stale-replay path this guard exists for.
    private var recentlyShown: [String: Date] = [:]
    private let recentTokenWindow: TimeInterval = 300

    private nonisolated static func dedupKey(token: String, fingerprint: String) -> String {
        token + "\u{1F}" + fingerprint
    }

    /// A control on the notification card (✕ / reveal / queue / banner action /
    /// open-app) was tapped, and that same mouse event must NOT also reach the
    /// island's outer `.onTapGesture` (ContentView) — SwiftUI delivers the
    /// event to the deepest view first, but the outer gesture still fires
    /// afterwards, so "press ✕" reads as "press the island" and the whole
    /// panel opens (2026-11-16 user report).
    ///
    /// 11-18 改判定依据：旧写法是一个 Bool + 0.4s 自然过期。问题是 Button
    /// 一旦把事件吃掉（外层手势不跑），旗标就得干等 0.4s 才失效，这期间用户
    /// 真的去点岛会被白白吞掉一次——就是「连点回归」的隐患。改成按 AppKit
    /// **事件号**判定：控件的 action 与外层手势在同一次事件派发里跑，事件号
    /// 必然相同；用户下一次点击必然是不同的号，所以该吞的吞、不该吞的一次都
    /// 不吞，不依赖任何时间猜测。
    private var suppressedOpenEvent: Int?
    /// 拿不到事件号时的兜底（AX 按下的 action、`NSApp.currentEvent` 为 nil）：
    /// 80ms 远小于人手连点间隔，不会误吞下一次真实点击。
    private var suppressedOpenFallbackDeadline: Date?
    private let suppressedOpenFallbackWindow: TimeInterval = 0.08

    private func armOpenTapSuppression() {
        if let event = NSApp.currentEvent {
            suppressedOpenEvent = event.eventNumber
            suppressedOpenFallbackDeadline = nil
        } else {
            suppressedOpenEvent = nil
            suppressedOpenFallbackDeadline = Date().addingTimeInterval(suppressedOpenFallbackWindow)
        }
    }

    /// 外层的 `.onTapGesture` 问一句「这一轮要不要吞掉」。
    /// 返回 true = 这次点击属于某个已处理的控件，不要再开岛。
    func consumeSuppressedOpenTap() -> Bool {
        if let armed = suppressedOpenEvent {
            suppressedOpenEvent = nil
            return NSApp.currentEvent?.eventNumber == armed
        }
        if let deadline = suppressedOpenFallbackDeadline {
            suppressedOpenFallbackDeadline = nil
            return Date() < deadline
        }
        return false
    }

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
        if heldAt == nil { heldAt = Date() }
    }

    /// 指针离开：从「剩余时间」续算，且不再清空队列。
    ///
    /// 旧实现有两个问题（2026-11-18 审查 P0-4）：
    /// ① 第一行就 `queuedNotifications.removeAll()`——指针一动，排队中的后续
    ///    通知当场被丢掉；
    /// ② 固定 2 秒，与 12 秒的展示时长互相矛盾，读一半走开就永久看不到。
    /// 现在：把「被冻结的这段时间」从剩余里扣掉，保底 `minimumGrace`。
    func resumeDismiss(after delay: TimeInterval? = nil) {
        isUserPresent = false
        if let heldAt {
            remaining = max(remaining - Date().timeIntervalSince(heldAt), Self.minimumGrace)
            self.heldAt = nil
        }
        guard let notification = activeNotification else { return }
        dismissTask?.cancel()
        let wait = delay ?? remaining
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: notification.id)
        }
    }

    func dismissActive(token: String? = nil) {
        guard token == nil || activeNotification?.id == token else { return }
        dismissTask?.cancel()
        dismissTask = nil
        activeNotification = nil
        // 11-18：`else { queuedNotifications.removeAll() }` 已删除。指针离开
        // 不等于"读完了"，排队中的通知应当留到用户下次回到岛上（或点 +N）。
        // 只有 stop()（关闭监听）与显式 clear 才清队列。
        //
        // 11-19：队列必须在这里推进。`+N` 徽标挂在卡片上，卡片一到期消失，
        // 队列就没有任何可见载体——突发 3 条时只有第 1 条真正被看到，另外 2 条
        // 要等"下一条通知把卡片带回来"才偶然露脸。到期即取下一条，队列本身
        // 仍然不清空（指针回来还能继续翻），只是每条都拿到自己的展示时间。
        promoteNext()
    }

    func showNextQueued() {
        armOpenTapSuppression()
        guard isUserPresent, let next = queuedNotifications.first else { return }
        if let activeNotification {
            queuedNotifications.append(activeNotification)
        }
        queuedNotifications.removeFirst()
        show(next)
    }

    func open(_ notification: SystemNotification) async -> Bool {
        armOpenTapSuppression()
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
        let now = Date()
        let fingerprint = Self.contentFingerprint(
            appName: payload["appName"],
            title: payload["title"],
            subtitle: payload["subtitle"],
            body: payload["body"]
        )
        let key = Self.dedupKey(token: token, fingerprint: fingerprint)
        recentlyShown = recentlyShown.filter {
            now.timeIntervalSince($0.value) < recentTokenWindow
        }
        if recentlyShown[key] != nil {
            // Same banner, re-scanned after an observer re-arm. Refresh the
            // timestamp so a banner that never leaves the center cannot
            // resurface every few minutes.
            recentlyShown[key] = now
            return
        }
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
        guard isAllowed(notification) else {
            // The helper has already parked this banner, so simply dropping it
            // here is exactly the "notification disappeared" case: the system
            // banner is off screen and no card is ever drawn. Hand the banner
            // back instead — a duplicate filter decision must never cost the
            // notification itself.
            bnDebugLog("drop token=\(token.prefix(6)) not in allow list — revealing banner")
            Task { _ = await XPCHelperClient.shared.revealNotification(token: token) }
            return
        }
        guard activeNotification == nil else {
            // A burst used to overwrite the card instantly: five alerts
            // arriving within 60 ms (2026-11-18 13:48) left only the last one
            // readable, because `show()` replaced `activeNotification` each
            // time. Queue them instead — the card keeps the one already on
            // screen, the queue is surfaced as the `+N` pill on the card
            // (`NotificationLiveActivity.controls`), and tapping it advances
            // (`showNextQueued`). Nothing in a burst is dropped on the floor.
            guard !queuedNotifications.contains(where: { $0.id == notification.id }) else { return }
            queuedNotifications.append(notification)
            if queuedNotifications.count > queueLimit {
                // The oldest card will never be drawn; its banner is parked
                // off screen, so dropping the struct silently is the same as
                // deleting the notification. Give it back to the system UI.
                let dropped = queuedNotifications.removeFirst()
                bnDebugLog("queue overflow — revealing token=\(dropped.id.prefix(6))")
                Task { _ = await XPCHelperClient.shared.revealNotification(token: dropped.id) }
            }
            return
        }
        show(notification)
    }

    private func show(_ notification: SystemNotification) {
        recentlyShown[Self.dedupKey(
            token: notification.id,
            fingerprint: Self.contentFingerprint(
                appName: notification.appName,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body
            )
        )] = Date()
        bnDebugLog("show token=\(notification.id.prefix(6)) app=\(notification.appName ?? "-")")
        dismissTask?.cancel()
        remaining = Self.displayDuration
        heldAt = nil
        activeNotification = notification
        scheduleDismiss(for: notification.id)
    }

    private func scheduleDismiss(for token: String) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.remaining ?? Self.displayDuration))
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
        armOpenTapSuppression()
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
        armOpenTapSuppression()
        let token = notification.id
        dismissActive(token: token)
        Task {
            _ = await XPCHelperClient.shared.revealNotification(token: token)
        }
    }

    /// Clear the notification out of Notification Center — the card's ✕.
    ///
    /// Dismissing the card alone only hides the mirror; an alert banner parked
    /// off-screen would keep sitting in Notification Center forever, and every
    /// watcher re-arm would mirror it again. Pressing the banner's own
    /// "全部清除" action removes it at the source, so ✕ means ✕, not "hide
    /// for 12 seconds". The helper resolves a stale card token through the
    /// banner's content fingerprint (host-window rebuilds rewrite tokens).
    func clear(_ notification: SystemNotification) {
        armOpenTapSuppression()
        let token = notification.id
        dismissActive(token: token)
        Task {
            let cleared = await XPCHelperClient.shared.clearNotificationBanner(token: token)
            if !cleared {
                bnDebugLog("clear token=\(token.prefix(6)) app=\(notification.appName ?? "-") no clear action / banner gone")
            }
        }
    }

    /// Must match the helper's `NotificationWatcher.contentFingerprint` —
    /// same fields, same separator, same whitespace handling.
    nonisolated static func contentFingerprint(
        appName: String?, title: String?, subtitle: String?, body: String?
    ) -> String {
        [appName, title, subtitle, body]
            .map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\u{1F}")
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

    // MARK: - Banner-host watchdog (2026-11-14)

    private var watchdogTask: Task<Void, Never>?
    private var onScreenStreak = 0

    /// The helper can lose its AX attachment in ways none of its internal
    /// timers reliably catch: a transient trust blip makes the health check
    /// `stop()` (which also invalidates that very timer), and a full
    /// NotificationCenter relaunch can race the re-attach. From the outside
    /// every one of these looks identical — the full-screen banner host
    /// window comes back to (0,0) and the user sees the system banner again.
    /// Watch that symptom directly rather than guessing at internal state.
    /// Two consecutive sightings (~20s) avoid re-arming during the brief
    /// window while a fresh NotificationCenter is still coming up.
    func startBannerWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                guard Defaults[.notificationLiveActivity] else {
                    self.onScreenStreak = 0
                    continue
                }
                if Self.bannerHostIsOnScreen() {
                    self.onScreenStreak += 1
                } else {
                    self.onScreenStreak = 0
                }
                if self.onScreenStreak >= 2 {
                    self.onScreenStreak = 0
                    await self.start()
                }
            }
        }
    }

    /// The banner host is the full-display transparent window (layer 23).
    /// While mirroring works it is parked at (-10000,-10000); seeing it on
    /// screen means the system banner has taken over. No TCC/screen-recording
    /// permission is needed for CGWindowListCopyWindowInfo.
    private static func bannerHostIsOnScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        for w in list {
            // 🔴 Layer ceiling. Window Server also paints full-screen
            // "Packages Display N Shield" windows at layer 2147483646 with
            // exactly the same 1512×982 / 1920×1080 bounds at (0,0). Without
            // the ceiling this probe reported a runaway banner permanently:
            // the watchdog re-armed every ~20s, each re-arm rebuilt the AX
            // observer and re-scanned two stale banners, and the same two
            // notifications popped up forever (docs/04 Q). The real banner
            // host is layer 23, parked at (-10000,-10000).
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  layer >= 20, layer < 1000 else { continue }
            // The Dock also owns a 1512×982 window at (0,0) on layer 20, so
            // the layer ceiling alone is not enough. Only the Notification
            // Center host counts; its bundle id is stable across localisations
            // (verified on this machine: pid 22915 → com.apple.notificationcenterui).
            guard let pid = w[kCGWindowOwnerPID as String] as? Int,
                  NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
                    == "com.apple.notificationcenterui" else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = b["Width"] as? Double ?? 0
            let height = b["Height"] as? Double ?? 0
            let x = b["X"] as? Double ?? 0
            let y = b["Y"] as? Double ?? 0
            if width > 1000, height > 600, x > -9000, y > -9000 { return true }
        }
        return false
    }
}
