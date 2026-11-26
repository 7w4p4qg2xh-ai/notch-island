import ApplicationServices
import Combine
import CoreAudio
import CoreGraphics
import Defaults
import Foundation
import IOKit
import IOKit.ps

/// Manages and monitors battery status changes on the device
/// - Note: This class uses the IOKit framework to monitor battery status
final class BatteryActivityManager {
    static let shared = BatteryActivityManager()

    private var batterySource: CFRunLoopSource?
    private var observers: [(BatteryEvent) -> Void] = []
    private var previousBatteryInfo: BatteryInfo?
    // actor-based queue to serialize notification delivery
    private let notificationQueueActor = NotificationQueue()

    /// An actor responsible for serializing and delivering events with a 1‑second delay.
    private actor NotificationQueue {
        private var queue: [BatteryEvent] = []
        private var processing = false

        /// Enqueue an event; the `deliver` closure is always invoked on the main actor.
        func enqueue(_ event: BatteryEvent, deliver: @MainActor @escaping (BatteryEvent) -> Void) {
            queue.append(event)
            if !processing {
                processing = true
                Task { await process(deliver: deliver) }
            }
        }

        private func process(deliver: @MainActor @escaping (BatteryEvent) -> Void) async {
            while !queue.isEmpty {
                let event = queue.removeFirst()
                // pause between notifications
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await deliver(event)
            }
            processing = false
        }
    }

    enum BatteryEvent {
        case powerSourceChanged(isPluggedIn: Bool)
        case batteryLevelChanged(level: Float)
        case lowPowerModeChanged(isEnabled: Bool)
        case isChargingChanged(isCharging: Bool)
        case timeToFullChargeChanged(time: Int)
        case timeToDischargeChanged(time: Int)
        case maxCapacityChanged(capacity: Float?)
        case adapterWattageChanged(watts: Int)
        case error(description: String)
    }

    enum BatteryError: Error {
        case powerSourceUnavailable
        case batteryInfoUnavailable(String)
        case batteryParameterMissing(String)
    }

    private let defaultBatteryInfo = BatteryInfo(
        isPluggedIn: false,
        isCharging: false,
        currentCapacity: 0,
        maxCapacity: nil,
        isInLowPowerMode: false,
        timeToFullCharge: 0,
        timeToDischarge: 0
    )

    private init() {
        startMonitoring()
        setupLowPowerModeObserver()
    }

    /// Setup observer for low power mode changes
    private func setupLowPowerModeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    /// Called when low power mode is enabled or disabled
    @objc private func lowPowerModeChanged() {
        notifyBatteryChanges()
    }

