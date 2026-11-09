//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

// MARK: - File System Paths
let documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSTemporaryDirectory())
let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.notchisland.app"
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSTemporaryDirectory())
let spacing: CGFloat = 16

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

struct AppLanguage: RawRepresentable, Hashable, Identifiable, Defaults.Serializable {
    static let system = AppLanguage(rawValue: "system")

    var id: String { rawValue }
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static var allCases: [AppLanguage] {
        let languages = Bundle.main.localizations
            .filter(isSelectableLocalization)
            .map(AppLanguage.init(rawValue:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return [.system] + languages
    }

    var displayName: String {
        if self == .system {
            return NSLocalizedString(
                "System default",
                comment: "Language picker option: follow the system app language"
            )
        }

        let displayName = nativeLocale.localizedString(forIdentifier: rawValue) ?? rawValue
        return displayName.capitalized(with: nativeLocale)
    }

    private var nativeLocale: Locale {
        Locale(identifier: rawValue)
    }

    private static func isSelectableLocalization(_ identifier: String) -> Bool {
        guard identifier != "Base" else { return false }
        guard let url = Bundle.main.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: identifier
        ) else {
            return false
        }

        guard
            let data = try? Data(contentsOf: url),
            let strings = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: String]
        else {
            return false
        }

        return strings.values.contains { !$0.isEmpty }
    }

    func applyAppleLanguagesOverride() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
    /// Follow whichever display carries the menu bar. This is what users mean
    /// by "my main screen". Do not confuse it with `.activeDisplay`, which
    /// tracks `NSScreen.main` — the screen with keyboard focus, which changes
    /// as you click between windows.
    case mainDisplay
    case preferredDisplay
    case fallbackIfPreferredUnavailable
    case activeDisplay
    case allDisplays

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .mainDisplay:
            "Follow the display with the menu bar"
        case .preferredDisplay:
            "Use preferred display"
        case .fallbackIfPreferredUnavailable:
            "Automatically switch display if preferred is unavailable"
        case .activeDisplay:
            "Always follow active display"
        case .allDisplays:
            "Show on all displays"
        }
    }
}

// macOS 27 renamed the "Accessibility" privacy pane to "Device Control and
// Data Access". Read the name from Apple's private UniversalAccess auth-warn
// prompt bundle so it matches what the user sees in System Settings, falling
// back to the localized catalog strings.
enum AccessibilityPermission {
    static var displayName: String {
        if let appleName = appleLocalizedAccessibilityName() {
            return appleName
        }
        if #available(macOS 27, *) {
            return String(localized: "Device Control and Data Access")
        } else {
            return String(localized: "Accessibility")
        }
    }

    static var systemImageName: String {
        if #available(macOS 27, *) {
            return "folder.badge.gearshape"
        } else {
            return "accessibility"
        }
    }

    private static let osLocalizationPath =
        "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app/Contents/Resources/Localizable.loctable"

    private static let osPermissionKey = "window.title.accessibility"

    private static let osLocalizedNameTables: [String: [String: String]]? = {
        guard let plist = NSDictionary(contentsOfFile: osLocalizationPath) else {
            return nil
        }
        var tables: [String: [String: String]] = [:]
        for (key, value) in plist {
            guard let locale = key as? String, let entries = value as? [String: Any] else {
                continue
            }
            tables[locale] = entries.compactMapValues { $0 as? String }
        }
        return tables
    }()

    private static func appleLocalizedAccessibilityName() -> String? {
        guard let tables = osLocalizedNameTables else {
            return nil
        }
        for locale in preferredLocaleCandidates {
            if let name = tables[locale]?[osPermissionKey] {
                return name
            }
        }
        return tables["en"]?[osPermissionKey]
    }

    private static var preferredLocaleCandidates: [String] {
        let preferred = Bundle.main.preferredLocalizations + Locale.preferredLanguages
        var candidates: [String] = []
        for preference in preferred {
            let identifier = preference.replacingOccurrences(of: "-", with: "_")
            candidates.append(identifier)
            if identifier.hasPrefix("zh_Hans") {
                candidates.append("zh_CN")
            } else if identifier.hasPrefix("zh_Hant") {
                candidates.append("zh_TW")
                candidates.append("zh_HK")
            }
            if let language = identifier.split(separator: "_", maxSplits: 1).first {
                candidates.append(String(language))
            }
        }
        return candidates
    }
}

