//
//  NotificationLiveActivity.swift
//  boringNotch
//

import SwiftUI

struct NotificationSourceIcon: View {
    let bundleID: String?
    /// Fallback source for icon resolution: when the capture chain couldn't
    /// resolve a bundle ID, the app's display name still identifies it
    /// (BundleIDResolver memoizes, so repeated renders are free).
    var appName: String? = nil
    let size: CGFloat

    private var resolvedBundleID: String? {
        bundleID ?? appName.flatMap { BundleIDResolver.shared.bundleID(forAppNamed: $0) }
    }

    var body: some View {
        if let resolvedBundleID {
            appIcon(for: resolvedBundleID)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: "bell")
                .font(.system(size: size * 0.55))
                .frame(width: size, height: size)
        }
    }
}

/// The arriving-message bar: which app it came from on top, then who sent it
/// and what they said on one line underneath.
struct NotificationPeekBar: View {
    @EnvironmentObject private var vm: BoringViewModel
    let notification: SystemNotification

    /// Peek metrics, shared with `ContentView` so the island's growth and the
    /// content that fills it can never drift apart — when they disagree the
    /// message is either clipped or floats in dead space.
    enum Metrics {
        /// Outer width of the bar. 460 was tuned for 14pt type; at 16pt the
        /// line needs ~10 more characters before it starts truncating.
        static let barWidth: CGFloat = 520
        /// App row: the label is a caption for the icon, not the headline.
        static let appLabelSize: CGFloat = 15
        static let iconSize: CGFloat = 23
        static let leadingInset: CGFloat = 14
        /// The message is what the eye lands on — 16pt against 15pt label.
        static let messageSize: CGFloat = 16
        /// Reserved height for the message line (16pt type + breathing room).
        static let messageLineHeight: CGFloat = 25
        /// Gap under the message line, before the rounded bottom edge.
        static let bottomPadding: CGFloat = 10
        /// How far the island grows below the camera strip.
        static var growth: CGFloat { messageLineHeight + bottomPadding }
    }

    private var barWidth: CGFloat { Metrics.barWidth }
    private var notchHeight: CGFloat { vm.effectiveClosedNotchHeight }
    /// Horizontal room outside the camera housing on the left side.
    private var leftSlot: CGFloat {
        max(90, (barWidth - vm.closedNotchSize.width) / 2 - Metrics.leadingInset)
    }

    /// Top line: which app this came from — the icon already shows it, the
    /// label makes it unambiguous when several apps use the same look.
    private var appLabel: String {
        let name = notification.appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "通知" : name.replacingOccurrences(of: "\n", with: " ")
    }

    /// Bottom line, part one: the sender.
    private var senderText: String {
        let title = notification.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, title != appLabel else { return "" }
        return title.replacingOccurrences(of: "\n", with: " ")
    }

    /// Bottom line, part two: the message itself.
    private var messageText: String {
        for candidate in [notification.body, notification.subtitle] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    /// Sender and body share one line so a glance covers "who" and "what".
    /// Two `Text` values concatenated (not an HStack) so truncation applies to
    /// the whole line instead of squeezing the message into nothing.
    private var contentLine: Text {
        let sender = senderText
        let message = messageText

        if sender.isEmpty {
            return Text(message)
                .font(.system(size: Metrics.messageSize))
                .foregroundColor(.white)
        }
        if message.isEmpty {
            return Text(sender)
                .font(.system(size: Metrics.messageSize, weight: .semibold))
                .foregroundColor(.white)
        }
        return Text(sender + "：")
            .font(.system(size: Metrics.messageSize, weight: .semibold))
            .foregroundColor(.white)
            + Text(message)
            .font(.system(size: Metrics.messageSize))
            .foregroundColor(.white)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                NotificationSourceIcon(
                    bundleID: notification.bundleID,
                    appName: notification.appName,
                    size: Metrics.iconSize
                )

                Text(appLabel)
                    .font(.system(size: Metrics.appLabelSize, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.leading, Metrics.leadingInset)
            .frame(width: leftSlot, alignment: .leading)
            .frame(width: barWidth, height: notchHeight, alignment: .leading)

            contentLine
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: barWidth - Metrics.leadingInset * 2, alignment: .center)
                .frame(height: Metrics.messageLineHeight, alignment: .center)
                .padding(.bottom, Metrics.bottomPadding)
        }
        // White type on the glass plate needs its own contrast: without this
        // the 16pt line picks up the panel's grey and reads as secondary.
        // Same two-pass shadow as the song info — a tight one traces the glyph
        // edge, a wide one gives the block local contrast.
        .shadow(color: .black.opacity(0.55), radius: 1)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        .frame(width: barWidth)
    }
}

