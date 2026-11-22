import AppKit

@MainActor
enum AppRelauncher {
    private static var inProgress = false

    static func relaunch(resetInputMonitoring: Bool = false) {
        guard !inProgress else { return }
        inProgress = true
        do {
            if resetInputMonitoring {
                guard let identifier = Bundle.main.bundleIdentifier else { throw CocoaError(.fileNoSuchFile) }
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", "ListenEvent", identifier]
                reset.terminationHandler = { process in
                    Task { @MainActor in
                        guard process.terminationStatus == 0 else {
                            reportFailure("macOS could not reset Input Monitoring. Open System Settings and remove the old MacGenuity entry.")
                            return
                        }
                        do { try restartAfterExit() }
                        catch { reportFailure(error.localizedDescription) }
                    }
                }
                try reset.run()
            } else {
                try restartAfterExit()
            }
        } catch {
            reportFailure(error.localizedDescription)
        }
    }

    private static func restartAfterExit() throws {
        guard let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Wait for this PID to disappear before Launch Services starts the
        // replacement. The single-instance check must never see both copies.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", """
            while kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
            /usr/bin/open -n "$2" || exec "$3"
            """, "macgenuity-relaunch", String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path, executable.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        // AppKit can wait for a termination reply in a nested run loop.
        // Leave the main dispatch queue free to deliver that reply.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
    }

    private static func reportFailure(_ message: String) {
        inProgress = false
        FileLogger.shared.error(.app, "Relaunch failed: \(message)")
        let alert = NSAlert()
        alert.messageText = "Couldn’t relaunch MacGenuity"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
