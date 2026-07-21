import Foundation

enum TrafficExporter {

    static func csv(for requests: [ProxyRequest]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["timestamp,method,scheme,host,port,path,status,bytes_in,bytes_out,duration_ms"]

        for request in requests {
            let fields = [
                formatter.string(from: request.timestamp),
                request.method,
                request.isEncrypted ? "https" : "http",
                request.host,
                String(request.port),
                request.path ?? "",
                request.responseStatus.map(String.init) ?? "",
                String(request.bytesIn),
                String(request.bytesOut),
                request.duration.map { String(format: "%.1f", $0 * 1000) } ?? ""
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
