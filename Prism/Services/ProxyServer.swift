import Foundation
import Network
import os

final class ProxyServer {
    private var listener: NWListener?
    private let recorder: TrafficRecorder
    private let queue = DispatchQueue(label: "com.subversivesoftware.prism.proxy", qos: .userInitiated)
    private(set) var port: UInt16
    var tunnelIdleTimeout: TimeInterval = 120
    var maxConnections = 2000

    private var effectiveIdleTimeout: TimeInterval {
        let count = activeConnectionCount
        if count > 500 { return min(tunnelIdleTimeout, 30) }
        if count > 200 { return min(tunnelIdleTimeout, 60) }
        return tunnelIdleTimeout
    }

    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionsLock = NSLock()

    private static let maxHeadSize = 64 * 1024
    private static let byteFlushThreshold = 256 * 1024

    var onStateChange: ((ProxyState) -> Void)?
    var onError: ((String) -> Void)?

    enum ProxyState {
        case stopped
        case starting
        case running
        case failed(String)
    }

    init(port: UInt16, recorder: TrafficRecorder) {
        self.port = port
        self.recorder = recorder
    }

    func start() throws {
        raiseFileDescriptorLimit()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        if port == 0 {
            // Port 0 requests an ephemeral port; the real one is read back on .ready.
            listener = try NWListener(using: params)
        } else {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw ProxyError.invalidPort
            }
            listener = try NWListener(using: params, on: nwPort)
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let actualPort = self?.listener?.port?.rawValue, actualPort != 0 {
                    self?.port = actualPort
                }
                ProxyLog.proxy.info("listener ready on port \(self?.port ?? 0, privacy: .public)")
                self?.onStateChange?(.running)
            case .failed(let error):
                ProxyLog.proxy.error("listener failed: \(error.localizedDescription, privacy: .public)")
                self?.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                ProxyLog.proxy.info("listener cancelled")
                self?.onStateChange?(.stopped)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        self.listener = listener
        onStateChange?(.starting)
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil

        let live = connectionsLock.withLock {
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        ProxyLog.proxy.info("stopping, closing \(live.count, privacy: .public) live connection(s)")
        live.forEach { $0.cancel() }
    }

    var activeConnectionCount: Int {
        connectionsLock.withLock { connections.count }
    }

    // MARK: - Connection Tracking

    // Every NWConnection (client and upstream) is registered so stop() can
    // close it and leaks are visible in activeConnectionCount. A connection
    // that is never unregistered is a file descriptor that is never released —
    // the process fd limit is the proxy's scarcest resource.
    private func register(_ connection: NWConnection) {
        let count = connectionsLock.withLock { () -> Int in
            connections[ObjectIdentifier(connection)] = connection
            return connections.count
        }
        if count > 200 && count % 50 == 0 {
            ProxyLog.proxy.warning("high connection count: \(count, privacy: .public) — possible leak or fd pressure")
        }
    }

    private func unregister(_ connection: NWConnection) {
        _ = connectionsLock.withLock {
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    private func track(_ client: NWConnection) {
        register(client)
        client.stateUpdateHandler = { [weak self, weak client] state in
            switch state {
            case .cancelled, .failed:
                if let client = client {
                    self?.unregister(client)
                }
            default:
                break
            }
        }
    }

    // MARK: - File Descriptors

    // GUI apps inherit launchd's soft limit of 256 open files — a proxy
    // handling two sockets per tunnel exhausts that in minutes of browsing.
    private func raiseFileDescriptorLimit() {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return }
        let target: rlim_t = min(10240, limits.rlim_max)
        if limits.rlim_cur < target {
            let previous = limits.rlim_cur
            limits.rlim_cur = target
            if setrlimit(RLIMIT_NOFILE, &limits) == 0 {
                ProxyLog.proxy.info("raised fd soft limit \(previous, privacy: .public) → \(target, privacy: .public)")
            } else {
                ProxyLog.proxy.error("failed to raise fd soft limit from \(previous, privacy: .public)")
            }
        }
    }

    // MARK: - Request Head Buffering

    private func handleNewConnection(_ client: NWConnection) {
        if activeConnectionCount >= maxConnections {
            ProxyLog.proxy.warning("connection cap (\(self.maxConnections, privacy: .public)) reached — rejecting")
            client.start(queue: queue)
            sendErrorAndClose(client, status: "503 Service Unavailable")
            return
        }
        track(client)
        client.start(queue: queue)
        receiveRequestHead(from: client, buffer: Data())
    }

    // Accumulates data until the full head (terminated by \r\n\r\n) has arrived —
    // clients are free to split the head across packets.
    private func receiveRequestHead(from client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty, error == nil else {
                client.cancel()
                return
            }

            var buffer = buffer
            buffer.append(data)

            if let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = Data(buffer[..<headEnd.upperBound])
                let bodyPrefix = Data(buffer[headEnd.upperBound...])
                self.route(head: head, bodyPrefix: bodyPrefix, client: client)
            } else if buffer.count > Self.maxHeadSize || isComplete {
                self.sendErrorAndClose(client, status: "400 Bad Request")
            } else {
                self.receiveRequestHead(from: client, buffer: buffer)
            }
        }
    }

