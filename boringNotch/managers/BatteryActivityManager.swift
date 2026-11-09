import Combine
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

    private var pollTask: Task<Void, Never>?
    private var knownDevices: [PeripheralDeviceBattery] = []
    private var alertedLowDevices: Set<String> = []
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
        pollTask = Task { [weak self] in
            // Give launch some breathing room; system_profiler is not cheap.
            try? await Task.sleep(for: .seconds(15))
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

        if previous.isEmpty {
            // Baseline: don't greet devices that were already connected.
            return
        }

        // system_profiler can report the same device more than once (the same
        // unit under two sections, or a duplicated entry). uniquingKeysWith
        // keeps the first occurrence — uniqueKeysWithValues would trap on the
        // duplicate and take the whole app down.
        let previousByName = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for device in snapshot where device.hasBattery {
            guard let old = previousByName[device.name] else {
                // Newly connected: greet it and (re)arm the low-battery alert.
                alertedLowDevices.remove(device.name)
                peek(device)
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

    private func peek(_ device: PeripheralDeviceBattery) {
        peekDevice = device
        NotchUIEventBus.events.send(.expandingView(type: .peripheralBattery))
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