/// The stock small window: app icon, camera mask and the accent dot, drawn
/// inside the notch band. Upstream shows exactly this when a notification
/// arrives; the closed-notch pill reuses it verbatim.
struct NotificationLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    let notification: SystemNotification

    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity = 0.0

    private var itemSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    var body: some View {
        HStack {
            NotificationSourceIcon(bundleID: notification.bundleID, appName: notification.appName, size: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            ZStack {
                Circle()
                    .stroke(Color.effectiveAccent, lineWidth: 1.5)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                Circle()
                    .fill(Color.effectiveAccent)
                    .frame(width: 7, height: 7)
            }
            .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .onAppear { pulse() }
        .onChange(of: notification.id) { _, _ in pulse() }
    }

    private func pulse() {
        ringScale = 1
        ringOpacity = 0.8
        withAnimation(.easeOut(duration: 0.6)) {
            ringScale = 1.8
            ringOpacity = 0
        }
    }
}

/// The hover-expanded card. The hardware-notch branch is upstream's layout
/// with type nudged up one step (15/13/14pt) and everything forced to white.
/// The floating-island branch (`compactLayout`) follows Apple's own banner
/// anatomy instead: ONE large app icon at the leading edge, a headline +
/// timestamp on line 1, the message on line 2 — the app is identified by its
/// icon, never by a separate line of text. See Apple HIG › Notifications ›
/// Content and the 11-07 screenshot measurements in docs/04 L11.
struct NotificationExpandedView: View {
    @ObservedObject private var manager = SystemNotificationManager.shared
    let notification: SystemNotification
    /// The floating island is sized to Apple's iPadOS / macOS Live Activity
    /// card (408 wide), so its content has to be tighter than the 520×132
    /// phone-sized card. `false` keeps the hardware-notch layout untouched.
    var compactLayout: Bool = false
    /// The card's outer width, handed down by `ContentView`. The card never
    /// learns it otherwise: the enclosing VStack is intrinsic, so it proposes
    /// the card's IDEAL width (measured 240pt in a 300pt plate) and every
    /// `maxWidth: .infinity` inside collapses to that. Passing the real width
    /// lets the column be computed instead of negotiated.
    var cardWidth: CGFloat?

    private var compactColumnWidth: CGFloat? {
        guard let cardWidth else { return nil }
        return max(0, cardWidth - compactLeadingInset - compactTrailingInset)
    }

    // Only the geometry tightens; type stays at a readable 12–14pt instead
    // of being scaled down to ~11pt with the card.
    // 11-07: the leading image is 42pt, measured off Apple's own banner
    // (48px ≈ 42pt on the user's 883×1920 @2x screenshot), not the old 32pt
    // thumbnail that made the card look like a row of list text.
    private var iconSize: CGFloat { compactLayout ? 42 : 46 }
    private var rowSpacing: CGFloat { compactLayout ? 10 : 12 }
    private var textSpacing: CGFloat { compactLayout ? 2 : 5 }
    private var stackSpacing: CGFloat { compactLayout ? 4 : 8 }
    private var textColumnWidth: CGFloat { compactLayout ? 250 : 300 }
    private var appNameSize: CGFloat { compactLayout ? 14 : 15 }
    private var timeSize: CGFloat { compactLayout ? 11 : 12 }
    private var detailSize: CGFloat { compactLayout ? 12 : 13 }
    private var bodySize: CGFloat { compactLayout ? 12.5 : 14 }
    private var bodyLineLimit: Int { compactLayout ? 1 : 2 }
    private var controlSize: CGFloat { compactLayout ? 16 : 18 }

    /// The system banner insets its icon 16pt from the card edge; 14 keeps the
    /// same optical breathing room on our 408pt card, 10 clears the controls.
    private var compactLeadingInset: CGFloat { 14 }
    private var compactTrailingInset: CGFloat { 10 }

    /// Width of the trailing button cluster, computed from the same items
    /// `controls` draws, so the text column never has to guess. A queued-
    /// notification pill adds one more item.
    private var controlsWidth: CGFloat {
        let hasQueue = !manager.queuedNotifications.isEmpty
        let items = hasQueue ? 3 : 2
        return controlSize * 2 + (hasQueue ? 24 : 0) + 4 * CGFloat(items - 1)
    }

    /// Explicit width for the two-line column. Passing a real number down
    /// (instead of `maxWidth: .infinity`) is what lets the timestamp's Spacer
    /// resolve: the enclosing VStack is intrinsic, so a flexible frame
    /// collapses to the ideal 240pt and the time never reaches the right
    /// edge (docs/04 L9.3).
    private var compactTextWidth: CGFloat? {
        guard let column = compactColumnWidth else { return nil }
        return max(120, column - iconSize - rowSpacing - controlsWidth - 8)
    }

    /// Apple puts the title/sender on line 1 and the message on line 2. The
    /// app name is NOT a line of its own — HIG: "Avoid including your app
    /// name or icon. The system automatically displays a large version of
    /// your app icon at the leading edge of each notification; in a
    /// communication notification, the system displays the sender's contact
    /// image badged with a small version of your icon." We express it with
    /// the single large app icon at the leading edge instead of burning a
    /// text row (no secondary badge — see `leadingIcon`).
    private var compactHeadline: String {
        let title = notification.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, title != notification.appName {
            return title.replacingOccurrences(of: "\n", with: " ")
        }
        return (notification.appName ?? "通知").replacingOccurrences(of: "\n", with: " ")
    }

    private var compactDetail: String {
        for candidate in [notification.body, notification.subtitle] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty, value != compactHeadline {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    var body: some View {
        Group {
            if compactLayout {
                // A macOS notification hangs its content off the LEFT edge:
                // icon first, text column right beside it, controls parked at
                // the far right. The 20:30 version centred the whole group to
                // satisfy the "visual centre" rule, which left ~70pt of empty
                // glass to the left of the icon — the user spotted it at once
                // ("苹果的通知是贴左边吧", 11-06 10:42). Centring belongs to the
                // closed capsule and the HUD; a notification is left-aligned.
                VStack(alignment: .leading, spacing: stackSpacing) {
                    HStack(spacing: 0) {
                        openButton
                        // Absorbs whatever the button cluster doesn't use.
                        // The cluster's width is already subtracted from
                        // `compactTextWidth`, so this can only ever be >= 4.
                        Spacer(minLength: 4)
                        controls
                    }
                    // Probe the visible row. The acceptance test is no longer
                    // "row centre == 320"; it is "icon's left edge == card's
                    // left edge + compactLeadingInset".
                    .background { cardProbe }
                    actionButtons
                }
                .padding(.leading, compactLeadingInset)
                .padding(.trailing, compactTrailingInset)
                // The card centres its child by default (300pt then, 408pt
                // now), so a VStack of intrinsic width still lands in the middle even
                // after the row inside it is left-aligned (measured: row at
                // x=215 with a 213pt width — dead centre). `maxWidth:
                // .infinity` cannot fix it, because the enclosing stack offers
                // only the ideal width; the column has to be sized outright.
                .frame(width: compactColumnWidth, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { logColumn(proxy) }
                            .onChange(of: proxy.size) { _, _ in logColumn(proxy) }
                    }
                }
            } else {
                // Hardware notch: the original layout, untouched. The card is
                // 520pt wide and the controls stay in the top-right corner.
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: stackSpacing) {
                        openButton
                        actionButtons
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.trailing, 44)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    controls
                        .padding(.trailing, 4)
                }
            }
        }
        // Do NOT freeze the dismiss countdown here. `onAppear` fires for the
        // automatic peek too (and can race the peek flag), which used to make
        // a notification stay on screen forever. Presence is owned by the
        // hover path alone: `ContentView.handleHover` calls `holdActive()` on
        // enter and `resumeDismiss()` on exit.
    }

    /// Icon + text, wrapped in the "open the source app" button. Only the
    /// floating island swaps in Apple's two-line anatomy; the hardware-notch
    /// card keeps its original four-line `textBlock` verbatim.
    private var openButton: some View {
        Button(action: openSourceApp) {
            HStack(alignment: .center, spacing: rowSpacing) {
                leadingIcon
                textContent
            }
            // No padding of its own any more: the horizontal inset comes from
            // the card (`compactLeadingInset`), and a vertical one would grow
            // the row by 8pt and with it the whole card.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(notification.appName ?? "App") notification")
        .accessibilityHint("Opens \(notification.appName ?? "the app")")
    }

    /// One large app icon, no secondary badge. The user decided on 11-07
    /// 20:47: without a real contact photo to put underneath, a second copy
    /// of the same app icon is just noise. HIG's "large version of your app
    /// icon at the leading edge" is satisfied by this alone. `iconSize`
    /// already differs per layout (42pt island / 46pt hardware notch).
    private var leadingIcon: some View {
        NotificationSourceIcon(bundleID: notification.bundleID,
                               appName: notification.appName,
                               size: iconSize)
    }

    @ViewBuilder
    private var textContent: some View {
        if compactLayout { compactTextBlock } else { textBlock }
    }

    /// Two rows, Apple's own order: headline + relative time on the first,
    /// message on the second. No app-name row, no subtitle row. The timestamp
    /// sits at the RIGHT edge of the column, not next to the app name.
    private var compactTextBlock: some View {
        VStack(alignment: .leading, spacing: textSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(compactHeadline)
                    .font(.system(size: appNameSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(notification.receivedAt, style: .relative)
                    .font(.system(size: timeSize))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize()
            }

            if !compactDetail.isEmpty {
                Text(compactDetail)
                    .font(.system(size: bodySize))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: compactTextWidth, alignment: .leading)
        // Same contrast pass as the peek bar: white type needs its own
        // shadow on clear glass over a light wallpaper.
        .shadow(color: .black.opacity(0.55), radius: 1)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { bnDebugLog("compacttext frame=\(proxy.frame(in: .global))") }
                    .onChange(of: proxy.size) { _, _ in
                        bnDebugLog("compacttext frame=\(proxy.frame(in: .global))")
                    }
            }
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: textSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notification.appName ?? "Notification")
                    .font(.system(size: appNameSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                // Was `.tertiary`: on the grey glass that resolves to
                // roughly 35% white and the age of the message looked
                // like a disabled control. Size already separates it
                // from the app name, so it can be full white.
                Text(notification.receivedAt, style: .relative)
                    .font(.system(size: timeSize))
                    .foregroundStyle(.white)
                    .fixedSize()
            }

            if let title = notification.title, title != notification.appName {
                Text(title)
                    .font(.system(size: detailSize, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            if let subtitle = notification.subtitle {
                Text(subtitle)
                    .font(.system(size: detailSize))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            if let body = notification.body {
                Text(body)
                    .font(.system(size: bodySize))
                    .foregroundStyle(.white)
                    .lineLimit(bodyLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Legacy hardware-notch card only — the floating island now uses
        // `compactTextBlock` with an explicit computed width. This branch
        // keeps its original 300pt cap untouched.
        .frame(maxWidth: compactLayout ? nil : textColumnWidth, alignment: .leading)
        // Same contrast pass as the peek bar: without it the white
        // body picks up the panel's grey on a light wallpaper.
        .shadow(color: .black.opacity(0.55), radius: 1)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }

    /// Runtime probe for the centring rule. Only way to tell "the card is
    /// centred" from "the frame is centred and the text drifted" without
    /// screen-recording permission (docs/04 D).
    private var cardProbe: some View {
        GeometryReader { proxy in
            Color.clear
                // `onAppear` alone samples the FIRST frame of the expand
                // animation (measured 235 → 262 while the card was still
                // growing), which is why two rounds of tuning were chasing a
                // moving target. `onChange` catches the settled value.
                .onAppear { bnDebugLog("notifcard frame=\(proxy.frame(in: .global))") }
                .onChange(of: proxy.size) { _, _ in
                    bnDebugLog("notifcard frame=\(proxy.frame(in: .global))")
                }
        }
    }

    /// Companion to `cardProbe`: reports the column that owns the leading
    /// inset. If this is narrower than the card, the `.frame(width:)` upstream
    /// is not reaching it and the inset can never take effect.
    private func logColumn(_ proxy: GeometryProxy) {
        bnDebugLog(
            "cardcol frame=\(proxy.frame(in: .global))"
            + " inset=\(compactLeadingInset)/\(compactTrailingInset)"
        )
    }

    /// The banner's own buttons, re-hosted in the notch.
    ///
    /// The real banner is parked off screen, so its "Accept" / "Decline" /
    /// "Open" buttons are still there but unreachable. They are drawn here and
    /// pressed through the helper. Buttons that need a keyboard ("Reply") never
    /// get this far — the helper leaves those banners on screen instead.
    @ViewBuilder
    private var actionButtons: some View {
        if !notification.actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(notification.actions.prefix(3)) { action in
                    Button {
                        manager.performAction(action, on: notification)
                    } label: {
                        Text(action.title)
                            .font(.system(size: compactLayout ? 11 : 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, compactLayout ? 10 : 12)
                            .padding(.vertical, compactLayout ? 5 : 6)
                            .background(.white.opacity(0.16), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title)
                }
            }
            // No horizontal padding of its own: the compact card aligns the
            // action row with the icon via `compactLeadingInset`, and the
            // hardware-notch branch adds its own 4pt back at the call site.
            .shadow(color: .black.opacity(0.4), radius: 1)
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if !manager.queuedNotifications.isEmpty {
                Button {
                    manager.showNextQueued()
                } label: {
                    Text("+\(manager.queuedNotifications.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show next queued notification")
            }

            Button {
                manager.reveal(notification)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                        .frame(width: controlSize, height: controlSize)
                        .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Show the real banner")
            .accessibilityLabel("Show this notification on screen")

            Button {
                manager.dismissActive(token: notification.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                        .frame(width: controlSize, height: controlSize)
                        .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
    }

    private func openSourceApp() {
        Task {
            guard await manager.open(notification) else { return }
            manager.dismissActive(token: notification.id)
        }
    }
}
