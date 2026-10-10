import AppKit
import SwiftUI

struct MiningPane: View {
    @Environment(MiningModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Wallet") {
                    HStack(spacing: 6) {
                        // Full width whether empty or holding a ~90-character
                        // address, so pasting doesn't reflow the row.
                        TextField("Wallet", text: $model.wallet, prompt: Text("Paste your Tari address"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(minWidth: 200, idealWidth: 340, maxWidth: .infinity)
                        Button {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                model.wallet = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .help("Paste from clipboard")
                    }
                }
                WalletStatus(check: model.walletCheck, wallet: model.walletTrimmed)
                TextField("Worker name", text: $model.worker, prompt: Text("mac"))
            } header: {
                Text("Payout")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsFooter("The pool pays rewards to this address. The worker name tells your machines apart on the pool's stats page.")
                    if model.isRunning { SettingsRestartNote() }
                }
            }
        }
    }
}

private struct WalletStatus: View {
    let check: MiningModel.WalletCheck
    let wallet: String

    var body: some View {
        switch check {
        case .empty:
            SettingsStatusRow(symbol: "exclamationmark.circle", tint: Theme.caution, text: Copy.walletEmpty)
        case .looksValid:
            HStack(spacing: 6) {
                SettingsStatusRow(symbol: "checkmark.circle.fill", tint: Theme.positive, text: Copy.walletValid)
                Spacer()
                Text(verbatim: "\(wallet.prefix(6))…\(wallet.suffix(6))")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .suspicious(let why):
            SettingsStatusRow(symbol: "exclamationmark.triangle.fill", tint: Theme.danger, text: why)
        }
    }
}
