import Foundation

final class TrafficSummarizer {

    private let analyzer: PrivacyAnalyzer
    private let persistenceDir: URL

    init(analyzer: PrivacyAnalyzer) {
        self.analyzer = analyzer

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        persistenceDir = appSupport.appendingPathComponent("Prism/summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: persistenceDir, withIntermediateDirectories: true)
    }

    func summarize(_ requests: [ProxyRequest]) -> TrafficSummary {
        let timestamps = requests.map(\.timestamp)
        let periodStart = timestamps.min() ?? Date()
        let periodEnd = timestamps.max() ?? Date()

        let grouped = Dictionary(grouping: requests, by: \.host)

        let domainBreakdowns: [DomainBreakdown] = grouped.map { host, reqs in
            let category = analyzer.categorize(domain: host)
            let reqTimestamps = reqs.map(\.timestamp)
            return DomainBreakdown(
                domain: host,
                requestCount: reqs.count,
                bytesIn: reqs.reduce(0) { $0 + $1.bytesIn },
                bytesOut: reqs.reduce(0) { $0 + $1.bytesOut },
                category: category,
                firstSeen: reqTimestamps.min() ?? Date(),
                lastSeen: reqTimestamps.max() ?? Date()
            )
        }.sorted { $0.requestCount > $1.requestCount }

        let methodCounts = Dictionary(grouping: requests, by: \.method)
            .map { MethodCount(method: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }

        let concerns = analyzer.analyze(requests)

        let summary = TrafficSummary(
            periodStart: periodStart,
            periodEnd: periodEnd,
            totalRequests: requests.count,
            uniqueDomains: grouped.count,
            totalBytesIn: requests.reduce(0) { $0 + $1.bytesIn },
            totalBytesOut: requests.reduce(0) { $0 + $1.bytesOut },
            httpRequests: requests.filter { !$0.isEncrypted }.count,
            httpsRequests: requests.filter { $0.isEncrypted }.count,
            domainBreakdowns: domainBreakdowns,
            concerns: concerns,
            topMethods: methodCounts
        )

        return summary
    }

    // MARK: - Persistence

    func save(_ summary: TrafficSummary) {
        let formatter = ISO8601DateFormatter()
        let filename = "summary-\(formatter.string(from: summary.periodStart)).json"
        let url = persistenceDir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(summary) {
            try? data.write(to: url)
        }
    }

    func loadSummaries() -> [TrafficSummary] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: persistenceDir, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TrafficSummary.self, from: data)
            }
            .sorted { $0.periodStart > $1.periodStart }
    }

    func pruneOldSummaries(keepDays: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? Date()

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: persistenceDir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
               let created = attrs.creationDate, created < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