    /// Starts monitoring battery changes
    private func startMonitoring() {
        guard let powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<BatteryActivityManager>.fromOpaque(context).takeUnretainedValue()
            manager.notifyBatteryChanges()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            return
        }
        batterySource = powerSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
    }

    /// Stops monitoring battery changes
    private func stopMonitoring() {
        if let powerSource = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
            batterySource = nil
        }
    }

    /// Checks for changes in a property and notifies observers
    private func checkAndNotify<T: Equatable>(
        previous: T,
        current: T,
        eventGenerator: (T) -> BatteryEvent
    ) {
        if previous != current {
            enqueueNotification(eventGenerator(current))
        }
    }

    /// Notifies the observers of battery changes
    /// Checks for changes in battery status and notifies observers
    private func notifyBatteryChanges() {
        let batteryInfo = getBatteryInfo()

        // Check for changes
        if let previousInfo = previousBatteryInfo {
            // Usar la función auxiliar para cada propiedad
            checkAndNotify(
                previous: previousInfo.isPluggedIn,
                current: batteryInfo.isPluggedIn,
                eventGenerator: { .powerSourceChanged(isPluggedIn: $0) }
            )

            checkAndNotify(
                previous: previousInfo.currentCapacity,
                current: batteryInfo.currentCapacity,
                eventGenerator: { .batteryLevelChanged(level: $0) }
            )

            checkAndNotify(
                previous: previousInfo.isCharging,
                current: batteryInfo.isCharging,
                eventGenerator: { .isChargingChanged(isCharging: $0) }
            )

            checkAndNotify(
                previous: previousInfo.isInLowPowerMode,
                current: batteryInfo.isInLowPowerMode,
                eventGenerator: { .lowPowerModeChanged(isEnabled: $0) }
            )

            checkAndNotify(
                previous: previousInfo.timeToFullCharge,
                current: batteryInfo.timeToFullCharge,
                eventGenerator: { .timeToFullChargeChanged(time: $0) }
            )

            checkAndNotify(
                previous: previousInfo.timeToDischarge,
                current: batteryInfo.timeToDischarge,
                eventGenerator: { .timeToDischargeChanged(time: $0) }
            )

            checkAndNotify(
                previous: previousInfo.maxCapacity,
                current: batteryInfo.maxCapacity,
                eventGenerator: { .maxCapacityChanged(capacity: $0) }
            )

            checkAndNotify(
                previous: previousInfo.maxAdapterWatts,
                current: batteryInfo.maxAdapterWatts,
                eventGenerator: { .adapterWattageChanged(watts: $0) }
            )
        } else {
            // First time notification
            enqueueNotification(.powerSourceChanged(isPluggedIn: batteryInfo.isPluggedIn))
            enqueueNotification(.batteryLevelChanged(level: batteryInfo.currentCapacity))
            enqueueNotification(.isChargingChanged(isCharging: batteryInfo.isCharging))
            enqueueNotification(.lowPowerModeChanged(isEnabled: batteryInfo.isInLowPowerMode))
            enqueueNotification(.timeToFullChargeChanged(time: batteryInfo.timeToFullCharge))
            enqueueNotification(.timeToDischargeChanged(time: batteryInfo.timeToDischarge))
            enqueueNotification(.maxCapacityChanged(capacity: batteryInfo.maxCapacity))
            enqueueNotification(.adapterWattageChanged(watts: batteryInfo.maxAdapterWatts))
        }

        // Update previous battery info
        previousBatteryInfo = batteryInfo
    }

    /// Enqueues a notification to be processed using the concurrency-based queue actor.
    private func enqueueNotification(_ event: BatteryEvent) {
        Task { @MainActor in
            await notificationQueueActor.enqueue(event) { [weak self] ev in
                self?.notifyObservers(event: ev)
            }
        }
    }

    /// Initializes the battery information when the manager starts
    /// - Returns: Current battery information
    func initializeBatteryInfo() -> BatteryInfo {
        previousBatteryInfo = getBatteryInfo()
        guard let batteryInfo = previousBatteryInfo else {
            return BatteryInfo(
                isPluggedIn: false,
                isCharging: false,
                currentCapacity: 0,
                maxCapacity: nil,
                isInLowPowerMode: false,
                timeToFullCharge: 0,
                timeToDischarge: 0
            )
        }
        return batteryInfo
    }

    /// Get the current battery information
    /// - Returns: The current battery information
    private func getBatteryInfo() -> BatteryInfo {
        do {
            // Get power source information
            guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                throw BatteryError.powerSourceUnavailable
            }

            guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
                !sources.isEmpty else {
                throw BatteryError.batteryInfoUnavailable("No power sources available")
            }

            let source = sources.first!

            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                throw BatteryError.batteryInfoUnavailable("Could not get power source description")
            }

            // Extract required battery parameters with error handling
            guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Float else {
                throw BatteryError.batteryParameterMissing("Current capacity")
            }

            guard let isCharging = description["Is Charging"] as? Bool else {
                throw BatteryError.batteryParameterMissing("Charging state")
            }

            guard let powerSource = description[kIOPSPowerSourceStateKey] as? String else {
                throw BatteryError.batteryParameterMissing("Power source state")
            }

            // Create battery info with the extracted parameters
            var batteryInfo = BatteryInfo(
                isPluggedIn: powerSource == kIOPSACPowerValue,
                isCharging: isCharging,
                currentCapacity: currentCapacity,
                maxCapacity: getBatteryHealthCapacity(),
                isInLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                timeToFullCharge: 0,
                timeToDischarge: 0
            )

            // Optional parameters
            if let timeToFullCharge = description[kIOPSTimeToFullChargeKey] as? Int {
                batteryInfo.timeToFullCharge = timeToFullCharge
            }

            if let timeToDischarge = description[kIOPSTimeToEmptyKey] as? Int {
                batteryInfo.timeToDischarge = timeToDischarge
            }

            // Rated adapter wattage; nil on battery or unreported, stays 0
            if let adapterDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
               let watts = adapterDetails[kIOPSPowerAdapterWattsKey as String] as? Int {
                batteryInfo.maxAdapterWatts = watts
            }

            return batteryInfo
        } catch BatteryError.powerSourceUnavailable {
            Log.battery.error("⚠️ Error: Power source information unavailable")
            return defaultBatteryInfo
        } catch BatteryError.batteryInfoUnavailable(let reason) {
            Log.battery.error("⚠️ Error: Battery information unavailable - \(reason)")
            return defaultBatteryInfo
        } catch BatteryError.batteryParameterMissing(let parameter) {
            Log.battery.error("⚠️ Error: Battery parameter missing - \(parameter)")
            return defaultBatteryInfo
        } catch {
            Log.battery.error("⚠️ Error: Unexpected error getting battery info - \(error.localizedDescription)")
            return defaultBatteryInfo
        }
    }

    /// Reads the user-visible battery health capacity from the smart battery registry.
    private func getBatteryHealthCapacity() -> Float? {
        let batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard batteryService != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(batteryService) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(batteryService, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let batteryProperties = properties?.takeRetainedValue() as? [String: Any],
              let designCapacity = capacityValue(in: batteryProperties, forKey: "DesignCapacity"),
              designCapacity > 0,
              let fullChargeCapacity = capacityValue(in: batteryProperties, forKey: "NominalChargeCapacity")
                ?? capacityValue(in: batteryProperties, forKey: "AppleRawMaxCapacity"),
              fullChargeCapacity > 0 else {
            return nil
        }

        let healthPercentage = (fullChargeCapacity / designCapacity) * 100
        return min(max((healthPercentage / 5).rounded() * 5, 0), 100)
    }

    private func capacityValue(in properties: [String: Any], forKey key: String) -> Float? {
        if let number = properties[key] as? NSNumber {
            return number.floatValue
        }
        if let value = properties[key] as? Float {
            return value
        }
        if let value = properties[key] as? Double {
            return Float(value)
        }
        if let value = properties[key] as? Int {
            return Float(value)
        }
        return nil
    }

    /// Adds an observer to listen to battery changes
    /// - Parameter observer: The observer closure to be called on battery events
    /// - Returns: The ID of the observer for later removal
    func addObserver(_ observer: @escaping (BatteryEvent) -> Void) -> Int {
        observers.append(observer)
        return observers.count - 1
    }

    /// Removes an observer by its ID
    /// - Parameter id: The ID of the observer to be removed
    func removeObserver(byId id: Int) {
        guard id >= 0 && id < observers.count else { return }
        observers.remove(at: id)
    }

    /// Notifies all observers of a battery event
    /// - Parameter event: The battery event to notify
    private func notifyObservers(event: BatteryEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for observer in self.observers {
                observer(event)
            }
        }
    }

    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }
}

/// Struct to hold battery information
struct BatteryInfo {
    var isPluggedIn: Bool
    var isCharging: Bool
    var currentCapacity: Float
    var maxCapacity: Float?
    var isInLowPowerMode: Bool
    var timeToFullCharge: Int
    var timeToDischarge: Int
    var maxAdapterWatts: Int = 0
}

// MARK: - Bluetooth peripheral battery

