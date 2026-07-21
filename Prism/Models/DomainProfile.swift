import Foundation

struct DomainProfile: Identifiable, Hashable {
    let domain: String
    var requestCount: Int
    var bytesIn: Int
    var bytesOut: Int
    var category: DomainCategory
    var firstSeen: Date
    var lastSeen: Date
    var methods: Set<String>
    var paths: Set<String>
    var concerns: [PrivacyConcern]

    var id: String { domain }
    var totalBytes: Int { bytesIn + bytesOut }

    var displayCategory: String { category.rawValue }

    static func from(requests: [ProxyRequest], category: DomainCategory) -> DomainProfile {
        guard let first = requests.first else {
            return DomainProfile(
                domain: "unknown", requestCount: 0, bytesIn: 0, bytesOut: 0,
                category: .unknown, firstSeen: Date(), lastSeen: Date(),
                methods: [], paths: [], concerns: []
            )
        }

        let domain = first.host
        let timestamps = requests.map(\.timestamp)
        let methods = Set(requests.map(\.method))
        let paths = Set(requests.compactMap(\.path))

        return DomainProfile(
            domain: domain,
            requestCount: requests.count,
            bytesIn: requests.reduce(0) { $0 + $1.bytesIn },
            bytesOut: requests.reduce(0) { $0 + $1.bytesOut },
            category: category,
            firstSeen: timestamps.min() ?? Date(),
            lastSeen: timestamps.max() ?? Date(),
            methods: methods,
            paths: paths,
            concerns: []
        )
    }
}

extension Int {
    var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(self))
    }
}
