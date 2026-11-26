# Changes relative to upstream Boring Notch v2.8-rc.2

Line counts are `git diff --stat` against the upstream tag. 33 Swift files
changed, roughly +3500 / -300. This file summarizes *what* changed and *why*;
the commit history has the per-step detail.

---

## 1. Notification pipeline

Upstream shows the system banner in the top-right corner and mirrors it into
the notch. This fork hides the native banner and renders the notification
inside the island itself.

| File | Change |
|---|---|
| `BoringNotchXPCHelper/NotificationWatcher.swift` | Application-name resolution with multi-path fallback (`AXAttributedDescription`, child elements, `AXDescription`, `AXLabel`, `AXTitle`); splitting on both ASCII and full-width commas; self-healing when a banner host window is lost; diagnostic dump |
| `boringNotch/components/Notch/NotificationLiveActivity.swift` | Compact bar plus icon resolution, two-line Apple-style layout |
| `boringNotch/ContentView.swift` | Peek scheduling, auto-expand, glass integration, conditional shadow |
| `boringNotch/XPCHelperClient/XPCHelperClient.swift` | Authorization polling, reconnect on connection loss, resume after wake, `lastError` surfacing instead of silent degradation |
| `boringNotch/components/Settings/Views/NotificationSettingsView.swift` | Auto-expand toggle |

Notable behavior: the banner host window is parked off-screen once and only
restored on `stop()`, app exit or crash. Restoring it per-notification made the
system banner flash in the corner on every incoming message.

## 2. Bluetooth peripheral battery

`boringNotch/managers/BatteryActivityManager.swift` gains a
`PeripheralBatteryManager` (+211 lines, no upstream code removed). Paired
headphones, mice and keyboards report battery over IOKit; the island shows a
compact indicator when a peripheral is low. Toggle in
`BatterySettingsView.swift`.

## 3. Liquid Glass surface

`boringNotch/components/Notch/NotchShape.swift` (+479 / -3) replaces the flat
black plate with a custom glass renderer built on Apple's private pipeline:

```
CABackdropLayer -> CASDFLayer / CASDFElementLayer -> CAFilter("glassBackground")
```

Design rules taken from Apple's `NSGlassEffectView` behavior: edge lensing with
a flat center, refraction before specular highlights, `clear` and `regular`
parameter sets never mixed, corner radius following plate height
(`min(requested, 0.24 * height)`) so tall HUD states don't collapse into a
fig-8 outline.

Backdrop awareness (`BackdropLuminance`): the wallpaper is not what sits behind
the island, so a black window behind it would keep the glass bright and
unreadable. ScreenCaptureKit samples a downsampled 192x108 region at the top
center of the screen (own windows excluded), smoothed with a 0.65/0.35
exponential filter at ~1.4 Hz. Below a mean luma of 0.22 no automatic scrim is
applied and a 1 pt rim is stroked along the plate outline instead, since a
fully transparent surface over pure black would otherwise disappear. This
requires the Screen Recording permission.

Settings live in `AppearanceSettingsView.swift`; the rim is drawn without
`.blendMode` or `.shadow` because both force an offscreen pass, and backdrop
layers have no window server inside an offscreen pass.

## 4. Floating island on displays without a notch

On an external display the upstream notch geometry is meaningless: it pinned a
static black rectangle to the top edge. This fork treats such displays as a
floating island and leaves the built-in notch display untouched, selected per
`screenUUID` so the two screens never share state.

| Element | Size |
|---|---|
| Notification card / music card | 408 x content height (~66) |
| Expanded panel | 480 x 150 |
| Collapsed pill | `Capsule` with radius from actual plate height |

Geometry is defined once in `ContentView` (`islandCardWidth`,
`islandNotificationSize`, `islandMusicSize`, `islandPanelSize`) and gated on
`usesFloatingIsland` / `hasNotch`. Collapsed state must use `Capsule` rather
than a hard-coded `radius = height / 2`; otherwise music or HUD states that
grow the plate produce a fig-8 outline.

Content is vertically and horizontally centered, height derived from content
plus symmetric padding. `islandOwnsPlate` keeps the glass layer authoritative.
Idle state suppresses the plate entirely (`hidesIdlePlateOnNonNotchDisplay`),
while full-screen notifications keep working. Now-playing cards are gated on
the playback source (`NowPlayingCardEligibility`), not on full-screen spaces,
because web players and in-app full-screen modes are not reported as spaces.

## 5. Music card and synchronized lyrics

A 408x66 card mirroring the notification card: 42 pt artwork, song title and
artist on the first line, current lyric line on the second.

Upstream `LyricsService.fetchLyrics()` tried AppleScript plain text first and
returned, so the LRCLIB time-synced path was unreachable. The order is now
LRCLIB synced -> NetEase synced -> plain text. A `TimelineView` at 0.25 s
advances the current line using `elapsedTime + delta * playbackRate`.

On the built-in notch display there is a physical constraint: the camera
cutout has no pixels, so a lyric line cannot be drawn inside the black plate.
`showLyricsOnNotchedDisplay` therefore renders a separate 320x26 capsule strip
*below* the plate, as an independent `ZStack` child with
`glassWhileClosed: true`. It cannot live inside the content `VStack` or after
`.clipShape`, both of which either crop it or inflate the plate.

## 6. Configuration keys

Eleven new `Defaults` keys were added in `boringNotch/models/Constants.swift`
covering glass parameters, backdrop sampling, floating-island geometry, idle
suppression, lyrics and peripheral battery. All default to values matching the
behavior described above.

---

## Differences from Apple's reference behavior (intentional)

- Glyphs do not invert with the material.
- No automatic 35% black scrim on bright `clear` backgrounds; the adaptive
  scrim is an opt-in toggle (`glassAdaptiveScrim`).
- Outer-edge refraction is not implemented: Apple's own `clear` material
  measures zero there, and the popular "rolling edge" effect is not how Apple
  builds it.
- No metaball merging, no pointer-driven highlights, no shadow outside the
  plate (a SwiftUI `.shadow` puts the backdrop layer into an offscreen pass
  where it renders black).

## Known limitations

- Verified only on Apple Silicon (M5 Pro, macOS 26) with one built-in notch
  display plus one external display.
- Screen Recording permission is required for backdrop-aware glass; without it
  the surface falls back to plain text over transparency by design.
- `private` CoreAnimation symbols (`CASDFLayer`, `glassBackground` filter) are
  undocumented and may break in a future macOS release.
- No automatic updates: the fork ships no appcast and does not use the upstream
  EdDSA key.
