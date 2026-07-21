import Foundation

final class SystemProxyManager {

    var isSystemProxyEnabled: Bool {
        guard let service = activeNetworkService() else { return false }
        let output = shell("networksetup -getwebproxy '\(service)'")
        return output.contains("Enabled: Yes")
    }

    func enableSystemProxy(port: UInt16) -> Bool {
        guard let service = activeNetworkService() else { return false }
        let p = String(port)

        let r1 = shell("networksetup -setwebproxy '\(service)' 127.0.0.1 \(p)")
        let r2 = shell("networksetup -setsecurewebproxy '\(service)' 127.0.0.1 \(p)")
        let r3 = shell("networksetup -setwebproxystate '\(service)' on")
        let r4 = shell("networksetup -setsecurewebproxystate '\(service)' on")

        _ = (r1, r2, r3, r4)
        return isSystemProxyEnabled
    }

    func disableSystemProxy() -> Bool {
        guard let service = activeNetworkService() else { return false }

        let r1 = shell("networksetup -setwebproxystate '\(service)' off")
        let r2 = shell("networksetup -setsecurewebproxystate '\(service)' off")

        _ = (r1, r2)
        return !isSystemProxyEnabled
    }

    func activeNetworkService() -> String? {
        let output = shell("networksetup -listallnetworkservices")
        let services = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }

        let preferred = ["Wi-Fi", "Ethernet", "USB 10/100/1000 LAN", "Thunderbolt Ethernet"]
        for name in preferred {
            if services.contains(name) { return name }
        }

        return services.first
    }

    @discardableResult
    private func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