/// One connected Bluetooth peripheral and whatever battery info macOS
/// exposes for it: keyboards/mice report a single level, AirPods report
/// left/right/case separately.
struct PeripheralDeviceBattery: Equatable {
    var name: String
    var icon: String
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// 11-24: `system_profiler` 的 `device_minorType`。iPhone / iPad /
    /// Apple Watch 这类走 BLE 的设备**根本没有这个键**，而旧逻辑把「空类别」
    /// 当成耳机，于是手机手表一靠近就弹「耳机已连接」，断开再弹「已转移到
    /// 其它设备」（`~/bn-airpods.log` 里 iPhone / Ultra 各有多次记录）。
    var minorType: String = ""
    /// 11-24: productID 命中 AirPods/Beats 型号表 —— 比类别更硬的耳机证据，
    /// 保证改了名的 AirPods 和没报 minorType 的苹果耳机照样认得出。
    var isKnownHeadphoneModel: Bool = false

    var hasBattery: Bool { main != nil || left != nil || right != nil || caseLevel != nil }
    var lowestLevel: Int? { [main, left, right, caseLevel].compactMap { $0 }.min() }

    /// 11-15: the iPhone-style connection card shows ONE overall ring. For
    /// two-piece earbuds the lower bud is the honest answer — using the higher
    /// one would read as "full" while one bud is nearly dead. Single devices
    /// fall back to their main level, then to the charging case.
    var overallLevel: Int? {
        if let left, let right { return min(left, right) }
        if let left { return left }
        if let right { return right }
        if let main { return main }
        return caseLevel
    }

    /// AirPods / Beats / generic headphones. Keyboards and mice keep the old
    /// one-line text pill; only headphones get the connection card.
    ///
    /// 11-16: 图标现在是分机型的（`airpodspro` / `airpodsmax` / `beats.*`），
    /// 只认 `== "headphones"` 会把改名成「AP5」的 AirPods 判成非耳机，
    /// 连接卡直接不弹 —— 所以按前缀一起认。
    /// 🔴 11-24: 不能只靠图标。`system_profiler` 里 iPhone / iPad / Apple Watch
    /// 不带 `device_minorType`，旧逻辑把「空类别」当耳机，于是一靠近就弹
    /// 「耳机已连接」、断开再弹「已转移到其它设备」。现在要求三者之一成立：
    /// 类别说是耳机 / 型号命中苹果耳机表 / 名字带耳机词。
    var looksLikeHeadphones: Bool {
        let type = minorType.lowercased()
        if type.contains("headphone") || type.contains("earphone") || type.contains("headset") {
            return true
        }
        if isKnownHeadphoneModel { return true }
        // 类别明确（键盘 / 鼠标 / 音箱 / 手机 / 手表…）就直接判非耳机。
        guard type.isEmpty else { return false }
        let name = self.name.lowercased()
        return name.contains("airpods")
            || name.contains("beats")
            || name.contains("headphone")
            || name.contains("耳机")
    }
}

/// Polls `system_profiler SPBluetoothDataType` (public API, no private
/// frameworks) for connected Bluetooth devices' battery levels and peeks the
/// notch pill when a device connects or first crosses the low-battery line.
@MainActor
final class PeripheralBatteryManager: ObservableObject {
    static let shared = PeripheralBatteryManager()

    /// Peek when a device connects or first drops to/below this percentage.
    static let lowBatteryThreshold = 20

    @Published private(set) var connectedDevices: [PeripheralDeviceBattery] = []
    /// The device the current peek pill is showing.
    @Published private(set) var peekDevice: PeripheralDeviceBattery?
    /// 11-15: true only for a fresh headphone connection (the iPhone-style
    /// card). Low-battery alerts and non-headphone devices keep the old
    /// one-line text pill.
    @Published private(set) var isConnectionPeek: Bool = false

    /// 13:31: macOS 的菜单栏蓝牙气泡（连接 / 已转移到 iPhone / 断开…）被收进
    /// 岛后，岛卡要显示系统原文和它自带的按钮。按钮的 AX 元素在窗口挪到屏外
    /// 之后仍然可按（helper 的 NotificationWatcher 已验证）。
    @Published private(set) var systemPromptDevice: String?
    @Published private(set) var systemPromptMessage: String?
    @Published private(set) var systemPromptButtonTitle: String?
    /// 15:04: 岛卡状态文案。系统气泡（「已转移到 iPad」）不在 AX 树里，
    /// 读不到原文，但至少不能继续错误地写着「已连接」。
    @Published private(set) var islandStatusMessage: String?
    private var systemPromptButton: AXUIElement?
    private var systemPromptWindow: AXUIElement?

    private var pollTask: Task<Void, Never>?
    private var knownDevices: [PeripheralDeviceBattery] = []
    private var alertedLowDevices: Set<String> = []
    /// CoreAudio can fire several times for one pairing; don't re-greet.
    private var lastConnectionPeekAt: [String: Date] = [:]
    /// 🔴 11-15: `knownDevices.isEmpty` used to stand for "first snapshot".
    /// On this machine there is often NO connected Bluetooth device at all,
    /// so it stayed empty forever and every poll bailed out as a baseline —
    /// a real connection was never detected. Track completion explicitly.
    private var hasBaseline = false
    private var cancellables: [AnyCancellable] = []

    private init() {
        cancellables.append(
            Defaults.publisher(.peripheralBatteryEnabled, options: [.initial])
                .sink { [weak self] change in
                    Task { @MainActor in
                        change.newValue ? self?.start() : self?.stop()
                    }
                }
        )
    }

