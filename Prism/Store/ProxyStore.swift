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
    var activeConnections = 0

    private var proxyServer: ProxyServer?
    private let recorder = TrafficRecorder()
    private let analyzer = PrivacyAnalyzer()
    private let summarizer: TrafficSummarizer
    private let systemProxy = SystemProxyManager()
    private var refreshTimer: Timer?
    private var summaryTimer: Timer?
    private var lastSummaryDate: Date?
    private var lastAnalyzedGeneration: UInt64 = 0
    private var analysisInFlight = false

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

    // Derived from the already-analyzed profiles rather than re-categorizing
    // every request — this is read on the main thread during every render.
    var trackingDomainCount: Int {
        domainProfiles.filter { $0.category.isTracking }.count
    }

    var encryptionRatio: Double {
        guard !requests.isEmpty else { return 1.0 }
        let encrypted = requests.filter(\.isEncrypted).count
        return Double(encrypted) / Double(requests.count)
    }

    // MARK: - Lifecycle

    init() {
        self.summarizer = TrafficSummarizer(analyzer: analyzer)

        let storedPort = UserDefaults.standard.integer(forKey: "proxyPort")
        if (1...65535).contains(storedPort) {
            port = UInt16(storedPort)
        }

        repairStaleSystemProxy()
        summarizer.pruneOldSummaries(keepDays: summaryRetentionDays)
        summaries = summarizer.loadSummaries()
        isSystemProxyEnabled = systemProxy.isSystemProxyEnabled
    }

    private var summaryRetentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: "summaryRetentionDays")
        return stored > 0 ? stored : 30
    }

    /// If a previous run enabled the system proxy and didn't shut down cleanly
    /// (crash, force quit), the Mac is still routing to a dead port. Undo that.
    private func repairStaleSystemProxy() {
        guard UserDefaults.standard.bool(forKey: "prismManagesSystemProxy") else { return }
        _ = systemProxy.disableSystemProxy()
        UserDefaults.standard.set(false, forKey: "prismManagesSystemProxy")
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
            UserDefaults.standard.set(false, forKey: "prismManagesSystemProxy")
        } else {
            if systemProxy.enableSystemProxy(port: port) {
                UserDefaults.standard.set(true, forKey: "prismManagesSystemProxy")
            } else {
                errorMessage = "Could not enable the system proxy. macOS may have blocked the change — you can set it manually in System Settings → Network, or check the port in Prism's settings."
            }
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
        activeConnections = proxyServer?.activeConnectionCount ?? 0

        // Idle ticks (no new traffic) and ticks arriving while an analysis is
        // already running cost nothing. The heavy work runs off the main actor;
        // only the publish hops back.
        guard !analysisInFlight,
              let (snapshot, generation) = recorder.snapshotIfChanged(since: lastAnalyzedGeneration) else {
            return
        }

        analysisInFlight = true
        let analyzer = self.analyzer
        Task.detached(priority: .utility) { [weak self] in
            let concerns = analyzer.analyze(snapshot)
            let profiles = ProxyStore.buildDomainProfiles(
                requests: snapshot, concerns: concerns, analyzer: analyzer
            )
            await self?.applyAnalysis(
                requests: snapshot, concerns: concerns, profiles: profiles, generation: generation
            )
        }
    }

    private func applyAnalysis(
        requests: [ProxyRequest],
        concerns: [PrivacyConcern],
        profiles: [DomainProfile],
        generation: UInt64
    ) {
        self.requests = requests
        self.concerns = concerns
        self.domainProfiles = profiles
        lastAnalyzedGeneration = generation
        analysisInFlight = false
    }

    nonisolated private static func buildDomainProfiles(
        requests: [ProxyRequest],
        concerns: [PrivacyConcern],
        analyzer: PrivacyAnalyzer
    ) -> [DomainProfile] {
        let grouped = Dictionary(grouping: requests, by: \.host)
        return grouped.map { host, reqs in
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
        summarizer.pruneOldSummaries(keepDays: summaryRetentionDays)
        summaries = summarizer.loadSummaries()
    }
}
