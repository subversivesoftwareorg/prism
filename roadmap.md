# Prism Roadmap

Prism's promise: **see through your network traffic** — an always-on observing proxy that
turns raw HTTP/HTTPS flow into privacy insight a regular Mac user can act on, while staying
detailed enough that a technical user reaches for it instead of a heavyweight proxy tool.

Two audiences, one bar for every feature:

- **Non-technical**: "Is something on my Mac doing something I should care about, and what
  do I do about it?" Plain language, zero configuration, glanceable.
- **Technical**: "Show me the actual requests, let me filter, attribute, and export."
  Nothing hidden, everything inspectable.

Guiding constraints (from SUBVERSIVE_MACOS_ARCH.md and the product vision):

- Always-on means **performance is a feature** — the proxy must never be the reason the
  network feels slow, and the UI must stay smooth under heavy traffic.
- Apple frameworks only (Network.framework, SwiftUI, Charts, `libproc`, `sqlite3` are all in
  bounds). Sparkle is the sole third-party dependency.
- HTTPS stays **tunneled, not decrypted**. Prism observes hostnames and byte volume for
  encrypted traffic. TLS interception is a non-goal (see bottom).
- Observe first, act second. Blocking is a later, opt-in capability — Prism's identity is
  awareness, not ad-blocking.

---

## Phase 1 — Foundations: correctness and performance — ✅ complete

The proxy works, but a deep read of the code shows defects and hot paths that undermine
"always-on." Everything later builds on this being solid.

### 1.1 Wire settings to reality (S) — ✅ done
`SettingsView` persists `proxyPort` and `summaryRetentionDays` via `@AppStorage`, but
`ProxyStore` hardcodes `port = 9080` and `pruneSummaries()` always uses the 30-day default.
Read the stored values in `ProxyStore.init()` and pass retention through. Users who change
the port today get silent no-ops — a trust-killer.

### 1.2 System proxy safety net (S) — ✅ done (cleanup on quit, stale-config repair, failure surfacing, bypass list)
If Prism quits (or crashes) while the system proxy is enabled, the Mac keeps routing to a
dead 127.0.0.1:9080 and the network appears broken. Fixes:
- `applicationWillTerminate` disables the system proxy if Prism enabled it.
- On launch, detect a stale Prism proxy config (enabled + pointing at our port + proxy not
  running) and offer to repair it.
- Detect `networksetup` failures (it can require authorization) instead of discarding the
  results, and surface actionable guidance in the UI.
- Add a localhost/private-range bypass list when enabling the system proxy.

### 1.3 Stable identity for requests and concerns (S) — ✅ done
`PrivacyConcern` mints a new `UUID` on every `analyze()` pass, and analysis re-runs every
2 seconds — so every concern is "new" every tick. Derive stable identity from content
(category + domain + evidence hash). This unlocks SwiftUI diffing, "mark as seen",
dismissals, and notifications that fire once instead of forever.

### 1.4 Recorder indexing and byte-update batching (M) — ✅ done
`TrafficRecorder.updateBytes` does a linear scan under `NSLock` for every 64KB relay chunk.
- Keep a `[UUID: Int]` index (or store requests in a dictionary + ordered ID list).
- Batch byte updates per connection in the proxy and flush to the recorder on a coarse
  interval (e.g., every 250ms or on completion) instead of per-chunk. Byte counts are for
  human display; per-chunk precision buys nothing.

### 1.5 Incremental analysis off the main actor (M) — ✅ done (generation-gated, background analysis, host-grouped tracker scan)
`refreshData()` currently snapshots everything, re-analyzes all requests, and rebuilds all
domain profiles on the main actor every 2 seconds. Restructure:
- Recorder tracks a generation counter / high-water mark; the store analyzes only new
  requests and merges into cumulative concern and domain-profile state.
- Run analysis on a background queue; publish results to `@MainActor` state.
- The 2s timer becomes a cheap merge, not a full recompute. Target: smooth UI with 50k+
  requests in the window.

### 1.6 Proxy protocol robustness (M) — ✅ done (also fixed: request bodies beyond the first packet were dropped; refused upstream connections hung in .waiting)
Current parsing assumes the whole request head arrives in one 64KB `receive`:
- Buffer until `\r\n\r\n` before parsing the request head.
- Handle HTTP keep-alive on plain-HTTP client connections (multiple requests per
  connection) or explicitly force `Connection: close` — today the relay just streams until
  close, so subsequent requests on the same connection are miscounted.
- CONNECT host parsing splits on `:` — breaks IPv6 literals (`[::1]:443`).
- Replace `NWEndpoint.Port(rawValue:)!` force-unwraps and the `"unknown"` host fallback
  (which currently attempts a TCP connection to the literal host "unknown") with clean 400
  responses.
- Track live connections (the `connections` set exists but is unused) so `stop()` can
  actually close them and the dashboard can show active-connection count.

