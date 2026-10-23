import Foundation

// Local usage statistics, the TokenWatch part: reads the JSONL logs Claude Code and Codex already
// write, aggregates tokens per hour/model, prices them. Only counts are kept, never content.
// Incremental: per-file offsets are cached in ~/Library/Caches/VibeToken, so only new bytes are parsed.

enum Source: String, Codable { case claude, codex }

struct Tokens: Codable {
    var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0
    var cost: Double = 0
    var turns: Int = 0
    var total: Int64 { input + output + cacheRead + cacheWrite + reasoning }

    enum CodingKeys: String, CodingKey { case input = "i", output = "o", cacheRead = "r", cacheWrite = "w", reasoning = "x", cost = "c", turns = "t" }

    mutating func add(_ o: Tokens, _ sign: Int64 = 1) {
        input += sign * o.input; output += sign * o.output; cacheRead += sign * o.cacheRead
        cacheWrite += sign * o.cacheWrite; reasoning += sign * o.reasoning
        cost += Double(sign) * o.cost; turns += Int(sign) * o.turns
    }
}

// MARK: - Pricing (USD per 1M tokens), bundled table from TokenWatch

struct Rate: Codable { var input: Double; var cached: Double; var cacheWrite: Double = 0; var output: Double }

enum Pricing {
    static let longContextThreshold: Int64 = 272_000

    static let bundled: [String: Rate] = {
        var t: [String: Rate] = [:]
        func r(_ i: Double, _ c: Double, _ o: Double, w: Double = 0, _ ids: String...) { for id in ids { t[id] = Rate(input: i, cached: c, cacheWrite: w, output: o) } }
        // GPT / Codex
        r(1.25, 0.125, 10, "gpt-5", "gpt-5-codex", "gpt-5-chat-latest", "gpt-5.1", "gpt-5.1-chat-latest", "gpt-5.1-codex", "gpt-5.1-codex-max")
        r(0.25, 0.025, 2, "gpt-5-codex-mini", "gpt-5-mini", "gpt-5.1-codex-mini")
        r(0.05, 0.005, 0.4, "gpt-5-nano")
        r(15, 0, 120, "gpt-5-pro")
        r(1.75, 0.175, 14, "gpt-5.2", "gpt-5.2-chat-latest", "gpt-5.2-codex", "gpt-5.3-chat-latest", "gpt-5.3-codex")
        r(21, 0, 168, "gpt-5.2-pro")
        r(2, 1, 8, "gpt-5.3-codex-spark")
        r(2.5, 0.25, 15, "gpt-5.4", "codex-auto-review")
        r(5, 0.5, 22.5, "gpt-5.4-long-context")
        r(0.75, 0.075, 4.5, "gpt-5.4-mini")
        r(30, 0, 180, "gpt-5.4-pro", "gpt-5.5-pro")
        r(60, 0, 270, "gpt-5.4-pro-long-context", "gpt-5.5-pro-long-context")
        r(5, 0.5, 30, "gpt-5.5")
        r(10, 1, 45, "gpt-5.5-long-context")
        r(4, 0.4, 20, w: 5, "gpt-5.6-sol")
        r(8, 0.8, 30, w: 10, "gpt-5.6-sol-long-context")
        r(2, 0.2, 12, w: 2.5, "gpt-5.6-terra")
        r(4, 0.4, 18, w: 5, "gpt-5.6-terra-long-context")
        r(0.2, 0.02, 1.2, w: 0.25, "gpt-5.6-luna")
        r(0.4, 0.04, 1.8, w: 0.5, "gpt-5.6-luna-long-context")
        r(10, 1, 50, w: 12.5, "gpt-6-astra")
        r(20, 2, 75, w: 25, "gpt-6-astra-long-context")
        r(2, 0.2, 10, w: 2.5, "gpt-6-sol")
        r(4, 0.4, 15, w: 5, "gpt-6-sol-long-context")
        r(0.1, 0.01, 0.5, w: 0.125, "gpt-6-luna")
        r(0.2, 0.02, 0.75, w: 0.25, "gpt-6-luna-long-context")
        r(2, 0.1, 10, w: 2.5, "gpt-6.1-sol")
        r(4, 0.2, 15, w: 5, "gpt-6.1-sol-long-context")
        r(2, 0.5, 8, "gpt-4.1", "o3")
        r(0.4, 0.1, 1.6, "gpt-4.1-mini")
        r(0.1, 0.025, 0.4, "gpt-4.1-nano")
        r(2.5, 1.25, 10, "gpt-4o")
        r(0.15, 0.075, 0.6, "gpt-4o-mini")
        r(1.1, 0.55, 4.4, "o3-mini")
        r(1.1, 0.275, 4.4, "o4-mini")
        r(1.5, 0.375, 6, "codex-mini-latest")
        // Claude (cache write = 5m price)
        r(4, 0.2, 20, w: 5, "claude-opus-5-5")
        r(5, 0.5, 25, w: 6.25, "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5")
        r(15, 1.5, 75, w: 18.75, "claude-opus-4-1", "claude-opus-4")
        r(10, 0.25, 50, w: 12.5, "claude-fable-5-1", "claude-mythos-5-1")
        r(10, 1, 50, w: 12.5, "claude-fable-5")
        r(2, 0.2, 10, w: 2.5, "claude-sonnet-5-5", "claude-sonnet-5")
        r(3, 0.3, 15, w: 3.75, "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4", "claude-3-7-sonnet")
        r(0.1, 0.01, 0.5, w: 0.125, "claude-haiku-5-5")
        r(1, 0.1, 5, w: 1.25, "claude-haiku-4-5")
        r(0.8, 0.08, 4, w: 1, "claude-haiku-3-5", "claude-3-5-haiku")
        return t
    }()
    static let fallback = Rate(input: 1.25, cached: 0.125, output: 10)

