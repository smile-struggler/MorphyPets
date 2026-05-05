import Foundation

public struct FocusSession: Codable, Sendable, Identifiable {
    public var id: UUID
    public var planMinutes: Int
    public var startAt: Date
    public var endAt: Date?
    public var taskTitle: String
    public var persona: String

    public init(id: UUID = UUID(), planMinutes: Int, startAt: Date, endAt: Date? = nil, taskTitle: String, persona: String) {
        self.id = id; self.planMinutes = planMinutes; self.startAt = startAt; self.endAt = endAt
        self.taskTitle = taskTitle; self.persona = persona
    }
}

public enum FocusEventKind: String, Codable, Sendable {
    case focus, distract, breakStart, intervene1, intervene2, intervene3, intervene4, dismiss
}

public struct FocusEvent: Codable, Sendable {
    public var sessionID: UUID
    public var ts: Date
    public var kind: FocusEventKind
    public var appBundle: String?
    public var url: String?
    public var durationS: Double?

    public init(sessionID: UUID, ts: Date, kind: FocusEventKind, appBundle: String? = nil, url: String? = nil, durationS: Double? = nil) {
        self.sessionID = sessionID
        self.ts = ts
        self.kind = kind
        self.appBundle = appBundle
        self.url = url
        self.durationS = durationS
    }
}

/// Minimal JSON-backed store. Replace with GRDB/SQLite when M6 lands.
public final class SessionStore {
    private let url: URL
    private let queue = DispatchQueue(label: "SessionStore", qos: .utility)

    public struct Snapshot: Codable {
        public var sessions: [FocusSession] = []
        public var events: [FocusEvent] = []
    }

    public init(directory: URL? = nil) {
        let dir: URL
        if let directory { dir = directory }
        else {
            let app = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            dir = app.appendingPathComponent("CyberPet", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("sessions.json")
    }

    public func load() -> Snapshot {
        guard let data = try? Data(contentsOf: url) else { return Snapshot() }
        return (try? JSONDecoder.iso.decode(Snapshot.self, from: data)) ?? Snapshot()
    }

    public func save(_ snap: Snapshot) {
        queue.async { [url] in
            if let data = try? JSONEncoder.iso.encode(snap) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public func append(event: FocusEvent) {
        var snap = load()
        snap.events.append(event)
        save(snap)
    }

    public func upsert(session: FocusSession) {
        var snap = load()
        if let i = snap.sessions.firstIndex(where: { $0.id == session.id }) {
            snap.sessions[i] = session
        } else {
            snap.sessions.append(session)
        }
        save(snap)
    }
}

public struct DailySummary: Sendable {
    public let planMinutes: Int
    public let focusMinutes: Int
    public let distractMinutes: Int
    public let interruptionCount: Int
    public let topDistractApp: String?
}

public enum DailyReport {
    public static func summarize(snapshot: SessionStore.Snapshot, day: Date = Date()) -> DailySummary {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let todaysSessions = snapshot.sessions.filter { $0.startAt >= dayStart && $0.startAt < dayEnd }
        let todaysEvents  = snapshot.events.filter { $0.ts >= dayStart && $0.ts < dayEnd }

        let plan = todaysSessions.reduce(0) { $0 + $1.planMinutes }
        let focusSec = todaysEvents.filter { $0.kind == .focus }.reduce(0.0) { $0 + ($1.durationS ?? 0) }
        let distSec  = todaysEvents.filter { $0.kind == .distract }.reduce(0.0) { $0 + ($1.durationS ?? 0) }
        let interruptions = todaysEvents.filter {
            [.intervene1, .intervene2, .intervene3, .intervene4].contains($0.kind)
        }.count

        let appCounts = Dictionary(grouping: todaysEvents.filter { $0.kind == .distract && $0.appBundle != nil },
                                   by: { $0.appBundle! })
            .mapValues { $0.reduce(0.0) { $0 + ($1.durationS ?? 0) } }
        let topApp = appCounts.max(by: { $0.value < $1.value })?.key

        return DailySummary(
            planMinutes: plan,
            focusMinutes: Int(focusSec / 60),
            distractMinutes: Int(distSec / 60),
            interruptionCount: interruptions,
            topDistractApp: topApp
        )
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
}
private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
