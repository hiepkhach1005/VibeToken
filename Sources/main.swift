import AppKit
import ServiceManagement
import UserNotifications

// MARK: - Preferences & localisation

let defaults = UserDefaults.standard
var lang: String { defaults.string(forKey: "lang") ?? "en" }
func tr(_ vi: String, _ en: String) -> String { lang == "vi" ? vi : en }

// MARK: - Formatting

enum Fmt {
    static func tokens(_ v: Int64) -> String {
        let d = Double(v)
        switch abs(d) {
        case ..<1_000: return "\(v)"
        case ..<1_000_000: return String(format: "%.1fK", d / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", d / 1_000_000)
        default: return String(format: "%.2fB", d / 1_000_000_000)
        }
    }
    static func usd(_ v: Double) -> String {
        if v >= 1000 { return "$" + (NumberFormatter.localizedString(from: NSNumber(value: Int(v.rounded())), number: .decimal)) }
        return String(format: v > 0 && v < 0.01 ? "$%.3f" : "$%.2f", v)
    }
    static func pct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))%" : String(format: "%.1f%%", r)
    }
    static func df(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: lang == "vi" ? "vi_VN" : "en_US"); f.dateFormat = format; return f
    }
    static func time(_ d: Date) -> String { df("HH:mm").string(from: d) }

    /// "1g12p" / "1h 12m", "6 ngày" / "6 days".
    static func remaining(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(d.timeIntervalSince(now)))
        let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if days >= 2 { return tr("\(days) ngày", "\(days) days") }
        if days == 1 { return tr("1 ngày \(h)g", "1 day \(h)h") }
        if h > 0 { return tr("\(h)g\(String(format: "%02d", m))p", "\(h)h \(m)m") }
        return tr("\(max(m, 1))p", "\(max(m, 1))m")
    }

    static func reset(_ d: Date, now: Date = Date()) -> String {
        let at = d.timeIntervalSince(now) < 20 * 3600
            ? tr("lúc ", "at ") + time(d)
            : df(tr("EEEE dd/MM", "EEE MMM d")).string(from: d).capitalizedFirst
        return tr("reset \(at) (còn \(remaining(d, now: now)))", "resets \(at) (in \(remaining(d, now: now)))")
    }

    static func ago(_ ts: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: lang == "vi" ? "vi_VN" : "en_US"); f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}

extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }

func pctColor(_ p: Double) -> NSColor { p >= 90 ? .systemRed : p >= 70 ? .systemOrange : .systemGreen }

// MARK: - Menu item views (dynamic colours -> follow light/dark automatically)

let menuInset: CGFloat = 17
let viewWidth: CGFloat = 440

final class QuotaRowView: NSView {
    let title: String, pct: Double?, detail: String
    init(title: String, pct: Double?, detail: String) {
        self.title = title; self.pct = pct; self.detail = detail
        super.init(frame: NSRect(x: 0, y: 0, width: viewWidth, height: 44))
        autoresizingMask = [.width]     // stretch to the menu's width
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width - menuInset * 2
        let titleAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let pctAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let detailAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        (title as NSString).draw(at: NSPoint(x: menuInset, y: 25), withAttributes: titleAttr)
        let p = Fmt.pct(pct.map { 100 - $0 }) as NSString
        let ps = p.size(withAttributes: pctAttr)
        p.draw(at: NSPoint(x: menuInset + w - ps.width, y: 25), withAttributes: pctAttr)
        let track = NSRect(x: menuInset, y: 18, width: w, height: 5)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if let pct {
            var fill = track; fill.size.width = max(0, min(1, (100 - pct) / 100)) * w
            pctColor(pct).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        }
        (detail as NSString).draw(at: NSPoint(x: menuInset, y: 2), withAttributes: detailAttr)
    }
}

