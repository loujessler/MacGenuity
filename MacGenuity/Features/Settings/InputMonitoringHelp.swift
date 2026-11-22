import SwiftUI

struct InputMonitoringHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow MacGenuity in Privacy & Security → Input Monitoring, then relaunch the app.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings…", action: HIDPermission.openSystemSettings)
                Button("Relaunch") { AppRelauncher.relaunch() }
            }
            DisclosureGroup("Already enabled?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If access still fails after relaunching, reset the old entry and grant access to the updated app.")
                    Button("Reset Access & Relaunch") { AppRelauncher.relaunch(resetInputMonitoring: true) }
                }
                .padding(.top, 4)
            }
        }
        .controlSize(.small)
    }

    @MainActor private static var helpWindow: NSWindow?

    @MainActor
    static func show(for model: DeviceViewModel) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        helpWindow = window
        window.title = "Input Monitoring"
        let content = InputMonitoringHelp()
            .padding(18)
            .frame(width: 370, alignment: .leading)
            .onReceive(model.$status) { [weak window] status in
                if status != .permissionRequired { window?.close() }
            }
        window.contentViewController = NSHostingController(rootView: content)
        window.center()
        // Keep the native authorization prompt in front when it is pending.
        if model.accessState == .unknown {
            window.orderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
