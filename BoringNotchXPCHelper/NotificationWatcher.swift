//
//  NotificationWatcher.swift
//  BoringNotchXPCHelper
//
import AppKit
import ApplicationServices
import Foundation

private let notificationCenterBundleID = "com.apple.notificationcenterui"
private let orderedChildrenAttribute = "AXOrderedChildren"
private let stackingIdentifierAttribute = "AXStackingIdentifier"
private let maxAccessibilityNodes = 1_024
private let maxTextNodes = 256
private let structuralIdentifiers: Set<String> = [
    "AXNotificationListItems",
    "widgets-overlay-view"
]
private let settleDelay: TimeInterval = 0.15

private extension AXUIElement {
    subscript(attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        self[attribute] as? String
    }

    func children() -> [AXUIElement] {
        (self[kAXChildrenAttribute] as? [AXUIElement] ?? [])
            + (self[orderedChildrenAttribute] as? [AXUIElement] ?? [])
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let value = self[attribute],
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    func size(_ attribute: String) -> CGSize? {
        guard let value = self[attribute],
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }
}

/// One action the system banner is offering ("Show", "Accept", "Decline"…).
///
/// macOS exposes these as accessibility *custom actions* on the banner itself —
/// not as child `AXButton` elements, and not only once the banner is expanded.
/// Measured on macOS 27: an unexpanded banner still reports
/// `["AXPress", "Name:显示详细信息\\nTarget:…", "Name:显示\\n…", "Name:关闭\\n…"]`,
/// and performing the short name ("显示") returns success while the window is
/// parked off-screen. `index` is the position in that list; `title` is what the
/// user sees, and what the press is matched on.
struct CapturedNotificationAction: Codable {
    let index: Int
    let title: String
}

struct CapturedNotification {
    let token: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    let actions: [CapturedNotificationAction]

    /// Only calls go back to the real banner.
    ///
    /// A message carrying a "Reply" action stays in the notch: replying needs a
    /// text field, but mirroring the message is still what the user asked for,
    /// and the card offers "show the real banner" for when they do want to
    /// answer. Treating "has a Reply button" as "needs the system UI" pushed
    /// every WeChat message into the corner, which is not what anyone wants.
    ///
    /// A call is different in kind: it expires in seconds, and a mirrored call
    /// cannot be answered.
    var needsNativeInteraction: Bool {
        looksLikeIncomingCall
    }

    private var looksLikeIncomingCall: Bool {
        let source = [appName, title]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !source.isEmpty else { return false }
        return NotificationWatcher.callKeywords.contains { source.contains($0) }
    }
}

final class NotificationWatcher {
    private final class ObserverContext: @unchecked Sendable {
        weak var watcher: NotificationWatcher?
    }

    /// AXUIElement has no `Sendable` conformance but is safe to hand to the main
    /// queue: it is a CF object the AX client copies for us.
    private struct AXElementBox: @unchecked Sendable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
    }

    var onBanner: ((CapturedNotification) -> Void)?

    private var appElement: AXUIElement?
    private var axObserver: AXObserver?
    private var observerRunLoop: AXObserverRunLoop?
    private var observerContext: ObserverContext?
    private var scanScheduled = false
    private var settleWorkItem: DispatchWorkItem?
    private var observedWindows: [CFHashCode: AXUIElement] = [:]
    private var liveTokens = Set<String>()
    private var allowedBundleIDs = Set<String>()
    private var axDumpCount = 0
    private var mirrorAllApps = false
    /// Windows parked off-screen, with the position to give back on `stop()`.
    ///
    /// Parking used to last only as long as the banner did: the window was put
    /// back on screen the moment its banner disappeared. That made the *next*
    /// banner render inside a visible window for the few dozen milliseconds it
    /// takes to notice and hide it again — the "系统横幅在右上角闪一下" — and
    /// the dismissal animation of the current one played on screen too. So a
    /// parked window now stays parked for the whole watching session and is
    /// only given back when the watcher stops.
    private var parkedWindows: [Int: (window: AXUIElement, origin: CGPoint)] = [:]
    /// Windows currently showing a banner we do not mirror: the system banner is
    /// the user's only reminder there, so it stays visible until it goes away.
    private var unmirroredWindows = Set<Int>()
    /// Banner elements by notification token, so an action tapped in the notch
    /// can be pressed through the *live* banner instead of a rebuilt copy. The
    /// elements are handed out by the same process that owns them; keeping
    /// them only costs a CFRetain.
    private var bannerElements: [String: AXUIElement] = [:]
    /// Which window a token's banner lives in — the window has to be given back
    /// when a press turns out not to work off-screen.
    private var bannerWindows: [String: Int] = [:]
    /// Whether calls are left on the system banner instead of being mirrored.
    /// See `CapturedNotification.needsNativeInteraction`.
    private var passthroughInteractive = true
    private var bundleIDCache: [String: String] = [:]
    /// Detects a NotificationCenter relaunch: its AX elements die with the
    /// old process, so the watcher must tear down and re-attach.
    private var centerMonitorTimer: Timer?
    private var lastCenterPID: pid_t = 0
    /// Health probe: sleep/wake can wedge the AX channel while everything
    /// else (process, connection) looks alive — the observer then goes deaf
    /// with no event ever firing to notice. There is no AX API to query
    /// whether a registration still delivers, so probe the channel itself:
    /// a healthy attachment answers attribute reads. `start()` is an
    /// idempotent re-arm, so an occasional spurious rebuild is harmless.
    private var healthTimer: Timer?

