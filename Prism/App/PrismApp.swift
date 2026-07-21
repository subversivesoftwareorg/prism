import SwiftUI
import Sparkle

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Prism") {
                    appDelegate.showAboutPanel(nil)
                }
            }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
