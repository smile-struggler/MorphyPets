import AppKit
import SwiftUI

/// Tiny input window: user types "明天下午3点 跟导师 meeting 1小时" and we add it to Calendar.
struct ScheduleInputView: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void = {}

    @State private var text: String = ""
    @State private var status: Status = .idle
    @FocusState private var focused: Bool

    enum Status: Equatable {
        case idle, working, ok(String), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自然语言排程")
                .font(.headline)
            Text("例：明天下午 3 点 跟导师 meeting 1 小时")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("输入要安排的事…", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }

            HStack {
                statusView
                Spacer()
                Button("取消") { onClose() }
                Button("加入日历") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || status == .working)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle: EmptyView()
        case .working:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("解析中…").font(.caption) }
        case .ok(let s):
            Label(s, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .failed(let s):
            Label(s, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption)
        }
    }

    private func submit() {
        let input = text.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        status = .working
        Task { @MainActor in
            do {
                let outcome = try await state.scheduleFromNaturalLanguageDetailed(input)
                let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"
                let badge: String = {
                    switch outcome.source {
                    case .llm: return "LLM 解析"
                    case .fallback(let r): return "本地规则降级（\(r)）"
                    }
                }()
                let lines = outcome.events.map { ev in
                    "• \(ev.title ?? "(无标题)") · \(f.string(from: ev.startDate))"
                }.joined(separator: "\n")
                let header = outcome.events.count > 1
                    ? "[\(badge)] 已加入 \(outcome.events.count) 件："
                    : "[\(badge)] 已加入："
                status = .ok("\(header)\n\(lines)")
                text = ""
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

/// A small floating panel host for the input view (so the user can tap into it without
/// promoting the menu-bar app to a full activation).
final class ScheduleInputWindow: NSPanel {
    init(state: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "排程"
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        let host = NSHostingView(rootView: ScheduleInputView(state: state, onClose: { [weak self] in self?.close() }))
        host.frame = contentLayoutRect
        host.autoresizingMask = [.width, .height]
        contentView = host
        center()
    }
}
