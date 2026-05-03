//
//  MacGenuityApp.swift
//  MacGenuity
//

import SwiftUI

@main
struct MacGenuityApp: App {
    @StateObject private var viewModel: DeviceViewModel
    @StateObject private var settings: AppSettings
    @StateObject private var presetStore: PresetStore
    @StateObject private var history: BatteryHistory
    @StateObject private var deviceStates: DeviceStateStore

    init() {
        // Install the Dock-policy watcher early so the very first window
        // open / close transition is observed.
        DockPolicyManager.shared.install()

        let settings = AppSettings()
        let history = BatteryHistory()
        let presetStore = PresetStore()
        let deviceStates = DeviceStateStore()
        let viewModel = DeviceViewModel(
            history: history,
            presetStore: presetStore,
            deviceStates: deviceStates
        )
        viewModel.attach(settings: settings)

        _viewModel = StateObject(wrappedValue: viewModel)
        _settings = StateObject(wrappedValue: settings)
        _presetStore = StateObject(wrappedValue: presetStore)
        _history = StateObject(wrappedValue: history)
        _deviceStates = StateObject(wrappedValue: deviceStates)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                viewModel: viewModel,
                settings: settings,
                presetStore: presetStore,
                history: history
            )
            .task {
                viewModel.setPollInterval(settings.refreshInterval)
                settings.refreshLaunchAtLoginStatus()
                viewModel.refreshAccessState()
                viewModel.start()
                await viewModel.refresh()
            }
            .onChange(of: settings.refreshInterval) { interval in
                viewModel.setPollInterval(interval)
            }
        } label: {
            MenuBarLabel(viewModel: viewModel, settings: settings)
        }
        .menuBarExtraStyle(.window)

        // Settings — explicit Window instead of `Settings { }` because:
        //   • This app has `LSUIElement = true` (no Dock icon, no app menu),
        //     so the system "Settings…" item that `Settings { }` registers
        //     is never reachable.
        //   • `NSApp.sendAction(Selector(("showSettingsWindow:")))` from a
        //     MenuBarExtra was unreliable (action dispatched while the
        //     menu was collapsing → no responder found → silent no-op).
        // openWindow(id: "settings") is bulletproof in both macOS 13 and 14+.
        Window("MacGenuity Settings", id: "settings") {
            SettingsScene(
                settings: settings,
                viewModel: viewModel,
                presetStore: presetStore
            )
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsWindow(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
