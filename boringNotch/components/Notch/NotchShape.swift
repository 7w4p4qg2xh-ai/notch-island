//
//  NotchShape.swift
//  boringNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Defaults
import ObjectiveC
import QuartzCore
import ScreenCaptureKit
import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    /// Apple uses two different corner curves depending on the object:
    /// the compact Dynamic Island is a true capsule with semicircular ends
    /// (a plain circular arc), while expanded panels/cards use continuous
    /// (squircle) curvature. `usesContinuousCorners` picks the squircle
    /// rectangle; `usesCircularCorners` picks the circular capsule. When
    /// neither is set the shape is the hardware-notch outline below, which
    /// now also uses continuous curvature.
    private var usesContinuousCorners: Bool
    private var usesCircularCorners: Bool
    /// A true Dynamic Island pill: both ends are exact semicircles of the
    /// CURRENT plate height. A fixed radius cannot work in the closed state:
    /// as soon as a live activity (music / HUD / battery) grows the plate from
    /// 24pt to 29pt, a 12pt radius leaves a straight waist between the upper
    /// and lower arcs — the "figure 8" outline the user photographed.
    private var usesCapsuleCorners: Bool

    /// Apple's corner-to-height ratio for a continuous-corner card.
    ///
    /// Measured from two independent references: the expanded Dynamic Island
    /// is 36–44pt on a 160pt card (0.225–0.275) and a macOS notification
    /// banner is ≈20pt on ~90pt (0.22). 0.24 sits between them and, by
    /// coincidence worth keeping, reproduces this project's 150pt panel at
    /// exactly the 36pt it already uses.
    ///
    /// The upper bound is forced by the geometry itself: one continuous
    /// corner spans 1.528665·r in both axes, so two corners need 3.057·r of
    /// height. 0.24 is comfortably under 1/3.057 = 0.327.
    static let cornerHeightRatio: CGFloat = 0.24

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil,
        usesContinuousCorners: Bool = false,
        usesCircularCorners: Bool = false,
        usesCapsuleCorners: Bool = false
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
        self.usesContinuousCorners = usesContinuousCorners
        self.usesCircularCorners = usesCircularCorners
        self.usesCapsuleCorners = usesCapsuleCorners
    }

    /// Exposed so the glass renderer can build its lens from the very numbers
    /// the clip shape uses — two sources of truth would drift apart the moment
    /// the panel changes size.
    var resolvedTopRadius: CGFloat { topCornerRadius }
    var resolvedBottomRadius: CGFloat { bottomCornerRadius }
    /// The refraction layer must match the corner *curve*, not just the
    /// radius (docs/04 C5). Every outline except the circular capsule is a
    /// continuous-curvature one now.
    var usesSquircleCorners: Bool { !usesCircularCorners && !usesCapsuleCorners }

    /// The glass renderer needs to know this outline is a true capsule: its
    /// radius is half the ACTUAL plate height (a music activity can grow the
    /// plate from 24 to 29pt), while `topCornerRadius` stays at the nominal
    /// 12pt passed in by `ContentView`. Using the nominal value would rebuild
    /// the straight waist inside the distance field even though the clip
    /// shape is a capsule.
    var isCapsule: Bool { usesCapsuleCorners }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {        get {
            .init(
                topCornerRadius,
                bottomCornerRadius
            )
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // `Capsule` derives its radius from the shorter side of `rect`, so the
        // ends stay semicircular whatever the closed plate's content height
        // is. This is the only shape that cannot produce a straight waist.
        if usesCapsuleCorners {
            return Capsule().path(in: rect)
        }

        // The compact island is a TRUE pill: two semicircular ends. Apple uses
        // an ordinary circular arc here (border-radius 9999px in HIG terms),
        // not a squircle — at r = height/2 the continuous curve reads as a
        // slightly squared-off capsule instead of a round one.
        if usesCircularCorners {
            return UnevenRoundedRectangle(
                topLeadingRadius: topCornerRadius,
                bottomLeadingRadius: bottomCornerRadius,
                bottomTrailingRadius: bottomCornerRadius,
                topTrailingRadius: topCornerRadius,
                style: .circular
            )
            .path(in: rect)
        }

        // Floating cards and the edge-anchored glass plate are plain rounded
        // rectangles, so SwiftUI can supply Apple's continuous curvature.
        //
        // The radius has to be capped against the card's HEIGHT, because a
        // continuous corner spans 1.528665·r horizontally *and* vertically:
        // two of them need 3.057·r of height before they stop competing for
        // the same pixels. SwiftUI does not keep the corner square when they
        // collide — it holds the horizontal span and squeezes the vertical
        // one, so r = 36 on a 56pt card (measured height of the notification
        // card) comes out 42.8 wide but only 28 tall: a 1.53:1 elliptic
        // corner. That is the "sagging" look; Apple never draws it.
        //
        // Apple's own ratio is r ≈ 0.24·h (Dynamic Island 36–44pt on a 160pt
        // card; macOS notification banners ≈20pt on ~90pt). At 0.24 our 150pt
        // hand-opened panel keeps its existing 36pt exactly, so this cap is a
        // no-op there, while a 56pt notification card lands on 13.4 and stays
        // equilateral.
        if usesContinuousCorners {
            let cap = rect.height * NotchShape.cornerHeightRatio
            let top = min(topCornerRadius, cap)
            let bottom = min(bottomCornerRadius, cap)
            return UnevenRoundedRectangle(
                topLeadingRadius: top,
                bottomLeadingRadius: bottom,
                bottomTrailingRadius: bottom,
                topTrailingRadius: top,
                style: .continuous
            )
            .path(in: rect)
        }

        // Hardware-notch outline: the top edge is full width (flush with the
        // bezel), the two shoulders inset by topCornerRadius, and the bottom
        // corners are the large ones.
        //
        // Upstream drew all four corners as quadratic Béziers — parabolas,
        // whose curvature jumps from zero on the straight edge to a fixed
        // value at the corner (a G1 discontinuity). Apple eases curvature in
        // and out instead. `addContinuousCorner` keeps the EXACT same
        // endpoints and end tangents as the old quadratic corner, so the
        // measured footprint against the physical cutout does not move by a
        // single pixel — only the curvature changes. The coefficients came
        // from dumping Apple's own `.continuous` path (see the helper).
        var path = Path()
        let t = topCornerRadius
        let b = bottomCornerRadius

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addContinuousCorner(
            vertex: CGPoint(x: rect.minX + t, y: rect.minY),
            incoming: CGVector(dx: 1, dy: 0),
            outgoing: CGVector(dx: 0, dy: 1),
            radius: t
        )
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addContinuousCorner(
            vertex: CGPoint(x: rect.minX + t, y: rect.maxY),
            incoming: CGVector(dx: 0, dy: 1),
            outgoing: CGVector(dx: 1, dy: 0),
            radius: b
        )
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addContinuousCorner(
            vertex: CGPoint(x: rect.maxX - t, y: rect.maxY),
            incoming: CGVector(dx: 1, dy: 0),
            outgoing: CGVector(dx: 0, dy: -1),
            radius: b
        )
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addContinuousCorner(
            vertex: CGPoint(x: rect.maxX - t, y: rect.minY),
            incoming: CGVector(dx: 0, dy: -1),
            outgoing: CGVector(dx: -1, dy: 0),
            radius: t
        )
        path.closeSubpath()

        return path
    }
}