    static var overridesPath: String { home + "/Library/Application Support/VibeToken/pricing.json" }

    /// Optional user overrides: { "model-id": { "input": 1.25, "cached": 0.125, "cacheWrite": 0, "output": 10 } } (USD / 1M).
    static let table: [String: Rate] = {
        var t = bundled
        if let o = jsonFile(overridesPath) {
            for (k, v) in o where !k.hasPrefix("$") {
                guard let d = v as? [String: Any], let i = num(d["input"]), let out = num(d["output"]), i >= 0, out >= 0 else { continue }
                t[k.lowercased()] = Rate(input: i, cached: num(d["cached"]) ?? 0, cacheWrite: num(d["cacheWrite"]) ?? 0, output: out)
            }
        }
        return t
    }()
    static let signature: String = table.keys.sorted().map { k in let r = table[k]!; return "\(k)\(r.input)\(r.cached)\(r.cacheWrite)\(r.output)" }.joined().hashValueStable

    /// Normalizes ids: dots -> dashes for Claude, strips "[1m]", date suffixes, then longest prefix match.
    static func rate(_ model: String, longContext: Bool) -> (Rate, known: Bool) {
        var m = model.lowercased().replacingOccurrences(of: "[1m]", with: "")
        if m.hasPrefix("claude") { m = m.replacingOccurrences(of: ".", with: "-") }
        if longContext, let r = lookup(m + "-long-context") { return (r, true) }
        if let r = lookup(m) { return (r, true) }
        return (fallback, false)
    }

