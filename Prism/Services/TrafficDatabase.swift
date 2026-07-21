import Foundation
import SQLite3

final class TrafficDatabase {
    private var db: OpaquePointer?
    private let lock = NSLock()

    enum Failure: Error, LocalizedError {
        case open(String)
        case query(String)

        var errorDescription: String? {
            switch self {
            case .open(let msg): return "Database open failed: \(msg)"
            case .query(let msg): return "Database query failed: \(msg)"
            }
        }
    }

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw Failure.open(msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try createSchema()
    }

    convenience init() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prism", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try self.init(path: dir.appendingPathComponent("traffic.db").path)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS requests (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                method TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL,
                path TEXT,
                is_encrypted INTEGER NOT NULL DEFAULT 0,
                response_status INTEGER,
                bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                completed_at REAL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_requests_ts ON requests(timestamp)")
        try exec("CREATE INDEX IF NOT EXISTS idx_requests_host ON requests(host)")

        try exec("""
            CREATE TABLE IF NOT EXISTS hourly_stats (
                hour_start REAL PRIMARY KEY,
                total_requests INTEGER NOT NULL,
                total_bytes_in INTEGER NOT NULL,
                total_bytes_out INTEGER NOT NULL,
                unique_domains INTEGER NOT NULL,
                encrypted_count INTEGER NOT NULL,
                domain_breakdown TEXT
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS domain_catalog (
                domain TEXT PRIMARY KEY,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL
            )
        """)
    }

    // MARK: - Insert

    func insertRequests(_ requests: [ProxyRequest]) throws {
        guard !requests.isEmpty else { return }
        try lock.withLock {
            try exec("BEGIN")
            do {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, """
                    INSERT OR IGNORE INTO requests
                    (id, timestamp, method, host, port, path, is_encrypted,
                     response_status, bytes_in, bytes_out, completed_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, -1, &stmt, nil) == SQLITE_OK else {
                    throw Failure.query(lastError)
                }
                defer { sqlite3_finalize(stmt) }

                for r in requests {
                    sqlite3_reset(stmt)
                    bindText(stmt, 1, r.id.uuidString)
                    sqlite3_bind_double(stmt, 2, r.timestamp.timeIntervalSince1970)
                    bindText(stmt, 3, r.method)
                    bindText(stmt, 4, r.host)
                    sqlite3_bind_int64(stmt, 5, Int64(r.port))
                    if let path = r.path { bindText(stmt, 6, path) }
                    else { sqlite3_bind_null(stmt, 6) }
                    sqlite3_bind_int64(stmt, 7, r.isEncrypted ? 1 : 0)
                    if let s = r.responseStatus { sqlite3_bind_int64(stmt, 8, Int64(s)) }
                    else { sqlite3_bind_null(stmt, 8) }
                    sqlite3_bind_int64(stmt, 9, Int64(r.bytesIn))
                    sqlite3_bind_int64(stmt, 10, Int64(r.bytesOut))
                    if let c = r.completedAt { sqlite3_bind_double(stmt, 11, c.timeIntervalSince1970) }
                    else { sqlite3_bind_null(stmt, 11) }

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw Failure.query(lastError)
                    }
                }
                try exec("COMMIT")
            } catch {
                _ = try? exec("ROLLBACK")
                throw error
            }
        }
    }

    func updateDomainCatalog(from requests: [ProxyRequest]) throws {
        var domainDates: [String: (first: Date, last: Date)] = [:]
        for r in requests {
            if let existing = domainDates[r.host] {
                domainDates[r.host] = (
                    first: min(existing.first, r.timestamp),
                    last: max(existing.last, r.timestamp)
                )
            } else {
                domainDates[r.host] = (first: r.timestamp, last: r.timestamp)
            }
        }
        guard !domainDates.isEmpty else { return }

        try lock.withLock {
            try exec("BEGIN")
            do {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, """
                    INSERT INTO domain_catalog (domain, first_seen, last_seen)
                    VALUES (?, ?, ?)
                    ON CONFLICT(domain) DO UPDATE SET
                        first_seen = MIN(first_seen, excluded.first_seen),
                        last_seen = MAX(last_seen, excluded.last_seen)
                """, -1, &stmt, nil) == SQLITE_OK else {
                    throw Failure.query(lastError)
                }
                defer { sqlite3_finalize(stmt) }

                for (domain, info) in domainDates {
                    sqlite3_reset(stmt)
                    bindText(stmt, 1, domain)
                    sqlite3_bind_double(stmt, 2, info.first.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 3, info.last.timeIntervalSince1970)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw Failure.query(lastError)
                    }
                }
                try exec("COMMIT")
            } catch {
                _ = try? exec("ROLLBACK")
                throw error
            }
        }
    }

    func recordHourlyStat(hourStart: Date, requests: [ProxyRequest]) throws {
        let hosts = Set(requests.map(\.host))
        let encrypted = requests.filter(\.isEncrypted).count
        let bytesIn = requests.reduce(0) { $0 + $1.bytesIn }
        let bytesOut = requests.reduce(0) { $0 + $1.bytesOut }

        let grouped = Dictionary(grouping: requests, by: \.host)
        let top = grouped.sorted { $0.value.count > $1.value.count }.prefix(50)
        let breakdown: [[String: Any]] = top.map { domain, reqs in
            ["d": domain, "n": reqs.count,
             "i": reqs.reduce(0) { $0 + $1.bytesIn },
             "o": reqs.reduce(0) { $0 + $1.bytesOut }]
        }
        let json = (try? JSONSerialization.data(withJSONObject: breakdown))
            .flatMap { String(data: $0, encoding: .utf8) }

        try lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                INSERT OR REPLACE INTO hourly_stats
                (hour_start, total_requests, total_bytes_in, total_bytes_out,
                 unique_domains, encrypted_count, domain_breakdown)
                VALUES (?,?,?,?,?,?,?)
            """, -1, &stmt, nil) == SQLITE_OK else {
                throw Failure.query(lastError)
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, hourStart.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, Int64(requests.count))
            sqlite3_bind_int64(stmt, 3, Int64(bytesIn))
            sqlite3_bind_int64(stmt, 4, Int64(bytesOut))
            sqlite3_bind_int64(stmt, 5, Int64(hosts.count))
            sqlite3_bind_int64(stmt, 6, Int64(encrypted))
            if let json = json { bindText(stmt, 7, json) }
            else { sqlite3_bind_null(stmt, 7) }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw Failure.query(lastError)
            }
        }
    }

    // MARK: - Pruning

    func pruneRequests(olderThanDays days: Int) throws {
        try lock.withLock {
            let cutoff = Date().addingTimeInterval(-TimeInterval(days * 86400))
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM requests WHERE timestamp < ?", -1, &stmt, nil) == SQLITE_OK else {
                throw Failure.query(lastError)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw Failure.query(lastError)
            }
        }
    }

    func pruneHourlyStats(olderThanMonths months: Int) throws {
        try lock.withLock {
            let cutoff = Date().addingTimeInterval(-TimeInterval(months * 30 * 86400))
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM hourly_stats WHERE hour_start < ?", -1, &stmt, nil) == SQLITE_OK else {
                throw Failure.query(lastError)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw Failure.query(lastError)
            }
        }
    }

    // MARK: - Queries

    func totalRequestCount() throws -> Int {
        try lock.withLock {
            try scalarInt("SELECT COUNT(*) FROM requests")
        }
    }

    func requestCount(since date: Date) throws -> Int {
        try lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM requests WHERE timestamp >= ?", -1, &stmt, nil) == SQLITE_OK else {
                throw Failure.query(lastError)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failure.query(lastError) }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func domainFirstSeen(_ domain: String) throws -> Date? {
        try lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT first_seen FROM domain_catalog WHERE domain = ?", -1, &stmt, nil) == SQLITE_OK else {
                throw Failure.query(lastError)
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, domain)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    func totalDomainCount() throws -> Int {
        try lock.withLock {
            try scalarInt("SELECT COUNT(*) FROM domain_catalog")
        }
    }

    func hourlyStatCount() throws -> Int {
        try lock.withLock {
            try scalarInt("SELECT COUNT(*) FROM hourly_stats")
        }
    }

    // MARK: - Helpers

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
    }

    @discardableResult
    private func exec(_ sql: String) throws -> Int32 {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err {
            let msg = String(cString: err)
            sqlite3_free(err)
            throw Failure.query(msg)
        }
        return rc
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { ptr in
            sqlite3_bind_text(stmt, index, ptr, -1, transient)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure.query(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failure.query(lastError) }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