private extension Path {
    /// One quarter corner with Apple's *actual* continuous curvature.
    ///
    /// These coefficients are measured, not guessed: they were read back from
    /// `UnevenRoundedRectangle(..., style: .continuous).cgPath` on macOS 27
    /// with r = 40 (dumped 2026-11-05), then reversed into our drawing
    /// direction. Apple splits one corner into THREE cubic Béziers and starts
    /// the rounding 1.528665·r away from the square vertex. The first and
    /// last control points sit on the straight edges, so curvature is zero at
    /// both ends — that is the whole point of a continuous corner, and it is
    /// what a quadratic parabola or a plain circular arc cannot do.
    ///
    /// The notch outline has fixed endpoints r away from the vertex (that is
    /// what makes its width match the physical cutout), so Apple's curve is
    /// uniformly squeezed by 1/1.528665. Endpoints and end tangents stay
    /// exactly where the old quadratic corner had them; only the curvature
    /// changes, so the measured footprint does not move by a pixel.
    mutating func addContinuousCorner(
        vertex: CGPoint,
        incoming: CGVector,
        outgoing: CGVector,
        radius: CGFloat
    ) {
        guard radius > 0 else { return }
        let s = radius / 1.528665

        func point(_ alongIncoming: CGFloat, _ alongOutgoing: CGFloat) -> CGPoint {
            CGPoint(
                x: vertex.x + incoming.dx * alongIncoming * s
                    + outgoing.dx * alongOutgoing * s,
                y: vertex.y + incoming.dy * alongIncoming * s
                    + outgoing.dy * alongOutgoing * s
            )
        }

        let start = point(-1.528665, 0)
        if currentPoint != start { addLine(to: start) }

        addCurve(
            to: point(-0.631495, 0.0749125),
            control1: point(-1.088490, 0),
            control2: point(-0.8684075, 0)
        )
        addCurve(
            to: point(-0.0749125, 0.631495),
            control1: point(-0.372825, 0.169060),
            control2: point(-0.169060, 0.372825)
        )
        addCurve(
            to: point(0, 1.528665),
            control1: point(0, 0.8684075),
            control2: point(0, 1.088490)
        )
    }
}

#Preview {
    NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        .frame(width: 200, height: 32)
        .padding(10)
}

// MARK: - Apple's glass recipe

/// Apple sizes the material with the element: a bigger surface gets a deeper
/// lens and a heavier shadow, because a thick slab of glass is physically
/// deeper than a thin one. These curves were **measured**, not guessed —
/// two live `NSGlassEffectView`s (180×44 and 640×210) were dumped and every
/// `glassBackground` input read back. Both sizes are reproduced exactly by the
/// formulas below, including Apple's clamps at the large end.
///
/// | element height | inner refraction | lens height | shadow | shadow height |
/// |---|---|---|---|---|
/// | 44pt | −28.6 | 15.84 | 27.5 | 17.6 |
/// | 210pt | −60 | 20 | 75 | 84 |
enum GlassMetrics {
    /// −28.6 at 44pt, −60 at 210pt and above.
    static func innerRefraction(height: CGFloat) -> Double {
        -min(0.65 * Double(height), 60)
    }

    /// 15.84 at 44pt, 20 at 210pt and above.
    static func innerRefractionHeight(height: CGFloat) -> Double {
        min(0.36 * Double(height), 20)
    }

    /// 27.5 at 44pt, 75 at 210pt and above. Only the clear variant uses it.
    static func shadowAmount(height: CGFloat) -> Double {
        min(0.625 * Double(height), 75)
    }

    /// Exactly 0.4 × height at both measured sizes.
    static func shadowHeight(height: CGFloat) -> Double {
        0.4 * Double(height)
    }

    /// 5 at 44pt, 10 at 210pt. Only the regular variant uses it.
    static func blurRadius(height: CGFloat) -> Double {
        max(5, min(0.05 * Double(height), 10))
    }

    /// 73.5 at 210pt. Regular variant only.
    static func bleedAmount(height: CGFloat) -> Double {
        min(0.35 * Double(height), 73.5)
    }
}

/// The two materials Apple ships. They are not one material with a blur dial:
/// `regular` swaps the shadow layer for a light-scattering "bleed" layer,
/// raises the black point and adds a ring shadow. Treating them as a single
/// parameter set is what made the frosted option read as "the same glass, but
/// smeared".
enum GlassVariant {
    case clear
    case regular
}

/// One complete material. Every field maps 1:1 onto a `glassBackground` input.
struct GlassParameters {
    var innerRefraction: Double = 0
    var innerRefractionHeight: Double = 0
    var refractionOpacity: Double = 0

    var faceWhite: Double = 1
    var faceBlack: Double = 0
    var faceSaturation: Double = 1
    var faceFillAlpha: Double = 0
    var faceMaxLumaSDR: Double = 1

    var shadowAmount: Double = 0
    var shadowHeight: Double = 0
    var shadowFillAlpha: Double = 0

    var highlight: Double = 0.4
    var highlightSpread: Double = 1.309
    var highlightColorBias: Double = -0.25

    var blurRadius: Double = 0
    var blurEdgeOpacity: Double = 0
    var blurFillRadius: Double = 0
    var blurFillLighten: Double = 0
    var blurFillDarken: Double = 0
    var blurFillNormal: Double = 0

    var bleedAmount: Double = 0
    var ringStroke: Double = 0
    var ringOffset: Double = 0
    var ringBlur: Double = 0
    var ringMask: Double = 0

    var dispersion: Double = 0

    init(variant: GlassVariant, height: CGFloat) {
        let h = max(height, 1)
        innerRefraction = GlassMetrics.innerRefraction(height: h)
        innerRefractionHeight = GlassMetrics.innerRefractionHeight(height: h)

        switch variant {
        case .clear:
            faceWhite = 0.95
            // Apple's own clear lifts the black point to 0.2. Faithful, but on a
            // colourful wallpaper the lift is what turns the panel milky-grey:
            // the darks never arrive, so the whole face sits on a grey floor.
            // Halved — still not a pure window, just no grey cast.
            faceBlack = 0.1
            faceSaturation = 1.0
            // The face fill is a white veil at this alpha. 0.1 read as "a sheet
            // of tracing paper over the desktop"; 0.05 keeps the slab tangible
            // without fogging what is behind it.
            faceFillAlpha = 0.05
            faceMaxLumaSDR = 1.0

            shadowAmount = GlassMetrics.shadowAmount(height: h)
            // 0.4 × height is Apple's measured value, but that is a 78pt band on
            // a 195pt panel — most of the plate ends up inside a soft black
            // gradient, which reads as grey rather than as an edge. Narrowed.
            shadowHeight = GlassMetrics.shadowHeight(height: h) * 0.7
            shadowFillAlpha = 0.05

            highlight = 0.4
            highlightSpread = 1.309
            highlightColorBias = -0.25

            // Clear is not "blur zero" in Apple's own filter — it is blur 10
            // with every distance stop pinned to 0, i.e. blur that never
            // reaches the sample. We pin the radius too, so nothing can
            // reintroduce a frost by accident.
            blurRadius = 0
        case .regular:
            faceWhite = 0.96
            faceBlack = 0.4
            faceSaturation = 1.2
            faceFillAlpha = 1.0
            faceMaxLumaSDR = 0.94

            shadowAmount = 0
            shadowHeight = 0
            shadowFillAlpha = 0.3

            highlight = 0.5
            highlightSpread = 2.094
            highlightColorBias = -0.1875

            blurRadius = GlassMetrics.blurRadius(height: h)
            blurEdgeOpacity = 0.8
            blurFillRadius = 8
            blurFillLighten = 0.675

            bleedAmount = GlassMetrics.bleedAmount(height: h)
            ringStroke = 4
            ringOffset = 8
            ringBlur = 5
            ringMask = 1
        }
    }

