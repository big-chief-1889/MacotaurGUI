import Foundation
import MacotaurCore

// What the model hands the views.

/// macOS's thermal state in Macotaur's words; titles in Copy.swift, color in Theme.
enum HeatLevel: Int, Comparable {
    case normal, warm, hot, veryHot
    static func < (a: HeatLevel, b: HeatLevel) -> Bool { a.rawValue < b.rawValue }

    init(_ t: ProcessInfo.ThermalState) {
        switch t {
        case .nominal: self = .normal
        case .fair: self = .warm
        case .serious: self = .hot
        case .critical: self = .veryHot
        @unknown default: self = .normal
        }
    }
}

/// One earnings figure on the status line, with its tooltip.
struct Figure: Equatable {
    var text: String
    var help: String
}

struct PayoutEvent: Equatable { var amount: Double; var date: Date }

/// The GPU readings on the status line (nil where this Mac reports none, and
/// while not mining).
struct PowerReadout: Equatable {
    var gpuWatts: Double?
    var gpuMHz: Double?
    var joulesPerGraph: Double?
}

/// Reserved while a session runs, given back on Stop.
enum GPUMemoryState: Equatable { case released, reserving(UInt64), inUse(UInt64) }

struct SessionStats: Equatable {
    var startedAt: Date
    var miningSeconds = 0.0
    var graphs = 0
    var accepted = 0
    var rejected = 0
    var job: Stratum.Job?
}

extension ActivityKind {
    /// Drawn in red in the log.
    var isProblem: Bool {
        switch self {
        case .shareRejected, .loginFailed, .problem: true
        default: false
        }
    }
}
