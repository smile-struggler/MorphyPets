import Foundation
import SwiftUI
import Combine
import FocusMonitor
import InterventionKit
import SessionStore

/// Owns the active focus session and drives the InterventionEngine from FocusMonitor samples.
@MainActor
final class FocusController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var taskTitle: String = ""
    @Published var planMinutes: Int = 90
    @Published private(set) var startedAt: Date?
    @Published private(set) var distractedSeconds: TimeInterval = 0
    @Published private(set) var currentLabel: ActivityLabel = .neutral
    @Published private(set) var lastInfo: FrontmostInfo?
    @Published var currentDecision: InterventionDecision?
    /// Streams in token-by-token from PersonaResponder while a decision is active.
    @Published var currentLine: String = ""

    private let state: AppState
    private let monitor = FocusMonitor()
    /// Public accessor for AppState to push user-edited app/host lists into the classifier.
    var monitorClassifier: ActivityClassifier {
        get { monitor.classifier }
        set { monitor.classifier = newValue }
    }
    private var lastTriggeredLevel: InterventionLevel = .none
    private var lineStreamTask: Task<Void, Never>?
    /// Local 1Hz timer drives smooth counter increments + frequent re-evaluation,
    /// independent of the monitor poll cadence.
    private var heartbeat: Timer?
    /// Set when the user clicks "我现在就工作" at L4. If they relapse to L4 again
    /// within `promiseGrace`, the next decision is marked aggressive (tile across screen).
    private var promisedAt: Date?
    private let promiseGrace: TimeInterval = 120
    /// Slack-off opt-in: domains the user explicitly said "我就是要摸鱼" on.
    /// Suppresses interventions for the rest of the current session (cleared on stop()).
    private var slackOffSession: Set<String> = []

    /// In-memory accumulator for the active session (flushed to store at stop and on
    /// ad-hoc summary requests). Keeps disk I/O low — one second of distraction does not
    /// need its own event row.
    private var currentSession: FocusSession?
    private var focusSecondsAcc: Double = 0
    private var distractSecondsAcc: Double = 0
    /// host → distracted seconds. Empty key for non-browser distract.
    private var distractByHost: [String: Double] = [:]
    /// bundleID → distracted seconds.
    private var distractByApp: [String: Double] = [:]

    init(state: AppState) {
        self.state = state
        monitor.onSample = { [weak self] sample in
            Task { @MainActor in self?.consume(sample) }
        }
    }

    func start() {
        guard !isRunning else { return }
        _ = FrontmostReader.promptAccessibilityPermission()

        var classifier = monitor.classifier
        classifier.whitelistDomains = Set(state.whitelist.keys)
        monitor.classifier = classifier

        isRunning = true
        startedAt = Date()
        distractedSeconds = 0
        lastTriggeredLevel = .none
        promisedAt = nil
        slackOffSession.removeAll()
        focusSecondsAcc = 0
        distractSecondsAcc = 0
        distractByHost.removeAll()
        distractByApp.removeAll()
        let session = FocusSession(
            planMinutes: planMinutes,
            startAt: startedAt ?? Date(),
            taskTitle: taskTitle,
            persona: state.persona.rawValue
        )
        currentSession = session
        state.store.upsert(session: session)
        Task { await state.engine.resetSession() }
        monitor.start()
        startHeartbeat()
    }

    func stop() {
        flushSessionStats()
        monitor.stop()
        stopHeartbeat()
        lineStreamTask?.cancel(); lineStreamTask = nil
        isRunning = false
        startedAt = nil
        distractedSeconds = 0
        currentDecision = nil
        currentLine = ""
    }

    func returnToTask() {
        lineStreamTask?.cancel(); lineStreamTask = nil
        currentDecision = nil
        currentLine = ""
        distractedSeconds = 0
        lastTriggeredLevel = .none
    }

    /// L4 button "我现在就工作": same effect as returnToTask, plus marks a promise
    /// so a relapse within `promiseGrace` will fire an aggressive (tiled) L4.
    func promiseToWork() {
        promisedAt = Date()
        returnToTask()
    }

    /// L4 button "我就是要摸鱼了": user explicitly opts into slack mode for THIS
    /// distraction context. Suppresses further interventions for this domain/app
    /// for the remainder of the session.
    func confessSlacking(reason: String) {
        let key = currentHost ?? lastInfo?.bundleID ?? lastInfo?.appName ?? "unknown"
        slackOffSession.insert(key)
        lineStreamTask?.cancel(); lineStreamTask = nil
        currentDecision = nil
        currentLine = ""
        distractedSeconds = 0
        lastTriggeredLevel = .none
        promisedAt = nil
    }

    func takeBreak(minutes: Int = 5) {
        currentDecision = nil
        monitor.stop()
        stopHeartbeat()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard let self, self.isRunning else { return }
            self.distractedSeconds = 0
            self.lastTriggeredLevel = .none
            self.monitor.start()
            self.startHeartbeat()
        }
    }

    func markReasonable() {
        if let host = currentHost {
            state.whitelist(domain: host)
            var c = monitor.classifier
            c.whitelistDomains.insert(host)
            monitor.classifier = c
        }
        lineStreamTask?.cancel(); lineStreamTask = nil
        currentDecision = nil
        currentLine = ""
        distractedSeconds = 0
        lastTriggeredLevel = .none
    }

    private var currentHost: String? {
        guard let url = lastInfo?.url, let parsed = URL(string: url) else { return nil }
        return parsed.host?.lowercased()
    }

    private var slackOffActive: Bool {
        let key = currentHost ?? lastInfo?.bundleID ?? lastInfo?.appName ?? ""
        return slackOffSession.contains(key)
    }

    /// FocusMonitor poll OR app-switch event delivers a sample → update label/info only.
    /// Accumulation happens on the 1Hz heartbeat below.
    private func consume(_ sample: FocusSample) {
        lastInfo = sample.info
        let host = sample.info.url.flatMap { URL(string: $0)?.host?.lowercased() }
        var label = sample.label
        // Catalog override: bundled seed + LLM-learned classifications.
        if let h = host {
            if let cataLabel = state.siteCatalog.lookup(host: h) {
                label = cataLabel
            } else {
                // Unknown host — fire async LLM classification using the page title.
                state.siteCatalog.ensureClassified(host: h, title: sample.info.windowTitle)
            }
        }
        let effective: ActivityLabel = state.isWhitelisted(domain: host) ? .focus : label
        currentLabel = effective
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTick() }
        }
        heartbeat = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    private func heartbeatTick() {
        guard isRunning else { return }
        switch currentLabel {
        case .distract:
            if slackOffActive { return }
            distractedSeconds += 1
            distractSecondsAcc += 1
            let host = currentHost ?? ""
            distractByHost[host, default: 0] += 1
            if let app = lastInfo?.bundleID { distractByApp[app, default: 0] += 1 }
            evaluate()
        case .focus:
            distractedSeconds = max(0, distractedSeconds - 2)
            focusSecondsAcc += 1
            if distractedSeconds == 0 { lastTriggeredLevel = .none }
            if let d = currentDecision, d.level != .l4 { currentDecision = nil }
        case .neutral:
            distractedSeconds = max(0, distractedSeconds - 0.25)
        }
    }

    private func evaluate() {
        let domain = currentHost
        let app = lastInfo?.appName
        let url = lastInfo?.url
        let title = taskTitle.isEmpty ? nil : taskTitle
        let secs = distractedSeconds
        let engine = state.engine
        let promiseBroken: Bool = {
            guard let p = promisedAt else { return false }
            return Date().timeIntervalSince(p) <= promiseGrace
        }()

        Task { @MainActor in
            guard let decision = await engine.decide(
                distractedSeconds: secs,
                taskTitle: title,
                domain: domain,
                app: app,
                url: url,
                promiseBroken: promiseBroken
            ) else { return }
            // Only escalate; never downgrade an in-flight decision.
            guard decision.level.rawValue > self.lastTriggeredLevel.rawValue else { return }
            self.lastTriggeredLevel = decision.level
            self.currentDecision = decision
            self.logIntervene(decision.level)
            self.streamLine(for: decision)
        }
    }

    private func logIntervene(_ level: InterventionLevel) {
        guard let s = currentSession else { return }
        let kind: FocusEventKind? = {
            switch level {
            case .l1: return .intervene1
            case .l2: return .intervene2
            case .l3: return .intervene3
            case .l4: return .intervene4
            case .none: return nil
            }
        }()
        guard let kind else { return }
        state.store.append(event: FocusEvent(
            sessionID: s.id, ts: Date(), kind: kind,
            appBundle: lastInfo?.bundleID, url: lastInfo?.url, durationS: nil
        ))
    }

    /// Persist accumulated focus/distract durations to the store. Called at session stop
    /// AND on ad-hoc summary so DailyReport sees up-to-date numbers.
    func flushSessionStats() {
        guard let s = currentSession else { return }
        let now = Date()
        if focusSecondsAcc > 0 {
            state.store.append(event: FocusEvent(
                sessionID: s.id, ts: now, kind: .focus,
                appBundle: nil, url: nil, durationS: focusSecondsAcc
            ))
            focusSecondsAcc = 0
        }
        if !distractByApp.isEmpty {
            for (app, secs) in distractByApp where secs > 0 {
                state.store.append(event: FocusEvent(
                    sessionID: s.id, ts: now, kind: .distract,
                    appBundle: app, url: nil, durationS: secs
                ))
            }
            distractByApp.removeAll()
        } else if distractSecondsAcc > 0 {
            state.store.append(event: FocusEvent(
                sessionID: s.id, ts: now, kind: .distract,
                appBundle: nil, url: nil, durationS: distractSecondsAcc
            ))
        }
        distractSecondsAcc = 0
        distractByHost.removeAll()
        // Update session endAt if stopping (caller's responsibility); ensure record exists.
        var updated = s
        if !isRunning { updated.endAt = now }
        state.store.upsert(session: updated)
        currentSession = updated
    }

    private func streamLine(for decision: InterventionDecision) {
        lineStreamTask?.cancel()
        currentLine = ""
        let r = state.responder
        let ctx = decision.context
        lineStreamTask = Task { @MainActor [weak self] in
            let stream = await r.respondStream(to: ctx)
            for await chunk in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                // Drop the stream if the decision has changed under us.
                if self.currentDecision?.level != decision.level { return }
                self.currentLine += chunk
            }
        }
    }
}