// Define notification names at file scope
extension Notification.Name {
    // MARK: - Display
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")

    // MARK: - Shelf
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")

    // MARK: - System
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")

    // MARK: - Sharing
    static let sharingDidFinish = Notification.Name("com.boringNotch.sharingDidFinish")

    // MARK: - UI
    static let accentColorChanged = Notification.Name("AccentColorChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying
    case appleMusic
    case spotify
    case youtubeMusic

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "nowPlaying", "Now Playing": self = .nowPlaying
        case "appleMusic", "Apple Music": self = .appleMusic
        case "spotify", "Spotify": self = .spotify
        case "youtubeMusic", "YouTube Music": self = .youtubeMusic
        default: return nil
        }
    }

    init?(nowPlayingBundleIdentifier bundleIdentifier: String) {
        switch bundleIdentifier {
        case "com.apple.Music":
            self = .appleMusic
        case "com.spotify.client":
            self = .spotify
        case YouTubeMusicConfiguration.default.bundleIdentifier:
            self = .youtubeMusic
        default:
            return nil
        }
    }

    var localizedResource: LocalizedStringResource {
        switch self {
        case .nowPlaying:
            "Now Playing"
        case .appleMusic:
            "Apple Music"
        case .spotify:
            "Spotify"
        case .youtubeMusic:
            "YouTube Music"
        }
    }

    var localizedString: String {
        String(localized: localizedResource)
    }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard
    case inline

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "standard", "Default": self = .standard
        case "inline", "Inline": self = .inline
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .standard:
            return String(localized: "Default", comment: "Sneak Peek style: Default")
        case .inline:
            return String(localized: "Inline", comment: "Sneak Peek style: Inline")
        }
    }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings
    case showOSD
    case none

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "openSettings", "Open System Settings": self = .openSettings
        case "showOSD", "Show HUD": self = .showOSD
        case "none", "No Action": self = .none
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .openSettings:
            return String(localized: "Open System Settings", comment: "Option (⌥) key behavior: Open System Settings")
        case .showOSD:
            return String(localized: "Show OSD", comment: "Option (⌥) key behavior: Show OSD")
        case .none:
            return String(localized: "No action", comment: "Option (⌥) key behavior: No action")
        }
    }
}

// Source/provider for OSD control (user-facing: "Source")
enum OSDControlSource: String, CaseIterable, Identifiable, Defaults.Serializable {
    case builtin
    case betterDisplay = "BetterDisplay"
    case lunar = "Lunar"

    var id: String { self.rawValue }

    var localizedString: String {
        switch self {
        case .builtin:
            return String(localized: "Built-in", comment: "OSD Sources: Built-in")
        case .betterDisplay:
            return "BetterDisplay"
        case .lunar:
            return "Lunar"
        }
    }
}

enum UpdateChannel: String, CaseIterable, Identifiable, Defaults.Serializable {
    case stable
    case beta
    case dev

    var id: String { rawValue }

    static var bundled: UpdateChannel {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BNUpdateChannel") as? String,
              let channel = UpdateChannel(rawValue: value)
        else {
            return .stable
        }
        return channel
    }

    static var visibleCases: [UpdateChannel] {
        // Dev nightlies are intentionally gated away from public stable/beta builds.
        if bundled == .dev || Defaults[.updateChannel] == .dev {
            return allCases
        }
        return [.stable, .beta]
    }

    var title: String {
        switch self {
        case .stable:
            return NSLocalizedString("Stable", comment: "Update channel: stable")
        case .beta:
            return NSLocalizedString("Beta", comment: "Update channel: beta")
        case .dev:
            return NSLocalizedString("Nightly", comment: "Update channel: nightly")
        }
    }

