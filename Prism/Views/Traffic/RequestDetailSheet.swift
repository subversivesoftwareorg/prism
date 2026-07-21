import SwiftUI

struct RequestDetailSheet: View {
    let request: ProxyRequest
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .long
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection
                    if !request.requestHeaders.isEmpty {
                        headersSection
                    }
                    transferSection
                }
                .padding()
            }
        }
        .frame(width: 550, height: 450)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(request.method) \(request.host)")
                    .font(.headline)
                if let path = request.path {
                    Text(path)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Connection

    private var connectionSection: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Host", value: request.host)
                DetailRow(label: "Port", value: String(request.port))
                DetailRow(label: "Method", value: request.method)
                DetailRow(label: "Encrypted", value: request.isEncrypted ? "Yes (HTTPS)" : "No (HTTP)")
                DetailRow(label: "Time", value: Self.dateFormatter.string(from: request.timestamp))
                if let status = request.responseStatus {
                    DetailRow(label: "Status", value: "\(status)")
                }
                if let duration = request.duration {
                    DetailRow(label: "Duration", value: String(format: "%.1fms", duration * 1000))
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Headers

    private var headersSection: some View {
        GroupBox("Request Headers") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(request.requestHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top) {
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                            .frame(minWidth: 120, alignment: .trailing)
                        Text(value)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Transfer

    private var transferSection: some View {
        GroupBox("Data Transfer") {
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Bytes In", value: request.bytesIn.formattedBytes)
                DetailRow(label: "Bytes Out", value: request.bytesOut.formattedBytes)
                DetailRow(label: "Total", value: (request.bytesIn + request.bytesOut).formattedBytes)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }
}
