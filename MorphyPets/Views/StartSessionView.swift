import AppKit
import SwiftUI

struct StartSessionView: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void = {}

    @State private var title: String = ""
    @State private var planMinutes: Int = 90
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开始专注").font(.headline)
            Text("接下来这段时间在做什么？")
                .font(.caption).foregroundStyle(.secondary)

            TextField("任务标题（如：写论文 第 3 章）", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { start() }

            Stepper(value: $planMinutes, in: 15...240, step: 15) {
                Text("计划时长：\(planMinutes) 分钟")
            }

            Text("Morphy Pets 会在你切到娱乐站点时按 30s / 90s / 3min / 5min 渐进式提醒。任何弹窗都能用 × 或 Esc 关闭。")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { onClose() }
                Button("开始") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func start() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.focus.taskTitle = t
        state.focus.planMinutes = planMinutes
        state.focus.start()
        onClose()
    }
}

final class StartSessionWindow: NSPanel {
    init(state: AppState, onClose: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "开始专注"
        level = .floating
        isFloatingPanel = true
        let host = NSHostingView(rootView: StartSessionView(state: state, onClose: { [weak self] in
            self?.close(); onClose()
        }))
        host.frame = contentLayoutRect
        host.autoresizingMask = [.width, .height]
        contentView = host
        center()
    }
}