    /// The "glass presence" slider. At 0 the face stops tinting the backdrop at
    /// all (a pure window onto the desktop); at 1 it is exactly Apple's clear
    /// face. Apple itself exposes this as the Tinted/Clear control, so the
    /// slider is the honest equivalent rather than a made-up knob.
    mutating func applyPresence(_ presence: Double) {
        let p = min(max(presence, 0), 1)
        faceWhite = 1 - (1 - faceWhite) * p
        faceBlack *= p
        faceFillAlpha *= p
        // The rim shadow is part of the same veil: leaving it at full strength
        // while the face goes clear is what made a low "glass presence" still
        // look grey around the edges. Scaling it makes the slider honest —
        // 100% is Apple's clear, 0% is a plain window.
        shadowFillAlpha *= p
    }
}

// MARK: - Liquid Glass surface

/// The plate behind the notch content.
///
/// Upstream paints it flat black. On macOS 26 and newer this can instead be
/// Apple's Liquid Glass — the same material the system uses for its own bars,
/// so it refracts whatever is behind the window instead of faking it with a
/// blur. Two rules keep the result usable:
///
/// 1. The closed pill (and the camera strip at the top of the open panel) stays
///    solid black, because the hardware cutout is there and a transparent
///    notch would show wallpaper through the camera housing.
/// 2. The glass never goes fully clear at the bottom — the panel's text is
///    white, so it always keeps a black wash the user can dial in.
struct NotchSurfaceBackground: View {
    /// The exact notch outline, so the glass follows the morph instead of
    /// sitting in a rounded rectangle behind it.
    let shape: NotchShape
    /// Glass only applies while the panel is open — the idle notch must look
    /// byte-for-byte like upstream.
    let isOpen: Bool
    /// Which display this surface belongs to. The adaptive scrim samples that
    /// display's wallpaper; without it every panel on a multi-monitor setup
    /// sampled whichever screen happened to have keyboard focus.
    var screenUUID: String? = nil
    /// Lower bound for the uniform black wash, supplied by the caller for a
    /// state that has to carry white type. A mirrored notification asks for
    /// Apple's clear-glass fallback (35% black); without it the white message
    /// vanishes over a bright window (docs/04 section I). 0 keeps the user's
    /// own transparency setting untouched for every other state.
    var minimumScrim: Double = 0
    /// Allow the material in the closed state as well. Only the floating
    /// island and the built-in-notch lyrics strip set this: a hardware-notch
    /// *plate* stays black so it fuses with the camera housing, while those
    /// two are separate objects with no cutout to blend into.
    var glassWhileClosed: Bool = false

    @Default(.enableLiquidGlass) private var enableLiquidGlass
    @Default(.liquidGlassClear) private var clearGlass
    @Default(.liquidGlassDarkness) private var darkness
    @Default(.glassOpacity) private var glassOpacity
    @Default(.glassRefraction) private var refraction
    @Default(.glassLensHeight) private var lensHeight
    @Default(.glassDispersion) private var dispersion
    @Default(.glassHighlight) private var highlight
    @Default(.glassFollowsAppleMetrics) private var followsAppleMetrics
    @Default(.glassAdaptiveScrim) private var adaptiveScrim
    @Default(.glassBackdropSampling) private var backdropSampling
    /// Luminance of the REAL content behind the island, refreshed ~1.4×/s.
    /// `nil` = sampling off / no Screen Recording permission / capture failed.
    @State private var backdropLuma: Double?
    @State private var didAcquireSampling = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var glassIsActive: Bool {
        enableLiquidGlass && (isOpen || glassWhileClosed) && !reduceTransparency
    }

    var body: some View {
        ZStack {
            base
            if glassIsActive {
                // Always draw it (0 opacity is free) so the notification's
                // 0 → 0.35 wash fades in/out instead of snapping when the
                // card appears and expires.
                scrim
                    .animation(.easeOut(duration: 0.2), value: scrimOpacity)
            }
            if showsDarkBackdropRim {
                rim
            }
        }
        // Insertion/removal of the rim needs the animation on the container:
        // `.animation` on the child alone does not drive a transition.
        .animation(.easeOut(duration: 0.25), value: showsDarkBackdropRim)
        .onAppear {
            GlassDefaultsMigration.run()
            GlassDiagnostics.log(tag: "probe", Self.probeSummary)
            setSampling(backdropSampling)
        }
        .onDisappear {
            setSampling(false)
        }
        .onChange(of: backdropSampling) { _, enabled in
            setSampling(enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bnBackdropLuminanceChanged)) { note in
            backdropLuma = (note.object as? NSNumber)?.doubleValue
        }
    }

    /// Idempotent: several panels can exist at once (one per display), and the
    /// sampler keeps a subscriber count rather than one loop per view.
    private func setSampling(_ enabled: Bool) {
        if enabled, !didAcquireSampling {
            didAcquireSampling = true
            BackdropLuminance.acquire()
        } else if !enabled, didAcquireSampling {
            didAcquireSampling = false
            backdropLuma = nil
            BackdropLuminance.release()
        }
    }

    /// Kept out of `body`: interpolating six class lookups inline in a
    /// ViewBuilder makes the type checker time out.
    private static var probeSummary: String {
        var parts: [String] = []
        parts.append("supported=\(LiquidGlassPipeline.isSupported)")
        parts.append("backdrop=\(NSClassFromString("CABackdropLayer") != nil)")
        parts.append("sdf=\(NSClassFromString("CASDFLayer") != nil)")
        parts.append("element=\(NSClassFromString("CASDFElementLayer") != nil)")
        parts.append("effect=\(NSClassFromString("CASDFOutputEffect") != nil)")
        parts.append("filter=\(NSClassFromString("CAFilter") != nil)")
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var base: some View {
        if glassIsActive {
            if LiquidGlassRefraction.isSupported {
                // The CoreAnimation refraction surface: a window-server backdrop
                // bent along the notch outline. This is the version that actually
                // reads as Liquid Glass — the public NSGlassEffectView only ever
                // renders the frosted material.
                LiquidGlassRefraction(
                    topRadius: shape.resolvedTopRadius,
                    bottomRadius: shape.resolvedBottomRadius,
                    sharpCorners: shape.usesSquircleCorners,
                    isCapsule: shape.isCapsule,
                    variant: clearGlass ? .clear : .regular,
                    followsAppleMetrics: followsAppleMetrics,
                    refraction: refraction,
                    lensHeight: lensHeight,
                    dispersion: dispersion,
                    highlight: highlight,
                    presence: glassOpacity,
                    animatesReveal: !reduceMotion,
                    backdropLuma: backdropSampling ? backdropLuma : nil
                )
                .allowsHitTesting(false)
            } else if #available(macOS 26.0, *) {
                SystemGlassSurface(
                    style: clearGlass ? .clear : .regular,
                    opacity: glassOpacity
                )
            } else {
                Color.black
            }
        } else {
            Color.black
        }
    }

