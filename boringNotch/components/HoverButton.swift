//
//  HoverButton.swift
//  boringNotch
//
//  Created by Kraigo on 04.09.2024.
//

import SwiftUI

/// 按下反馈。HIG 第一条「按下即反馈，不等松手」：原实现只有 hover 变色，
/// 鼠标按住到松手之间界面完全不动。SwiftUI 的 `PlainButtonStyle` 拿不到
/// `isPressed`，所以用一个最小 ButtonStyle 把它接出来。
/// 参数按 2026-11-24 审查结论：缩放到 0.96（不是 0.9），临界阻尼不弹跳，
/// 按下 0.22s 响应、松开 0.22s 淡出。
private struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(Color.gray.opacity(configuration.isPressed ? 0.28 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(
                configuration.isPressed ? StandardAnimations.press : StandardAnimations.fade,
                value: configuration.isPressed
            )
    }
}

struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect

    @State private var isHovering = false

    var body: some View {
        let size = CGFloat(scale == .large ? 40 : 30)

        Button(action: action) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: size, height: size)
                .overlay {
                    Capsule()
                        .fill(isHovering ? Color.gray.opacity(0.2) : .clear)
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: icon)
                                .foregroundColor(iconColor)
                                .contentTransition(contentTransition)
                                .font(scale == .large ? .largeTitle : .body)
                        }
                }
        }
        .buttonStyle(HoverIconButtonStyle())
        .onHover { hovering in
            withAnimation(StandardAnimations.fade) {
                isHovering = hovering
            }
        }
    }
}
