import SwiftUI
import AppKit
import PetEngine
import PersonaLLM
import FocusMonitor
import InterventionKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("通用", systemImage: "gear") }
            LLMPane().tabItem { Label("LLM", systemImage: "brain") }
            PetsPane().tabItem { Label("宠物库", systemImage: "pawprint") }
            InterventionPane().tabItem { Label("干预", systemImage: "bell") }
        }
        .frame(width: 640, height: 540)
        .padding()
    }
}

private struct GeneralPane: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Morphy Pets · 百变萌宠")
                    .font(.headline)
                Text("桌面陪伴式防摸鱼助手。在状态栏 🐾 菜单中可以隐藏 / 显示桌宠。")
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                Text("每日总结时间").font(.subheadline).bold()
                HStack {
                    DatePicker("", selection: dailyReportTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("每天到点自动弹出今日总结。也可右键宠物 → 总结一下手动触发。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 4)

                Text("人格").font(.subheadline).bold()
                Picker("", selection: $state.persona) {
                    ForEach(Persona.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .onChange(of: state.persona) { _, _ in state.rebuildLLM() }

                if state.persona == .custom {
                    Text("自定义 system prompt").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $state.customPersonaPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .border(Color.secondary.opacity(0.3))
                    Text("修改后会立即生效。每次请求都只发当条 prompt + 当前事件，不带历史。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(state.persona.systemPrompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var dailyReportTimeBinding: Binding<Date> {
        Binding(
            get: {
                let cal = Calendar.current
                var c = cal.dateComponents([.year, .month, .day], from: Date())
                c.hour = state.dailyReportHour
                c.minute = state.dailyReportMinute
                return cal.date(from: c) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                state.dailyReportHour = comps.hour ?? 23
                state.dailyReportMinute = comps.minute ?? 0
            }
        )
    }
}

private struct LLMPane: View {
    @EnvironmentObject var state: AppState
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle, running, ok(String), failed(String)
    }

    var body: some View {
        Form {
            TextField("Base URL", text: $state.llmConfig.baseURL)
            SecureField("API Key", text: $state.llmConfig.apiKey)
            TextField("Model", text: $state.llmConfig.model)
            HStack {
                Button("应用") { state.rebuildLLM() }
                Button("测试连通性") { runTest() }
                    .disabled(testStatus == .running || state.llmConfig.apiKey.isEmpty)
                statusView
            }
            Text("OpenAI 兼容协议。留空 API Key 走纯本地 fallback 台词。")
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Toggle("精细判别是否为摸鱼行为", isOn: $state.siteAutoClassify)
            Text(state.siteAutoClassify
                 ? "开启后，遇到未在内置仓库里的网站会调用 LLM 判断一次（结果缓存到本地）。浏览面广时可能产生较多 token 开销。"
                 : "关闭中：仅使用内置 sites.json 的分类。未识别的网站按 neutral 处理。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch testStatus {
        case .idle: EmptyView()
        case .running:
            HStack(spacing: 4) { ProgressView().controlSize(.small); Text("测试中…").font(.caption) }
        case .ok(let s):
            Label(s, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .failed(let s):
            Label(s, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }

    private func runTest() {
        // Apply current settings before testing so the test reflects what the user sees in fields.
        state.rebuildLLM()
        guard let client = state.llmClient else {
            testStatus = .failed("未创建客户端：检查 Base URL / API Key")
            return
        }
        let model = state.llmConfig.model
        testStatus = .running
        Task { @MainActor in
            let start = Date()
            do {
                let reply = try await client.chat(messages: [
                    .init(role: "system", content: "你是连通性测试助手。"),
                    .init(role: "user", content: "回复一个字：好"),
                ])
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let preview = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20)
                testStatus = .ok("OK · \(model) · \(ms)ms · \(preview)")
            } catch {
                testStatus = .failed(error.localizedDescription)
            }
        }
    }
}

private struct PetsPane: View {
    @EnvironmentObject var state: AppState
    @State private var installed: [PetManifest] = []
    @State private var fromCodex: [(PetManifest, URL)] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("已安装").font(.headline)
                Spacer()
                Text("拖拽重排序")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(installed, id: \.id) { p in
                    HStack {
                        if state.activePet?.id == p.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "pawprint").foregroundStyle(.secondary)
                        }
                        Text(p.displayName)
                        Spacer()
                        Button("使用") { state.activate(pet: p) }
                            .disabled(state.activePet?.id == p.id)
                        Button(role: .destructive) {
                            uninstall(p)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .onMove(perform: move)
            }
            .frame(height: 160)

            Text("从 Codex 导入 (~/.codex/pets/)").font(.headline).padding(.top)
            List(fromCodex, id: \.0.id) { entry in
                HStack {
                    Text(entry.0.displayName)
                    Spacer()
                    Button("导入") {
                        if let m = try? state.petLibrary.importPet(from: entry.1) {
                            state.activate(pet: m)
                            refresh()
                        }
                    }
                }
            }
            .frame(height: 100)
            HStack {
                Button("从文件夹导入…") { importFromFolder() }
                Button("刷新") { refresh() }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        installed = state.petLibrary.installedPets()
        fromCodex = state.petLibrary.discoverCodexPets()
    }

    private func move(from source: IndexSet, to destination: Int) {
        installed.move(fromOffsets: source, toOffset: destination)
        state.petLibrary.setOrder(installed.map { $0.id })
    }

    private func uninstall(_ pet: PetManifest) {
        let alert = NSAlert()
        alert.messageText = "卸载「\(pet.displayName)」？"
        alert.informativeText = "会从磁盘删除该宠物的资源文件，操作不可恢复。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wasActive = state.activePet?.id == pet.id
        state.petLibrary.uninstall(pet: pet)
        refresh()
        if wasActive, let next = installed.first {
            state.activate(pet: next)
        } else if wasActive {
            state.activePet = nil
            state.renderer = nil
        }
    }

    private func importFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url,
           let m = try? state.petLibrary.importPet(from: url) {
            state.activate(pet: m); refresh()
        }
    }
}

private struct InterventionPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("干预模式", selection: Binding(
                    get: { modeKey(state.interventionMode) },
                    set: { state.interventionMode = mode(for: $0); state.rebuildLLM() }
                )) {
                    Text("完整 (L1–L4)").tag("full")
                    Text("仅 L1+L2（不放大）").tag("lite")
                    Text("静音（仅状态栏 + 表情）").tag("silent")
                }

                Toggle("测试模式（阈值 3/6/9/12s）", isOn: $state.testMode)
                Text(state.testMode
                     ? "当前阈值：L1=3s · L2=6s · L3=9s · L4=12s。"
                     : currentThresholdLabel)
                    .font(.caption).foregroundStyle(.secondary)

                thresholdEditor

                Text("无论哪个级别，弹窗都可用 × 或 Esc 关闭，也会自动收回。")
                    .font(.caption).foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                Text("摸鱼 / 工作 名单").font(.headline)
                Text("内置条目可直接删除（删除后不会再被识别）；下方可添加自己的网站（host 子串）或应用（bundle ID）。")
                    .font(.caption).foregroundStyle(.secondary)
                TwoColumnLists()
                    .frame(minHeight: 320)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var thresholdEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("自定义阈值（秒，仅在非测试模式下生效）")
                .font(.subheadline).bold()
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text("L\(i+1)").font(.caption).foregroundStyle(.secondary)
                        TextField("", value: thresholdBinding(at: i), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                    }
                }
                Button("恢复默认") { state.customThresholds = nil }
                    .padding(.leading, 8)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
    }

    private var currentThresholdLabel: String {
        let t = state.customThresholds ?? AppState.normalThresholds
        return "当前阈值：L1=\(Int(t[0]))s · L2=\(Int(t[1]))s · L3=\(Int(t[2]))s · L4=\(Int(t[3]))s。"
    }

    private func thresholdBinding(at i: Int) -> Binding<Int> {
        Binding(
            get: {
                let t = state.customThresholds ?? AppState.normalThresholds
                return Int(t[i])
            },
            set: { newVal in
                var t = state.customThresholds ?? AppState.normalThresholds
                t[i] = TimeInterval(max(1, newVal))
                state.customThresholds = t
            }
        )
    }

    private func modeKey(_ m: InterventionMode) -> String {
        switch m.maxLevel {
        case .l4: "full"; case .l2: "lite"; default: "silent"
        }
    }
    private func mode(for key: String) -> InterventionMode {
        switch key {
        case "full": .full; case "lite": .lite; default: .silent
        }
    }
}

/// Two parallel columns (摸鱼 / 工作), each listing seed + user-added websites and apps.
/// Seed entries are read-only; user entries can be removed.
private struct TwoColumnLists: View {
    @EnvironmentObject var state: AppState
    @State private var draftDistract: String = ""
    @State private var draftFocus: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column(
                title: "🐟 摸鱼",
                tint: .orange,
                seedHosts: seedHosts(label: .distract),
                seedApps: [],
                userHosts: $state.userDistractHosts,
                userApps: $state.userDistractApps,
                draft: $draftDistract,
                placeholder: "host (bilibili.com) 或 bundleID"
            )
            column(
                title: "💼 工作",
                tint: .green,
                seedHosts: seedHosts(label: .focus),
                seedApps: visibleSeedFocusApps(),
                userHosts: $state.userFocusHosts,
                userApps: $state.userFocusApps,
                draft: $draftFocus,
                placeholder: "host (github.com) 或 bundleID"
            )
        }
    }

    private func seedHosts(label: ActivityLabel) -> [String] {
        let removed = Set(state.userRemovedSeedHosts)
        return state.siteCatalog.seedEntries.compactMap {
            $0.label == label && !removed.contains($0.host) ? $0.host : nil
        }
    }

    private func visibleSeedFocusApps() -> [String] {
        let removed = Set(state.userRemovedSeedApps)
        return AppState.seedFocusApps.filter { !removed.contains($0) }
    }

    @ViewBuilder
    private func column(
        title: String, tint: Color,
        seedHosts: [String], seedApps: [String],
        userHosts: Binding<[String]>, userApps: Binding<[String]>,
        draft: Binding<String>, placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold().foregroundStyle(tint)
            HStack(spacing: 6) {
                TextField(placeholder, text: draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addUserEntry(draft: draft, hosts: userHosts, apps: userApps) }
                Button("添加") {
                    addUserEntry(draft: draft, hosts: userHosts, apps: userApps)
                }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                Section("内置") {
                    ForEach(seedHosts, id: \.self) { h in
                        rowEditable(h, kind: .host, isSeed: true) {
                            if !state.userRemovedSeedHosts.contains(h) {
                                state.userRemovedSeedHosts.append(h)
                            }
                        }
                    }
                    ForEach(seedApps, id: \.self) { a in
                        rowEditable(a, kind: .app, isSeed: true) {
                            if !state.userRemovedSeedApps.contains(a) {
                                state.userRemovedSeedApps.append(a)
                            }
                        }
                    }
                }
                Section("我的") {
                    ForEach(userHosts.wrappedValue, id: \.self) { h in
                        rowEditable(h, kind: .host, isSeed: false) {
                            userHosts.wrappedValue.removeAll { $0 == h }
                        }
                    }
                    ForEach(userApps.wrappedValue, id: \.self) { a in
                        rowEditable(a, kind: .app, isSeed: false) {
                            userApps.wrappedValue.removeAll { $0 == a }
                        }
                    }
                    if userHosts.wrappedValue.isEmpty && userApps.wrappedValue.isEmpty {
                        Text("（暂无）").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 260)
        }
        .frame(maxWidth: .infinity)
    }

    private enum EntryKind { case host, app }

    @ViewBuilder
    private func rowEditable(_ s: String, kind: EntryKind, isSeed: Bool, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: kind == .host ? "globe" : "app.fill")
                .foregroundStyle(isSeed ? Color.secondary : Color.accentColor)
            Text(s).font(.body.monospaced())
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }.buttonStyle(.borderless)
        }
    }

    /// Heuristic: contains a dot AND no slash → host; otherwise treat as bundle ID.
    private func addUserEntry(draft: Binding<String>, hosts: Binding<[String]>, apps: Binding<[String]>) {
        let s = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        let looksLikeHost = s.contains(".") && !s.contains(" ")
            && !s.hasPrefix("com.") && !s.hasPrefix("io.") && !s.hasPrefix("org.") && !s.hasPrefix("md.")
            && !s.hasPrefix("tv.") && !s.hasPrefix("net.") && !s.hasPrefix("ai.") && !s.hasPrefix("dev.")
        if looksLikeHost {
            if !hosts.wrappedValue.contains(s) { hosts.wrappedValue.append(s) }
        } else {
            if !apps.wrappedValue.contains(s) { apps.wrappedValue.append(s) }
        }
        draft.wrappedValue = ""
    }
}

final class SettingsPanel: NSPanel {
    init(state: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Morphy Pets 设置"
        level = .floating
        isFloatingPanel = true
        let host = NSHostingView(rootView: SettingsView().environmentObject(state))
        host.frame = contentLayoutRect
        host.autoresizingMask = [.width, .height]
        contentView = host
        center()
    }
}
