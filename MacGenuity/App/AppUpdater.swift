import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var installsAutomatically = false

    init() {
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checksAutomatically)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$installsAutomatically)
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setInstallsAutomatically(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }
}
