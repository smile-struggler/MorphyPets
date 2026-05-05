import AppKit
import SwiftUI
import FocusMonitor

struct DiagnosticsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var focus: FocusController
    @State private var info: FrontmostInfo = FrontmostReader.snapshot()
    @State private var ax: Bool = FrontmostReader.hasAccessibilityPermission
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var onClose: () -> Void = {}

    init(state: AppState, onClose: @escaping () -> Void = {}) {
        self.state = state
        self.focus = state.focus
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Morphy Pets 诊断").font(.headline)
                Spacer()
                Button("关闭") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            GroupBox("辅助功能权限") {
                HStack {
                    Image(systemName: ax ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ax ? .green : .orange)
                    Text(ax ? "已授权 — 可以读取浏览器 URL" : "未授权 — 浏览器 URL 读不到，会回退到窗口标题匹配")
                        .font(.callout)
                    Spacer()
                    if !ax {
                        Button("打开系统设置") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                    }
                }.padding(6)
            }

            GroupBox("当前前台") {
                VStack(alignment: .leading, spacing: 4) {
                    row("App", info.appName ?? "?")
                    row("Bundle ID", info.bundleID ?? "?")
                    row("窗口标题", info.windowTitle ?? "(无)")
                    row("URL", info.url ?? "(无)")
                }.padding(6)
            }

            GroupBox("专注会话") {
                VStack(alignment: .leading, spacing: 4) {
                    row("状态", focus.isRunning ? "运行中" : "未启动 — 右键 → 开始专注…")
                    row("当前任务", focus.taskTitle.isEmpty ? "(未设置)" : focus.taskTitle)
                    row("当前分类", focus.currentLabel.rawValue)
                    row("已分心秒数", "\(Int(focus.distractedSeconds))s")
                    row("干预级别", focus.currentDecision.map { "L\($0.level.rawValue)" } ?? "无")
                }.padding(6)
            }

            Text("阈值：L1=30s · L2=90s · L3=180s · L4=300s。打开 b 站等娱乐站点观察「已分心秒数」是否在涨。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 520)
        .onReceive(ticker) { _ in
            info = FrontmostReader.snapshot()
            ax = FrontmostReader.hasAccessibilityPermission
        }
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(v).font(.caption).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer()
        }
    }
}

final class DiagnosticsWindow: NSPanel {
    init(state: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Morphy Pets 诊断"
        level = .floating
        isFloatingPanel = true
        let host = NSHostingView(rootView: DiagnosticsView(state: state, onClose: { [weak self] in
            self?.close()
        }))
        host.frame = contentLayoutRect
        host.autoresizingMask = [.width, .height]
        contentView = host
        center()
    }
}