    var isRunning: Bool { appElement != nil }

    // MARK: - Diagnostics

    /// Opt-in timing trace: create `/tmp/bn-watch.debug` and every park event is
    /// appended to `/tmp/bn-watch.log`. The helper's NSLog does not reach
    /// `log show`, so this is the only way to tell "AX event latency" apart from
    /// "our own scan latency" when the system banner stays visible too long.
    ///
    /// The marker is checked on EVERY trace, not cached in a `lazy var`.
    /// A cached URL meant "touch the marker after the helper started" silently
    /// did nothing, so an empty log was mistaken for "AX delivered no events"
    /// during the 2026-11-05 notification incident (docs/04 section I).
    /// It is now a hot switch: `touch` / `rm` takes effect immediately.
    private static let traceMarkerPath = "/tmp/bn-watch.debug"
    private static let traceLogPath = "/tmp/bn-watch.log"

    private func trace(_ message: @autoclosure () -> String) {
        guard FileManager.default.fileExists(atPath: Self.traceMarkerPath),
              let data = "\(Date().timeIntervalSince1970) \(message())\n".data(using: .utf8) else {
            return
        }
        let url = URL(fileURLWithPath: Self.traceLogPath)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }


    func configureFilter(bundleIDs: Set<String>, allApps: Bool) {
        allowedBundleIDs = bundleIDs
        mirrorAllApps = allApps
    }

