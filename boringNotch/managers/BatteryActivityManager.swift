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
    var looksLikeHeadphones: Bool {
        if icon == "headphones" { return true }
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
        BluetoothPromptHider.shared.start()
        // 11-15: 15s + 30s was far too slow for "the moment AirPods connect",
        // and CoreAudio alone is not enough (macOS often asks the user to
        // confirm the connection first, so the output device never switches).
        // system_profiler stays on a background queue; 2s/4s is responsive
        // without a permanent busy loop.
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(4))
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

        for device in snapshot where device.hasBattery {
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
    }

    private func crossedLowThreshold(old: PeripheralDeviceBattery, new: PeripheralDeviceBattery) -> Bool {
        guard let newLowest = new.lowestLevel,
              newLowest <= Self.lowBatteryThreshold else { return false }
        if let oldLowest = old.lowestLevel, oldLowest <= Self.lowBatteryThreshold { return false }
        return true
    }

    private func peek(_ device: PeripheralDeviceBattery, isConnection: Bool = false) {
        if isConnection {
            if let last = lastConnectionPeekAt[device.name],
               Date().timeIntervalSince(last) < 30 { return }
            lastConnectionPeekAt[device.name] = Date()
        }
        peekDevice = device
        isConnectionPeek = isConnection
        clearSystemPrompt()
        AirPodsTrace.log("peek name=\(device.name) connection=\(isConnection) level=\(device.overallLevel.map(String.init) ?? "-")")
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
            let found = snapshot.first {
                $0.hasBattery && $0.looksLikeHeadphones && !before.contains($0.name)
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
        return parseBluetoothReport(data)
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
                devices.append(
                    PeripheralDeviceBattery(
                        name: name,
                        icon: icon(for: minorType),
                        main: percentValue(properties["device_batteryLevelMain"]),
                        left: percentValue(properties["device_batteryLevelLeft"]),
                        right: percentValue(properties["device_batteryLevelRight"]),
                        caseLevel: percentValue(properties["device_batteryLevelCase"])
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

    nonisolated private static func icon(for minorType: String) -> String {
        let type = minorType.lowercased()
        if type.contains("headphone") { return "headphones" }
        if type.contains("keyboard") { return "keyboard" }
        if type.contains("mouse") { return "computermouse" }
        if type.contains("trackpad") { return "trackpad" }
        if type.contains("game") { return "gamecontroller" }
        if type.contains("speaker") { return "hifispeaker" }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - Instant headphone connection trigger (11-15)

/// CoreAudio reports the default output device changing the moment AirPods
/// take over. Polling alone took up to 30s, so the connection card arrived
/// long after the earbuds were already in. This is a public API with no TCC
/// prompt — the app already listens to the same property in VolumeManager.
/// Appended here rather than in a new .swift file (pbxproj discipline).
final class AudioDeviceConnectionWatcher {
    static let shared = AudioDeviceConnectionWatcher()

    private var started = false
    private var address: AudioObjectPropertyAddress?
    private var listener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.notchisland.audio-device-watcher")

    func start() {
        guard !started else { return }
        started = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                await PeripheralBatteryManager.shared.handlePossibleConnection()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
        ) == noErr else { return }
        address = addr
        listener = block
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
            if owner == "Notch Island" || owner == "Boring Notch" { continue }
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