    private static func lookup(_ m: String) -> Rate? {
        if let r = table[m] { return r }
        let stripped = m.replacingOccurrences(of: #"-\d{4}-?\d{2}-?\d{2}$"#, with: "", options: .regularExpression)
        if let r = table[stripped] { return r }
        return table.keys.filter { stripped.hasPrefix($0 + "-") }.max { $0.count < $1.count }.flatMap { table[$0] }
    }

    static func isKnown(_ model: String) -> Bool { rate(model, longContext: false).known }

    static func cost(_ model: String, _ t: Tokens, longContext: Bool = false) -> Double {
        let r = rate(model, longContext: longContext).0
        return (Double(t.input) * r.input + Double(t.cacheRead) * r.cached + Double(t.cacheWrite) * r.cacheWrite
                + Double(t.output + t.reasoning) * r.output) / 1_000_000
    }
}

extension String {
    /// FNV-1a, stable across launches (Swift's hashValue is seeded).
    var hashValueStable: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

// MARK: - Per-file cached state

struct FileState: Codable {
    var source: Source
    var size: Int64 = 0
    var mtime: Double = 0
    var offset: Int64 = 0
    var session = ""
    var cwd = ""
    var lastTs: Double = 0
    var buckets: [String: Tokens] = [:]     // "hour|model|effort"
    var tools: [String: Int] = [:]          // "hour|name"
    // Context of the last turn (for the "context" line, like Claude Code's context panel)
    var ctxUsed: Int64 = 0
    var ctxWindow: Int64 = 0
    var ctxModel = ""
    // Codex parser state
    var model = ""
    var effort = ""
    var prevTotals: [Int64] = []            // input, cached, output, reasoning
    // Claude parser state: last request (log repeats a request across lines, last one wins)
    var lastReq = ""
    var lastReqKey = ""
    var lastReqTokens = Tokens()
}

struct CacheFile: Codable { var version: Int; var pricing: String; var files: [String: FileState] }

// MARK: - Scanner

final class UsageStore {
    static let cacheVersion = 4
    private let queue = DispatchQueue(label: "vibetoken.scan", qos: .utility)
    private var files: [String: FileState] = [:]
    private var loaded = false
    private var scanning = false

    /// Read on the main thread only.
    private(set) var snapshot: [String: FileState] = [:]
    private(set) var lastScan: Date?

    var cachePath: String { home + "/Library/Caches/VibeToken/usage.plist" }

    func scan(reset: Bool = false, completion: @escaping () -> Void) {
        queue.async { [self] in
            if scanning { return }
            scanning = true
            if reset { files = [:]; loaded = true; try? FileManager.default.removeItem(atPath: cachePath) }
            if !loaded { loadCache(); loaded = true }
            var changed = false
            var present = Set<String>()
            for (path, source, size, mtime) in discover() {
                present.insert(path)
                var st = files[path] ?? FileState(source: source)
                if st.size == size && st.mtime == mtime { continue }
                if size < st.offset { st = FileState(source: source) }     // truncated / rewritten
                parse(path, &st)
                st.size = size; st.mtime = mtime
                files[path] = st
                changed = true
            }
            // Keep history of deleted logs (TokenWatch keeps totals too); drop only entries never parsed.
            for (p, st) in files where !present.contains(p) && st.buckets.isEmpty { files[p] = nil; changed = true }
            if changed { saveCache() }
            let snap = files
            scanning = false
            DispatchQueue.main.async { self.snapshot = snap; self.lastScan = Date(); completion() }
        }
    }

    private func loadCache() {
        guard let d = FileManager.default.contents(atPath: cachePath),
              let c = try? PropertyListDecoder().decode(CacheFile.self, from: d),
              c.version == Self.cacheVersion, c.pricing == Pricing.signature else { return }
        files = c.files
    }

