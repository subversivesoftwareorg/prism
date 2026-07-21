import Foundation

struct ProxyRequest: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let method: String
    let host: String
    let port: UInt16
    let path: String?
    let isEncrypted: Bool
    let requestHeaders: [String: String]
    var responseStatus: Int?
    var bytesIn: Int
    var bytesOut: Int
    var completedAt: Date?

    var duration: TimeInterval? {
        completedAt.map { $0.timeIntervalSince(timestamp) }
    }

    var displayURL: String {
        let scheme = isEncrypted ? "https" : "http"
        let portSuffix = (isEncrypted && port == 443) || (!isEncrypted && port == 80) ? "" : ":\(port)"
        let pathPart = path ?? ""
        return "\(scheme)://\(host)\(portSuffix)\(pathPart)"
    }

    var methodColor: String {
        switch method {
        case "GET": return "blue"
        case "POST": return "green"
        case "PUT", "PATCH": return "orange"
        case "DELETE": return "red"
        case "CONNECT": return "purple"
        default: return "gray"
        }
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        host: String,
        port: UInt16,
        path: String? = nil,
        isEncrypted: Bool,
        requestHeaders: [String: String] = [:],
        responseStatus: Int? = nil,
        bytesIn: Int = 0,
        bytesOut: Int = 0,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.host = host
        self.port = port
        self.path = path
        self.isEncrypted = isEncrypted
        self.requestHeaders = requestHeaders
        self.responseStatus = responseStatus
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.completedAt = completedAt
    }
}

struct RequestLine {
    let method: String
    let target: String
    let version: String
}
