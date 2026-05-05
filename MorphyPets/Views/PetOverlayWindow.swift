import AppKit
import SwiftUI
import Combine
import PetEngine
import PersonaLLM
import InterventionKit
import FocusMonitor
#if canImport(EventKit)
import EventKit
#endif

final class PetOverlayWindow: NSPanel {
    init(state: AppState) {
        super.init(
            contentRect: NSRect(x: 200, y: 200, width: 280, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: PetOverlayContent(state: state))
        host.frame = contentLayoutRect
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PetOverlayContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var focus: FocusController
    @State private var bubble: String?
    @State private var bubbleDismissTask: Task<Void, Never>?
    @State private var scheduleWindow: ScheduleInputWindow?
    @State private var startSessionWindow: NSWindow?
    @State private var diagnosticsWindow: NSWindow?
    @State private var settingsWindow: NSWindow?
    @State private var dailyReportWindow: NSWindow?

    init(state: AppState) {
        self.state = state
        self.focus = state.focus
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Bubble area or L2 card. L1 = bubble, L2 = inline card with buttons.
            VStack {
                if let decision = focus.currentDecision, decision.level == .l2 {
                    L2Card(
                        focus: focus,
                        onReturn: { focus.returnToTask() },
                        onBreak:  { focus.takeBreak() },
                        onClose:  { focus.currentDecision = nil; focus.currentLine = "" }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else if let bubble {
                    Text(bubble)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 240)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 140)

            // Pet sprite anchored at bottom.
            VStack {
                Spacer(minLength: 0)
                if let renderer = state.renderer {
                    PetView(renderer: renderer, size: 160)
                        .onTapGesture { toggleBubble() }
                        .contextMenu { petMenu }
                } else {
                    Text("没有宠物 🐣\n请到设置导入")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                        .contextMenu { petMenu }
                }
                if focus.isRunning { sessionFooter } else { idleFooter }
            }
        }
        .frame(width: 280, height: 320)
        .animation(.easeInOut(duration: 0.18), value: bubble)
        .animation(.easeInOut(duration: 0.18), value: focus.currentDecision?.level.rawValue)
        .onAppear {
            state.onSpeak = { line in showBubble(line, autoDismissAfter: 8) }
        }
        // L1 line: when engine emits an L1, surface the streaming line through the bubble.
        .onReceive(focus.$currentDecision.combineLatest(focus.$currentLine)) { decision, line in
            guard let d = decision, d.level == .l1 else { return }
            // Don't trample an explicit greeting; only update when streaming meaningful content.
            if !line.isEmpty {
                showBubble(line, autoDismissAfter: d.autoDismissAfter > 0 ? d.autoDismissAfter : 6)
            }
        }
    }

    @ViewBuilder
    private var idleFooter: some View {
        Button {
            openStartSession()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill").foregroundStyle(.tint)
                Text("开始专注")
                    .font(.caption).bold()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var sessionFooter: some View {
        VStack(spacing: 2) {
            Text(focus.taskTitle.isEmpty ? "专注中" : focus.taskTitle)
                .font(.caption).bold()
                .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: focus.currentLabel == .distract ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(focus.currentLabel == .distract ? .orange : .green)
                Text(footerStatusText)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let info = focus.lastInfo {
                Text(diagnosticLine(info))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 240)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 4)
    }

    private func diagnosticLine(_ info: FrontmostInfo) -> String {
        let app = info.appName ?? info.bundleID ?? "?"
        if let url = info.url, let host = URL(string: url)?.host {
            return "\(app) · \(host)"
        }
        if let t = info.windowTitle, !t.isEmpty {
            return "\(app) · \(t)"
        }
        return app
    }

    private var footerStatusText: String {
        switch focus.currentLabel {
        case .focus:    return "专注中"
        case .neutral:  return "—"
        case .distract: return "已分心 \(Int(focus.distractedSeconds))s"
        }
    }

    @ViewBuilder
    private var petMenu: some View {
        if focus.isRunning {
            Button("结束专注") { focus.stop() }
            Button("休息 5 分钟") { focus.takeBreak() }
        } else {
            Button("开始专注…") { openStartSession() }
        }
        Divider()

        Button("排个日程…") { openScheduleInput() }

        Menu("今日日程") {
            if !state.calendarAuthorized {
                Button("请求日历权限") { Task { await state.requestCalendarAccess() } }
            } else if state.todaysEvents.isEmpty {
                Text("今天没有事件")
            } else {
                let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
                ForEach(state.todaysEvents, id: \.eventIdentifier) { ev in
                    Text("\(f.string(from: ev.startDate))  \(ev.title ?? "(无标题)")")
                }
                Divider()
                Button("刷新") { state.refreshTodaysEvents() }
            }
        }

        Divider()

        Menu("人格") {
            ForEach(Persona.allCases, id: \.self) { p in
                Button(action: { state.persona = p; state.rebuildLLM() }) {
                    if state.persona == p {
                        Label(p.displayName, systemImage: "checkmark")
                    } else {
                        Text(p.displayName)
                    }
                }
            }
        }

        Menu("干预模式") {
            interventionModeButton("完整 (L1–L4)",    mode: .full)
            interventionModeButton("仅 L1+L2 不放大", mode: .lite)
            interventionModeButton("静音",            mode: .silent)
        }

        Divider()
        Button("总结一下")          { openDailyReport() }
        Button("诊断…")             { showDiagnostics() }
        Button("设置…")             { openSettings() }
        Button("隐藏桌宠")          { hidePet() }
        Divider()
        Button("退出 Morphy Pets")     { NSApp.terminate(nil) }
    }

    @ViewBuilder
    private func interventionModeButton(_ label: String, mode: InterventionMode) -> some View {
        let isCurrent = state.interventionMode.maxLevel == mode.maxLevel
        Button(action: { state.interventionMode = mode; state.rebuildLLM() }) {
            if isCurrent {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    // MARK: - bubble

    private func toggleBubble() {
        if bubble != nil { dismissBubble(); return }
        state.encourageMe()
    }

    private func startGreeting() {
        let task = state.focus.taskTitle.isEmpty ? nil : state.focus.taskTitle
        let r = state.responder
        bubbleDismissTask?.cancel()
        bubble = "…"
        Task { @MainActor in
            let stream = await r.greetingStream(taskTitle: task)
            await state.speakStream(stream)
        }
    }

    private func showBubble(_ text: String, autoDismissAfter seconds: Double = 4) {
        bubble = text
        bubbleDismissTask?.cancel()
        bubbleDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { bubble = nil }
        }
    }

    private func dismissBubble() {
        bubbleDismissTask?.cancel()
        bubble = nil
    }

    // MARK: - actions

    private func openScheduleInput() {
        if let w = scheduleWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let w = ScheduleInputWindow(state: state)
        scheduleWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func openStartSession() {
        if let w = startSessionWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let panel = StartSessionWindow(state: state, onClose: { [weak window = startSessionWindow] in
            window?.close()
        })
        startSessionWindow = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func openSettings() {
        if let w = settingsWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let w = SettingsPanel(state: state)
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func hidePet() {
        NSApp.windows.first { $0 is PetOverlayWindow }?.orderOut(nil)
    }

    private func showDiagnostics() {
        if let w = diagnosticsWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let w = DiagnosticsWindow(state: state)
        diagnosticsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func openDailyReport() {
        if let w = dailyReportWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let stats = state.buildTodayStats()
        let w = DailyReportWindow(state: state, stats: stats)
        dailyReportWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
