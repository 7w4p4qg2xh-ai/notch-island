//
//  Button+Bouncing.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
import SwiftUI
import Defaults

struct BouncingButtonStyle: ButtonStyle {
    let vm: BoringViewModel
    @State private var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                    .strokeBorder(.white.opacity(0.04), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .onChange(of: configuration.isPressed) { _, _ in
                // 2026-11-24 审查：按压反馈不允许过冲。原参数
                // dampingFraction 0.3 + scale 0.9 会明显回弹，改成临界阻尼、
                // 0.97 的浅缩放（与 HoverIconButtonStyle 同口径）。
                withAnimation(StandardAnimations.press) {
                    isPressed.toggle()
                }
            }
    }
}

extension Button {
    func bouncingStyle(vm: BoringViewModel) -> some View {
        self.buttonStyle(BouncingButtonStyle(vm: vm))
    }
}