    /// A uniform black wash, tied to the Transparency slider (0% = fully clear).
    /// It must stay uniform: any band that covers part of the panel makes the
    /// surface look like two materials stacked, which is exactly what the old
    /// menu-bar veil did.
    ///
    /// On top of the user's value this enforces Apple's *clear* gate: clear
    /// glass is only allowed over content it can read, and its documented
    /// fallback is a ~35% black darkening layer when the content behind is
    /// bright. The desktop wallpaper is the only backdrop we can measure
    /// without screen-recording permission, so it is the stand-in — and the
    /// whole rule can be switched off in settings, because the user has asked
    /// for maximum transparency more than once.
    private var scrimOpacity: Double {
        // Apple HIG, Materials: a clear Liquid Glass component needs a ~35%
        // dark dimming layer ONLY when the content beneath is bright; when that
        // content is sufficiently dark, no dimming layer is needed. The old
        // unconditional `minimumScrim` ignored the backdrop entirely and, on a
        // black window under the island, pressed the rim highlights down with
        // the rest of the plate — the "grey slab" reported 11-08 23:17.
        //
        // Prefer the real backdrop sample; fall back to the wallpaper proxy
        // only when sampling is unavailable (docs/04 C13 explains why the
        // wallpaper alone is not enough).
        let realLuma = backdropSampling ? backdropLuma : nil
        let wallpaperLuma = adaptiveScrim ? DesktopLuminance.average(for: screenUUID) : nil
        let luminance = realLuma ?? wallpaperLuma

        var value = darkness

        if let luminance {
            if luminance <= 0.22 {
                // Dark backdrop: no *automatic* dimming layer at all. White type
                // is already legible and the rim highlight must stay intact to
                // draw the glass edge. The user's own darkness dial is never
                // overridden — `value` stays exactly `darkness` here.
            } else {
                value = max(value, minimumScrim)
                if luminance > 0.62 {
                    value = max(value, 0.35)
                } else if luminance > 0.45 {
                    value = max(value, 0.18)
                }
            }
        } else {
            // No usable measurement: keep the old guaranteed floor so white
            // type on a bright window never becomes unreadable.
            value = max(value, minimumScrim)
        }

        // Apple's "Increase Contrast" makes the material materially more
        // opaque rather than merely recolouring it.
        if contrast == .increased {
            value = max(value, 0.28)
        }

        return min(max(value, 0), 0.85)
    }

    private var scrim: some View {
        Color.black.opacity(scrimOpacity)
            .clipShape(shape)
            // It is now drawn even at 0 opacity; a transparent background
            // layer must not swallow clicks meant for the panel's buttons.
            .allowsHitTesting(false)
    }

    /// Only a real backdrop sample can tell us the content behind is black —
    /// the wallpaper proxy is blind to a black window (docs/04 P3).
    private var sampledLuma: Double? {
        backdropSampling ? backdropLuma : nil
    }

    /// Draw the edge ourselves when clear glass sits on a dark backdrop.
    ///
    /// Clear glass reads as glass because it *bends* what is behind it. On a
    /// uniform black backdrop there is nothing to bend — refraction returns
    /// black, HIG says no dimming layer is needed, and the face layers are
    /// zeroed by the dark-backdrop branch below. Three layers all end up
    /// invisible, so the card disappears and only the white type is left
    /// (reported 11-09). Apple's own clear glass keeps a specular edge in this
    /// situation; that edge is what has to be drawn explicitly here, because no
    /// private filter input survives a zero-luminance backdrop.
    ///
    /// No `.blendMode` / `.shadow`: both force an offscreen pass, and a backdrop
    /// layer has no window server to sample in one (docs/04). A plain stroked
    /// gradient composites as a sibling layer and leaves the glass untouched.
    private var showsDarkBackdropRim: Bool {
        guard glassIsActive, clearGlass, !reduceTransparency else { return false }
        guard let luma = sampledLuma else { return false }
        return luma <= 0.22
    }

    private var rim: some View {
        shape
            .stroke(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.34), location: 0.0),
                        .init(color: .white.opacity(0.14), location: 0.55),
                        .init(color: .white.opacity(0.07), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: - Desktop luminance

/// Average luminance of the desktop picture, used as the stand-in for "what is
/// behind the glass" when screen capture is unavailable. Cheap (one 1×1
/// CoreImage reduction) and cached, because the wallpaper changes rarely.
@MainActor
enum DesktopLuminance {
    /// Cached per display UUID. A single global cache meant that on a
    /// multi-monitor setup every panel sampled the same wallpaper.
    private static var cachedValues: [String: Double] = [:]
    private static var cachedAt: Date?

    /// Luminance of the wallpaper belonging to `screenUUID`, or of the screen
    /// currently under the pointer when no UUID is known.
    static func average(for screenUUID: String? = nil) -> Double? {
        let key = screenUUID ?? ""
        if let value = cachedValues[key], let at = cachedAt, Date().timeIntervalSince(at) < 45 {
            return value
        }

        let screen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
            ?? NSScreen.main
            ?? NSScreen.menuBarScreen

        guard let screen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = CIImage(contentsOf: url),
              let filter = CIFilter(
                name: "CIAreaAverage",
                parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)]
              ),
              let output = filter.outputImage
        else { return cachedValues[key] }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Rec. 709 luma — the same weighting the glass tint uses.
        let luminance = (0.2126 * Double(pixel[0])
                         + 0.7152 * Double(pixel[1])
                         + 0.0722 * Double(pixel[2])) / 255

        cachedValues[key] = luminance
        cachedAt = Date()
        return luminance
    }
}

// MARK: - Luminance of what is ACTUALLY behind the glass

extension Notification.Name {
    static let bnBackdropLuminanceChanged = Notification.Name("bn.backdropLuminanceChanged")
}

/// Apple's clear material continuously reads the content behind it. The
/// wallpaper is not that content: a black window dragged under the island
/// leaves `DesktopLuminance` at 0.440 while the real backdrop is ~0, so the
/// 35% dimming layer stays on and the plate reads as a flat grey slab.
///
/// With Screen Recording granted, sample the real backdrop (excluding our own
/// windows) down to 192×108, ~1.4 times a second, and keep ONE number: the
/// average luminance of the top-centre strip where the island lives. No image
/// is stored, written to disk, or sent anywhere.
@MainActor
enum BackdropLuminance {
    static private(set) var current: Double?
    static private(set) var status: String = "off"

    private static var users = 0
    private static var loop: Task<Void, Never>?

    nonisolated static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The system prompt only appears once. Afterwards the user has to flip the
    /// switch in System Settings and relaunch the app (TCC takes effect at
    /// launch), which the settings UI explains.
    nonisolated static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    nonisolated static func acquire() {
        Task { @MainActor in
            users += 1
            start()
        }
    }

