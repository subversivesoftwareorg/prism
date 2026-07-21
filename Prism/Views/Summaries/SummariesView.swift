import SwiftUI

struct SummariesView: View {
    @Environment(ProxyStore.self) private var store
    @State private var selectedSummary: TrafficSummary?

    var body: some View {
        HSplitView {
            summaryList
                .frame(minWidth: 280, maxWidth: 350)

            if let summary = selectedSummary {
                SummaryDetailView(summary: summary)
            } else {
                emptyDetail
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Generate Now") {
                    store.generateSummaryNow()
                }
                .disabled(store.requests.isEmpty)
                .help("Generate a summary of the captured traffic")
            }
        }
    }

    // MARK: - Summary List

    private var summaryList: some View {
        Group {
            if store.summaries.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No summaries yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Summaries are generated every hour while the proxy is running")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
            } else {
                List(store.summaries, selection: $selectedSummary) { summary in
                    SummaryRow(summary: summary)
                        .tag(summary)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Empty Detail

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select a summary to view details")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Summary Row

struct SummaryRow: View {
    let summary: TrafficSummary

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.timeFormatter.string(from: summary.periodStart))
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 12) {
                Label("\(summary.totalRequests)", systemImage: "arrow.left.arrow.right")
                Label("\(summary.uniqueDomains)", systemImage: "globe")
                if !summary.concerns.isEmpty {
                    Label("\(summary.concerns.count)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                EncryptionBar(ratio: summary.encryptionRatio)
                    .frame(height: 4)
                Text("\(Int(summary.encryptionRatio * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Encryption Bar

struct EncryptionBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.red.opacity(0.3))
                RoundedRectangle(cornerRadius: 2)
                    .fill(.green)
                    .frame(width: geometry.size.width * max(0, min(1, ratio)))
            }
        }
    }
}

extension TrafficSummary: Hashable {
    static func == (lhs: TrafficSummary, rhs: TrafficSummary) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
