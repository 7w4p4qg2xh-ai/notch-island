//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import AppKit
import ApplicationServices
import IOKit

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    private weak var connection: NSXPCConnection?

    private let lunarStateQueue = DispatchQueue(label: "BoringNotchXPCHelper.lunar.state")
    private let lunarExecutableURL = URL(fileURLWithPath: "/Applications/Lunar.app/Contents/MacOS/Lunar")
    private var lunarProcess: Process?
    private var lunarPipeHandler: JSONLinesPipeHandler?
    private var lunarStreamTask: Task<Void, Never>?
    private var lunarListener: BoringNotchXPCHelperLunarListener?

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    override init() {
        super.init()
    }

    deinit {
        var processToTerminate: Process?
        var taskToCancel: Task<Void, Never>?
        var pipeHandlerToClose: JSONLinesPipeHandler?

        lunarStateQueue.sync {
            processToTerminate = self.lunarProcess
            self.lunarProcess = nil

            taskToCancel = self.lunarStreamTask
            self.lunarStreamTask = nil

            pipeHandlerToClose = self.lunarPipeHandler
            self.lunarPipeHandler = nil

            self.lunarListener = nil
        }

        taskToCancel?.cancel()
        if let p = processToTerminate, p.isRunning { p.terminate() }
        if let ph = pipeHandlerToClose {
            Task { await ph.close() }
        }
    }

    /// 只弹一次系统权限对话框。主 app 会周期性轮询这个方法探测授权状态，
    /// 每次都带 prompt 会连续弹窗。
    private static var didPromptForAccessibility = false

    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        let trusted = AXIsProcessTrusted()
        // 未授权时用带 prompt 的版本请求一次。只有它会把这个 helper 放进
        // 「隐私与安全性 → 辅助功能」列表；不带 prompt 的 AXIsProcessTrusted()
        // 仅查询状态，而 TCC 不会展示从未请求过该权限的进程，用户只能在
        // 列表里手动点 + 添加——2026-11-09 实测就是这个坑。
        if !trusted, !Self.didPromptForAccessibility {
            Self.didPromptForAccessibility = true
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        reply(trusted)
    }

    @objc func migrateLegacyAppBundle(
        from sourcePath: String,
        to destinationPath: String,
        with reply: @escaping (Bool) -> Void
    ) {
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let fileManager = FileManager.default

        guard sourceURL.lastPathComponent == BoringNotchAppBundleNames.legacy,
              destinationURL.lastPathComponent == BoringNotchAppBundleNames.current,
              sourceURL.deletingLastPathComponent() == destinationURL.deletingLastPathComponent(),
              fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path)
        else {
            NSLog("[boringNotch] refused legacy bundle migration for %@ -> %@", sourcePath, destinationPath)
            reply(false)
            return
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            NSWorkspace.shared.noteFileSystemChanged(destinationURL.deletingLastPathComponent().path)
            reply(true)
        } catch {
            NSLog("[boringNotch] legacy bundle migration failed for %@: %@", sourcePath, error.localizedDescription)
            reply(false)
        }
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        guard promptIfNeeded else {
            reply(false)
            return
        }

        requestAccessibilityAuthorization()

        let deadline = DispatchTime.now() + .seconds(15)
        func waitForAuthorization() {
            if AXIsProcessTrusted() {
                reply(true)
            } else if DispatchTime.now() >= deadline {
                reply(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    waitForAuthorization()
                }
            }
        }
        waitForAuthorization()
    }

    // MARK: - Notification Center banners

    private static let watcher = NotificationWatcher()

    /// The app went away without calling `stopNotificationWatching` — force
    /// quit, crash, or a dropped connection. The banner windows have to go back
    /// on screen, otherwise the system keeps painting every notification into
    /// an off-screen window and the user sees none of them (issue #1577).
    static func handleClientDisconnect() {
        DispatchQueue.main.async { watcher.stopWatching() }
    }

    @objc func startNotificationWatching(with reply: @escaping (Bool) -> Void) {
        // Capture the delegate for this connection before hopping queues —
        // NSXPCConnection.current() is only valid inside the incoming call.
        //
        // Cast to BoringNotchXPCAppDelegate, not its parent protocol: the
        // proxy's conformance is built from the exact interface the
        // connection was configured with, so casting to the parent can
        // return nil and silently swallow every callback.
        let connection = NSXPCConnection.current()
        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            NSLog("[boringNotch] notification callback failed: \(error.localizedDescription)")
        }
        let delegate = proxy as? BoringNotchXPCAppDelegate

        if delegate == nil {
            NSLog("[boringNotch] could not obtain notification delegate proxy — banners will not reach the app")
        }

        DispatchQueue.main.async {
            let watcher = Self.watcher
            watcher.onBanner = { notification in
                delegate?.notificationDidAppear([
                    "token": notification.token,
                    "appName": notification.appName ?? "",
                    "bundleID": notification.bundleID ?? "",
                    "title": notification.title ?? "",
                    "subtitle": notification.subtitle ?? "",
                    "body": notification.body ?? "",
                    // The XPC dictionary is [String: String]; the button list
                    // travels as JSON so the app can draw real controls.
                    "actions": Self.encodeActions(notification.actions)
                ])
            }
            let started = watcher.start()
            NSLog("[boringNotch] notification watcher start -> \(started), AX trusted: \(AXIsProcessTrusted())")
            reply(started)
        }
    }

    private static func encodeActions(_ actions: [CapturedNotificationAction]) -> String {
        guard !actions.isEmpty,
              let data = try? JSONEncoder().encode(actions),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }

    /// Perform one of the banner's own actions (the title the user tapped in
    /// the notch). The banner is off-screen, so this is the only path that keeps
    /// its actions usable.
    @objc func performNotificationAction(
        _ token: String,
        actionTitle: String,
        with reply: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            reply(Self.watcher.performAction(token: token, title: actionTitle))
        }
    }

    @objc func setNotificationPassthrough(_ enabled: Bool) {
        DispatchQueue.main.async {
            Self.watcher.configureInteractionPassthrough(enabled)
        }
    }

    /// Siri 面板开着时不给宿主窗口停泊 —— 面板的位置算在宿主 origin 上，
    /// 宿主飞出屏幕 Siri 就没有可见窗口了。检测在 app 侧做（helper 沙盒里
    /// `CGWindowListCopyWindowInfo` 返回 nil）。
    @objc func setSiriYield(_ yielding: Bool) {
        DispatchQueue.main.async {
            Self.watcher.setSiriYield(yielding)
        }
    }

    /// Put a mirrored banner back on screen, e.g. when the user asks for the
    /// real one because the notch cannot finish the interaction.
    @objc func revealNotification(_ token: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            reply(Self.watcher.revealNotification(token: token))
        }
    }

    /// Clear the banner out of Notification Center ("全部清除") — the notch
    /// card's ✕ button.
    @objc func clearNotificationBanner(_ token: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            reply(Self.watcher.clearNotificationBanner(token: token))
        }
    }

    @objc func stopNotificationWatching() {
        DispatchQueue.main.async { Self.watcher.stopWatching() }
    }

    @objc func setNotificationFilter(_ bundleIDs: [String], allApps: Bool) {
        DispatchQueue.main.async {
            Self.watcher.configureFilter(bundleIDs: Set(bundleIDs), allApps: allApps)
        }
    }
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    private func brightnessDisplayID() -> CGDirectDisplayID {
        let mainDisplayID = CGMainDisplayID()
        var tmp: Float = 0

        if displayServicesGetBrightness(displayID: mainDisplayID, out: &tmp) || ioServiceFor(displayID: mainDisplayID) != nil {
            return mainDisplayID
        }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        let allocated = Int(count)
        var ids = [CGDirectDisplayID](repeating: 0, count: allocated)
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids {
            if CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }

        return mainDisplayID
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        var b: Float = 0
        // DisplayServices reports success but answers -1.0 on third-party panels
        // it cannot read; that value must never reach the OSD (it used to become
        // the starting point of the HUD number).
        if displayServicesGetBrightness(displayID: displayID, out: &b), (0...1).contains(b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var level: Float = 0
            let ok = IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess
            IOObjectRelease(io)
            if ok, (0...1).contains(level) {
                reply(NSNumber(value: level))
                return
            }
        }
        // External panel: fall back to DDC so the OSD opens on the real value
        // (virtual scale — gamma dim below DDC 0 included).
        if CGDisplayIsBuiltin(displayID) == 0,
           let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let uuid = CFUUIDCreateString(nil, uuidRef.takeRetainedValue()) as String
            if let m1ddc = Self.m1ddcURL, let value = Self.currentVirtual(m1ddc: m1ddc, uuid: uuid) {
                reply(NSNumber(value: value))
                return
            }
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightness(displayID: displayID, value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    @objc func adjustScreenBrightness(by value: Float, with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        // 11-15 23:32：`DisplayServicesSetBrightnessSmooth` 要的是**绝对亮度**（0…1），
        // 不是增量。这里原先直接把 ±1/16 的 delta 传进去，等于每按一次都把屏幕
        // 设成 6%（或负数被 clamp 到 0），用户按「加亮度」看到的是屏幕变暗。
        // 这条分支以前从没真正跑过——亮度键在 macOS 27 上收不到，也就没人踩到。
        // 现在先读当前值、加上增量、再设绝对目标。
        var current: Float = 0
        // Validate the reading: a -1.0 answer would turn into "set brightness 0".
        if displayServicesGetBrightness(displayID: displayID, out: &current), (0...1).contains(current) {
            let target = max(0, min(1, current + value))
            // 23:34 实测：macOS 27 上 `DisplayServicesSetBrightnessSmooth` 是
            // 空操作——rc=0 但亮度纹丝不动（0.60、0.35 都试过，读回仍是 1.0），
            // 只有非 Smooth 的 `DisplayServicesSetBrightness` 真生效（0.90 → 0.9）。
            // 所以这里必须用非 Smooth 版本，代价是没有系统那种渐变动画。
            if displayServicesSetBrightness(displayID: displayID, value: target) {
                // Read back inside the helper so the client pays for one RPC
                // instead of two (adjust + currentScreenBrightness).
                var b: Float = 0
                if displayServicesGetBrightness(displayID: displayID, out: &b) {
                    reply(NSNumber(value: b))
                    return
                }
                reply(NSNumber(value: target))
                return
            }
        }
        if let io = ioServiceFor(displayID: displayID) {
            var ioCurrent: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &ioCurrent) == kIOReturnSuccess {
                let target = max(0, min(1, ioCurrent + value))
                let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, target) == kIOReturnSuccess
                IOObjectRelease(io)
                reply(ok ? NSNumber(value: target) : nil)
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    /// Per-display brightness adjustment for the focus-screen F1/F2 path.
    /// Built-in panel: DisplayServices/IOKit with a 0...1 scale.
    /// External panel: DDC via `m1ddc` with a 0...100 scale, addressed by CG display UUID.
    /// This helper is unsandboxed so it can launch the m1ddc binary.
    @objc func adjustBrightness(displayID: NSNumber, delta: Float, with reply: @escaping (NSNumber?) -> Void) {
        let targetID = CGDirectDisplayID(displayID.uint32Value)
        Self.ddcTrace("adjust id=\(targetID) builtin=\(CGDisplayIsBuiltin(targetID)) delta=\(delta)")
        if CGDisplayIsBuiltin(targetID) != 0 {
            var current: Float = 0
            if displayServicesGetBrightness(displayID: targetID, out: &current), current >= 0 {
                let next = max(0, min(1, current + delta))
                if displayServicesSetBrightness(displayID: targetID, value: next) {
                    var readBack: Float = next
                    if displayServicesGetBrightness(displayID: targetID, out: &readBack) {
                        reply(NSNumber(value: readBack))
                    } else {
                        reply(NSNumber(value: next))
                    }
                    return
                }
            }
            if let io = ioServiceFor(displayID: targetID) {
                var ioCurrent: Float = 0
                if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &ioCurrent) == kIOReturnSuccess {
                    let next = max(0, min(1, ioCurrent + delta))
                    let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, next) == kIOReturnSuccess
                    IOObjectRelease(io)
                    reply(ok ? NSNumber(value: next) : nil)
                    return
                }
                IOObjectRelease(io)
            }
            reply(nil)
            return
        }

        // External display: DDC. The virtual value (0...1) is what the OSD and
        // the app see; its bottom `gammaZone` maps to "DDC 0 + gamma dimming",
        // so the keyboard can go darker than DDC 0 — matching what MonitorControl
        // achieves with its software (gamma) dimming on this panel.
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(targetID) else {
            reply(nil)
            return
        }
        let uuid = CFUUIDCreateString(nil, uuidRef.takeRetainedValue()) as String
        guard let m1ddc = Self.m1ddcURL else {
            NSLog("[brightness] m1ddc not found; cannot adjust external display \(uuid)")
            reply(nil)
            return
        }
        // DDC on this panel is asymmetric: an absolute `set` costs ~76 ms, while
        // `chg` (read current, then write) costs ~125 ms — and worse, the read
        // inside `chg` intermittently answers garbage (2809), which m1ddc then
        // writes straight back, so the panel jumps to 100% ("Writing 2808").
        // Keep an absolute value cache and always write with `set`.
        guard let current = Self.currentVirtual(m1ddc: m1ddc, uuid: uuid) else {
            NSLog("[brightness] could not read DDC luminance for \(uuid)")
            reply(nil)
            return
        }
        let target = max(0, min(1, current + delta))
        let ddcTarget = Self.ddcTarget(forVirtual: target)
        Self.ddcTrace(String(format: "ddc uuid=%@ current=%.3f step=%.3f target=%.3f ddc=%d", uuid, current, delta, target, ddcTarget))
        guard Self.runM1ddc(m1ddc, args: ["display", uuid, "set", "luminance", String(ddcTarget)]) != nil else {
            NSLog("[brightness] m1ddc set luminance \(ddcTarget) failed")
            Self.ddcTrace("ddc set FAILED target=\(ddcTarget)")
            reply(nil)
            return
        }
        Self.storeVirtual(target, uuid: uuid)
        // Gamma dim below DDC 0 (see `gammaZone`). Skipped entirely while
        // neutral so MonitorControl's gamma is never clobbered by a no-op.
        Self.applyGammaFactor(Self.gammaFactor(forVirtual: target), displayID: targetID, uuid: uuid)
        reply(NSNumber(value: target))
    }

    // MARK: - DDC trace

    /// 每次按键的 delta / 基线 / 目标落盘，便于事后取证「数字和实际为什么对不上」。
    private static func ddcTrace(_ message: String) {
        let path = "/tmp/bn-ddc.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - DDC virtual brightness cache + gamma dim

    private static let ddcLock = NSLock()
    private static var virtualCache: [String: (value: Float, at: Date)] = [:]
    /// Last gamma factor we wrote per display UUID (nil = never touched gamma).
    private static var gammaFactorCache: [String: Float] = [:]
    /// A pressed key sequence hits this cache repeatedly; the TTL only bounds how
    /// long an out-of-band change (monitor buttons, another DDC app) can hide.
    ///
    /// 11-19：原来是 20 秒，等于把手动改过的亮度当成了「当前值」——用户在
    /// MonitorControl 里拉到 10，这边还按 100 的基线算 +6 写成 100；反过来
    /// 按键减到底时又是从一个陈旧的高值往下走，实际永远到不了底。表现就是
    /// 「两边完全独立」。压到 0.9 秒：连续按键仍在同一序列内命中缓存（不卡），
    /// 松手后下一次按键必定重新读硬件，外部改动立刻同步。
    private static let ddcCacheTTL: TimeInterval = 0.9

    /// Bottom slice of the virtual range that lives *below* DDC 0: while the
    /// virtual value is inside this zone the DDC luminance is pinned at 0 and
    /// darkness comes from scaling the display's gamma transfer down to black.
    /// DDC 0 on the H27P6S is still visibly bright; MonitorControl reaches its
    /// darker floor only because `SwBrightness` maps the bottom of its range
    /// into gamma. Virtual 0 = gamma 0 = screen black.
    private static let gammaZone: Float = 0.25

    /// Virtual 0...1 → DDC luminance 0...100 (0 while inside the gamma zone).
    private static func ddcTarget(forVirtual v: Float) -> Int {
        guard v > gammaZone else { return 0 }
        return Int((((v - gammaZone) / (1 - gammaZone)) * 100).rounded())
    }

    /// DDC luminance 0...100 → virtual value, assuming our gamma is neutral.
    private static func virtualFromDDC(_ ddc: Int) -> Float {
        gammaZone + (Float(ddc) / 100.0) * (1 - gammaZone)
    }

    /// Virtual 0...1 → gamma transfer scale (1 = neutral, 0 = black).
    private static func gammaFactor(forVirtual v: Float) -> Float {
        guard v < gammaZone else { return 1 }
        return max(0, v / gammaZone)
    }

    /// Virtual brightness (0...1) for a DDC display, cached between presses.
    /// While our own gamma dim is on the screen a DDC read can't reveal the
    /// virtual value (it always answers 0), so the cache — our last known
    /// state — is the source of truth and skips the TTL; otherwise an expired
    /// entry triggers a fresh hardware read so out-of-band changes sync.
    private static func currentVirtual(m1ddc: URL, uuid: String) -> Float? {
        ddcLock.lock()
        let cached = virtualCache[uuid]
        let dimmed = gammaFactorCache[uuid].map { $0 < 0.999 } ?? false
        ddcLock.unlock()
        if let cached, dimmed || Date().timeIntervalSince(cached.at) < ddcCacheTTL {
            return cached.value
        }
        // `get` prints a bare number. Right after a write the bus can answer
        // garbage (2809), so validate the range and retry once before giving up.
        for _ in 0..<2 {
            if let out = runM1ddc(m1ddc, args: ["display", uuid, "get", "luminance"]),
               let value = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)),
               (0...100).contains(value) {
                let v = virtualFromDDC(value)
                storeVirtual(v, uuid: uuid)
                return v
            }
        }
        // DDC read glitch: a stale value beats failing the whole adjustment.
        return cached?.value
    }

    private static func storeVirtual(_ value: Float, uuid: String) {
        ddcLock.lock()
        virtualCache[uuid] = (value, Date())
        ddcLock.unlock()
    }

    /// Writes the gamma transfer formula (`min 0, max f, gamma 1` per channel).
    /// Neutral rewrites are skipped entirely — we must not clobber another
    /// app's gamma (MonitorControl) with a no-op. Active dim rewrites every
    /// time so an OS-side gamma reset (sleep/wake, profile change) heals on
    /// the next key press instead of leaving HUD 0% on a bright screen.
    private static func applyGammaFactor(_ factor: Float, displayID: CGDirectDisplayID, uuid: String) {
        ddcLock.lock()
        let last = gammaFactorCache[uuid]
        ddcLock.unlock()
        if let last, abs(last - factor) < 0.005, factor > 0.999 { return }
        let err = CGSetDisplayTransferByFormula(
            displayID,
            0, factor, 1.0,
            0, factor, 1.0,
            0, factor, 1.0
        )
        Self.ddcTrace(String(format: "gamma uuid=%@ factor=%.3f last=%@ rc=%d", uuid, factor, last.map { String($0) } ?? "nil", err.rawValue))
        if err == .success {
            ddcLock.lock()
            gammaFactorCache[uuid] = factor
            ddcLock.unlock()
        }
    }

    private static let m1ddcURL: URL? = {
        let candidates = [
            "/Users/lisiyuan/homebrew/bin/m1ddc",
            "/opt/homebrew/bin/m1ddc",
            "/usr/local/bin/m1ddc",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    private static func runM1ddc(_ url: URL, args: [String]) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                NSLog("[brightness] m1ddc \(args.joined(separator: " ")) rc=\(process.terminationStatus)")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            NSLog("[brightness] m1ddc launch failed: \(error)")
            return nil
        }
    }

    // MARK: - Lunar Events

    @objc func displayIDForBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let id = brightnessDisplayID()
        reply(NSNumber(value: id))
    }

    @objc func isLunarAvailable(with reply: @escaping (Bool) -> Void) {
        reply(FileManager.default.isExecutableFile(atPath: lunarExecutableURL.path))
    }

    @objc func startLunarEventStream(with reply: @escaping (Bool) -> Void) {
        lunarStateQueue.async { [weak self] in
            guard let self else {
                reply(false)
                return
            }

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                reply(true)
                return
            }

            guard FileManager.default.isExecutableFile(atPath: self.lunarExecutableURL.path) else {
                reply(false)
                return
            }

            guard let connection = self.connection else {
                reply(false)
                return
            }

            // Weak capture: the proxy is stored in `self.lunarListener` and
            // retains its error handler, so a strong `self` here is a
            // self -> proxy -> block -> self cycle that keeps this helper
            // alive forever and skips `deinit` (Lunar child process and pipe
            // handler leak after the client disconnects).
            let listenerProxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.stopLunarEventStream()
            } as? BoringNotchXPCHelperLunarListener

            guard let listenerProxy else {
                reply(false)
                return
            }

            let process = Process()
            process.executableURL = self.lunarExecutableURL
            process.arguments = ["@", "listen", "--only-user-adjustments", "-j"]

            let pipeHandler = JSONLinesPipeHandler()
            process.standardOutput = pipeHandler.outputPipe
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { [weak self] _ in
                self?.stopLunarEventStream(reason: "Lunar stream ended")
            }

            do {
                try process.run()
            } catch {
                reply(false)
                return
            }

            self.lunarProcess = process
            self.lunarPipeHandler = pipeHandler
            self.lunarListener = listenerProxy

            let currentPipeHandler = pipeHandler
            self.lunarStreamTask = Task { [weak self] in
                await self?.readLunarEvents(pipeHandler: currentPipeHandler)
            }

            reply(true)
        }
    }

    @objc func stopLunarEventStream() {
        stopLunarEventStream(reason: nil)
    }

    private func stopLunarEventStream(reason: String?) {
        lunarStateQueue.async { [weak self] in
            guard let self else { return }

            self.lunarStreamTask?.cancel()
            self.lunarStreamTask = nil

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                lunarProcess.terminate()
            }

            self.lunarProcess = nil

            if let pipeHandler = self.lunarPipeHandler {
                pipeHandler.close()
            }

            self.lunarPipeHandler = nil

            if let reason {
                self.lunarListener?.lunarStreamDidStop(reason)
            }

            self.lunarListener = nil
        }
    }

    private func readLunarEvents(pipeHandler: JSONLinesPipeHandler) async {
        await pipeHandler.readJSONLines(as: LunarBrightnessEvent.self) { [weak self] event in
            self?.emitLunarEvent(event)
        }
    }

    private func emitLunarEvent(_ event: LunarBrightnessEvent) {
        let payload = BNLunarBrightnessEvent(
            brightness: event.brightness,
            display: event.display
        )
        lunarStateQueue.async { [weak self] in
            self?.lunarListener?.lunarEventDidUpdate(payload)
        }
    }

    // MARK: - Lunar OSD preference (hideOSD)

    private static let lunarBundleID = "fyi.lunar.Lunar"
    private static let lunarHideOSDKey = "hideOSD"

    @objc func setLunarOSDHidden(_ hide: Bool, with reply: @escaping (Bool) -> Void) {
        let appID = Self.lunarBundleID as CFString
        let key = Self.lunarHideOSDKey as CFString
        let value = hide as CFBoolean
        NSLog("Hide OSD in Lunar: \(hide)")
        CFPreferencesSetValue(key, value, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let ok = CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reply(ok)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func displayServicesSetBrightnessSmooth(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightnessSmooth") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

// MARK: - Lunar Parsing

private struct LunarBrightnessEvent: Decodable, Sendable {
    let brightness: Double
    let display: Int
}