    nonisolated static func release() {
        Task { @MainActor in
            users = max(0, users - 1)
            if users == 0 { stop() }
        }
    }

    nonisolated static func refreshPermission() {
        Task { @MainActor in
            if hasPermission, loop == nil, users > 0 { start() }
        }
    }

    private static func start() {
        guard loop == nil else { return }
        guard hasPermission else {
            status = "no-permission"
            // An app only appears in System Settings → Screen Recording after
            // it has asked once. Ask exactly once per install so the user does
            // not have to hunt for the switch; the settings page has a manual
            // fallback if the first prompt was declined.
            let key = "bnScreenCapturePromptShown"
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: key) {
                defaults.set(true, forKey: key)
                _ = CGRequestScreenCaptureAccess()
            }
            return
        }
        status = "starting"
        loop = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let value = await capture()
                await MainActor.run {
                    // Exponential smoothing: a one-frame spike at the 0.22
                    // threshold must not make the material flip between "pure
                    // window" and "35% black" every 0.7s.
                    if let value {
                        let smoothed = current.map { $0 * 0.65 + value * 0.35 } ?? value
                        current = smoothed
                        status = String(format: "%.3f", smoothed)
                        NotificationCenter.default.post(
                            name: .bnBackdropLuminanceChanged,
                            object: NSNumber(value: smoothed)
                        )
                    } else {
                        status = "capture-failed"
                        // Keep the last good sample: one dropped frame must not
                        // snap the plate back to the grey fallback.
                    }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private static func stop() {
        loop?.cancel()
        loop = nil
        current = nil
        status = "off"
        NotificationCenter.default.post(name: .bnBackdropLuminanceChanged, object: nil)
    }

    nonisolated private static func capture() async -> Double? {
        guard #available(macOS 14.0, *) else { return nil }
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else { return nil }
            let own = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            // Excluding OUR windows is what makes the sample show the content
            // behind the island rather than the island's own grey plate.
            let filter = SCContentFilter(display: display,
                                         excludingApplications: own,
                                         exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 192
            config.height = 108
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            let sample = try await SCScreenshotManager.captureSampleBuffer(
                contentFilter: filter, configuration: config
            )
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return nil }
            let image = CIImage(cvPixelBuffer: pixels)
            let w = image.extent.width, h = image.extent.height
            // CIImage's origin is bottom-left; the island sits in the TOP
            // centre. 40% × 20% covers the 408–640pt plate on both displays.
            let region = CGRect(x: w * 0.30, y: h * 0.80,
                                width: w * 0.40, height: h * 0.20)
            guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: region)
            ])?.outputImage else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(avg, toBitmap: &px, rowBytes: 4,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1])
                    + 0.0722 * Double(px[2])) / 255
        } catch {
            return nil
        }
    }
}

// MARK: - One-time defaults migration

/// The glass parameters were replaced by Apple's measured recipe; values still
/// sitting on the old factory defaults were never touched by anyone, so they
/// get moved onto the new ones. A value the user actually changed is left
/// alone.
enum GlassDefaultsMigration {
    private static let flag = "glassAppleRecipeApplied"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }

        if Defaults[.glassHighlight] == 0.1 { Defaults[.glassHighlight] = 0.4 }
        if Defaults[.glassDispersion] == 3 { Defaults[.glassDispersion] = 0 }
        if Defaults[.glassOpacity] == 0.6 { Defaults[.glassOpacity] = 1.0 }

        defaults.set(true, forKey: flag)
    }
}

// MARK: - System glass

/// Thin wrapper around Apple's own glass view. The shape is applied by the
/// caller's `clipShape`, so the glass itself is a plain rect and the notch
/// outline does the masking.
@available(macOS 26.0, *)
struct SystemGlassSurface: NSViewRepresentable {
    let style: NSGlassEffectView.Style
    /// Overall presence of the glass. Below 1 the desktop shows through the
    /// material itself, which is the only way to get "clearer than clear" with
    /// the public API.
    let opacity: Double

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = style
        view.cornerRadius = 0
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.style = style
        view.alphaValue = opacity
    }
}

// MARK: - Diagnostics

/// One-shot probe written to disk: unified logging from an ad-hoc signed build
/// is not reliable enough to tell us whether the private pipeline was taken.
enum GlassDiagnostics {
    static func log(tag: String, _ message: String) {
        let path = NSHomeDirectory() + "/bn-glass-\(tag).log"
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? ("[BNGLASS \(tag)] " + message + "\n").write(
            to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8
        )
        NSLog("[BNGLASS %@] %@", tag, message)
    }

    /// Overwritten on every launch, so it always describes the build that is
    /// running now. This is the only way to prove which numbers the material
    /// actually received — the filter is private API and there is no other
    /// read-back path once the app is installed.
    static func record(_ message: String) {
        let path = NSHomeDirectory() + "/bn-glass-applied.log"
        try? (message + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        NSLog("[BNGLASS applied] %@", message)
    }

    /// Overwritten whenever the measured backdrop changes bucket. This is the
    /// only way to prove the Screen Recording sample reached the material —
    /// `bn-glass-applied.log` is written once at launch, before the first frame.
    static func recordLuma(_ value: String) {
        let path = NSHomeDirectory() + "/bn-glass-luma.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? ("\(stamp) backdropLuma=\(value)\n").write(
            to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8
        )
    }
}

// MARK: - Real Liquid Glass (CoreAnimation refraction)

/// Availability probe for the private glass pipeline. Every symbol is checked
/// once; the rest of the file only asks a Bool.
enum LiquidGlassPipeline {
    static let isSupported: Bool = {
        guard #available(macOS 26.0, *) else { return false }
        guard NSClassFromString("CABackdropLayer") != nil,
              NSClassFromString("CASDFLayer") != nil,
              NSClassFromString("CASDFElementLayer") != nil,
              NSClassFromString("CASDFOutputEffect") != nil
        else { return false }
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject as? NSObjectProtocol,
              filterClass.perform(NSSelectorFromString("filterWithType:"), with: "glassBackground") != nil
        else { return false }
        return true
    }()
}

private typealias SetDoubleIMP = @convention(c) (AnyObject, Selector, Double) -> Void
private typealias SetObjectIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

/// The material itself: a `CABackdropLayer` that samples the desktop behind the
/// window, bent along the notch's perimeter by the `glassBackground` filter.
/// `blur` stays at zero on purpose — blur is what makes a surface look frosted;
/// the lens is supposed to bend light, not smear it.
final class LiquidGlassSurfaceView: NSView {
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = 19
    var sharpCorners: Bool = true
    /// Closed island pill: the SDF radius follows the real height.
    var isCapsule: Bool = false