final class TrendView: NSView {
    let bars: [(label: String, value: Double)]
    let format: (Double) -> String
    let footer: String
    init(bars: [(String, Double)], format: @escaping (Double) -> String, footer: String) {
        self.bars = bars; self.format = format; self.footer = footer
        super.init(frame: NSRect(x: 0, y: 0, width: viewWidth, height: 118))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let axisW: CGFloat = 38
        let plot = NSRect(x: menuInset + axisW, y: 30, width: bounds.width - menuInset * 2 - axisW, height: 76)
        let maxV = max(bars.map(\.value).max() ?? 0, 0.000001)
        // grid + y labels
        for (i, f) in [0.0, 0.5, 1.0].enumerated() {
            let y = plot.minY + plot.height * f
            NSColor.separatorColor.setFill()
            NSRect(x: plot.minX, y: y, width: plot.width, height: 0.5).fill()
            let s = (i == 0 ? "0" : format(maxV * f)) as NSString
            s.draw(at: NSPoint(x: menuInset, y: y - 6), withAttributes: small)
        }
        let n = max(bars.count, 1)
        let slot = plot.width / CGFloat(n)
        let bw = max(2, min(22, slot * 0.6))
        let labelEvery = n > 12 ? 4 : 1
        for (i, b) in bars.enumerated() {
            let x = plot.minX + slot * CGFloat(i) + (slot - bw) / 2
            let h = plot.height * CGFloat(b.value / maxV)
            if b.value > 0 {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: plot.minY, width: bw, height: max(h, 1.5)), xRadius: 2, yRadius: 2).fill()
            }
            if i % labelEvery == 0 {
                let s = b.label as NSString
                let sw = s.size(withAttributes: small).width
                s.draw(at: NSPoint(x: x + bw / 2 - sw / 2, y: plot.minY - 14), withAttributes: small)
            }
        }
        (footer as NSString).draw(at: NSPoint(x: menuInset, y: 1),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let providers: [any QuotaProvider] = [ClaudeProvider(), CodexProvider()]
    var quotas: [ProviderID: Quota] = [:]
    let store = UsageStore()
    var timer: Timer?
    var lastUpdate: Date?
    var refreshing = false
    var quickRetries = 0
    var appearanceObs: NSKeyValueObservation?

    var filter: Filter { Filter(rawValue: defaults.string(forKey: "filter") ?? "") ?? .all }
    var period: Period { Period(rawValue: defaults.string(forKey: "period") ?? "") ?? .today }
    var metric: TrendMetric { TrendMetric(rawValue: defaults.string(forKey: "metric") ?? "") ?? .tokens }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .semibold)
        statusItem.button?.title = "AI …"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        appearanceObs = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateTitle() }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        timer?.tolerance = 30
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    // MARK: Refresh

    /// Providers shown in the menu bar; only these are polled by the timer.
    var barProviders: [ProviderID] {
        let bar = defaults.string(forKey: "bar") ?? "both"
        return ProviderID.allCases.filter { bar == "both" || bar == $0.rawValue }
    }

    /// Timer / wake: menu bar providers only. ⌘R (from the menu): everything.
    @objc func refresh() {
        store.scan { [weak self] in self?.updateTitle(); self?.checkCostAlerts(); self?.dumpIfDone() }
        let manual = NSApp.currentEvent?.type == .keyDown || menuOpen
        fetch(manual || CommandLine.arguments.contains("--dump") ? ProviderID.allCases : barProviders, minAge: 30)
    }

    var lastFetch: [ProviderID: Date] = [:]
    var inFlight = Set<ProviderID>()
    var menuOpen = false

    /// The usage endpoints are rate limited: a provider is never called more than once per `minAge` seconds.
    func fetch(_ ids: [ProviderID], minAge: TimeInterval) {
        let due = providers.filter { p in
            ids.contains(p.id) && !inFlight.contains(p.id) && Date().timeIntervalSince(lastFetch[p.id] ?? .distantPast) > minAge
        }
        guard !due.isEmpty else { return }
        due.forEach { inFlight.insert($0.id) }
        refreshing = true
        Task {
            let results = await withTaskGroup(of: Quota.self) { g -> [Quota] in
                for p in due { g.addTask { await p.fetch() } }
                var out: [Quota] = []
                for await q in g { out.append(q) }
                return out
            }
            for q in results { merge(q); lastFetch[q.provider] = Date(); inFlight.remove(q.provider) }
            lastUpdate = Date()
            refreshing = !inFlight.isEmpty
            updateTitle()
            checkQuotaAlerts()
            if menuOpen { build() }     // fill in the open menu as data arrives
            // Transient failure with nothing to show yet (e.g. HTTP 429 right after launch): retry sooner than the 5-min timer.
            if results.contains(where: { if case .network = $0.status { return quotas[$0.provider]?.windows.isEmpty ?? true }; return false }) {
                if quickRetries < 2 {
                    quickRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.refresh() }
                }
            } else { quickRetries = 0 }
            dumpIfDone()
        }
    }

    // Providers hidden from the menu bar are only fetched when the menu opens (and data is older than 60 s).
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        fetch(ProviderID.allCases.filter { !barProviders.contains($0) }, minAge: 60)
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    /// `VibeToken --dump`: print the menu bar text and menu contents, then exit (for testing).
    func dumpIfDone() {
        guard CommandLine.arguments.contains("--dump"), lastUpdate != nil, inFlight.isEmpty, store.lastScan != nil else { return }
        build()
        print("MENUBAR: \(statusItem.button?.title ?? "")")
        func walk(_ m: NSMenu, _ indent: String) {
            for i in m.items {
                if i.isSeparatorItem { print(indent + "────"); continue }
                if let v = i.view as? QuotaRowView { print(indent + "[\(v.title)] \(Fmt.pct(v.pct)) — \(v.detail)") }
                else if let v = i.view as? TrendView { print(indent + "[chart] " + v.bars.map { "\($0.label)=\(v.format($0.value))" }.joined(separator: " ") + " | " + v.footer) }
                else { print(indent + (i.state == .on ? "✓ " : "") + i.title.replacingOccurrences(of: "\t", with: " | ")) }
                if let sub = i.submenu { walk(sub, indent + "    ") }
            }
        }
        walk(menu, "")
        exit(0)
    }

    func merge(_ new: Quota) {
        if case .network = new.status, var old = quotas[new.provider] ?? loadSaved(new.provider), !old.windows.isEmpty {
            old.isStale = true
            quotas[new.provider] = old
        } else {
            quotas[new.provider] = new
            if new.status == .ok && !new.windows.isEmpty { save(new) }
        }
    }

    // Last good numbers survive restarts (percentages and reset times only, never tokens).
    func save(_ q: Quota) {
        let wins: [[String: Any]] = q.windows.map { w in
            var d: [String: Any] = ["noNew": w.noNewData]
            switch w.kind { case .session: d["k"] = "s"; case .weekly: d["k"] = "w"; case .scoped(let l): d["k"] = "x"; d["l"] = l; case .window(let l): d["k"] = "o"; d["l"] = l }
            if let p = w.usedPct { d["p"] = p }
            if let r = w.resetsAt { d["r"] = r.timeIntervalSince1970 }
            return d
        }
        var d: [String: Any] = ["w": wins, "e": q.extras, "t": q.fetchedAt.timeIntervalSince1970]
        if let v = q.account.email { d["email"] = v }
        if let v = q.account.name { d["name"] = v }
        if let v = q.account.org { d["org"] = v }
        if let v = q.account.plan { d["plan"] = v }
        defaults.set(d, forKey: "saved.\(q.provider.rawValue)")
    }

    func loadSaved(_ id: ProviderID) -> Quota? {
        guard let d = defaults.dictionary(forKey: "saved.\(id.rawValue)") else { return nil }
        var q = Quota(provider: id)
        q.windows = ((d["w"] as? [[String: Any]]) ?? []).map { w in
            let l = w["l"] as? String ?? ""
            let kind: WindowKind = switch w["k"] as? String { case "s": .session; case "w": .weekly; case "o": .window(l); default: .scoped(l) }
            return QuotaWindow(kind: kind, usedPct: w["p"] as? Double, resetsAt: (w["r"] as? Double).map(Date.init(timeIntervalSince1970:)), noNewData: w["noNew"] as? Bool ?? false)
        }
        q.extras = d["e"] as? [String] ?? []
        q.fetchedAt = Date(timeIntervalSince1970: d["t"] as? Double ?? 0)
        q.account = Account(email: d["email"] as? String, name: d["name"] as? String, org: d["org"] as? String, plan: d["plan"] as? String)
        return q
    }

    /// Hidden: never signed in, or signed in but no current usage (no data, or the log only has windows that already reset).
    /// An expired sign-in (401) stays visible so the "sign in again" hint shows.
    var visible: [Quota] {
        ProviderID.allCases.compactMap { quotas[$0] }.filter { q in
            if q.status == .noCredentials { return false }
            if q.status == .authExpired { return true }
            return q.windows.contains { !$0.noNewData }
        }
    }

    enum Seg { case icon(ProviderID), text(String, NSColor?) }   // nil colour = normal menu bar text

    func updateTitle() {
        var segs: [Seg] = []
        let bar = defaults.string(forKey: "bar") ?? "both"   // which providers appear in the menu bar
        for (i, q) in visible.filter({ bar == "both" || bar == $0.provider.rawValue }).enumerated() {
            if i > 0 { segs.append(.text("    ", nil)) }
            segs.append(.icon(q.provider))
            guard !q.windows.isEmpty else { segs.append(.text(" —", nil)); continue }
            // Remaining %.
            func part(_ label: String, _ w: QuotaWindow?) {
                guard let used = w?.usedPct else { segs.append(.text("\(label) –", nil)); return }
                segs.append(.text(label, nil))
                segs.append(.text("\(Int((100 - used).rounded()))%", nil))
            }
            if q.session != nil || q.weekly != nil {
                part(" 5H ", q.session)
                part(" · W ", q.weekly)
            } else if let w = q.windows.first {
                // e.g. Codex Free: a single 30-day window.
                if case .window(let s) = w.kind { part(" \(s.uppercased()) ", w) } else { part(" ", w) }
            }
        }
        if defaults.bool(forKey: "showCost") && store.lastScan != nil {
            segs.append(.text("    " + Fmt.usd(store.costSince(Calendar.current.startOfDay(for: Date()))), nil))
        }
        if segs.isEmpty { segs.append(.text(quotas.isEmpty ? "AI …" : "AI —", nil)) }

        let font = statusItem.button?.font ?? NSFont.menuBarFont(ofSize: 0)
        let side = font.capHeight + 5
        let icons = Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { id in
            Bundle.main.url(forResource: id.rawValue, withExtension: "svg").flatMap(NSImage.init(contentsOf:)).map { (id, $0) } })
        func width(_ s: Seg) -> CGFloat {
            switch s {
            case .icon(let id): return icons[id] != nil ? side : ("C" as NSString).size(withAttributes: [.font: font]).width
            case .text(let t, _): return (t as NSString).size(withAttributes: [.font: font]).width
            }
        }
        let total = ceil(segs.reduce(0) { $0 + width($1) })
        let button = statusItem.button
        // Drawn at display time with the menu bar's appearance, so labelColor is white/black as appropriate.
        let img = NSImage(size: NSSize(width: total, height: 18), flipped: false) { r in
            let draw = {
                var x: CGFloat = 0
                let textH = ("5" as NSString).size(withAttributes: [.font: font]).height
                for s in segs {
                    switch s {
                    case .icon(let id):
                        let rect = NSRect(x: x, y: (r.height - side) / 2, width: side, height: side)
                        if let img = icons[id], let ctx = NSGraphicsContext.current?.cgContext {
                            ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
                            img.draw(in: rect)
                            NSColor.labelColor.set()
                            rect.fill(using: .sourceAtop)
                            ctx.endTransparencyLayer()
                        } else {
                            ("C" as NSString).draw(at: NSPoint(x: x, y: (r.height - textH) / 2), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
                        }
                    case .text(let t, let c):
                        (t as NSString).draw(at: NSPoint(x: x, y: (r.height - textH) / 2), withAttributes: [.font: font, .foregroundColor: c ?? NSColor.labelColor])
                    }
                    x += width(s)
                }
            }
            if let ap = button?.effectiveAppearance { ap.performAsCurrentDrawingAppearance(draw) } else { draw() }
            return true
        }
        button?.title = ""
        button?.image = img
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) { build() }

    func build() {
        menu.removeAllItems()
        for q in visible { addProvider(q); menu.addItem(.separator()) }
        if visible.isEmpty {
            menu.addItem(info(tr("Không tìm thấy Claude Code hay Codex trên máy", "No Claude Code or Codex sign-in found"), secondary: true))
            menu.addItem(.separator())
        }
        addUsage()
        menu.addItem(.separator())
        let upd = lastUpdate.map { tr("Cập nhật lần cuối: ", "Last updated: ") + Fmt.time($0) } ?? tr("Đang tải…", "Loading…")
        menu.addItem(info(upd + (refreshing ? tr(" (đang làm mới…)", " (refreshing…)") : ""), secondary: true))
        menu.addItem(action(tr("Làm mới", "Refresh"), #selector(refresh), key: "r"))
        menu.addItem(optionsItem())
        let login = action(tr("Mở lúc đăng nhập", "Open at Login"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action(tr("Thoát", "Quit"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    func addProvider(_ q: Quota) {
        let name = q.provider == .claude ? "Claude Code" : "Codex"
        let head = NSMutableAttributedString(string: name, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        if let plan = q.account.plan { head.append(NSAttributedString(string: "  \(plan)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])) }
        if q.isStale { head.append(NSAttributedString(string: tr("  (dữ liệu cũ, lúc ", "  (stale, from ") + Fmt.df("HH:mm dd/MM").string(from: q.fetchedAt) + ")", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange])) }
        menu.addItem(info(head))

        if q.windows.isEmpty {
            menu.addItem(info("—"))
            switch q.status {
            case .authExpired: menu.addItem(info(tr("Mở \(name) để đăng nhập lại", "Open \(name) to sign in again"), secondary: true))
            case .network(let e) where e.contains("429"):
                menu.addItem(info(tr("API đang giới hạn tần suất (HTTP 429), sẽ thử lại sau", "API rate limited (HTTP 429), will retry later"), secondary: true))
            case .failed(let e), .network(let e): menu.addItem(info(tr("Lỗi: ", "Error: ") + e, secondary: true))
            default: break
            }
        }
        for w in q.windows {
            let title: String
            switch w.kind {
            case .session: title = tr("Phiên 5h", "5h session")
            case .weekly: title = tr("Tuần", "Weekly")
            case .scoped(let s): title = tr("Tuần · ", "Weekly · ") + s
            case .window(let s): title = tr("Giới hạn \(s)", "\(s) limit")
            }
            var detail = w.usedPct.map { tr("còn \(Fmt.pct(100 - $0)) (đã dùng \(Fmt.pct($0)))", "\(Fmt.pct(100 - $0)) left (\(Fmt.pct($0)) used)") } ?? ""
            if let r = w.resetsAt { detail += (detail.isEmpty ? "" : ", ") + Fmt.reset(r) }
            if w.noNewData { detail += tr(" (chưa có dữ liệu mới)", " (no new data yet)") }
            let item = NSMenuItem()
            item.view = QuotaRowView(title: title, pct: w.usedPct, detail: detail)
            menu.addItem(item)
        }
        for e in q.extras { menu.addItem(info(e, secondary: true)) }
        if q.provider == .codex, let d = q.dataAsOf, q.sourceNote != "chatgpt.com" {
            menu.addItem(info(tr("Nguồn: log phiên lúc ", "Source: session log at ") + Fmt.df("HH:mm dd/MM").string(from: d), secondary: true))
        }
        if let c = store.latestContext(q.provider == .claude ? .claude : .codex) {
            let p = Double(c.used) / Double(max(c.window, 1)) * 100
            var s = "Context: \(Fmt.pct(p)) · \(Fmt.tokens(c.used)) / \(Fmt.tokens(c.window))"
            if !c.project.isEmpty { s += " · \(c.project)" }
            s += " · \(Fmt.ago(c.last))"
            menu.addItem(info(s, secondary: true))
        }
        if let e = q.account.email { menu.addItem(info(tr("Tài khoản: ", "Account: ") + e + (q.account.name.map { " (\($0))" } ?? ""), secondary: true)) }
        if let o = q.account.org { menu.addItem(info(tr("Tổ chức: ", "Organization: ") + o, secondary: true)) }
        if let p = q.account.plan { menu.addItem(info(tr("Gói: ", "Plan: ") + p, secondary: true)) }
    }

    // MARK: TokenWatch-style usage section

    func periodName(_ p: Period) -> String {
        switch p {
        case .today: return tr("Hôm nay", "Today")
        case .day: return tr("7 ngày", "Day (7 days)")
        case .week: return tr("7 tuần", "Week (7 weeks)")
        case .month: return tr("6 tháng", "Month (6 months)")
        case .year: return tr("2 năm", "Year (2 years)")
        }
    }
    func filterName(_ f: Filter) -> String {
        switch f { case .all: return tr("Tất cả", "All"); case .codex: return "Codex"; case .claude: return "Claude" }
    }
    func metricName(_ m: TrendMetric) -> String {
        switch m { case .tokens: return "Tokens"; case .cost: return tr("Chi phí", "Cost"); case .turns: return tr("Lượt", "Turns") }
    }

    func addUsage() {
        let head = NSMutableAttributedString(string: tr("Thống kê sử dụng", "Usage"), attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        head.append(NSAttributedString(string: "  \(periodName(period)) · \(filterName(filter))",
                                       attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        menu.addItem(info(head))
        let sources = Set(store.snapshot.values.filter { !$0.buckets.isEmpty }.map(\.source))
        if sources.count > 1 {
            menu.addItem(radioSubmenu(tr("Nguồn", "Source") + ": " + filterName(filter), Filter.allCases.map { ($0.rawValue, filterName($0)) }, key: "filter", current: filter.rawValue))
        }
        menu.addItem(radioSubmenu(tr("Khoảng", "Period") + ": " + periodName(period), Period.allCases.map { ($0.rawValue, periodName($0)) }, key: "period", current: period.rawValue))

        guard store.lastScan != nil else { menu.addItem(info(tr("Đang đọc log…", "Reading logs…"), secondary: true)); return }
        let s = store.summary(period, filter)
        let t = s.t
        let prevName = period == .today ? tr("hôm qua", "yesterday") : tr("kỳ trước", "previous period")

        // Cost + comparison
        let cost = NSMutableAttributedString(string: tr("Chi phí  ", "Cost  "), attributes: [.font: NSFont.systemFont(ofSize: 13)])
        cost.append(NSAttributedString(string: Fmt.usd(t.cost), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)]))
        if s.prev.cost > 0 {
            let d = (t.cost - s.prev.cost) / s.prev.cost * 100
            cost.append(NSAttributedString(string: "   \(d >= 0 ? "↑" : "↓") \(Fmt.pct(abs(d))) " + tr("so với ", "vs ") + "\(Fmt.usd(s.prev.cost)) \(prevName)",
                                           attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: d >= 0 ? NSColor.systemRed : NSColor.systemGreen]))
        }
        menu.addItem(info(cost))

        let cacheBase = Double(t.cacheRead + t.input + t.cacheWrite)
        let cachePct = cacheBase > 0 ? Double(t.cacheRead) / cacheBase * 100 : 0
        menu.addItem(info("Token: \(Fmt.tokens(t.total)) " + tr("tổng", "total") + " · cache \(Fmt.pct(cachePct))"))
        menu.addItem(info("Input \(Fmt.tokens(t.input)) · Output \(Fmt.tokens(t.output)) · " + tr("Cache đọc", "Cache read") + " \(Fmt.tokens(t.cacheRead)) · " + tr("Cache ghi", "Cache write") + " \(Fmt.tokens(t.cacheWrite)) · Reasoning \(Fmt.tokens(t.reasoning))", secondary: true))
        let perTurn = t.turns > 0 ? t.cost / Double(t.turns) : 0
        menu.addItem(info(tr("Lượt", "Turns") + " \(t.turns) · Tool \(s.toolCount) · Model \(s.models.count) · " + tr("$/lượt", "$/turn") + String(format: " %.3f", perTurn), secondary: true))

        // Trend
        let values: [(String, Double)] = s.trend.map { b in
            switch metric { case .tokens: return (b.label, Double(b.t.total)); case .cost: return (b.label, b.t.cost); case .turns: return (b.label, Double(b.t.turns)) }
        }
        let fmt: (Double) -> String = metric == .cost ? { Fmt.usd($0) } : { Fmt.tokens(Int64($0)) }
        let peak = values.max { $0.1 < $1.1 }
        var footer = tr("Tổng ", "Total ") + (metric == .cost ? Fmt.usd(values.reduce(0) { $0 + $1.1 }) : Fmt.tokens(Int64(values.reduce(0) { $0 + $1.1 })))
        if let peak, peak.1 > 0 { footer += tr(" · đỉnh ", " · peak ") + peak.0 + (period == .today ? ":00" : "") }
        let unit = period == .today ? tr("giờ", "hours") : tr("kỳ", "buckets")
        footer += " · \(s.activeBuckets) " + unit + tr(" hoạt động", " active")
        let chart = NSMenuItem()
        chart.view = TrendView(bars: values, format: fmt, footer: footer)
        menu.addItem(chart)
        menu.addItem(radioSubmenu(tr("Biểu đồ", "Chart") + ": " + metricName(metric), TrendMetric.allCases.map { ($0.rawValue, metricName($0)) }, key: "metric", current: metric.rawValue))

        // Top models
        let models = NSMenu()
        let tabs = tabStyle([250, 310, 370, 430])
        models.addItem(info(attr(tr("Model\tTokens\tLượt\tChi phí\tTỉ lệ", "Model\tTokens\tTurns\tCost\tShare"), tabs, secondary: true)))
        for m in s.models.prefix(20) {
            let share = t.total > 0 ? Double(m.t.total) / Double(t.total) * 100 : 0
            var name = m.model + (m.effort.isEmpty ? "" : " · \(m.effort.capitalizedFirst)")
            if !Pricing.isKnown(m.model) { name += tr(" (giá ước tính)", " (fallback price)") }
            models.addItem(info(attr("\(name)\t\(Fmt.tokens(m.t.total))\t\(m.t.turns)\t\(Fmt.usd(m.t.cost))\t\(Fmt.pct(share))", tabs)))
        }
        menu.addItem(submenu("Top model (\(s.models.count))", models))

        // Tool calls
        let tools = NSMenu()
        let toolTabs = tabStyle([260])
        for src in [Source.claude, .codex] {
            guard let byName = s.tools[src], !byName.isEmpty else { continue }
            tools.addItem(info(attr("\(src == .claude ? "Claude Code" : "Codex")\t\(byName.values.reduce(0, +))", toolTabs, bold: true)))
            for (n, c) in byName.sorted(by: { $0.value > $1.value }).prefix(25) { tools.addItem(info(attr("  \(n)\t\(c)", toolTabs))) }
        }
        if tools.items.isEmpty { tools.addItem(info("—", secondary: true)) }
        menu.addItem(submenu("Tool calls (\(s.toolCount))", tools))

        // Sessions
        let sessions = NSMenu()
        let sTabs = tabStyle([280, 340, 400])
        sessions.addItem(info(attr(tr("Dự án · model\tTokens\tChi phí\tGần nhất", "Project · model\tTokens\tCost\tLast"), sTabs, secondary: true)))
        for r in s.sessions.prefix(20) {
            let proj = r.project.isEmpty ? String(r.id.prefix(8)) : r.project
            let icon = r.source == .claude ? "C" : "X"
            sessions.addItem(info(attr("\(icon) \(proj) · \(r.models.sorted().joined(separator: ", "))\t\(Fmt.tokens(r.t.total))\t\(Fmt.usd(r.t.cost))\t\(Fmt.df("dd/MM HH:mm").string(from: Date(timeIntervalSince1970: r.last)))", sTabs)))
        }
        menu.addItem(submenu(tr("Phiên", "Sessions") + " (\(s.sessions.count))", sessions))

        // Insights
        let ins = NSMenu()
        if s.prev.cost > 0 {
            let d = (t.cost - s.prev.cost) / s.prev.cost * 100
            ins.addItem(info(tr("So với \(prevName): ", "Vs \(prevName): ") + "\(d >= 0 ? "↑" : "↓") \(Fmt.pct(abs(d))) (\(Fmt.usd(t.cost)) / \(Fmt.usd(s.prev.cost)))"))
        }
        ins.addItem(info(tr("Đòn bẩy cache: ", "Cache leverage: ") + Fmt.pct(cachePct) + " (\(Fmt.tokens(t.cacheRead)) " + tr("cache / ", "cached vs ") + "\(Fmt.tokens(t.input)) " + tr("input mới)", "fresh input)")))
        if t.turns > 0 {
            ins.addItem(info(tr("Độ nặng mỗi lượt: ", "Turn weight: ") + Fmt.tokens(t.total / Int64(t.turns)) + " · " + Fmt.usd(perTurn) + tr("/lượt", "/turn")))
        }
        if let top = s.models.first, t.total > 0 {
            ins.addItem(info(tr("Model chính: ", "Main model: ") + "\(top.model) · \(Fmt.pct(Double(top.t.total) / Double(t.total) * 100)) tokens · \(top.t.turns) " + tr("lượt", "turns")))
        }
        let outAll = t.output + t.reasoning
        ins.addItem(info(tr("Tỉ lệ reasoning: ", "Reasoning mix: ") + Fmt.pct(outAll > 0 ? Double(t.reasoning) / Double(outAll) * 100 : 0) + " (\(Fmt.tokens(t.reasoning)))"))
        if t.input > 0 {
            ins.addItem(info(tr("Hình dạng output: ", "Output shape: ") + Fmt.pct(Double(outAll) / Double(t.input) * 100) + " (\(Fmt.tokens(outAll)) output / \(Fmt.tokens(t.input)) input)"))
        }
        menu.addItem(submenu("Insights", ins))
    }

    // MARK: Options submenu

    func optionsItem() -> NSMenuItem {
        let m = NSMenu()
        m.addItem(radioSubmenu(tr("Ngôn ngữ", "Language"), [("vi", "Tiếng Việt"), ("en", "English")], key: "lang", current: lang))
        m.addItem(radioSubmenu(tr("Hiện trên menubar", "Show in menu bar"), [("both", tr("Cả hai", "Both")), ("claude", "Claude"), ("codex", "Codex")],
                               key: "bar", current: defaults.string(forKey: "bar") ?? "both"))
        let cost = action(tr("Hiện chi phí hôm nay trên menubar", "Show today's cost in menu bar"), #selector(toggleDefault(_:)))
        cost.representedObject = "showCost"; cost.state = defaults.bool(forKey: "showCost") ? .on : .off
        m.addItem(cost)
        let qa = action(tr("Thông báo khi quota ≥ 80% / 95%", "Notify when quota ≥ 80% / 95%"), #selector(toggleDefault(_:)))
        qa.representedObject = "quotaAlerts"; qa.state = defaults.bool(forKey: "quotaAlerts") ? .on : .off
        m.addItem(qa)
        m.addItem(.separator())
        m.addItem(info(tr("Cảnh báo chi phí (80/95/100%)", "Cost alerts (80/95/100%)"), secondary: true))
        let amounts: [Double] = [0, 1, 5, 10, 20, 50, 100, 200, 500]
        for (key, name) in [("budget.daily", tr("Ngày", "Daily")), ("budget.weekly", tr("Tuần", "Weekly")), ("budget.monthly", tr("Tháng", "Monthly"))] {
            let cur = defaults.double(forKey: key)
            let opts = amounts.map { ($0 == 0 ? "0" : String(Int($0)), $0 == 0 ? tr("Tắt", "Off") : Fmt.usd($0)) }
            m.addItem(radioSubmenu("\(name): " + (cur > 0 ? Fmt.usd(cur) : tr("Tắt", "Off")), opts, key: key, current: cur > 0 ? String(Int(cur)) : "0"))
        }
        m.addItem(.separator())
        m.addItem(action(tr("Giá model tuỳ chỉnh…", "Custom model pricing…"), #selector(openPricing)))
        m.addItem(action(tr("Quét lại toàn bộ log", "Rescan all logs"), #selector(rescan)))
        return submenu(tr("Tuỳ chọn", "Options"), m)
    }

    @objc func pickRadio(_ sender: NSMenuItem) {
        guard let (key, value) = sender.representedObject as? (String, String) else { return }
        if key.hasPrefix("budget.") { defaults.set(Double(value) ?? 0, forKey: key); requestNotifications() }
        else { defaults.set(value, forKey: key) }
        if key == "lang" { refresh() }
        if key == "bar" { fetch(barProviders, minAge: 30) }
        updateTitle()
    }

    @objc func toggleDefault(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        if key == "quotaAlerts" && defaults.bool(forKey: key) { requestNotifications() }
        updateTitle()
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            SMAppService.openSystemSettingsLoginItems()
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc func openPricing() {
        let path = Pricing.overridesPath
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let sample = """
            {
              "$comment": "USD per 1M tokens. Keys starting with $ are ignored. Restart VibeToken after editing.",
              "$example-model": { "input": 1.25, "cached": 0.125, "cacheWrite": 0, "output": 10 }
            }
            """
            try? sample.write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func rescan() { store.scan(reset: true) { [weak self] in self?.updateTitle() } }

    // MARK: Notifications

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Fires once per level per window (keyed by the window's reset time).
    func checkQuotaAlerts() {
        guard defaults.bool(forKey: "quotaAlerts") else { return }
        for q in visible where !q.isStale {
            for w in q.windows where w.kind == .session || w.kind == .weekly {
                guard let p = w.usedPct, !w.noNewData, let level = [95.0, 80.0].first(where: { p >= $0 }) else { continue }
                let key = "fired.q.\(q.provider.rawValue).\(w.kind == .session ? "s" : "w").\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
                guard defaults.double(forKey: key) < level else { continue }
                defaults.set(level, forKey: key)
                let name = q.provider == .claude ? "Claude Code" : "Codex"
                let win = w.kind == .session ? tr("phiên 5h", "5h session") : tr("tuần", "weekly")
                notify("\(name): \(Fmt.pct(p))", tr("Quota \(win) đã dùng \(Fmt.pct(p))", "\(win.capitalizedFirst) quota at \(Fmt.pct(p))") + (w.resetsAt.map { ", " + Fmt.reset($0) } ?? ""))
            }
        }
    }

    func checkCostAlerts() {
        let cal = Calendar.current
        let now = Date()
        var mondayCal = cal; mondayCal.firstWeekday = 2
        let starts: [(String, Date, String)] = [
            ("budget.daily", cal.startOfDay(for: now), tr("hôm nay", "today")),
            ("budget.weekly", mondayCal.dateInterval(of: .weekOfYear, for: now)!.start, tr("tuần này", "this week")),
            ("budget.monthly", cal.dateInterval(of: .month, for: now)!.start, tr("tháng này", "this month")),
        ]
        for (key, start, name) in starts {
            let budget = defaults.double(forKey: key)
            guard budget > 0 else { continue }
            let spent = store.costSince(start)
            guard let level = [100.0, 95.0, 80.0].first(where: { spent >= budget * $0 / 100 }) else { continue }
            let fk = "fired.\(key).\(Int(start.timeIntervalSince1970)).\(Int(budget))"
            guard defaults.double(forKey: fk) < level else { continue }
            defaults.set(level, forKey: fk)
            notify(tr("Cảnh báo chi phí", "Cost alert"), tr("Chi phí \(name): \(Fmt.usd(spent)) / \(Fmt.usd(budget)) (\(Int(level))%)",
                                                            "Spend \(name): \(Fmt.usd(spent)) / \(Fmt.usd(budget)) (\(Int(level))%)"))
        }
    }

    // MARK: Item helpers

    func info(_ s: String, secondary: Bool = false) -> NSMenuItem {
        info(NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: secondary ? 12 : 13),
                                                         .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor]))
    }
    func info(_ a: NSAttributedString) -> NSMenuItem {
        let i = NSMenuItem(title: a.string, action: nil, keyEquivalent: "")
        i.attributedTitle = a
        i.isEnabled = true
        return i
    }
    func action(_ title: String, _ sel: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = target ?? self
        return i
    }
    func submenu(_ title: String, _ m: NSMenu) -> NSMenuItem {
        m.autoenablesItems = false
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = m
        return i
    }
    func radioSubmenu(_ title: String, _ options: [(String, String)], key: String, current: String) -> NSMenuItem {
        let m = NSMenu()
        for (value, label) in options {
            let i = action(label, #selector(pickRadio(_:)))
            i.representedObject = (key, value)
            i.state = value == current ? .on : .off
            m.addItem(i)
        }
        return submenu(title, m)
    }
    func tabStyle(_ stops: [CGFloat]) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.tabStops = stops.map { NSTextTab(textAlignment: .right, location: $0) }
        return p
    }
    func attr(_ s: String, _ p: NSParagraphStyle, secondary: Bool = false, bold: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.paragraphStyle: p,
                                                   .font: bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                                   .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor])
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
