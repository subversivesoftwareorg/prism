import Foundation

final class TrafficRecorder {
    private var requests: [ProxyRequest] = []
    private let lock = NSLock()
    private let maxAge: TimeInterval = 3600

    func record(_ request: ProxyRequest) {
        lock.withLock {
            requests.append(request)
        }
    }

    func updateBytes(id: UUID, bytesIn: Int = 0, bytesOut: Int = 0) {
        lock.withLock {
            if let index = requests.lastIndex(where: { $0.id == id }) {
                requests[index].bytesIn += bytesIn
                requests[index].bytesOut += bytesOut
            }
        }
    }

    func complete(id: UUID) {
        lock.withLock {
            if let index = requests.lastIndex(where: { $0.id == id }) {
                requests[index].completedAt = Date()
            }
        }
    }

    func setResponseStatus(id: UUID, status: Int) {
        lock.withLock {
            if let index = requests.lastIndex(where: { $0.id == id }) {
                requests[index].responseStatus = status
            }
        }
    }

    func snapshot() -> [ProxyRequest] {
        lock.withLock {
            prune()
            return requests
        }
    }

    func snapshotAndClear() -> [ProxyRequest] {
        lock.withLock {
            let current = requests
            requests.removeAll()
            return current
        }
    }

    var count: Int {
        lock.withLock { requests.count }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        requests.removeAll { $0.timestamp < cutoff }
    }
}
