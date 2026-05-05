import Foundation
#if canImport(AppKit)
import AppKit

public struct FocusSample: Sendable {
    public let info: FrontmostInfo
    public let label: ActivityLabel
    public let at: Date
}

@MainActor
public final class FocusMonitor {
    public var classifier: ActivityClassifier
    public private(set) var isRunning = false
    public var onSample: ((FocusSample) -> Void)?
    public var pollInterval: TimeInterval = 5

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    public init(classifier: ActivityClassifier = ActivityClassifier()) {
        self.classifier = classifier
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        // Event-driven: react instantly when the user switches apps. AX-internal navigation
        // (URL changes inside the same browser) still relies on the slower poll.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activationObserver = nil
        }
        isRunning = false
    }

    private func tick() {
        let info = FrontmostReader.snapshot()
        let label = classifier.classify(bundleID: info.bundleID, url: info.url, windowTitle: info.windowTitle)
        onSample?(FocusSample(info: info, label: label, at: Date()))
    }
}
#endif
