//
//  InlineOSD.swift
//  boringNotch
//
//  Created by Richard Kunkli on 14/09/2024.
//

import SwiftUI
import Defaults

struct InlineOSD: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Binding var accent: Color?
    @Binding var hoverAnimation: Bool
    @Binding var gestureProgress: CGFloat

    /// The hardware-notch display keeps the stock layout, where a black
    /// rectangle masks the camera cutout between the label and the slider.
    /// An external display has no cutout: that rectangle would paint a solid
    /// black bar right through the centre of the clear glass (docs/04 C10/P7).
    private var usesFloatingIsland: Bool {
        !vm.hasNotch && Defaults[.floatingPillOnNonNotchDisplay]
    }

    var body: some View {
        if usesFloatingIsland {
            floatingIslandOSD
        } else {
            notchOSD
        }
    }

    private var notchOSD: some View {
        HStack {
            HStack(spacing: 5) {
                OSDIconView(eventType: type, icon: icon, value: value, accent: accent)

                Text(osdTypeName(type))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .contentTransition(.numericText())
            }
            .frame(width: 100 - (hoverAnimation ? 0 : 12) + gestureProgress / 2, height: vm.notchSize.height - (hoverAnimation ? 0 : 12), alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)

            HStack {
                if type == .mic {
                    Text(value.isZero ? "muted" : "unmuted")
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                } else {
                        HStack {
                        DraggableProgressBar(value: $value, onChange: { v in
                            if type == .volume {
                                VolumeManager.shared.setAbsolute(Float32(v))
                            } else if type == .brightness {
                                BrightnessManager.shared.setAbsolute(value: Float32(v))
                            }
                        }, accentColor: accent, compact: true)
                        .frame(maxWidth: .infinity)
                        if type == .volume && value.isZero {
                            Text("muted")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .allowsTightening(true)
                                .multilineTextAlignment(.trailing)
                        } else if Defaults[.showClosedNotchOSDPercentage] {
                            Text(value, format: .percent.precision(.fractionLength(0)))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .allowsTightening(true)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .padding(.trailing, 4)
            .frame(width: 100 - (hoverAnimation ? 0 : 12) + gestureProgress / 2, height: vm.closedNotchSize.height - (hoverAnimation ? 0 : 12), alignment: .center)
        }
        .frame(height: vm.closedNotchSize.height + (hoverAnimation ? 8 : 0), alignment: .center)
    }

    /// Island OSD: one centred row, no camera mask, no fill. The width is
    /// fixed so the capsule grows to a predictable pill; the height comes from
    /// the content plus symmetric padding (docs/04 L8, AGENTS §3.5). Left and
    /// right insets match, so the row's visible centre is the plate's centre.
    private var floatingIslandOSD: some View {
        HStack(spacing: 10) {
            OSDIconView(eventType: type, icon: icon, value: value, accent: accent)
                .frame(width: 22)

            if type == .mic {
                Text(value > 0 ? "麦克风已开" : "麦克风已静音")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DraggableProgressBar(value: $value, onChange: { v in
                    if type == .volume {
                        VolumeManager.shared.setAbsolute(Float32(v))
                    } else if type == .brightness {
                        BrightnessManager.shared.setAbsolute(value: Float32(v))
                    }
                }, accentColor: accent, compact: true)
                .frame(maxWidth: .infinity)

                Group {
                    if type == .volume && value.isZero {
                        Text("静音")
                    } else {
                        Text(value, format: .percent.precision(.fractionLength(0)))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .monospacedDigit()
                .shadow(color: .black.opacity(0.55), radius: 1)
                .frame(width: 38, alignment: .trailing)
            }
        }
        .imageScale(.medium)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 300)
    }

    func osdTypeName(_ type: SneakContentType) -> String {
        switch type {
            case .volume:
                return NSLocalizedString("Volume", comment: "")
            case .brightness:
                return NSLocalizedString("Brightness", comment: "")
            case .backlight:
                return NSLocalizedString("Backlight", comment: "")
            case .mic:
                return NSLocalizedString("Mic", comment: "")
            default:
                return ""
        }
    }
}

#Preview {
    InlineOSD(type: .constant(.brightness), value: .constant(0.4), icon: .constant(""), accent: .constant(nil), hoverAnimation: .constant(false), gestureProgress: .constant(0))
        .padding(.horizontal, 8)
        .background(Color.black)
        .padding()
        .environmentObject(BoringViewModel(camera: CameraModel()))
}
