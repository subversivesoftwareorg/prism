import Foundation

struct TrafficSummary: Identifiable, Codable {
    let id: UUID
    let periodStart: Date
    let periodEnd: Date
    let totalRequests: Int
    let uniqueDomains: Int
    let totalBytesIn: Int
    let totalBytesOut: Int
    let httpRequests: Int
    let httpsRequests: Int
    let domainBreakdowns: [DomainBreakdown]
    let concerns: [PrivacyConcern]
    let topMethods: [MethodCount]

    var totalBytes: Int { totalBytesIn + totalBytesOut }

    var encryptionRatio: Double {
        guard totalRequests > 0 else { return 1.0 }
        return Double(httpsRequests) / Double(totalRequests)
    }

    init(
        periodStart: Date,
        periodEnd: Date,
        totalRequests: Int,
        uniqueDomains: Int,
        totalBytesIn: Int,
        totalBytesOut: Int,
        httpRequests: Int,
        httpsRequests: Int,
        domainBreakdowns: [DomainBreakdown],
        concerns: [PrivacyConcern],
        topMethods: [MethodCount]
    ) {
        self.id = UUID()
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.totalRequests = totalRequests
        self.uniqueDomains = uniqueDomains
        self.totalBytesIn = totalBytesIn
        self.totalBytesOut = totalBytesOut
        self.httpRequests = httpRequests
        self.httpsRequests = httpsRequests
        self.domainBreakdowns = domainBreakdowns
        self.concerns = concerns
        self.topMethods = topMethods
    }
}

struct DomainBreakdown: Identifiable, Codable, Hashable {
    let domain: String
    let requestCount: Int
    let bytesIn: Int
    let bytesOut: Int
    let category: DomainCategory
    let firstSeen: Date
    let lastSeen: Date

    var id: String { domain }
    var totalBytes: Int { bytesIn + bytesOut }
}

enum DomainCategory: String, Codable, CaseIterable, Hashable {
    case analytics = "Analytics"
    case advertising = "Advertising"
    case socialTracking = "Social Tracking"
    case cdn = "CDN"
    case api = "API"
    case media = "Media"
    case fingerprinting = "Fingerprinting"
    case telemetry = "Telemetry"
    case unknown = "Unknown"

    var systemImage: String {
        switch self {
        case .analytics: return "chart.bar"
        case .advertising: return "megaphone"
        case .socialTracking: return "person.2.wave.2"
        case .cdn: return "server.rack"
        case .api: return "arrow.left.arrow.right"
        case .media: return "photo"
        case .fingerprinting: return "touchid"
        case .telemetry: return "antenna.radiowaves.left.and.right"
        case .unknown: return "questionmark.circle"
        }
    }

    var isTracking: Bool {
        switch self {
        case .analytics, .advertising, .socialTracking, .fingerprinting, .telemetry:
            return true
        case .cdn, .api, .media, .unknown:
            return false
        }
    }
}

struct MethodCount: Identifiable, Codable {
    let method: String
    let count: Int

    var id: String { method }
}