    var variant: GlassVariant = .clear
    /// `true` = take refraction and lens depth from Apple's size curve.
    var followsAppleMetrics: Bool = true
    /// Manual override, in points of displacement. Apple's own glass is −60 at
    /// this panel size; 30+ on a small element turns the lip into a fisheye.
    var manualRefraction: Double = 60
    /// How far that bend reaches inward, when the manual override is on.
    var manualLensHeight: Double = 20
    /// Chromatic split along the rim. Apple's own glass has none — dispersion is
    /// a tutorial embellishment, kept here as a dial, defaulted off.
    var dispersion: Double = 0
    /// Specular highlight on the rim. 0.4 is Apple's clear value.
    var highlight: Double = 0.4
    /// 0…1 — how much of Apple's face tint the material carries.
    var presence: Double = 1
    /// Apple's material "develops" (the bend ramps up) instead of fading in.
    var animatesReveal: Bool = true
    /// Luminance of the real content behind the glass. `nil` = unknown, in
    /// which case the material keeps its static Apple-clear recipe.
    var backdropLuma: Double?

    private var backdrop: CALayer?
    private var sdfLayer: CALayer?
    private var sdfElement: CALayer?

    private var reveal: Double = 1
    private var revealStart: CFTimeInterval = 0
    private var revealTimer: Timer?
    private var lastHeight: CGFloat = 0
    private var didRecordApplied = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setup()
        startReveal()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        revealTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        updateGeometry()

