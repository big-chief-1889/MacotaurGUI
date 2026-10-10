import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var tab = SettingsTab.mining

    static let width: CGFloat = 560

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    // The window takes each pane's natural height, but on a
                    // small display a long pane scrolls instead of running
                    // off the bottom of the screen.
                    ScrollView { SettingsPane(tab: tab).scrollDisabled(true) }
                        .frame(maxHeight: Self.maxPaneHeight)
                }
            }
        }
        .frame(width: Self.width)
        .reportsVisibility(.settings)
    }

    /// The screen's usable height less the title bar and tab toolbar.
    private static var maxPaneHeight: CGFloat {
        max(360, (NSScreen.main?.visibleFrame.height ?? 800) - 120)
    }
}

/// One settings tab as a grouped Form at its natural height. The snapshot
/// runner renders it directly, so it must not rely on the TabView.
struct SettingsPane: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .mining: MiningPane()
            case .pool: PoolPane()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
    }
}