### 1.7 Test the proxy itself (M) — ✅ done
Tests cover the recorder/analyzer/summarizer but not one byte of `ProxyServer`. Add
integration tests: spin up the proxy on an ephemeral port, run a local HTTP server, assert
requests are recorded, bytes counted, CONNECT tunneled, malformed input rejected. This is
the highest-risk untested code in the app.

### 1.8 Connection lifecycle + connectivity watchdog (field fix) — ✅ done
Ten minutes of real-world use hung every proxied app: gracefully closed
CONNECT tunnels were never cancelled, leaking two file descriptors each until
the process hit launchd's 256-fd soft limit and new connections silently
failed. Fixes: tunnels now tear down when both directions finish; upstream
connections are tracked and released; the fd soft limit is raised to 10240 at
startup; os.Logger debug logging throughout (subsystem
`com.subversivesoftware.prism`); a 10-second health watchdog probes the
listener and auto-disables the system proxy if it stops answering; and
stopping the proxy now drops the system proxy first. Design rule going
forward: **a sick proxy must never take the Mac's connectivity down with it.**

---

## Phase 2 — Attribution and smarter analysis

This phase is Prism's differentiation: not "what domains" but "which app talked to what,
and what does it mean."

### 2.1 Per-app attribution (L) — flagship feature
Every client connection arrives over loopback, so the client's source port maps to a PID
via `libproc` (allowed by the architecture conventions; same territory as Vigil). Resolve
PID → app name/bundle ID/icon at connection time and stamp it on `ProxyRequest`.

This transforms every surface: "Slack contacted 14 domains, 2 trackers", per-app filters in
Traffic, an Apps tab, and concerns that say *"Spotify sent data to a tracker"* instead of
*"something on your Mac did."* For non-technical users this is the difference between noise
and a story.

### 2.2 Real tracker intelligence (M)
The tracker list is ~50 hardcoded substring patterns in `PrivacyAnalyzer`. Replace with:
- A bundled, structured dataset (JSON) derived from an established open list
  (e.g., DuckDuckGo Tracker Radar / Disconnect format): domain → owner entity, category,
  prevalence. Proper suffix-based domain matching instead of `contains` (which today makes
  `notdoubleclick.net.evil.com` match, and `cdn.` match anywhere in a hostname).
- Refreshable out-of-band (fetch updated dataset periodically; Sparkle-style signed feed or
  simple versioned JSON on subversivesoftware.org).
- Entity rollup: "Google (7 domains), Meta (3 domains)" — owners, not hostnames, are what
  people recognize.

### 2.3 First-seen / new-domain detection (M)
Keep a persistent catalog of every domain (and app+domain pair) ever seen, with first-seen
timestamps. "New domain your Mac has never contacted before" is one of the highest-signal,
lowest-noise privacy events for both audiences — and it requires history, which the 1-hour
in-memory window can't provide. (Storage lands in Phase 4; a lightweight domain catalog
file can ship earlier.)

### 2.4 Actionable concerns (M)
`PrivacyConcern` gains `recommendation` and `explanation` fields. Every detector must
answer, in plain language: *what happened, why it matters, what you can do.* Examples:
- Unencrypted traffic → "Avoid entering passwords on this site; check for an https:// version."
- Tracker in app traffic → "This is telemetry from <app>. You can often disable it in the
  app's privacy settings."
- Concerns become dismissible ("got it" / "always ignore this domain") using the stable
  identity from 1.3 — an alert system nobody can quiet is an alert system people turn off.

### 2.5 Detector tuning (S)
- Excessive-connections threshold (hardcoded 100/hour) should scale with window size and
  ignore known-CDN categories.
- Beacon detection currently requires the domain to already be categorized as tracking —
  loosen to flag beacon-shaped paths on unknown domains at low severity.
- Score encrypted-only domains by behavior (request cadence, byte asymmetry) since we can't
  see paths: steady-cadence, small-payload connections look like telemetry heartbeats.

---

## Phase 3 — Ease of use: meet users where they are

### 3.1 Menu bar presence (M)
An always-on tool should not live only in a window. Add a `MenuBarExtra`:
status dot (running / stopped / concern pending), today's headline numbers, quick
start/stop, "Open Prism." Optionally hide the Dock icon when backgrounded. This is the
single biggest ease-of-use win for the non-technical audience.