    private func route(head: Data, bodyPrefix: Data, client: NWConnection) {
        guard let requestLine = parseRequestLine(head) else {
            ProxyLog.proxy.info("unparseable request head, responding 400")
            sendErrorAndClose(client, status: "400 Bad Request")
            return
        }
        ProxyLog.proxy.debug("\(requestLine.method, privacy: .public) \(requestLine.target, privacy: .public) (active: \(self.activeConnectionCount, privacy: .public))")

        if requestLine.method == "CONNECT" {
            handleConnect(requestLine: requestLine, client: client, earlyData: bodyPrefix)
        } else {
            handleHTTPRequest(requestLine: requestLine, head: head, bodyPrefix: bodyPrefix, client: client)
        }
    }

    // MARK: - CONNECT Tunnel

    private func handleConnect(requestLine: RequestLine, client: NWConnection, earlyData: Data) {
        guard let authority = Self.parseAuthority(requestLine.target, defaultPort: 443),
              let nwPort = NWEndpoint.Port(rawValue: authority.port) else {
            sendErrorAndClose(client, status: "400 Bad Request")
            return
        }

        let record = ProxyRequest(
            method: "CONNECT",
            host: authority.host,
            port: authority.port,
            isEncrypted: true
        )
        recorder.record(record)

        let server = NWConnection(host: NWEndpoint.Host(authority.host), port: nwPort, using: .tcp)
        register(server)

        var established = false
        server.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard !established else { return }
                established = true
                let response = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(content: response, completion: .contentProcessed { error in
                    guard error == nil else {
                        client.cancel()
                        server.cancel()
                        self?.recorder.complete(id: record.id)
                        return
                    }
                    if !earlyData.isEmpty {
                        self?.recorder.updateBytes(id: record.id, bytesOut: earlyData.count)
                        server.send(content: earlyData, completion: .contentProcessed { _ in })
                    }
                    let tunnel = TunnelState()
                    tunnel.setIdleHandler { [weak self] in
                        ProxyLog.proxy.debug("tunnel idle \(authority.host, privacy: .public):\(authority.port, privacy: .public) — tearing down")
                        client.cancel()
                        server.cancel()
                        self?.recorder.complete(id: record.id)
                    }
                    if let self = self {
                        tunnel.resetIdleTimer(on: self.queue, timeout: self.effectiveIdleTimeout)
                    }
                    self?.relay(from: client, to: server, recordID: record.id,
                                direction: .outbound, accumulator: ByteAccumulator(), tunnel: tunnel)
                    self?.relay(from: server, to: client, recordID: record.id,
                                direction: .inbound, accumulator: ByteAccumulator(), tunnel: tunnel)
                })
            case .waiting(let error):
                // "Waiting" means no viable path right now (e.g. connection refused).
                // A proxy must fail fast, not park the client until conditions change.
                ProxyLog.proxy.error("CONNECT upstream unreachable: \(authority.host, privacy: .public):\(authority.port, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                server.cancel()
            case .failed(let error):
                ProxyLog.proxy.error("CONNECT upstream failed: \(authority.host, privacy: .public):\(authority.port, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                self?.unregister(server)
                if !established {
                    established = true
                    self?.sendErrorAndClose(client, status: "502 Bad Gateway")
                    self?.recorder.complete(id: record.id)
                }
            case .cancelled:
                self?.unregister(server)
                if !established {
                    established = true
                    self?.sendErrorAndClose(client, status: "502 Bad Gateway")
                    self?.recorder.complete(id: record.id)
                }
            default:
                break
            }
        }

        server.start(queue: queue)
    }

