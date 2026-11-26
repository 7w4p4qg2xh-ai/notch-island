//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()

    @Published var fullscreenStatus: [String: Bool] = [:]

    private var monitorTask: Task<Void, Never>?

    private init() {
        startMonitoring()
    }

    deinit {
        monitorTask?.cancel()
    }

    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                updateStatus(with: spaces)
            }
        }
    }

    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo]) {
        var newStatus: [String: Bool] = [:]

        for space in spaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                if Defaults[.hideNotchOption] == .nowPlayingOnly, let musicSourceBundle = MusicManager.shared.bundleIdentifier {
                    shouldDetect = space.runningApps.contains(musicSourceBundle)
                } else {
                    shouldDetect = true
                }
                newStatus[uuid] = shouldDetect
            }
        }

        self.fullscreenStatus = newStatus
    }
}

// MARK: - 「正在播放」卡的来源判定（2026-11-08）

/// 用户 11-08：「全屏看视频的话就不要弹那个正在播放的卡片，只针对视频
/// 播放器，我说的是正在播放的窗口」。
///
/// 那块卡由系统 now-playing 源触发，视频 App / 网页视频也会被系统当成
/// 播放源。运行期日志实测（19:49）：抖音桌面版
/// `com.bytedance.douyin.desktop`，title=「抖音-记录美好生活」、artist 为空，
/// 于是看视频时浮岛一直挂着一块没有歌手、也没有歌词的「正在播放」卡。
///
/// 这里按**播放源本身**判定，而不是按 `FullScreenMonitor` 的全屏 space：
/// 后者只认带 TileLayoutManager 的 macOS 原生全屏空间，网页全屏、应用内
/// 全屏（抖音、B 站网页、YouTube）都不会创建那种空间，按全屏判必然漏。
/// 用户要的是「只针对视频播放器」，所以其余来源一概保持原行为。
enum NowPlayingCardEligibility {
    /// 已知音乐 App：即使某帧元数据没到齐，也照常显示卡片。
    private static let musicBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.apple.Music.classical",
        "com.apple.iTunes",
        "com.spotify.client",
        "com.tencent.QQMusicMac",
        "com.tencent.QQMusic",
        "com.netease.163music",
        "com.netease.macmusic",
        "com.kugou.kugouMac",
        "com.kuwo.kwplayer.mac",
        "com.tidal.desktop",
        "com.aspiro.TIDAL",
        "com.deezer.Deezer",
        "com.soundcloud.desktop",
        "com.coppertino.VOX",
        "com.swinsian.Swinsian",
    ]

    /// - Parameter bundleIdentifier: 当前 now-playing 源（可能为 nil）
    /// - Parameter artist: 当前曲目的艺术家；网页视频 / 短视频通常为空
    static func allowsCard(bundleIdentifier: String?, artist: String) -> Bool {
        // 来源未知时保持原行为，别把 Apple Music 首发那几帧一起误伤。
        guard let id = bundleIdentifier, !id.isEmpty else { return true }
        if musicBundleIDs.contains(id)
            || id.hasPrefix("com.apple.Music")
            || id.hasPrefix("com.spotify") { return true }

        // 非音乐 App 只有给出真正的艺术家才算「一首歌」：
        // 浏览器里听 YouTube Music 有 artist，网页视频 / 短视频只有标题。
        return !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
