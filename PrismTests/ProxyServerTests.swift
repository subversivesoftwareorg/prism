import Testing
import Foundation
import Network
@testable import Prism

// MARK: - Async helpers

private struct TimeoutError: Error, CustomStringConvertible {
    var description: String { "Timed out waiting for network activity" }
}

private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval = 5,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let result = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return result
    }
}

private func pollUntil(
    timeout: TimeInterval = 3,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw TimeoutError()
}

// MARK: - Test origin server

/// A minimal TCP server on an ephemeral port: either answers any request with a
/// canned HTTP response, or echoes bytes back (for tunnel tests).
private final class TestOrigin {
    enum Mode {
        case respond(Data)
        case echo
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "prism.tests.origin")
    private let mode: Mode
    private let lock = NSLock()
    private var receivedBytes = Data()

    private(set) var port: UInt16 = 0

    var received: Data { lock.withLock { receivedBytes } }

    private init(mode: Mode) throws {
        self.mode = mode
        self.listener = try NWListener(using: .tcp)
    }

    static func start(mode: Mode) async throws -> TestOrigin {
        let origin = try TestOrigin(mode: mode)
        try await withTimeout(5) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                origin.listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        origin.port = origin.listener.port?.rawValue ?? 0
                        continuation.resume()
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                origin.listener.newConnectionHandler = { [weak origin] connection in
                    origin?.handle(connection)
                }
                origin.listener.start(queue: origin.queue)
            }
        }
        return origin
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.lock.withLock { self.receivedBytes.append(data) }

                switch self.mode {
                case .respond(let response):
                    connection.send(
                        content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                    return
                case .echo:
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            }

            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveLoop(connection)
            }
        }
    }
}

// MARK: - Proxy client helpers

private func startProxy(recorder: TrafficRecorder) async throws -> ProxyServer {
    let proxy = ProxyServer(port: 0, recorder: recorder)
    try await withTimeout(5) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            proxy.onStateChange = { state in
                guard !resumed else { return }
                switch state {
                case .running:
                    resumed = true
                    continuation.resume()
                case .failed(let message):
                    resumed = true
                    continuation.resume(throwing: ProxyError.listenerFailed(message))
                default:
                    break
                }
            }
            do {
                try proxy.start()
            } catch {
                resumed = true
                continuation.resume(throwing: error)
            }
        }
    }
    return proxy
}

private func openConnection(port: UInt16) async throws -> NWConnection {
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: port) ?? 0,
        using: .tcp
    )
    try await withTimeout(5) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "prism.tests.client"))
        }
    }
    return connection
}

private func send(_ data: Data, over connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        })
    }
}

private func receiveChunk(_ connection: NWConnection) async -> (data: Data?, isComplete: Bool) {
    await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if error != nil {
                continuation.resume(returning: (data, true))
            } else {
                continuation.resume(returning: (data, isComplete))
            }
        }
    }
}

private func receiveAll(over connection: NWConnection) async -> Data {
    var result = Data()
    while true {
        let (data, isComplete) = await receiveChunk(connection)
        if let data = data { result.append(data) }
        if isComplete || data == nil { return result }
    }
}

// MARK: - Tests

@Suite("ProxyServer integration", .serialized)
struct ProxyServerIntegrationTests {

    @Test("Proxies a plain HTTP GET, rewrites the request, and records it")
    func httpGetThroughProxy() async throws {
        let originResponse = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8)
        let origin = try await TestOrigin.start(mode: .respond(originResponse))
        defer { origin.stop() }

        let recorder = TrafficRecorder()
        let proxy = try await startProxy(recorder: recorder)
        defer { proxy.stop() }

        let client = try await openConnection(port: proxy.port)
        defer { client.cancel() }

        let request = "GET http://127.0.0.1:\(origin.port)/hello?q=1 HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Connection: keep-alive\r\n"
            + "User-Agent: PrismTests\r\n\r\n"
        try await send(Data(request.utf8), over: client)

        let response = try await withTimeout { await receiveAll(over: client) }
        let responseText = String(data: response, encoding: .utf8) ?? ""
        #expect(responseText.contains("200 OK"))
        #expect(responseText.hasSuffix("hello"))

        // The origin must see an origin-form request with proxy headers stripped.
        let forwarded = String(data: origin.received, encoding: .utf8) ?? ""
        #expect(forwarded.hasPrefix("GET /hello?q=1 HTTP/1.1\r\n"))
        #expect(!forwarded.lowercased().contains("proxy-connection"))
        #expect(forwarded.contains("Connection: close"))
        #expect(forwarded.contains("User-Agent: PrismTests"))

