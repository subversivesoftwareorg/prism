import Foundation

final class PrivacyAnalyzer {

    func analyze(_ requests: [ProxyRequest]) -> [PrivacyConcern] {
        var concerns: [PrivacyConcern] = []
        concerns.append(contentsOf: detectTrackers(requests))
        concerns.append(contentsOf: detectUnencryptedTraffic(requests))
        concerns.append(contentsOf: detectExcessiveConnections(requests))
        concerns.append(contentsOf: detectFingerprintingHeaders(requests))
        concerns.append(contentsOf: detectTrackingBeacons(requests))
        return concerns.sorted { $0.severity < $1.severity }
    }

    func categorize(domain: String) -> DomainCategory {
        let lower = domain.lowercased()

        for (pattern, category) in domainCategories {
            if lower.contains(pattern) { return category }
        }

        return .unknown
    }

    // MARK: - Detection

    private func detectTrackers(_ requests: [ProxyRequest]) -> [PrivacyConcern] {
        var seen = Set<String>()
        var concerns: [PrivacyConcern] = []

        for request in requests {
            let host = request.host.lowercased()
            guard !seen.contains(host) else { continue }

            for (pattern, label) in knownTrackers {
                if host.contains(pattern) {
                    seen.insert(host)
                    concerns.append(PrivacyConcern(
                        timestamp: request.timestamp,
                        severity: .medium,
                        category: .tracking,
                        title: "Tracker detected: \(label)",
                        detail: "Your traffic includes connections to \(host), a known \(label) service.",
                        domain: host,
                        evidence: "\(request.method) \(request.displayURL)"
                    ))
                    break
                }
            }
        }

        return concerns
    }

    private func detectUnencryptedTraffic(_ requests: [ProxyRequest]) -> [PrivacyConcern] {
        let httpRequests = requests.filter { !$0.isEncrypted }
        let httpDomains = Set(httpRequests.map(\.host))

        guard !httpDomains.isEmpty else { return [] }

        return [PrivacyConcern(
            timestamp: Date(),
            severity: .high,
            category: .unencrypted,
            title: "Unencrypted HTTP traffic detected",
            detail: "\(httpDomains.count) domain(s) contacted over plain HTTP. Data sent to these sites is visible to anyone on the network.",
            domain: httpDomains.first ?? "multiple",
            evidence: "Domains: \(httpDomains.sorted().prefix(10).joined(separator: ", "))"
        )]
    }

    private func detectExcessiveConnections(_ requests: [ProxyRequest]) -> [PrivacyConcern] {
        let domainCounts = Dictionary(grouping: requests, by: \.host)
            .mapValues(\.count)
            .filter { $0.value > 100 }

        return domainCounts.map { domain, count in
            PrivacyConcern(
                timestamp: Date(),
                severity: .low,
                category: .excessiveConnections,
                title: "High request volume to \(domain)",
                detail: "\(count) requests to \(domain) in the current window. This may indicate aggressive polling, telemetry, or tracking.",
                domain: domain,
                evidence: "\(count) requests"
            )
        }
    }

    private func detectFingerprintingHeaders(_ requests: [ProxyRequest]) -> [PrivacyConcern] {
        let fingerprintHeaders = [
            "X-Fingerprint", "X-Device-Fingerprint", "X-Browser-Fingerprint",
            "X-Canvas-FP", "X-WebGL-FP"
        ]

        var concerns: [PrivacyConcern] = []
        var seen = Set<String>()

        for request in requests {
            let host = request.host
            guard !seen.contains(host) else { continue }

            for header in fingerprintHeaders {
                if request.requestHeaders.keys.contains(where: { $0.caseInsensitiveCompare(header) == .orderedSame }) {
                    seen.insert(host)
                    concerns.append(PrivacyConcern(
                        timestamp: request.timestamp,
                        severity: .high,
                        category: .fingerprinting,
                        title: "Fingerprinting header sent to \(host)",
                        detail: "A browser fingerprinting header (\(header)) was detected in a request to \(host).",
                        domain: host,
                        evidence: "\(header) header present"
                    ))
                    break
                }
            }
        }

        return concerns
    }

    private func detectTrackingBeacons(_ requests: [ProxyRequest]) -> [PrivacyConcern] {
        let beaconPatterns = [
            "/pixel", "/beacon", "/track", "/collect", "/event",
            "/log", "/ping", "/impression", "/__utm"
        ]

        var concerns: [PrivacyConcern] = []
        var seen = Set<String>()

        for request in requests {
            guard let path = request.path else { continue }
            let host = request.host
            let key = "\(host)\(path)"
            guard !seen.contains(key) else { continue }

            let lower = path.lowercased()
            for pattern in beaconPatterns {
                if lower.contains(pattern) {
                    seen.insert(key)
                    let category = categorize(domain: host)
                    if category.isTracking {
                        concerns.append(PrivacyConcern(
                            timestamp: request.timestamp,
                            severity: .medium,
                            category: .beaconPixel,
                            title: "Tracking beacon to \(host)",
                            detail: "A tracking beacon or pixel request was sent to \(host)\(path).",
                            domain: host,
                            evidence: "\(request.method) \(request.displayURL)"
                        ))
                    }
                    break
                }
            }
        }

        return concerns
    }

