import os

// Structured logging visible in Console.app or via:
//   log stream --predicate 'subsystem == "com.subversivesoftware.prism"' --level debug
// Hosts and counts are marked public: this is the user's own machine and the
// entire point of Prism is showing them this traffic.
enum ProxyLog {
    static let proxy = Logger(subsystem: "com.subversivesoftware.prism", category: "proxy")
    static let health = Logger(subsystem: "com.subversivesoftware.prism", category: "health")
    static let system = Logger(subsystem: "com.subversivesoftware.prism", category: "system-proxy")
}
