import SwiftUI

struct PoolPane: View {
    @Environment(MiningModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Pool", selection: $model.preset) {
                    ForEach(MiningModel.PoolPreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(model.preset.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                switch model.preset {
                case .kryptex:
                    Picker("Server", selection: $model.kryptexRegion) {
                        ForEach(MiningModel.KryptexRegion.allCases) { Text($0.title).tag($0) }
                    }
                    endpointRows
                case .luckyPool:
                    endpointRows
                case .custom:
                    TextField("Host", text: $model.customHost, prompt: Text("pool.example.com"))
                    TextField("Port", text: $model.customPort, prompt: Text("3333"))
                    TextField("Login separator", text: $model.customSeparator, prompt: Text("."))
                    if model.endpoint == nil {
                        SettingsStatusRow(symbol: "exclamationmark.circle", tint: Theme.caution,
                                          text: "Enter a host and a port number.")
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                if model.preset != .kryptex || model.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.preset != .kryptex { SettingsFooter(Copy.otherPoolFooter) }
                        if model.isRunning { SettingsRestartNote() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var endpointRows: some View {
        if let e = model.endpoint {
            LabeledContent("Address") {
                Text(verbatim: "\(e.host):\(e.port)").font(.callout.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Login") {
                Text(verbatim: "wallet\(e.separator)\(model.workerName)").font(.callout.monospaced())
            }
        }
    }
}
