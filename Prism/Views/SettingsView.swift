import SwiftUI

struct SettingsView: View {
    @AppStorage("proxyPort") private var proxyPort = 9080
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @AppStorage("summaryRetentionDays") private var summaryRetentionDays = 30

    var body: some View {
        Form {
            Section("Proxy") {
                TextField("Port", value: $proxyPort, format: .number)
                    .frame(width: 200)
                    .help("The port Prism listens on. Default: 9080. Requires restart to take effect.")

                Toggle("Start proxy automatically on launch", isOn: $autoStartProxy)
            }

            Section("Data") {
                Picker("Keep summaries for", selection: $summaryRetentionDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(9999)
                }
                .frame(width: 250)
            }

            Section("Browser Configuration") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To route traffic through Prism, configure your browser's HTTP proxy:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            ProxyConfigRow(label: "HTTP Proxy", value: "127.0.0.1")
                            ProxyConfigRow(label: "Port", value: "\(proxyPort)")
                            ProxyConfigRow(label: "HTTPS Proxy", value: "127.0.0.1")
                            ProxyConfigRow(label: "HTTPS Port", value: "\(proxyPort)")
                        }
                        .padding(4)
                    }

                    Text("Or use the \"Enable System Proxy\" button on the Dashboard to configure it system-wide.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 350)
    }
}

struct ProxyConfigRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }
}