    /// When on (the default), an incoming call is never parked: mirroring it
    /// would take away the only way to answer, and a call expires in seconds.
    /// Messages — including ones carrying a Reply button — are always mirrored.
    func configureInteractionPassthrough(_ enabled: Bool) {
        passthroughInteractive = enabled
    }

    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else {
            // Stale running state after a revoke would block the next
            // start() (isRunning guard), leaving capture dead even once
            // trust returns — reset first so recovery is automatic.
            if isRunning { stop() } else { restoreAllWindows() }
            return false
        }
        // Start is also the "re-arm" path: the app calls it again after an XPC
        // connection rebuild and after the machine wakes, where the old
        // observer can be silently deaf while `appElement` still looks alive.
        // Rebuild the attachments instead of trusting them.
        //
        // The parked windows stay parked across the rebuild: they are parked on
        // purpose, and handing them back only re-opens the flash window for the
        // next banner.
        if isRunning { stop(restoringWindows: false) }

        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: notificationCenterBundleID
        ).first else {
            restoreAllWindows()
            return false
        }

        appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard installObserver(for: application.processIdentifier) else {
            appElement = nil
            restoreAllWindows()
            return false
        }

        refreshObservedWindows()
        restoreParkedOrphans()
        scan()
        startCenterMonitor()
        startHealthMonitor()
        return true
    }

    func stop(restoringWindows: Bool = true) {
        settleWorkItem?.cancel()
        settleWorkItem = nil
        centerMonitorTimer?.invalidate()
        centerMonitorTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        if let observer = axObserver {
            if let appElement {
                removeObserverNotifications(from: appElement, observer: observer)
            }
            for window in observedWindows.values {
                removeObserverNotifications(from: window, observer: observer)
            }
        }
        observedWindows.removeAll()
        observerRunLoop?.stop()
        axObserver = nil
        observerRunLoop = nil
        observerContext = nil
        scanScheduled = false
        liveTokens.removeAll()
        unmirroredWindows.removeAll()
        bannerElements.removeAll()
        bannerWindows.removeAll()
        if restoringWindows {
            restoreAllWindows()
        }
        appElement = nil
    }

    // MARK: - Self-healing

    private func currentCenterPID() -> pid_t {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: notificationCenterBundleID
        ).first?.processIdentifier ?? 0
    }

    /// Re-attach automatically when NotificationCenter restarts — without
    /// this, a crashed/relaunched NotificationCenter silently ends capture.
    private func startCenterMonitor() {
        lastCenterPID = currentCenterPID()
        centerMonitorTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkCenterProcess()
        }
        RunLoop.main.add(timer, forMode: .common)
        centerMonitorTimer = timer
    }

    private func checkCenterProcess() {
        let pid = currentCenterPID()
        guard pid != 0, pid != lastCenterPID else { return }
        NSLog("[boringNotch] NotificationCenter restarted (pid \(lastCenterPID) -> \(pid)); re-attaching watcher")
        lastCenterPID = pid
        stop()
        start()
    }

    // MARK: - Health monitor

    /// Every minute, read an attribute through the live AX attachment. A
    /// wedged channel (stale mach port after sleep, revoked trust) answers
    /// with an error instead of data — tear down and re-arm immediately,
    /// without waiting for a missed notification to be noticed by hand.
    private func startHealthMonitor() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkAXHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func checkAXHealth() {
        guard let appElement else { return }
        guard AXIsProcessTrusted() else {
            NSLog("[boringNotch] health check: AX trust lost; resetting watcher")
            stop()
            return
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        )
        switch result {
        case .success, .noValue, .attributeUnsupported:
            // Channel alive; .noValue just means "no windows right now".
            break
        default:
            NSLog("[boringNotch] health check: AX channel unhealthy (rawValue \(result.rawValue)); re-arming watcher")
            stop()
            _ = start()
        }
    }

    /// Windows this watcher (or a previous, force-killed instance) parked at
    /// (-10000, -10000) would otherwise swallow every future banner: the
    /// system keeps rendering banners into the off-screen host window. The
    /// banner host is a full-screen-covering surface — put it back at (0, 0);
    /// anything else off-screen goes to the top-right corner where banners
    /// and the notification list normally live.
    private func restoreParkedOrphans() {
        guard let appElement else { return }
        guard let screen = NSScreen.main else { return }
        let screenWidth = screen.frame.width

        for window in (appElement[kAXWindowsAttribute] as? [AXUIElement]) ?? [] {
            guard let position = window.point(kAXPositionAttribute),
                  position.x <= -9000, position.y <= -9000 else { continue }
            // Parked by us on purpose — a re-arm must not give it back.
            guard !parkedWindows.values.contains(where: { CFEqual($0.window, window) }) else { continue }
            // This read used to go through `point(_:)`, which only accepts
            // CGPoint values — it always returned nil for a size, so orphan
            // repair silently did nothing. Now that it works, keep it from
            // resizing anything: a zero size just means "unknown", and the
            // window still has to be put back at (0, 0).
            let size = window.size(kAXSizeAttribute) ?? .zero

            var target: CGPoint
            if size.width >= screenWidth * 0.9 {
                target = CGPoint(x: 0, y: 0)
            } else {
                target = CGPoint(x: max(0, screenWidth - size.width), y: 8)
            }

            if let value = AXValueCreate(.cgPoint, &target),
               AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success {
                NSLog("[boringNotch] restored orphaned off-screen window \(Int(size.width))x\(Int(size.height)) to (\(Int(target.x)), \(Int(target.y)))")
            }
        }
    }

    private func addObserverNotifications(to element: AXUIElement) -> Bool {
        guard let observer = axObserver, let context = observerContext else { return false }
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        var registered = false
        for notification in NotificationObservationPolicy.structuralNotifications {
            let result = AXObserverAddNotification(
                observer,
                element,
                notification as CFString,
                refcon
            )
            if result == .success {
                registered = true
            }
        }
        return registered
    }

    private func removeObserverNotifications(from element: AXUIElement, observer: AXObserver) {
        for notification in NotificationObservationPolicy.structuralNotifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
    }

    private func refreshObservedWindows() {
        guard let appElement else { return }
        let windows = (appElement[kAXWindowsAttribute] as? [AXUIElement]) ?? []
        var current = Set<CFHashCode>()
        for window in windows {
            let subrole = window.string(kAXSubroleAttribute)
            let identifier = window.string(kAXIdentifierAttribute)
            guard NotificationObservationPolicy.shouldObserveElement(
                subrole: subrole,
                identifier: identifier
            ) else { continue }

            let key = CFHash(window)
            current.insert(key)
            guard observedWindows[key] == nil else { continue }
            _ = addObserverNotifications(to: window)
            observedWindows[key] = window
        }

        let stale = observedWindows.keys.filter { !current.contains($0) }
        for key in stale {
            if let window = observedWindows.removeValue(forKey: key) {
                if let observer = axObserver {
                    removeObserverNotifications(from: window, observer: observer)
                }
            }
        }
    }

    private func installObserver(for processIdentifier: pid_t) -> Bool {
        var observer: AXObserver?
        let result = AXObserverCreate(processIdentifier, { _, element, notification, refcon in
            guard let refcon else { return }
            let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            // Destroyed elements answer no attributes, and a move only needs
            // the element itself — skip the IPC for both.
            let skipAttributes = name == "AXUIElementDestroyed" || name == "AXWindowMoved"
            let subrole = skipAttributes ? nil : element.string(kAXSubroleAttribute)
            let identifier = skipAttributes ? nil : element.string(kAXIdentifierAttribute)
            let boxed = AXElementBox(element)
            DispatchQueue.main.async { [weak context] in
                context?.watcher?.handleObserverEvent(
                    notification: name,
                    element: boxed.element,
                    subrole: subrole,
                    identifier: identifier
                )
            }
        }, &observer)
        guard result == .success, let observer, let appElement else { return false }

        let context = ObserverContext()
        context.watcher = self
        observerContext = context
        axObserver = observer
        guard addObserverNotifications(to: appElement) else {
            axObserver = nil
            observerContext = nil
            return false
        }

        let runLoop = AXObserverRunLoop(observer: observer)
        guard runLoop.start() else {
            axObserver = nil
            observerContext = nil
            return false
        }
        observerRunLoop = runLoop
        return true
    }

    private func handleObserverEvent(
        notification: String,
        element: AXUIElement,
        subrole: String?,
        identifier: String?
    ) {
        trace("event \(notification) subrole=\(subrole ?? "-")")
        // NotificationCenter slid one of our parked windows back on screen.
        // Hide it again before anything else happens — the full scan below costs
        // dozens of AX round trips, and every one of them is time the banner is
        // being painted in front of the user.
        if notification == "AXWindowMoved" {
            repark(window: element)
        }

        guard NotificationObservationPolicy.shouldScan(
            notification: notification,
            subrole: subrole,
            identifier: identifier
        ) else { return }

        scheduleScan()
        scheduleSettleScan()
    }

    /// Re-park a single window without walking any tree. Cheap enough to run on
    /// every move event, which is what keeps the system popup off screen.
    private func repark(window: AXUIElement) {
        guard parkedWindows[key(for: window)] != nil else { return }
        _ = parkIfExposed(window)
    }

    private func scheduleSettleScan() {
        guard settleWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWorkItem = nil
            self.scan()
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
    }

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.scan()
        }
    }

    private func scan() {
        autoreleasepool {
            guard let appElement else { return }
            refreshObservedWindows()
            trace("scan begin")
            var seen = Set<String>()
            let windows = (appElement[kAXWindowsAttribute] as? [AXUIElement]) ?? []

            for window in windows {
                switch inspect(window) {
                case .panel:
                    // The notification list, the stack and the desktop widgets
                    // have to stay on screen — a parked window here means the
                    // user opens Notification Center onto nothing (upstream
                    // issue #1577).
                    restoreWindow(window)

                case .empty:
                    // Deliberately nothing to the window. A window that no
                    // longer holds a banner is the next banner's host, so it
                    // must stay parked: that is what stops the system popup from
                    // being painted on screen at all.
                    unmirroredWindows.remove(key(for: window))

                case .banners(let banners):
                    let windowKey = key(for: window)
                    // A banner we deliberately leave to the system is visible on
                    // purpose — parking it again would only make it oscillate.
                    if unmirroredWindows.contains(windowKey) {
                        for banner in banners { seen.insert(token(for: banner)) }
                        continue
                    }

                    // Hide first, describe later. `capture` walks the banner's
                    // AX tree and resolves the source app (disk I/O); the window
                    // must not stay on screen for any of that.
                    let wasParked = ensureParked(window)

                    var allowed: [String] = []
                    var arrivals: [(token: String, notification: CapturedNotification)] = []
                    var needsNative = false

                    for banner in banners {
                        let token = token(for: banner)
                        seen.insert(token)
                        // Already mirrored: don't pay for another AX text walk.
                        if liveTokens.contains(token) {
                            allowed.append(token)
                            continue
                        }
                        let notification = capture(banner, token: token)
                        guard mirrorAllApps || isAllowed(notification) else { continue }
                        // The banner wants typing (reply / 回复). Mirroring it
                        // would take away the only way to answer, so hand the
                        // whole window back and let the system own it.
                        if passthroughInteractive, notification.needsNativeInteraction {
                            trace("passthrough token=\(token) actions=\(notification.actions.map(\.title))")
                            needsNative = true
                            break
                        }
                        allowed.append(token)
                        arrivals.append((token, notification))
                        bannerElements[token] = banner
                        bannerWindows[token] = windowKey
                    }

                    if needsNative {
                        if wasParked { restoreWindow(window) }
                        unmirroredWindows.insert(windowKey)
                        // Anything we staged for this window is moot now.
                        for banner in banners {
                            let token = token(for: banner)
                            bannerElements.removeValue(forKey: token)
                            bannerWindows.removeValue(forKey: token)
                        }
                        continue
                    }

                    guard let first = allowed.first else {
                        // Nothing here is mirrored (app not on the allow list),
                        // so the system banner is the only channel the user has
                        // — give the window back instead of swallowing it.
                        if wasParked { restoreWindow(window) }
                        unmirroredWindows.insert(windowKey)
                        continue
                    }

                    guard wasParked else {
                        NSLog("[boringNotch] could not hide notification banner \(first)")
                        continue
                    }
                    for arrival in arrivals {
                        liveTokens.insert(arrival.token)
                        onBanner?(arrival.notification)
                    }
                }
            }

            liveTokens.formIntersection(seen)
            bannerElements = bannerElements.filter { seen.contains($0.key) }
            bannerWindows = bannerWindows.filter { seen.contains($0.key) }
            // Forget windows NotificationCenter destroyed, or the parked list
            // grows for the lifetime of the helper.
            let liveKeys = Set(windows.map { key(for: $0) })
            parkedWindows = parkedWindows.filter { liveKeys.contains($0.key) }
            unmirroredWindows.formIntersection(liveKeys)
            trace("scan end parked=\(parkedWindows.count) live=\(liveTokens.count)")
        }
    }

    private enum WindowContents {
        case panel
        case empty
        case banners([AXUIElement])
    }

    private func inspect(_ root: AXUIElement) -> WindowContents {
        var pending: [(element: AXUIElement, insideBanner: Bool, insideList: Bool)] = [
            (root, false, false)
        ]
        var visited = Set<CFHashCode>()
        var banners: [AXUIElement] = []

        while let node = pending.popLast() {
            let element = node.element
            guard visited.insert(CFHash(element)).inserted else { continue }
            // An unreadable tree tells us nothing; leaving the window where it
            // is beats acting on a guess.
            guard visited.count <= maxAccessibilityNodes else { return .empty }

            let subrole = element.string(kAXSubroleAttribute)
            let identifier = element.string(kAXIdentifierAttribute)
            let stackingIdentifier = node.insideList && subrole == "AXButton"
                ? element.string(stackingIdentifierAttribute)
                : nil
            if NotificationPanelDetection.isPanel(
                subrole: subrole,
                identifier: identifier,
                stackingIdentifier: stackingIdentifier,
                insideNotificationList: node.insideList && !node.insideBanner
            ) || NotificationPanelDetection.isDesktopWidget(identifier: identifier) {
                return .panel
            }

            if !node.insideBanner, NotificationPanelDetection.isBanner(subrole: subrole) {
                banners.append(element)
            }

            let childInsideBanner = node.insideBanner || NotificationPanelDetection.isBanner(subrole: subrole)
            let childInsideList = node.insideList
                || identifier == NotificationPanelDetection.panelListIdentifier
            pending.append(contentsOf: element.children().reversed().map {
                ($0, childInsideBanner, childInsideList)
            })
        }

        return banners.isEmpty ? .empty : .banners(banners)
    }

    private func token(for banner: AXUIElement) -> String {
        if let identifier = banner.string(kAXIdentifierAttribute),
           !identifier.isEmpty,
           !structuralIdentifiers.contains(identifier) {
            return identifier
        }
        if let stackingIdentifier = banner.string(stackingIdentifierAttribute),
           !stackingIdentifier.isEmpty {
            return stackingIdentifier
        }

        return "ax-\(CFHash(banner))"
    }

    private func key(for window: AXUIElement) -> Int {
        Int(bitPattern: CFHash(window))
    }

    /// Park the window and remember where it came from, or — for a window that
    /// is already parked — put it back off-screen if something moved it.
    ///
    /// NotificationCenter moves its banner host around on its own (a new banner
    /// arriving, the stack re-laying out, the connection being re-established),
    /// and a moved-back window is a banner the user can see. Checking on every
    /// scan is cheap: one attribute read.
    private func ensureParked(_ window: AXUIElement) -> Bool {
        let key = key(for: window)

        if parkedWindows[key] != nil {
            return parkIfExposed(window)
        }

        guard let origin = window.point(kAXPositionAttribute) else { return false }
        parkedWindows[key] = (window, origin)
        guard hide(window) else {
            parkedWindows.removeValue(forKey: key)
            return false
        }
        return true
    }

    @discardableResult
    private func parkIfExposed(_ window: AXUIElement) -> Bool {
        guard let position = window.point(kAXPositionAttribute),
              position.x > Self.hiddenOrigin.x else { return true }
        trace("exposed at x=\(Int(position.x)); re-parking")
        return hide(window)
    }

    /// Moving the window off-screen is all we can do, and it is done as early as
    /// possible: on the very move event NotificationCenter emits when it slides
    /// the host back for a banner, and again on every scan.
    ///
    /// The residual is NotificationCenter's own latency — it honours the AX
    /// write ~15-25 ms after it has already started presenting (measured), so a
    /// couple of frames of a barely-faded banner can still be on screen. Clipping
    /// the window to 1×1 would remove even those, but `AXSize` is rejected on
    /// these windows (`AXUIElementSetAttributeValue` returns false).
    @discardableResult
    private func hide(_ window: AXUIElement) -> Bool {
        var hidden = Self.hiddenOrigin
        guard let value = AXValueCreate(.cgPoint, &hidden) else { return false }
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
        trace("hide move=\(moved)")
        return moved
    }

    private static let hiddenOrigin = CGPoint(x: -10000, y: -10000)

    private func restoreWindow(_ window: AXUIElement) {
        guard let parked = parkedWindows.removeValue(forKey: key(for: window)) else { return }
        giveBack(parked)
    }

    private func restoreAllWindows() {
        for parked in parkedWindows.values {
            giveBack(parked)
        }
        parkedWindows.removeAll()
    }

    private func giveBack(_ parked: (window: AXUIElement, origin: CGPoint)) {
        var origin = parked.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(parked.window, kAXPositionAttribute as CFString, value)
        }
    }

    private func capture(_ banner: AXUIElement, token: String) -> CapturedNotification {
        let parts = collectText(in: banner)
        let appName = resolveAppName(banner)
        let actions = captureActions(in: banner)
        dumpAXTreeIfNeeded(banner, token: token, appName: appName, parts: parts, actions: actions)

        return CapturedNotification(
            token: token,
            appName: appName,
            bundleID: appName.flatMap(bundleID(forAppNamed:)),
            title: parts["title"],
            subtitle: parts["subtitle"],
            body: parts["body"],
            actions: actions
        )
    }

    // MARK: - Banner actions

    /// Actions whose label reads like a keyboard is needed ("Reply", "回复").
    /// These are never mirrored — the text field they open lives inside the
    /// parked banner, so the user would be typing into something invisible.
    fileprivate static let textEntryKeywords = ["回复", "回覆", "reply", "回答"]

    /// Sources whose notifications must go back to the real banner: a call that
    /// is only mirrored is a call the user cannot answer, and it expires in
    /// seconds — there is no time to reach for a fallback button.
    fileprivate static let callKeywords = [
        "facetime", "来电", "通话", "incoming call", "phone call"
    ]

    /// Actions that only duplicate something the notch already offers (tapping
    /// the card opens the app, the ✕ dismisses). Matched exactly, so an action
    /// like "Accept & Open" is never swallowed.
    fileprivate static let redundantActionTitles: Set<String> = [
        "关闭", "close", "dismiss", "清除", "clear",
        "显示", "show", "显示详细信息", "show details", "打开", "open"
    ]

    /// Reads the banner's own action list.
    ///
    /// A macOS banner exposes its buttons as accessibility *custom actions*, not
    /// as child elements, and it does so even while unexpanded — measured on a
    /// parked banner: `["AXPress", "Name:显示详细信息\\n…", "Name:显示\\n…",
    /// "Name:关闭\\n…"]`. Performing the short name succeeds off-screen, which
    /// is what makes a mirrored "Accept"/"Decline" button real rather than
    /// decorative.
    private func captureActions(in banner: AXUIElement) -> [CapturedNotificationAction] {
        Self.actionTitles(of: banner).enumerated().map { index, title in
            CapturedNotificationAction(index: index, title: title)
        }
    }

    static func actionTitles(of banner: AXUIElement) -> [String] {
        var titles: [String] = []
        for name in rawActionNames(of: banner) {
            guard let title = displayTitle(forAction: name) else { continue }
            guard !redundantActionTitles.contains(title.lowercased()) else { continue }
            // "Reply" opens a text field *inside the banner* — which is parked
            // off screen. Offering it would put the caret somewhere the user
            // cannot see. The card's "show the real banner" covers this case.
            guard !textEntryKeywords.contains(where: {
                title.localizedCaseInsensitiveContains($0)
            }) else { continue }
            guard !titles.contains(title) else { continue }
            titles.append(title)
            if titles.count == 3 { break }
        }
        return titles
    }

    /// Untouched action names, for the diagnostic dump: when a call banner
    /// behaves unexpectedly this is the only record of what the system offered.
    static func rawActionNames(of banner: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(banner, &names) == .success,
              let raw = names as? [String] else { return [] }
        return raw
    }

    /// `Name:显示\nTarget:0x0\nSelector:(null)` → `显示`. Standard actions
    /// (`AXPress` and friends) return nil: tapping the card already covers them.
    private static func displayTitle(forAction name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("AX") else { return nil }
        let core = trimmed.components(separatedBy: "Name:").last ?? trimmed
        let title = core.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, title.count <= 30 else { return nil }
        return title
    }

    /// Perform one of the banner's own actions, matched by the title the user
    /// tapped. The banner lives off-screen, and `AXUIElementPerformAction` does
    /// not care where a window is drawn — verified before this was written.
    ///
    /// If the system refuses anyway, the window is handed straight back to the
    /// screen: the user must never lose the ability to answer.
    @discardableResult
    func performAction(token: String, title: String) -> Bool {
        guard let banner = bannerElements[token] else {
            NSLog("[boringNotch] action '\(title)' for \(token): banner is gone")
            return restoreForFailedAction(token)
        }

        let result = AXUIElementPerformAction(banner, title as CFString)
        trace("perform '\(title)' token=\(token) result=\(result.rawValue)")
        NSLog("[boringNotch] perform '\(title)' on \(token) -> \(result.rawValue)")
        guard result == .success else {
            NSLog("[boringNotch] action refused — handing banner back to the screen")
            return restoreForFailedAction(token)
        }
        return true
    }

    /// Give the banner's window back so the user can finish the interaction on
    /// the real banner. The window is also blacklisted from mirroring, or the
    /// next scan would hide it again and the fallback would never stick.
    @discardableResult
    private func restoreForFailedAction(_ token: String) -> Bool {
        _ = revealToken(token)
        return false
    }

    /// Hand a mirrored banner back to the screen and stop mirroring its window.
    ///
    /// This is the escape hatch for everything the notch cannot do: a button
    /// that refused the press, a notification that only makes sense with a
    /// keyboard, and whatever the user explicitly asks to see in place. Once
    /// revealed, the window stays out of the mirror list so the next scan does
    /// not hide it again.
    @discardableResult
    func revealNotification(token: String) -> Bool {
        revealToken(token)
    }

    @discardableResult
    private func revealToken(_ token: String) -> Bool {
        guard let windowKey = bannerWindows[token],
              let appElement,
              let window = ((appElement[kAXWindowsAttribute] as? [AXUIElement]) ?? [])
                .first(where: { key(for: $0) == windowKey })
        else { return false }

        restoreWindow(window)
        unmirroredWindows.insert(windowKey)
        liveTokens.remove(token)
        trace("revealed \(token)")
        return true
    }

    /// The app name used to come exclusively from the banner's
    /// `AXAttributedDescription` ("App, 2 new messages"). macOS 27 no longer
    /// exposes it on every banner, which left the peek with no icon and no
    /// text at all, so walk a few fallbacks before giving up.
    private func resolveAppName(_ banner: AXUIElement) -> String? {
        if let description = Self.attributedDescription(of: banner),
           let name = splitAppName(fromDescription: description) {
            return name
        }

        // The same attribute sometimes lives on a child element instead.
        for element in descendants(of: banner) {
            if let description = Self.attributedDescription(of: element),
               let name = splitAppName(fromDescription: description) {
                return name
            }
        }

        // Last resort: a short description/title that reads like an app name.
        for element in [banner] + descendants(of: banner) {
            for attribute in ["AXDescription", "AXLabel", "AXTitle"] {
                guard let raw = element[attribute] as? String else { continue }
                let value = Self.cleanedAppName(raw)
                guard !value.isEmpty, value.count <= 24, !value.contains("\n") else { continue }
                if bundleID(forAppNamed: value) != nil { return value }
            }
        }

        return nil
    }

    private static func attributedDescription(of element: AXUIElement) -> String? {
        if let text = (element["AXAttributedDescription"] as? NSAttributedString)?.string,
           !text.isEmpty {
            return text
        }
        if let text = element["AXAttributedDescription"] as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    /// The banner description packs everything into one string and the
    /// separators differ per app and per language:
    ///
    ///   "脚本编辑器 李老师, 微信, 晚上七点半…"          ← space between app and title
    ///   "WorkBuddy，任务已完成, 修复…，来自iPhone"      ← full-width comma instead
    ///
    /// Fields are split on the ASCII comma first, then the app name is taken
    /// from the head of that first field either at a full-width comma or — for
    /// names containing spaces — at the longest prefix that resolves to a real
    /// app.
    private func splitAppName(fromDescription raw: String) -> String? {
        let field = raw.components(separatedBy: ",").first ?? raw
        let head = field.components(separatedBy: "，").first ?? field
        let cleaned = Self.cleanedAppName(head)
        guard !cleaned.isEmpty else { return nil }

        if bundleID(forAppNamed: cleaned) != nil { return cleaned }

        let words = cleaned.split(separator: " ").map(String.init)
        guard words.count > 1 else { return cleaned }

        for count in stride(from: words.count - 1, through: 1, by: -1) {
            let candidate = words.prefix(count).joined(separator: " ")
            if bundleID(forAppNamed: candidate) != nil { return candidate }
        }

        // Nothing resolved. The head is then most likely "<app> <title>"
        // concatenated with no app we can find ("脚本编辑器 李老师"), so show
        // the first word rather than the whole run-on string.
        return words.first ?? cleaned
    }

    private func descendants(of root: AXUIElement, limit: Int = 512) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var pending = root.children()
        var visited = Set<CFHashCode>()
        while let element = pending.popLast() {
            guard visited.insert(CFHash(element)).inserted, out.count < limit else { continue }
            out.append(element)
            pending.append(contentsOf: element.children().reversed())
        }
        return out
    }

    /// Dumps what the system actually hands us for a banner, so the next
    /// release can target the real attribute names instead of guessing.
    private func dumpAXTreeIfNeeded(
        _ banner: AXUIElement,
        token: String,
        appName: String?,
        parts: [String: String],
        actions: [CapturedNotificationAction]
    ) {
        guard axDumpCount < 5 else { return }
        axDumpCount += 1

        let actionSummary = actions.map { "\($0.index):\($0.title)" }.joined(separator: "|")
        let rawSummary = Self.rawActionNames(of: banner)
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: " / ")
        var lines: [String] = [
            "token=\(token) appName=\(appName ?? "nil") title=\(parts["title"] ?? "nil") subtitle=\(parts["subtitle"] ?? "nil") body=\(parts["body"] ?? "nil") actions=[\(actionSummary)] rawActions=[\(rawSummary)]"
        ]
        appendDump(of: banner, depth: 0, into: &lines)

        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let name = "axdump-\(formatter.string(from: Date()))-\(token.prefix(6)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NSLog("[boringNotch] AX dump written to \(url.path)")
    }

    private func appendDump(of element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth < 9, lines.count < 600 else { return }

        var names: CFArray?
        let attributeNames = AXUIElementCopyAttributeNames(element, &names) == .success
            ? (names as? [String] ?? [])
            : []

        var fields: [String] = []
        for name in attributeNames {
            guard !["AXChildren", "AXParent", "AXWindow", "AXTopLevelUIElement"].contains(name) else { continue }
            guard let value = element[name] else { continue }
            if value is [AXUIElement] { continue }
            let text = String(describing: value)
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(90)
            fields.append("\(name)=\(text)")
        }

        lines.append(String(repeating: "· ", count: depth) + fields.joined(separator: " | "))
        for child in element.children() {
            appendDump(of: child, depth: depth + 1, into: &lines)
        }
    }

    private func collectText(in root: AXUIElement) -> [String: String] {
        var parts: [String: String] = [:]
        var pending = [root]
        var visited = Set<CFHashCode>()

        while let element = pending.popLast() {
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxTextNodes else { break }

            if let identifier = element.string(kAXIdentifierAttribute),
               let value = element[kAXValueAttribute] as? String {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                switch identifier {
                case "title":
                    parts["title"] = value
                case "header" where parts["title"] == nil:
                    parts["title"] = value
                case "subtitle":
                    parts["subtitle"] = value
                case "body":
                    parts["body"] = value
                default:
                    break
                }
            }

            pending.append(contentsOf: element.children().reversed())
        }

        return parts
    }

    private func bundleID(forAppNamed name: String) -> String? {
        let target = Self.normalizedAppName(name)
        guard !target.isEmpty else { return nil }
        if let cached = bundleIDCache[target] { return cached }

        let running = NSWorkspace.shared.runningApplications
            .filter {
                guard let localizedName = $0.localizedName else { return false }
                return Self.normalizedAppName(localizedName) == target
            }
            .sorted(by: Self.preferRegularApplication)
            .compactMap { $0.bundleIdentifier }
            .first

        if let resolved = resolveBundleID(
            forRunningBundleID: running,
            appName: name,
            target: target
        ) {
            bundleIDCache[target] = resolved
            return resolved
        }
        return nil
    }

    private func resolveBundleID(
        forRunningBundleID runningBundleID: String?,
        appName: String,
        target: String
    ) -> String? {
        if let runningBundleID {
            return normalizedBundleIdentifier(runningBundleID)
        }

        let displayName = Self.cleanedAppName(appName)
        let withoutSpaces = displayName.replacingOccurrences(of: " ", with: "")
        let filenameCandidates = withoutSpaces == displayName
            ? [displayName]
            : [displayName, withoutSpaces]
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/Applications/Utilities")
        ]

        for directory in directories {
            for candidate in filenameCandidates where !candidate.isEmpty {
                let appURL = directory.appendingPathComponent(candidate).appendingPathExtension("app")
                if let bundleID = bundleIdentifier(at: appURL) {
                    return normalizedBundleIdentifier(bundleID)
                }
            }
        }

        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier else { continue }
                let names = [
                    entry.deletingPathExtension().lastPathComponent,
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ] + Self.localizedBundleNames(bundle)
                if names.contains(where: { name in
                    guard let name else { return false }
                    return Self.normalizedAppName(name) == target
                }) {
                    return normalizedBundleIdentifier(bundleID)
                }
            }
        }
        return nil
    }

    private func bundleIdentifier(at appURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    /// The name people see is localized ("脚本编辑器" for Script Editor) while
    /// the bundle only carries the English string, so check the localized
    /// InfoPlist.strings before giving up on a match.
    private static func localizedBundleNames(_ bundle: Bundle) -> [String] {
        let languages = bundle.localizations.filter { $0.hasPrefix("zh") } + ["en", "Base"]
        var names: [String] = []
        for language in languages {
            guard let url = bundle.url(
                forResource: "InfoPlist",
                withExtension: "strings",
                subdirectory: nil,
                localization: language
            ),
                let strings = NSDictionary(contentsOf: url) as? [String: String]
            else { continue }
            if let name = strings["CFBundleDisplayName"] ?? strings["CFBundleName"], !name.isEmpty {
                names.append(name)
            }
        }
        return names
    }

    private func normalizedBundleIdentifier(_ bundleID: String) -> String {
        let lower = bundleID.lowercased()
        if lower.hasPrefix("com.apple.safaritechnologypreview.") {
            return "com.apple.SafariTechnologyPreview"
        }
        if lower.hasPrefix("com.apple.webkit.") || lower.hasPrefix("com.apple.safari.") {
            return "com.apple.Safari"
        }
        let components = bundleID.components(separatedBy: ".")
        if let helperIndex = components.firstIndex(where: { $0.lowercased() == "helper" }) {
            return components[0..<helperIndex].joined(separator: ".")
        }
        return bundleID
    }

    private static func normalizedAppName(_ name: String) -> String {
        cleanedAppName(name).lowercased()
    }

    private static func cleanedAppName(_ name: String) -> String {
        name.filter { !$0.unicodeScalars.allSatisfy(bidiControlCharacters.contains) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let bidiControlCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\u{200E}\u{200F}")
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")
        return set
    }()

    private static func preferRegularApplication(
        _ lhs: NSRunningApplication,
        _ rhs: NSRunningApplication
    ) -> Bool {
        if lhs.activationPolicy == .regular, rhs.activationPolicy != .regular {
            return true
        }
        if rhs.activationPolicy == .regular, lhs.activationPolicy != .regular {
            return false
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    private func isAllowed(_ notification: CapturedNotification) -> Bool {
        if let bundleID = notification.bundleID {
            return allowedBundleIDs.contains(bundleID)
        }
        guard let appName = notification.appName?.lowercased(), !appName.isEmpty else {
            return false
        }
        return allowedBundleIDs.contains { bundleID in
            guard let lastComponent = bundleID.split(separator: ".").last else { return false }
            return Self.normalizedAppName(appName) == Self.normalizedAppName(String(lastComponent))
        }
    }
}

private final class AXObserverRunLoop {
    private let observer: AXObserver
    private let ready = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    init(observer: AXObserver) {
        self.observer = observer
    }

    func start() -> Bool {
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(
                runLoop,
                AXObserverGetRunLoopSource(self.observer),
                .defaultMode
            )
            self.ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(
                runLoop,
                AXObserverGetRunLoopSource(self.observer),
                .defaultMode
            )
        }
        self.thread = thread
        thread.start()
        return ready.wait(timeout: .now() + 1) == .success
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
        thread = nil
        self.runLoop = nil
    }
}
