import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LiveTrafficView: View {
    @Environment(ProxyStore.self) private var store
    @State private var searchText = ""
    @State private var filterMethod = "All"
    @State private var showEncryptedOnly = false
    @State private var selectedRequest: ProxyRequest?

    private let methods = ["All", "CONNECT", "GET", "POST", "PUT", "DELETE", "PATCH"]

    private var filteredRequests: [ProxyRequest] {
        var result = store.requests

        if filterMethod != "All" {
            result = result.filter { $0.method == filterMethod }
        }

        if showEncryptedOnly {
            result = result.filter { $0.isEncrypted }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.host.lowercased().contains(query) ||
                ($0.path?.lowercased().contains(query) ?? false)
            }
        }

        return result.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            if store.requests.isEmpty {
                emptyState
            } else {
                requestList
            }
        }
        .sheet(item: $selectedRequest) { request in
            RequestDetailSheet(request: request)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export CSV") {
                    exportCSV()
                }
                .disabled(filteredRequests.isEmpty)
                .help("Export the currently filtered requests as CSV")
            }
        }
    }

    // MARK: - Export

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "prism-traffic.csv"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TrafficExporter.csv(for: filteredRequests)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by domain or path...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Picker("Method", selection: $filterMethod) {
                ForEach(methods, id: \.self) { method in
                    Text(method).tag(method)
                }
            }
            .frame(width: 110)

            Toggle("HTTPS only", isOn: $showEncryptedOnly)
                .toggleStyle(.checkbox)

            Spacer()

            Text("\(filteredRequests.count) requests")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Request List

    private var requestList: some View {
        List(filteredRequests) { request in
            RequestRow(request: request)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedRequest = request
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "network.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No traffic captured")
                .font(.title3)
                .foregroundStyle(.secondary)
            if !store.isRunning {
                Text("Start the proxy to begin capturing traffic")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Configure your browser to use 127.0.0.1:\(store.port) as its HTTP proxy")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

// MARK: - Request Row

struct RequestRow: View {
    let request: ProxyRequest

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Text(request.method)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(methodColor)
                .frame(width: 65, alignment: .leading)

            Image(systemName: request.isEncrypted ? "lock.fill" : "lock.open")
                .font(.caption2)
                .foregroundStyle(request.isEncrypted ? .green : .orange)
                .frame(width: 14)

            Text(request.host)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1)
                .frame(minWidth: 150, alignment: .leading)

            if let path = request.path {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if request.bytesIn + request.bytesOut > 0 {
                Text((request.bytesIn + request.bytesOut).formattedBytes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }

            Text(Self.timeFormatter.string(from: request.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var methodColor: Color {
        switch request.method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        case "CONNECT": return .purple
        default: return .primary
        }
    }
}
