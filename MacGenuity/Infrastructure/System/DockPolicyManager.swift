//
//  DockPolicyManager.swift
//  MacGenuity
//
//  Toggles `NSApp.setActivationPolicy` between `.accessory` (no Dock
//  icon, menu-bar-only) and `.regular` (Dock icon + Cmd-Tab) based on
//  whether any user-facing window is open.
//
//  Implementation notes:
//    • Plain `final class` instead of `@MainActor enum`. The latter
//      crashed at launch because static @MainActor state + `@Sendable`
//      observer closures triggered a Swift runtime check.
//    • Callbacks are scheduled on `OperationQueue.main`, so they always
//      arrive on the main thread — direct calls to NSApp/NSApplication
//      from the closures are safe without any actor hop.
//    • The initial `setActivationPolicy(.accessory)` is deferred to the
//      next main-runloop tick. Calling it during SwiftUI App.init() is
//      legal but happens before NSApplication is fully constructed,
//      which has produced inconsistent behaviour on some macOS builds.
//

import AppKit

final class DockPolicyManager {
    static let shared = DockPolicyManager()

    private var observers: [NSObjectProtocol] = []
    private var installed = false

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }

        let center = NotificationCenter.default
        let main = OperationQueue.main

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: main
        ) { [weak self] _ in
            self?.update()
        })

        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: main
        ) { [weak self] _ in
            // willCloseNotification fires *before* the window is removed
            // from `NSApp.windows`. Re-check on the next runloop tick.
            DispatchQueue.main.async { [weak self] in
                self?.update()
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: main
        ) { [weak self] _ in
            self?.update()
        })
    }

    /// Counts only "real" user-facing windows. The MenuBarExtra popover
    /// is a panel that returns `canBecomeMain == false`, so it doesn't
    /// count — without this filter the policy would flicker every time
    /// the menu opens.
    private func update() {
        let userVisible = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain
        }
        if userVisible {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
