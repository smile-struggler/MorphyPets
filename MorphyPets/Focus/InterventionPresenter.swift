import AppKit
import Combine
import SwiftUI
import InterventionKit

/// Watches FocusController.currentDecision and spawns L3/L4 windows when needed.
/// L1/L2 are shown by the pet overlay itself, so this presenter only handles L3+.
@MainActor
final class InterventionPresenter {
    private let state: AppState
    private var cancellable: AnyCancellable?
    private var l3Window: L3Window?
    private var l4Windows: [L4Window] = []
    private var autoDismissTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
        cancellable = state.focus.$currentDecision.sink { [weak self] decision in
            self?.handle(decision)
        }
    }

    private func handle(_ decision: InterventionDecision?) {
        autoDismissTask?.cancel()

        guard let decision else {
            closeAll()
            return
        }

        switch decision.level {
        case .l3: showL3(decision: decision)
        case .l4: showL4(decision: decision)
        default: closeAll()
        }

        if decision.autoDismissAfter > 0 {
            autoDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(decision.autoDismissAfter * 1_000_000_000))
                if !Task.isCancelled { self?.dismiss() }
            }
        }
    }

    private func closeAll() {
        l3Window?.close(); l3Window = nil
        l4Windows.forEach { $0.close() }
        l4Windows.removeAll()
    }

    private func showL3(decision: InterventionDecision) {
        l4Windows.forEach { $0.close() }; l4Windows.removeAll()
        guard let renderer = state.renderer else { return }
        renderer.mood = decision.mood
        if let w = l3Window { w.makeKeyAndOrderFront(nil); return }
        let w = L3Window(renderer: renderer, focus: state.focus) { [weak self] in
            self?.dismiss()
        }
        l3Window = w
        w.orderFrontRegardless()
    }

    private func showL4(decision: InterventionDecision) {
        l3Window?.close(); l3Window = nil
        if !l4Windows.isEmpty { l4Windows.first?.makeKeyAndOrderFront(nil); return }

        let copies = decision.aggressive ? 6 : 1

        for screen in NSScreen.screens {
            let overlay = L4ScreenOverlay(
                decision: decision,
                focus: state.focus,
                copies: copies,
                onPromise: { [weak self] in self?.state.focus.promiseToWork() },
                onConfess: { [weak self] reason in self?.state.focus.confessSlacking(reason: reason) },
                onClose:   { [weak self] in self?.dismiss() }
            )
            let w = L4Window(screen: screen) { overlay }
            l4Windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        l4Windows.first?.makeKey()
    }

    private func dismiss() {
        state.focus.currentDecision = nil
    }
}
