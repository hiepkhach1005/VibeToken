import Foundation

// MARK: - Model

enum ProviderID: String, CaseIterable { case claude, codex }

enum WindowKind: Equatable {
    case session                // 5h
    case weekly                 // 7 days, all models
    case scoped(String)         // weekly per model / surface / feature, label already human readable
}

struct QuotaWindow {
    var kind: WindowKind
    var usedPct: Double?
    var resetsAt: Date?
    var noNewData = false       // Codex log is older than the reset -> shown as 0%
}

struct Account {
    var email: String?
    var name: String?
    var org: String?
    var plan: String?
}

enum QuotaStatus: Equatable {
    case ok
    case noCredentials          // provider not installed / never signed in -> hidden
    case authExpired            // 401 / missing token -> "—" + re-login hint
    case network(String)        // transient, keep old numbers
    case failed(String)
}

struct Quota {
    var provider: ProviderID
    var status: QuotaStatus = .ok
    var windows: [QuotaWindow] = []
    var extras: [String] = []   // extra lines (breakdown, extra usage, reset credits...)
    var account = Account()
    var fetchedAt = Date()
    var dataAsOf: Date?         // Codex: timestamp of the log event used
    var sourceNote: String?     // where the numbers came from
    var isStale = false         // network failed, numbers are from a previous fetch

    var session: QuotaWindow? { windows.first { $0.kind == .session } }
    var weekly: QuotaWindow? { windows.first { $0.kind == .weekly } }
}

protocol QuotaProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async -> Quota
}

// MARK: - Shared helpers

enum Net {
    // Ephemeral: no cookies, no disk cache. Tokens are only ever sent to the provider's own host.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func get(_ url: URL, headers: [String: String]) async -> (Int, Data?, String?) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data, nil)
        } catch {
            return (0, nil, error.localizedDescription)
        }
    }
}

func jsonObject(_ data: Data?) -> [String: Any]? {
    guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return o
}

func jsonFile(_ path: String) -> [String: Any]? {
    jsonObject(FileManager.default.contents(atPath: path))
}

func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber, !(v is Bool) { let d = n.doubleValue; return d.isFinite ? d : nil }
    if let s = v as? String { return Double(s) }
    return nil
}

func str(_ v: Any?) -> String? {
    guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseISO(_ v: Any?) -> Date? {
    guard let s = str(v) else { return nil }
    if let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) { return d }
    // Python-style microseconds ("…:59.944732+00:00"): trim to milliseconds.
    if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        let frac = s[s.index(after: dot)..<tz].prefix(3)
        return isoFrac.date(from: String(s[..<dot]) + "." + frac + String(s[tz...]))
    }
    return nil
}

