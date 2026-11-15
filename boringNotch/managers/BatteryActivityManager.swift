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
        AirPodsTrace.log("peek name=\(device.name) connection=\(isConnection) level=\(device.overallLevel.map(String.init) ?? "-")")
        NotchUIEventBus.events.send(.expandingView(type: .peripheralBattery))
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

// MARK: - Hide the system Bluetooth prompt (11-15)

/// The user wants macOS's own AirPods prompt gone and only the island card.
/// Window-list scanning needs no TCC permission; parking the window off-screen
/// uses the same AX technique as NotificationWatcher.hide. A prompt that still
/// has a "Connect" button is left alone — hiding a confirmation the user must
/// click would make the device impossible to pair.
final class BluetoothPromptHider {
    static let shared = BluetoothPromptHider()

    private var timer: DispatchSourceTimer?
    private var lastTriggerAt: Date = .distantPast
    private var lastSampleAt: Date = .distantPast
    private var lastPressAt: Date = .distantPast

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

        //定期采样：万一系统弹窗的 owner 不带 "Bluetooth"，下一次连一次耳机
        //就能从日志里看到真实窗口名，不用再猜。
        if Date().timeIntervalSince(lastSampleAt) > 20 {
            lastSampleAt = Date()
            let sample: [String] = list.compactMap { w in
                guard let owner = w[kCGWindowOwnerName as String] as? String else { return nil }
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let wd = b["Width"] as? Double ?? 0
                let ht = b["Height"] as? Double ?? 0
                guard wd > 60, wd < 1000, ht > 40, ht < 800 else { return nil }
                let name = w[kCGWindowName as String] as? String ?? ""
                return "\(owner):\(name)"
            }
            AirPodsTrace.log("windows sample=\(sample.prefix(12).joined(separator: " | "))")
        }

        var matchedPID: pid_t?
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }
            let name = w[kCGWindowName as String] as? String ?? ""
            let ownerHit = owner.localizedCaseInsensitiveContains("bluetooth")
            let nameHit = name.localizedCaseInsensitiveContains("airpods")
                || name.localizedCaseInsensitiveContains("蓝牙")
            guard ownerHit || nameHit else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  x > -9000, y > -9000,
                  let width = b["Width"] as? Double, width > 60, width < 1000,
                  let height = b["Height"] as? Double, height > 40, height < 800,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32
            else { continue }
            matchedPID = pid_t(pid)
            AirPodsTrace.log("prompt owner=\(owner) name=\(name) pid=\(pid) bounds=\(b)")
            break
        }
        guard let pid = matchedPID else { return }

        // A prompt stays up for a few seconds; don't queue a snapshot per tick.
        if Date().timeIntervalSince(lastTriggerAt) > 6 {
            lastTriggerAt = Date()
            Task { @MainActor in
                await PeripheralBatteryManager.shared.handlePossibleConnection()
            }
        }
        hideSystemPrompt(pid: pid)
    }

    private func hideSystemPrompt(pid: pid_t) {
        guard AXIsProcessTrusted() else {
            AirPodsTrace.log("hide skipped: no accessibility trust")
            return
        }
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return }
        for window in windows {
            if let button = connectButton(in: window) {
                // macOS often asks the user to confirm ("Connect"). Pressing
                // it is what actually connects the earbuds — parking the
                // dialog without pressing would leave them unpaired and the
                // island card would have no battery to show. Once pressed the
                // system dismisses its own dialog; no window move needed.
                if Date().timeIntervalSince(lastPressAt) > 10 {
                    lastPressAt = Date()
                    let pressed = AXUIElementPerformAction(button, "AXPress" as CFString) == .success
                    AirPodsTrace.log("press Connect=\(pressed)")
                }
                continue
            }
            var hidden = CGPoint(x: -10000, y: -10000)
            guard let position = AXValueCreate(.cgPoint, &hidden) else { continue }
            let moved = AXUIElementSetAttributeValue(
                window, kAXPositionAttribute as CFString, position
            ) == .success
            AirPodsTrace.log("hide move=\(moved)")
        }
    }

    private func connectButton(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 5 else { return nil }
        var roleRaw: CFTypeRef?
        var titleRaw: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRaw)
        if let role = roleRaw as? String, role == "AXButton",
           let title = titleRaw as? String,
           title.localizedCaseInsensitiveContains("连接")
            || title.localizedCaseInsensitiveContains("connect") {
            return element
        }
        var childrenRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRaw) == .success,
              let children = childrenRaw as? [AXUIElement] else { return nil }
        for child in children.prefix(60) {
            if let found = connectButton(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
