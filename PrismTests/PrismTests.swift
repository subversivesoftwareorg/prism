import Testing
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
