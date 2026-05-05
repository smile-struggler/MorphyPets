import AppKit
import SwiftUI
import PersonaLLM
import SessionStore

/// Daily report panel — shown by right-click "总结一下" or by the 23:00 auto-trigger.
/// Displays today's stats and a streamed persona summary.
struct DailyReportView: View {
    @ObservedObject var state: AppState
    var initialStats: PersonaResponder.DailyStats
    var onClose: () -> Void = {}

    @State private var summary: String = ""
    @State private var streaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("今日总结")
                    .font(.title2).bold()
                Spacer()
                Text(Date(), style: .date)
                    .font(.caption).foregroundStyle(.secondary)
            }

            statsGrid

            Divider()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.fill").foregroundStyle(.tint)
                ScrollView {
                    Text(summary.isEmpty ? "正在让 \(state.persona.displayName) 写两句…" : summary)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: 160)
            }

            HStack {
                Button("重新生成") { regenerate() }
                    .disabled(streaming)
                Spacer()
                Button("关闭") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { regenerate() }
    }

    @ViewBuilder
    private var statsGrid: some View {
        let stats = initialStats
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                statCell("计划专注", "\(stats.planMinutes) 分钟")
                statCell("实际专注", "\(stats.focusMinutes) 分钟")
            }
            GridRow {
                statCell("摸鱼", "\(stats.distractMinutes) 分钟")
                statCell("被打断", "\(stats.interruptionCount) 次")
            }
            GridRow {
                statCell("最常分心", stats.topDistractApp ?? "无")
                EmptyView()
            }
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
    }

    private func regenerate() {
        streaming = true
        summary = ""
        let r = state.responder
        let stats = initialStats
        Task { @MainActor in
            var acc = ""
            let stream = await r.summarizeStream(stats: stats)
            for await chunk in stream {
                acc += chunk
                summary = acc
            }
            streaming = false
        }
    }
}

final class DailyReportWindow: NSPanel {
    init(state: AppState, stats: PersonaResponder.DailyStats) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        title = "今日总结"
        level = .floating
        isFloatingPanel = true
        let host = NSHostingView(rootView: DailyReportView(state: state, initialStats: stats, onClose: { [weak self] in self?.close() }))
        host.frame = contentLayoutRect
        host.autoresizingMask = [.width, .height]
        contentView = host
        center()
    }
}
