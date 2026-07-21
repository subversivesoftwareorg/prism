import Testing
import Foundation
@testable import Prism

@Suite("TrafficRecorder")
struct TrafficRecorderTests {

    @Test("Records and retrieves requests")
    func recordAndRetrieve() {
        let recorder = TrafficRecorder()
        let request = ProxyRequest(
            method: "CONNECT",
            host: "example.com",
            port: 443,
            isEncrypted: true
        )

        recorder.record(request)
        let snapshot = recorder.snapshot()

        #expect(snapshot.count == 1)
        #expect(snapshot.first?.host == "example.com")
        #expect(snapshot.first?.method == "CONNECT")
    }

    @Test("Updates byte counts")
    func updateBytes() {
        let recorder = TrafficRecorder()
        let request = ProxyRequest(
            method: "GET",
            host: "example.com",
            port: 80,
            path: "/index.html",
            isEncrypted: false
        )

        recorder.record(request)
        recorder.updateBytes(id: request.id, bytesIn: 1024, bytesOut: 256)

        let snapshot = recorder.snapshot()
        #expect(snapshot.first?.bytesIn == 1024)
        #expect(snapshot.first?.bytesOut == 256)
    }

    @Test("Marks requests as completed")
    func completion() {
        let recorder = TrafficRecorder()
        let request = ProxyRequest(
            method: "CONNECT",
            host: "example.com",
            port: 443,
            isEncrypted: true
        )

        recorder.record(request)
        recorder.complete(id: request.id)

        let snapshot = recorder.snapshot()
        #expect(snapshot.first?.completedAt != nil)
    }

    @Test("Prunes requests older than one hour")
    func pruning() {
        let recorder = TrafficRecorder()
        recorder.record(ProxyRequest(
            timestamp: Date().addingTimeInterval(-7200),
            method: "GET", host: "old.example.com", port: 80, isEncrypted: false
        ))
        recorder.record(ProxyRequest(
            method: "GET", host: "new.example.com", port: 80, isEncrypted: false
        ))

        let snapshot = recorder.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.host == "new.example.com")
    }

    @Test("snapshotIfChanged returns nil when nothing changed")
    func generationGating() {
        let recorder = TrafficRecorder()
        let request = ProxyRequest(method: "GET", host: "example.com", port: 80, isEncrypted: false)
        recorder.record(request)

        let first = recorder.snapshotIfChanged(since: 0)
        #expect(first != nil)

        let second = recorder.snapshotIfChanged(since: first?.generation ?? 0)
        #expect(second == nil)

        recorder.updateBytes(id: request.id, bytesIn: 10)
        #expect(recorder.snapshotIfChanged(since: first?.generation ?? 0) != nil)
    }
}

@Suite("PrivacyAnalyzer")
struct PrivacyAnalyzerTests {

    @Test("Categorizes known tracking domains")
    func categorization() {
        let analyzer = PrivacyAnalyzer()

        #expect(analyzer.categorize(domain: "google-analytics.com") == .analytics)
        #expect(analyzer.categorize(domain: "doubleclick.net") == .advertising)
        #expect(analyzer.categorize(domain: "connect.facebook.net") == .socialTracking)
        #expect(analyzer.categorize(domain: "cdn.cloudflare.com") == .cdn)
        #expect(analyzer.categorize(domain: "example.com") == .unknown)
    }

    @Test("Detects unencrypted traffic")
    func unencryptedDetection() {
        let analyzer = PrivacyAnalyzer()
        let requests = [
            ProxyRequest(method: "GET", host: "insecure.com", port: 80, path: "/", isEncrypted: false)
        ]

        let concerns = analyzer.analyze(requests)
        let unencrypted = concerns.filter { $0.category == .unencrypted }
        #expect(!unencrypted.isEmpty)
    }

    @Test("Detects known trackers")
    func trackerDetection() {
        let analyzer = PrivacyAnalyzer()
        let requests = [
            ProxyRequest(method: "CONNECT", host: "www.google-analytics.com", port: 443, isEncrypted: true)
        ]

        let concerns = analyzer.analyze(requests)
        let tracking = concerns.filter { $0.category == .tracking }
        #expect(!tracking.isEmpty)
    }

    @Test("Concern identity is stable across repeated analysis of the same traffic")
    func stableConcernIdentity() {
        let analyzer = PrivacyAnalyzer()
        let requests = [
            ProxyRequest(method: "CONNECT", host: "www.google-analytics.com", port: 443, isEncrypted: true),
            ProxyRequest(method: "GET", host: "insecure.com", port: 80, path: "/", isEncrypted: false),
        ]

        let first = analyzer.analyze(requests)
        let second = analyzer.analyze(requests)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(first == second)
    }

    @Test("Excessive-connection concern identity survives a growing request count")
    func excessiveConnectionIdentityStable() {
        let analyzer = PrivacyAnalyzer()
        let base = (0..<101).map { _ in
            ProxyRequest(method: "CONNECT", host: "chatty.example.com", port: 443, isEncrypted: true)
        }
        let grown = base + [
            ProxyRequest(method: "CONNECT", host: "chatty.example.com", port: 443, isEncrypted: true)
        ]

        let firstID = analyzer.analyze(base).first { $0.category == .excessiveConnections }?.id
        let secondID = analyzer.analyze(grown).first { $0.category == .excessiveConnections }?.id

        #expect(firstID != nil)
        #expect(firstID == secondID)
    }
}

@Suite("ProxyRequest")
struct ProxyRequestTests {

