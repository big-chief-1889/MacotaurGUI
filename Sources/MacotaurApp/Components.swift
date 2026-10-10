import SwiftUI

extension EnvironmentValues {
    /// Rendering offscreen for --snapshot: no animation, and the dashboard draws its own toolbar row.
    @Entry var isSnapshot = false
}

extension View {
    /// Captures openWindow into the model, for Window > Dashboard and reopening from the Dock.
    func installsNavigation() -> some View { modifier(InstallsNavigation()) }

    /// model.noteVisible(surface, …) on appear/disappear.
    func reportsVisibility(_ surface: UISurface) -> some View { modifier(ReportsVisibility(surface: surface)) }
}

private struct InstallsNavigation: ViewModifier {
    @Environment(MiningModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { model.installNavigation(openWindow: openWindow) }
    }
}

private struct ReportsVisibility: ViewModifier {
    var surface: UISurface
    @Environment(MiningModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onAppear { model.noteVisible(surface, true) }
            .onDisappear { model.noteVisible(surface, false) }
    }
}