    /// This fork ships no appcast of its own. Returning `nil` keeps Sparkle
    /// from installing the upstream official build over this one, which would
    /// silently discard every customization in this repository. If you ever
    /// publish your own release channel, restore a feed URL here (and the
    /// matching `SUPublicEDKey` in Info.plist) — a feed signed by upstream
    /// must never be reused.
    var feedURLString: String? {
        nil
    }

    var allowedSparkleChannels: Set<String> {
        self == .stable ? [] : [rawValue]
    }
}

enum PreferenceCompatibility {
    /// Runs before Defaults.Key registers its fallback, so a saved false is
    /// distinguishable from a missing value. Keep the old key for older builds.
    static func migratedKeyName(
        _ name: String,
        from legacyName: String,
        in defaults: UserDefaults = .standard
    ) -> String {
        if defaults.object(forKey: name) == nil,
           let legacyValue = defaults.object(forKey: legacyName) as? Bool {
            defaults.set(legacyValue, forKey: name)
        }
        return name
    }
}

extension Defaults.Keys {
    // MARK: General
    static let appLanguage = Key<AppLanguage>("appLanguage", default: .system)
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    /// "Follow the display with the menu bar" is the behaviour the user asked
    /// for on 2026-11-05. `NSScreen.main` is the *keyboard-focus* screen, not
    /// the menu-bar screen, so neither `.activeDisplay` nor the old
    /// `.fallbackIfPreferredUnavailable` default tracks the main display.
    static let displayMode = Key<DisplayMode>("displayMode", default: .mainDisplay)

    // Legacy display settings retained only for one-time migration.
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let followActiveDisplay = Key<Bool>("followActiveDisplay", default: false)
    static let releaseName = Key<String>("releaseName", default: "Dapper Crab 🎩🦀")
    static let updateChannel = Key<UpdateChannel>("updateChannel", default: UpdateChannel.bundled)

    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableOpeningAnimation = Key<Bool>("enableOpeningAnimation", default: true)
    static let animationSpeedMultiplier = Key<Double>("animationSpeedMultiplier", default: 1.0)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    // static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)