    @Test("Generates display URL correctly")
    func displayURL() {
        let httpsRequest = ProxyRequest(
            method: "CONNECT", host: "example.com", port: 443, isEncrypted: true
        )
        #expect(httpsRequest.displayURL == "https://example.com")

        let httpRequest = ProxyRequest(
            method: "GET", host: "example.com", port: 80, path: "/page", isEncrypted: false
        )
        #expect(httpRequest.displayURL == "http://example.com/page")

        let customPort = ProxyRequest(
            method: "GET", host: "example.com", port: 8080, path: "/api", isEncrypted: false
        )
        #expect(customPort.displayURL == "http://example.com:8080/api")
    }
}

@Suite("TrafficSummarizer")
struct TrafficSummarizerTests {

    @Test("Generates summary from requests")
    func summarize() {
        let analyzer = PrivacyAnalyzer()
        let summarizer = TrafficSummarizer(analyzer: analyzer)

        let requests = [
            ProxyRequest(method: "CONNECT", host: "example.com", port: 443, isEncrypted: true, bytesIn: 1000),
            ProxyRequest(method: "CONNECT", host: "example.com", port: 443, isEncrypted: true, bytesIn: 2000),
            ProxyRequest(method: "GET", host: "other.com", port: 80, path: "/", isEncrypted: false, bytesIn: 500),
        ]

        let summary = summarizer.summarize(requests)

        #expect(summary.totalRequests == 3)
        #expect(summary.uniqueDomains == 2)
        #expect(summary.httpsRequests == 2)
        #expect(summary.httpRequests == 1)
        #expect(summary.totalBytesIn == 3500)
    }
}

@Suite("TrafficDatabase")
struct TrafficDatabaseTests {

    @Test("Inserts and counts requests")
    func insertAndCount() throws {
        let db = try TrafficDatabase(path: ":memory:")

        let r = ProxyRequest(method: "GET", host: "example.com", port: 80,
                             path: "/test", isEncrypted: false, completedAt: Date())
        try db.insertRequests([r])
        #expect(try db.totalRequestCount() == 1)

        try db.insertRequests([r])
        #expect(try db.totalRequestCount() == 1)
    }

    @Test("Tracks domain first-seen dates")
    func domainCatalog() throws {
        let db = try TrafficDatabase(path: ":memory:")

        let t1 = Date().addingTimeInterval(-3600)
        let r1 = ProxyRequest(timestamp: t1, method: "GET", host: "example.com",
                              port: 80, isEncrypted: false)
        try db.updateDomainCatalog(from: [r1])

        let firstSeen = try db.domainFirstSeen("example.com")
        #expect(firstSeen != nil)
        #expect(abs(firstSeen!.timeIntervalSince(t1)) < 1)
        #expect(try db.totalDomainCount() == 1)
        #expect(try db.domainFirstSeen("never.seen") == nil)

        let r2 = ProxyRequest(method: "GET", host: "example.com", port: 80, isEncrypted: false)
        try db.updateDomainCatalog(from: [r2])
        let still = try db.domainFirstSeen("example.com")
        #expect(abs(still!.timeIntervalSince(t1)) < 1)
    }

    @Test("Prunes old requests")
    func pruning() throws {
        let db = try TrafficDatabase(path: ":memory:")

        let old = ProxyRequest(timestamp: Date().addingTimeInterval(-86400 * 10),
                               method: "GET", host: "old.com", port: 80,
                               isEncrypted: false, completedAt: Date().addingTimeInterval(-86400 * 10))
        let recent = ProxyRequest(method: "GET", host: "new.com", port: 80,
                                  isEncrypted: false, completedAt: Date())
        try db.insertRequests([old, recent])
        #expect(try db.totalRequestCount() == 2)

        try db.pruneRequests(olderThanDays: 7)
        #expect(try db.totalRequestCount() == 1)
    }

    @Test("Records hourly statistics")
    func hourlyStats() throws {
        let db = try TrafficDatabase(path: ":memory:")

        let requests = [
            ProxyRequest(method: "GET", host: "a.com", port: 80,
                         isEncrypted: false, bytesIn: 100, bytesOut: 50),
            ProxyRequest(method: "CONNECT", host: "b.com", port: 443,
                         isEncrypted: true, bytesIn: 200, bytesOut: 150)
        ]
        let hourStart = Date(timeIntervalSince1970:
            floor(Date().timeIntervalSince1970 / 3600) * 3600)
        try db.recordHourlyStat(hourStart: hourStart, requests: requests)
        #expect(try db.hourlyStatCount() == 1)
    }
}

@Suite("TrafficExporter")
struct TrafficExporterTests {

    @Test("Exports requests as CSV with header row")
    func csvBasic() {
        let requests = [
            ProxyRequest(
                method: "GET", host: "example.com", port: 80, path: "/index.html",
                isEncrypted: false, responseStatus: 200, bytesIn: 1024, bytesOut: 256
            )
        ]

        let csv = TrafficExporter.csv(for: requests)
        let lines = csv.split(separator: "\n")

        #expect(lines.count == 2)
        #expect(lines[0] == "timestamp,method,scheme,host,port,path,status,bytes_in,bytes_out,duration_ms")
        #expect(lines[1].contains("GET,http,example.com,80,/index.html,200,1024,256"))
    }

    @Test("Escapes fields containing commas and quotes")
    func csvEscaping() {
        let requests = [
            ProxyRequest(
                method: "GET", host: "example.com", port: 80,
                path: "/search?q=\"a,b\"", isEncrypted: false
            )
        ]

        let csv = TrafficExporter.csv(for: requests)

        #expect(csv.contains("\"/search?q=\"\"a,b\"\"\""))
    }
}