    // MARK: - HTTP Proxy

    private func handleHTTPRequest(requestLine: RequestLine, head: Data, bodyPrefix: Data, client: NWConnection) {
        let headers = parseHeaders(from: head)

        let host: String
        let port: UInt16
        let originPath: String

        if let url = URL(string: requestLine.target), let urlHost = url.host {
            // Absolute-form target, the normal shape for proxied requests.
            host = urlHost
            port = UInt16(exactly: url.port ?? 80) ?? 0
            let path = url.path.isEmpty ? "/" : url.path
            originPath = path + (url.query.map { "?\($0)" } ?? "")
        } else if let hostHeader = headerValue("Host", in: headers),
                  let authority = Self.parseAuthority(hostHeader, defaultPort: 80) {
            // Origin-form target: route by the Host header.
            host = authority.host
            port = authority.port
            originPath = requestLine.target
        } else {
            sendErrorAndClose(client, status: "400 Bad Request")
            return
        }

        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            sendErrorAndClose(client, status: "400 Bad Request")
            return
        }

        let record = ProxyRequest(
            method: requestLine.method,
            host: host,
            port: port,
            path: originPath,
            isEncrypted: false,
            requestHeaders: headers
        )
        recorder.record(record)

        var outbound = rewriteHead(requestLine: requestLine, head: head, originPath: originPath)
        outbound.append(bodyPrefix)

        let server = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        register(server)

        var established = false
        server.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard !established else { return }
                established = true
                server.send(content: outbound, completion: .contentProcessed { error in
                    guard error == nil else {
                        client.cancel()
                        server.cancel()
                        self?.recorder.complete(id: record.id)
                        return
                    }
                    self?.recorder.updateBytes(id: record.id, bytesOut: outbound.count)
                    // Any remaining request body streams client→server while the
                    // response relays back the other way.
                    self?.relay(from: client, to: server, recordID: record.id,
                                direction: .outbound, accumulator: ByteAccumulator(), tunnel: TunnelState())
                    self?.relayHTTPResponse(from: server, to: client, recordID: record.id)
                })
            case .waiting(let error):
                ProxyLog.proxy.error("HTTP upstream unreachable: \(host, privacy: .public):\(port, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                server.cancel()
            case .failed(let error):
                ProxyLog.proxy.error("HTTP upstream failed: \(host, privacy: .public):\(port, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                self?.unregister(server)
                if !established {
                    established = true
                    self?.sendErrorAndClose(client, status: "502 Bad Gateway")
                    self?.recorder.complete(id: record.id)
                }
            case .cancelled:
                self?.unregister(server)
                if !established {
                    established = true
                    self?.sendErrorAndClose(client, status: "502 Bad Gateway")
                    self?.recorder.complete(id: record.id)
                }
            default:
                break
            }
        }

