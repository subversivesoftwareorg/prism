import SwiftUI

struct DomainsView: View {
    @Environment(ProxyStore.self) private var store
    @State private var searchText = ""
    @State private var filterCategory: DomainCategory?
    @State private var sortBy: DomainSort = .requests
    @State private var showTrackingOnly = false

    private enum DomainSort: String, CaseIterable {
        case requests = "Requests"
        case data = "Data"
        case name = "Name"
        case recent = "Recent"
    }

    private var filteredProfiles: [DomainProfile] {
        var result = store.domainProfiles

        if showTrackingOnly {
            result = result.filter { $0.category.isTracking }
        }

        if let category = filterCategory {
            result = result.filter { $0.category == category }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.domain.lowercased().contains(query) }
        }

        switch sortBy {
        case .requests:
            result.sort { $0.requestCount > $1.requestCount }
        case .data:
            result.sort { $0.totalBytes > $1.totalBytes }
        case .name:
            result.sort { $0.domain < $1.domain }
        case .recent:
            result.sort { $0.lastSeen > $1.lastSeen }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            if store.domainProfiles.isEmpty {
                emptyState
            } else {
                domainList
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter domains...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Picker("Sort", selection: $sortBy) {
                ForEach(DomainSort.allCases, id: \.self) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            .frame(width: 110)

            Toggle("Tracking only", isOn: $showTrackingOnly)
                .toggleStyle(.checkbox)

            Spacer()

            Text("\(filteredProfiles.count) domains")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Domain List

    private var domainList: some View {
        List(filteredProfiles) { profile in
            DomainRow(profile: profile)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No domains observed")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Domains will appear here as traffic flows through the proxy")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

// MARK: - Domain Row

struct DomainRow: View {
    let profile: DomainProfile

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.category.systemImage)
                .foregroundStyle(profile.category.isTracking ? .red : .blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.domain)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)

                    if profile.category.isTracking {
                        Text(profile.category.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }

                HStack(spacing: 12) {
                    Label("\(profile.requestCount)", systemImage: "arrow.left.arrow.right")
                    Label(profile.totalBytes.formattedBytes, systemImage: "internaldrive")
                    Label(profile.methods.sorted().joined(separator: ", "), systemImage: "tag")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !profile.concerns.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("\(profile.concerns.count) concern(s)")
            }

            Text(Self.timeFormatter.localizedString(for: profile.lastSeen, relativeTo: Date()))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
