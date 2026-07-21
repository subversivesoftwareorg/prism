import Foundation

struct PrivacyConcern: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let severity: ConcernSeverity
    let category: ConcernCategory
    let title: String
    let detail: String
    let domain: String
    let evidence: String

    init(
        timestamp: Date = Date(),
        severity: ConcernSeverity,
        category: ConcernCategory,
        title: String,
        detail: String,
        domain: String,
        evidence: String
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.title = title
        self.detail = detail
        self.domain = domain
        self.evidence = evidence
    }
}

enum ConcernSeverity: String, Codable, CaseIterable, Comparable, Hashable {
    case info = "Info"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"

    var systemImage: String {
        switch self {
        case .info: return "info.circle"
        case .low: return "exclamationmark.circle"
        case .medium: return "exclamationmark.triangle"
        case .high: return "exclamationmark.octagon"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .info: return 4
        }
    }

    static func < (lhs: ConcernSeverity, rhs: ConcernSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

enum ConcernCategory: String, Codable, CaseIterable, Hashable {
    case tracking = "Tracking"
    case unencrypted = "Unencrypted Traffic"
    case fingerprinting = "Browser Fingerprinting"
    case dataExfiltration = "Data Exfiltration"
    case thirdPartyCookies = "Third-Party Cookies"
    case beaconPixel = "Tracking Beacons"
    case excessiveConnections = "Excessive Connections"

    var systemImage: String {
        switch self {
        case .tracking: return "eye"
        case .unencrypted: return "lock.open"
        case .fingerprinting: return "touchid"
        case .dataExfiltration: return "arrow.up.doc"
        case .thirdPartyCookies: return "checklist"
        case .beaconPixel: return "dot.radiowaves.right"
        case .excessiveConnections: return "network"
        }
    }
}