        server.start(queue: queue)
    }

    // MARK: - Relay

    private enum RelayDirection {
        case inbound, outbound
    }

    // Byte counts accumulate per relay direction and flush to the recorder in
    // batches — per-chunk recorder updates would contend on its lock for every
    // 64KB of a fast transfer. All relay callbacks run on the proxy's serial
    // queue, so the accumulator needs no synchronization of its own.
    private final class ByteAccumulator {
        var pending = 0
    }

    private func flush(_ accumulator: ByteAccumulator, recordID: UUID, direction: RelayDirection) {
        guard accumulator.pending > 0 else { return }
        switch direction {
        case .inbound:
            recorder.updateBytes(id: recordID, bytesIn: accumulator.pending)
        case .outbound:
            recorder.updateBytes(id: recordID, bytesOut: accumulator.pending)
        }
        accumulator.pending = 0
    }

    private final class TunnelState {
        var finishedDirections = 0
        private(set) var tornDown = false
        private var timeoutItem: DispatchWorkItem?
        private var onTimeout: (() -> Void)?

        func setIdleHandler(_ handler: @escaping () -> Void) {
            onTimeout = handler
        }

        func markTornDown() {
            tornDown = true
            timeoutItem?.cancel()
            timeoutItem = nil
        }

        func resetIdleTimer(on queue: DispatchQueue, timeout: TimeInterval) {
            guard !tornDown, onTimeout != nil else { return }
            timeoutItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, !self.tornDown else { return }
                self.markTornDown()
                self.onTimeout?()
            }
            timeoutItem = item
            queue.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    private func relay(from source: NWConnection, to destination: NWConnection,
                       recordID: UUID, direction: RelayDirection,
                       accumulator: ByteAccumulator, tunnel: TunnelState) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                tunnel.resetIdleTimer(on: self.queue, timeout: self.effectiveIdleTimeout)
                accumulator.pending += data.count
                if accumulator.pending >= Self.byteFlushThreshold {
                    self.flush(accumulator, recordID: recordID, direction: direction)
                }

                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil && !isComplete {
                        self.relay(from: source, to: destination, recordID: recordID,
                                   direction: direction, accumulator: accumulator, tunnel: tunnel)
                    } else if isComplete {
                        self.finishDirection(tunnel, source: source, destination: destination,
                                             recordID: recordID, direction: direction, accumulator: accumulator)
                    } else {
                        tunnel.markTornDown()
                        self.flush(accumulator, recordID: recordID, direction: direction)
                        source.cancel()
                        destination.cancel()
                        self.recorder.complete(id: recordID)
                    }
                })
            } else if error != nil {
                tunnel.markTornDown()
                self.flush(accumulator, recordID: recordID, direction: direction)
                source.cancel()
                destination.cancel()
                self.recorder.complete(id: recordID)
            } else if isComplete {
                self.finishDirection(tunnel, source: source, destination: destination,
                                     recordID: recordID, direction: direction, accumulator: accumulator)
            }
        }
    }

    private func finishDirection(_ tunnel: TunnelState, source: NWConnection, destination: NWConnection,
                                 recordID: UUID, direction: RelayDirection, accumulator: ByteAccumulator) {
        flush(accumulator, recordID: recordID, direction: direction)
        tunnel.finishedDirections += 1

        if tunnel.finishedDirections >= 2 {
            tunnel.markTornDown()
            source.cancel()
            destination.cancel()
            recorder.complete(id: recordID)
        } else {
            // Half-close: propagate the FIN but let the reverse direction
            // keep flowing (e.g. client done sending, server still responding).
            destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                             completion: .contentProcessed { _ in })
        }
    }

    private func relayHTTPResponse(from server: NWConnection, to client: NWConnection, recordID: UUID) {
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                // The status line is ASCII; decode only a small prefix so a binary
                // body sharing the first chunk can't defeat the parse.
                if let headText = String(data: data.prefix(128), encoding: .isoLatin1),
                   let firstLine = headText.split(separator: "\r\n", maxSplits: 1).first {
                    let parts = firstLine.split(separator: " ", maxSplits: 2)
                    if parts.count >= 2, let status = Int(parts[1]) {
                        self.recorder.setResponseStatus(id: recordID, status: status)
                    }
                }

                let accumulator = ByteAccumulator()
                accumulator.pending = data.count

                client.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil && !isComplete {
                        self.relayAll(from: server, to: client, recordID: recordID, accumulator: accumulator)
                    } else {
                        self.flush(accumulator, recordID: recordID, direction: .inbound)
                        server.cancel()
                        client.cancel()
                        self.recorder.complete(id: recordID)
                    }
                })
            } else if isComplete || error != nil {
                server.cancel()
                client.cancel()
                self.recorder.complete(id: recordID)
            }
        }
    }

    private func relayAll(from source: NWConnection, to destination: NWConnection,
                          recordID: UUID, accumulator: ByteAccumulator) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                accumulator.pending += data.count
                if accumulator.pending >= Self.byteFlushThreshold {
                    self.flush(accumulator, recordID: recordID, direction: .inbound)
                }

                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil && !isComplete {
                        self.relayAll(from: source, to: destination, recordID: recordID, accumulator: accumulator)
                    } else {
                        self.flush(accumulator, recordID: recordID, direction: .inbound)
                        source.cancel()
                        destination.cancel()
                        self.recorder.complete(id: recordID)
                    }
                })
            } else if isComplete || error != nil {
                self.flush(accumulator, recordID: recordID, direction: .inbound)
                source.cancel()
                destination.cancel()
                self.recorder.complete(id: recordID)
            }
        }
    }

    // MARK: - HTTP Parsing

    private func parseRequestLine(_ head: Data) -> RequestLine? {
        guard let str = String(data: head, encoding: .utf8) else { return nil }
        guard let lineEnd = str.range(of: "\r\n") else { return nil }
        let firstLine = String(str[str.startIndex..<lineEnd.lowerBound])
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        return RequestLine(
            method: String(parts[0]),
            target: String(parts[1]),
            version: parts.count > 2 ? String(parts[2]) : "HTTP/1.1"
        )
    }

    private func parseHeaders(from head: Data) -> [String: String] {
        guard let str = String(data: head, encoding: .utf8) else { return [:] }
        let lines = str.split(separator: "\r\n", omittingEmptySubsequences: false)
        var headers: [String: String] = [:]

        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return headers
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Parses "host", "host:port", "[v6literal]", or "[v6literal]:port".
    /// An unbracketed IPv6 literal (no port) is passed through whole.
    static func parseAuthority(_ target: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        guard !target.isEmpty else { return nil }

        if target.hasPrefix("[") {
            guard let close = target.firstIndex(of: "]") else { return nil }
            let host = String(target[target.index(after: target.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let rest = target[target.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port != 0 else { return nil }
            return (host, port)
        }

        if let colon = target.lastIndex(of: ":"), !target[..<colon].contains(":") {
            guard let port = UInt16(target[target.index(after: colon)...]), port != 0 else { return nil }
            return (String(target[..<colon]), port)
        }

        return (target, defaultPort)
    }

    // Rebuilds the request head in origin-form: proxy-only headers are stripped
    // and Connection: close is forced. One request per client connection keeps
    // the relay simple and correct; clients reopen connections transparently.
    // Only the head is rewritten as text — the body may be binary.
    private func rewriteHead(requestLine: RequestLine, head: Data, originPath: String) -> Data {
        guard let str = String(data: head, encoding: .utf8) else { return head }

        var headerLines = str.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        if !headerLines.isEmpty { headerLines.removeFirst() }
        headerLines.removeAll { line in
            let lower = line.lowercased()
            return lower.hasPrefix("proxy-connection:")
                || lower.hasPrefix("proxy-authorization:")
                || lower.hasPrefix("connection:")
        }

        var lines = ["\(requestLine.method) \(originPath) \(requestLine.version)"]
        lines.append(contentsOf: headerLines)
        lines.append("Connection: close")

        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    // MARK: - Errors

    private func sendErrorAndClose(_ client: NWConnection, status: String) {
        let response = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        client.send(content: response, completion: .contentProcessed { _ in
            client.cancel()
        })
    }
}

enum ProxyError: Error, LocalizedError {
    case invalidPort
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "Invalid port number"
        case .listenerFailed(let msg): return "Proxy listener failed: \(msg)"
        }
    }
}