    // MARK: Appearance
    // static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let isMirrored = Key<Bool>("isMirrored", default: true)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let mirrorCameraID = Key<String?>("mirrorCameraID", default: nil)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    /// Liquid Glass surface for the opened notch (macOS 26+ only). A hardware
    /// notch keeps its closed pill pure black so it blends into the camera
    /// housing; the floating island on a notch-less display uses glass in the
    /// closed state too (`closedPillUsesGlass` in ContentView).
    static let enableLiquidGlass = Key<Bool>("enableLiquidGlass", default: false)
    /// `true` uses the clear "crystal" glass, `false` the regular frosted one.
    /// Crystal is the default: the frosted style reads as a grey plate on a
    /// dark wallpaper, which is the opposite of what Liquid Glass is for.
    static let liquidGlassClear = Key<Bool>("liquidGlassClear", default: true)
    /// How dark the glass is where it meets the bottom edge. The text on the
    /// panel is white, so the surface can never go fully clear.
    static let liquidGlassDarkness = Key<Double>("liquidGlassDarkness", default: 0.0)
    /// Manual edge refraction, in points of displacement. Only used when
    /// `glassFollowsAppleMetrics` is off — otherwise the value is derived from
    /// the panel height with Apple's measured curve (−60 at 210pt tall).
    static let glassRefraction = Key<Double>("glassRefraction", default: 14)
    /// How far the refraction reaches inward, manual mode only.
    static let glassLensHeight = Key<Double>("glassLensHeight", default: 10)
    /// Chromatic dispersion along the rim. Apple's own glass has none — this is
    /// a tutorial-style embellishment kept as a dial, defaulted off.
    static let glassDispersion = Key<Double>("glassDispersion", default: 0)
    /// Specular highlight on the rim. 0.4 is Apple's measured clear value.
    static let glassHighlight = Key<Double>("glassHighlight", default: 0.4)
    /// The "face" tint of the material: how much the slab colours what passes
    /// through it. 1 = Apple's clear face exactly, 0 = a pure window.
    static let glassOpacity = Key<Double>("glassOpacity", default: 1.0)
    /// Take refraction and lens depth from Apple's size curve instead of the
    /// two manual sliders. On by default — this is the conforming behaviour.
    static let glassFollowsAppleMetrics = Key<Bool>("glassFollowsAppleMetrics", default: true)
    /// Enforce Apple's *clear* gate: clear glass over bright content needs a
    /// ~35% black darkening layer. Off by default because the user has asked
    /// for maximum transparency; the switch exists to be conforming on demand.
    static let glassAdaptiveScrim = Key<Bool>("glassAdaptiveScrim", default: false)
    /// Apple's material continuously reads what is *actually* behind the glass.
    /// The wallpaper is a poor stand-in: a black window dragged under the island
    /// leaves `DesktopLuminance` at 0.440 and the clear-glass dimming layer on,
    /// which paints the whole plate grey. With Screen Recording permission we
    /// sample the real backdrop instead. On by default; silently degrades to the
    /// wallpaper proxy when the permission has not been granted.
    static let glassBackdropSampling = Key<Bool>("glassBackdropSampling", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)

    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let enableHorizontalMediaGestures = Key<Bool>("enableHorizontalMediaGestures", default: false)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)

    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let realtimeAudioWaveform = Key<Bool>("realtimeAudioWaveform", default: false)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    /// 11-08 用户：「Mac 自己屏幕放音乐没有办法显示歌词」「加上一个显示歌词的开关，
    /// 然后用液态玻璃显示歌词，不要上下太宽」。
    /// 只作用于硬件刘海屏：收起态中间是物理摄像头切口，不能写字，
    /// 所以在纯黑刘海板下方挂一条独立的细玻璃歌词带。无刘海屏走浮岛的
    /// 408×66 音乐卡，不受这个开关影响。
    static let showLyricsOnNotchedDisplay = Key<Bool>("showLyricsOnNotchedDisplay", default: true)
    static let showRemainingTime = Key<Bool>("showRemainingTime", default: false)
    static let showMediaSourceAppIcon = Key<Bool>("showMediaSourceAppIcon", default: true)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )

    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    /// Peek the notch when a Bluetooth peripheral (AirPods, keyboard, mouse…)
    /// connects or first crosses the low-battery threshold.
    static let peripheralBatteryEnabled = Key<Bool>("peripheralBatteryEnabled", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    static let showChargingWattage = Key<Bool>("showChargingWattage", default: true)

    // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon)

    // MARK: OSD
    static let osdReplacement = Key<Bool>(PreferenceCompatibility.migratedKeyName("osdReplacement", from: "hudReplacement"), default: false)
    static let inlineOSD = Key<Bool>(PreferenceCompatibility.migratedKeyName("inlineOSD", from: "inlineHUD"), default: false)

    // MARK: Layout
    /// Swaps the opened notch for a smaller, player-only layout: no tab
    /// bar, calendar or mirror. Off by default so existing users keep the
    /// layout they already have.
    static let compactMode = Key<Bool>("compactMode", default: false)

    // MARK: Notifications
    /// Off by default: mirroring banners needs Accessibility access.
    static let notificationLiveActivity = Key<Bool>("notificationLiveActivity", default: false)
    static let notificationsFromAllApps = Key<Bool>("notificationsFromAllApps", default: false)
    static let notificationAllowedApps = Key<Set<String>>(
        "notificationAllowedApps",
        default: []
    )
    /// iOS-style peek: an incoming banner opens the notch on its own so the
    /// message text is readable without hovering over it first.
    static let notificationAutoExpand = Key<Bool>("notificationAutoExpand", default: true)
    /// Calls go back to the real system banner — a mirrored call cannot be
    /// answered, and it expires in seconds. Everything else (including messages
    /// with a Reply button) stays in the notch.
    static let notificationPassthroughActions = Key<Bool>("notificationPassthroughActions", default: true)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchOSD = Key<Bool>(PreferenceCompatibility.migratedKeyName("showOpenNotchOSD", from: "showOpenNotchHUD"), default: true)
    static let showOpenNotchOSDPercentage = Key<Bool>(PreferenceCompatibility.migratedKeyName("showOpenNotchOSDPercentage", from: "showOpenNotchHUDPercentage"), default: true)
    static let showClosedNotchOSDPercentage = Key<Bool>(PreferenceCompatibility.migratedKeyName("showClosedNotchOSDPercentage", from: "showClosedNotchHUDPercentage"), default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    // Brightness/volume/keyboard source selection
    static let osdBrightnessSource = Key<OSDControlSource>("osdBrightnessSource", default: .builtin)
    static let osdVolumeSource = Key<OSDControlSource>("osdVolumeSource", default: .builtin)

    // MARK: Shelf
    static let boringShelf = Key<Bool>("boringShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let shelfTapToOpen = Key<Bool>("shelfTapToOpen", default: true)
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.defaultProvider.id)
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    static let reverseShelfOrdering = Key<Bool>("reverseShelfOrdering", default: false)

    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    static let calendarWeekView = Key<Bool>("calendarWeekView", default: false)
    static let weekStartDay = Key<WeekStartDay>("weekStartDay", default: .system)
    static let joinMeetingOnEventTap = Key<Bool>("joinMeetingOnEventTap", default: true)

    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)

    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    static let didChooseMediaController = Key<Bool>("didChooseMediaController", default: false)
    static let didMigrateMediaControllerChoice = Key<Bool>("didMigrateMediaControllerChoice", default: false)
    static let lastSupportedNowPlayingBundleIdentifier = Key<String?>(
        "lastSupportedNowPlayingBundleIdentifier",
        default: nil
    )

    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    static let hideNonNotchedFromMissionControl = Key<Bool>("hideNonNotchedFromMissionControl", default: true)
    /// 11-08 用户拍板「空闲时候可以消失」。无刘海屏上没有硬件挖孔，
    /// 空着还画一颗玻璃胶囊就像贴纸；默认只在真有内容时画。
    /// 关掉它可以恢复「常驻胶囊」，与下面的浮岛总开关互不依赖。
    static let hideIdlePlateOnNonNotch = Key<Bool>("hideIdlePlateOnNonNotch", default: true)
    /// 浮岛总开关（通知卡 / 音乐卡 / 手点开面板 / 圆角 / 悬浮 offset 全部
    /// 挂在 `usesFloatingIsland` 上），不是「静止时画胶囊」的开关。
    /// 关掉会退回内建屏那套贴边黑板，一般不要动。
    /// 11-08 起与 `hideIdlePlateOnNonNotch` 不再互斥 —— 旧版设置页强制把两者
    /// 归一化成「常驻胶囊」，是空闲浮岛关不掉的历史原因（docs/04 J3）。
    static let floatingPillOnNonNotchDisplay = Key<Bool>("floatingPillOnNonNotchDisplay", default: true)
    /// v2 of the one-shot `preferred_screen_uuid` repair. v1 marked itself done
    /// even when the repair never ran (e.g. only one display online at launch),
    /// so the baked-in UUID survived forever. v2 only marks itself when it
    /// actually cleared the value.
    static let preferredScreenUUIDRepairV2 = Key<Bool>("preferredScreenUUIDRepairV2", default: false)
    /// One-shot switch from the legacy `.fallbackIfPreferredUnavailable`
    /// default to `.mainDisplay`. Deliberately leaves any mode the user
    /// deliberately picked (preferred / active / all displays) untouched.
    static let displayModeMigratedToMainDisplay = Key<Bool>("displayModeMigratedToMainDisplay", default: false)
    // Normalize scroll/gesture direction so when macOS "Natural scrolling" is disabled, it doesn't invert gestures
    static let normalizeGestureDirection = Key<Bool>("normalizeGestureDirection", default: true)

    // Keep the default stable. Runtime availability is handled by MusicManager.
    static var defaultMediaController: MediaControllerType {
        .nowPlaying
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
