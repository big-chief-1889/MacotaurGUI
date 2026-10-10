import Foundation

/// Command-line flags.
///
///   --demo [air|pro|mini|studio|m1]   sample data, nothing real (default pro)
///   --snapshot OUT SECS              render the snapshot catalog to OUT-stem-<name>.png, then quit
///   --snapshot-only SUBSTR           only catalog entries whose name contains SUBSTR
///   --start                          developer only: start mining at launch (ignored with --demo/--snapshot)
///   --power-debug                    print the telemetry sources found, then quit
struct LaunchOptions: Sendable {
    static let current = LaunchOptions(arguments: CommandLine.arguments)

    var demo: DemoProfile?
    var snapshot: (base: URL, delay: Double)?
    var snapshotFilter: String?
    var startAtLaunch: Bool
    var powerDebug: Bool
    var isSnapshot: Bool { snapshot != nil }

    init(arguments args: [String]) {
        demo = nil
        if let i = args.firstIndex(of: "--demo") {
            let next = i + 1 < args.count ? args[i + 1] : ""
            demo = DemoProfile(rawValue: next) ?? .pro
        }
        snapshot = nil
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let delay = i + 2 < args.count ? Double(args[i + 2]) ?? 1 : 1
            snapshot = (URL(fileURLWithPath: args[i + 1]), max(0, delay))
        }
        snapshotFilter = args.firstIndex(of: "--snapshot-only").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        powerDebug = args.contains("--power-debug")
        startAtLaunch = args.contains("--start") && demo == nil && snapshot == nil && !powerDebug
    }
}

/// What a model may touch. Live mining gets everything; demo and snapshot
/// runs get memory-only stores and no networking, telemetry, monitors, GPU
/// or sleep assertions.
struct AppEnvironment {
    var isDemo: Bool
    var store: PreferenceStore
    var historyURL: URL?                            // nil: memory only
    var statsURL: URL?
    var activityLogURL: URL?                        // nil: no file
    var networking: Bool                            // Kryptex
    var urlSession = URLSession.shared              // for Kryptex (tests stub it)
    var systemMonitors: Bool                        // the thermal state observer
    var telemetry: Bool                             // IOReport / SMC
    var canMine: Bool                               // real MetalSolver + Miner
    var keepAwake: Bool
    var isReadOnly = false                          // a snapshot of the live model

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Macotaur")
    }
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Macotaur")
    }

    /// The real app. `readOnly` (a snapshot of the live model): settings are
    /// copied into memory and nothing is written or started.
    static func live(readOnly: Bool) -> AppEnvironment {
        if readOnly {
            return AppEnvironment(isDemo: false, store: MemoryStore(seed: DefaultsStore().snapshot()), historyURL: nil,
                                  statsURL: nil, activityLogURL: nil, networking: false, systemMonitors: false,
                                  telemetry: true, canMine: false, keepAwake: false, isReadOnly: true)
        }
        return AppEnvironment(isDemo: false, store: DefaultsStore(),
                              historyURL: supportDirectory.appending(path: "history-v1.json"),
                              statsURL: supportDirectory.appending(path: "stats-v1.json"),
                              activityLogURL: logDirectory.appending(path: "activity.log"),
                              networking: true, systemMonitors: true, telemetry: true, canMine: true, keepAwake: true)
    }

    static func demo() -> AppEnvironment {
        AppEnvironment(isDemo: true, store: MemoryStore(), historyURL: nil, statsURL: nil, activityLogURL: nil,
                       networking: false, systemMonitors: false, telemetry: false, canMine: false, keepAwake: false)
    }
}