        try await pollUntil { recorder.snapshot().first?.responseStatus == 200 }
        let record = try #require(recorder.snapshot().first)
        #expect(record.method == "GET")
        #expect(record.host == "127.0.0.1")
        #expect(record.port == origin.port)
        #expect(record.path == "/hello?q=1")
        #expect(!record.isEncrypted)
        #expect(record.bytesIn >= originResponse.count)
        #expect(record.bytesOut > 0)
        #expect(record.completedAt != nil)
    }

    @Test("Routes origin-form requests via the Host header")
    func originFormRequest() async throws {
        let originResponse = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
        let origin = try await TestOrigin.start(mode: .respond(originResponse))
        defer { origin.stop() }

        let recorder = TrafficRecorder()
        let proxy = try await startProxy(recorder: recorder)
        defer { proxy.stop() }

        let client = try await openConnection(port: proxy.port)
        defer { client.cancel() }

        let request = "GET /direct HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n"
        try await send(Data(request.utf8), over: client)

        let response = try await withTimeout { await receiveAll(over: client) }
        #expect((String(data: response, encoding: .utf8) ?? "").hasSuffix("ok"))

        try await pollUntil { recorder.snapshot().first?.path == "/direct" }
        #expect(recorder.snapshot().first?.port == origin.port)
    }

    @Test("CONNECT tunnels bytes both ways and counts them")
    func connectTunnel() async throws {
        let origin = try await TestOrigin.start(mode: .echo)
        defer { origin.stop() }

        let recorder = TrafficRecorder()
        let proxy = try await startProxy(recorder: recorder)
        defer { proxy.stop() }

        let client = try await openConnection(port: proxy.port)
        defer { client.cancel() }

        let connect = "CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n"
        try await send(Data(connect.utf8), over: client)

        let established = try await withTimeout { await receiveChunk(client).data ?? Data() }
        #expect(String(data: established, encoding: .utf8)?.contains("200 Connection Established") == true)

        let payload = Data("ping-12345".utf8)
        try await send(payload, over: client)
        let echoed = try await withTimeout { await receiveChunk(client).data ?? Data() }
        #expect(echoed == payload)

        client.cancel()

        try await pollUntil {
            guard let record = recorder.snapshot().first else { return false }
            return record.bytesOut >= payload.count && record.bytesIn >= payload.count
        }
        let record = try #require(recorder.snapshot().first)
        #expect(record.method == "CONNECT")
        #expect(record.isEncrypted)
        #expect(record.host == "127.0.0.1")
        #expect(record.port == origin.port)
    }

    @Test("Parses a request head that arrives split across packets")
    func splitHead() async throws {
        let originResponse = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)
        let origin = try await TestOrigin.start(mode: .respond(originResponse))
        defer { origin.stop() }

        let recorder = TrafficRecorder()
        let proxy = try await startProxy(recorder: recorder)
        defer { proxy.stop() }

        let client = try await openConnection(port: proxy.port)
        defer { client.cancel() }

        let request = "GET http://127.0.0.1:\(origin.port)/split HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n"
        let bytes = Data(request.utf8)
        let cut = bytes.count / 2
        try await send(bytes.prefix(cut), over: client)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await send(bytes.suffix(from: cut), over: client)

        let response = try await withTimeout { await receiveAll(over: client) }
        #expect((String(data: response, encoding: .utf8) ?? "").contains("204"))

        try await pollUntil { recorder.snapshot().first?.path == "/split" }
    }

    @Test("Rejects a malformed request with 400")
    func malformedRequest() async throws {
        let recorder = TrafficRecorder()
        let proxy = try await startProxy(recorder: recorder)
        defer { proxy.stop() }

        let client = try await openConnection(port: proxy.port)
        defer { client.cancel() }

        try await send(Data("NONSENSE\r\n\r\n".utf8), over: client)
        let response = try await withTimeout { await receiveAll(over: client) }
        #expect((String(data: response, encoding: .utf8) ?? "").contains("400"))
        #expect(recorder.count == 0)
    }

    @Test("CONNECT to an unreachable port returns 502")
    func connectRefused() async throws {
        let recorder = TrafficRecorder()
        let proxy = try await startProxy(recorder: recorder)
        defer { proxy.stop() }

        let client = try await openConnection(port: proxy.port)
        defer { client.cancel() }

        // Port 1 is privileged and unused; loopback refuses immediately.
        try await send(Data("CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n".utf8), over: client)
        let response = try await withTimeout(10) { await receiveAll(over: client) }
        #expect((String(data: response, encoding: .utf8) ?? "").contains("502"))
    }
}

@Suite("ProxyServer parsing")
struct ProxyServerParsingTests {

    @Test("Parses CONNECT authority forms including IPv6 literals")
    func authorityParsing() {
        #expect(ProxyServer.parseAuthority("example.com:8443", defaultPort: 443)?.host == "example.com")
        #expect(ProxyServer.parseAuthority("example.com:8443", defaultPort: 443)?.port == 8443)
        #expect(ProxyServer.parseAuthority("example.com", defaultPort: 443)?.port == 443)
        #expect(ProxyServer.parseAuthority("[2001:db8::1]:8443", defaultPort: 443)?.host == "2001:db8::1")
        #expect(ProxyServer.parseAuthority("[2001:db8::1]:8443", defaultPort: 443)?.port == 8443)
        #expect(ProxyServer.parseAuthority("[2001:db8::1]", defaultPort: 443)?.port == 443)
        #expect(ProxyServer.parseAuthority("2001:db8::1", defaultPort: 443)?.host == "2001:db8::1")
        #expect(ProxyServer.parseAuthority("example.com:0", defaultPort: 443) == nil)
        #expect(ProxyServer.parseAuthority("", defaultPort: 443) == nil)
        #expect(ProxyServer.parseAuthority("[broken", defaultPort: 443) == nil)
    }
}
