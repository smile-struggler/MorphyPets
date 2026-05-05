import Foundation
import SwiftUI
import PetEngine
import PersonaLLM
import CalendarBridge
import FocusMonitor
import InterventionKit
import SessionStore
#if canImport(EventKit)
import EventKit
#endif

@MainActor
final class AppState: ObservableObject {
    @Published var persona: Persona = .gentle {
        didSet { savePreferences() }
    }
    @Published var activePet: PetManifest?
    @Published var renderer: PetRenderer?
    @Published var llmConfig = LLMConfig.default {
        didSet { savePreferences() }
    }
    @Published var interventionMode: InterventionMode = .full {
        didSet { savePreferences() }
    }
    @Published var testMode: Bool = false {
        didSet { applyThresholds(); savePreferences() }
    }
    static let normalThresholds: [TimeInterval] = [30, 90, 180, 300]
    static let testThresholds:   [TimeInterval] = [3, 6, 9, 12]
    /// Bundle IDs the classifier always treats as focus by default. Surfaced in the
    /// settings UI so users see what's preset.
    static let seedFocusApps: [String] = [
        // Editors / IDEs
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",     // Cursor
        "com.exafunction.windsurf",          // Windsurf
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.jetbrains.AppCode",
        "com.sublimetext.4",
        "io.neovide.neovide",
        // Terminal
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        // Notes / Docs
        "com.apple.TextEdit",
        "md.obsidian",
        "notion.id",
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.literatureandlatte.scrivener3",
        // Design / Diagram
        "com.figma.Desktop",
        "com.electron.lark",                 // 飞书 Lark
        // Reading / Reference
        "com.apple.Preview",                 // PDF reader
        "com.readdle.PDFExpert-Mac",
    ]
    @Published var calendarAuthorized = false
    @Published var todaysEvents: [EKEvent] = []
    /// When true, unknown websites trigger an LLM classification (cached afterward).
    /// Default OFF — token spend can balloon if the user browses widely.
    @Published var siteAutoClassify: Bool = false {
        didSet { wireSiteCatalogLLM(); savePreferences() }
    }
    /// When the daily summary auto-fires. Default 23:00.
    @Published var dailyReportHour: Int = 23 {
        didSet { scheduleNextDailyReport(); savePreferences() }
    }
    @Published var dailyReportMinute: Int = 0 {
        didSet { scheduleNextDailyReport(); savePreferences() }
    }
    /// User-configured intervention thresholds (4 entries) for normal mode. nil → use defaults.
    @Published var customThresholds: [TimeInterval]? = nil {
        didSet { applyThresholds(); savePreferences() }
    }
    /// User-supplied lists of explicit classifications.
    @Published var userDistractApps: [String] = [] {
        didSet { applyUserLists(); savePreferences() }
    }
    @Published var userFocusApps: [String] = [] {
        didSet { applyUserLists(); savePreferences() }
    }
    @Published var userDistractHosts: [String] = [] {
        didSet { applyUserLists(); savePreferences() }
    }
    @Published var userFocusHosts: [String] = [] {
        didSet { applyUserLists(); savePreferences() }
    }
    /// Seed (built-in) hosts the user explicitly removed. Their classification is
    /// overridden to .neutral so they no longer count as focus/distract.
    @Published var userRemovedSeedHosts: [String] = [] {
        didSet { applyUserLists(); savePreferences() }
    }
    /// Seed (built-in) bundle IDs the user explicitly removed from the focus apps list.
    @Published var userRemovedSeedApps: [String] = [] {
        didSet { applyUserLists(); savePreferences() }
    }
    /// Editable system prompt used when persona == .custom.
    @Published var customPersonaPrompt: String = "你是一个友好的赛博宠物，会提醒用户回到任务。中文，最多两句，不超过 40 字。" {
        didSet { rebuildLLM(); savePreferences() }
    }

    /// Single subscriber for "show this line in the pet's bubble".
    var onSpeak: ((String) -> Void)?

