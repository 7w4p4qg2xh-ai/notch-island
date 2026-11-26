//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var shelfState = ShelfStateViewModel.shared

    /// The header's icon buttons sit on a black capsule upstream. On Liquid
    /// Glass that capsule would be a second material stacked on the first —
    /// Apple's rule is no glass on glass, and a static translucent plate is the
    /// visual equivalent of one. On glass the control becomes the glyph alone,
    /// with the plate appearing only under the pointer (Apple's "interaction
    /// feedback" layer); off glass the original black capsule is untouched.
    private var onGlass: Bool { Defaults[.enableLiquidGlass] }

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if (!shelfState.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf] {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                // The camera housing is a physical cutout, so this plate only
                // exists to cover the camera preview on black. On Liquid Glass
                // it paints a second, fake notch on top of the surface — the
                // hardware already provides the silhouette, so it steps aside.
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
                    .opacity(Defaults[.enableLiquidGlass] ? 0 : 1)
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isOSDType(coordinator.sneakPeekState(for: vm.screenUUID).type) && coordinator.shouldShowSneakPeek(on: vm.screenUUID) && Defaults[.showOpenNotchOSD] {
                        OpenNotchOSD(
                             type: coordinator.binding(for: vm.screenUUID).type,
                             value: coordinator.binding(for: vm.screenUUID).value,
                             icon: coordinator.binding(for: vm.screenUUID).icon,
                             accent: coordinator.binding(for: vm.screenUUID).accent
                        )
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.showMirror] && coordinator.currentView == .home {
                            HeaderGlyphButton(onGlass: onGlass, icon: "web.camera") {
                                vm.toggleCameraPreview()
                            }
                        }
                        if Defaults[.settingsIconInNotch] {
                            HeaderGlyphButton(onGlass: onGlass, icon: "gear") {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                            }
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                timeToDischarge: batteryModel.timeToDischarge,
                                maxAdapterWatts: batteryModel.maxAdapterWatts,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        // On black, grey icons read as "secondary". On glass they disappear into
        // a light wallpaper, so the panel switches to white glyphs with a soft
        // shadow — the shadow is what keeps them legible on a white desktop too.
        // Split into a tight and a wide pass for the same reason as the song
        // info: the wide one alone leaves thin glyph strokes looking blurry.
        .foregroundColor(Defaults[.enableLiquidGlass] ? .white : .gray)
        .shadow(color: Defaults[.enableLiquidGlass] ? .black.opacity(0.5) : .clear, radius: 1, y: 0.5)
        .shadow(color: Defaults[.enableLiquidGlass] ? .black.opacity(0.3) : .clear, radius: 3, y: 1)
        .environmentObject(vm)
    }

    func isOSDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}

/// A 30 × 30 glyph button for the panel header.
///
/// Off glass it keeps upstream's black capsule. On glass the capsule is gone —
/// a permanently visible plate would be a second material stacked on the
/// first — and the fill only exists while the pointer is over it, which is the
/// interaction-feedback layer Apple draws for controls that live on glass.
private struct HeaderGlyphButton: View {
    let onGlass: Bool
    let icon: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundColor(.white)
                .imageScale(.medium)
                .frame(width: 30, height: 30)
                .background {
                    if onGlass {
                        Circle().fill(.white.opacity(hovering ? 0.18 : 0))
                    } else {
                        Capsule().fill(.black)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering = $0 }
    }
}
