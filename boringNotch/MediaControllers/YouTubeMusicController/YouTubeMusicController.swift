//
//  YouTubeMusicController.swift
//  boringNotch
//
//  Created By Alexander on 2025-03-30.
//  Modified by Pranav on 2025-06-16.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class YouTubeMusicController: MediaControllerProtocol {
    // MARK: - Published Properties
    @Published var playbackState = PlaybackState(
        bundleIdentifier: YouTubeMusicConfiguration.default.bundleIdentifier
    )

    private var artworkFetchTask: Task<Void, Never>?

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    var supportsFavorite: Bool { true }

    func setFavorite(_ favorite: Bool) async {
        do {
            let token = try await authManager.authenticate()
            if favorite && !playbackState.isFavorite {
                _ = try await httpClient.toggleLike(token: token)
            } else if !favorite && playbackState.isFavorite {
                _ = try await httpClient.toggleLike(token: token)
            }
            try? await Task.sleep(for: .milliseconds(150))
            await updatePlaybackInfo()
        } catch {
            Log.music.error("[YouTubeMusicController] Failed to set favorite: \(error)")
        }
    }

    // MARK: - Private Properties
    private let configuration: YouTubeMusicConfiguration
    private let httpClient: YouTubeMusicHTTPClient
    private let authManager: YouTubeMusicAuthManager
    private var webSocketClient: YouTubeMusicWebSocketClient?

    private var updateTimer: Timer?
    /// App launch/terminate observers; removed when this controller deallocates.
    private let workspaceObservers = WorkspaceNotificationObservers()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1.0

    // MARK: - Initialization
    init(configuration: YouTubeMusicConfiguration = .default) {
        self.configuration = configuration
        self.httpClient = YouTubeMusicHTTPClient(baseURL: configuration.baseURL)
        self.authManager = YouTubeMusicAuthManager(httpClient: httpClient)

        setupAppStateObserver()

        Task {
            await initializeIfAppActive()
        }
    }

    deinit {
        artworkFetchTask?.cancel()
        reconnectTask?.cancel()
        updateTimer?.invalidate()

        if let webSocketClient {
            Task {
                await webSocketClient.disconnect()
            }
        }
    }

    // MARK: - MediaControllerProtocol Implementation
    func play() async { await sendCommand(endpoint: "/play", method: "POST") }

    func pause() async { await sendCommand(endpoint: "/pause", method: "POST") }

    func togglePlay() async {
        if !isActive() { launchApp() }
        await sendCommand(endpoint: "/toggle-play", method: "POST")
    }

    func nextTrack() async { await sendCommand(endpoint: "/next", method: "POST") }

    func previousTrack() async { await sendCommand(endpoint: "/previous", method: "POST") }

    func seek(to time: Double) async {
        let payload = ["seconds": time]
        await sendCommand(endpoint: "/seek-to", method: "POST", body: payload)
    }

    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        let payload = ["volume": volumePercentage]
        await sendCommand(endpoint: "/volume", method: "POST", body: payload)
    }
    func fetchShuffleState() async { await sendCommand(endpoint: "/shuffle", method: "GET", refresh: false) }
    func fetchRepeatMode() async { await sendCommand(endpoint: "/repeat-mode", method: "GET", refresh: false) }

    func toggleShuffle() async { await sendCommand(endpoint: "/shuffle", method: "POST") }
    func toggleRepeat() async { await sendCommand(endpoint: "/switch-repeat", method: "POST") }

    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == configuration.bundleIdentifier
        }
    }

    func updatePlaybackInfo() async {
        guard isActive() else {
            resetPlaybackState()
            return
        }

        do {
            let token = try await authManager.authenticate()
            let response = try await httpClient.getPlaybackInfo(token: token)
            await updatePlaybackState(with: response)
            // Fetch like state if supported
            do {
                let likeResp = try await httpClient.getLikeState(token: token)
                var newState = playbackState
                    if let state = likeResp.state {
                        switch state.uppercased() {
                        case "LIKE":
                            newState.isFavorite = true
                        case "DISLIKE":
                            // We don't have a separate dislike UI yet, treat as not favorited
                            newState.isFavorite = false
                        default:
                            newState.isFavorite = false
                        }
                    } else {
                        newState.isFavorite = false
                    }
                playbackState = newState
            } catch {
                // Don't treat it as an error if the like endpoint doesn't exist — just skip
            }
        } catch YouTubeMusicError.authenticationRequired {
            await authManager.invalidateToken()
        } catch {
            Log.music.error("[YouTubeMusicController] Failed to update playback info: \(error)")
        }
    }

    // MARK: - Private Methods

    /// Block-based NSWorkspace observers instead of `Task` + `withTaskGroup`
    /// over `notifications(named:)`: those child tasks wait on an async
    /// sequence that does not end when the parent task is cancelled, so a new
    /// controller per media-source switch left a set of live subscriptions
    /// (and their parent task) behind. Tokens are removed in `deinit`.
    private func setupAppStateObserver() {
        workspaceObservers.add(forName: NSWorkspace.didLaunchApplicationNotification) { [weak self] notification in
            let bundleID = Self.bundleIdentifier(of: notification)
            Task { @MainActor [weak self] in
                await self?.handleAppLaunched(bundleID: bundleID)
            }
        }

        workspaceObservers.add(forName: NSWorkspace.didTerminateApplicationNotification) { [weak self] notification in
            let bundleID = Self.bundleIdentifier(of: notification)
            Task { @MainActor [weak self] in
                await self?.handleAppTerminated(bundleID: bundleID)
            }
        }
    }

    private nonisolated static func bundleIdentifier(of notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func handleAppLaunched(bundleID: String?) async {
        guard bundleID == configuration.bundleIdentifier else {
            return
        }

        cancelReconnect(resetDelay: true)
        await initializeIfAppActive()
    }

    private func handleAppTerminated(bundleID: String?) async {
        guard bundleID == configuration.bundleIdentifier else {
            return
        }

        let disconnectedClient = takeWebSocketClient()

        Task { @MainActor in
            stopPeriodicUpdates()
            // NOTE: Do NOT remove the app-state observers here.
            // They must stay alive to detect when the app launches again.
        }

        cancelReconnect(resetDelay: true)
        resetPlaybackState()
        disconnectClient(disconnectedClient)
    }

    private func initializeIfAppActive() async {
        guard isActive() else { return }

        cancelReconnect(resetDelay: false)

        if await hasActiveWebSocketConnection() {
            await updatePlaybackInfo()
            return
        }

        do {
            let token = try await authManager.authenticate()
            await setupWebSocketIfPossible(token: token)
            await startPeriodicUpdates()
            await updatePlaybackInfo()
        } catch {
            Log.music.error("[YouTubeMusicController] Failed to initialize: \(error)")
            scheduleReconnect()
        }
    }

    private func setupWebSocketIfPossible(token: String) async {
        guard let wsURL = WebSocketURLBuilder.buildURL(from: configuration.baseURL) else {
            Log.music.error("[YouTubeMusicController] Failed to build WebSocket URL")
            return
        }

        let client = YouTubeMusicWebSocketClient(
            onMessage: { [weak self] data in
                await self?.handleWebSocketMessage(data)
            },
            onDisconnect: { [weak self] in
                await self?.handleWebSocketDisconnect()
            }
        )

        do {
            try await client.connect(to: wsURL, with: token)
            activateWebSocket(client)
        } catch {
            Log.music.error("[YouTubeMusicController] WebSocket connection failed: \(error)")
            scheduleReconnect()
        }
    }

    private func handleWebSocketMessage(_ data: Data) async {
        guard let message = WebSocketMessage(from: data) else {
            if let response = try? JSONDecoder().decode(PlaybackResponse.self, from: data) {
                await updatePlaybackState(with: response)
            }
            return
        }
        switch message.type {
        case .playerInfo, .videoChanged, .playerStateChanged:
            if let data = message.extractData(),
               let response = PlaybackResponse.from(websocketData: data) {
                await updatePlaybackState(with: response)
            }

        case .positionChanged:
            guard let data = message.extractData() else { return }

            var position: Double?
            if let pos = data["position"] as? Double {
                position = pos
            } else if let elapsed = data["elapsedSeconds"] as? Double {
                position = elapsed
            }
            guard let newPosition = position else { return }

            // Threshold position updates: the websocket pushes ~1/s (often
            // more), and an always-new lastUpdated defeated the Equatable
            // check so every tick republished the whole playback state.
            guard abs(newPosition - playbackState.currentTime) > 0.25 else { return }
            var copied = playbackState
            copied.currentTime = newPosition
            copied.lastUpdated = Date()
            playbackState = copied

        case .repeatChanged:
            guard let data = message.extractData() else { return }
            var copy = playbackState

            if let repeatStr = data["repeat"] as? String {
                switch repeatStr.uppercased() {
                case "NONE": copy.repeatMode = .off
                case "ALL": copy.repeatMode = .all
                case "ONE": copy.repeatMode = .one
                default: break
                }
            }
            copy.lastUpdated = Date()
            if copy != playbackState { playbackState = copy }

        case .shuffleChanged:
            guard let data = message.extractData() else { return }
            var copy = playbackState
            if let shuffle = data["shuffle"] as? Bool { copy.isShuffled = shuffle } else if let shuffle = data["isShuffled"] as? Bool { copy.isShuffled = shuffle }
            copy.lastUpdated = Date()
            if copy != playbackState { playbackState = copy }

        case .volumeChanged:
            guard let data = message.extractData() else { return }
            var copy = playbackState
            if let volume = data["volume"] as? Double {
                copy.volume = volume / 100.0
            } else if let volume = data["volume"] as? Int {
                copy.volume = Double(volume) / 100.0
            }
            copy.lastUpdated = Date()
            if copy != playbackState { playbackState = copy }
        }
    }

    private func handleWebSocketDisconnect() async {
        _ = takeWebSocketClient()
        await startPeriodicUpdates() // Fallback to polling
        scheduleReconnect()
    }

    private func hasActiveWebSocketConnection() async -> Bool {
        guard let currentClient = webSocketClient else { return false }

        let isConnected = await currentClient.isConnected
        if !isConnected, webSocketClient === currentClient {
            webSocketClient = nil
        }

        return isConnected
    }

    private func cancelReconnect(resetDelay: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil

        if resetDelay {
            reconnectDelay = configuration.reconnectDelay.lowerBound
        }
    }

    private func takeWebSocketClient() -> YouTubeMusicWebSocketClient? {
        let currentClient = webSocketClient
        webSocketClient = nil
        return currentClient
    }

    private func activateWebSocket(_ client: YouTubeMusicWebSocketClient) {
        webSocketClient = client
        cancelReconnect(resetDelay: true)
        stopPeriodicUpdates() // WebSocket will provide real-time updates
    }

    private func disconnectClient(_ client: YouTubeMusicWebSocketClient?) {
        Task {
            await client?.disconnect()
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        let delay = reconnectDelay
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }

            self.reconnectTask = nil
            self.reconnectDelay = min(delay * 2, self.configuration.reconnectDelay.upperBound)

            guard self.isActive(), self.webSocketClient == nil else { return }
            await self.initializeIfAppActive()
        }
    }

    private func startPeriodicUpdates() async {
        guard isActive() && webSocketClient == nil else { return }

        stopPeriodicUpdates()

        updateTimer = Timer.scheduledTimer(withTimeInterval: configuration.updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePlaybackInfo()
            }
        }
    }

    private func stopPeriodicUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func pollPlaybackState() async {
        if !isActive() {
            return
        }

        await fetchRepeatMode()
        await fetchShuffleState()
        await updatePlaybackInfo()
    }

    private func sendCommand(
        endpoint: String,
        method: String = "POST",
        body: (any Codable & Sendable)? = nil,
        refresh: Bool = true
    ) async {
        do {
            let token = try await authManager.authenticate()

            let data = try await httpClient.sendCommand(
                endpoint: endpoint,
                method: method,
                body: body,
                token: token
            )
            // Lightweight endpoint-specific parsing
            if endpoint == "/shuffle" {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let shuffleState = json["state"] as? Bool {
                    playbackState.isShuffled = shuffleState
                } else {
                    playbackState.isShuffled = !playbackState.isShuffled
                }
            } else if endpoint == "/repeat-mode" {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let mode = json["mode"] as? String { updateRepeatMode(mode) }
                }
            } else if endpoint == "/switch-repeat" {
                // Find next repeat mode
                let nextMode: RepeatMode
                switch playbackState.repeatMode {
                case .off: nextMode = .all
                case .all: nextMode = .one
                case .one: nextMode = .off
                }
                playbackState.repeatMode = nextMode
            } else if refresh && webSocketClient == nil {
                try? await Task.sleep(for: .milliseconds(100))
                await updatePlaybackInfo()
            }
        } catch YouTubeMusicError.authenticationRequired {
            await authManager.invalidateToken()
        } catch {
            Log.music.error("[YouTubeMusicController] Command failed: \(error)")
        }
    }

    private func updatePlaybackState(with response: PlaybackResponse) async {
        var newState = playbackState

        newState.isPlaying = !response.isPaused

        if let title = response.title {
            newState.title = title
        }

        if let artist = response.artist {
            newState.artist = artist
        }

        if let album = response.album {
            newState.album = album
        }

        if let elapsed = response.elapsedSeconds {
            newState.currentTime = elapsed
        }

        if let duration = response.songDuration {
            newState.duration = duration
        }

        newState.lastUpdated = Date()

        if let shuffled = response.isShuffled {
            newState.isShuffled = shuffled
        }

        if let mode = response.repeatMode {
            switch mode {
            case 0: newState.repeatMode = .off
            case 1: newState.repeatMode = .all
            case 2: newState.repeatMode = .one
            default: break
            }
        }

        if let volume = response.volume {
            newState.volume = volume / 100.0
        }

        if newState != playbackState {
            playbackState = newState

            artworkFetchTask?.cancel()
            artworkFetchTask = nil

            if let artworkURL = response.imageSrc,
               let url = URL(string: artworkURL) {
                artworkFetchTask = Task {
                    do {
                        let data = try await ImageService.shared.fetchImageData(from: url)
                        await MainActor.run { [weak self] in
                            self?.playbackState.artwork = data
                        }
                    } catch { /* ignore */ }
                }
            }
        }
    }

    private func resetPlaybackState() {
        playbackState = PlaybackState(
            bundleIdentifier: configuration.bundleIdentifier,
            isPlaying: false,
            lastUpdated: Date()
        )
    }

    private func launchApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: configuration.bundleIdentifier) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

     private func updateRepeatMode(_ mode: String) {
        var target: RepeatMode?
        switch mode {
            case "NONE": target = .off
            case "ALL": target = .all
            case "ONE": target = .one
            default: break
        }
        if let target, target != playbackState.repeatMode { playbackState.repeatMode = target }
    }
}

/// Owns a set of block-based notification observers and unregisters them when
/// it goes away.
///
/// The controller's `deinit` is nonisolated, and touching an `NSObjectProtocol`
/// token from there trips a concurrency warning; keeping the tokens in this box
/// makes the observer lifetime follow the controller without touching `deinit`.
private final class WorkspaceNotificationObservers: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
    }

    func add(forName name: Notification.Name, handler: @escaping @Sendable (Notification) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: handler))
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}