    let petLibrary = PetLibrary()
    let store = SessionStore()
    let calendar = CalendarService()
    /// Shared site classification catalog (bundled JSON + learned LLM overrides).
    let siteCatalog = SiteCatalog()
    lazy var focus: FocusController = FocusController(state: self)
    lazy var reminder: CalendarReminder = {
        let r = CalendarReminder(service: calendar)
        r.onFire = { [weak self] hit in
            Task { @MainActor in self?.handleReminder(hit) }
        }
        return r
    }()

    var llmClient: LLMClient?
    private(set) var responder: PersonaResponder
    private(set) var engine: InterventionEngine

    /// 24h domain whitelist (key = host substring, value = expiry).
    @Published var whitelist: [String: Date] = [:]

    /// Suppresses savePreferences() during init load so we don't write the same data
    /// we just read.
    private var isLoadingPreferences = false

    init() {
        // Always start with a fallback responder; rebuildLLM() upgrades it once a key is set.
        let r = PersonaResponder(client: nil, persona: .gentle)
        self.responder = r
        self.engine = InterventionEngine(mode: .full)
        loadPreferences()
        bootstrap()
    }

    // MARK: - Preferences persistence

    private static let prefsKey = "CyberPet.preferences.v1"

    private struct Preferences: Codable {
        var personaRaw: String?
        var llmConfig: LLMConfig?
        var interventionModeKey: String?     // "full" / "lite" / "silent"
        var testMode: Bool?
        var siteAutoClassify: Bool?
        var dailyReportHour: Int?
        var dailyReportMinute: Int?
        var customThresholds: [TimeInterval]?
        var userDistractApps: [String]?
        var userFocusApps: [String]?
        var userDistractHosts: [String]?
        var userFocusHosts: [String]?
        var userRemovedSeedHosts: [String]?
        var userRemovedSeedApps: [String]?
        var customPersonaPrompt: String?
    }

