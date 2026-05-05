import Foundation
#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Drives a SwiftUI view that plays the current mood's animation row.
@MainActor
public final class PetRenderer: ObservableObject {
    @Published public private(set) var currentFrame: CGImage?
    @Published public var mood: PetMood = .idle {
        didSet { frameIndex = 0 }
    }

    public let sheet: SpriteSheet
    public var fps: Double = 8

    private var timer: Timer?
    private var frameIndex: Int = 0

    public init(sheet: SpriteSheet) {
        self.sheet = sheet
        self.currentFrame = framesForMood(.idle).first ?? sheet.frame(row: 0, col: 0)
        start()
    }

    deinit {
        timer?.invalidate()
    }

    public func start() {
        stop()
        let interval = 1.0 / max(fps, 1)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func framesForMood(_ mood: PetMood) -> [CGImage] {
        let frames = sheet.frames(forRow: mood.rowIndex)
        if !frames.isEmpty { return frames }
        // Fallback to idle row if requested mood row is empty.
        let idle = sheet.frames(forRow: PetMood.idle.rowIndex)
        if !idle.isEmpty { return idle }
        // Last resort: any non-empty row.
        for r in 0..<9 {
            let f = sheet.frames(forRow: r)
            if !f.isEmpty { return f }
        }
        return []
    }

    private func tick() {
        let frames = framesForMood(mood)
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        currentFrame = frames[frameIndex]
    }
}

public struct PetView: View {
    @ObservedObject var renderer: PetRenderer
    public var size: CGFloat = 160

    public init(renderer: PetRenderer, size: CGFloat = 160) {
        self.renderer = renderer
        self.size = size
    }

    public var body: some View {
        Group {
            if let frame = renderer.currentFrame {
                Image(decorative: frame, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        // Renderer's timer is started in init() and torn down on deinit; we don't tie
        // it to view lifecycle because the same renderer is shown in multiple views
        // (main overlay + L3/L4 windows). View-driven stop() would freeze the others.
    }
}
#endif
