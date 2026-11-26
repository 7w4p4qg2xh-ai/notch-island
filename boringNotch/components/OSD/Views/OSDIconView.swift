//
//  OSDIconView.swift
//  boringNotch
//
//  Created by Alexander on 2026-02-07.
//

import SwiftUI
import Defaults

struct OSDIconView: View {
    var eventType: SneakContentType
    var icon: String
    var value: CGFloat
    var accent: Color?

    var body: some View {
        switch eventType {
        case .volume:
            // 显式 icon 优先；否则按当前输出机型选图标（AirPods / 头戴 / 扬声器）。
            // MainActor（SwiftUI body）下调用，才能读 @MainActor 的外设管理器。
            Image(systemName: icon.isEmpty ? AudioOutputRouteResolver.shared.volumeSymbolForCurrentOutput(value: value) : icon)
                .contentTransition(.interpolate)
                .opacity(value.isZero ? 0.6 : 1)
                .scaleEffect(value.isZero ? 0.85 : 1)
                .frame(width: 20, height: 15, alignment: .leading)
        case .brightness:
            let symbol = icon.isEmpty ? brightnessSymbolName(value) : icon
            Image(systemName: symbol)
                .contentTransition(.interpolate)
                .frame(width: 20, height: 15)
                .foregroundColor(accent ?? .white)
        case .backlight:
            Image(systemName: value > 0.5 ? "light.max" : "light.min")
                .contentTransition(.interpolate)
                .frame(width: 20, height: 15)
                .foregroundStyle(.white)
        case .mic:
            Image(systemName: "mic")
                .symbolVariant(value > 0 ? .none : .slash)
                .contentTransition(.interpolate)
                .frame(width: 20, height: 15)
                .foregroundStyle(.white)
        default:
            EmptyView()
        }
    }

private func brightnessSymbolName(_ value: CGFloat) -> String {
         return value < 0.3 ? "sun.min.fill" : "sun.max.fill"
    }
}
