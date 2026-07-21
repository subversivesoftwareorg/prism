# Prism

Network-observing HTTP/HTTPS proxy for macOS. Always-on proxy that captures, analyzes, and summarizes your network traffic to surface privacy concerns, tracking, and behavioral patterns.

Follows all conventions from [SUBVERSIVE_MACOS_ARCH.md](../SUBVERSIVE_MACOS_ARCH.md) — reference it for shared patterns.

## Build & Test

```bash
swift build                  # Debug build
swift build -c release       # Release build
swift test                   # Run tests
```

## Debugging

Structured logs via os.Logger, subsystem `com.subversivesoftware.prism`
(categories: `proxy`, `health`, `system-proxy`):

```bash
log stream --predicate 'subsystem == "com.subversivesoftware.prism"' --level debug
```

## Architecture

- **ProxyServer** — Network.framework TCP proxy. Handles HTTP (full request/response observation) and HTTPS CONNECT (hostname + byte count only).
- **TrafficRecorder** — Lock-protected ring buffer, retains 1 hour of raw traffic data.
- **TrafficSummarizer** — Generates hourly summaries with domain breakdowns and privacy analysis. Persists to ~/Library/Application Support/Prism/summaries/.
- **PrivacyAnalyzer** — Detects known trackers, unencrypted traffic, fingerprinting headers, tracking beacons, and excessive connections.
- **SystemProxyManager** — Configures macOS system HTTP proxy via `networksetup`.
- **ProxyStore** — @Observable @MainActor state container. Refreshes UI every 2 seconds via Timer.

## Key Design Decisions

- Uses Network.framework (not SwiftNIO) to stay within the Apple-frameworks-only convention.
- TrafficRecorder uses NSLock (not Swift actor) because the proxy runs on DispatchQueues.
- HTTPS traffic is tunneled, not decrypted — Prism sees the target hostname and byte volume, not the content.
- Default port: 9080.

## Bundle ID

`com.subversivesoftware.prism`
