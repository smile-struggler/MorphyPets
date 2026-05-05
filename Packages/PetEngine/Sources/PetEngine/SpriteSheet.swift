#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import Foundation

/// Slices a spritesheet into per-frame CGImages, trimming trailing transparent
/// frames per row (Codex hatch sheets often pad rows with blanks).
public struct SpriteSheet: Sendable {
    public let atlas: Atlas
    public let frameWidth: Int
    public let frameHeight: Int

    /// rows[r] holds only the non-empty frames for row r, in left-to-right order.
    private let rows: [[CGImage]]

    public func frames(forRow row: Int) -> [CGImage] {
        guard rows.indices.contains(row) else { return [] }
        return rows[row]
    }

    public func frame(row: Int, col: Int) -> CGImage? {
        let row = frames(forRow: row)
        return row.indices.contains(col) ? row[col] : nil
    }

    #if canImport(AppKit)
    public static func load(from url: URL, atlas: Atlas = Atlas()) throws -> SpriteSheet {
        guard let image = NSImage(contentsOf: url) else {
            throw SpriteSheetError.cannotDecode(url)
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw SpriteSheetError.cannotDecode(url)
        }
        let frameW = cg.width / atlas.cols
        let frameH = cg.height / atlas.rows

        var rows: [[CGImage]] = []
        rows.reserveCapacity(atlas.rows)
        for row in 0..<atlas.rows {
            var rowFrames: [CGImage] = []
            for col in 0..<atlas.cols {
                let r = CGRect(x: col * frameW, y: row * frameH, width: frameW, height: frameH)
                if let slice = cg.cropping(to: r) {
                    rowFrames.append(slice)
                }
            }
            // Trim trailing fully-transparent frames.
            while let last = rowFrames.last, isMostlyTransparent(last) {
                rowFrames.removeLast()
            }
            rows.append(rowFrames)
        }
        return SpriteSheet(atlas: atlas, frameWidth: frameW, frameHeight: frameH, rows: rows)
    }
    #endif

    public init(atlas: Atlas, frameWidth: Int, frameHeight: Int, rows: [[CGImage]]) {
        self.atlas = atlas
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.rows = rows
    }

    /// Samples a 4×4 grid of pixels; returns true if all alpha values are zero.
    static func isMostlyTransparent(_ image: CGImage) -> Bool {
        let w = max(image.width, 1)
        let h = max(image.height, 1)
        // Render into an 8×8 alpha buffer for cheap sampling.
        let side = 8
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        _ = (w, h)  // silence warnings
        for i in 0..<(side * side) {
            if buffer[i * 4 + 3] > 4 { return false }   // any non-trivially-opaque pixel
        }
        return true
    }
}

public enum SpriteSheetError: Error, CustomStringConvertible {
    case cannotDecode(URL)
    public var description: String {
        switch self {
        case .cannotDecode(let url): "Cannot decode spritesheet at \(url.path)"
        }
    }
}