func humanize(_ s: String) -> String {
    s.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

let home = FileManager.default.homeDirectoryForCurrentUser.path

// MARK: - Claude Code

struct ClaudeProvider: QuotaProvider {
    let id = ProviderID.claude
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    var configDir: String {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty { return d }
        return home + "/.claude"
    }

    /// Read-only. `security` is used instead of SecItemCopyMatching because the item's ACL
    /// already trusts /usr/bin/security (Claude Code writes it that way), so no prompt appears.
    func credentials() -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0, let o = jsonObject(data)?["claudeAiOauth"] as? [String: Any] { return o }
        }
        return jsonFile(configDir + "/.credentials.json")?["claudeAiOauth"] as? [String: Any]
    }

    func account(_ creds: [String: Any]) -> Account {
        var a = Account()
        let globalJSON = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { $0 + "/.claude.json" } ?? home + "/.claude.json"
        if let o = jsonFile(globalJSON)?["oauthAccount"] as? [String: Any] {
            a.email = str(o["emailAddress"])
            a.name = str(o["displayName"]) ?? str(o["fullName"])
            a.org = str(o["organizationName"])
        }
        a.plan = Self.planLabel(str(creds["subscriptionType"]), tier: str(creds["rateLimitTier"]))
        return a
    }

    static func planLabel(_ sub: String?, tier: String?) -> String? {
        let t = tier?.lowercased() ?? ""
        if t.contains("20x") { return "Max 20×" }
        if t.contains("5x") { return "Max 5×" }
        guard let s = sub?.lowercased() else { return nil }
        let labels = ["free": "Free", "pro": "Pro", "max": "Max", "max_5x": "Max 5×", "max_20x": "Max 20×",
                      "team": "Team", "enterprise": "Enterprise"]
        return labels[s] ?? humanize(s)
    }

    func fetch() async -> Quota {
        var q = Quota(provider: .claude)
        guard let creds = credentials() else { q.status = .noCredentials; return q }
        q.account = account(creds)
        guard let token = str(creds["accessToken"]) else { q.status = .authExpired; return q }

        let (code, data, err) = await Net.get(Self.usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            // Other user agents are rate limited much harder on this endpoint (HTTP 429).
            "User-Agent": "claude-code/2.1.0",
        ])
        if let err { q.status = .network(err); return q }
        switch code {
        case 200: break
        case 401, 403: q.status = .authExpired; return q
        case 429: q.status = .network("HTTP 429"); return q
        default: q.status = code >= 500 ? .network("HTTP \(code)") : .failed("HTTP \(code)"); return q
        }
        guard let o = jsonObject(data) else { q.status = .failed("JSON"); return q }
        Self.parse(o, into: &q)
        q.sourceNote = "api.anthropic.com"
        return q
    }

    static func parse(_ o: [String: Any], into q: inout Quota) {
        var seen: [String: Int] = [:]   // id -> index in q.windows
        func put(_ id: String, _ w: QuotaWindow) {
            guard w.usedPct != nil || w.resetsAt != nil else { return }
            if let i = seen[id] {
                q.windows[i].usedPct = w.usedPct ?? q.windows[i].usedPct
                q.windows[i].resetsAt = w.resetsAt ?? q.windows[i].resetsAt
            } else { seen[id] = q.windows.count; q.windows.append(w) }
        }
        // Top-level windows: five_hour, seven_day, seven_day_<model>...
        for key in o.keys.sorted() {
            guard let w = o[key] as? [String: Any], w["utilization"] != nil || w["resets_at"] != nil,
                  key == "five_hour" || key.hasPrefix("seven_day") else { continue }
            let win = QuotaWindow(kind: .session, usedPct: num(w["utilization"]), resetsAt: parseISO(w["resets_at"]))
            if key == "five_hour" { put("session", win) }
            else if key == "seven_day" { var x = win; x.kind = .weekly; put("weekly", x) }
            else {
                let raw = String(key.dropFirst("seven_day_".count))
                let label = raw == "oauth_apps" ? "OAuth apps" : humanize(raw)
                var x = win; x.kind = .scoped(label); put("w:" + label.lowercased(), x)
            }
        }
        // Dynamic limits list (current payloads), authoritative when present.
        for l in (o["limits"] as? [[String: Any]]) ?? [] {
            let kind = str(l["kind"]) ?? ""
            let group = str(l["group"]) ?? ""
            let scope = l["scope"] as? [String: Any]
            let model = str((scope?["model"] as? [String: Any])?["display_name"]) ?? str((scope?["model"] as? [String: Any])?["id"])
            let surface = str(scope?["surface"]).map(humanize)
            var w = QuotaWindow(kind: .session, usedPct: num(l["percent"]), resetsAt: parseISO(l["resets_at"]))
            if kind == "session" { put("session", w) }
            else if kind == "weekly_all" { w.kind = .weekly; put("weekly", w) }
            else {
                let scopeLabel = [model, surface.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
                let label = scopeLabel.isEmpty ? humanize(kind) : (group == "weekly" ? scopeLabel : "\(scopeLabel) · \(humanize(kind))")
                w.kind = .scoped(label); put("w:" + label.lowercased(), w)
            }
        }
        if let rows = (o["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] {
            let parts = rows.compactMap { r -> String? in
                guard let n = str(r["display_name"]), let p = num(r["percent"]) else { return nil }
                return "\(n) \(Int(p.rounded()))%"
            }
            if !parts.isEmpty { q.extras.append(tr("Tuần theo nơi dùng: ", "Weekly by surface: ") + parts.joined(separator: " · ")) }
        }
        if let ex = o["extra_usage"] as? [String: Any], ex["is_enabled"] as? Bool == true {
            var s = tr("Extra usage: bật", "Extra usage: on")
            if let used = num(ex["used_credits"]), let lim = num(ex["monthly_limit"]) {
                let dp = Int(num(ex["decimal_places"]) ?? 2)
                let div = pow(10, Double(dp))
                s += String(format: " · %.2f / %.2f %@", used / div, lim / div, str(ex["currency"]) ?? "")
            }
            if let u = num(ex["utilization"]) { s += " (\(Int(u.rounded()))%)" }
            q.extras.append(s)
        }
    }
}

// MARK: - Codex

struct CodexProvider: QuotaProvider {
    let id = ProviderID.codex
    /// Secondary source: only used when the local log has no data, or its data is older than the reset.
    /// Endpoint verified in openai/codex: codex-rs/backend-client (PathStyle::ChatGptApi -> "{base}/wham/usage").
    static let useNetworkFallback = true
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    var codexHome: String {
        if let d = ProcessInfo.processInfo.environment["CODEX_HOME"], !d.isEmpty { return d }
        return home + "/.codex"
    }

    static let planLabels = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
                             "pro_lite": "Pro Lite", "business": "Business", "team": "Team",
                             "enterprise": "Enterprise", "edu": "Edu"]
    static func planLabel(_ s: String?) -> String? {
        guard let s = s?.lowercased(), !s.isEmpty else { return nil }
        return planLabels[s] ?? humanize(s)
    }

    /// Decode only (never verified, never sent anywhere).
    static func jwtClaims(_ jwt: String?) -> [String: Any]? {
        guard let parts = jwt?.split(separator: "."), parts.count >= 2 else { return nil }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return jsonObject(Data(base64Encoded: b))
    }

    func fetch() async -> Quota {
        var q = Quota(provider: .codex)
        let auth = jsonFile(codexHome + "/auth.json")
        let tokens = auth?["tokens"] as? [String: Any]
        let fileEvent = latestRateLimitEvent()
        if auth == nil && fileEvent == nil { q.status = .noCredentials; return q }

        if let c = Self.jwtClaims(str(tokens?["id_token"])) {
            let a = c["https://api.openai.com/auth"] as? [String: Any]
            q.account.email = str(c["email"]) ?? str((c["https://api.openai.com/profile"] as? [String: Any])?["email"])
            q.account.name = str(c["name"])
            q.account.plan = Self.planLabel(str(a?["chatgpt_plan_type"]))
        }

        if let (rl, ts) = fileEvent {
            q.dataAsOf = ts
            q.sourceNote = tr("log phiên Codex", "Codex session log")
            if q.account.plan == nil { q.account.plan = Self.planLabel(str(rl["plan_type"])) }
            let now = Date()
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any] else { continue }
                let minutes = num(w["window_minutes"])
                var reset: Date? = num(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                if reset == nil, let s = num(w["resets_in_seconds"]) { reset = ts.addingTimeInterval(s) }
                var win = QuotaWindow(kind: Self.kind(minutes: minutes, fallback: key), usedPct: num(w["used_percent"]), resetsAt: reset)
                if let r = reset, r < now { win.usedPct = 0; win.noNewData = true; win.resetsAt = nil }
                q.windows.append(win)
            }
        }

        let needNetwork = q.windows.isEmpty || q.windows.contains { $0.noNewData }
        if Self.useNetworkFallback, needNetwork, let token = str(tokens?["access_token"]) {
            var h = ["Authorization": "Bearer \(token)", "Accept": "application/json", "User-Agent": "codex-cli"]
            if let acc = str(tokens?["account_id"]) { h["ChatGPT-Account-Id"] = acc }
            let (code, data, err) = await Net.get(Self.usageURL, headers: h)
            if code == 200, let o = jsonObject(data), Self.parseAPI(o, into: &q) {
                q.dataAsOf = Date(); q.sourceNote = "chatgpt.com"
            } else if q.windows.isEmpty {
                if let err { q.status = .network(err) }
                else if code == 401 || code == 403 { q.status = .authExpired }
                else { q.status = .failed(Self.apiError(code, data)) }
            } else if err == nil {
                q.extras.append("API: " + (code == 401 ? tr("token hết hạn", "token expired") : Self.apiError(code, data)))
            }
        } else if q.windows.isEmpty {
            q.status = .authExpired
        }
        return q
    }

    static func apiError(_ code: Int, _ data: Data?) -> String {
        let e = jsonObject(data)?["error"] as? [String: Any]
        if str(e?["code"]) == "deactivated_workspace" { return tr("workspace đã bị vô hiệu hoá (HTTP \(code))", "workspace deactivated (HTTP \(code))") }
        return "HTTP \(code)" + (str(e?["message"]).map { " – \($0)" } ?? "")
    }

    /// Identify windows by length, never by field name.
    static func kind(minutes: Double?, fallback: String) -> WindowKind {
        guard let m = minutes, m > 0 else { return fallback == "primary" ? .session : .weekly }
        if m <= 6 * 60 { return .session }
        if m >= 6 * 24 * 60 && m <= 8 * 24 * 60 { return .weekly }
        let label = m.truncatingRemainder(dividingBy: 1440) == 0 ? "\(Int(m / 1440))d" : "\(Int(m / 60))h"
        return .scoped(label)
    }

    static func parseAPI(_ o: [String: Any], into q: inout Quota) -> Bool {
        var wins: [QuotaWindow] = []
        func add(_ rl: [String: Any]?, prefix: String?) {
            for key in ["primary_window", "secondary_window"] {
                guard let w = rl?[key] as? [String: Any] else { continue }
                let secs = num(w["limit_window_seconds"])
                var reset = num(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                if reset == nil, let s = num(w["reset_after_seconds"]) { reset = Date().addingTimeInterval(s) }
                var k = kind(minutes: secs.map { $0 / 60 }, fallback: key == "primary_window" ? "primary" : "secondary")
                if let prefix {
                    let base: String
                    switch k { case .session: base = "5h"; case .weekly: base = tr("tuần", "weekly"); case .scoped(let s): base = s }
                    k = .scoped("\(prefix) · \(base)")
                }
                let win = QuotaWindow(kind: k, usedPct: num(w["used_percent"]), resetsAt: reset)
                if win.usedPct != nil || win.resetsAt != nil { wins.append(win) }
            }
        }
        add(o["rate_limit"] as? [String: Any], prefix: nil)
        add(o["code_review_rate_limit"] as? [String: Any], prefix: "Code Review")
        for (i, a) in ((o["additional_rate_limits"] as? [[String: Any]]) ?? []).enumerated() {
            add(a["rate_limit"] as? [String: Any], prefix: str(a["limit_name"]) ?? str(a["metered_feature"]) ?? "Limit \(i + 1)")
        }
        guard !wins.isEmpty else { return false }
        q.windows = wins
        if let p = planLabel(str(o["plan_type"])) { q.account.plan = p }
        if let n = num((o["rate_limit_reset_credits"] as? [String: Any])?["available_count"]) {
            q.extras.append(tr("Lượt reset giới hạn còn: \(Int(n))", "Limit resets available: \(Int(n))"))
        }
        return true
    }

    /// Newest `token_count` event with `rate_limits`, read from the tail of the newest rollout files.
    func latestRateLimitEvent() -> ([String: Any], Date)? {
        let files = rolloutFiles().prefix(8)
        for f in files {
            if let e = tailScan(f) { return e }
        }
        return nil
    }

    func rolloutFiles() -> [String] {
        var out: [(String, Date)] = []
        let fm = FileManager.default
        for dir in [codexHome + "/sessions"] {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in en where u.lastPathComponent.hasPrefix("rollout-") && u.pathExtension == "jsonl" {
                let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                out.append((u.path, d))
            }
        }
        return out.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    private func tailScan(_ path: String) -> ([String: Any], Date)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var end = size
        var carry = Data()
        let chunk: UInt64 = 512 * 1024
        var scanned: UInt64 = 0
        while end > 0 && scanned < 16 * 1024 * 1024 {
            let start = end > chunk ? end - chunk : 0
            try? fh.seek(toOffset: start)
            var buf = fh.readData(ofLength: Int(end - start))
            buf.append(carry)
            // Keep the first (possibly partial) line for the next iteration.
            var lines = buf.split(separator: 0x0A, omittingEmptySubsequences: false)
            carry = start > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() where line.range(of: Data("\"rate_limits\"".utf8)) != nil
                && line.range(of: Data("\"token_count\"".utf8)) != nil {
                guard let o = jsonObject(Data(line)), let p = o["payload"] as? [String: Any],
                      let rl = (p["rate_limits"] ?? o["rate_limits"]) as? [String: Any],
                      rl["primary"] is [String: Any] || rl["secondary"] is [String: Any] else { continue }
                if let lid = str(rl["limit_id"]), lid != "codex" { continue }
                return (rl, parseISO(o["timestamp"]) ?? Date())
            }
            scanned += end - start
            end = start
        }
        return nil
    }
}
