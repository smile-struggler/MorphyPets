import Foundation
#if canImport(EventKit)
import EventKit

public struct ReminderHit: Sendable {
    public enum Kind: String, Sendable { case t10, t2, t0 }
    public let kind: Kind
    public let title: String
    public let notes: String?
    public let location: String?
    public let start: Date
    public let eventID: String
}

/// Polls the calendar every minute and fires `onFire` when an event reaches its T-10 / T-2 / T-0 mark.
@MainActor
public final class CalendarReminder {
    public var onFire: ((ReminderHit) -> Void)?
    public var pollInterval: TimeInterval = 30

    private let service: CalendarService
    private var timer: Timer?
    /// Tracks fired (eventID, kind) so we don't double-trigger.
    private var firedKeys: Set<String> = []

    public init(service: CalendarService) {
        self.service = service
    }

    public func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        tick()
    }

    public func stop() {
        timer?.invalidate(); timer = nil
    }

    private func tick() {
        let now = Date()
        for ev in service.eventsToday() {
            let secondsUntil = ev.startDate.timeIntervalSince(now)
            for (kind, secs) in [(ReminderHit.Kind.t10, 600.0), (.t2, 120.0), (.t0, 0.0)] {
                // Window: fire if within [secs - 30s, secs + 30s] and not yet fired.
                if abs(secondsUntil - secs) <= pollInterval / 2 + 1 {
                    let id = ev.eventIdentifier ?? "\(ev.title ?? "")-\(ev.startDate.timeIntervalSince1970)"
                    let key = "\(id)|\(kind.rawValue)"
                    if firedKeys.contains(key) { continue }
                    firedKeys.insert(key)
                    let hit = ReminderHit(
                        kind: kind,
                        title: ev.title ?? "(无标题)",
                        notes: ev.notes,
                        location: ev.location,
                        start: ev.startDate,
                        eventID: id
                    )
                    onFire?(hit)
                }
            }
        }
        // Garbage collect entries older than 24h to avoid unbounded growth.
        if firedKeys.count > 500 { firedKeys.removeAll() }
    }
}

public extension ReminderHit {
    var defaultLine: String {
        let t = title
        switch kind {
        case .t10: return "再过 10 分钟：\(t)"
        case .t2:  return "2 分钟后：\(t)，准备好了吗？"
        case .t0:  return "现在开始：\(t)"
        }
    }
}
#endif
