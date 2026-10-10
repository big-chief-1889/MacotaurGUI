import AppKit
import SwiftUI

/// Snapshot and --power-debug runs never start the SwiftUI app: with no scene
/// or window, AppKit writes nothing to UserDefaults.
@main
enum MacotaurMain {
    @MainActor static func main() {
        let options = LaunchOptions.current
        if options.isSnapshot || options.powerDebug {
            HeadlessDelegate.run(options)
        } else {
            MacotaurApp.main()
        }
    }
}

struct MacotaurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = MiningModel.shared

    var body: some Scene {
        Window("Macotaur", id: "dashboard") {
            DashboardView()
                .installsNavigation()
                .environment(model)
                .tint(Theme.accent)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SettingsLink { Label("Settings", systemImage: "gearshape") }
                    }
                }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
        .commands { MiningCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .tint(Theme.accent)
        }
    }
}

/// Launch and quit. Closing the window quits the app, which stops mining first.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.current
        if options.demo != nil { Self.keepDemoWindowsOutOfDefaults() }
        if options.startAtLaunch { MiningModel.shared.start() }
    }

    /// Interactive --demo writes nothing to UserDefaults: window frames are
    /// not autosaved (AppKit would store "NSWindow Frame …").
    private static func keepDemoWindowsOutOfDefaults() {
        clearFrameAutosave()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { clearFrameAutosave() }
            }
        }
    }

    private static func clearFrameAutosave() {
        for w in NSApp.windows where !w.frameAutosaveName.isEmpty { w.setFrameAutosaveName("") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MiningModel.shared.showDashboard() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = MiningModel.shared
        if model.isDemo { return .terminateNow }
        guard model.hasActiveSession else {
            model.saveStores()
            return .terminateNow
        }
        model.prepareToQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// The app delegate for snapshot and --power-debug runs (no SwiftUI scenes).
@MainActor final class HeadlessDelegate: NSObject, NSApplicationDelegate {
    private static var current: HeadlessDelegate?
    let options: LaunchOptions

    init(options: LaunchOptions) { self.options = options }

    static func run(_ options: LaunchOptions) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)        // no Dock icon
        let d = HeadlessDelegate(options: options)
        current = d
        app.delegate = d
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if options.powerDebug {
            Self.printPowerDebug()
            return
        }
        Task { @MainActor in
            await SnapshotRunner.run(options)
            NSApp.terminate(nil)
        }
    }

    /// `--power-debug`: the telemetry sources this Mac has, and two samples.
    private static func printPowerDebug() {
        DispatchQueue.global(qos: .utility).async {
            let m = PowerMonitor()
            print("power-debug: \(m.debugDescription)")
            print("power-debug: capabilities \(m.capabilities.names.joined(separator: ", "))")
            _ = m.sample()
            for _ in 0..<2 {
                Thread.sleep(forTimeInterval: 2)
                let s = m.sample()
                func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
                print("power-debug: \(String(format: "%.2f", s.interval)) s · GPU \(f(s.gpuWatts)) W · busy \(f(s.gpuBusy)) · \(f(s.gpuMHz)) of \(f(s.gpuMaxMHz)) MHz · DRAM \(f(s.dramGBps)) GB/s · system \(f(s.systemWatts)) W · process \(f(s.processWatts)) W · fans \(s.fanCount.map(String.init) ?? "unknown") \(s.fanRPM)")
            }
            let fans = PowerMonitor.fanCount()
            print("power-debug: SMC fan count \(fans.map(String.init) ?? "unknown")")
            // The meter's own cost: CPU time per sample (the app samples every 2 s at most).
            let clock = ContinuousClock()
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let cpu0 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            let wall = clock.measure { for _ in 0..<50 { _ = m.sample() } }
            getrusage(RUSAGE_SELF, &usage)
            let cpu1 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            let perSample = (cpu1 - cpu0) / 50
            print(String(format: "power-debug: %.2f ms CPU per sample (%.3f%% of one core at one sample every 2 s); wall %@ for 50",
                         perSample * 1000, perSample / 2 * 100, "\(wall)"))
            exit(0)
        }
    }
}

/// The Mining menu and Window ▸ Dashboard.
struct MiningCommands: Commands {
    let model: MiningModel

    var body: some Commands {
        CommandMenu("Mining") {
            if model.hasActiveSession {
                Button("Stop Mining") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.status == .stopping)
            } else {
                Button("Start Mining") { model.start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canStart)
            }
            Divider()
            Button("Refresh Earnings") { Task { await model.refreshEarnings() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(before: .windowList) {
            Button("Dashboard") { model.showDashboard() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
