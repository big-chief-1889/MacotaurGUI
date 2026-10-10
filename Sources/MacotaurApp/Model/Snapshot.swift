import AppKit
import SwiftUI

/// Offscreen, borderless, never shown on screen.
final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// `--snapshot OUT SECS`: waits SECS, renders the catalog (with `--demo`) to
/// OUT-stem-<name>.png, prints each path, then the app quits. Without
/// `--demo` it renders the live model (read-only) as dashboard-live-light/dark.
///
/// Rendering: an offscreen NSHostingView + cacheDisplay draws Form controls
/// and ScrollView contents; system controls draw in their inactive-window
/// style. Never override the control active state in the environment: it
/// blanks the whole render.
@MainActor enum SnapshotRunner {
    enum Screen {
        case dashboard
        case settings(SettingsTab)
    }

    struct Job {
        var name: String
        var scenario: DemoScenario
        var screen: Screen
        var scheme: ColorScheme = .light
        var configure: @MainActor (MiningModel) -> Void = { _ in }
    }

    static func catalog() -> [Job] {
        func s(_ p: DemoProfile, _ st: DemoState) -> DemoScenario { DemoScenario(profile: p, state: st) }
        var jobs: [Job] = [
            Job(name: "dashboard-pro-mining-light", scenario: s(.pro, .mining), screen: .dashboard),
            Job(name: "dashboard-pro-mining-dark", scenario: s(.pro, .mining), screen: .dashboard, scheme: .dark),
            Job(name: "dashboard-pro-log-light", scenario: s(.pro, .mining), screen: .dashboard,
                configure: { $0.ui.activityExpanded = true }),
            Job(name: "dashboard-pro-stopped-light", scenario: s(.pro, .stopped), screen: .dashboard),
            Job(name: "dashboard-firstrun-light", scenario: s(.pro, .firstRun), screen: .dashboard),
            Job(name: "dashboard-pro-failed-light", scenario: s(.pro, .failed), screen: .dashboard),
            Job(name: "dashboard-pro-luckypool-light", scenario: s(.pro, .luckyPool), screen: .dashboard),
            Job(name: "dashboard-pro-preparing-light", scenario: s(.pro, .preparing), screen: .dashboard),
            Job(name: "dashboard-pro-reconnecting-dark", scenario: s(.pro, .reconnecting), screen: .dashboard, scheme: .dark),
        ]
        for tab in SettingsTab.allCases {
            jobs.append(Job(name: "settings-\(tab.rawValue)-light", scenario: s(.pro, .mining), screen: .settings(tab)))
        }
        return jobs
    }

    static func run(_ options: LaunchOptions) async {
        guard let snapshot = options.snapshot else { return }
        try? await Task.sleep(for: .seconds(snapshot.delay))
        let dir = snapshot.base.deletingLastPathComponent()
        let stem = snapshot.base.deletingPathExtension().lastPathComponent
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written = 0

        if options.demo == nil {
            // The live model, read-only.
            for scheme in [ColorScheme.light, .dark] {
                let name = "dashboard-live-\(scheme == .dark ? "dark" : "light")"
                if let f = options.snapshotFilter, !name.contains(f) { continue }
                let view = DashboardView().environment(MiningModel.shared)
                if await write(view, width: DashboardView.width, scheme: scheme, to: dir.appending(path: "\(stem)-\(name).png")) { written += 1 }
            }
            print("snapshot: wrote \(written) files")
            return
        }

        for job in catalog() {
            if let f = options.snapshotFilter, !job.name.contains(f) { continue }
            let url = dir.appending(path: "\(stem)-\(job.name).png")
            let model = MiningModel(demo: job.scenario)
            job.configure(model)
            let ok: Bool
            switch job.screen {
            case .dashboard:
                ok = await write(DashboardView().environment(model), width: DashboardView.width, scheme: job.scheme, to: url)
            case .settings(let tab):
                ok = await write(SettingsPane(tab: tab).environment(model), width: SettingsView.width, scheme: job.scheme, to: url)
            }
            if ok { written += 1 }
        }
        print("snapshot: wrote \(written) files")
    }

    /// Renders `content` at `width` (natural height) and writes a PNG (2× on Retina).
    static func write<V: View>(_ content: V, width: CGFloat, scheme: ColorScheme, to url: URL) async -> Bool {
        let root = content
            .environment(\.isSnapshot, true)
            .environment(\.colorScheme, scheme)
            .tint(Theme.accent)
            .frame(width: width)
            .background(Theme.windowBackground)
            .transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: root)
        let win = SnapshotWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 400),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.contentView = host
        func fit() {
            let size = host.fittingSize
            let h = max(1, size.height)
            host.frame = NSRect(x: 0, y: 0, width: width, height: h)
            win.setContentSize(NSSize(width: width, height: h))
            win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        }
        fit()
        win.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.5))
        fit()
        try? await Task.sleep(for: .seconds(0.3))
        defer { win.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return false }
        print(url.path)
        return true
    }
}