    func start() {
        guard pollTask == nil else { return }
        AudioDeviceConnectionWatcher.shared.start()
        // 🔴 17:29: DO NOT start BluetoothPromptHider. Its shape filter was
        // wide enough to catch ordinary menu-bar drop-downs and app windows;
        // the log shows 3 real hits with hidden=true (MenuBarAgent #770/#1181,
        // 访达 #467), i.e. it MOVED SYSTEM WINDOWS OFF SCREEN and pushed
        // nonsense island cards ("Deskflow 正在连接...", "连接服务器…").
        // The user also decided at 15:04 to keep the system bubble (docs/04
        // S8: it has no AX elements anyway). Keep the 4s poll only.
        // 11-15: 15s + 30s was far too slow for "the moment AirPods connect",
        // and CoreAudio alone is not enough (macOS often asks the user to
        // confirm the connection first, so the output device never switches).
        // system_profiler stays on a background queue.
        // 🔴 11-22: 每一轮轮询都是一整个 system_profiler SPBluetoothDataType
        // 进程（单次 1~3s，全程查询 blued）。4s 一轮被实测证实拖慢 AirPods
        // 在设备间切换——用户退出本 app 立刻恢复秒切。兜底轮询退到 30s，
        // 实时性改由 CoreAudio 事件驱动（AudioDeviceConnectionWatcher）。
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollOnce() async {
        let snapshot = await Self.fetchSnapshot()
        process(snapshot)
    }

    // MARK: Change detection & peeking

    private func process(_ snapshot: [PeripheralDeviceBattery]) {
        let previous = knownDevices
        knownDevices = snapshot
        connectedDevices = snapshot

        // 🔴 Explicit baseline flag, NOT `previous.isEmpty` (see the note on
        // the property). Without this, a machine with zero connected devices
        // never detects any new connection at all.
        if !hasBaseline {
            hasBaseline = true
            AirPodsTrace.log("baseline(poll) count=\(snapshot.count) names=\(snapshot.map(\.name))")
            return
        }
        if snapshot.count != previous.count {
            AirPodsTrace.log("poll changed count=\(snapshot.count) names=\(snapshot.map(\.name))")
        }

        // system_profiler can report the same device more than once (the same
        // unit under two sections, or a duplicated entry). uniquingKeysWith
        // keeps the first occurrence — uniqueKeysWithValues would trap on the
        // duplicate and take the whole app down.
        let previousByName = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        // 11-21: 不能只遍历有电量的设备。AirPods Max 的电量 system_profiler
        // 不暴露（系统弹窗走私有渠道能读 96%，公开接口拿不到），但它仍是耳机。
        // 用 looksLikeHeadphones 放行，让没电量的耳机也能弹连接卡；低电量逻辑
        // 对 nil 电量天然返回 false，不会误报。
        for device in snapshot where device.hasBattery || device.looksLikeHeadphones {
            guard let old = previousByName[device.name] else {
                // Newly connected: greet it and (re)arm the low-battery alert.
                // Headphones get the iPhone-style connection card; everything
                // else keeps the old one-line text pill (11-15).
                alertedLowDevices.remove(device.name)
                peek(device, isConnection: device.looksLikeHeadphones)
                continue
            }
            if device == old { continue }
            if crossedLowThreshold(old: old, new: device) {
                if !alertedLowDevices.contains(device.name) {
                    alertedLowDevices.insert(device.name)
                    peek(device)
                }
            } else if let lowest = device.lowestLevel, lowest > Self.lowBatteryThreshold {
                // Recharged above the line — allow the next drop to alert again.
                alertedLowDevices.remove(device.name)
            }
        }

        // 15:04: a headphone that disappears shortly after a connection peek
        // is macOS handing it over to iPhone/iPad. The system bubble stays on
        // screen (it is NOT an AX window — docs/04 S8), so the island must at
        // least tell the truth instead of still saying "已连接".
        let currentNames = Set(snapshot.map(\.name))
        for old in previous where old.looksLikeHeadphones && !currentNames.contains(old.name) {
            guard let last = lastConnectionPeekAt[old.name],
                  Date().timeIntervalSince(last) < 90,
                  Date().timeIntervalSince(last) > 4 else { continue }
            lastConnectionPeekAt.removeValue(forKey: old.name)
            peekTransferred(old)
            break
        }
    }

    private func crossedLowThreshold(old: PeripheralDeviceBattery, new: PeripheralDeviceBattery) -> Bool {
        guard let newLowest = new.lowestLevel,
              newLowest <= Self.lowBatteryThreshold else { return false }
        if let oldLowest = old.lowestLevel, oldLowest <= Self.lowBatteryThreshold { return false }
        return true
    }

    private func peek(_ device: PeripheralDeviceBattery, isConnection: Bool = false) {
        // 11-24: 兜底闸门。无电量、又不是耳机的设备（iPhone / iPad / Apple
        // Watch 这类 BLE 设备）永远不该进岛卡，哪怕以后又多一条调用路径。
        guard device.hasBattery || device.looksLikeHeadphones else { return }
        if isConnection {
            if let last = lastConnectionPeekAt[device.name],
               Date().timeIntervalSince(last) < 30 { return }
            lastConnectionPeekAt[device.name] = Date()
        }
        peekDevice = device
        isConnectionPeek = isConnection
        // 17:29: on the island EVERY peripheral peek now uses the card, so a
        // keyboard/mouse connecting must not be labelled "电量偏低".
        let low = (device.lowestLevel ?? 100) <= Self.lowBatteryThreshold
        islandStatusMessage = low ? "电量偏低" : "已连接"
        clearSystemPrompt()
        AirPodsTrace.log("peek name=\(device.name) connection=\(isConnection) level=\(device.overallLevel.map(String.init) ?? "-")")
        NotchUIEventBus.events.send(.expandingView(type: .peripheralBattery))
    }

    /// 设备被切到别的 Apple 设备：岛卡显示真实状态，系统气泡照常留着
    /// （用户 15:04 选「先不动系统设置」，那边按钮还能自己点）。
    private func peekTransferred(_ device: PeripheralDeviceBattery) {
        peekDevice = device
        isConnectionPeek = true
        islandStatusMessage = "已转移到其它设备"
        clearSystemPrompt()
        AirPodsTrace.log("peek transferred name=\(device.name)")
        NotchUIEventBus.events.send(.expandingView(type: .peripheralBattery))
    }

    // MARK: - 系统气泡收口（13:31）

    /// 气泡出现时调用：把系统原文和按钮交给岛卡，绝不按按钮。
    func presentSystemPrompt(device: String, message: String, buttonTitle: String?,
                             button: AXUIElement?, window: AXUIElement?) {
        systemPromptDevice = device
        systemPromptMessage = message
        systemPromptButtonTitle = buttonTitle
        systemPromptButton = button
        systemPromptWindow = window
        isConnectionPeek = true
        AirPodsTrace.log("present prompt device=\(device) message=\(message) button=\(buttonTitle ?? "none")")
        NotchUIEventBus.events.send(.expandingView(type: .peripheralBattery))
    }

    /// 只有用户点岛上的按钮时才会走到这里（13:01「不要自动连啊…我自己点」）。
    func performSystemPromptAction() {
        guard let button = systemPromptButton else {
            AirPodsTrace.log("island button: no AX button, ignored")
            return
        }
        let result = AXUIElementPerformAction(button, "AXPress" as CFString)
        AirPodsTrace.log("island button pressed result=\(result.rawValue)")
        if result != .success, let window = systemPromptWindow {
            // helper 的安全原则：系统拒绝时把窗口还回屏幕，用户绝不能失去
            // 操作入口。只还位置，不自动执行任何动作。
            var origin = CGPoint(x: 320, y: 60)
            if let position = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
            }
            AirPodsTrace.log("action refused, restored system bubble on screen")
        }
        systemPromptButton = nil
        systemPromptButtonTitle = nil
    }

