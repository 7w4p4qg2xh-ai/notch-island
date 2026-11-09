//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

/// 取证开关：`touch /tmp/bn-notch.debug` 之后，通知弹窗链路上的关键判定会追加
/// 写进 `/tmp/bn-notch.log`（helper 的 NSLog 进不了 `log show`，app 侧也同理）。
/// 不用了就删掉那个开关文件。
func bnDebugLog(_ message: String) {
    guard FileManager.default.fileExists(atPath: "/tmp/bn-notch.debug") else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let line = "\(formatter.string(from: Date())) \(message)\n"
    let path = "/tmp/bn-notch.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    /// Lyrics live in their own service now; observing it makes a freshly
    /// fetched LRC appear on the next frame instead of waiting for a redraw.
    @ObservedObject var lyricsService = LyricsService.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var peripheralBatteryModel = PeripheralBatteryManager.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @ObservedObject var notificationManager = SystemNotificationManager.shared
    /// Which entry of the closed-notch activity stack is on top.
    @State private var activityIndex: Int = 0
    @State private var hoverTask: Task<Void, Never>?
    @State private var notificationPeekTask: Task<Void, Never>?
    @State private var isNotificationPeeking = false
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero
    @State private var horizontalMediaGestureTriggered = false
    @State private var horizontalMediaGestureFeedback: CGFloat = .zero
    @State private var isHoveringMusicArea = false

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.showNotHumanFace) var showNotHumanFace
    /// Toggling this has to redraw the plate immediately, so it is a
    /// `@Default` rather than a `Defaults[...]` read inside body.
    @Default(.hideIdlePlateOnNonNotch) var hideIdlePlateOnNonNotch
    /// Same reasoning as above: flipping it must redraw the plate at once.
    @Default(.floatingPillOnNonNotchDisplay) var floatingPillOnNonNotch

    // 浮岛几何（11-09）：设置页拖动滑块要立刻重排版面，所以同样必须是
    // `@Default` 而不是 body 里现读 —— `Defaults[...]` 不是响应式的，
    // 用它做尺寸会让滑块拖完整页不动，直到窗口重建。
    @Default(.islandCardWidth) var islandCardWidthSetting
    @Default(.islandCardCornerRadius) var islandCardCornerRadiusSetting
    @Default(.islandPanelWidth) var islandPanelWidthSetting
    @Default(.islandPanelHeight) var islandPanelHeightSetting
    @Default(.closedPillGlassEnabled) var closedPillGlassEnabled
    @Default(.islandMusicCardEnabled) var islandMusicCardEnabled

    // Use standardized animations from StandardAnimations enum
    private let animationSpring = StandardAnimations.interactive

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10
    private let nowPlayingFallbackNoticeWidth: CGFloat = 330
    /// Matches the popovers' dismiss delay; long enough to reach a control
    /// inside the panel without closing under the pointer.
    private let hoverExitDelayMilliseconds = 350

    // MARK: - Corner Radius Scaling
    private var cornerRadiusScaleFactor: CGFloat? {
        guard Defaults[.cornerRadiusScaling] else { return nil }
        let effectiveHeight = displayClosedNotchHeight
        guard effectiveHeight > 0 else { return nil }
        return effectiveHeight / 38.0
    }

    /// Compact mode gets a rounder opened shape (35 vs 19) — at its smaller
    /// size the standard radius reads square rather than pill-like.
    private var openedInsets: (top: CGFloat, bottom: CGFloat) {
        Defaults[.compactMode] ? compactCornerRadiusInsets.opened : cornerRadiusInsets.opened
    }

    private var topCornerRadius: CGFloat {
        // If the notch is open, return the opened radius.
        if vm.notchState == .open {
            return openedInsets.top
        }

        // For the closed notch, scale if enabled
        let baseClosedTop = cornerRadiusInsets.closed.top
        guard let scaleFactor = cornerRadiusScaleFactor else {
            return displayClosedNotchHeight > 0 ? baseClosedTop : 0
        }
        return max(0, baseClosedTop * scaleFactor)
    }

    /// Bottom corner radius for the current state. Pulled out of
    /// `currentNotchShape` so the glass surface can round its lens edge with
    /// the same number the clip shape uses.
    private var bottomCornerRadius: CGFloat {
        // Scale bottom corner radius for closed notch shape when scaling is enabled.
        let baseClosedBottom = cornerRadiusInsets.closed.bottom

        if vm.notchState == .open {
            return openedInsets.bottom
        } else if let scaleFactor = cornerRadiusScaleFactor {
            return max(0, baseClosedBottom * scaleFactor)
        } else {
            return displayClosedNotchHeight > 0 ? baseClosedBottom : 0
        }
    }

    /// Glass applies to every opened panel — including a mirrored
    /// notification. The notification keeps its glass; readability comes from
    /// a *uniform* darkening wash on the surface (see `minimumScrim`), not
    /// from switching the material off. Turning the glass off entirely was a
    /// wrong call: the user never asked for that (docs/04 section I).
    private var liquidGlassActive: Bool {
        Defaults[.enableLiquidGlass] && vm.notchState == .open
    }

    /// A mirrored notification drawn in the OPEN panel — either the automatic
    /// peek or the hover-expanded card. The closed-state notification pill is
    /// a completely different view, so every geometry change below must gate
    /// on `notchState` too; otherwise a closed pill would be stretched to
    /// 520pt and lose its shape.
    private var showsNotificationCard: Bool {
        vm.notchState == .open && notificationManager.activeNotification != nil
    }

    /// The closed island's own "now playing" card (11-07). It is NOT the
    /// hand-opened player. A notification outranks music — `liveActivities`
    /// puts it first — so an incoming message takes over without any extra
    /// restore bookkeeping. Playing only: pausing collapses back to the
    /// 185×24 capsule. Gated on `usesFloatingIsland` so the built-in notched
    /// display keeps its original music live activity untouched.
    private var showsMusicCard: Bool {
        guard islandMusicCardEnabled,
              usesFloatingIsland,
              allowsNowPlayingCard,
              vm.notchState == .closed,
              !vm.hideOnClosed,
              // A volume/brightness HUD draws in the same closed slot. If the
              // plate stayed 408×66 while that row is on top, it would be a
              // wide empty card (docs/04 F: judge by content, not by notch).
              !coordinator.shouldShowSneakPeek(on: vm.screenUUID),
              notificationManager.activeNotification == nil,
              musicManager.isPlaying,
              let first = liveActivities.first else { return false }
        if case .music = first { return true }
        return false
    }

    /// 11-08 用户：「全屏看视频的话就不要弹那个正在播放的卡片，只针对视频
    /// 播放器，我说的是正在播放的窗口」。
    ///
    /// 那块 408×66 的卡由系统的 now-playing 源触发，但视频 App / 网页视频
    /// 同样会被系统当成播放源（运行期实测：抖音桌面版
    /// com.bytedance.douyin.desktop，title=「抖音-记录美好生活」、artist 为空），
    /// 于是看视频时浮岛一直挂着一块既没有歌手也没有歌词的「正在播放」卡。
    /// 判定按**播放源本身**，不按系统全屏 space：MacroVisionKit 只认
    /// TileLayoutManager 的原生全屏空间，网页 / 应用内全屏会漏判。
    /// 只作用于浮岛；内建刘海屏的 MusicLiveActivity 一行不动。
    private var allowsNowPlayingCard: Bool {
        guard usesFloatingIsland else { return true }
        return NowPlayingCardEligibility.allowsCard(
            bundleIdentifier: musicManager.bundleIdentifier,
            artist: musicManager.artistName
        )
    }

    /// 11-08 用户：「Mac 自己屏幕放音乐没有办法显示歌词」「加上一个显示歌词的开关，
    /// 然后用液态玻璃显示歌词，不要上下太宽」。
    ///
    /// 硬件刘海屏的收起态中间是物理摄像头切口，那块纯黑板不能写字（相机
    /// 挖孔处屏幕没有像素），所以歌词不塞进刘海，而是在黑板下沿挂一条
    /// **独立**的 320×26 细玻璃带。收起黑板、摄像头遮罩、通知排版、
    /// 内建屏所有原值、外接屏的 408×66 音乐卡一律不动；这是内建屏唯一
    /// 新增的可见内容，可用设置开关整体关掉。
    private var showsNotchedLyricsStrip: Bool {
        guard Defaults[.showLyricsOnNotchedDisplay],
              vm.hasNotch,
              !usesFloatingIsland,
              vm.notchState == .closed,
              !vm.hideOnClosed,
              !suppressesMainPlate,
              musicManager.isPlaying,
              Defaults[.enableLyrics],
              notificationManager.activeNotification == nil,
              !coordinator.shouldShowSneakPeek(on: vm.screenUUID)
        else { return false }
        // 没有时间轴、也没有纯文本歌词时不要挂一条空玻璃。视频 App 常被
        // 系统当成 now-playing 源（11-08 实测抖音桌面版），那种情况本来
        // 就没有歌词，只显示标题反而像坏掉。
        return !lyricsService.syncedLyrics.isEmpty
            || !lyricsService.currentLyrics
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Apple's Dynamic Island / Vision panel corner spec (36–44pt), used as an
    /// UPPER BOUND rather than a fixed value. A continuous corner spans
    /// 1.528665·r in both axes, so 36 only fits a card at least 110pt tall —
    /// the hand-opened panel (150pt) keeps it, while the notification card is
    /// only ~66pt tall and drops to ~16 via `NotchShape.cornerHeightRatio`
    /// (0.24·h, Apple's own ratio). Forcing 36 there made SwiftUI squeeze the
    /// corner into a 1.53:1 ellipse instead of a circle.
    private var islandCardRadius: CGFloat { CGFloat(islandCardCornerRadiusSetting) }

    /// Apple HIG "Live Activities" gives iPadOS cards 425–500pt and macOS
    /// (which reuses the iOS sizes) 371–408pt, with heights of 84–160pt. The
    /// old 520×132 notification card and 640×190 home panel were sized like a
    /// phone scaled up, and read as a slab on a 4K desktop. These two values
    /// are the only places the new proportions are defined; every frame, hit
    /// region and glass layer derives from them.
    ///
    /// 11-07: 300 was measured to wrap the OLD three-line content (245pt of
    /// text + 54pt padding). It is too short for a real notification: the user
    /// measured Apple's own cards on an iPhone screenshot (883×1920 @2x,
    /// 498px preview = 441pt logical). Card edges 16…482px → 466px ≈ 413pt,
    /// a standard two-line card is 75px ≈ 66pt tall, icon 48px ≈ 42pt, inset
    /// ≈ 14pt — a 6.2:1 ribbon, not the 5.4:1 stub we had. 408 is the HIG
    /// macOS upper bound and sits within 5pt of that measurement.
    /// (The 400pt card the user rejected on 11-05 was rejected because its
    /// content was CENTRED, leaving dead glass either side — see docs/04 L8.
    /// Content hangs off the left edge now, so width reads as information,
    /// not emptiness.)
    /// 11-09: 408 现在是默认值，实际宽度来自设置页
    /// （`islandCardWidth` 键，默认 408，范围 340…560）。
    private var islandCardWidth: CGFloat { CGFloat(islandCardWidthSetting) }
    private var islandNotificationSize: CGSize {
        // Apple's standard two-line banner measures ~66pt tall on the 11-07
        // screenshot (42pt leading icon + 12pt above/below), which is what
        // the card now grows to naturally. The old 96 was never the real
        // height anyway: `.frame(maxHeight: .infinity)` inside the card
        // stretched it to 152.8pt, which produced the huge empty bands
        // (logged 20:18:41, docs/04 L8).
        // No minimum height: the plate is content + symmetric padding. Any
        // fixed minimum just reintroduces empty bands, and `frame(minHeight:
        // alignment:)` kept pinning the block to the top (logged 20:22:46:
        // content y=7.5 inside an 84pt card with ~23pt below it).
        CGSize(width: islandCardWidth, height: 0)
    }
    /// 11-09: 480×150 现在是默认值，实际尺寸来自设置页。
    /// 高度下限 120 是有意的 —— 再矮会裁掉面板里的播放控件。
    private var islandPanelSize: CGSize {
        CGSize(width: islandPanelWidthSetting, height: islandPanelHeightSetting)
    }

    /// 11-07: music gets its own size, cloned from the NOTIFICATION card
    /// rather than the hand-opened 480×150 player. The user asked for the
    /// notification card's proportions ("就像通知窗口那个大小，比例也要按
    /// 照那个比例"): 408 wide × ~66 tall ≈ 6.2:1, a 42pt artwork on the left
    /// and two lines of text. Height is content-driven (0), exactly like the
    /// notification card — any fixed minimum reintroduces empty bands (L8).
    /// ONLY on the floating island; the hardware-notch display keeps its
    /// original music live activity (15:56 agreement, docs/04 K4 / J2).
    private var islandMusicSize: CGSize {
        CGSize(width: islandCardWidth, height: 0)
    }

    /// 408 − 14 leading − 42 artwork − 10 gap − 14 trailing. Passed in as a
    /// literal width: the enclosing VStack is intrinsic, so `.infinity` would
    /// collapse back to the ideal width (docs/04 L9.1).
    private var islandMusicTextColumnWidth: CGFloat {
        islandCardWidth - 14 - 42 - 10 - 14
    }

    private var currentNotchShape: NotchShape {
        // On a notch-less display there is no cutout to blend into, so the
        // notification grows out of the floating capsule instead: the top
        // corners stay rounded and the whole card keeps a gap from the screen
        // edge. On a hardware-notch display the original edge-flush outline
        // stays untouched (docs/04 I2, the 15:56 agreement).
        if showsNotificationCard {
            // Apple's Dynamic Island / Vision panel spec calls for a 36–44pt
            // corner on the expanded card. On a notch-less display the card
            // really is a floating island, so it takes the spec value (36pt,
            // the low end, to stay clear of the content padding). The
            // hardware-notch display keeps its edge-flush plate (top 0) with
            // the original 22pt lower corner so it still merges into the
            // physical cutout instead of reading as a detached panel.
            return NotchShape(
                topCornerRadius: usesFloatingIsland ? islandCardRadius : 0,
                bottomCornerRadius: usesFloatingIsland ? islandCardRadius : 22,
                usesContinuousCorners: true
            )
        }

        // A panel opened by hand on the island (click / hover / shortcut) is
        // still the SAME floating object — not the edge-flush black plate used
        // on a hardware-notch display. Without this branch `liquidGlassActive`
        // below would win and turn top radius back to 0, so clicking the
        // capsule would pop a rectangle glued to the top of the screen.
        if usesFloatingIsland, vm.notchState == .open {
            return NotchShape(
                topCornerRadius: islandCardRadius,
                bottomCornerRadius: islandCardRadius,
                usesContinuousCorners: true
            )
        }

        // The closed capsule is the *same* shape object as the opened card.
        // NotchShape's animatableData interpolates both radii, so opening
        // reads as one object growing rather than two plates swapping.
        //
        // The compact island is a TRUE capsule: Apple gives it semicircular
        // ends, not the squircle used by expanded panels. `Capsule` takes its
        // radius from the ACTUAL plate height — a fixed r = 12 leaves a 5pt
        // straight waist once a music/HUD activity grows the plate to 29pt,
        // which reads as a figure-8 where the plate meets the screen edge
        // (user screenshot 19:29). Idle and activity states now share one
        // outline, with no seam between them.
        if usesFloatingIsland, vm.notchState == .closed {
            // The music card is a real CARD, not a grown capsule: it takes the
            // same continuous corners and height-derived radius as the
            // notification card (≈16pt at 66pt tall). A Capsule would give it
            // a 33pt radius and read as a long pill, not the 6.2:1 card the
            // user asked for. The small 185×24 capsule stays a Capsule —
            // its radius follows the ACTUAL plate height (docs/04 L2).
            if showsMusicCard {
                return NotchShape(
                    topCornerRadius: islandCardRadius,
                    bottomCornerRadius: islandCardRadius,
                    usesContinuousCorners: true
                )
            }
            let radius = floatingPillSize.height / 2
            return NotchShape(
                topCornerRadius: radius,
                bottomCornerRadius: radius,
                usesCapsuleCorners: true
            )
        }

        // Glass has to meet the bezel the way the hardware notch does: flush
        // with the screen edge, with the curvature only at the bottom. A 19pt
        // top radius would leave two wallpaper wedges between the glass and the
        // black bezel, which reads as a floating plate.
        if liquidGlassActive {
            return NotchShape(
                topCornerRadius: 0,
                bottomCornerRadius: bottomCornerRadius,
                usesContinuousCorners: true
            )
        }

        // Hardware-notch outline. Its four corners are now Apple's continuous
        // curvature rather than upstream's quadratic parabolas; endpoints and
        // tangents are unchanged, so the width that meets the physical cutout
        // is untouched.
        return NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    /// Closed-notch activities, newest first. A notification sits in front of
    /// music, so an incoming message takes over the display; when it expires
    /// it drops out of this list on its own and music comes back — no
    /// explicit "restore previous activity" bookkeeping needed.
    private var liveActivities: [LiveActivityItem] {
        var items: [LiveActivityItem] = []

        if let notification = notificationManager.activeNotification {
            items.append(.notification(notification))
        }

        // 11-08: 视频 App 被系统当成 now-playing 源时，不要把 .music 放进栈。
        // 否则 closedNotchContent 永远停在 .activities、空闲态回不到 .idle，
        // 常驻胶囊也就永远不消失 —— 两个毛病其实是同一条链。
        // 切歌速览同理：刷短视频同样会触发一次 music peek，必须一起挡掉。
        let musicAllowed = allowsNowPlayingCard
        let musicIsShowing = musicAllowed
            && (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled
        // The inline song-change peek is drawn inside the music pill, so it
        // has to bring the pill with it even when the persistent live
        // activity is turned off — otherwise the peek never appears.
        if musicIsShowing || (musicAllowed && showingInlineMusicPeek) {
            items.append(.music)
        }

        return items
    }

    /// A notification is a glance, not a workspace — it doesn't need the full
    /// height the home/shelf tabs are sized for, and stretching to fill it
    /// just surrounds two lines of text with empty black. 132 is the height
    /// the existing full notification card was tuned for.
    /// nil means "size to content".
    ///
    /// Compact mode must use nil: this frame bounds hit-testing as well as
    /// layout, so any value shorter than the content leaves the transport
    /// row outside the hover region — moving toward the buttons registered
    /// as a hover-exit and closed the notch. The compact panel's height is
    /// controlled by its own internal padding instead, which is the honest
    /// lever anyway.
    private var openNotchHeight: CGFloat? {
        // The old auto-peek grew only 35pt below the camera strip
        // (29 + 35 = 64) and drew a single truncated line. Together with the
        // clear glass it read as "a sliver that never opened". The auto-peek
        // now draws the very same full card the pointer would reveal.
        //
        // On the floating island that card (and the hand-opened panel) follow
        // the iPadOS / macOS Live Activity sizes instead of the old phone-
        // scaled 132 / 190. This is a MINIMUM height — the frame below uses
        // minHeight so a notification with action buttons can still grow
        // instead of being clipped. A hardware-notch display keeps its
        // original numbers untouched.
        if notificationManager.activeNotification != nil {
            return usesFloatingIsland ? islandNotificationSize.height : 132
        }
        if Defaults[.compactMode] { return nil }
        return usesFloatingIsland ? islandPanelSize.height : vm.notchSize.height
    }

    /// Compact mode drops the tab bar along with the tabs it switches
    /// between — there's only the player to show, so a switcher would have
    /// nothing to switch to. Also what keeps the panel narrow, since the
    /// header spans the full notch width.
    private var showsHeader: Bool {
        vm.notchState == .open
            && notificationManager.activeNotification == nil
            && !Defaults[.compactMode]
    }

    /// The activity currently on top of the stack — what the chin has to be
    /// sized for.
    private var selectedActivity: LiveActivityItem? {
        let items = liveActivities
        guard !items.isEmpty else { return nil }
        return items[min(max(activityIndex, 0), items.count - 1)]
    }

    private enum ClosedNotchContent: Equatable {
        case hello
        case nowPlayingFallback
        case batteryStatus
        case peripheralBatteryStatus
        case osd(SneakContentType)
        case activities([LiveActivityItem])
        case face
        case idle
    }

    /// 视频 App 每换一条视频，系统也会发一次 music 类型的 sneak peek。
    /// 若不挡掉，它会把 closedNotchContent 顶到 .osd，空闲态就永远回不去
    /// —— 看视频时浮岛会一直闪。只挡浮岛 + 非音乐源这一条。
    private var allowsMusicSneakPeek: Bool {
        coordinator.sneakPeekState(for: vm.screenUUID).type != .music
            || !usesFloatingIsland
            || allowsNowPlayingCard
    }

    private var closedNotchContent: ClosedNotchContent {
        if coordinator.helloAnimationRunning { return .hello }
        if nowPlayingFallbackNoticeActive { return .nowPlayingFallback }
        if coordinator.expandingView.show,
           coordinator.expandingView.type == .battery,
           Defaults[.showPowerStatusNotifications] {
            return .batteryStatus
        }
        if coordinator.expandingView.show,
           coordinator.expandingView.type == .peripheralBattery,
           Defaults[.peripheralBatteryEnabled] {
            return .peripheralBatteryStatus
        }
        if coordinator.shouldShowSneakPeek(on: vm.screenUUID),
           allowsMusicSneakPeek {
            return .osd(coordinator.sneakPeekState(for: vm.screenUUID).type)
        }
        if !liveActivities.isEmpty, !vm.hideOnClosed {
            return .activities(liveActivities)
        }
        if !coordinator.expandingView.show,
           !musicManager.isPlaying,
           musicManager.isPlayerIdle,
           Defaults[.showNotHumanFace],
           !vm.hideOnClosed {
            return .face
        }
        return .idle
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if shouldDisplayNowPlayingFallbackNotice {
            chinWidth = nowPlayingFallbackNoticeWidth
        } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications] {
            chinWidth = 640
        } else if coordinator.expandingView.type == .peripheralBattery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.peripheralBatteryEnabled] {
            chinWidth = 640
        } else if vm.notchState == .closed, !vm.hideOnClosed, let activity = selectedActivity {
            // Sized for whichever activity is actually on top, not for
            // whichever happens to exist — otherwise swiping to music while a
            // notification is still in the stack leaves the chin at the
            // notification's width.
            switch activity {
            case .notification:
                chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
            case .music:
                chinWidth += (2 * max(0, displayClosedNotchHeight - 12) + 20 + 2 * liveActivityEdgeMargin + 2)
                // The inline song-change peek widens the pill itself, so the
                // chin has to grow with it — otherwise the hover region is
                // narrower than what's on screen.
                if showingInlineMusicPeek {
                    chinWidth += 2 * inlineMusicPeekLabelWidth
                }
            }
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed {
            chinWidth += (2 * max(0, displayClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    private var shouldDisplayNowPlayingFallbackNotice: Bool {
        vm.notchState == .closed && nowPlayingFallbackNoticeActive
    }

    private var nowPlayingFallbackNoticeActive: Bool {
        guard musicManager.nowPlayingNotice != nil else { return false }

        let selectedScreen = NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
        let targetScreenUUID = selectedScreen?.displayUUID ?? NSScreen.main?.displayUUID
        let currentScreen = vm.screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let isConnected = vm.screenUUID == nil || currentScreen != nil
        let isTargetDisplay = vm.screenUUID == nil || vm.screenUUID == targetScreenUUID

        return isConnected
            && isTargetDisplay
            && !isNotchHeightZero
    }

    // If the closed notch height is 0 (any display/setting), display a 10pt nearly-invisible notch
    // instead of fully hiding it. This preserves layout while avoiding visual artifacts.
    private var isNotchHeightZero: Bool { vm.effectiveClosedNotchHeight == 0 }

    private var displayClosedNotchHeight: CGFloat { isNotchHeightZero ? 10 : vm.effectiveClosedNotchHeight }

    /// True when the black plate should be *completely absent*: a display with
    /// no hardware notch, the notch is closed, and there is nothing to show.
    ///
    /// Nothing is being switched off here except the plate itself — the popup
    /// path is untouched. A notification, a HUD, a live activity or an opened
    /// panel all leave `.idle` behind, so the plate comes straight back.
    private var hidesIdlePlateOnNonNotchDisplay: Bool {
        guard hideIdlePlateOnNonNotch,
              !vm.hasNotch,
              vm.notchState == .closed
        else { return false }

        switch closedNotchContent {
        case .idle, .hello:
            return true
        default:
            return false
        }
    }

    /// 11-08 用户拍板「空闲时候可以消失」：空 = 屏幕上什么都没有。
    /// 底板、胶囊描边、命中测试一起关掉，只留菜单栏图标 / ⌘⇧I / 通知自动展开。
    ///
    /// 旧版这里额外要求 `!islandOwnsPlate`，是为了保住当时想要的常驻胶囊
    /// （docs/04 J3「两个开关默认都 true」）。但浮岛路径上 islandOwnsPlate
    /// 恒 true，那个豁免让「静止时不画」开关完全失效。现在反过来：
    /// 空闲就必须连岛一起不画。
    /// 判据仍然是内容，不是屏幕：closedNotchContent 一旦离开 .idle/.hello
    /// （通知 / HUD / 音乐 / 外设电量 / 手点开），底板自动回来，
    /// 通知抓取与自动展开链路一行未动。
    private var suppressesMainPlate: Bool {
        hidesIdlePlateOnNonNotchDisplay
    }

    /// A notch-less display runs the Dynamic-Island path: the idle capsule and
    /// the expanded notification card are one object. Kept as a single gate so
    /// the hardware-notch display (and the 15:56 agreement) is never touched.
    private var usesFloatingIsland: Bool {
        floatingPillOnNonNotch && !vm.hasNotch
    }

    /// The idle/closed capsule uses the same liquid glass as the opened card.
    ///
    /// This is *only* the floating island. On a hardware-notch display the
    /// closed plate must stay pure black: it is the only colour that fuses
    /// with the camera housing, and there is no physical cutout on an external
    /// display, which is exactly why the island can afford to be transparent.
    /// White type on clear glass needs a floor, so the capsule also gets a
    /// uniform wash — same mechanism as the notification card, lower value
    /// because the capsule is small and a heavy wash would read as black
    /// again (user: "黑底改玻璃", 20:36).
    private var closedPillUsesGlass: Bool {
        usesFloatingIsland && Defaults[.enableLiquidGlass] && closedPillGlassEnabled
    }

    private var closedPillScrim: Double {
        closedPillUsesGlass ? 0.25 : 0
    }

    /// True while the island is the only surface being painted — idle capsule,
    /// or a notification that grew out of it. `isNotificationPeeking` keeps the
    /// island alive for the few frames of the closing spring, otherwise the
    /// surface would vanish between "card dismissed" and "idle again".
    private var islandOwnsPlate: Bool {
        // Every panel on a notch-less display belongs to the island, in BOTH
        // states and whether or not a live activity is showing. The old gate
        // only claimed the idle capsule, so a music / HUD / battery peek fell
        // back to the edge-anchored plate: no side inset, no floating offset,
        // fixed 12pt corners on a 29pt plate → the figure-8 outline where it
        // touched the screen edge. Hand-opened panels and notification cards
        // are covered by `vm.notchState == .open` implicitly.
        usesFloatingIsland
    }

    /// The island's single frame. Opening interpolates 185×24 → 400×96
    /// (notification) or 480×150 (hand-opened panel) with the top edge
    /// pinned; closing runs the same interpolation backwards.
    private var floatingIslandSize: CGSize {
        if showsNotificationCard { return islandNotificationSize }
        if showsMusicCard { return islandMusicSize }
        if vm.notchState == .open { return islandPanelSize }
        return floatingPillSize
    }

    /// Keep the island vertically centred inside the menu bar in both states.
    private var floatingIslandTopInset: CGFloat {
        max(0, (menuBarHeightForCurrentScreen - floatingPillSize.height) / 2)
    }

    /// Hit testing is on whenever a surface is actually painted. The old
    /// version returned false for BOTH "nothing is drawn" and "the idle
    /// capsule is drawn", which made the black island unclickable — the user
    /// had to fall back to the menu bar icon or a keyboard shortcut.
    ///
    /// `suppressesMainPlate` is the right signal: it is true only when there
    /// is genuinely no plate (the hide-idle switch with the island disabled).
    /// In the idle state the island owns the plate, so it is false and the
    /// capsule becomes clickable again. The clickable area itself is trimmed
    /// to the capsule outline by `islandHitShape`.
    private var panelIsInteractive: Bool {
        !suppressesMainPlate
    }

    /// Clicks and hovers must land on the pill itself, not on the 640pt
    /// rectangle the window reserves around it. Use the very same shape the
    /// plate is clipped to, so the two never drift apart.
    private var islandHitShape: AnyShape {
        if usesFloatingIsland, vm.notchState == .closed {
            return AnyShape(currentNotchShape)
        }
        return AnyShape(Rectangle())
    }

    /// A detached black capsule for a display with no hardware notch.
    ///
    /// A plate glued to the top edge reads as a black rectangle stuck onto the
    /// menu bar, because there is no cutout for it to blend into — there is no
    /// physical reason for that rectangle to exist. A floating capsule reads as
    /// a deliberate object instead, the same visual language as the iPhone
    /// Dynamic Island, which also floats rather than merging into an edge.
    ///
    /// It is interactive: a click (or a hover, when `openNotchOnHover` is on)
    /// opens the island into the floating glass card. The clickable outline is
    /// the capsule itself, so the surrounding menu bar stays usable.
    /// Menu bar icon, keyboard shortcut and incoming notifications still work.
    private var showsFloatingPill: Bool {
        guard floatingPillOnNonNotch,
              !vm.hasNotch,
              vm.notchState == .closed,
              // 11-08: 空闲时整块岛都不画。这里只剩白描边那一层，
              // 不跟着关掉的话会留一个空心的胶囊轮廓 —— 还是「贴纸」。
              !hidesIdlePlateOnNonNotchDisplay
        else { return false }

        // Only while genuinely idle. A notification, HUD, music capsule or
        // battery peek still uses the normal plate — suppressing it here would
        // leave that content floating on a transparent background. Judge by
        // content, not by the presence of a notch (docs/04 F).
        switch closedNotchContent {
        case .idle, .hello:
            return true
        default:
            return false
        }
    }

    /// Matches the built-in notch so the two displays feel like one product.
    /// Falls back to the measured jump when the panel cannot report a notch.
    private var floatingPillSize: CGSize {
        // The capsule has to fit *inside* the menu bar with clearance above and
        // below, otherwise it reads as a black bar glued to the screen edge —
        // exactly the look this is meant to avoid. Menu bar height differs per
        // display (30 on the external 4K here, 32 on the built-in), so derive
        // rather than hardcode. Clamped so it stays legible on shallow bars.
        let bar = menuBarHeightForCurrentScreen
        let height = min(max(bar - pillEdgeGap * 2, 20), 32)
        // On a notch-less display getClosedNotchSize() already returns the
        // 185pt constant (there are no auxiliary top areas to subtract), so
        // the -4pt seam allowance used on notched displays would make the pill
        // 181pt — narrower than the hardware notch it is meant to match.
        return CGSize(width: vm.closedNotchSize.width, height: height)
    }

    private var pillEdgeGap: CGFloat { 3 }

    private var menuBarHeightForCurrentScreen: CGFloat {
        let screen = vm.screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        return getMenuBarHeight(for: screen)
    }

    /// The island is deliberately NOT a separate view. It is the single
    /// `NotchSurfaceBackground` behind `NotchLayout`, with its outline and
    /// minimum frame driven by `currentNotchShape` / `floatingIslandSize`.
    /// A second glass layer made two differently coloured plates visible at
    /// once (user screenshot 17:23), which read as two objects glued together.

    var body: some View {
        @Bindable var dropInteraction = vm.dropInteraction

        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    // On the island path the surface IS the capsule / card, so
                    // the closed state must not add the stock side padding —
                    // 14pt on each side would stretch the 185pt pill to 213.
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                            ? openedInsets.top
                            : (islandOwnsPlate ? 0 : cornerRadiusInsets.closed.bottom)
                    )
                    // Symmetric on the island. It used to pad the bottom only,
                    // which is correct for an edge-anchored plate (the top
                    // hugs the bezel) but leaves a notification card visually
                    // top-heavy: 12pt below, 0 above.
                    .padding([.horizontal, .vertical], vm.notchState == .open
                             ? (notificationManager.activeNotification != nil
                                ? (isNotificationPeeking ? 8 : 12)
                                : 12)
                             : 0)
                    // One surface only. Give the plate a minimum frame so the
                    // idle state is a real 185×24 capsule and the open state is
                    // a full card, while the background still grows with the
                    // content — a separate glass layer used to leave two
                    // differently coloured plates visible at once.
                    .frame(
                        minWidth: islandOwnsPlate ? floatingIslandSize.width : nil,
                        minHeight: islandOwnsPlate ? floatingIslandSize.height : nil,
                        // The floating card's content is centred inside the
                        // minimum height; an edge-anchored notch plate stays
                        // pinned to the top so it keeps hugging the bezel.
                        alignment: islandOwnsPlate ? .center : .top
                    )
                    .background {
                        // No plate at all while idle on a notch-less display:
                        // a see-through surface would still be a surface for
                        // the glass pipeline to sample and draw.
                        if suppressesMainPlate {
                            Color.clear
                        } else {
                            NotchSurfaceBackground(
                                shape: currentNotchShape,
                                isOpen: vm.notchState == .open,
                                screenUUID: vm.screenUUID,
                                // A notification is white type on clear glass,
                                // so it needs Apple's clear-glass fallback —
                                // one UNIFORM darkening wash over the whole
                                // panel. A local/top-only veil looks like a
                                // second material (docs/04 C3). Every other
                                // state keeps the user's transparency setting.
                                // Must follow screenUUID: the memberwise
                                // initialiser keeps declaration order.
                                // The music card carries the same two white
                                // text lines as a notification, so it takes
                                // the same uniform wash. The 24pt capsule
                                // stays at 0.25 or it reads as black again.
                                minimumScrim: (showsNotificationCard || showsMusicCard)
                                    ? 0.35
                                    : closedPillScrim,
                                // The closed island is glass too — one material
                                // for the whole lifecycle, so the capsule no
                                // longer turns from black to glass as it grows.
                                // Hardware-notch plates never take this path.
                                glassWhileClosed: closedPillUsesGlass
                            )
                            // Hairline for the black capsule only: on glass the
                            // material draws its own edge, and a drawn stroke
                            // would read as a border (same rule as the card).
                            .overlay {
                                if showsFloatingPill, !closedPillUsesGlass {
                                    currentNotchShape
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                }
                            }
                        }
                    }
                    .clipShape(currentNotchShape)
                          .overlay(alignment: .top) {
                              // The seam-hider is a black hairline for the black
                              // plate. On glass it would read as a drawn border,
                              // so it only exists when the plate is black.
                              (displayClosedNotchHeight.isZero && vm.notchState == .closed)
                                || suppressesMainPlate
                                || islandOwnsPlate
                                || liquidGlassActive ? nil
                        : Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        // No shadow on glass — it cannot be cast by this panel.
                        //
                        // `.shadow` rasterises the view into an offscreen pass
                        // and blurs its *alpha*. A `CABackdropLayer` samples the
                        // window server, which does not exist in that offscreen
                        // pass, so the whole glass plate renders as opaque black
                        // there. The result is not a shadow but a blurred black
                        // silhouette of the panel: a hard black edge right
                        // outside the outline, fading over ~6pt. Measured on a
                        // white wallpaper: 232 → 150 in a single pixel, which is
                        // 0.7 × ~50% — the shadow colour at full source alpha.
                        //
                        // On the black plate the same silhouette *is* the plate,
                        // so the shadow stays correct there.
                        color: ((vm.notchState == .open || isHovering)
                                && Defaults[.enableShadow]
                                && !liquidGlassActive
                                && !suppressesMainPlate
                                && !islandOwnsPlate)
                            ? .black.opacity(0.7) : .clear, radius: 6
                    )
                    // Removed conditional bottom padding when using custom 0 notch to keep layout stable
                    //
                    // 0 (not 0.01) on a notch-less display: that 1% residue is
                    // still a faint grey pill against a light menu bar, which
                    // is exactly what was being complained about.
                    // Only "draw nothing at all" hides the content. The island
                    // keeps its content visible even though it is one surface
                    // with the plate, so the notification card can render.
                    .opacity(suppressesMainPlate
                             ? 0
                             : ((isNotchHeightZero && vm.notchState == .closed) ? 0.01 : 1))

                mainLayout
                    // alignment: .top matters here — without it this frame
                    // defaults to centering, and shrinking the height for a
                    // notification (openNotchHeight < vm.notchSize.height)
                    // then pulls the visible top edge down by half the
                    // difference instead of staying flush with the window's
                    // top-anchored origin. That's what read as "the notch
                    // sits a bit off the top of the screen."
                    //
                    // The width stays pinned for the whole lifetime of a
                    // notification so handing control to the pointer doesn't
                    // resize the card under it. 520 leaves the full card
                    // comfortably inside the 640pt canvas without a wide
                    // empty band around the text.
                    .frame(
                        width: showsNotificationCard
                            ? notificationPeekBarWidth
                            : (islandOwnsPlate && vm.notchState == .open ? islandPanelSize.width : nil),
                        alignment: .top
                    )
                    // minHeight, not a fixed height: the smaller island card
                    // has to be able to grow a few points for a notification
                    // carrying action buttons instead of clipping them. The
                    // plate's own .frame(minHeight:) below follows the same
                    // number, so the glass never runs past the outline.
                    .frame(
                        minHeight: vm.notchState == .open ? openNotchHeight : nil,
                        alignment: .top
                    )
                    .conditionalModifier(true) { view in
                        return view
                            .animation(vm.notchState == .open ? StandardAnimations.open : StandardAnimations.close, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                            // Outermost on purpose: it only fires when the
                            // closed-state content changes (the key is stable
                            // across open/close), and when several keys change
                            // at once the innermost animation wins, so the
                            // open/close springs below keep precedence.
                            .animation(.smooth(duration: 0.3), value: closedNotchContent)
                    }
                    .contentShape(islandHitShape)
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        if vm.notchState == .closed && !shouldDisplayNowPlayingFallbackNotice {
                            doOpen()
                        }
                    }
                    .conditionalModifier(Defaults[.enableGestures] && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures] && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.enableHorizontalMediaGestures] && Defaults[.enableGestures] && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .left) { translation, phase in
                                handleNextTrackGesture(translation: translation, phase: phase)
                            }
                            .panGesture(direction: .right) { translation, phase in
                                handlePreviousTrackGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        scheduleCloseIfNotHovering(overNotch: vm)
                    }
                    // A new notification always takes the front of the stack,
                    // even if the user had swiped away to music.
                    .onChange(of: notificationManager.activeNotification?.id) { _, newID in
                        if newID != nil { activityIndex = 0 }
                        handleNotificationPeek(for: newID)
                    }
                    // Activities disappear on their own (a notification
                    // expires, music stops). Keep the selection in range so
                    // the stack falls back to whatever is left instead of
                    // pointing past the end.
                    .onChange(of: liveActivities.count) { _, count in
                        if activityIndex >= count { activityIndex = max(count - 1, 0) }
                    }
                    .onChange(of: vm.isPopoverActive) { _, _ in
                        scheduleCloseIfNotHovering(overNotch: vm)
                    }
                    // 11-08 运行期取证：空闲抑制 / 视频源抑制是否真的翻转，
                    // 不需要截屏或辅助功能权限（touch /tmp/bn-notch.debug）。
                    .onChange(of: suppressesMainPlate) { _, suppressed in
                        bnDebugLog("idle suppress=\(suppressed) content=\(closedNotchContent) floating=\(usesFloatingIsland)")
                    }
                    .onChange(of: allowsNowPlayingCard) { _, allowed in
                        bnDebugLog("musiccard allowed=\(allowed) src=\(musicManager.bundleIdentifier ?? "nil") artist=\(musicManager.artistName)")
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                // The chin is a 1% black filler under the plate, meant to cover
                // the titlebar gap. With no plate at all it is just a faint
                // grey band, so it goes with it.
                if vm.chinHeight > 0, !suppressesMainPlate, !islandOwnsPlate {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }

            }
            // `.offset` only moves the *rendered* result: the layout frame
            // stays at y=0, so on a 29pt menu bar the 23pt capsule sat flush
            // against the screen edge (measured: frame=(227.5, 0, 185, 23),
            // menuBar=29, inset=3). Padding changes the real geometry, which
            // is what gives the island clearance above and below.
            .padding(.top, islandOwnsPlate ? floatingIslandTopInset : 0)
            // Runtime geometry probe. Enable with `touch /tmp/bn-notch.debug`
            // and read /tmp/bn-notch.log — the only way to see the plate's
            // real origin without screen-recording permission (docs/04 D).
            .overlay {
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        bnDebugLog(
                            "island frame=\(proxy.frame(in: .global))"
                            + " pillH=\(floatingPillSize.height)"
                            + " inset=\(floatingIslandTopInset)"
                            + " floating=\(usesFloatingIsland)"
                            + " owns=\(islandOwnsPlate)"
                            + " menuBar=\(menuBarHeightForCurrentScreen)"
                        )
                    }
                }
                .allowsHitTesting(false)
            }

            // 内建刘海屏的细玻璃歌词带：贴在纯黑收起板下沿，避开摄像头挖孔。
            // 挂在 ZStack 上而不是 VStack / clipShape 之后，才不会被刘海板的
            // 形状裁掉，也不会把纯黑板本身撑高或改成玻璃。窗口本身是固定
            // 640×210 的画板（sizing/matters.swift），多这 26pt 不会被裁。
            if showsNotchedLyricsStrip {
                notchLyricsStrip
                    .padding(.top, displayClosedNotchHeight + 3)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .ignoresSafeArea(.all)
        .compositingGroup()
        // Only the truly empty state (no plate at all) is click-through: an
        // invisible target that pops a panel open over the menu bar is a trap.
        // The idle capsule IS a plate, so it accepts clicks and hovers like the
        // original notch did; `islandHitShape` keeps that target pill-shaped.
        .allowsHitTesting(panelIsInteractive)
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: dropInteraction.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if Defaults[.boringShelf] && vm.notchState == .closed {
                    if doOpen() {
                        coordinator.currentView = .shelf
                    }
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if dropInteraction.dropEvent {
                    dropInteraction.dropEvent = false
                    return
                }

                dropInteraction.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        @Bindable var dropInteraction = vm.dropInteraction

        // A notification must hug the notch: the stock ~10pt stack spacing
        // would push the card toward the bottom edge.
        VStack(alignment: .leading, spacing: showsNotificationCard ? 0 : nil) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if shouldDisplayNowPlayingFallbackNotice,
                       let notice = musicManager.nowPlayingNotice {
                        nowPlayingFallbackNotice(notice)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications] {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    maxAdapterWatts: batteryModel.maxAdapterWatts,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: displayClosedNotchHeight, alignment: .center)
                        } else if coordinator.expandingView.type == .peripheralBattery && coordinator.expandingView.show
                            && vm.notchState == .closed && Defaults[.peripheralBatteryEnabled] {
                            HStack(spacing: 0) {
                                HStack {
                                    Text(peripheralBatteryModel.peekSummary ?? "")
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }

                                Rectangle()
                                    .fill(.black)
                                    .frame(width: vm.closedNotchSize.width + 10)

                                HStack {
                                    Image(systemName: peripheralBatteryModel.peekIcon)
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 76, alignment: .trailing)
                            }
                            .frame(height: displayClosedNotchHeight, alignment: .center)
                        } else if coordinator.shouldShowSneakPeek(on: vm.screenUUID) && Defaults[.inlineOSD] && (coordinator.sneakPeekState(for: vm.screenUUID).type != .music) && (coordinator.sneakPeekState(for: vm.screenUUID).type != .battery) && vm.notchState == .closed {
                           InlineOSD(
                              type: coordinator.binding(for: vm.screenUUID).type,
                              value: coordinator.binding(for: vm.screenUUID).value,
                              icon: coordinator.binding(for: vm.screenUUID).icon,
                              accent: coordinator.binding(for: vm.screenUUID).accent,
                              hoverAnimation: $isHovering,
                              gestureProgress: $gestureProgress
                          )
                              .transition(.opacity)
                      } else if showsMusicCard {
                          // 408×66 now-playing card, NOT the hand-opened
                          // player. Left aligned like Apple's banner, one
                          // current lyric line only (11-07 user decision).
                          islandMusicContent
                              .transition(.opacity)
                      } else if usesFloatingIsland && vm.notchState == .closed && !liveActivities.isEmpty && !vm.hideOnClosed {
                          // The island gets its own row: upstream's pill is
                          // sized around a camera cutout and its labels spill
                          // outside a floating capsule (docs/04 L7).
                          islandClosedContent
                              .transition(.opacity)
                      } else if !liveActivities.isEmpty && vm.notchState == .closed && !vm.hideOnClosed {
                          LiveActivityStack(items: liveActivities, index: $activityIndex) { item in
                              switch item {
                              case .notification(let notification):
                                  NotificationLiveActivity(notification: notification)
                              case .music:
                                  MusicLiveActivity()
                                      .frame(alignment: .center)
                              }
                          }
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed {
                          BoringFaceAnimation()
                       } else if showsHeader {
                           // No tab bar over a notification: it's a glance,
                           // not a place to switch between home and shelf —
                           // and the header spans the full notch width,
                           // which is what was stretching the whole panel
                           // out around a short message.
                           BoringHeader()
                               .frame(height: max(38, displayClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       }
                        // A mirrored notification reserves the whole camera
                        // band; the card itself is drawn by the open-state
                        // stack below. This must come BEFORE the !vm.hasNotch
                        // case: on the external 4K display that branch used to
                        // win and reserve only 11pt, so the auto-peek showed
                        // an almost empty panel — the "tiny stuck glass" the
                        // user reported (docs/04 section I).
                       else if showsNotificationCard {
                           // A hardware notch needs the camera band reserved.
                           // A floating island has no camera: keeping 29pt of
                           // invisible band here is what made the card too
                           // tall to shrink to the iPad/Mac proportions.
                           Rectangle().fill(.clear).frame(
                               width: vm.closedNotchSize.width - 20,
                               height: usesFloatingIsland ? 0 : displayClosedNotchHeight
                           )
                       }
                        // New case to enable compact notch on external displays
                        else if !vm.hasNotch {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: 11) // idle notch height is halved on non notch display
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: displayClosedNotchHeight)
                       }

                        if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
                           if (coordinator.sneakPeekState(for: vm.screenUUID).type != .music) && (coordinator.sneakPeekState(for: vm.screenUUID).type != .battery) && !Defaults[.inlineOSD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: coordinator.binding(for: vm.screenUUID).type,
                                  value: coordinator.binding(for: vm.screenUUID).value,
                                  icon: coordinator.binding(for: vm.screenUUID).icon,
                                  accent: coordinator.binding(for: vm.screenUUID).accent,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeekState(for: vm.screenUUID).type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                           // Old sneak peek music. On the island this row was
                           // drawn OUTSIDE the capsule (grey, left-aligned —
                           // the "obviously not centred" line in the 20:16
                           // screenshot); `islandClosedContent` already shows
                           // the same song inside the pill.
                           else if coordinator.sneakPeekState(for: vm.screenUUID).type == .music
                                       && !usesFloatingIsland {
                               if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                   HStack(alignment: .center) {
                                       Image(systemName: "music.note")
                                       GeometryReader { geo in
                                           MarqueeText(musicManager.songTitle + " - " + musicManager.artistName, color: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, delayDuration: 1.0, frameWidth: geo.size.width)
                                       }
                                   }
                                   .foregroundStyle(.gray)
                                   .padding(.bottom, 10)
                               }
                           }
                       }
                        }
                      }
                      .conditionalModifier((coordinator.shouldShowSneakPeek(on: vm.screenUUID) && (coordinator.sneakPeekState(for: vm.screenUUID).type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.shouldShowSneakPeek(on: vm.screenUUID) && (coordinator.sneakPeekState(for: vm.screenUUID).type != .music) && (vm.notchState == .closed))) { view in
                          view
                              .fixedSize()
                      }
                      .zIndex(1)
            if vm.notchState == .open {
                VStack {
                    // An open notch with a live notification is showing the
                    // reply UI — the usual tabs can wait until it's dismissed.
                    // The automatic peek now draws the SAME full card the
                    // pointer would reveal: icon, app, sender, body and the
                    // action buttons, not a two-line bar. Nothing here freezes
                    // the countdown — only a real hover does that (see
                    // handleHover), so an automatic peek always ages out.
                    if let notification = notificationManager.activeNotification {
                        NotificationExpandedView(
                            notification: notification,
                            compactLayout: usesFloatingIsland,
                            // Hand the card its real width. A `.frame(width:)`
                            // wrapped around the view here does NOT reach it:
                            // the enclosing VStack is intrinsic and keeps
                            // proposing the ideal width, so the card laid
                            // itself out at 240pt inside a 300pt plate and
                            // every leading inset was swallowed by centring.
                            cardWidth: usesFloatingIsland ? islandCardWidth : nil
                        )
                            .id(notification.id)
                    } else if Defaults[.compactMode] {
                        // Player only — no tab switching, so currentView is
                        // ignored here rather than offering a shelf the
                        // compact layout has no room (or tab bar) for.
                        // 336 = Atoll's 420 base less 20%, which also lands
                        // within a few points of their Dynamic Island width
                        // (340) — the tighter of their two compact sizes.
                        CompactHomeView(
                            albumArtNamespace: albumArtNamespace,
                            horizontalMediaGestureFeedback: horizontalMediaGestureFeedback
                        )
                        .frame(width: 336)
                        .onHover { hovering in
                            isHoveringMusicArea = hovering
                        }
                        .onDisappear {
                            isHoveringMusicArea = false
                        }
                    } else {
                        switch coordinator.currentView {
                        case .home:
                            NotchHomeView(
                                albumArtNamespace: albumArtNamespace,
                                horizontalMediaGestureFeedback: horizontalMediaGestureFeedback,
                                isHoveringMusicArea: $isHoveringMusicArea
                            )
                        case .shelf:
                            ShelfView(
                                dropInteraction: vm.dropInteraction,
                                animation: vm.animation
                            )
                        }
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $dropInteraction.generalDropTargeting))
    }

    private func nowPlayingFallbackNotice(_ notice: NowPlayingFallbackNotice) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(notice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(2)

            Spacer(minLength: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: nowPlayingFallbackNoticeWidth)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
        .onAppear {
            if musicManager.markNowPlayingNoticePresented(notice.id) {
                announceNowPlayingFallbackNotice(notice)
            }
        }
    }

    private func announceNowPlayingFallbackNotice(_ notice: NowPlayingFallbackNotice) {
        let announcement = "\(String(localized: notice.title)). \(String(localized: notice.subtitle))."
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 20)
            let faceScale = min(1.0, displayClosedNotchHeight / 30.0)
            AnimatedFace(height: 24.0 * faceScale, width: 30.0 * faceScale)
        }.frame(
            height: displayClosedNotchHeight,
            alignment: .center
        )
    }

    /// True while the song-change peek is expanding the closed pill inline.
    private var showingInlineMusicPeek: Bool {
        coordinator.expandingView.show
            && coordinator.expandingView.type == .music
            && Defaults[.sneakPeekStyles] == .inline
    }

    /// Width of the black centre section of the closed music pill.
    ///
    /// Derived from the real notch width rather than the previous hard-coded
    /// 380. That constant assumed a particular notch size: the title sits
    /// left of the cutout and the artist right of it, separated by a spacer
    /// as wide as the notch itself, so on a wider notch there was no room
    /// left for the artist and the labels collided. Sizing from
    /// closedNotchSize keeps a fixed label budget either side whatever the
    /// hardware is, and keeps liveActivityEdgeMargin in play so content
    /// clears the bezel — the inline path had dropped it entirely.
    /// The closed island on a notch-less display.
    ///
    /// Upstream's pill is built around a physical camera cutout: a 185pt
    /// spacer in the middle with the song title on one side and the artist on
    /// the other, plus margins measured from the bezel. On a ~197pt floating
    /// capsule that pair needs ~405pt, so the labels were simply drawn OUTSIDE
    /// the plate — the text that appeared to hang below the pill in the user's
    /// 19:59 screenshot. This row is self-contained: artwork, one truncated
    /// line, visualizer, all inside the 24pt capsule.
    /// Closed-island music card (11-07): 408×66, left aligned like Apple's
    /// notification banner, with ONE current lyric line. A TimelineView keeps
    /// the line moving at each LRC stamp instead of waiting for the player to
    /// push a new elapsedTime — the same interpolation NotchHomeView uses.
    @ViewBuilder
    private var islandMusicContent: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(islandNowPlayingLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                    Text(islandLyricLine(at: islandElapsed(at: timeline.date)))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Reserve the line's height whether or not lyrics exist, so
                // the card never changes height when a song has no LRC.
                .frame(height: 16, alignment: .leading)
            }
            .frame(width: islandMusicTextColumnWidth, alignment: .leading)
            // White type on clear glass: a tight glyph-edge shadow plus a
            // wide local-contrast shadow, same recipe as the notification.
            .shadow(color: .black.opacity(0.55), radius: 1)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: islandCardWidth, alignment: .leading)
    }

    /// 内建刘海屏的细玻璃歌词带（11-08）。320×26，圆角按实际高度走 Capsule，
    /// 文字水平、垂直都居中，左右 padding 对称——不加按钮、不留一侧空白。
    private var notchLyricsStrip: some View {
        let stripHeight: CGFloat = 26
        let stripWidth: CGFloat = 320
        let stripShape = NotchShape(
            topCornerRadius: stripHeight / 2,
            bottomCornerRadius: stripHeight / 2,
            usesCapsuleCorners: true
        )
        return ZStack {
            // 复用整块板的玻璃管线：折射 + 高光 + 一层*均匀*压暗。
            // 白字在亮壁纸上读不清时，正解是压暗玻璃，不是把玻璃换成
            // 纯黑底（docs/04 I6，用户 11-05 的强制要求）。
            NotchSurfaceBackground(
                shape: stripShape,
                isOpen: false,
                screenUUID: vm.screenUUID,
                minimumScrim: 0.25,
                glassWhileClosed: true
            )
            TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                Text(notchStripText(at: islandElapsed(at: timeline.date)))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: stripWidth - 32, height: stripHeight, alignment: .center)
                    .padding(.horizontal, 16)
            }
            .shadow(color: .black.opacity(0.55), radius: 1)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        }
        .frame(width: stripWidth, height: stripHeight)
        .clipShape(Capsule())
        // 纯展示：不抢刘海本身的点击 / 悬停展开手势。
        .allowsHitTesting(false)
        // 运行期取证：内建屏分支在这台只接外接屏的机器上没法当场验证，
        // 切回自带屏时看 /tmp/bn-notch.log 是否有这一行即可。
        .onAppear {
            bnDebugLog(
                "notchlyrics appear hasNotch=\(vm.hasNotch)"
                + " floating=\(usesFloatingIsland)"
                + " glass=\(Defaults[.enableLiquidGlass])"
                + " synced=\(lyricsService.syncedLyrics.count)"
            )
        }
    }

    /// 歌词还在抓取、或这一句刚好是空行时，退回「歌名 · 艺术家」，
    /// 免得玻璃带里空一块或高度抖动。
    private func notchStripText(at elapsed: Double) -> String {
        let line = islandLyricLine(at: elapsed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { return line }
        let artist = musicManager.artistName
        return artist.isEmpty
            ? musicManager.songTitle
            : "\(musicManager.songTitle) · \(artist)"
    }

    private func islandElapsed(at date: Date) -> Double {
        guard musicManager.isPlaying else { return musicManager.elapsedTime }
        let delta = date.timeIntervalSince(musicManager.timestampDate)
        let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
        // songDuration is 0 for some streamed tracks; clamping to 0 would
        // freeze every lyric on the first line.
        let cap = musicManager.songDuration > 0 ? musicManager.songDuration : Double.infinity
        return min(max(progressed, 0), cap)
    }

    private func islandLyricLine(at elapsed: Double) -> String {
        if lyricsService.isFetchingLyrics { return "" }
        if !lyricsService.syncedLyrics.isEmpty {
            return lyricsService.lyricLine(at: elapsed)
        }
        // No time line anywhere (instrumental, or a plain-text-only source):
        // show the first line instead of the whole song squeezed into one.
        return lyricsService.currentLyrics
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }

    @ViewBuilder
    private var islandClosedContent: some View {
        if let item = liveActivities.first {
            HStack(spacing: 7) {
                switch item {
                case .music:
                    Image(nsImage: musicManager.albumArt)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(islandNowPlayingLabel)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The capsule is glass now, so white type needs its own
                        // edge on a bright menu bar. A shadow is not a veil: it
                        // keeps the material transparent (docs/04 I6).
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 0.5)
                        .frame(maxWidth: 190, alignment: .leading)
                    Spacer(minLength: 2)
                    MusicVisualizer(
                        isPlaying: musicManager.isPlaying,
                        tintColor: Color.white.opacity(0.7)
                    )
                    // The model draws 14pt bars; a 10pt layout box made the
                    // row centre the box while the bars spilled 4pt above it,
                    // which read as 2pt high (user's 20:36 crop: 3.5pt above,
                    // 7.5pt below). Box and drawing are the same now.
                    .frame(width: 14, height: 14)
                case .notification(let notification):
                    NotificationSourceIcon(
                        bundleID: notification.bundleID,
                        appName: notification.appName,
                        size: 18
                    )
                    Text(islandNotificationLabel(notification))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 0.5)
                        .frame(maxWidth: 210, alignment: .leading)
                    Spacer(minLength: 2)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: floatingPillSize.height)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: floatingPillSize.width)
        }
    }

    private var islandNowPlayingLabel: String {
        let title = musicManager.songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = musicManager.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return artist.isEmpty ? "正在播放" : artist }
        return artist.isEmpty ? title : "\(title) · \(artist)"
    }

    private func islandNotificationLabel(_ notification: SystemNotification) -> String {
        for candidate in [notification.title, notification.body, notification.appName] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return "通知"
    }

    private var musicActivityCenterWidth: CGFloat {
        let margin = vm.closedNotchSize.width - 4 + (2 * liveActivityEdgeMargin)
        guard showingInlineMusicPeek else { return margin }
        return margin + (2 * inlineMusicPeekLabelWidth)
    }

    /// Space reserved for the title (left of the cutout) and artist (right).
    private let inlineMusicPeekLabelWidth: CGFloat = 110

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack(spacing: 0) {
            // Closed-mode album art: scale padding and corner radius according to cornerRadiusScaleFactor
            let baseArtSize = displayClosedNotchHeight - 12
            let scaledArtSize: CGFloat = {
                if let scale = cornerRadiusScaleFactor {
                    return displayClosedNotchHeight - 12 * scale
                }
                return baseArtSize
            }()
            // The art's top/bottom gap to the pill; the leading offset below
            // trims the row's edge slack down to this same inset.
            let artVerticalInset = (displayClosedNotchHeight - scaledArtSize) / 2

            let closedCornerRadius: CGFloat = {
                let base = MusicPlayerImageSizes.cornerRadiusInset.closed
                if let scale = cornerRadiusScaleFactor {
                    return max(0, base * scale)
                }
                return base
            }()

            Image(nsImage: musicManager.albumArt)
                .resizable().scaledToFit()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: closedCornerRadius)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: scaledArtSize,
                    height: scaledArtSize
                )
                // On the floating island the pill's own edge IS the plate
                // edge, so upstream's `inset − 8pt` formula goes negative and
                // pushes the artwork out through the capsule's left corner
                // (user screenshot 19:48). There it simply sits `inset` in.
                .offset(x: usesFloatingIsland
                        ? artVerticalInset
                        : artVerticalInset - liveActivityEdgeMargin)

            Rectangle()
                .fill(.black)
                .overlay(
                    // .center, not .top: the album art beside this is
                    // vertically centered, so top-aligned labels sat visibly
                    // high against it.
                    HStack(alignment: .center) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music {
                            MarqueeText(
                                musicManager.songTitle,
                                color: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.white,
                                delayDuration: 0.4,
                                frameWidth: inlineMusicPeekLabelWidth
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: inlineMusicPeekLabelWidth, alignment: .trailing)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.white
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                    .padding(.horizontal, 8)
                )
                .frame(width: musicActivityCenterWidth)

            HStack {
                MusicVisualizer(
                    isPlaying: musicManager.isPlaying,
                    tintColor: Defaults[.coloredSpectrogram]
                    ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.5)
                    : Color.gray
                )
                .frame(width: 18, height: 12)
            }
            .frame(
                width: max(
                    0,
                    displayClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    displayClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: displayClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        @Bindable var dropInteraction = vm.dropInteraction

        if Defaults[.boringShelf] && vm.notchState == .closed && !shouldDisplayNowPlayingFallbackNotice {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $dropInteraction.dragDetectorTargeting) { providers in
            dropInteraction.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

}
// MARK: - Gesture & Hover Handling

extension ContentView {
    @discardableResult
    private func doOpen() -> Bool {
        var didOpen = false
        withAnimation(animationSpring) {
            didOpen = vm.open()
        }
        return didOpen
    }

    // MARK: - Hover Management

    /// Closes the open notch after the hover grace period unless a popover
    /// still owns the pointer.
    private func scheduleCloseIfNotHovering(overNotch notchViewModel: BoringViewModel) {
        guard notchViewModel.notchState == .open,
              !isHovering,
              !notchViewModel.isPopoverActive else { return }
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(hoverExitDelayMilliseconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self.vm.notchState == .open,
                   !self.isHovering,
                   !self.vm.isPopoverActive,
                   !SharingStateManager.shared.preventNotchClose {
                    self.vm.close()
                }
            }
        }
    }

    // MARK: - Notification Peek

    /// How long a mirrored message stays on screen before the notch closes
    /// again. Must match `SystemNotificationManager.displayDuration` or the
    /// manager expires the card before this countdown gets to close the panel.
    /// 12s gives the user time to actually read the full card; pointing at it
    /// still freezes the countdown (`handleHover` → `holdActive`).
    private var notificationPeekSeconds: TimeInterval { 12 }

    /// Outer width of the notification card. The floating island takes the
    /// iPad/Mac card width; a hardware-notch display keeps the stock 520pt
    /// bar so that path is untouched.
    private var notificationPeekBarWidth: CGFloat {
        usesFloatingIsland ? islandCardWidth : NotificationPeekBar.Metrics.barWidth
    }

    /// iOS-style behaviour for mirrored notifications: the banner opens the
    /// notch on its own and shows the stock small window (icon + accent dot),
    /// then closes again. Hovering, opening the notch by hand or a popover
    /// hands control back to the normal hover logic.
    private func handleNotificationPeek(for id: String?) {
        bnDebugLog(
            "peek id=\(id?.prefix(6) ?? "nil") state=\(vm.notchState)"
            + " hideOnClosed=\(vm.hideOnClosed) autoExpand=\(Defaults[.notificationAutoExpand])"
            + " firstLaunch=\(coordinator.firstLaunch) hovering=\(isHovering)"
            + " popover=\(vm.isPopoverActive) sharing=\(SharingStateManager.shared.preventNotchClose)"
            + " hasNotch=\(vm.hasNotch) hidesIdle=\(hidesIdlePlateOnNonNotchDisplay) pill=\(showsFloatingPill)"
            + " suppress=\(suppressesMainPlate) musicAllowed=\(allowsNowPlayingCard)"
            + " src=\(musicManager.bundleIdentifier ?? "nil") artist=\(musicManager.artistName)"
            + " glass=\(liquidGlassActive) peekBefore=\(isNotificationPeeking)"
            + " active=\(notificationManager.activeNotification?.id.prefix(6) ?? "nil")"
        )
        notificationPeekTask?.cancel()
        notificationPeekTask = nil

        guard let id else {
            endNotificationPeek(closeNotch: true)
            return
        }

        guard Defaults[.notificationAutoExpand],
              !coordinator.firstLaunch,
              !isHovering,
              !vm.hideOnClosed,
              !vm.isPopoverActive,
              !SharingStateManager.shared.preventNotchClose else {
            isNotificationPeeking = false
            return
        }

        // The user opened this themselves — don't take the panel over.
        if vm.notchState == .open, !isNotificationPeeking { return }

        isNotificationPeeking = true
        if vm.notchState == .closed {
            withAnimation(animationSpring) {
                _ = vm.open()
            }
        }

        let peekSeconds = notificationPeekSeconds
        notificationPeekTask = Task {
            try? await Task.sleep(for: .seconds(peekSeconds))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                // A pointer that arrived a moment ago already cancelled this
                // task; guard anyway so the two racing paths can't close a
                // card the user is reading.
                guard notificationManager.activeNotification?.id == id,
                      !isHovering else { return }
                notificationManager.dismissActive(token: id)
                endNotificationPeek(closeNotch: true)
            }
        }
    }

    private func endNotificationPeek(closeNotch: Bool) {
        notificationPeekTask?.cancel()
        notificationPeekTask = nil
        guard isNotificationPeeking else { return }
        isNotificationPeeking = false
        guard closeNotch,
              vm.notchState == .open,
              !isHovering,
              !vm.isPopoverActive,
              !SharingStateManager.shared.preventNotchClose else { return }
        withAnimation(animationSpring) {
            vm.close()
        }
    }

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            // A peek the pointer interrupts becomes a plain hover: the user is
            // in control now, so stop counting down to auto-close.
            if isNotificationPeeking {
                notificationPeekTask?.cancel()
                notificationPeekTask = nil
                isNotificationPeeking = false
            }

            // Freeze the dismiss countdown the moment the pointer arrives,
            // not when the notch finishes opening. Opening waits out
            // minimumHoverDuration plus an animation, and a notification
            // near the end of its life would expire during that — so it
            // vanished exactly as the notch opened around it.
            if notificationManager.activeNotification != nil {
                notificationManager.holdActive()
            }

            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }

            guard vm.notchState == .closed,
                  !shouldDisplayNowPlayingFallbackNotice,
                  !coordinator.shouldShowSneakPeek(on: vm.screenUUID),
                  Defaults[.openNotchOnHover] else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.shouldDisplayNowPlayingFallbackNotice,
                          !self.coordinator.shouldShowSneakPeek(on: self.vm.screenUUID) else { return }

                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(hoverExitDelayMilliseconds))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }

                    // Pointer left — let the notification age out again.
                    self.notificationManager.resumeDismiss()

                    if self.vm.notchState == .open,
                       !self.vm.isPopoverActive,
                       !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose {
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func handleNextTrackGesture(translation: CGFloat, phase: NSEvent.Phase) {
        handleHorizontalMediaGesture(translation: translation, phase: phase, feedback: -1) {
            musicManager.nextTrack()
        }
    }

    private func handlePreviousTrackGesture(translation: CGFloat, phase: NSEvent.Phase) {
        handleHorizontalMediaGesture(translation: translation, phase: phase, feedback: 1) {
            musicManager.previousTrack()
        }
    }

    private func handleHorizontalMediaGesture(
        translation: CGFloat,
        phase: NSEvent.Phase,
        feedback: CGFloat,
        action: () -> Void
    ) {
        guard isHorizontalMediaGestureContext else {
            resetHorizontalMediaGesture()
            return
        }
        guard phase != .ended else {
            resetHorizontalMediaGesture()
            return
        }
        guard !horizontalMediaGestureTriggered else { return }
        guard translation > Defaults[.gestureSensitivity] else { return }

        horizontalMediaGestureTriggered = true
        triggerHorizontalMediaFeedback(feedback)
        action()

        if Defaults[.enableHaptics] {
            haptics.toggle()
        }
    }

    private func resetHorizontalMediaGesture() {
        horizontalMediaGestureTriggered = false
    }

    private func triggerHorizontalMediaFeedback(_ feedback: CGFloat) {
        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.62)) {
            horizontalMediaGestureFeedback = feedback
            if vm.notchState == .closed {
                gestureProgress = 2
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(animationSpring) {
                horizontalMediaGestureFeedback = .zero
                if vm.notchState == .closed {
                    gestureProgress = .zero
                }
            }
        }
    }

    private var isHorizontalMediaGestureContext: Bool {
        switch vm.notchState {
        case .closed:
            guard !vm.hideOnClosed else { return false }

            if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
                return coordinator.sneakPeekState(for: vm.screenUUID).type == .music
            }

            guard !coordinator.expandingView.show || coordinator.expandingView.type == .music else {
                return false
            }

            return coordinator.musicLiveActivityEnabled && (musicManager.isPlaying || !musicManager.isPlayerIdle)

        case .open:
            if Defaults[.compactMode] {
                return !musicManager.isPlayerIdle && isHoveringMusicArea
            }
            return coordinator.currentView == .home && !musicManager.isPlayerIdle && isHoveringMusicArea
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }
}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel(camera: CameraModel())
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
