import Foundation
#if canImport(EventKit)
import EventKit

@MainActor
public final class CalendarService {
    public let store = EKEventStore()

    public init() {}

    public func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: .event) { granted, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: granted) }
                }
            }
        }
    }

    public func eventsToday() -> [EKEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    @discardableResult
    public func add(title: String, start: Date, end: Date, notes: String? = nil) throws -> EKEvent {
        let ev = EKEvent(eventStore: store)
        ev.title = title
        ev.startDate = start
        ev.endDate = end
        ev.notes = notes
        ev.calendar = store.defaultCalendarForNewEvents
        try store.save(ev, span: .thisEvent, commit: true)
        return ev
    }
}
#endif
