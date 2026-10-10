import Foundation

// Fixed user-facing strings. Copy never names a Mac model and never says
// whether it has a fan.

enum Copy {
    static let powerHelp = "How much of the time the GPU works. Lower runs cooler and uses less power."
    static let thermalHelp = "How hot macOS says this Mac is. When a Mac gets hot, macOS lowers its clock speeds, which slows mining. Turning Power down lets it cool."
    static let restartNote = "Wallet, worker and pool changes apply the next time mining starts."
    static let kryptexSummary = "1% fee, pays out at 200 XTM. Macotaur shows the time to your next payout."
    static let otherPoolFooter = "Payout progress is shown for Kryptex only. The XTM-a-day estimate uses public network figures from Kryptex (no wallet is sent) and doesn't include your pool's fee."
    static let walletEmpty = "No wallet yet. Mining can't start without one."
    static let walletValid = "Looks like a Tari address"
}

// MARK: Heat

extension HeatLevel {
    var title: String {
        switch self {
        case .normal: "Normal"
        case .warm: "Warm"
        case .hot: "Hot"
        case .veryHot: "Very hot"
        }
    }
}

// MARK: Settings

extension SettingsTab {
    var title: String {
        switch self {
        case .mining: "Mining"
        case .pool: "Pool"
        }
    }

    var symbol: String {
        switch self {
        case .mining: "hammer"
        case .pool: "network"
        }
    }
}

// MARK: Problems

extension MiningModel.Problem {
    /// The solver's buffers couldn't be allocated.
    static func memory(bytes: UInt64) -> Self {
        .init(title: "Couldn't start",
              detail: "Macotaur needs about \(Format.bytes(bytes)) of GPU memory and macOS couldn't reserve it. Quit some apps and try again.")
    }

    static func setup(_ error: Error) -> Self {
        .init(title: "Couldn't start", detail: "The GPU couldn't be set up (\(error)). Try again, or restart your Mac if it keeps happening.")
    }

    static let loginRejected = Self(title: "The pool rejected the login",
                                    detail: "The pool rejected the wallet/worker login 3 times. Check your wallet address in Settings.")
}
