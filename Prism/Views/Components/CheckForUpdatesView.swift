import SwiftUI
import Combine
import Sparkle

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates\u{2026}", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

// ObservableObject required here — Sparkle's SPUUpdater uses Combine KVO.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
