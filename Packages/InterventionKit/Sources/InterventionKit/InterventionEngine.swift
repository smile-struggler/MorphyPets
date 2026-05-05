import Foundation
import PetEngine
import PersonaLLM

public enum InterventionLevel: Int, Sendable, Comparable {
    case none = 0, l1 = 1, l2 = 2, l3 = 3, l4 = 4
    public static func < (a: InterventionLevel, b: InterventionLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct InterventionMode: Sendable, Equatable {
    public var maxLevel: InterventionLevel
    public var muteSounds: Bool

    public init(maxLevel: InterventionLevel = .l4, muteSounds: Bool = false) {
        self.maxLevel = maxLevel
        self.muteSounds = muteSounds
    }

    /// 仅 L1+L2，不放大、不挡视线
    public static let lite = InterventionMode(maxLevel: .l2)
    /// 完整四级
    public static let full = InterventionMode(maxLevel: .l4)
    /// 静音：只更新桌宠表情，不弹气泡
    public static let silent = InterventionMode(maxLevel: .l1, muteSounds: true)
}

/// Decides current intervention level from continuous distraction duration & cooldowns.
public final class EscalationPolicy {
    public var thresholds: [TimeInterval] = [30, 90, 180, 300]   // L1..L4 cumulative seconds
    public var l4MaxPerSession: Int = 2
    public var domainL4Counts: [String: Int] = [:]

    public init() {}

    public func levelFor(distractedSeconds: TimeInterval, mode: InterventionMode, currentDomain: String?) -> InterventionLevel {
        var raw: InterventionLevel = .none
        for (i, t) in thresholds.enumerated() where distractedSeconds >= t {
            raw = InterventionLevel(rawValue: i + 1) ?? .none
        }
        // L4 cooldown per-domain per session
        if raw == .l4, let d = currentDomain, (domainL4Counts[d] ?? 0) >= l4MaxPerSession {
            raw = .l2
        }
        // global ceiling
        if raw.rawValue > mode.maxLevel.rawValue {
            raw = mode.maxLevel
        }
        return raw
    }

    public func recordTriggered(_ level: InterventionLevel, domain: String?) {
        guard level == .l4, let d = domain else { return }
        domainL4Counts[d, default: 0] += 1
    }

    public func resetSession() {
        domainL4Counts.removeAll()
    }
}

public struct InterventionDecision: Sendable {
    public let level: InterventionLevel
    public let mood: PetMood
    public let autoDismissAfter: TimeInterval     // 0 means "no auto-dismiss"
    public let allowsCloseButton: Bool
    public let allowsEscape: Bool
    public let aggressive: Bool                   // promise-broken → tile L4 across screen
    /// Snapshot context that produced this decision; used by callers to ask the LLM
    /// for the line (streamed) without holding a reference to the engine.
    public let context: PersonaContext
}

public actor InterventionEngine {
    public let policy = EscalationPolicy()
    public var mode: InterventionMode

    public init(mode: InterventionMode = .full) {
        self.mode = mode
    }

    public func setMode(_ m: InterventionMode) { mode = m }

    public func resetSession() { policy.resetSession() }

    public func setThresholds(_ t: [TimeInterval]) {
        guard t.count == 4 else { return }
        policy.thresholds = t
    }

    /// Pure decision: returns level/mood/aggressive only. The line is generated
    /// separately by PersonaResponder so it can stream into the UI.
    public func decide(distractedSeconds: TimeInterval, taskTitle: String?, domain: String?, app: String?, url: String?, promiseBroken: Bool = false) -> InterventionDecision? {
        let level = policy.levelFor(distractedSeconds: distractedSeconds, mode: mode, currentDomain: domain)
        guard level != .none else { return nil }

        let mood: PetMood
        let autoDismiss: TimeInterval
        switch level {
        case .none, .l1: mood = .nag;   autoDismiss = 6
        case .l2:        mood = .angry; autoDismiss = 12
        case .l3:        mood = .angry; autoDismiss = 0
        case .l4:        mood = .block; autoDismiss = 0
        }
        policy.recordTriggered(level, domain: domain)
        return InterventionDecision(
            level: level,
            mood: mood,
            autoDismissAfter: autoDismiss,
            allowsCloseButton: true,
            allowsEscape: true,
            aggressive: level == .l4 && promiseBroken,
            context: PersonaContext(
                taskTitle: taskTitle,
                distractionApp: app,
                distractionURL: url,
                level: level.rawValue,
                distractedSeconds: Int(distractedSeconds)
            )
        )
    }
}
