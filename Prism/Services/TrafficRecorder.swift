import Foundation

final class TrafficRecorder {
    private var requests: [ProxyRequest] = []
    private var indexByID: [UUID: Int] = [:]
    private var generationValue: UInt64 = 0
    private let lock = NSLock()
    private let maxAge: TimeInterval = 3600

    func record(_ request: ProxyRequest) {
        lock.withLock {
            indexByID[request.id] = requests.count
            requests.append(request)
            generationValue &+= 1
        }
    }

    func updateBytes(id: UUID, bytesIn: Int = 0, bytesOut: Int = 0) {
        lock.withLock {
            guard let index = indexByID[id] else { return }
            requests[index].bytesIn += bytesIn
            requests[index].bytesOut += bytesOut
            generationValue &+= 1
        }
    }

    func complete(id: UUID) {
        lock.withLock {
            guard let index = indexByID[id] else { return }
            guard requests[index].completedAt == nil else { return }
            requests[index].completedAt = Date()
            generationValue &+= 1
        }
    }

    func setResponseStatus(id: UUID, status: Int) {
        lock.withLock {
            guard let index = indexByID[id] else { return }
            requests[index].responseStatus = status
            generationValue &+= 1
        }
    }

    func snapshot() -> [ProxyRequest] {
        lock.withLock {
            prune()
            return requests
        }
    }

    /// Returns nil when nothing has changed since `generation`, so callers can
    /// skip re-analysis entirely on idle ticks.
    func snapshotIfChanged(since generation: UInt64) -> (requests: [ProxyRequest], generation: UInt64)? {
        lock.withLock {
            prune()
            guard generationValue != generation else { return nil }
            return (requests, generationValue)
        }
    }

    func snapshotAndClear() -> [ProxyRequest] {
        lock.withLock {
            let current = requests
            requests.removeAll()
            indexByID.removeAll()
            generationValue &+= 1
            return current
        }
    }

    var count: Int {
        lock.withLock { requests.count }
    }

    var generation: UInt64 {
        lock.withLock { generationValue }
    }

    // Requests are appended in arrival order, so pruning is a removeFirst of the
    // expired prefix rather than a full-array filter.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)

        guard let firstValid = requests.firstIndex(where: { $0.timestamp >= cutoff }) else {
            if !requests.isEmpty {
                requests.removeAll()
                indexByID.removeAll()
                generationValue &+= 1
            }
            return
        }

        if firstValid > 0 {
            requests.removeFirst(firstValid)
            indexByID = Dictionary(uniqueKeysWithValues: requests.enumerated().map { ($0.element.id, $0.offset) })
            generationValue &+= 1
        }
    }
}
