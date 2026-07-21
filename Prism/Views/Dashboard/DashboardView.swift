import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                proxyStatusCard
                statsGrid
                if !store.concerns.isEmpty {
                    concernsSummaryCard
                }
                if !store.domainProfiles.isEmpty {
                    topDomainsCard
                }
            }
            .padding()
        }
    }

    // MARK: - Proxy Status

    private var proxyStatusCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(store.isRunning ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(store.isRunning ? "Proxy Running" : "Proxy Stopped")
                        .font(.headline)
                }
                Text(store.isRunning
                     ? "Port \(store.port) · \(store.activeConnections) active connection\(store.activeConnections == 1 ? "" : "s")"
                     : "Port \(store.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = store.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Button(store.isRunning ? "Stop Proxy" : "Start Proxy") {
                    store.toggleProxy()
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isRunning ? .red : .green)

                if store.isRunning {
                    Button(store.isSystemProxyEnabled ? "Disable System Proxy" : "Enable System Proxy") {
                        store.toggleSystemProxy()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
            StatCard(title: "Requests", value: "\(store.totalRequests)", icon: "arrow.left.arrow.right")
            StatCard(title: "Domains", value: "\(store.uniqueDomains)", icon: "globe")
            StatCard(
                title: "Data In",
                value: store.totalBytesIn.formattedBytes,
                icon: "arrow.down.circle"
            )
            StatCard(
                title: "Data Out",
                value: store.totalBytesOut.formattedBytes,
                icon: "arrow.up.circle"
            )
        }
    }

    // MARK: - Concerns

    private var concernsSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text("Privacy Concerns")
                    .font(.headline)
                Spacer()
                Text("\(store.concerns.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
            }

            ForEach(store.concerns.prefix(5)) { concern in
                HStack(spacing: 8) {
                    Image(systemName: concern.severity.systemImage)
                        .foregroundStyle(severityColor(concern.severity))
                        .frame(width: 16)
                    VStack(alignment: .leading) {
                        Text(concern.title)
                            .font(.subheadline)
                        Text(concern.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if store.concerns.count > 5 {
                Text("+ \(store.concerns.count - 5) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Top Domains

    private var topDomainsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Domains")
                .font(.headline)

            let topDomains = store.domainProfiles.prefix(8)

            if !topDomains.isEmpty {
                Chart(Array(topDomains), id: \.domain) { profile in
                    BarMark(
                        x: .value("Requests", profile.requestCount),
                        y: .value("Domain", profile.domain)
                    )
                    .foregroundStyle(profile.category.isTracking ? .red : .blue)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let domain = value.as(String.self) {
                                Text(truncateDomain(domain))
                                    .font(.caption)
                            }
                        }
                    }
                }
                .frame(height: CGFloat(topDomains.count) * 28 + 20)
            }

            HStack(spacing: 16) {
                Label("Regular", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Label("Tracking", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func severityColor(_ severity: ConcernSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .info: return .gray
        }
    }

    private func truncateDomain(_ domain: String) -> String {
        if domain.count > 30 {
            return String(domain.prefix(27)) + "..."
        }
        return domain
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
