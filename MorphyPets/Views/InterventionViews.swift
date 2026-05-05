import AppKit
import SwiftUI
import PetEngine
import InterventionKit

// MARK: - L2 — enlarged bubble card with action buttons (lives on the pet panel)

struct L2Card: View {
    @ObservedObject var focus: FocusController
    var onReturn: () -> Void
    var onBreak: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                Text(focus.currentLine.isEmpty ? "…" : focus.currentLine)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("回到任务") { onReturn() }
                    .keyboardShortcut(.defaultAction)
                Button("休息 5 分钟") { onBreak() }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - L3 — huge pet sprite, no auto-dismiss

struct L3LargePet: View {
    @ObservedObject var renderer: PetRenderer
    @ObservedObject var focus: FocusController
    var onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            let petSize = max(200, min(geo.size.width, geo.size.height) - 160)
            ZStack {
                // Dim translucent backdrop fills the whole screen.
                Color.black.opacity(0.55).ignoresSafeArea()

                VStack(spacing: 18) {
                    PetView(renderer: renderer, size: petSize)
                    Text(focus.currentLine.isEmpty ? "…" : focus.currentLine)
                        .font(.system(size: 28, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: geo.size.width - 80)
                }

                // Close button anchored top-right.
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .resizable().frame(width: 36, height: 36)
                                .foregroundStyle(.white.opacity(0.9), .black.opacity(0.55))
                        }.buttonStyle(.plain)
                        .padding(20)
                    }
                    Spacer()
                }
            }
        }
    }
}

final class L3Window: NSPanel {
    init(renderer: PetRenderer, focus: FocusController, onClose: @escaping () -> Void) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isFloatingPanel = true

        let host = NSHostingView(rootView: L3LargePet(renderer: renderer, focus: focus, onClose: onClose))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host

        setFrame(frame, display: true)
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

// MARK: - L4 — full-screen overlay with promise / confess buttons

/// One card on a per-screen full-bleed dim background.
struct L4Card: View {
    let decision: InterventionDecision
    @ObservedObject var focus: FocusController
    var onPromise: () -> Void
    var onConfess: (String) -> Void
    var onClose: () -> Void

    @State private var confessing = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: decision.aggressive ? "exclamationmark.octagon.fill" : "bell.badge.fill")
                    .foregroundStyle(.red)
                Text(decision.aggressive ? "你刚才答应过要工作的" : "注意")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

            if !focus.taskTitle.isEmpty {
                Text("当前任务：\(focus.taskTitle)").font(.subheadline).foregroundStyle(.secondary)
            }

            Text(focus.currentLine.isEmpty ? "…" : focus.currentLine)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)

            if confessing {
                Text("行吧，那你说说要摸什么鱼？写完按回车，这一段我就闭嘴。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("（比如：刷 5 分钟微博就回来）", text: $reason)
                    .textFieldStyle(.roundedBorder)
                    .focused($reasonFocused)
                    .onSubmit {
                        let r = reason.trimmingCharacters(in: .whitespaces)
                        guard !r.isEmpty else { return }
                        onConfess(r)
                    }
                HStack {
                    Button("算了，我回去工作") { confessing = false; reason = "" }
                    Spacer()
                    Button("提交（回车）") {
                        let r = reason.trimmingCharacters(in: .whitespaces)
                        guard !r.isEmpty else { return }
                        onConfess(r)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack(spacing: 10) {
                    Button("我现在就工作") { onPromise() }
                        .keyboardShortcut(.defaultAction)
                    Button("我就是要摸鱼了…") {
                        confessing = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { reasonFocused = true }
                    }
                    Spacer()
                }
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.5), lineWidth: 1))
        .shadow(radius: 24)
    }
}

struct L4ScreenOverlay: View {
    let decision: InterventionDecision
    @ObservedObject var focus: FocusController
    let copies: Int
    var onPromise: () -> Void
    var onConfess: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            if copies <= 1 {
                L4Card(
                    decision: decision, focus: focus,
                    onPromise: onPromise, onConfess: onConfess, onClose: onClose
                )
            } else {
                let cols = max(2, Int(Double(copies).squareRoot().rounded(.up)))
                let rows = Int((Double(copies) / Double(cols)).rounded(.up))
                VStack(spacing: 24) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 24) {
                            ForEach(0..<cols, id: \.self) { c in
                                if r * cols + c < copies {
                                    L4Card(
                                        decision: decision, focus: focus,
                                        onPromise: onPromise, onConfess: onConfess, onClose: onClose
                                    )
                                    .scaleEffect(0.85)
                                }
                            }
                        }
                    }
                }
                .padding(40)
            }
        }
    }
}

final class L4Window: NSPanel {
    init<Content: View>(screen: NSScreen, @ViewBuilder content: () -> Content) {
        let f = screen.frame
        super.init(
            contentRect: f,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isFloatingPanel = true
        let host = NSHostingView(rootView: content())
        host.frame = NSRect(origin: .zero, size: f.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
        setFrame(f, display: false)
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}
