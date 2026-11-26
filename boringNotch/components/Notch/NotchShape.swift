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
    ///
    /// 🔴 20:19 clamp lowered 75 → 30, user-rejected as-is: Apple's 75 was
    /// dumped from a panel that sits ON the screen top edge, where the upper
    /// half of the shadow band is off-screen. Our floating-island cards are
    /// drawn INSIDE the 640×210 artboard (y≈38+), so the whole ring is
    /// visible and reads as "一大圈黑色阴影" (user, 20:19). Narrowing the
    /// spread to 30 keeps a contact shadow under the bottom edge and lets
    /// the lens carry the depth instead. Do not "restore the measured value"
    /// without re-checking the geometry of the surface it is applied to.
    static func shadowAmount(height: CGFloat) -> Double {
        min(0.625 * Double(height), 30)
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

    // MARK: The drop shadow's four remaining dials (P2)
    //
    // `inputShadowAmount` / `inputShadowHeight` only shape *where* the cast
    // shadow band sits; the five inputs below are the ones that give it
    // density, softness and direction. They were pinned to 0.0 in `rebuild()`,
    // which is why the plate had a shadow geometry and no shadow: the band was
    // there, fully transparent. Apple's clear glass carries all five live.
    /// Peak alpha of the cast shadow.
    /// 🔴 20:48: 0.16 → 0.10. Third strike on the outline ring: after the
    /// spread was narrowed (75→30) the band still read as a dark rim on the
    /// floating cards over a light wallpaper. The lens and the specular lip
    /// carry the depth; the cast band stays only as a faint contact cue.
    static let shadowOpacity: Double = 0.10
    /// Geometric spread of the shadow band, in points.
    /// 🔴 20:19: 18 → 12 alongside the shadowAmount clamp 75 → 30 — the wide
    /// spread plus the full visible ring read as a dark outline on floating
    /// cards; a narrower band under the bottom edge reads as a cast shadow.
    static let shadowRadius: Double = 12
    /// Softness of the band's outer falloff, in points.
    static let shadowBlurRadius: Double = 16
    /// Vertical travel, in points. Positive = downward (y grows down).
    static let shadowDistanceOffset: Double = 4
    /// How much desktop colour bleeds into the shadow, 0…1.
    static let shadowVibrancyContribution: Double = 0.15

    /// How much of the lens is actually visible, 0…1.
    ///
    /// Apple leaves `inputRefractionOpacity` at 0 for a plain `NSGlassEffectView`
    /// and turns it on for the interactive/`clear` presentations; at 0 the layer
    /// still samples the desktop but the bend is multiplied away, so the panel
    /// keeps the dimensions of a glass slab with none of the depth cues. 0.55 is
    /// the point where the rim picks up a readable highlight/shadow pair without
    /// the centre band picking up a tint, and it is the only value P1 changes.
    static let refractionOpacity: Double = 0.55
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
    // The cast shadow's density / softness / travel. Zero on the frosted
    // variant, which swaps the shadow layer for the bleed layer.
    var shadowOpacity: Double = 0
    var shadowRadius: Double = 0
    var shadowBlurRadius: Double = 0
    var shadowDistanceOffset: Double = 0
    var shadowVibrancyContribution: Double = 0

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
            // Without these five the band above is a shape with nothing in it
            // — `inputShadowOpacity == 0` multiplies the whole layer away.
            shadowOpacity = GlassMetrics.shadowOpacity
            shadowRadius = GlassMetrics.shadowRadius
            shadowBlurRadius = GlassMetrics.shadowBlurRadius
            shadowDistanceOffset = GlassMetrics.shadowDistanceOffset
            shadowVibrancyContribution = GlassMetrics.shadowVibrancyContribution

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

        // The cast shadow belongs to the same material, so the same dial owns
        // it: at presence 0 there is no slab, hence nothing to cast one.
        // Density, travel and vibrancy follow the dial linearly (they are what
        // "how much glass" means); radius and blur only travel a third of the
        // way, because a shadow that loses all of its spread degrades into a
        // hard 1pt outline — a border, not a shadow.
        let reach = 0.6 + 0.4 * p
        shadowOpacity *= p
        shadowDistanceOffset *= p
        shadowVibrancyContribution *= p
        shadowRadius *= reach
        shadowBlurRadius *= reach
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
    /// Content flex: `true` while something is up on this surface (open
    /// panel, a peeking card). The material then reads thicker — deeper cast
    /// shadow, hotter specular — and relaxes when the content dismisses
    /// (WWDC25 219 "Adaptivity": morphing larger simulates a thicker slab).
    var flexed: Bool = false
    /// 内容层材质（11-18 用户拍板「稍微 regular 一点」）。
    ///
    /// HIG › Materials 明确要求：内容层不要用 Liquid Glass；承载大量文字的
    /// 组件（alert、侧栏、popover）该用 regular 变体，因为 regular 会模糊并
    /// 调整背景亮度以保证可读性。通知卡与音乐卡恰恰是"内容 + 大量文字"。
    ///
    /// 完全换成 regular 会丢掉用户调了两周的 clear 透镜观感，所以这里取中间
    /// 态：透镜（折射/高光/边缘）保持 clear 不变，只补上 regular 的可读性
    /// 手段——轻微模糊 + 抬高的黑位 + 多一点面层填充。配合把 35% 黑遮罩降
    /// 到 0.16，文字不需要再靠两层投影硬撑。
    var contentLifted: Bool = false

    @Default(.enableLiquidGlass) private var enableLiquidGlass
    @Default(.liquidGlassClear) private var clearGlass
    @Default(.liquidGlassDarkness) private var darkness
    @Default(.glassOpacity) private var glassOpacity
    @Default(.glassRefraction) private var refraction
    @Default(.glassLensHeight) private var lensHeight
    @Default(.glassDispersion) private var dispersion
    @Default(.glassHighlight) private var highlight
    @Default(.glassFollowsAppleMetrics) private var followsAppleMetrics
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
                if clearGlass, !reduceTransparency {
                    // WWDC25 219 "Principles": highlights and shadow are
                    // separate layers of the material, not a dimming veil.
                    // The stack stays in the tree so its strength can ramp
                    // continuously with the sampled backdrop; at strength 0
                    // it is fully transparent and the approved bright-backdrop
                    // look is untouched.
                    glassSurfaceHighlights
                        // Low-frequency easing only: the light angle and the
                        // rim width are the only values that move, and both
                        // are quantised upstream. No blend mode, no shadow,
                        // no mask — those render offscreen and black out the
                        // private glass layer underneath.
                        .animation(.easeOut(duration: 0.42), value: specularAngleForLayer)
                        .animation(.easeOut(duration: 0.42), value: specularLineWidth)
                        .animation(.easeOut(duration: 0.42), value: specularStrength)
                }
            }
            // Size probe: background child, zero visual footprint, no effect
            // on the surface's own geometry.
            Color.clear
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { surfaceSize = proxy.size }
                            .onChange(of: proxy.size) { _, size in surfaceSize = size }
                    }
                )
                .allowsHitTesting(false)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard clearGlass, !reduceMotion else { return }
            switch phase {
            case .active(let point):
                setPointerLight(at: point)
            case .ended:
                if pointerLightAngle != nil { pointerLightAngle = nil }
            }
        }
        .onAppear {
            GlassDefaultsMigration.run()
            GlassDiagnostics.log(tag: "probe", Self.probeSummary)
            GlassDiagnostics.forceNextSurface()
            GlassDiagnostics.timeline(
                "mount",
                "isOpen=\(isOpen) glassWhileClosed=\(glassWhileClosed)"
                + " active=\(glassIsActive) clear=\(clearGlass)"
                + " minScrim=" + String(format: "%.3f", minimumScrim)
                + " lifted=\(contentLifted)"
            )
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
                    contentLifted: contentLifted,
                    flexed: flexed
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
    /// Uniform black wash over the plate. 11-17: reduced to the user's own
    /// transparency dial (+ the system's Increase-Contrast floor). The previous
    /// automatic luma-driven gate sampled the top-centre 40%×20% strip, which
    /// includes the menu bar and a window's white title border — a thin white
    /// edge pushed the average past 0.62 and switched the whole card to 35%
    /// black. That switch is gone; see the note inside.
    private var scrimOpacity: Double {
        // 🔴 11-17 用户拍板「直接去掉」自动黑遮罩。
        // 旧的 luma 驱动逻辑读「顶部中央 40%×20%」这条大采样窗，覆盖菜单栏和
        // 窗口白色标题栏：一条白边把 CIAreaAverage 均值拉过 0.62 → 触发 0.35
        // 硬闸，把整块卡片开关式盖黑（用户两张对比图实证：白边在→黑底，
        // 白边没→正常）。这是误判，不是可读性问题。现在遮罩只认用户透明度
        // dial；采样亮度仍驱动边缘高光（darkBackdropStrength / rimStrength），
        // 但不再碰中心遮罩。
        var value = darkness

        // 11-17：整段 luma 驱动的自适应遮罩已移除。白边误触发见上方说明。
        // 现在只有用户自己的透明度 dial（darkness）与系统的增加对比度
        // 能加遮罩；采样值继续只服务边缘高光/折射。

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

    // 20:56: `sampledLuma`（受闸门的采样）随最后两条 luma 分支一起删掉了。
    // 11-18：连采样管线本身也整体移除 —— 它已经不参与任何渲染，却仍在
    // 2.5 次/秒截屏并索要「屏幕录制」权限（详见 docs/02 的 11-18 条目）。

    /// 0…1 strength of the dark-backdrop **edge** treatment. The centre is
    /// never touched — see `glassSurfaceHighlights`.
    ///
    /// WWDC25 219 (13:13): *clear* Liquid Glass "does not have adaptive
    /// behaviors" — it stays permanently transparent and belongs only over
    /// media-rich backgrounds. Apple's own answer to a flat dark backdrop is
    /// the regular/Tinted material: macOS 26.1 documents tinted items as
    /// opaque against dark backgrounds, with notifications the named case.
    /// HIG Materials likewise says alerts (and anything with a lot of text)
    /// use regular, not clear.
    ///
    /// We deliberately leave the clear *pipeline* untouched — mixing the two
    /// parameter sets is what made regular read as "the same glass smudged"
    /// (docs/04 C12). Instead we supply Apple's highlights / shadow layers
    /// as sibling strokes hugging the outline. A uniform face wash was tried
    /// here on 11-14 and rejected: it is frosted glass, not Liquid Glass
    /// (docs/04 P7). Clear glass on black is a material vacuum:
    /// there is nothing to refract, HIG forbids a dimming layer, and the dark
    /// branch zeroes the face layers (docs/04 P5), so these layers are the
    /// only thing that can define the object's silhouette.
    ///
    /// 🔴 20:56 用户拍板：**边缘强度不再听背景亮度**，恒为一个常量。
    ///
    /// 现象（两张对比图）：面板离窗口很远、正下方空空如也，却整块忽深忽浅。
    /// 根因是采样窗尺度错了 —— 当年的采样器取的是屏幕**顶部中央
    /// 40% 宽 × 20% 高**（本机 ≈768×216pt）的一整条大区域，而浮岛只有
    /// 408×70pt 左右。多出来的 150pt 高度和两侧各 180pt 宽度把这个 app 自己
    /// 以外的桌面、壁纸、别的窗口全都算了进去。壁纸一亮一暗，luma 就从
    /// 0.52 掉到 0.2x，于是边缘高光在 0 与 1 之间整幅摆动 —— 看起来就是
    /// "面板自己在变深变浅"，跟它底下有什么毫无关系。
    ///
    /// 之前 11-17 已经把 luma 驱动的黑遮罩删了，剩下这一条边缘调制是同类
    /// 残余。弹窗永远贴在屏幕最顶上，背后只有菜单栏和壁纸，这个采样值对观感
    /// 没有任何增益，只有干扰 —— 所以直接冻结成常量，采样保留但只写日志
    /// （`bn-glass-surface.log`），不再参与渲染。
    ///
    /// 常量取 0.22：接近原来亮背景下的保底观感（无采样时 0.25），避免用户
    /// 立刻看到"边又亮了"；暗背景下也不再突然长出一圈亮边（11-17 已明确
    /// 嫌那圈高光"太奇怪"）。要调只改这一处。
    static let fixedEdgeStrength: Double = 0.22

    private var darkBackdropStrength: Double {
        guard glassIsActive, clearGlass, !reduceTransparency else { return 0 }
        return Self.fixedEdgeStrength
    }

    /// On a bright / rich backdrop the glass already defines itself by
    /// lensing and the filter's own key-fill highlight, so strength 0 leaves
    /// the entire sibling stack transparent: the look the user approved is
    /// unchanged, with no extra outline on the wallpaper.
    ///
    /// When Screen Recording is revoked there is no sample to trust, so keep
    /// a faint outline instead of degrading to "white type on nothing" (P5's
    /// old fallback, explicitly rejected on 11-14). Only the *wash* needs a
    /// real measurement; a specular edge is safe to draw unconditionally.
    private var rimStrength: Double {
        // 20:56: no longer branches on `sampledLuma` either — a sample existing
        // or not must not change the look. One constant for every backdrop.
        darkBackdropStrength
    }

    /// The centre of a Liquid Glass element is a **pure window**. What makes
    /// it read as glass is the lensed, lit edge — never a uniform tint over
    /// the whole plate. A uniform wash (or a blur) is the definition of
    /// frosted glass / glassmorphism, which is exactly what the first 11-14
    /// attempt produced (user: "像一个磨砂玻璃…根本不像液态玻璃").
    ///
    /// WWDC25 219, 1:55: "The primary way Liquid Glass visually defines
    /// itself is through Lensing"; 10:44 the highlights layer is "light
    /// sources ... shine on the material ... defining its silhouette".
    /// Apple's specular highlights are built from inner shadows and gradient
    /// overlays that follow the outline — never a flat face fill.
    ///
    /// 🔴 21:33 user: "深色背景下这个高光太奇怪了". The first edge version
    /// stacked 10pt / 4pt / 3pt / 1pt strokes. A `stroke` is centred on the
    /// path, so half of every wide one spills **outside** the outline — on a
    /// dark backdrop that painted a thick glowing frame around the card:
    /// "a popup with a border", not glass. Keep only a hairline plus a 2pt
    /// top-edge glow (1pt of spill at most).
    ///
    /// Nothing fills the centre: the dark window behind stays visible
    /// *through* the card. No `.blendMode`, `.shadow`, `.mask` or
    /// `.clipShape` — each forces an offscreen pass and a backdrop layer has
    /// no window server to sample in one (docs/04 C8 / P5).
    /// Strength of the directional layer. Same dark-backdrop ramp as
    /// `rimStrength`, but with a floor: Apple's clear glass keeps a specular
    /// edge over bright content too, and at `rimStrength == 0` (bright
    /// backdrop) the plate had no lit edge at all and read as a flat slab.
    /// The floor is a fraction of the user's own highlight dial, so that dial
    /// still governs the result.
    private var specularStrength: Double {
        // +0.12 while the pointer is on the plate: the specular lobe brightens
        // as the light "turns towards" the viewer, the same way Apple's
        // pointer-reactive material does. Still driven by the user's dial.
        max(rimStrength, highlight * 0.30) + (pointerLightAngle == nil ? 0 : 0.12)
    }

    /// Light direction in degrees (0 = right, -90 = straight above) while the
    /// pointer is over the surface. `nil` = nobody is pointing, so the rest
    /// angle wins. Kept off the private filter path deliberately: this only
    /// re-parameterises a SwiftUI gradient, it never re-creates a CA layer.
    @State private var pointerLightAngle: Double?
    /// Measured size of the surface, used only to turn the pointer position
    /// into an angle. Reported by a background `GeometryReader`, so it never
    /// takes part in layout.
    @State private var surfaceSize: CGSize = .zero

    /// Light direction at rest: straight above while the island is closed, and
    /// a little to the upper left once it opens. That shift is the light's
    /// contribution to the open/close morph — it reads as the material
    /// catching a different part of the room as the plate grows.
    private var restLightAngle: Double { isOpen ? -74 : -90 }

    /// Angle actually handed to the conic gradient.
    private var specularAngleForLayer: Double { pointerLightAngle ?? restLightAngle }

    /// The rim thickens a hair while open: Apple's larger plate carries a
    /// wider specular band than the small capsule.
    private var specularLineWidth: Double { isOpen ? 1.7 : 1.5 }

    /// Turns the pointer position into a light angle, quantised: only a >6°
    /// change is published and the 0.42s ease does the smoothing, so a moving
    /// pointer costs a handful of gradient rebuilds instead of one per event.
    private func setPointerLight(at point: CGPoint) {
        guard surfaceSize.width > 40, surfaceSize.height > 8 else { return }
        let dx = point.x - surfaceSize.width / 2
        let dy = point.y - surfaceSize.height / 2
        guard abs(dx) + abs(dy) > 1 else { return }
        let snapped = (atan2(dy, dx) * 180 / .pi / 6).rounded() * 6
        if let current = pointerLightAngle, abs(current - snapped) < 5.9 { return }
        pointerLightAngle = snapped
        GlassDiagnostics.recordSurface(
            strength: darkBackdropStrength,
            rim: rimStrength,
            angle: snapped
        )
    }

    /// Strength of the hand-drawn inner shadow, 0…1.
    ///
    /// `glassBackground` has **no** `inputInnerShadow*` channel — the full
    /// input list of the filter was checked key by key (60 keys: `inputShadow*`,
    /// `inputRingShadow*`, `inputSDRShadow*`, `inputFace*`, `inputBleed*`,
    /// `inputKeyFillHighlight*`, …), and nothing takes an inset shadow. Apple's
    /// own Liquid Glass builds that cue out of outline-following overlays, so
    /// it is drawn the same way here rather than enabling a filter channel that
    /// does not exist.
    ///
    /// Scaled by the same presence dial as the face and the cast shadow: at
    /// presence 0 there is no slab, so there is nothing for the edge to shade.
    private var innerShadowStrength: Double {
        guard glassIsActive, clearGlass, !reduceTransparency else { return 0 }
        return min(max(glassOpacity, 0), 1)
    }

    /// 🔴 20:48 user kill switch: the inner shadow ring IS the "一大圈黑色阴影".
    /// Three nested black strokes hugging the outline (~0.15 combined alpha,
    /// 6–10pt band) read on the floating cards as a dark rim around the whole
    /// card — the user has now rejected it three rounds in a row with a
    /// screenshot ("你他妈自己看"). 0 = ring off. The glass keeps its depth
    /// from the lens bend and the specular lip; if a hint of edge shading is
    /// ever wanted back, raise this in small steps (0.3 ≈ 0.05 at the edge).
    static let innerShadowScale: Double = 0

    /// The inner shadow ring: black only along the outline, decaying inwards.
    ///
    /// A single `Shape.stroke` paints its whole band at one alpha, so the
    /// "0.16 at the outermost 1pt fading to 0 by 6pt" profile is composed from
    /// three nested strokes whose alphas accumulate where they overlap:
    /// 10pt (+0.05), 8pt (+0.04), 6pt (+0.07) → ≈0.152 in the first 3pt inside
    /// the edge, ≈0.088 at 3–4pt, ≈0.05 at 4–5pt, 0 beyond — a straight-ish
    /// ramp, no fill anywhere near the centre, no `.shadow`, `.blur`,
    /// `.blendMode` or `.mask` (each would force an offscreen pass that a
    /// backdrop layer cannot sample in).
    @ViewBuilder
    private var innerShadowRing: some View {
        if innerShadowStrength > 0.001, Self.innerShadowScale > 0.001 {
            ZStack {
                shape.stroke(Color.black.opacity(0.05 * innerShadowStrength * Self.innerShadowScale), lineWidth: 10)
                shape.stroke(Color.black.opacity(0.04 * innerShadowStrength * Self.innerShadowScale), lineWidth: 8)
                shape.stroke(Color.black.opacity(0.07 * innerShadowStrength * Self.innerShadowScale), lineWidth: 6)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var glassSurfaceHighlights: some View {
        ZStack {
            // P2: the missing inner shadow. Sits at the bottom of the stack so
            // the specular lobe still paints over it — light passes over shade.
            innerShadowRing

            // A 2pt glow that exists ONLY along the top edge. The sides and
            // bottom are fully transparent, so no visible frame can form.
            shape.stroke(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.16 * rimStrength), location: 0.0),
                        .init(color: .white.opacity(0.05 * rimStrength), location: 0.16),
                        .init(color: .clear, location: 0.34),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 2
            )

            // The specular hairline: bright along the top, fading down the
            // sides, turning into a faint dark inner lip at the bottom.
            shape.stroke(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.55 * rimStrength), location: 0.0),
                        .init(color: .white.opacity(0.16 * rimStrength), location: 0.20),
                        .init(color: .white.opacity(0.04 * rimStrength), location: 0.60),
                        .init(color: .black.opacity(0.18 * rimStrength), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )

            // Directional specular — the structure of Apple's
            // CASDFGlassHighlightEffect: it takes a light angle and returns two
            // lobes, a strong one on the side whose outline normal faces the
            // light, plus a weaker counter-lobe on the opposite side (WWDC25
            // 219: highlights are geometry-driven, not a veil). That private
            // filter cannot be driven per frame from here, so the same two-lobe
            // structure is drawn as a conic gradient *along the outline*: only
            // the rim band is painted, the centre stays at zero pixels — no
            // fill, no mask, no blend mode.
            shape.stroke(
                AngularGradient(
                    stops: [
                        // primary lobe, centred on `specularAngle`
                        .init(color: .white.opacity(0.36 * specularStrength), location: 0.00),
                        .init(color: .white.opacity(0.13 * specularStrength), location: 0.06),
                        .init(color: .white.opacity(0.00), location: 0.12),
                        // counter-lobe: the faint secondary reflection that
                        // keeps the plate from reading as a one-sided sticker
                        .init(color: .white.opacity(0.00), location: 0.42),
                        .init(color: .white.opacity(0.09 * specularStrength), location: 0.50),
                        .init(color: .white.opacity(0.00), location: 0.58),
                        .init(color: .white.opacity(0.00), location: 1.00)
                    ],
                    center: .center,
                    angle: .degrees(specularAngleForLayer - 22)
                ),
                lineWidth: specularLineWidth
            )
        }
        .allowsHitTesting(false)
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
    /// 诊断日志总开关，**默认关闭**。
    ///
    /// 这是一套取证基建：`timeline` 每次调用都要 fileExists + stat 取大小 +
    /// open + seek + write + close，而它的调用点包括每 0.4 秒的采样 tick 和
    /// 每次材质重建。留在生产路径上等于日常运行一直在往 ~ 根目录写盘，且
    /// 5 个日志文件散落在家目录（审查 P2-4）。
    ///
    /// 排查时：
    ///     touch /tmp/bn-notch.debug
    /// 重启 app 即恢复全部日志，与 `bnDebugLog` 共用同一个开关。
    private static let enabled: Bool =
        FileManager.default.fileExists(atPath: "/tmp/bn-notch.debug")

    static func log(tag: String, _ message: String) {
        guard enabled else { return }
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
        guard enabled else { return }
        let path = NSHomeDirectory() + "/bn-glass-applied.log"
        try? (message + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        NSLog("[BNGLASS applied] %@", message)
    }

    /// Written only when the adaptive strength crosses a 0.1 bucket, so the
    /// sampler's ~2.5 updates/s do not turn into as many disk writes. This is
    /// the only read-back for the sibling highlight layers — they are plain
    /// SwiftUI shapes and have no private filter to dump.
    private static var lastSurfaceBucket: Int = -1

    /// The last value handed to `inputRefractionOpacity`, mirrored here so the
    /// surface read-back (which runs in the SwiftUI layer and cannot reach the
    /// NSView's parameters) can show it alongside the other strengths.
    static var appliedRefractionOpacity: Double = 0

    static func recordSurface(strength: Double, rim: Double, angle: Double? = nil) {
        guard enabled else { return }
        // The refraction opacity is part of the key: the first mount writes a
        // line before the surface has rebuilt once, and a strength-only bucket
        // would then swallow every later line, leaving a stale 0.000 on disk.
        let bucket = Int(strength * 10) * 1000 + Int((appliedRefractionOpacity * 100).rounded())
        guard bucket != lastSurfaceBucket else { return }
        lastSurfaceBucket = bucket
        let text = "darkStrength=" + String(format: "%.2f", strength)
            + " edge=" + String(format: "%.2f", rim)
            + " refrOp=" + String(format: "%.3f", appliedRefractionOpacity)
            + " light=" + (angle.map { String(format: "%.0f", $0) } ?? "rest")
            + " centre=pure-window"
        let path = NSHomeDirectory() + "/bn-glass-surface.log"
        try? (text + "\n").write(
            to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8
        )
    }

    /// Lets the next `recordSurface` through the bucket filter. The first frame
    /// after the island mounts is exactly what the warm-up bug is about, and a
    /// bucket equal to the previous scene's last bucket used to swallow it.
    static func forceNextSurface() { lastSurfaceBucket = -1 }

    /// APPEND-ONLY trace of *when* each number reached the material.
    ///
    /// Every other log in this type is useless for timing: `applied` and `luma`
    /// overwrite, and `surface` is deduplicated by 0.1 buckets. A 3-second
    /// warm-up therefore left no evidence at all — only its last frame
    /// survived, and the first (wrong) frame was gone. This one never
    /// overwrites, so the reveal can be replayed tick by tick.
    ///
    /// Line format: `<epoch-ms> <media-time> <tag> k=v ...`
    /// - rotated once per launch to `~/bn-glass-timeline.prev.log`, and again
    ///   mid-session if the live file passes 2 MB, so a long run cannot grow
    ///   without bound;
    /// - per-tag 16 ms throttle: a SwiftUI re-render storm collapses into one
    ///   line per frame, while the first entry after any quiet gap always gets
    ///   through (the throttle only ever drops entries that repeat within a
    ///   single frame).
    private static let timelineThrottle: CFTimeInterval = 0.016
    private static var timelineRotated = false
    private static var timelineStamp: [String: CFTimeInterval] = [:]

    static func timeline(_ tag: String, _ fields: String = "") {
        guard enabled else { return }
        let home = NSHomeDirectory()
        let path = home + "/bn-glass-timeline.log"
        let prev = home + "/bn-glass-timeline.prev.log"
        let fm = FileManager.default

        if !timelineRotated {
            timelineRotated = true
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: prev)
                try? fm.moveItem(atPath: path, toPath: prev)
            }
        }

        let now = CACurrentMediaTime()
        if let last = timelineStamp[tag], now - last < timelineThrottle { return }
        timelineStamp[tag] = now

        var line = String(format: "%.3f", Date().timeIntervalSince1970 * 1000)
            + " " + String(format: "%.4f", now)
            + " " + tag
        if !fields.isEmpty { line += " " + fields }
        line += "\n"
        guard let data = line.data(using: .utf8) else { return }

        let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        if size > 2_000_000 {
            try? fm.removeItem(atPath: prev)
            try? fm.moveItem(atPath: path, toPath: prev)
        }

        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
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

    /// 一行可粘贴的诊断摘要：系统版本 + 四个私有符号是否存在。私有 API 在
    /// 小版本里改名时，设置页靠它区分"用户没开"和"系统不支持"。
    static var diagnosticsSummary: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let symbols = [
            "CABackdropLayer": NSClassFromString("CABackdropLayer") != nil,
            "CASDFLayer": NSClassFromString("CASDFLayer") != nil,
            "CASDFElementLayer": NSClassFromString("CASDFElementLayer") != nil,
            "CASDFOutputEffect": NSClassFromString("CASDFOutputEffect") != nil,
            "CAFilter(glassBackground)": NSClassFromString("CAFilter") != nil,
        ]
        let body = symbols.map { "\($0.key)=\($0.value ? 1 : 0)" }.joined(separator: " ")
        return "Notch Island 材质诊断 macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) "
            + "supported=\(isSupported ? 1 : 0) " + body
    }
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
    /// 内容层材质开关（见 NotchSurfaceBackground.contentLifted）。
    var contentLifted: Bool = false

    private var backdrop: CALayer?
    private var sdfLayer: CALayer?
    private var sdfElement: CALayer?

    private var reveal: Double = 1
    private var revealStart: CFTimeInterval = 0

    /// Apple's material reads thicker while it is flexed to carry content
    /// (WWDC25 219 "Adaptivity": morphing to a larger size simulates a
    /// thicker slab with **more pronounced lensing and refraction**).
    /// 0 = resting (the static size curve), 1 = fully flexed; ramped by
    /// `flex(to:)` the same way `reveal` is, so the bend change is never a
    /// step. Flex drives ONLY the lens — a shadow-deepening variant was
    /// user-rejected on 11-17 ("外面一圈阴影很丑": the shadow band wraps the
    /// whole outline, so deepening it reads as a dirty ring, not a cast).
    var flexTarget: Double = 0
    private var flex: Double = 0
    private var flexFrom: Double = 0
    private var flexStart: CFTimeInterval = 0

    /// 11-18：reveal 与 flex 的两条 ramp 合并到一个 CADisplayLink 驱动。
    /// 原来各挂一个 60Hz Timer——Timer 走 RunLoop .common 但不与屏幕刷新
    /// 对齐，错过一个 tick 就整帧跳变；CADisplayLink 每个屏幕刷新周期回调
    /// 一次，与 CoreAnimation 的呈现节奏同步，且 ProMotion 屏自动跟到 120Hz。
    /// 链上用 WeakDisplayLinkTarget 壳弱引用视图：link 强引用 target 直到
    /// invalidate，直接传 self 会挡住 deinit。
    private var displayLink: CADisplayLink?
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
        displayLink?.invalidate()
        displayLink = nil
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
        ensureFrameLoop()
    }

    /// Skips the ramp — used when Reduce Motion is on, and when the view is
    /// rebuilt with animation switched off after it has already started.
    func finishReveal() {
        reveal = 1
        rebuild()
        // 只在 flex 也没有 ramp 在跑时才停帧，别把进行中的 flex 动画一起杀掉。
        if flex == flexTarget {
            stopFrameLoop()
        }
    }

    // MARK: Content flex

    /// Ramps the morph dial to `target` (0…1) over ~0.28 s, same easing as the
    /// reveal. While content is up on the glass the lens bends harder —
    /// Apple's "more pronounced lensing and refraction" — then relaxes back
    /// to the resting size curve when the content dismisses.
    func flex(to target: Double) {
        let clamped = min(max(target, 0), 1)
        guard clamped != flexTarget else { return }
        flexFrom = flex
        flexTarget = clamped
        flexStart = CACurrentMediaTime()
        ensureFrameLoop()
    }

    /// Jumps the dial without a ramp — used at mount time, where a fresh
    /// material should already match its content instead of animating late.
    func settleFlex(to target: Double) {
        flexTarget = min(max(target, 0), 1)
        flex = flexTarget
    }

    // MARK: Frame loop

    /// 任一 ramp 活跃时确保帧循环在跑（幂等）。
    private func ensureFrameLoop() {
        guard displayLink == nil else { return }
        let proxy = WeakDisplayLinkTarget()
        proxy.owner = self
        // macOS 上 iOS 风格的 CADisplayLink(target:selector:) 标记为
        // API_UNAVAILABLE，必须走 NSView.displayLink(withTarget:selector:)
        // （macOS 14+）拿同一颗 CADisplayLink，SDK 头文件明确指了这条路。
        let link = displayLink(target: proxy,
                               selector: #selector(WeakDisplayLinkTarget.frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopFrameLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 每帧步进：reveal 与 flex 各自按时间算进度，任一仍在动就 rebuild 一次，
    /// 两条 ramp 都到头才停帧。CADisplayLink 加在 .main 上，回调必在主线程。
    func stepFrame(_ link: CADisplayLink) {
        var active = false

        if reveal < 1 {
            let progress = min(1.0, (CACurrentMediaTime() - revealStart) / 0.26)
            reveal = progress >= 1 ? 1 : 1 - pow(1 - progress, 3)
            if progress < 1 { active = true }
        }

        if flex != flexTarget {
            let progress = min(1.0, (CACurrentMediaTime() - flexStart) / 0.28)
            let eased = 1 - pow(1 - progress, 3)
            flex = progress >= 1 ? flexTarget : flexFrom + (flexTarget - flexFrom) * eased
            if progress < 1 { active = true }
        }

        if active {
            rebuild()
        } else {
            stopFrameLoop()
        }
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

        // 🔴 20:56: the `luma <= 0.22` hard branch is gone. It zeroed
        // faceBlack / faceFill / shadowFill and boosted `highlight` ×1.25 the
        // instant the sample crossed 0.22 — a binary switch on top of the
        // now-frozen edge constant, i.e. the last remaining source of
        // "the panel changes shade for no reason". The clear variant's own
        // face values (0.1 / 0.05 / 0.05) are already imperceptible, so nothing
        // is lost by running the same numbers on every backdrop.

        p.applyPresence(presence)

        // 11-18（晚）：用户把这张卡截图发回来——「为了可读性完全做成磨砂玻璃了，
        // 还是不要这么重的磨砂，还是要液态玻璃」。判断成立：上一版照 HIG「内容层用
        // regular」的说法补的正是 regular 的核心手段——**模糊**，而模糊在视觉上就等于
        // 磨砂，跟这套 clear 透镜的语言直接冲突（docs/04 P6/P7：均匀 tint/blur = 磨砂，
        // 已被否定两次）。所以把模糊整块撤掉，只保留不改变通透感的两件事：
        //   · 轻微抬高黑位（0.10），亮壁纸不会把白字淹掉
        //   · 极少量面层填充（0.06），让板子有实体感而不是描图纸
        // 可读性改由已有的两层文字投影 + 0.16 黑遮罩承担（文字不再需要靠材质硬撑）。
        // 透镜（折射/色散/边缘高光）一行未动——那才是「液态玻璃」的可见部分。
        if contentLifted, variant == .clear {
            let lift = min(max(presence, 0), 1)
            p.blurRadius = 0
            p.blurEdgeOpacity = 0
            p.blurFillLighten = 0
            p.faceBlack = 0.10 * lift
            p.faceFillAlpha = max(p.faceFillAlpha, 0.06 * lift)
        }

        // The lens. Scaled by the same presence dial the face uses, so "glass
        // presence 0" still means a plain window rather than a window with a
        // refracting rim. `reveal` is applied at filter-set time, next to
        // `inputInnerRefractionAmount`, so the bend and its opacity ramp
        // together instead of the rim popping in at full strength.
        p.refractionOpacity = GlassMetrics.refractionOpacity * min(max(presence, 0), 1)
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
        //    Content flex deepens the bend (not the shadow): WWDC25 219
        //    "Adaptivity" says morphing larger simulates a thicker material
        //    with **more pronounced lensing and refraction** — the liquid feel
        //    lives in the lens, not in a darker outline. Amplitudes are kept
        //    small (+13% bend, +20% opacity) so the rim never reads as a
        //    drawn border or a dark band; it only bends light harder.
        filter.setValue(p.innerRefraction * ramp * (1 + 0.13 * flex), forKey: "inputInnerRefractionAmount")
        filter.setValue(p.innerRefractionHeight, forKey: "inputInnerRefractionHeight")
        // Apple's clear glass does *not* flare light back out of the rim; the
        // outer pass stays at zero. The "翻卷" in the tutorial is what Apple
        // gets for free from the two-layer bend, not from an extra parameter.
        filter.setValue(0.0, forKey: "inputOuterRefractionAmount")
        filter.setValue(0.0, forKey: "inputOuterRefractionHeight")
        filter.setValue(-1.0, forKey: "inputRefractionDistance0")
        filter.setValue(0.0, forKey: "inputRefractionDistance1")
        // Ramps with `reveal` exactly like the bend above, so the lip fades in
        // over the 0.26 s reveal instead of popping to full depth on frame one.
        filter.setValue(p.refractionOpacity * ramp * (1 + 0.20 * flex), forKey: "inputRefractionOpacity")
        // Mirrored for the surface read-back; this is the number the filter is
        // actually running with, not the struct's stored field.
        GlassDiagnostics.appliedRefractionOpacity = p.refractionOpacity * ramp * (1 + 0.20 * flex)

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
        // The five dials that decide whether that band is actually visible.
        // They used to be hard-zero here, which is why the plate had a shadow
        // *geometry* and no shadow at all. `p.*` already carries the presence
        // scaling (see `applyPresence`); `ramp` is the open/close reveal, so
        // the shadow grows in with the plate instead of popping on.
        // 🔴 11-17 目测判定：投影加深（opacity ×1.55、offset +2.5）读作「绕轮廓一圈
        // 的脏暗带」，用户原话「外面一圈阴影很丑」。投影环带是沿 SDF 轮廓一圈画的，
        // 加深/加大 offset 会让上缘和侧缘也露出来——不是「下方一坨投影」。永久还原
        // Apple 静态五件套，flex 不再碰投影。见本文件 flex 的折射映射（液态感正解）。
        filter.setValue(p.shadowOpacity * ramp, forKey: "inputShadowOpacity")
        filter.setValue(p.shadowRadius, forKey: "inputShadowRadius")
        filter.setValue(p.shadowBlurRadius, forKey: "inputShadowBlurRadius")
        filter.setValue(p.shadowDistanceOffset, forKey: "inputShadowDistanceOffset")
        filter.setValue(p.shadowVibrancyContribution, forKey: "inputShadowVibrancyContribution")
        filter.setValue(1.0, forKey: "inputShadowColorMatrixWhite")
        filter.setValue(0.0, forKey: "inputShadowColorMatrixBlack")
        filter.setValue(1.2, forKey: "inputShadowColorMatrixSaturation")
        // Shadow offset pushed 8 → 10pt down (20:19): with the narrowed band
        // the remaining ink should sit mostly UNDER the bottom edge — a cast
        // shadow from an overhead light — not wrap the outline evenly.
        filter.setValue(NSValue(size: NSSize(width: 0, height: 10)), forKey: "inputShadowOffset")

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

        // `reveal` and the face/shadow fills are what make the plate read
        // deep. One line per rebuild so the ramp can be replayed tick by tick.
        GlassDiagnostics.timeline(
            "rebuild",
            "variant=\(variant == .clear ? "clear" : "regular")"
            + " faceBlack=" + String(format: "%.3f", p.faceBlack)
            + " faceFill=" + String(format: "%.3f", p.faceFillAlpha)
            + " shadowFill=" + String(format: "%.3f", p.shadowFillAlpha)
            + " highlight=" + String(format: "%.2f", p.highlight)
            + " presence=" + String(format: "%.2f", presence)
            + " reveal=" + String(format: "%.2f", ramp)
            + " flex=" + String(format: "%.2f", flex)
            // The value actually handed to `inputRefractionOpacity` (reveal is
            // applied on the way in). 0 here means the rim is invisible no
            // matter what the bend is set to.
            + " refrOp=" + String(format: "%.3f", p.refractionOpacity * ramp * (1 + 0.20 * flex))
            + " refrAmt=" + String(format: "%.1f", p.innerRefraction * ramp * (1 + 0.13 * flex))
            + " h=" + String(format: "%.0f", bounds.height)
            + " lifted=\(contentLifted)"
        )
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
            // The bend above is worth nothing while `inputRefractionOpacity` is
            // 0, and both numbers look identical in a screenshot either way, so
            // the applied opacity has to be in the log to prove P1 is live.
            + " refractionOpacity=\(p.refractionOpacity)"
            + " shadow=\(p.shadowAmount)/\(p.shadowHeight)/\(p.shadowFillAlpha) highlight=\(p.highlight)"
            // P2: the five dials that decide whether the band above is visible
            // at all. All five were 0.0 before this commit, and identical
            // screenshots look identical whether they are 0 or 0.16 — only the
            // log can prove the shadow is live.
            + " shadowOp=\(String(format: "%.4f", p.shadowOpacity))"
            + " shadowR=\(String(format: "%.2f", p.shadowRadius))"
            + " shadowBlur=\(String(format: "%.2f", p.shadowBlurRadius))"
            + " shadowDist=\(String(format: "%.2f", p.shadowDistanceOffset))"
            + " shadowVib=\(String(format: "%.4f", p.shadowVibrancyContribution))"
            + " presence=\(presence) dispersion=\(p.dispersion)"
            + " faceWhite=\(p.faceWhite) faceBlack=\(p.faceBlack) faceFill=\(p.faceFillAlpha)"
            + " lifted=\(contentLifted)"
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
    /// 内容层材质：见 NotchSurfaceBackground.contentLifted。
    var contentLifted: Bool = false
    /// Content flex: `true` while something is up on this surface (open
    /// panel, a peeking card). Defaults to false so existing call sites and
    /// the memberwise initialiser keep working untouched.
    var flexed: Bool = false

    static var isSupported: Bool { LiquidGlassPipeline.isSupported }

    func makeNSView(context: Context) -> LiquidGlassSurfaceView {
        GlassDiagnostics.log(tag: "make", "makeNSView refraction=\(refraction) lens=\(lensHeight)")
        let view = LiquidGlassSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 195))
        apply(to: view)
        // A fresh material must already match its content state instead of
        // animating late; the ramp only runs on later state flips.
        view.settleFlex(to: flexed ? 1 : 0)
        view.rebuild()
        return view
    }

    func updateNSView(_ nsView: LiquidGlassSurfaceView, context: Context) {
        apply(to: nsView)
        nsView.flex(to: flexed ? 1 : 0)
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
        view.contentLifted = contentLifted
        if !animatesReveal { view.finishReveal() }
        view.recordAppliedOnce()
    }
}

/// CADisplayLink 的 target 会被 link 强持有（直到 invalidate），直接传视图
/// 会形成保留环、deinit 永远不跑。这个壳只弱引用视图：视图释放后下一帧
/// 自动把 link 停掉，动画期间视图也不会被 link 拖活。
@MainActor
private final class WeakDisplayLinkTarget: NSObject {
    weak var owner: LiquidGlassSurfaceView?

    @objc func frame(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.stepFrame(link)
    }
}