    private func clearSystemPrompt() {
        systemPromptDevice = nil
        systemPromptMessage = nil
        systemPromptButtonTitle = nil
        systemPromptButton = nil
        systemPromptWindow = nil
    }

    // MARK: 11-22 事件驱动入口（替代 4s 高频轮询）

    /// CoreAudio 两个监听（默认输出切换 + 音频设备列表变化）统一汇到这里。
    /// 同一次耳机连接/离开会连发好几个 CoreAudio 事件，400ms 内合并成一次
    /// 处理，避免事件风暴变成 system_profiler 连发。处理内容 =
    /// pollOnce()（完整快照：新设备问候 + 转移检测）
    /// + handlePossibleConnection()（blued 电量晚到，需要连拍兜底）。
    private var handlingAudioEvent = false
    private var pendingAudioEvent = false

    @MainActor
    func handleAudioEvent() {
        guard Defaults[.peripheralBatteryEnabled] else { return }
        if handlingAudioEvent {
            pendingAudioEvent = true
            return
        }
        handlingAudioEvent = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            await self.pollOnce()
            await self.handlePossibleConnection()
            self.handlingAudioEvent = false
            if self.pendingAudioEvent {
                self.pendingAudioEvent = false
                self.handleAudioEvent()
            }
        }
    }

    /// 11-15: called by BOTH the CoreAudio output-device change and the system
    /// Bluetooth prompt watcher. bluetoothd publishes battery levels a beat
    /// AFTER the prompt / route change, so take a few quick snapshots instead
    /// of trusting a single one.
    func handlePossibleConnection() async {
        guard Defaults[.peripheralBatteryEnabled] else { return }
        guard hasBaseline else {
            AirPodsTrace.log("connection trigger ignored: no baseline yet")
            return
        }
        let before = Set(knownDevices.map(\.name))
        AirPodsTrace.log("connection trigger, before=\(before.sorted())")
        for attempt in 1...3 {
            try? await Task.sleep(for: .milliseconds(attempt == 1 ? 600 : 1200))
            let snapshot = await Self.fetchSnapshot()
            knownDevices = snapshot
            connectedDevices = snapshot
            // 11-17: primary signal is still a NEW device name (name-diff).
            // 11-21: 去掉 hasBattery 硬门槛——AirPods Max 被系统认作耳机
            // （icon=airpodsmax）但 system_profiler 不报电量，照样要弹卡。
            var found = snapshot.first {
                $0.looksLikeHeadphones && !before.contains($0.name)
            }
            // 11-17 fallback: CoreAudio fired because audio ROUTED to a
            // headphone, but the name was already in our baseline (app
            // relaunched with AP5 connected, or a re-connect / system-bubble
            // confirm that never removed it from system_profiler). Match the
            // CURRENT output device name against the snapshot so the card
            // still greets. `peek(isConnection:true)` dedups within 30s, so
            // CoreAudio's multiple firings can't re-greet.
            if found == nil {
                let outputName = AudioOutputRouteResolver.shared.currentOutputDeviceName()
                    .lowercased()
                if !outputName.isEmpty {
                    found = snapshot.first { device in
                        guard device.looksLikeHeadphones else { return false }  // 11-21: 不再要求 hasBattery
                        let n = device.name.lowercased()
                        return outputName.contains(n) || n.contains(outputName)
                    }
                    if found != nil {
                        AirPodsTrace.log("route fallback output=\(outputName) matched=\(found?.name ?? "none")")
                    }
                }
            }
            AirPodsTrace.log("attempt \(attempt) count=\(snapshot.count) new=\(found?.name ?? "none")")
            if let found {
                peek(found, isConnection: true)
                return
            }
        }
    }

    /// Left-of-notch text for the peek pill, e.g.
    /// "AirPods Pro — L 80% · R 75% · Case 90%" or "Magic Keyboard — 100%".
    var peekSummary: String? {
        guard let device = peekDevice else { return nil }
        var parts: [String] = []
        if let main = device.main { parts.append("\(main)%") }
        if let left = device.left { parts.append("L \(left)%") }
        if let right = device.right { parts.append("R \(right)%") }
        if let caseLevel = device.caseLevel { parts.append("Case \(caseLevel)%") }
        guard !parts.isEmpty else { return device.name }
        return "\(device.name) — \(parts.joined(separator: " · "))"
    }

    var peekIcon: String { peekDevice?.icon ?? "dot.radiowaves.left.and.right" }

    /// 11-21: 音量 HUD 用的机型图标。按「当前 CoreAudio 输出设备名」在已连接
    /// 设备里找对应耳机，返回它的 Product-ID 机型图标（airpods / airpodspro /
    /// airpodsmax / beats.* / headphones）。这样改名成 AP5 的 AirPods 也能在
    /// 音量条上显示 AirPods 图标，头戴式显示头戴图标，两者明确区分。
    /// 找不到匹配（输出不是蓝牙耳机 / 数据还没到）时返回 nil，由调用方回落到
    /// 原来的 CoreAudio 名字分类。
    @MainActor
    func currentHeadphoneIcon() -> String? {
        let outputName = AudioOutputRouteResolver.shared.currentOutputDeviceName()
        guard !outputName.isEmpty else { return nil }
        let needle = outputName.lowercased()
        for device in connectedDevices where device.looksLikeHeadphones {
            let name = device.name.lowercased()
            // 双向包含：CoreAudio 名可能是 "AP5" 而蓝牙名是 "AP5"，也可能是
            // 带后缀的长名，任一方是另一方的子串都算同一台。
            if needle.contains(name) || name.contains(needle) {
                return device.icon
            }
        }
        return nil
    }

    // MARK: Data source

    nonisolated private static func fetchSnapshot() async -> [PeripheralDeviceBattery] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runSystemProfiler())
            }
        }
    }

    nonisolated private static func runSystemProfiler() -> [PeripheralDeviceBattery] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.battery.error("⚠️ Peripheral battery: system_profiler failed to launch - \(error.localizedDescription)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return [] }
        var devices = parseBluetoothReport(data)
        // 🔴 11-21：AirPods Max 的电量 system_profiler 根本不导出 —— 同一份
        // JSON 里 AP5（同样未连接）Left/Right/Case 三个键都在，Max 一个
        // battery 键都没有，所以不是解析问题。而系统自己那条「AirPods Max
        // 已连接」通知能画出 34%，说明值在 powerd 的配件电量表里；
        // `pmset -g accps` 是公开命令、不要蓝牙 TCC、不碰私有框架，直接读它
        // 补空缺。实测：` -AirPods Max (id=45094193)	34%`，和系统通知的
        // 34 完全一致。
        Self.fillMissingLevels(&devices, from: Self.accessoryPowerLevels())
        return devices
    }

    /// `pmset -g accps` → ["AirPods Max": 34]。
    /// 输出形如（每台一行，名字可能为空）：
    /// ```
    ///  -InternalBattery-0 (id=24051811)	80%; AC attached; not charging present: true
    ///  - (id=375652352)	86%; discharging present: true
    ///  -AirPods Max (id=45094193)	34%; discharging present: true
    /// ```
    /// 名字为空的条目无从对应设备，直接跳过。
    nonisolated private static func accessoryPowerLevels() -> [String: Int] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [:] }

        var levels: [String: Int] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-"), let idRange = line.range(of: " (id=") else { continue }
            let name = String(line[line.index(after: line.startIndex)..<idRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard let closeParen = line.range(of: ")", range: idRange.upperBound..<line.endIndex),
                  let level = Int(line[closeParen.upperBound...]
                    .drop { !$0.isNumber }
                    .prefix { $0.isNumber }) else { continue }
            levels[name] = level
        }
        return levels
    }

    /// 只给「system_profiler 一个电量键都没有」的设备补值：
    /// 耳塞（AP5/Pro）本来就有 L/R/Case，别用合并值覆盖。
    nonisolated private static func fillMissingLevels(
        _ devices: inout [PeripheralDeviceBattery],
        from levels: [String: Int]
    ) {
        guard !levels.isEmpty else { return }
        for index in devices.indices where !devices[index].hasBattery {
            let name = devices[index].name
            // 先精确匹配，再双向包含（名字被改过、pmset 多一段后缀都能认）。
            if let exact = levels[name] {
                devices[index].main = exact
                continue
            }
            let lowered = name.lowercased()
            if let matched = levels.first(where: { key, _ in
                let candidate = key.lowercased()
                return candidate.contains(lowered) || lowered.contains(candidate)
            }) {
                devices[index].main = matched.value
            }
        }
    }

    nonisolated private static func parseBluetoothReport(_ data: Data) -> [PeripheralDeviceBattery] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var devices: [PeripheralDeviceBattery] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                guard let properties = entry.values.first as? [String: Any] else { continue }
                let name = entry.keys.first ?? "Bluetooth Device"
                let minorType = properties["device_minorType"] as? String ?? ""
                let productID = hexValue(properties["device_productID"])
                let vendorID = hexValue(properties["device_vendorID"])
                devices.append(
                    PeripheralDeviceBattery(
                        name: name,
                        icon: icon(
                            for: minorType,
                            name: name,
                            productID: productID,
                            vendorID: vendorID
                        ),
                        main: percentValue(properties["device_batteryLevelMain"]),
                        left: percentValue(properties["device_batteryLevelLeft"]),
                        right: percentValue(properties["device_batteryLevelRight"]),
                        caseLevel: percentValue(properties["device_batteryLevelCase"]),
                        minorType: minorType,
                        isKnownHeadphoneModel: airPodsSymbol(productID) != nil
                    )
                )
            }
        }
        return devices
    }

    nonisolated private static func percentValue(_ raw: Any?) -> Int? {
        guard let text = raw as? String else { return nil }
        let digits = text.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// `device_productID` / `device_vendorID` come out of system_profiler as
    /// the hex strings "0x2030" / "0x004C".
    nonisolated private static func hexValue(_ raw: Any?) -> Int? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return Int(trimmed, radix: 16)
    }

    /// 11-16: 机型图标，不再一律用 `headphones`。
    ///
    /// 用户原话「不同耳机要不同图标，就苹果的」。蓝牙 Product ID 是唯一可靠的
    /// 判据 —— 设备名可以随便改（他这台叫「AP5」，改名后按名字判断就废了），
    /// minorType 一律是 `Headphones`。表里的数值取自 The Apple Wiki /
    /// pods-control 的对应表，落库前逐台核对过。
    ///
    /// SF Symbols 没有「第 5 代」这个词条，AirPods 5 用 `airpods.gen4`
    /// （同为无耳塞短柄造型，是苹果自家画得最接近的一版）。
    nonisolated private static func icon(
        for minorType: String,
        name: String,
        productID: Int?,
        vendorID: Int?
    ) -> String {
        let type = minorType.lowercased()
        let lowered = name.lowercased()

        // 11-24: 型号表是最硬的证据 —— 有没有 minorType 都先认。
        if let symbol = airPodsSymbol(productID) { return symbol }

        if type.contains("headphone") || type.contains("earphone") || type.contains("headset") {
            // 名字里带机型的（没被改名的设备）也认一下
            if lowered.contains("airpods max") { return "airpodsmax" }
            if lowered.contains("airpods pro") { return "airpodspro" }
            if lowered.contains("airpods") { return "airpods" }
            if lowered.contains("beats") { return "beats.headphones" }
            // 苹果自家的耳机，型号表里没有的新品至少给 AirPods 的造型
            if vendorID == 0x004C { return "airpods" }
            return "headphones"
        }
        if type.contains("keyboard") { return "keyboard" }
        if type.contains("mouse") { return "computermouse" }
        if type.contains("trackpad") { return "trackpad" }
        if type.contains("game") { return "gamecontroller" }
        if type.contains("speaker") { return "hifispeaker" }
        // 🔴 11-24: 这一句原来是 `if type.contains("headphone") || type.isEmpty`。
        // 空类别被当成耳机，于是 iPhone / iPad / Apple Watch 全拿到耳机图标，
        // 苹果设备还会因为 vendorID == 0x004C 显示成 AirPods。现在空类别只按
        // 名字认耳机，其它一律通用蓝牙图标。
        if type.isEmpty {
            if lowered.contains("airpods max") { return "airpodsmax" }
            if lowered.contains("airpods pro") { return "airpodspro" }
            if lowered.contains("airpods") { return "airpods" }
            if lowered.contains("beats") { return "beats.headphones" }
            if lowered.contains("headphone") || lowered.contains("耳机") { return "headphones" }
        }
        return "dot.radiowaves.left.and.right"
    }

    /// 蓝牙 Product ID → SF Symbol。AirPods 家族按代际分开，Beats 按系列。
    nonisolated private static func airPodsSymbol(_ productID: Int?) -> String? {
        guard let id = productID else { return nil }
        switch id {
        // AirPods
        case 0x2002, 0x200F:            return "airpods"          // 1 代 / 2 代
        case 0x2013:                    return "airpods.gen3"      // 3 代
        case 0x2019, 0x201B:            return "airpods.gen4"      // 4 代 / 4 代 ANC
        case 0x2030, 0x2036:            return "airpods.gen4"      // 5 代（无 gen5 词条）
        // AirPods Pro
        case 0x200E, 0x2014, 0x2024,
             0x2027, 0x202B, 0x202C:    return "airpodspro"        // Pro 1 / 2 / 3
        // AirPods Max
        case 0x200A, 0x201F, 0x202D:    return "airpodsmax"       // Max 1 / Max 2
        // Beats
        case 0x2003, 0x200B, 0x200D:    return "beats.powerbeats"
        case 0x2011, 0x2016, 0x2026:    return "beats.studiobuds"
        case 0x2012:                    return "beats.fitpro"
        case 0x2006, 0x2009, 0x200C,
             0x2017, 0x2025:            return "beats.headphones"
        case 0x2005, 0x2010:            return "beats.earphones"
        default:                        return nil
        }
    }
}