    // MARK: - Known Trackers

    private let knownTrackers: [(String, String)] = [
        // Analytics
        ("google-analytics.com", "Google Analytics"),
        ("analytics.google.com", "Google Analytics"),
        ("googletagmanager.com", "Google Tag Manager"),
        ("stats.g.doubleclick.net", "Google Analytics"),
        ("hotjar.com", "Hotjar Analytics"),
        ("mixpanel.com", "Mixpanel Analytics"),
        ("segment.io", "Segment Analytics"),
        ("segment.com", "Segment Analytics"),
        ("amplitude.com", "Amplitude Analytics"),
        ("fullstory.com", "FullStory Session Recording"),
        ("heap.io", "Heap Analytics"),
        ("plausible.io", "Plausible Analytics"),
        ("matomo.org", "Matomo Analytics"),

        // Advertising
        ("doubleclick.net", "Google Advertising"),
        ("googlesyndication.com", "Google Ads"),
        ("googleadservices.com", "Google Ads"),
        ("adnxs.com", "AppNexus Advertising"),
        ("adsrvr.org", "The Trade Desk"),
        ("criteo.com", "Criteo Advertising"),
        ("taboola.com", "Taboola Advertising"),
        ("outbrain.com", "Outbrain Advertising"),
        ("amazon-adsystem.com", "Amazon Advertising"),
        ("moatads.com", "Oracle Moat"),

        // Social tracking
        ("connect.facebook.net", "Facebook Tracking"),
        ("facebook.com/tr", "Facebook Pixel"),
        ("graph.facebook.com", "Facebook API"),
        ("platform.twitter.com", "Twitter/X Tracking"),
        ("snap.licdn.com", "LinkedIn Tracking"),
        ("px.ads.linkedin.com", "LinkedIn Advertising"),
        ("tiktok.com/i18n/pixel", "TikTok Pixel"),
        ("analytics.tiktok.com", "TikTok Analytics"),

        // Telemetry
        ("telemetry.mozilla.org", "Mozilla Telemetry"),
        ("data.microsoft.com", "Microsoft Telemetry"),
        ("vortex.data.microsoft.com", "Microsoft Telemetry"),
        ("settings-win.data.microsoft.com", "Microsoft Telemetry"),
        ("activity.windows.com", "Windows Activity"),
        ("browser.events.data.msn.com", "Edge Telemetry"),
        ("mobile.events.data.microsoft.com", "Microsoft Mobile Telemetry"),
        ("sentry.io", "Sentry Error Tracking"),
        ("bugsnag.com", "Bugsnag Error Tracking"),
        ("datadog.com", "Datadog Monitoring"),
        ("newrelic.com", "New Relic Monitoring"),

        // Fingerprinting
        ("cdn.cookielaw.org", "OneTrust Consent/Tracking"),
        ("bat.bing.com", "Bing Tracking"),
        ("clarity.ms", "Microsoft Clarity"),
    ]

    private let domainCategories: [(String, DomainCategory)] = [
        // Analytics
        ("google-analytics", .analytics),
        ("analytics.google", .analytics),
        ("googletagmanager", .analytics),
        ("hotjar", .analytics),
        ("mixpanel", .analytics),
        ("segment.io", .analytics),
        ("segment.com", .analytics),
        ("amplitude", .analytics),
        ("fullstory", .analytics),
        ("heap.io", .analytics),
        ("clarity.ms", .analytics),

        // Advertising
        ("doubleclick", .advertising),
        ("googlesyndication", .advertising),
        ("googleadservices", .advertising),
        ("adnxs", .advertising),
        ("adsrvr", .advertising),
        ("criteo", .advertising),
        ("taboola", .advertising),
        ("outbrain", .advertising),
        ("amazon-adsystem", .advertising),
        ("moatads", .advertising),

        // Social
        ("facebook.net", .socialTracking),
        ("facebook.com", .socialTracking),
        ("fbcdn", .socialTracking),
        ("twitter.com", .socialTracking),
        ("linkedin.com", .socialTracking),
        ("tiktok.com", .socialTracking),

        // CDN
        ("cloudflare", .cdn),
        ("akamai", .cdn),
        ("fastly", .cdn),
        ("cdn.", .cdn),
        ("cloudfront", .cdn),
        ("googleapis.com", .cdn),
        ("gstatic.com", .cdn),

        // Telemetry
        ("sentry.io", .telemetry),
        ("bugsnag", .telemetry),
        ("datadog", .telemetry),
        ("newrelic", .telemetry),
        ("telemetry", .telemetry),

        // Fingerprinting
        ("cookielaw.org", .fingerprinting),
        ("fingerprintjs", .fingerprinting),
    ]
}
