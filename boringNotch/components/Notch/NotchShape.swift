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
    /// Luminance of the REAL content behind the island, refreshed ~2.5×/s.
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
                + " sampling=\(backdropSampling)"
                + " luma=" + (backdropLuma.map { String(format: "%.3f", $0) } ?? "nil")
            )
            setSampling(backdropSampling)
        }
        .onDisappear {
            GlassDiagnostics.timeline(
                "unmount",
                "isOpen=\(isOpen) sampling=\(didAcquireSampling)"
                + " luma=" + (backdropLuma.map { String(format: "%.3f", $0) } ?? "nil")
            )
            setSampling(false)
        }
        .onChange(of: backdropSampling) { _, enabled in
            setSampling(enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bnBackdropLuminanceChanged)) { note in
            backdropLuma = (note.object as? NSNumber)?.doubleValue
            // Every field that can make the plate read deeper or shallower, in
            // the order they are applied. `scrim` is the black wash, `dark` the
            // dark-backdrop edge treatment, `spec` the specular stroke: the
            // "deep → shallow" flip is whichever of these three moves first.
            GlassDiagnostics.timeline(
                "surface",
                "luma=" + (backdropLuma.map { String(format: "%.3f", $0) } ?? "nil")
                + " dark=" + String(format: "%.3f", darkBackdropStrength)
                + " rim=" + String(format: "%.3f", rimStrength)
                + " spec=" + String(format: "%.3f", specularStrength)
                + " scrim=" + String(format: "%.3f", scrimOpacity)
                + " minScrim=" + String(format: "%.3f", minimumScrim)
                + " refrOp=" + String(format: "%.3f", GlassDiagnostics.appliedRefractionOpacity)
                + " glassOpacity=" + String(format: "%.2f", glassOpacity)
                + " isOpen=\(isOpen) active=\(glassIsActive)"
            )
            GlassDiagnostics.recordSurface(
                luma: backdropLuma,
                strength: darkBackdropStrength,
                rim: rimStrength
            )
        }
    }

    /// Idempotent: several panels can exist at once (one per display), and the
    /// sampler keeps a subscriber count rather than one loop per view.
    private func setSampling(_ enabled: Bool) {
        if enabled, !didAcquireSampling {
            didAcquireSampling = true
            BackdropLuminance.acquire()
            // A notification wakes the floating island from a fully hidden
            // state. Reuse the last real sample only while it still describes
            // the live desktop (one tick ≈ 0.4 s, so 0.9 s is "current or the
            // one before last"): that avoids the ~0.7 s empty interval which
            // used to fall back to the wallpaper proxy and flash a black scrim
            // (docs/04 P7). Anything older is a different scene and must NOT
            // be applied — that stale reuse is what opened the card deep and
            // then took ~3 s to un-deepen. `nil` here is the honest answer and
            // `scrimOpacity` has an explicit branch for it.
            if let cached = BackdropLuminance.currentIfFresh(within: 0.9) {
                backdropLuma = cached
            } else {
                backdropLuma = nil
            }
            // `age` is the number that matters: a cached sample is only useful
            // if it still describes what is behind the island right now.
            let age = BackdropLuminance.lastSampleAt.map { Date().timeIntervalSince($0) }
            GlassDiagnostics.timeline(
                "seed",
                "cached=" + (BackdropLuminance.current.map { String(format: "%.3f", $0) } ?? "nil")
                + " age=" + (age.map { String(format: "%.2f", $0) } ?? "none")
                + " applied=" + (backdropLuma.map { String(format: "%.3f", $0) } ?? "nil")
                + " status=\(BackdropLuminance.status)"
            )
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
        // 🔴 While real sampling is enabled but has not produced its first
        // frame, the wallpaper proxy must NOT take over: on this machine it
        // reads 0.440 while the actual content behind the island is a dark
        // window (docs/04 P3), which instantly triggers the 35% black wash —
        // the "black popup" reported 11-14 at notification onset.
        let luminance = realLuma ?? (backdropSampling ? nil : wallpaperLuma)

        var value = darkness

        if let luminance {
            if luminance <= 0.22 {
                // Dark backdrop: no *automatic* dimming layer at all. White type
                // is already legible and the edge highlights must stay intact.
                // The user's own darkness dial is never overridden here.
            } else {
                // 🔴 Continuous, not a step. The old `max(value, minimumScrim)`
                // jumped straight to 0.35 black the moment a smoothed sample
                // crept above 0.22; this machine's dark UI measures 0.166–0.216,
                // so a single frame over the threshold slapped a black slab
                // over the card and pressed the specular edge down with it.
                // Same 0.22→0.32 ramp as `darkBackdropStrength`: at 0.365 (the
                // normal wallpaper) `warm == 1`, so the approved bright-
                // backdrop look is unchanged.
                let warm = min(max((luminance - 0.22) / 0.10, 0), 1)
                value = max(value, minimumScrim * warm)
                if luminance > 0.62 {
                    value = max(value, 0.35)
                } else if luminance > 0.45 {
                    value = max(value, 0.18)
                }
            }
        } else {
            // Sampling enabled but no frame yet, or the last one is stale
            // enough that `setSampling` refused to apply it. Unknown backdrop
            // must be treated as the *worst case the gate exists for* — bright
            // content — because under-dimming bright content is a legibility
            // failure while over-dimming dark content is merely a wrong look
            // for one capture (~0.1 s; `start()` samples immediately).
            //
            // This used to be `minimumScrim * 0.2` (= 0.07), which was tuned
            // when the seed always supplied a value and `nil` never happened
            // in practice. With stale samples now rejected it *does* happen,
            // and 7% over a real white window made white type unreadable.
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
    /// Continuous rather than a boolean: a hard cut at 0.22 made the card
    /// flicker whenever the smoothed sample crawled across the threshold.
    private var darkBackdropStrength: Double {
        guard glassIsActive, clearGlass, !reduceTransparency else { return 0 }
        guard let luma = sampledLuma else { return 0 }
        // This machine's normal wallpaper measures ~0.365, and a rich
        // wallpaper is exactly where HIG says clear glass belongs. The
        // treatment must be completely gone by then, so the ramp ends at
        // 0.32 — NOT at the scrim's 0.45 "bright" gate: that one is about
        // dimming *bright* content for legibility, a different question.
        let t = (luma - 0.22) / (0.32 - 0.22)
        return 1 - min(max(t, 0), 1)
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
        sampledLuma == nil ? 0.25 : darkBackdropStrength
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
            luma: backdropLuma,
            strength: darkBackdropStrength,
            rim: rimStrength,
            angle: snapped
        )
    }

    @ViewBuilder
    private var glassSurfaceHighlights: some View {
        ZStack {
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
/// windows) down to 192×108, ~2.5 times a second, and keep ONE number: the
/// average luminance of the top-centre strip where the island lives. No image
/// is stored, written to disk, or sent anywhere.
@MainActor
enum BackdropLuminance {
    static private(set) var current: Double?
    /// When the sample behind `current` was taken. `stop()` deliberately keeps
    /// `current`, so the number alone cannot tell a 40 ms-old reading from a
    /// 40 s-old one — only this timestamp can.
    static private(set) var lastSampleAt: Date?
    static private(set) var status: String = "off"

    private static var users = 0
    private static var loop: Task<Void, Never>?
    private static var tickCount = 0
    private static var lastTickAt: CFTimeInterval?

    /// The last reading, but only if it is young enough to still describe what
    /// is behind the island *now*.
    ///
    /// `stop()` keeps `current` on purpose (the floating island has no window
    /// while idle, so it must not lose the reading), but the island can be
    /// rebuilt minutes later over completely different content. Reusing a
    /// 4-minute-old 0.679 sample made a fresh card open with the bright-backdrop
    /// treatment — 35% black wash, no dark-backdrop edge, face fill still on,
    /// i.e. "偏深" — and the EMA needed six 0.7 s ticks to crawl back under
    /// 0.22, which is the ~3 s "变浅" the user sees.
    static func currentIfFresh(within seconds: TimeInterval) -> Double? {
        guard let current, let lastSampleAt else { return nil }
        guard Date().timeIntervalSince(lastSampleAt) <= seconds else { return nil }
        return current
    }

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
                    // Exponential smoothing only for drift: a one-frame spike
                    // at the 0.22 threshold must not make the material flip
                    // between "pure window" and "35% black" every 0.4 s. A
                    // scene-sized jump is handled further down by a reset.
                    if let value {
                        // Two different jobs, two different rules:
                        // - normal drift (a wallpaper parallax, a window edge
                        //   moving) → slow EMA, so the material never flickers;
                        // - a jump > 0.12 → this is a *different scene*, not
                        //   drift. The old code still crawled there at 35% per
                        //   tick: from a stale 0.679 down to the 0.22 threshold
                        //   took six ticks, i.e. the ~3 s of "偏深" after reveal.
                        //   Reset instead of smoothing; one frame of noise is
                        //   cheaper than three seconds of the wrong material.
                        let didReset: Bool
                        let smoothed: Double
                        if let last = current, abs(last - value) <= 0.12 {
                            didReset = false
                            smoothed = last * 0.65 + value * 0.35
                        } else {
                            didReset = true
                            smoothed = value
                        }
                        current = smoothed
                        lastSampleAt = Date()
                        status = String(format: "%.3f", smoothed)
                        tickCount += 1
                        let now = CACurrentMediaTime()
                        let gap = lastTickAt.map { now - $0 } ?? 0
                        lastTickAt = now
                        GlassDiagnostics.timeline(
                            "tick",
                            "raw=" + String(format: "%.3f", value)
                            + " ema=" + String(format: "%.3f", smoothed)
                            + " n=\(tickCount)"
                            + " dt=" + String(format: "%.3f", gap)
                            + " reset=\(didReset ? 1 : 0)"
                            + " iv=0.400"
                            + " status=\(status)"
                        )
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
                // 0.4 s, not 0.7 s. Two reasons: the EMA only has to smooth
                // drift now (a scene change resets it), and halving the period
                // halves how long any wrong reading can survive a reveal. The
                // cost is two 192×108 captures per second instead of 1.4.
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private static func stop() {
        loop?.cancel()
        loop = nil
        // Keep `current`: the floating island disappears entirely while idle,
        // so the next notification rebuilds this view and may reuse the last
        // real reading instead of waiting a full tick. Clearing it (and posting
        // nil) made every new card start with `backdropLuma == nil` → wallpaper
        // proxy → 35% black scrim for its first frames (docs/04 P7).
        //
        // `lastSampleAt` is what keeps that safe: the value survives, but the
        // view only applies it while `currentIfFresh(within:)` says the scene
        // has not changed. Without the timestamp this cache was a trap — a
        // reading from minutes ago was indistinguishable from a current one.
        status = "off"
        if let last = current {
            NotificationCenter.default.post(
                name: .bnBackdropLuminanceChanged, object: NSNumber(value: last)
            )
        } else {
            NotificationCenter.default.post(name: .bnBackdropLuminanceChanged, object: nil)
        }
    }

    /// Timing wrapper: the sampler's *cadence* is the bug, so every capture is
    /// logged with how long it blocked and what it produced. `rect` is the
    /// constant sample window (30%/80% origin, 40%×20% of the frame), repeated
    /// here so a log alone proves which pixels the number came from.
    nonisolated private static func capture() async -> Double? {
        let started = CACurrentMediaTime()
        let value = await sampleBackdrop()
        GlassDiagnostics.timeline(
            "cap",
            "dur=" + String(format: "%.3f", CACurrentMediaTime() - started)
            + " rect=0.30/0.80/0.40/0.20"
            + " result=" + (value.map { String(format: "%.3f", $0) } ?? "nil")
        )
        return value
    }

    nonisolated private static func sampleBackdrop() async -> Double? {
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

    /// Written only when the adaptive strength crosses a 0.1 bucket, so the
    /// sampler's ~2.5 updates/s do not turn into as many disk writes. This is
    /// the only read-back for the sibling highlight layers — they are plain
    /// SwiftUI shapes and have no private filter to dump.
    private static var lastSurfaceBucket: Int = -1

    /// The last value handed to `inputRefractionOpacity`, mirrored here so the
    /// surface read-back (which runs in the SwiftUI layer and cannot reach the
    /// NSView's parameters) can show it alongside the other strengths.
    static var appliedRefractionOpacity: Double = 0

    static func recordSurface(luma: Double?, strength: Double, rim: Double, angle: Double? = nil) {
        // The refraction opacity is part of the key: the first mount writes a
        // line before the surface has rebuilt once, and a strength-only bucket
        // would then swallow every later line, leaving a stale 0.000 on disk.
        let bucket = Int(strength * 10) * 1000 + Int((appliedRefractionOpacity * 100).rounded())
        guard bucket != lastSurfaceBucket else { return }
        lastSurfaceBucket = bucket
        let text = "luma=" + (luma.map { String(format: "%.3f", $0) } ?? "nil")
            + " darkStrength=" + String(format: "%.2f", strength)
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
        filter.setValue(p.innerRefraction * ramp, forKey: "inputInnerRefractionAmount")
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
        filter.setValue(p.refractionOpacity * ramp, forKey: "inputRefractionOpacity")
        // Mirrored for the surface read-back; this is the number the filter is
        // actually running with, not the struct's stored field.
        GlassDiagnostics.appliedRefractionOpacity = p.refractionOpacity * ramp

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

        // `reveal` and the face/shadow fills are what make the plate read
        // deep; `backdropLuma` is why they change. Both in one line so the
        // reveal can be matched against the sampler ticks.
        GlassDiagnostics.timeline(
            "rebuild",
            "variant=\(variant == .clear ? "clear" : "regular")"
            + " faceBlack=" + String(format: "%.3f", p.faceBlack)
            + " faceFill=" + String(format: "%.3f", p.faceFillAlpha)
            + " shadowFill=" + String(format: "%.3f", p.shadowFillAlpha)
            + " highlight=" + String(format: "%.2f", p.highlight)
            + " presence=" + String(format: "%.2f", presence)
            + " reveal=" + String(format: "%.2f", ramp)
            // The value actually handed to `inputRefractionOpacity` (reveal is
            // applied on the way in). 0 here means the rim is invisible no
            // matter what the bend is set to.
            + " refrOp=" + String(format: "%.3f", p.refractionOpacity * ramp)
            + " refrAmt=" + String(format: "%.1f", p.innerRefraction * ramp)
            + " h=" + String(format: "%.0f", bounds.height)
            + " luma=" + (backdropLuma.map { String(format: "%.3f", $0) } ?? "nil")
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
