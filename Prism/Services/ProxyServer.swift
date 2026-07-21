import Foundation
import Network

final class ProxyServer {
    private var listener: NWListener?
    private let recorder: TrafficRecorder
    private let queue = DispatchQueue(label: "com.subversivesoftware.prism.proxy", qos: .userInitiated)
    private(set) var port: UInt16
    private var connections = Set<ObjectIdentifier>()
    private let connectionsLock = NSLock()

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
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyError.invalidPort
        }

        let listener = try NWListener(using: params, on: nwPort)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?(.running)
            case .failed(let error):
                self?.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
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
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ client: NWConnection) {
        client.start(queue: queue)

        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                client.cancel()
                return
            }

            guard let requestLine = self.parseRequestLine(data) else {
                client.cancel()
                return
            }

            if requestLine.method == "CONNECT" {
                self.handleConnect(requestLine: requestLine, client: client, rawRequest: data)
            } else {
                self.handleHTTPRequest(requestLine: requestLine, client: client, rawRequest: data)
            }
        }
    }

    // MARK: - CONNECT Tunnel

    private func handleConnect(requestLine: RequestLine, client: NWConnection, rawRequest: Data) {
        let components = requestLine.target.split(separator: ":", maxSplits: 1)
        let host = String(components[0])
        let port = components.count > 1 ? UInt16(components[1]) ?? 443 : 443

        let record = ProxyRequest(
            method: "CONNECT",
            host: host,
            port: port,
            isEncrypted: true
        )
        recorder.record(record)

        let serverConnection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )

        serverConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let response = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(content: response, completion: .contentProcessed { error in
                    if error == nil {
                        self?.relay(from: client, to: serverConnection, recordID: record.id, direction: .outbound)
                        self?.relay(from: serverConnection, to: client, recordID: record.id, direction: .inbound)
                    } else {
                        client.cancel()
                        serverConnection.cancel()
                        self?.recorder.complete(id: record.id)
                    }
                })
            case .failed, .cancelled:
                let response = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8)
                client.send(content: response, completion: .contentProcessed { _ in
                    client.cancel()
                })
                self?.recorder.complete(id: record.id)
            default:
                break
            }
        }

        serverConnection.start(queue: queue)
    }

    // MARK: - HTTP Proxy

    private func handleHTTPRequest(requestLine: RequestLine, client: NWConnection, rawRequest: Data) {
        guard let url = URL(string: requestLine.target) else {
            let host = extractHostHeader(from: rawRequest) ?? "unknown"
            handleRelativeHTTPRequest(
                requestLine: requestLine, client: client, rawRequest: rawRequest, host: host
            )
            return
        }

        let host = url.host ?? "unknown"
        let port = UInt16(url.port ?? 80)
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        let fullPath = path + query

        let headers = parseHeaders(from: rawRequest)

        let record = ProxyRequest(
            method: requestLine.method,
            host: host,
            port: port,
            path: fullPath,
            isEncrypted: false,
            requestHeaders: headers
        )
        recorder.record(record)

        let rewritten = rewriteRequest(rawRequest, absoluteURL: requestLine.target, relativePath: fullPath)

        let serverConnection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )

        serverConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                serverConnection.send(content: rewritten, completion: .contentProcessed { error in
                    if error == nil {
                        self?.relayHTTPResponse(
                            from: serverConnection, to: client, recordID: record.id
                        )
                    } else {
                        client.cancel()
                        serverConnection.cancel()
                        self?.recorder.complete(id: record.id)
                    }
                })
            case .failed, .cancelled:
                let response = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8)
                client.send(content: response, completion: .contentProcessed { _ in
                    client.cancel()
                })
                self?.recorder.complete(id: record.id)
            default:
                break
            }
        }

        serverConnection.start(queue: queue)
    }

    private func handleRelativeHTTPRequest(
        requestLine: RequestLine, client: NWConnection, rawRequest: Data, host: String
    ) {
        let record = ProxyRequest(
            method: requestLine.method,
            host: host,
            port: 80,
            path: requestLine.target,
            isEncrypted: false,
            requestHeaders: parseHeaders(from: rawRequest)
        )
        recorder.record(record)

        let serverConnection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: 80)!,
            using: .tcp
        )

        serverConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                serverConnection.send(content: rawRequest, completion: .contentProcessed { error in
                    if error == nil {
                        self?.relayHTTPResponse(from: serverConnection, to: client, recordID: record.id)
                    } else {
                        client.cancel()
                        serverConnection.cancel()
                        self?.recorder.complete(id: record.id)
                    }
                })
            case .failed, .cancelled:
                client.cancel()
                self?.recorder.complete(id: record.id)
            default:
                break
            }
        }

        serverConnection.start(queue: queue)
    }

    // MARK: - Relay

    private enum RelayDirection {
        case inbound, outbound
    }

    private func relay(
        from source: NWConnection, to destination: NWConnection,
        recordID: UUID, direction: RelayDirection
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                switch direction {
                case .inbound:
                    self?.recorder.updateBytes(id: recordID, bytesIn: data.count)
                case .outbound:
                    self?.recorder.updateBytes(id: recordID, bytesOut: data.count)
                }

                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil && !isComplete {
                        self?.relay(from: source, to: destination, recordID: recordID, direction: direction)
                    } else if isComplete {
                        destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                         completion: .contentProcessed { _ in })
                        self?.recorder.complete(id: recordID)
                    } else {
                        source.cancel()
                        destination.cancel()
                        self?.recorder.complete(id: recordID)
                    }
                })
            } else if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { _ in })
                self?.recorder.complete(id: recordID)
            }
        }
    }

    private func relayHTTPResponse(from server: NWConnection, to client: NWConnection, recordID: UUID) {
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                if let statusLine = String(data: data, encoding: .utf8),
                   let firstLine = statusLine.split(separator: "\r\n", maxSplits: 1).first {
                    let parts = firstLine.split(separator: " ", maxSplits: 2)
                    if parts.count >= 2, let status = Int(parts[1]) {
                        self?.recorder.setResponseStatus(id: recordID, status: status)
                    }
                }

                self?.recorder.updateBytes(id: recordID, bytesIn: data.count)

                client.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil && !isComplete {
                        self?.relayAll(from: server, to: client, recordID: recordID)
                    } else {
                        server.cancel()
                        client.cancel()
                        self?.recorder.complete(id: recordID)
                    }
                })
            } else if isComplete || error != nil {
                server.cancel()
                client.cancel()
                self?.recorder.complete(id: recordID)
            }
        }
    }

    private func relayAll(from source: NWConnection, to destination: NWConnection, recordID: UUID) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.recorder.updateBytes(id: recordID, bytesIn: data.count)

                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil && !isComplete {
                        self?.relayAll(from: source, to: destination, recordID: recordID)
                    } else {
                        source.cancel()
                        destination.cancel()
                        self?.recorder.complete(id: recordID)
                    }
                })
            } else if isComplete || error != nil {
                source.cancel()
                destination.cancel()
                self?.recorder.complete(id: recordID)
            }
        }
    }

    // MARK: - HTTP Parsing

    private func parseRequestLine(_ data: Data) -> RequestLine? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
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

    private func parseHeaders(from data: Data) -> [String: String] {
        guard let str = String(data: data, encoding: .utf8) else { return [:] }
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

    private func extractHostHeader(from data: Data) -> String? {
        let headers = parseHeaders(from: data)
        return headers["Host"] ?? headers["host"]
    }

    private func rewriteRequest(_ data: Data, absoluteURL: String, relativePath: String) -> Data {
        guard var str = String(data: data, encoding: .utf8) else { return data }
        guard let firstLineEnd = str.range(of: "\r\n") else { return data }

        var firstLine = String(str[str.startIndex..<firstLineEnd.lowerBound])
        firstLine = firstLine.replacingOccurrences(of: absoluteURL, with: relativePath)
        str.replaceSubrange(str.startIndex..<firstLineEnd.lowerBound, with: firstLine)

        // Strip proxy-specific headers
        let proxyHeaders = ["Proxy-Connection", "Proxy-Authorization"]
        for header in proxyHeaders {
            while let range = str.range(of: "\r\n\(header):", options: .caseInsensitive) {
                if let endRange = str.range(of: "\r\n", range: str.index(after: range.lowerBound)..<str.endIndex) {
                    str.replaceSubrange(range.lowerBound..<endRange.lowerBound, with: "")
                } else {
                    break
                }
            }
        }

        return Data(str.utf8)
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