// MARK: - Instant headphone connection trigger (11-15)

/// CoreAudio reports the default output device changing the moment AirPods
/// take over. Polling alone took up to 30s, so the connection card arrived
/// long after the earbuds were already in. This is a public API with no TCC
/// prompt — the app already listens to the same property in VolumeManager.
/// Appended here rather than in a new .swift file (pbxproj discipline).
/// 🔴 11-22: 4s system_profiler 轮询被实测证实拖慢 AirPods 跨设备切换，本类
/// 从「连接卡事件的补充」升级为实时检测的主信号源。现在监听两个属性：
/// 默认输出切换（AirPods 接管/交还）+ 音频设备列表变化（AirPods 已出现在
/// 系统里但尚未被确认为默认输出，比如连接确认气泡还挂着的情况）。两个源
/// 都汇到 PeripheralBatteryManager.handleAudioEvent() 合并处理。
final class AudioDeviceConnectionWatcher {
    static let shared = AudioDeviceConnectionWatcher()

    private var started = false
    private var addresses: [AudioObjectPropertyAddress] = []
    private var blocks: [AudioObjectPropertyListenerBlock] = []
    private let queue = DispatchQueue(label: "com.notchisland.audio-device-watcher")

    func start() {
        guard !started else { return }
        started = true
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ]
        for selector in selectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in
                    PeripheralBatteryManager.shared.handleAudioEvent()
                }
            }
            guard AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
            ) == noErr else { continue }
            addresses.append(addr)
            blocks.append(block)
        }
    }
}