### 3.2 First-run onboarding (M)
Today a new user sees an empty dashboard and must discover the Start button, then the
system-proxy button, then trust prompts. Replace with a 3-step guided flow: what Prism does
(and what it deliberately can't see) → start the proxy → enable the system proxy with a
live "traffic is flowing" confirmation. Include a "test my setup" check that fetches a URL
through the proxy and confirms capture.

### 3.3 Notifications for what matters (S)
`UserNotifications` for high-severity, *newly seen* events only (requires 1.3): new tracker
entity, unencrypted login-looking POST, first-seen domain spike. Strict rate limiting and a
single toggle in Settings. Never notify on recurring known concerns.

### 3.4 Plain-language digest on the Dashboard (M)
The dashboard shows numbers; it should also tell the story. A generated text block, rebuilt
from the same data as the stats:

> "In the last hour your Mac talked to 43 sites. Most traffic was Zoom (1.2 GB). 6 tracking
> services were contacted — mostly Google Analytics via your browser. Everything except one
> site used encryption."

Template-based generation from the summary model — deterministic, testable, no LLM
dependency. This directly serves the "distill clear information" goal.

### 3.5 Export and sharing (S) — ✅ traffic CSV export done; summary export & copy-as-curl remain
CSV/JSON export for the traffic table and summaries; copy-as-curl on a request row
(technical users); "export report" for a summary (shareable HTML/PDF-ish output). Data the
user can't get out is data they don't own.

### 3.6 UI affordances audit (S)
- Live Traffic: pause/resume autoscroll, column for app (after 2.1), status-code column.
- Domains: clicking a row should open a domain detail (paths seen, timeline, concerns,
  which apps talked to it) — `DomainProfile` already collects paths/methods that no view
  shows today.
- ✅ "Generate Now" summary button no longer requires the proxy to be running — only
  captured traffic.

---

## Phase 4 — History, trends, and the summary engine

The 1-hour in-memory window and per-hour JSON files can't answer "is this normal?" —
and *normal vs. new* is the core of useful privacy insight.

### 4.1 SQLite-backed history (L)
Move durable storage to `sqlite3` (allowed by conventions): compact per-request rows
(domain, app, timestamps, bytes, category — not headers) with rollup tables per
hour/day. In-memory recorder stays as the hot buffer; a writer drains it. Retention
policies per tier (raw rows: days; hourly rollups: months; daily rollups: forever).
JSON summaries in Application Support remain as the export format, not the database.

### 4.2 Trends and baselines (M)
With history: week-over-week charts (Charts framework), per-domain and per-app baselines,
and anomaly flags — "3× your usual upload volume to this domain", "this app normally never
talks to this country/entity." Baseline deviation is what makes an *observing* tool
genuinely protective without blocking anything.

### 4.3 Daily and weekly digests (M)
Summaries are currently hourly snapshots viewed one at a time. Add rollup digests: "Your
week: top apps, new domains, tracker trend ▼12%, encryption 99%." Weekly notification
(opt-in) linking to the digest. This is the artifact a non-technical user would actually
read — and the thing they'd screenshot to a friend.

### 4.4 Summary quality (S)
- Fix overlap: hourly summarization should drain (`snapshotAndClear`) or track a watermark
  so back-to-back summaries don't double-count the same trailing window.
- Summaries should record which app (once 2.1 lands) and top *entities* (once 2.2 lands),
  not just raw hostnames.

---

## Phase 5 — Optional control (opt-in, clearly separated)

Prism observes. But once trust is established, "I saw it — now make it stop" is the natural
next ask. Everything here is off by default and framed as user-initiated.

### 5.1 Domain rules: block / allow (L)
Per-domain rules enforced in the proxy: return 403 (HTTP) or refuse the tunnel (CONNECT)
for blocked domains. UI: right-click any domain anywhere → "Block this domain." A visible
"blocking N domains" indicator, one-click disable-all. Start with exact/suffix domain
matches only — no filter-list subscriptions; that's an ad-blocker's job.

### 5.2 PAC file serving (M)
Serve a generated PAC file so the system proxy config can bypass local/chosen hosts
cleanly, and so users can point a single browser at Prism without system-wide changes.
Also improves capture coverage guidance: be honest in the UI that `networksetup` proxies
are advisory — some CLI tools ignore them — and show what fraction of the system's traffic
Prism likely sees.

### 5.3 Per-app rules (M, after 2.1)
"Never proxy this app" (privacy for e.g. password managers) and "flag anything new from
this app." Enforcement is best-effort at the proxy layer with attribution.

---

## Sequencing and rationale

| Order | Theme | Why now |
|-------|-------|---------|
| 1 | Foundations | Correctness bugs (settings, proxy cleanup) actively hurt trust; perf work unblocks always-on. |
| 2 | Attribution + analysis | The differentiating insight layer; everything downstream (digests, notifications, rules) is better with app + entity context. |
| 3 | Ease of use | Menu bar + onboarding + digest make Prism livable for non-technical users. |
| 4 | History | Trends/baselines need storage; do it after the data model stabilizes (app attribution changes the schema). |
| 5 | Control | Only valuable once observation is trusted; philosophically opt-in. |

Quick wins to do immediately regardless of phase: 1.1 (wire settings), 1.2 (proxy cleanup
on quit), 1.3 (stable concern identity), 3.5 export CSV, 3.6 "Generate Now" decoupling.

## Non-goals (deliberate)

- **TLS interception / MITM decryption.** Prism's trust model is "we can't read your
  encrypted content" — that's a feature, stated in onboarding. Revisit only ever as
  explicit per-domain opt-in for developers, and probably not even then.
- **Packet-level capture.** That's Tapped's territory; Prism is application-layer on purpose.
- **Filter-list ad-blocking.** Rules exist to act on what Prism *showed you*, not to
  compete with dedicated blockers.
- **Third-party dependencies.** Everything above is achievable with Apple frameworks +
  sqlite3 + libproc.
