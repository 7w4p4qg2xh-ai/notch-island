//
//  NotchUIEvent.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Created as part of the architecture remediation.
//

import SwiftUI
import Combine

/// UI-presentation events emitted by hardware/OS-facing managers.
///
/// Inverts the old "manager calls `BoringViewCoordinator.shared`" direction:
/// the coordinator also *configures* those same managers (applyOSDSources),
/// so direct calls created a dependency cycle. Managers now publish events;
/// the coordinator is the single subscriber and decides what to present.
/// Presentation policy (e.g. `Defaults[.osdReplacement]`) lives on the
/// presenter side, and managers stay testable without the UI stack.
enum NotchUIEvent {
    case sneakPeek(
        type: SneakContentType,
        value: CGFloat,
        icon: String = "",
        accent: Color? = nil,
        targetScreenUUID: String? = nil,
        duration: TimeInterval = 1.5
    )
    case expandingView(type: SneakContentType)
}

/// The event pipe. `BoringViewCoordinator` is the intended subscriber.
///
/// An object holding the subject (instead of a bare global `PassthroughSubject`)
/// so tests can exercise the same publish/subscribe seam on a private pipe: the
/// test target runs inside the host app via `TEST_HOST`, whose managers publish
/// volume/battery/music events on the shared pipe and whose coordinator
/// consumes everything sent to it.
final class NotchUIEventBus: @unchecked Sendable {
    static let shared = NotchUIEventBus()

    let events = PassthroughSubject<NotchUIEvent, Never>()

    init() {}

    /// App-wide pipe: managers publish, the coordinator subscribes.
    static var events: PassthroughSubject<NotchUIEvent, Never> { shared.events }
}