    private func saveCache() {
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        guard let d = try? enc.encode(CacheFile(version: Self.cacheVersion, pricing: Pricing.signature, files: files)) else { return }
        try? FileManager.default.createDirectory(atPath: (cachePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
    }

    private func discover() -> [(String, Source, Int64, Double)] {
        let env = ProcessInfo.processInfo.environment
        var claudeRoots = [home + "/.claude/projects", home + "/.config/claude/projects"]
        if let d = env["CLAUDE_CONFIG_DIR"], !d.isEmpty { claudeRoots.insert(d + "/projects", at: 0) }
        let codexHome = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
        var out: [(String, Source, Int64, Double)] = []
        var seen = Set<String>()
        func walk(_ root: String, _ src: Source) {
            let url = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for case let u as URL in en where u.pathExtension == "jsonl" {
                if src == .codex && !u.lastPathComponent.hasPrefix("rollout-") { continue }
                guard seen.insert(u.path).inserted,
                      let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                out.append((u.path, src, Int64(v.fileSize ?? 0), v.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        for r in claudeRoots { walk(r, .claude) }
        walk(codexHome + "/sessions", .codex)
        walk(codexHome + "/archived_sessions", .codex)
        return out
    }

    // MARK: Parsing

    private func parse(_ path: String, _ st: inout FileState) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(st.offset))
        if st.source == .claude && st.session.isEmpty {
            st.session = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        var pending = Data()
        var skipping = false                 // inside a long line already known to be irrelevant
        var chunkStart = st.offset           // file offset of the current chunk
        var lineStart = st.offset            // file offset of the line being assembled
        let isCodex = st.source == .codex
        var done = false
        while !done { autoreleasepool {
            let chunk = fh.readData(ofLength: 4 << 20)
            if chunk.isEmpty { done = true; return }
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let n = raw.count
                var i = 0
                while i < n {
                    let nl = memchr(base + i, 0x0A, n - i).map { UnsafePointer<UInt8>($0.assumingMemoryBound(to: UInt8.self)) - base }
                    if !skipping {
                        pending.append(base + i, count: (nl ?? n) - i)
                        if nl == nil && isCodex && pending.count > 512 && !codexRelevant(pending) { skipping = true; pending.removeAll() }
                    }
                    guard let nl else { break }
                    if !skipping && !pending.isEmpty {
                        if isCodex { if codexRelevant(pending) { codexLine(pending, &st) } } else { claudeLine(pending, &st) }
                    }
                    pending.removeAll(keepingCapacity: pending.count < 1 << 20)
                    skipping = false
                    i = nl + 1
                    lineStart = chunkStart + Int64(i)
                }
            }
            chunkStart += Int64(chunk.count)
            st.offset = lineStart
        } }
        // A partial final line (still being written) is re-read next time.
    }

    private static let markers = ["\"token_count\"", "\"turn_context\"", "\"session_meta\""].map { Data($0.utf8) }
    private static let payloadType = Data("\"payload\":{\"type\":\"".utf8)

    /// `function_call`, `custom_tool_call`, `local_shell_call`, `web_search_call`, … (not `*_output`).
    private func codexToolType(_ head: Data) -> String? {
        guard let r = head.range(of: Self.payloadType), let q = head[r.upperBound...].firstIndex(of: 0x22) else { return nil }
        let t = String(decoding: head[r.upperBound..<q], as: UTF8.self)
        return t.hasSuffix("_call") ? t : nil
    }

    private func codexRelevant(_ line: Data) -> Bool {
        let head = line.prefix(300)
        return Self.markers.contains { head.range(of: $0) != nil } || codexToolType(head) != nil
    }

    private func codexLine(_ line: Data, _ st: inout FileState) {
        if let type = codexToolType(line.prefix(300)) {
            // Only the tool name is needed; avoid parsing huge arguments.
            var name = type == "local_shell_call" ? "shell" : String(type.dropLast("_call".count))
            if type == "function_call" || type == "custom_tool_call", let r = line.range(of: Data("\"name\":\"".utf8)),
               let q = line[r.upperBound...].firstIndex(of: 0x22) {
                name = String(decoding: line[r.upperBound..<q], as: UTF8.self)
            }
            let hour = Self.hour(Self.timestamp(line) ?? st.lastTs)
            st.tools["\(hour)|\(name)", default: 0] += 1
            return
        }
        guard let o = jsonObject(line), let type = o["type"] as? String, let p = o["payload"] as? [String: Any] else { return }
        let ts = Self.timestamp(line) ?? st.lastTs
        switch type {
        case "session_meta":
            if let id = str(p["id"]) { st.session = id }
            if let c = str(p["cwd"]) { st.cwd = c }
        case "turn_context":
            if let m = str(p["model"]) { st.model = m }
            st.effort = str(p["effort"]) ?? str((p["collaboration_mode"] as? [String: Any])?["reasoning_effort"]) ?? ""
            if st.cwd.isEmpty, let c = str(p["cwd"]) { st.cwd = c }
        case "event_msg" where str(p["type"]) == "token_count":
            guard let info = (p["info"] ?? o["info"]) as? [String: Any], !st.model.isEmpty else { return }
            let last = info["last_token_usage"] as? [String: Any]
            func v(_ d: [String: Any]?, _ k: String) -> Int64 { Int64(num(d?[k]) ?? 0) }
            var input: Int64, cached: Int64, output: Int64, reasoning: Int64
            if let total = info["total_token_usage"] as? [String: Any] {
                let next = [v(total, "input_tokens"), v(total, "cached_input_tokens"), v(total, "output_tokens"), v(total, "reasoning_output_tokens")]
                let prev = st.prevTotals.count == 4 ? st.prevTotals : [0, 0, 0, 0]
                let restarted = next[0] + next[2] < prev[0] + prev[2]
                let d = restarted ? next : zip(next, prev).map { $0 - $1 }
                st.prevTotals = next
                let consumed = d[0] + d[2]
                guard consumed > 0 else { return }
                input = min(max(0, d[0]), consumed); output = consumed - input
                cached = min(max(0, d[1]), input); reasoning = min(max(0, d[3]), output)
            } else if let last, last["input_tokens"] != nil {
                input = v(last, "input_tokens"); cached = v(last, "cached_input_tokens")
                output = v(last, "output_tokens"); reasoning = v(last, "reasoning_output_tokens")
            } else { return }
            var t = Tokens()
            t.cacheRead = min(cached, input); t.input = input - t.cacheRead
            t.reasoning = min(reasoning, output); t.output = output - t.reasoning
            t.turns = 1
            let ctx = v(last, "input_tokens")
            t.cost = Pricing.cost(st.model, t, longContext: ctx > Pricing.longContextThreshold)
            st.buckets["\(Self.hour(ts))|\(st.model)|\(st.effort)", default: Tokens()].add(t)
            st.lastTs = max(st.lastTs, ts)
            st.ctxUsed = ctx; st.ctxModel = st.model
            st.ctxWindow = Int64(num(info["model_context_window"]) ?? 0)
        default: break
        }
    }

    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)

    private func claudeLine(_ line: Data, _ st: inout FileState) {
        guard line.range(of: Self.usageMarker) != nil, line.range(of: Self.assistantMarker) != nil,
              let o = jsonObject(line), str(o["type"]) == "assistant",
              let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
              let model = str(msg["model"]), !model.hasPrefix("<"), model != "unknown" else { return }
        let ts = parseISO(o["timestamp"])?.timeIntervalSince1970 ?? st.lastTs
        if let c = str(o["cwd"]) { st.cwd = c }
        if let s = str(o["sessionId"]) { st.session = s }
        let effortRaw = (msg["output_config"] as? [String: Any])?["effort"] ?? msg["effort"]
            ?? (o["output_config"] as? [String: Any])?["effort"] ?? o["effort"]
        let effort = str(effortRaw) ?? ""
        var t = Tokens()
        t.input = Int64(num(u["input_tokens"]) ?? 0)
        t.output = Int64(num(u["output_tokens"]) ?? 0)
        t.cacheRead = Int64(num(u["cache_read_input_tokens"]) ?? 0)
        t.cacheWrite = Int64(num(u["cache_creation_input_tokens"]) ?? 0)
        t.turns = 1
        t.cost = Pricing.cost(model, t)
        let key = "\(Self.hour(ts))|\(model)|\(effort)"
        let req = str(o["requestId"]) ?? str(msg["id"]) ?? str(o["uuid"]) ?? ""
        if !req.isEmpty && req == st.lastReq {
            st.buckets[st.lastReqKey]?.add(st.lastReqTokens, -1)   // same request logged again: replace
        }
        st.buckets[key, default: Tokens()].add(t)
        st.lastReq = req; st.lastReqKey = key; st.lastReqTokens = t
        let hour = Self.hour(ts)
        for b in (msg["content"] as? [[String: Any]]) ?? [] where str(b["type"]) == "tool_use" {
            st.tools["\(hour)|\(str(b["name"]) ?? "unknown")", default: 0] += 1
        }
        st.lastTs = max(st.lastTs, ts)
        if o["isSidechain"] as? Bool != true {
            st.ctxUsed = t.input + t.cacheRead + t.cacheWrite; st.ctxModel = model
        }
    }

    static func hour(_ ts: Double) -> Int { Int((ts / 3600).rounded(.down)) }

    /// Fast path for `"timestamp":"2026-10-23T17:17:44.615Z"` without a date formatter.
    static func timestamp(_ line: Data) -> Double? {
        guard let r = line.prefix(400).range(of: Data("\"timestamp\":\"".utf8)) else { return nil }
        let s = line[r.upperBound...].prefix(30)
        let b = Array(s)
        guard b.count >= 19 else { return nil }
        func n(_ a: Int, _ len: Int) -> Int? {
            var v = 0
            for k in a..<(a + len) { let c = Int(b[k]) - 48; guard c >= 0 && c <= 9 else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = n(0, 4), let mo = n(5, 2), let d = n(8, 2), let h = n(11, 2), let mi = n(14, 2), let se = n(17, 2) else { return nil }
        // days from civil (H. Hinnant)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        var t = Double(days * 86400 + h * 3600 + mi * 60 + se)
        // Offsets other than Z (rare) are applied when present.
        if b.count > 19 {
            var k = 19
            if b[k] == 0x2E { k += 1; while k < b.count, b[k] >= 48 && b[k] <= 57 { k += 1 } }
            if k + 5 < b.count, b[k] == 0x2B || b[k] == 0x2D, let oh = n(k + 1, 2), let om = n(k + 4, 2) {
                t -= Double(b[k] == 0x2B ? 1 : -1) * Double(oh * 3600 + om * 60)
            }
        }
        return t
    }
}

// MARK: - Queries (TokenWatch periods)

enum Period: String, CaseIterable { case today, day, week, month, year }
enum Filter: String, CaseIterable { case all, codex, claude }
enum TrendMetric: String, CaseIterable { case tokens, cost, turns }

struct ModelRow { var model: String; var source: Source; var effort: String; var t = Tokens() }
struct SessionRow { var id: String; var source: Source; var project: String; var t = Tokens(); var last: Double = 0; var models = Set<String>() }

struct Summary {
    var period: Period
    var t = Tokens()
    var prev = Tokens()
    var tools: [Source: [String: Int]] = [:]
    var models: [ModelRow] = []
    var sessions: [SessionRow] = []
    var trend: [(label: String, t: Tokens)] = []
    var activeBuckets = 0
    var toolCount: Int { tools.values.reduce(0) { $0 + $1.values.reduce(0, +) } }
}

struct ContextInfo { var source: Source; var project: String; var model: String; var used: Int64; var window: Int64; var last: Double }

extension UsageStore {
    static func range(_ p: Period, now: Date = Date()) -> (from: Date, to: Date, prevFrom: Date, buckets: [(Date, Date)]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        func add(_ c: Calendar.Component, _ v: Int, _ d: Date) -> Date { cal.date(byAdding: c, value: v, to: d)! }
        switch p {
        case .today:
            let b = (0..<24).map { (add(.hour, $0, today), add(.hour, $0 + 1, today)) }
            return (today, tomorrow, add(.day, -1, today), b)
        case .day:
            let from = add(.day, -6, today)
            return (from, tomorrow, add(.day, -7, from), (0..<7).map { (add(.day, $0, from), add(.day, $0 + 1, from)) })
        case .week:
            var c = cal; c.firstWeekday = 2
            let ws = c.dateInterval(of: .weekOfYear, for: now)!.start
            let from = add(.weekOfYear, -6, ws)
            return (from, tomorrow, add(.weekOfYear, -7, from), (0..<7).map { (add(.weekOfYear, $0, from), min(tomorrow, add(.weekOfYear, $0 + 1, from))) })
        case .month:
            let ms = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let from = add(.month, -5, ms)
            return (from, tomorrow, add(.month, -6, from), (0..<6).map { (add(.month, $0, from), min(tomorrow, add(.month, $0 + 1, from))) })
        case .year:
            let ys = cal.date(from: cal.dateComponents([.year], from: now))!
            let from = add(.year, -1, ys)
            return (from, tomorrow, add(.year, -2, from), (0..<2).map { (add(.year, $0, from), min(tomorrow, add(.year, $0 + 1, from))) })
        }
    }

    func summary(_ period: Period, _ filter: Filter, now: Date = Date()) -> Summary {
        let r = Self.range(period, now: now)
        let from = r.from.timeIntervalSince1970, to = r.to.timeIntervalSince1970, prevFrom = r.prevFrom.timeIntervalSince1970
        var s = Summary(period: period)
        var buckets = [Tokens](repeating: Tokens(), count: r.buckets.count)
        let edges = r.buckets.map { ($0.0.timeIntervalSince1970, $0.1.timeIntervalSince1970) }
        var models: [String: ModelRow] = [:]
        var sessions: [String: SessionRow] = [:]
        for st in snapshot.values {
            if filter == .codex && st.source != .codex || filter == .claude && st.source != .claude { continue }
            for (k, t) in st.buckets {
                let parts = k.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let h = Int(parts[0]) else { continue }
                let ts = Double(h) * 3600
                if ts >= prevFrom && ts < from { s.prev.add(t); continue }
                guard ts >= from && ts < to else { continue }
                s.t.add(t)
                if let i = edges.firstIndex(where: { ts >= $0.0 && ts < $0.1 }) { buckets[i].add(t) }
                let model = String(parts[1]), effort = String(parts[2])
                let mk = "\(st.source.rawValue)|\(model)|\(effort)"
                models[mk, default: ModelRow(model: model, source: st.source, effort: effort)].t.add(t)
                let sid = st.session.isEmpty ? k : st.session
                var row = sessions[sid] ?? SessionRow(id: sid, source: st.source, project: (st.cwd as NSString).lastPathComponent)
                row.t.add(t); row.last = max(row.last, ts); row.models.insert(model)
                if row.project.isEmpty { row.project = (st.cwd as NSString).lastPathComponent }
                sessions[sid] = row
            }
            for (k, n) in st.tools {
                guard let bar = k.firstIndex(of: "|"), let h = Int(k[..<bar]) else { continue }
                let ts = Double(h) * 3600
                guard ts >= from && ts < to else { continue }
                s.tools[st.source, default: [:]][String(k[k.index(after: bar)...]), default: 0] += n
            }
        }
        s.models = models.values.sorted { $0.t.total > $1.t.total }
        s.sessions = sessions.values.sorted { $0.t.cost > $1.t.cost }
        s.activeBuckets = buckets.filter { $0.total > 0 }.count
        let f = DateFormatter()
        f.locale = Locale(identifier: lang == "vi" ? "vi_VN" : "en_US")
        switch period {
        case .today: f.dateFormat = "HH"
        case .day, .week: f.dateFormat = "dd/MM"
        case .month: f.dateFormat = "MM/yy"
        case .year: f.dateFormat = "yyyy"
        }
        s.trend = r.buckets.indices.map { (label: f.string(from: r.buckets[$0].0), t: buckets[$0]) }
        return s
    }

    /// Latest main-thread context per source (like Claude Code's "Context x% used").
    func latestContext(_ source: Source) -> ContextInfo? {
        guard let st = snapshot.values.filter({ $0.source == source && $0.ctxUsed > 0 }).max(by: { $0.lastTs < $1.lastTs }) else { return nil }
        var window = st.ctxWindow
        if window <= 0 {
            let m = st.ctxModel.lowercased()
            let big = m.contains("[1m]") || ["opus-5", "sonnet-5", "fable-5", "mythos-5", "opus-4-6", "opus-4-7", "opus-4-8", "sonnet-4-6"].contains { m.contains($0) }
            window = big || st.ctxUsed > 200_000 ? 1_000_000 : 200_000
        }
        return ContextInfo(source: source, project: (st.cwd as NSString).lastPathComponent, model: st.ctxModel, used: st.ctxUsed, window: window, last: st.lastTs)
    }

    /// Today / this week / this month totals for cost alerts (all sources).
    func costSince(_ d: Date) -> Double {
        let from = d.timeIntervalSince1970
        var c = 0.0
        for st in snapshot.values { for (k, t) in st.buckets {
            if let bar = k.firstIndex(of: "|"), let h = Int(k[..<bar]), Double(h) * 3600 >= from { c += t.cost }
        } }
        return c
    }
}
