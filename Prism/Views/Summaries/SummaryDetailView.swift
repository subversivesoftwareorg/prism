import SwiftUI
import Charts

struct SummaryDetailView: View {
    let summary: TrafficSummary

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy HH:mm"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                statsSection
                if !summary.concerns.isEmpty {
                    concernsSection
                }
                domainBreakdownSection
                categoryBreakdownChart
            }
            .padding()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Traffic Summary")
                .font(.title2)
                .fontWeight(.bold)
            Text("\(Self.dateFormatter.string(from: summary.periodStart)) — \(Self.dateFormatter.string(from: summary.periodEnd))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            SummaryStatCard(title: "Requests", value: "\(summary.totalRequests)")
            SummaryStatCard(title: "Domains", value: "\(summary.uniqueDomains)")
            SummaryStatCard(title: "Data", value: summary.totalBytes.formattedBytes)
            SummaryStatCard(title: "HTTPS", value: "\(summary.httpsRequests)")
            SummaryStatCard(title: "HTTP", value: "\(summary.httpRequests)")
            SummaryStatCard(
                title: "Encryption",
                value: "\(Int(summary.encryptionRatio * 100))%"
            )
        }
    }

    // MARK: - Concerns

    private var concernsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy Concerns")
                .font(.headline)

            ForEach(summary.concerns) { concern in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: concern.severity.systemImage)
                        .foregroundStyle(severityColor(concern.severity))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(concern.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(concern.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Domain Breakdown

    private var domainBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Domain Breakdown")
                .font(.headline)

            ForEach(summary.domainBreakdowns.prefix(20)) { breakdown in
                HStack {
                    Image(systemName: breakdown.category.systemImage)
                        .foregroundStyle(breakdown.category.isTracking ? .red : .blue)
                        .frame(width: 16)
                    Text(breakdown.domain)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)

                    if breakdown.category.isTracking {
                        Text(breakdown.category.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }

                    Spacer()

                    Text("\(breakdown.requestCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(breakdown.totalBytes.formattedBytes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Category Chart

    private var categoryBreakdownChart: some View {
        let categoryCounts = Dictionary(grouping: summary.domainBreakdowns, by: \.category)
            .map { (category: $0.key, count: $0.value.reduce(0) { $0 + $1.requestCount }) }
            .sorted { $0.count > $1.count }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Traffic by Category")
                .font(.headline)

            if !categoryCounts.isEmpty {
                Chart(categoryCounts, id: \.category) { item in
                    SectorMark(
                        angle: .value("Count", item.count),
                        innerRadius: .ratio(0.5)
                    )
                    .foregroundStyle(by: .value("Category", item.category.rawValue))
                }
                .frame(height: 200)
            }
        }
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
}

// MARK: - Summary Stat Card

struct SummaryStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
