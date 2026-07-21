import Foundation

@Observable
@MainActor
final class ProxyStore {
    var isRunning = false
    var proxyState: ProxyServer.ProxyState = .stopped
    var requests: [ProxyRequest] = []
    var summaries: [TrafficSummary] = []
    var concerns: [PrivacyConcern] = []
    var domainProfiles: [DomainProfile] = []
    var errorMessage: String?
    var port: UInt16 = 9080
    var isSystemProxyEnabled = false

    private var proxyServer: ProxyServer?
    private let recorder = TrafficRecorder()
    private let analyzer = PrivacyAnalyzer()
    private let summarizer: TrafficSummarizer
    private let systemProxy = SystemProxyManager()
    private var refreshTimer: Timer?
    private var summaryTimer: Timer?
    private var lastSummaryDate: Date?

    // MARK: - Session Stats

    var totalRequests: Int { requests.count }

    var uniqueDomains: Int {
        Set(requests.map(\.host)).count
    }

    var totalBytesIn: Int {
        requests.reduce(0) { $0 + $1.bytesIn }
    }

    var totalBytesOut: Int {
        requests.reduce(0) { $0 + $1.bytesOut }
    }

    var trackingDomainCount: Int {
        let trackingHosts = Set(requests.map(\.host).filter { analyzer.categorize(domain: $0).isTracking })
        return trackingHosts.count
    }

    var encryptionRatio: Double {
        guard !requests.isEmpty else { return 1.0 }
        let encrypted = requests.filter(\.isEncrypted).count
        return Double(encrypted) / Double(requests.count)
    }

    // MARK: - Lifecycle

    init() {
        self.summarizer = TrafficSummarizer(analyzer: analyzer)
        summaries = summarizer.loadSummaries()
        isSystemProxyEnabled = systemProxy.isSystemProxyEnabled
    }

    func startProxy() {
        guard proxyServer == nil else { return }

        let server = ProxyServer(port: port, recorder: recorder)
        server.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.proxyState = state
                switch state {
                case .running:
                    self?.isRunning = true
                    self?.errorMessage = nil
                case .stopped:
                    self?.isRunning = false
                case .failed(let msg):
                    self?.isRunning = false
                    self?.errorMessage = msg
                case .starting:
                    break
                }
            }
        }

        do {
            try server.start()
            proxyServer = server
            startRefreshTimer()
            startSummaryTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopProxy() {
        proxyServer?.stop()
        proxyServer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        summaryTimer?.invalidate()
        summaryTimer = nil
        isRunning = false
        proxyState = .stopped
    }

    func toggleProxy() {
        if isRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    // MARK: - System Proxy

    func toggleSystemProxy() {
        if isSystemProxyEnabled {
            _ = systemProxy.disableSystemProxy()
        } else {
            _ = systemProxy.enableSystemProxy(port: port)
        }
        isSystemProxyEnabled = systemProxy.isSystemProxyEnabled
    }

    // MARK: - Manual Summary

    func generateSummaryNow() {
        let snapshot = recorder.snapshot()
        guard !snapshot.isEmpty else { return }

        let summary = summarizer.summarize(snapshot)
        summarizer.save(summary)
        summaries.insert(summary, at: 0)
        lastSummaryDate = Date()
    }

    // MARK: - Timers

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshData()
            }
        }
    }

    private func startSummaryTimer() {
        summaryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.generateSummaryNow()
            }
        }
    }

    private func refreshData() {
        requests = recorder.snapshot()
        concerns = analyzer.analyze(requests)
        rebuildDomainProfiles()
    }

    private func rebuildDomainProfiles() {
        let grouped = Dictionary(grouping: requests, by: \.host)
        domainProfiles = grouped.map { host, reqs in
            let category = analyzer.categorize(domain: host)
            var profile = DomainProfile.from(requests: reqs, category: category)
            profile.concerns = concerns.filter { $0.domain == host }
            return profile
        }.sorted { $0.requestCount > $1.requestCount }
    }

    // MARK: - Cleanup

    func clearCurrentSession() {
        _ = recorder.snapshotAndClear()
        requests.removeAll()
        concerns.removeAll()
        domainProfiles.removeAll()
    }

    func pruneSummaries() {
        summarizer.pruneOldSummaries()
        summaries = summarizer.loadSummaries()
    }
}