    private func savePreferences() {
        guard !isLoadingPreferences else { return }
        let p = Preferences(
            personaRaw: persona.rawValue,
            llmConfig: llmConfig,
            interventionModeKey: interventionModeKey(),
            testMode: testMode,
            siteAutoClassify: siteAutoClassify,
            dailyReportHour: dailyReportHour,
            dailyReportMinute: dailyReportMinute,
            customThresholds: customThresholds,
            userDistractApps: userDistractApps,
            userFocusApps: userFocusApps,
            userDistractHosts: userDistractHosts,
            userFocusHosts: userFocusHosts,
            userRemovedSeedHosts: userRemovedSeedHosts,
            userRemovedSeedApps: userRemovedSeedApps,
            customPersonaPrompt: customPersonaPrompt
        )
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.prefsKey)
        }
    }

    private func loadPreferences() {
        guard let data = UserDefaults.standard.data(forKey: Self.prefsKey),
              let p = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return }
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }
        if let raw = p.personaRaw, let parsed = Persona(rawValue: raw) { persona = parsed }
        if let cfg = p.llmConfig { llmConfig = cfg }
        if let key = p.interventionModeKey { interventionMode = mode(forKey: key) }
        if let v = p.testMode { testMode = v }
        if let v = p.siteAutoClassify { siteAutoClassify = v }
        if let v = p.dailyReportHour { dailyReportHour = v }
        if let v = p.dailyReportMinute { dailyReportMinute = v }
        if let v = p.customThresholds { customThresholds = v }
        if let v = p.userDistractApps { userDistractApps = v }
        if let v = p.userFocusApps { userFocusApps = v }
        if let v = p.userDistractHosts { userDistractHosts = v }
        if let v = p.userFocusHosts { userFocusHosts = v }
        if let v = p.userRemovedSeedHosts { userRemovedSeedHosts = v }
        if let v = p.userRemovedSeedApps { userRemovedSeedApps = v }
        if let v = p.customPersonaPrompt { customPersonaPrompt = v }
    }

    private func interventionModeKey() -> String {
        switch interventionMode.maxLevel {
        case .l4: return "full"
        case .l2: return "lite"
        default:  return "silent"
        }
    }
    private func mode(forKey key: String) -> InterventionMode {
        switch key {
        case "full": return .full
        case "lite": return .lite
        default:     return .silent
        }
    }

    func isWhitelisted(domain: String?) -> Bool {
        guard let domain else { return false }
        let now = Date()
        for (key, expiry) in whitelist where expiry > now {
            if domain.contains(key) { return true }
        }
        return false
    }

    func whitelist(domain: String, hours: Double = 24) {
        whitelist[domain] = Date().addingTimeInterval(hours * 3600)
    }

    private func bootstrap() {
        // 1. Built-in ikun.
        let bundled = Bundle.module.url(forResource: "Pets/ikun", withExtension: nil)
            ?? Bundle.module.url(forResource: "ikun", withExtension: nil, subdirectory: "Pets")
        if let bundled {
            _ = try? petLibrary.ensureBuiltinIkun(bundledAt: bundled)
        }
        if let pet = petLibrary.installedPets().first {
            activate(pet: pet)
        }

        // 2. LLM.
        rebuildLLM()
        wireSiteCatalogLLM()

        // 3. Calendar — request access async; start reminders if granted.
        Task { @MainActor in
            await self.requestCalendarAccess()
        }

        // 4. Schedule the 23:00 daily report.
        scheduleNextDailyReport()
    }

    private var dailyReportTimer: Timer?
    /// Hook called by the 23:00 trigger so AppDelegate can open the panel.
    var onDailyReportFired: ((PersonaResponder.DailyStats) -> Void)?

    private func scheduleNextDailyReport() {
        dailyReportTimer?.invalidate()
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = dailyReportHour; comps.minute = dailyReportMinute
        var fire = cal.date(from: comps) ?? now
        if fire <= now { fire = cal.date(byAdding: .day, value: 1, to: fire) ?? fire }
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let stats = self.summarizeToday()
                self.onDailyReportFired?(stats)
                self.scheduleNextDailyReport()
            }
        }
        dailyReportTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func activate(pet: PetManifest) {
        let dir = petLibrary.directory(for: pet)
        let sheetURL = pet.resolvedSpritesheetURL(in: dir)
        guard let sheet = try? SpriteSheet.load(from: sheetURL) else { return }
        activePet = pet
        renderer = PetRenderer(sheet: sheet)
    }

    func rebuildLLM() {
        if !llmConfig.apiKey.isEmpty, let url = URL(string: llmConfig.baseURL) {
            llmClient = LLMClient(config: .init(baseURL: url, apiKey: llmConfig.apiKey, model: llmConfig.model))
        } else {
            llmClient = nil
        }
        responder = PersonaResponder(client: llmClient, persona: persona, customSystemPrompt: customPersonaPrompt)
        engine = InterventionEngine(mode: interventionMode)
        applyThresholds()
        applyUserLists()
        wireSiteCatalogLLM()
    }

    private func applyThresholds() {
        let t: [TimeInterval]
        if testMode {
            t = AppState.testThresholds
        } else if let c = customThresholds, c.count == 4 {
            t = c
        } else {
            t = AppState.normalThresholds
        }
        let e = engine
        Task { await e.setThresholds(t) }
    }

    /// Push user-edited distract/focus lists into the live monitor classifier and site catalog.
    func applyUserLists() {
        var c = focus.monitorClassifier
        c.distractBundleIDs = Set(userDistractApps)
        let removedApps = Set(userRemovedSeedApps)
        c.focusBundleIDs = Set(userFocusApps).union(Set(AppState.seedFocusApps).subtracting(removedApps))
        focus.monitorClassifier = c
        for h in userDistractHosts { siteCatalog.record(host: h, label: .distract) }
        for h in userFocusHosts    { siteCatalog.record(host: h, label: .focus) }
        // Removed seeds → record as neutral so they no longer trigger distract/focus.
        for h in userRemovedSeedHosts { siteCatalog.record(host: h, label: .neutral) }
    }

    /// Connects the SiteCatalog's LLM-based unknown-host classifier to the current
    /// `llmClient`. Called whenever the client is rebuilt. Closure sends ONLY (host, title)
    /// — no history — to keep the request cheap.
    private func wireSiteCatalogLLM() {
        guard siteAutoClassify, let client = llmClient else {
            siteCatalog.llm = nil
            return
        }
        siteCatalog.llm = { host, title in
            let user = """
            判断这个网页对"工作/学习专注"是属于：focus（有助于专注，比如开发/文档/论文/课程平台）/ distract（典型摸鱼，比如短视频/娱乐论坛）/ neutral（无法判断）。
            host: \(host)
            title: \(title ?? "(无)")
            仅输出 JSON：{"label":"focus|distract|neutral"}
            """
            do {
                let raw = try await client.chat(messages: [
                    .init(role: "system", content: "你是网页内容分类器，只输出 JSON。"),
                    .init(role: "user", content: user),
                ], jsonMode: true)
                struct R: Decodable { let label: String }
                guard let data = raw.data(using: .utf8),
                      let r = try? JSONDecoder().decode(R.self, from: data)
                else { return nil }
                return ActivityLabel(rawValue: r.label)
            } catch {
                return nil
            }
        }
    }

    private func applyThresholds_old_DELETED() {
        let t = testMode ? AppState.testThresholds : AppState.normalThresholds
        let e = engine
        Task { await e.setThresholds(t) }
    }

    // MARK: - Calendar

    func requestCalendarAccess() async {
        do {
            let granted = try await calendar.requestAccess()
            calendarAuthorized = granted
            if granted {
                refreshTodaysEvents()
                reminder.start()
                startCalendarAutoSync()
            }
        } catch {
            calendarAuthorized = false
        }
    }

    private var calendarSyncTimer: Timer?
    private var calendarChangeObserver: NSObjectProtocol?

    /// Subscribe to EKEventStore change notifications and run a 5-min fallback poll, so
    /// edits made in the system Calendar app reflect here without manual "刷新".
    private func startCalendarAutoSync() {
        if calendarChangeObserver == nil {
            calendarChangeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: calendar.store,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshTodaysEvents() }
            }
        }
        calendarSyncTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTodaysEvents() }
        }
        calendarSyncTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func refreshTodaysEvents() {
        todaysEvents = calendar.eventsToday()
    }

    private func handleReminder(_ hit: ReminderHit) {
        let minutes: Int = {
            switch hit.kind {
            case .t10: return 10
            case .t2:  return 2
            case .t0:  return 0
            }
        }()
        let r = responder
        Task { @MainActor in
            let stream = await r.reminderStream(title: hit.title, notes: hit.notes, location: hit.location, minutesUntil: minutes)
            await self.speakStream(stream, autoDismissAfter: 8)
        }
        refreshTodaysEvents()
    }

    /// Drive the bubble (via onSpeak) from an AsyncStream of incremental chunks.
    /// onSpeak is called with the cumulative text after each chunk arrives.
    func speakStream(_ stream: AsyncStream<String>, autoDismissAfter seconds: Double = 6) async {
        var acc = ""
        for await chunk in stream {
            acc += chunk
            onSpeak?(acc)
        }
        if acc.isEmpty { return }
        _ = seconds
    }

    /// Right-click "鼓励一下" → LLM-powered encouragement based on today's calendar
    /// (and current focus task if any). Each call sends ONLY today's snapshot, no history.
    func encourageMe() {
        let task = focus.taskTitle.isEmpty ? nil : focus.taskTitle
        let now = Date()
        let upcoming: [PersonaResponder.UpcomingEvent] = todaysEvents
            .filter { $0.endDate >= now }
            .prefix(5)
            .map { ev in
                let mins = Int(ev.startDate.timeIntervalSince(now) / 60)
                return .init(title: ev.title ?? "(无标题)", startsInMinutes: mins)
            }
        let r = responder
        Task { @MainActor in
            let stream = await r.encourageStream(currentTask: task, upcoming: upcoming)
            await self.speakStream(stream, autoDismissAfter: 10)
        }
    }

    enum NLParseSource {
        case llm
        case fallback(reason: String)
    }
    struct NLParseOutcome {
        let events: [EKEvent]
        let source: NLParseSource
    }

    /// LLM-first natural-language scheduling. The model can split one utterance into
    /// multiple events ("十秒后刷牙，下午三点开会" → 2 events). Falls back to local regex
    /// only when LLM is unavailable or fails. Returns ALL added events plus which path
    /// produced them.
    func scheduleFromNaturalLanguageDetailed(_ input: String) async throws -> NLParseOutcome {
        var drafts: [NLEventDraft] = []
        var llmReason: String? = nil
        if let llmClient {
            do {
                let scheduler = NLScheduler(llm: llmClient)
                drafts = try await scheduler.parse(input)
            } catch {
                llmReason = "LLM 失败：\(error.localizedDescription)"
            }
        } else {
            llmReason = "未配置 API key"
        }
        let usedLLM = !drafts.isEmpty
        if drafts.isEmpty {
            drafts = LocalNLFallback.parseAll(input)
        }
        guard !drafts.isEmpty else {
            throw NSError(domain: "CyberPet.NL", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法理解，请补充更具体的描述"])
        }
        var saved: [EKEvent] = []
        for d in drafts {
            if let ev = try? calendar.add(title: d.title, start: d.start, end: d.end, notes: d.notes) {
                saved.append(ev)
            }
        }
        guard !saved.isEmpty else {
            throw NSError(domain: "CyberPet.NL", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "解析成功但写入日历失败"])
        }
        refreshTodaysEvents()
        return NLParseOutcome(
            events: saved,
            source: usedLLM ? .llm : .fallback(reason: llmReason ?? "未知")
        )
    }

    /// Compatibility shim — prefer scheduleFromNaturalLanguageDetailed.
    func scheduleFromNaturalLanguage(_ input: String) async throws -> EKEvent {
        guard let first = try await scheduleFromNaturalLanguageDetailed(input).events.first else {
            throw NSError(domain: "CyberPet.NL", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "未生成事件"])
        }
        return first
    }

    // MARK: - Daily summary (M6)

    /// Build today's stats from the persisted store, blending in any in-flight session
    /// numbers by flushing the FocusController's accumulator first.
    func buildTodayStats(day: Date = Date()) -> PersonaResponder.DailyStats {
        focus.flushSessionStats()
        let snap = store.load()
        let s = DailyReport.summarize(snapshot: snap, day: day)
        return .init(
            planMinutes: s.planMinutes,
            focusMinutes: s.focusMinutes,
            distractMinutes: s.distractMinutes,
            interruptionCount: s.interruptionCount,
            topDistractApp: s.topDistractApp
        )
    }

    /// Stream a persona-flavored summary into the bubble. Used both by the right-click
    /// "总结一下" button and by the 23:00 daily auto-trigger.
    @discardableResult
    func summarizeToday() -> PersonaResponder.DailyStats {
        let stats = buildTodayStats()
        let r = responder
        Task { @MainActor in
            let stream = await r.summarizeStream(stats: stats)
            await self.speakStream(stream, autoDismissAfter: 20)
        }
        return stats
    }
}

struct LLMConfig: Codable, Equatable {
    var baseURL: String
    var apiKey: String
    var model: String
    static let `default` = LLMConfig(baseURL: "https://api.deepseek.com/v1", apiKey: "", model: "deepseek-chat")
}
