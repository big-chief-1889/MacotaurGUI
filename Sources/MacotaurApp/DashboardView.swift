import AppKit
import SwiftUI

/// The whole window: a short list of readings and one button.
struct DashboardView: View {
    @Environment(MiningModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    static let width: CGFloat = 320

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                if !model.hasWallet { WalletSection() }
                Section {
                    reading("Speed", "speedometer", speed, help: model.speedCaption)
                    reading("Shares", "checkmark.seal", "\(model.today.accepted)", help: model.sharesFigure.help)
                    if let balance = model.poolBalance {
                        reading("Balance", "wallet.pass", balance.text, help: balance.help)
                    }
                    if let payout = model.payoutFigure {
                        reading("Payout", "clock", payout.text, help: payout.help)
                    }
                    reading("GPU", "cpu", gpu, help: gpuHelp)
                    reading("Heat", "thermometer.medium", model.heat.title, help: Copy.thermalHelp,
                            color: model.heat == .normal ? .primary : model.heat.color)
                    PowerRow()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.isFailed ? model.speedCaption : model.windowSubtitle)
                        .foregroundStyle(model.isFailed ? Theme.danger : Color.secondary)
                        .lineLimit(model.isFailed ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Toggle(isOn: $model.ui.activityExpanded) {
                        Text(model.ui.activityExpanded ? "Hide Log" : "Show Log")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentText)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 2)
                ActionButton()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            if model.ui.activityExpanded {
                Divider()
                LogPane()
            }
        }
        .frame(width: Self.width)
        .reportsVisibility(.dashboard)
    }

    private func reading(_ title: String, _ symbol: String, _ value: String, help: String, color: Color = .primary) -> some View {
        LabeledContent {
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        } label: {
            Label(title, systemImage: symbol)
        }
        .help(help)
    }

    /// "5.18 g/s", or a dash when there is no speed to show.
    private var speed: String {
        let text = model.speedText
        return text.first?.isNumber == true ? "\(text) g/s" : text
    }

    private var gpu: String {
        let p = model.power
        guard model.status == .mining else { return "—" }
        let parts = [p.gpuWatts.map(Format.watts), p.gpuMHz.map(Format.mhz)].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var gpuHelp: String {
        var parts: [String] = []
        if model.status == .mining, let j = model.power.joulesPerGraph { parts.append("\(Format.joules(j)) per graph") }
        switch model.gpuMemory {
        case .released: parts.append("no GPU memory in use")
        case .reserving(let b): parts.append("reserving \(Format.bytes(b)) of GPU memory")
        case .inUse(let b): parts.append("\(Format.bytes(b)) of GPU memory in use")
        }
        return parts.joined(separator: " · ")
    }
}

/// How much of the time the GPU works, on a slider.
private struct PowerRow: View {
    @Environment(MiningModel.self) private var model
    /// Where the knob was let go. It moves freely; the setting follows in steps of 5.
    @State private var knob: Double?

    var body: some View {
        HStack(spacing: 10) {
            Label("Power", systemImage: "bolt")
            Slider(value: position, in: 10...100) { Text("Power") }
                .labelsHidden()
                .accessibilityValue("\(model.intensity)%")
            // As wide as the widest value, so the slider keeps its length.
            Text(verbatim: "100%")
                .hidden()
                .overlay(alignment: .trailing) { Text(verbatim: "\(model.intensity)%") }
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .help(Copy.powerHelp)
    }

    private var position: Binding<Double> {
        Binding {
            // Unless the setting has moved on since.
            if let knob, MiningModel.intensity(nearest: Int(knob.rounded())) == model.intensity { return knob }
            return Double(model.intensity)
        } set: {
            knob = $0
            model.intensity = Int($0.rounded())
        }
    }
}

/// The one action that fits the current state.
private struct ActionButton: View {
    @Environment(MiningModel.self) private var model

    var body: some View {
        Group {
            switch model.status {
            case .stopped:
                Button { model.start() } label: { Text("Start Mining").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
            case .preparingGPU, .connecting:
                Button { model.stop() } label: { Text("Cancel").frame(maxWidth: .infinity) }
            case .mining, .reconnecting:
                Button { model.stop() } label: { Text("Stop Mining").frame(maxWidth: .infinity) }
            case .stopping:
                Button {} label: { Text("Stopping…").frame(maxWidth: .infinity) }
                    .disabled(true)
            case .failed:
                Button { model.retry() } label: { Text("Try Again").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }
}

/// Shown above the readings until there is a wallet to mine to.
private struct WalletSection: View {
    @Environment(MiningModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            HStack(spacing: 8) {
                TextField("Wallet", text: $model.wallet, prompt: Text("Paste your Tari address"))
                    .labelsHidden()
                Button("Paste") {
                    guard let s = NSPasteboard.general.string(forType: .string) else { return }
                    model.wallet = s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } footer: {
            Group {
                if case .suspicious(let why) = model.walletCheck {
                    Text(why).foregroundStyle(Theme.caution)
                } else {
                    Text("The pool pays rewards to this address. Pool: \(model.poolLabel).")
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The newest activity first, as plain lines.
private struct LogPane: View {
    @Environment(MiningModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(model.activity.suffix(200).reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.clock(entry.time))
                            .foregroundStyle(.tertiary)
                        Text(entry.text)
                            .foregroundStyle(entry.kind.isProblem ? Theme.danger : Color.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(height: 132)
    }
}