// MARK: - Trace (11-15)

enum AirPodsTrace {
    nonisolated static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("bn-airpods.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - 系统状态气泡统一收口（11-15 13:31）

/// 用户要求「这样的弹窗都要到灵动岛统一弹窗」：macOS 在菜单栏附近画的
/// 蓝牙/音频设备提示（连接、已转移到 iPhone、断开…）不再单独出现，
/// 原文和它自带的按钮一起搬进灵动岛卡。
/// 🔴 绝不自动按按钮（13:01「不要自动连啊，跟系统一样我自己点啊」）：
/// 只有用户点岛上的按钮时，才对已挪到屏外的窗口执行 AXPress。
/// helper 的 NotificationWatcher 已验证「窗口离屏后 AXUIElementPerformAction 仍有效」。

private struct BubbleCandidate: Sendable {
    let number: Int
    let pid: pid_t
    let owner: String
}

final class BluetoothPromptHider {
    static let shared = BluetoothPromptHider()

    private var timer: DispatchSourceTimer?
    private var lastSampleAt: Date = .distantPast
    private var handledWindowNumber: Int?
    private var handledAt: Date = .distantPast

    func start() {
        guard timer == nil else { return }
        AirPodsTrace.log("hider start axTrusted=\(AXIsProcessTrusted())")
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    private func scan() {
        guard let list = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let candidates = bubbleCandidates(in: list)
        if Date().timeIntervalSince(lastSampleAt) > 20 {
            lastSampleAt = Date()
            // Record EVERY window in the top band with its real geometry, even
            // when it does not match the candidate filter. If the next real
            // bubble falls outside the filter, this line is what tells us the
            // exact size/layer to widen it to — no guessing (docs/04 S5).
            let top: [String] = list.compactMap { w in
                guard let owner = w[kCGWindowOwnerName as String] as? String else { return nil }
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let y = b["Y"] as? Double ?? 0
                guard y >= -30, y < 160 else { return nil }
                let wd = b["Width"] as? Double ?? 0
                let ht = b["Height"] as? Double ?? 0
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                return "\(owner)#\(Int(wd))x\(Int(ht))@\(Int(y))L\(layer)"
            }
            AirPodsTrace.log("top windows=\(top.prefix(20).joined(separator: " | "))")
            AirPodsTrace.log("bubble candidates=\(candidates.map { "\($0.owner)#\($0.number)" }.joined(separator: " | "))")
        }
        for candidate in candidates {
            Task { @MainActor in
                BluetoothPromptHider.shared.handle(candidate)
            }
        }
    }

    /// 顶部的小浮层就是这类系统气泡的形状。不靠 owner 名字——本机实测
    /// 气泡归属进程名里没有 "Bluetooth"，上一版因此一次都没命中。
    private func bubbleCandidates(in list: [[String: Any]]) -> [BubbleCandidate] {
        var out: [BubbleCandidate] = []
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }
            if owner == "Notch Island" || owner == "Notch Island" { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let y = b["Y"] as? Double ?? 0
            let wd = b["Width"] as? Double ?? 0
            let ht = b["Height"] as? Double ?? 0
            guard y >= -30, y < 160, wd >= 80, wd <= 700, ht >= 18, ht <= 160 else { continue }
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let number = w[kCGWindowNumber as String] as? Int else { continue }
            out.append(BubbleCandidate(number: number, pid: pid_t(pid), owner: owner))
        }
        return out
    }

    @MainActor
    private func handle(_ candidate: BubbleCandidate) {
        if handledWindowNumber == candidate.number,
           Date().timeIntervalSince(handledAt) < 30 { return }
        guard AXIsProcessTrusted() else {
            AirPodsTrace.log("hider: no accessibility trust")
            return
        }
        guard let found = inspect(candidate.pid) else { return }
        let joined = found.texts.joined(separator: " ")
        guard looksLikeDevicePrompt(joined) else { return }

        let message = found.texts.first(where: { looksLikeStatus($0) })
            ?? found.texts.first ?? "设备状态变化"
        let device = found.texts.first(where: {
            $0 != message && !looksLikeStatus($0) && $0.count <= 24
        }) ?? "耳机"
        var buttonTitle: String?
        if let button = found.buttons.first {
            buttonTitle = button.0.isEmpty ? "连接" : button.0
        }

        var hidden = CGPoint(x: -10000, y: -10000)
        var moved = false
        if let position = AXValueCreate(.cgPoint, &hidden) {
            moved = AXUIElementSetAttributeValue(
                found.window, kAXPositionAttribute as CFString, position
            ) == .success
        }
        AirPodsTrace.log("bubble owner=\(candidate.owner) #\(candidate.number) texts=\(found.texts) button=\(buttonTitle ?? "none") hidden=\(moved)")

        handledWindowNumber = candidate.number
        handledAt = Date()
        // 隐藏失败也照样弹岛卡；日志里 hidden=false 会留证，下一轮再修。
        PeripheralBatteryManager.shared.presentSystemPrompt(
            device: device, message: message, buttonTitle: buttonTitle,
            button: found.buttons.first?.1, window: found.window
        )
    }

    /// 返回该进程里第一个「文字像设备提示」的窗口，连同其文字与按钮。
    @MainActor
    private func inspect(_ pid: pid_t) -> (window: AXUIElement, texts: [String], buttons: [(String, AXUIElement)])? {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return nil }
        for window in windows.prefix(16) {
            var texts: [String] = []
            var buttons: [(String, AXUIElement)] = []
            collect(from: window, depth: 0, texts: &texts, buttons: &buttons)
            if looksLikeDevicePrompt(texts.joined(separator: " ")) {
                return (window, texts, buttons)
            }
        }
        return nil
    }

    private func collect(from element: AXUIElement, depth: Int,
                         texts: inout [String], buttons: inout [(String, AXUIElement)]) {
        guard depth < 6 else { return }
        var role: CFTypeRef?, title: CFTypeRef?, value: CFTypeRef?, desc: CFTypeRef?, children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
        for item in [title, value, desc] {
            if let s = item as? String, !s.isEmpty, s.count < 80 { texts.append(s) }
        }
        if let r = role as? String, r == "AXButton" {
            buttons.append(((title as? String) ?? (desc as? String) ?? "连接", element))
        }
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let kids = children as? [AXUIElement] {
            for kid in kids.prefix(60) {
                collect(from: kid, depth: depth + 1, texts: &texts, buttons: &buttons)
            }
        }
    }

    private func looksLikeDevicePrompt(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["airpods", "蓝牙", "连接", "connect", "转移", "iphone", "已断开", "耳机"]
            .contains { t.contains($0) }
    }

    private func looksLikeStatus(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["转移", "连接", "断开", "iphone", "已", "connect", "disconnect"]
            .contains { t.contains($0) }
    }
}

// The timer callbacks run on a fixed background queue while all state reads
// and writes happen inside @MainActor methods; there is no shared mutable
// state crossing the boundary.
extension BluetoothPromptHider: @unchecked Sendable {}