        // Thickness follows size in Apple's material, so a panel that is still
        // growing during the open animation needs its lens rebuilt as it grows.
        if abs(bounds.height - lastHeight) > 0.5 {
            lastHeight = bounds.height
            rebuild()
        }
    }

    // MARK: Material development

    /// Apple's glass does not fade in — the amount of bending ramps from 0 to 1
    /// while the shape is already there. Fading opacity instead is what makes a
    /// replica look like a pasted plate.
    private func startReveal() {
        guard animatesReveal else {
            reveal = 1
            return
        }

        reveal = 0
        revealStart = CACurrentMediaTime()
        revealTimer?.invalidate()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let progress = min(1.0, (CACurrentMediaTime() - self.revealStart) / 0.26)
                let eased = 1 - pow(1 - progress, 3)
                self.reveal = eased
                self.rebuild()
                if progress >= 1 {
                    timer.invalidate()
                    self.revealTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// Skips the ramp — used when Reduce Motion is on, and when the view is
    /// rebuilt with animation switched off after it has already started.
    func finishReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        reveal = 1
        rebuild()
    }

    // MARK: Parameters

    private var parameters: GlassParameters {
        var p = GlassParameters(variant: variant, height: bounds.height)

        if !followsAppleMetrics {
            p.innerRefraction = -manualRefraction
            p.innerRefractionHeight = manualLensHeight
        }

        p.highlight = highlight
        p.dispersion = dispersion

        // On a near-black backdrop there is nothing for the lens to bend, so
        // Apple's depth cues have to come from the material's own surface.
        // A lifted black point and a white face veil would instead lay a flat
        // grey sheet over the black: keep the centre a pure window and let the
        // specular rim define the object (WWDC25 219, "Adaptivity").
        if variant == .clear, let luma = backdropLuma, luma <= 0.22 {
            p.faceBlack = 0
            p.faceFillAlpha = 0
            p.shadowFillAlpha = 0
            p.highlight = min(p.highlight * 1.25, 0.8)
        }

        p.applyPresence(presence)
        return p
    }

    // MARK: Layer construction

    private func setup() {
        guard let root = layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }

        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let sdfLayerClass = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let sdfElementClass = NSClassFromString("CASDFElementLayer") as? CALayer.Type,
              let sdfEffectClass = NSClassFromString("CASDFOutputEffect") as? NSObject.Type
        else { return }

        let backdropInstance = backdropClass.init()
        backdropInstance.frame = bounds
        backdropInstance.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // `tracksLuma` is the vibrancy switch, and it is what made the plate
        // read as "a bit dark" instead of clear: with luma tracking on, the
        // window server hands the material a *luminance-matched* copy of what
        // is behind it, so a bright wallpaper arrives dimmed and a dark one
        // arrives lifted. Apple's own glass runs with it OFF — dumping a live
        // `NSGlassEffectView(.clear)` shows tracksLuma = 0, tracksLumaWhileHidden
        // = 0, while `allowsFilteredLuma` stays 1.
        backdropInstance.setValue(false, forKey: "tracksLuma")
        backdropInstance.setValue(false, forKey: "tracksLumaWhileHidden")
        backdropInstance.setValue(true, forKey: "allowsFilteredLuma")
        backdropInstance.setValue(true, forKey: "windowServerAware")
        // Same sampling margin AppKit puts on its own backdrop. Deliberately
        // *not* copying `sourceSublayerDefinesBounds`: our SDF element is
        // taller than the view on purpose (the top rounding is bled off-screen),
        // and letting it define the backdrop's bounds would stretch the sampled
        // region with it.
        backdropInstance.setValue(0.5, forKey: "marginWidth")
        backdropInstance.allowsGroupOpacity = false

        // Turns the distance field into the normals the refraction filter bends
        // the sampled image along.
        let effect = sdfEffectClass.init()
        let selMin = NSSelectorFromString("setMinimum:")
        let selMax = NSSelectorFromString("setMaximum:")
        if let methodMin = class_getInstanceMethod(sdfEffectClass, selMin),
           let methodMax = class_getInstanceMethod(sdfEffectClass, selMax) {
            let impMin = unsafeBitCast(method_getImplementation(methodMin), to: SetDoubleIMP.self)
            let impMax = unsafeBitCast(method_getImplementation(methodMax), to: SetDoubleIMP.self)
            impMin(effect, selMin, -1000.0)
            impMax(effect, selMax, 1.0)
        }

        let sdfLayerInstance = sdfLayerClass.init()
        sdfLayerInstance.name = "@0"
        sdfLayerInstance.frame = bounds
        sdfLayerInstance.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        if let methodEffect = class_getInstanceMethod(sdfLayerClass, NSSelectorFromString("setEffect:")) {
            let imp = unsafeBitCast(method_getImplementation(methodEffect), to: SetObjectIMP.self)
            imp(sdfLayerInstance, NSSelectorFromString("setEffect:"), effect)
        }
        if let methodSmooth = class_getInstanceMethod(sdfLayerClass, NSSelectorFromString("setSmoothness:")) {
            let imp = unsafeBitCast(method_getImplementation(methodSmooth), to: SetDoubleIMP.self)
            // 8 is what AppKit uses on its own glass (measured). A high value
            // widens the falloff until the bend reaches well inside the panel
            // and the rim turns into a soft dark band instead of a crisp lip.
            imp(sdfLayerInstance, NSSelectorFromString("setSmoothness:"), 8.0)
        }

        let sdfElementInstance = sdfElementClass.init()
        sdfLayerInstance.sublayers = [sdfElementInstance]

        backdropInstance.sublayers = [sdfLayerInstance]
        root.addSublayer(backdropInstance)

        self.backdrop = backdropInstance
        self.sdfLayer = sdfLayerInstance
        self.sdfElement = sdfElementInstance

        updateGeometry()
        rebuild()
    }

    func updateGeometry() {
        guard let backdrop, let sdfLayer, let sdfElement else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        sdfLayer.frame = bounds

        // Two different panels share this view, and the SDF element must be
        // laid out differently for each:
        //
        //  · Edge-anchored plate (topRadius == 0): the top edge butts against
        //    the bezel, so CALayer's all-four corner rounding has to be bled
        //    off the top of the visible area, leaving only the bottom corners.
        //  · Floating island card (topRadius > 0): all four corners are meant
        //    to be visible. The OLD `inset = sharpCorners ? topRadius : 0`
        //    shrank the element by topRadius on each side under the assumption
        //    that the top rounding would fall off-screen. With a 22pt top
        //    radius that carved 22pt of *uncoated* backdrop off both sides —
        //    the two dark strips that made the card look like two plates glued
        //    together (user screenshots 17:23 / 17:33; pixel analysis measured
        //    ~21px strips at x=120..141 and x=618..639).
        //
        // A floating card therefore gets the full bounds, no bleed, and four
        // rounded corners: one continuous piece of glass, edge to edge.
        let floatingPanel = isCapsule || topRadius > 0
        let inset: CGFloat = floatingPanel ? 0 : (sharpCorners ? topRadius : 0)
        let width = max(bounds.width - inset * 2, 0)
        let bleed: CGFloat = floatingPanel ? 0 : (bottomRadius + 4)
        // A capsule's radius is half the real plate height, not the nominal
        // value the shape carries: the plate grows for music / HUD, and a
        // fixed 12pt radius would leave a straight waist inside the lens even
        // though the clip outline is a perfect pill.
        //
        // A continuous-corner card is capped by height EXACTLY the way
        // `path(in:)` caps the clip outline. Without this the two curves
        // diverge at the corners: CALayer does clamp an oversized radius on
        // its own, but with a different rule. Measured on 300×56 with r = 36,
        // the clip squeezes to 42.8×28 while CALayer shrinks to ~31×20 — an
        // 11pt mismatch right where the glass lip is supposed to sit, which
        // reads as a strip of un-lensed surface inside each corner.
        let fittedCornerRadius: CGFloat
        if isCapsule {
            fittedCornerRadius = bounds.height / 2
        } else if floatingPanel {
            fittedCornerRadius = min(topRadius, bounds.height * NotchShape.cornerHeightRatio)
        } else {
            fittedCornerRadius = bottomRadius
        }
        sdfElement.frame = CGRect(x: inset, y: 0, width: width, height: bounds.height + bleed)
        sdfElement.cornerRadius = fittedCornerRadius
        // The corner *style* has to match the clip shape, not just the radius.
        // `NotchShape` draws continuous (squircle) corners whenever the glass is
        // on, while CALayer falls back to a plain circular arc. Both agree along
        // the straight edges and diverge at the 45° point — at these radii that
        // is a ~2pt sliver, and it sits *inside* the panel outline, so the
        // clipShape cannot hide it. What it looked like: a black crescent
        // tucked under each bottom corner, with the distance field's normals
        // piling into a bright arc right beside it.
        //
        // Apple's own glass element carries exactly this pair of properties
        // (r = corner radius, curve = .continuous).
        sdfElement.cornerCurve = (sharpCorners && !isCapsule) ? CALayerCornerCurve.continuous : CALayerCornerCurve.circular
        sdfElement.setValue("bounds", forKey: "mode")
        sdfElement.setValue("union", forKey: "operation")

        backdrop.setNeedsDisplay()
        sdfLayer.setNeedsDisplay()
        CATransaction.commit()
    }

    func rebuild() {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject as? NSObjectProtocol,
              let backdrop else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let rawFilter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")?
            .takeUnretainedValue() as? NSObject else { return }
        let filter = rawFilter

        let p = parameters
        let ramp = reveal

        filter.setValue("glassBackground", forKey: "name")
        filter.setValue("@0", forKey: "inputSourceSublayerName")

        // 1. The lens. Negative bends the sampled image inward, which is what
        //    reads as a convex glass lip. Depth and reach come from Apple's
        //    size curve, so a taller panel gets a deeper slab.
        filter.setValue(p.innerRefraction * ramp, forKey: "inputInnerRefractionAmount")
        filter.setValue(p.innerRefractionHeight, forKey: "inputInnerRefractionHeight")
        // Apple's clear glass does *not* flare light back out of the rim; the
        // outer pass stays at zero. The "翻卷" in the tutorial is what Apple
        // gets for free from the two-layer bend, not from an extra parameter.
        filter.setValue(0.0, forKey: "inputOuterRefractionAmount")
        filter.setValue(0.0, forKey: "inputOuterRefractionHeight")
        filter.setValue(-1.0, forKey: "inputRefractionDistance0")
        filter.setValue(0.0, forKey: "inputRefractionDistance1")
        // 0, not 1: the flat centre must stay a pure window onto the desktop.
        filter.setValue(p.refractionOpacity, forKey: "inputRefractionOpacity")

        // 2. Blur. Clear pins the radius at zero so nothing can reintroduce a
        //    frost; regular uses Apple's own edge blur plus the fill pass that
        //    lightens the material from behind.
        filter.setValue(p.blurRadius, forKey: "inputBlurRadius")
        filter.setValue(p.blurFillRadius, forKey: "inputBlurFillBlurRadius")
        filter.setValue(p.blurEdgeOpacity, forKey: "inputBlurOpacity0")
        filter.setValue(p.blurEdgeOpacity, forKey: "inputBlurOpacity1")
        filter.setValue(p.blurRadius > 0 ? 1.0 : 0.0, forKey: "inputBlurOpacity2")
        filter.setValue(p.blurRadius > 0 ? 1.0 : 0.0, forKey: "inputBlurOpacity3")
        filter.setValue(p.blurFillNormal, forKey: "inputBlurFillNormalOpacity")
        filter.setValue(p.blurFillDarken, forKey: "inputBlurFillDarkenOpacity")
        filter.setValue(p.blurFillLighten, forKey: "inputBlurFillLightenOpacity")
        filter.setValue(0.0, forKey: "inputBlurDistance0")
        filter.setValue(0.0, forKey: "inputBlurDistance1")
        filter.setValue(0.0, forKey: "inputBlurDistance2")
        filter.setValue(0.0, forKey: "inputBlurDistance3")

        // 3. Chromatic dispersion along the rim. Off by default — Apple's own
        //    glass carries no rainbow edge at all.
        filter.setValue(p.dispersion, forKey: "inputAberrationAmount")
        filter.setValue(p.dispersion > 0 ? p.innerRefractionHeight : 0.0, forKey: "inputAberrationHeight")
        filter.setValue(0.0, forKey: "inputAberrationOffset")
        filter.setValue(0.0, forKey: "inputAberrationAngle")

        // 4. The face: how much the slab tints what passes through it. This is
        //    the layer that was missing entirely — without it the panel is a
        //    perfect window, which is *clearer* than Apple's clear and reads as
        //    "empty" rather than "glass".
        filter.setValue(1.0, forKey: "inputFaceOpacity")
        filter.setValue(p.faceWhite, forKey: "inputFaceColorMatrixWhite")
        filter.setValue(p.faceBlack, forKey: "inputFaceColorMatrixBlack")
        filter.setValue(p.faceSaturation, forKey: "inputFaceColorMatrixSaturation")
        filter.setValue(1.0, forKey: "inputFaceColorMatrixMaxLuma")
        filter.setValue(p.faceMaxLumaSDR, forKey: "inputFaceColorMatrixMaxLumaSDR")
        filter.setValue(
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: p.faceFillAlpha),
            forKey: "inputFaceColorMatrixFillColor"
        )

        // 5. The shadow layer. Apple's clear glass carries a real one (amount
        //    75, height 0.4 × the element, offset 8pt down) — it is what lifts
        //    the panel off the desktop. Ours was pinned to zero, and the SwiftUI
        //    `.shadow` that used to stand in for it cannot work here: it forces
        //    an offscreen pass, and a backdrop layer has no window server to
        //    sample in that pass.
        filter.setValue(p.shadowAmount * ramp, forKey: "inputShadowAmount")
        filter.setValue(p.shadowHeight, forKey: "inputShadowHeight")
        filter.setValue(
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: p.shadowFillAlpha),
            forKey: "inputShadowColorMatrixFillColor"
        )
        filter.setValue(0.0, forKey: "inputShadowOpacity")
        filter.setValue(0.0, forKey: "inputShadowRadius")
        filter.setValue(0.0, forKey: "inputShadowBlurRadius")
        filter.setValue(0.0, forKey: "inputShadowDistanceOffset")
        filter.setValue(0.0, forKey: "inputShadowVibrancyContribution")
        filter.setValue(1.0, forKey: "inputShadowColorMatrixWhite")
        filter.setValue(0.0, forKey: "inputShadowColorMatrixBlack")
        filter.setValue(1.2, forKey: "inputShadowColorMatrixSaturation")
        filter.setValue(NSValue(size: NSSize(width: 0, height: 8)), forKey: "inputShadowOffset")

        // 6. Bleed and ring shadow belong to the frosted variant only.
        filter.setValue(p.bleedAmount, forKey: "inputBleedAmount")
        filter.setValue(0.0, forKey: "inputBleedOpacity")
        filter.setValue(p.bleedAmount, forKey: "inputBleedHeight")
        filter.setValue(0.0, forKey: "inputBleedBlurRadius")
        filter.setValue(p.ringMask, forKey: "inputRingShadowMask")
        filter.setValue(p.ringStroke, forKey: "inputRingShadowStrokeWidth")
        filter.setValue(p.ringOffset, forKey: "inputRingShadowOffset")
        filter.setValue(p.ringBlur, forKey: "inputRingShadowBlurRadius")
        filter.setValue(0.0, forKey: "inputRingShadowOpacity")

        // 7. Specular. The direction and spread are not optional: with only the
        //    amount set the highlight has no light source, wraps the whole rim
        //    and piles up at the corners.
        filter.setValue(p.highlight * ramp, forKey: "inputKeyFillHighlightAmount")
        filter.setValue(Double.pi / 2, forKey: "inputKeyFillHighlightAngle")
        filter.setValue(0.5, forKey: "inputKeyFillHighlightHeight")
        filter.setValue(p.highlightSpread, forKey: "inputKeyFillHighlightSpread")
        filter.setValue(p.highlightSpread, forKey: "inputKeyFillHighlightSpreadSDR")
        filter.setValue(p.highlightColorBias, forKey: "inputKeyFillHighlightColorBias")
        filter.setValue(-0.5, forKey: "inputKeyFillHighlightEffectOffset")

        // 8. Tone mapping. Apple clamps the sample at 1.2× headroom so an HDR
        //    wallpaper cannot blow the face out; on an SDR desktop this is a
        //    no-op, which is why it is safe to carry over.
        filter.setValue(1.0, forKey: "inputClamp")
        filter.setValue(false, forKey: "inputClampPreserveHue")
        filter.setValue(1.2, forKey: "inputMaxHeadroom")
        filter.setValue(1.0, forKey: "inputSDRGradientDistance0")
        filter.setValue(1.0, forKey: "inputSDRGradientDistance1")
        filter.setValue(false, forKey: "inputSDRHoldingToneEnabled")
        filter.setValue(1.0, forKey: "inputSDRHoldingToneWhite")
        filter.setValue(0.0, forKey: "inputSDRShadowOpacity")

        backdrop.filters = [filter]
        backdrop.setNeedsDisplay()
    }

    /// Called by the SwiftUI wrapper *after* the new values are in place. It
    /// must not live in `rebuild()`: `init` rebuilds once before the wrapper
    /// has applied anything, and that first pass would report the struct's
    /// defaults instead of what the user actually set.
    func recordAppliedOnce() {
        guard !didRecordApplied else { return }
        didRecordApplied = true
        let p = parameters
        GlassDiagnostics.record(
            "height=\(Int(bounds.height)) variant=\(variant == .clear ? "clear" : "regular")"
            + " appleMetrics=\(followsAppleMetrics)"
            + " refraction=\(p.innerRefraction) lens=\(p.innerRefractionHeight)"
            + " shadow=\(p.shadowAmount)/\(p.shadowHeight)/\(p.shadowFillAlpha) highlight=\(p.highlight)"
            + " presence=\(presence) dispersion=\(p.dispersion)"
            + " backdropLuma=\(backdropLuma.map { String(format: "%.3f", $0) } ?? "nil")"
            + " faceWhite=\(p.faceWhite) faceBlack=\(p.faceBlack) faceFill=\(p.faceFillAlpha)"
            // The scrim is the only layer that can shove a big black wash over
            // the whole plate; without the backdrop luminance in the log there
            // is no way to tell "the glass is grey" from "something dimmed it".
            + " deskLuma=\(DesktopLuminance.average().map { String(format: "%.3f", $0) } ?? "nil")"
        )
    }
}

