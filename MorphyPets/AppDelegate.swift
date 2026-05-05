import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var petWindow: PetOverlayWindow?
    private var interventionPresenter: InterventionPresenter?
    private var dailyReportWindow: DailyReportWindow?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            self.installStatusItem()
            self.showPetOverlay()
            self.interventionPresenter = InterventionPresenter(state: self.appState)
            self.appState.onDailyReportFired = { [weak self] stats in
                guard let self else { return }
                let w = DailyReportWindow(state: self.appState, stats: stats)
                self.dailyReportWindow = w
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐾"
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "显示 / 隐藏桌宠", action: #selector(togglePet), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "退出 Morphy Pets", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    private func showPetOverlay() {
        let win = PetOverlayWindow(state: appState)
        petWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePet() {
        guard let win = petWindow else { showPetOverlay(); return }
        if win.isVisible { win.orderOut(nil) } else { win.makeKeyAndOrderFront(nil) }
    }

    @objc private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
