import Foundation

/// Codex pet.json schema (lenient — Codex's real schema is minimal).
public struct PetManifest: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let spritesheetPath: String

    public init(id: String, displayName: String, description: String? = nil, spritesheetPath: String) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
    }

    public static func load(from directory: URL) throws -> PetManifest {
        let url = directory.appendingPathComponent("pet.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PetManifest.self, from: data)
    }

    public func resolvedSpritesheetURL(in directory: URL) -> URL {
        directory.appendingPathComponent(spritesheetPath)
    }
}

/// Codex convention: 8 columns × 9 rows. Rows map to mood animations.
public struct Atlas: Equatable, Sendable {
    public static let codexCols = 8
    public static let codexRows = 9

    public let cols: Int
    public let rows: Int

    public init(cols: Int = Atlas.codexCols, rows: Int = Atlas.codexRows) {
        self.cols = cols
        self.rows = rows
    }
}

/// Mood -> row-index mapping (Codex convention; can be overridden per-pet later).
public enum PetMood: String, CaseIterable, Sendable {
    case idle, happy, focused, nag, angry, block, sleep, walk, talk

    public var rowIndex: Int {
        switch self {
        case .idle: 0
        case .walk: 1
        case .happy: 2
        case .focused: 3
        case .talk: 4
        case .nag: 5
        case .angry: 6
        case .block: 7
        case .sleep: 8
        }
    }
}