struct LiquidGlassRefraction: NSViewRepresentable {
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let sharpCorners: Bool
    /// True for the closed island pill: radius = bounds.height / 2.
    let isCapsule: Bool
    let variant: GlassVariant
    let followsAppleMetrics: Bool
    let refraction: Double
    let lensHeight: Double
    let dispersion: Double
    let highlight: Double
    let presence: Double
    let animatesReveal: Bool
    let backdropLuma: Double?

    static var isSupported: Bool { LiquidGlassPipeline.isSupported }

    func makeNSView(context: Context) -> LiquidGlassSurfaceView {
        GlassDiagnostics.log(tag: "make", "makeNSView refraction=\(refraction) lens=\(lensHeight)")
        let view = LiquidGlassSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 195))
        apply(to: view)
        view.rebuild()
        return view
    }

    func updateNSView(_ nsView: LiquidGlassSurfaceView, context: Context) {
        apply(to: nsView)
        nsView.updateGeometry()
        nsView.rebuild()
    }

    private func apply(to view: LiquidGlassSurfaceView) {
        view.topRadius = topRadius
        view.bottomRadius = bottomRadius
        view.sharpCorners = sharpCorners
        view.isCapsule = isCapsule
        view.variant = variant
        view.followsAppleMetrics = followsAppleMetrics
        view.manualRefraction = refraction
        view.manualLensHeight = lensHeight
        view.dispersion = dispersion
        view.highlight = highlight
        view.presence = presence
        view.animatesReveal = animatesReveal
        if view.backdropLuma != backdropLuma {
            view.backdropLuma = backdropLuma
            GlassDiagnostics.recordLuma(
                backdropLuma.map { String(format: "%.3f", $0) } ?? "nil"
            )
        }
        if !animatesReveal { view.finishReveal() }
        view.recordAppliedOnce()
    }
}
