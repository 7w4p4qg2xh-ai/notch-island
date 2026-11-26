//
//  drop.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import Defaults
import Foundation
import SwiftUI

// MARK: - Standardized Animations
/// Centralized animation definitions for consistent UI behavior across the app.
enum StandardAnimations {
    /// Interactive spring for responsive UI (used for notch interactions)
    static let interactive = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    /// Spring animation for opening the notch
    static var open: Animation {
        guard Defaults[.enableOpeningAnimation] else {
            return Animation.linear(duration: 0)
        }
        return Animation.spring(response: 0.42 / Defaults[.animationSpeedMultiplier], dampingFraction: 0.8, blendDuration: 0)
    }

    /// Spring animation for closing the notch
    static var close: Animation {
        guard Defaults[.enableOpeningAnimation] else {
            return Animation.linear(duration: 0)
        }
        return Animation.spring(response: 0.45 / Defaults[.animationSpeedMultiplier], dampingFraction: 1.0, blendDuration: 0)
    }

    /// Bouncy spring for playful animations
    @available(macOS 14.0, *)
    static var bouncy: Animation {
        Animation.spring(.bouncy(duration: 0.4))
    }

    /// Smooth animation for general transitions
    static let smooth = Animation.smooth

    // MARK: HIG-aligned tokens (2026-11-24 Apple HIG audit · batch 1)
    //
    // 规则来源：《Designing Fluid Interfaces》—— 默认临界阻尼（damping 1.0，
    // response 0.3–0.4）；弹跳（~0.8）只给带动量的手势；纯透明度过渡不允许
    // 过冲。凡是"状态切换"都应该走这三档，不要再手写 easeInOut。

    /// 默认状态切换：临界阻尼，不过冲。用于选中态、开关、滑杆展开。
    static let ui = Animation.spring(response: 0.38, dampingFraction: 1.0, blendDuration: 0)

    /// 位移 / 重排：卡片进出、布局让位、尺寸变化。
    static let move = Animation.spring(response: 0.42, dampingFraction: 1.0, blendDuration: 0)

    /// 纯透明度过渡：裁掉了 0.3–0.4 之外的长尾，只做淡入淡出。
    static let fade = Animation.smooth(duration: 0.22)

    /// 按下反馈：必须短、必须无弹跳（规范第 1 条「按下即反馈」）。
    static let press = Animation.spring(response: 0.22, dampingFraction: 1.0, blendDuration: 0)

    /// 手势反馈：跟手动作的"确认一下"（横向切歌意味着 1.12 缩放这类）。
    /// 允许轻微过冲（0.82），因为背后是用户的手指动量，不是自动播放。
    static let feedback = Animation.spring(response: 0.24, dampingFraction: 0.82, blendDuration: 0)

    /// Timing curve fallback for older macOS versions
    static let timingCurve = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)
}

final class BoringAnimations {
    @Published var notchStyle: Style = .notch

    var animation: Animation {
        if #available(macOS 14.0, *), notchStyle == .notch {
            StandardAnimations.bouncy
        } else {
            StandardAnimations.timingCurve
        }
    }
}
