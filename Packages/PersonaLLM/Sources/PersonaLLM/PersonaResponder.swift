import Foundation

public struct PersonaContext: Sendable {
    public var taskTitle: String?
    public var distractionApp: String?
    public var distractionURL: String?
    public var level: Int                   // 1..4
    public var distractedSeconds: Int

    public init(taskTitle: String?, distractionApp: String?, distractionURL: String?, level: Int, distractedSeconds: Int) {
        self.taskTitle = taskTitle
        self.distractionApp = distractionApp
        self.distractionURL = distractionURL
        self.level = level
        self.distractedSeconds = distractedSeconds
    }
}

/// Generates one-line nags / reminders / greetings with the given persona.
/// Falls back to static lines when no LLM client is configured or the call fails.
public actor PersonaResponder {
    private let client: LLMClient?
    public var persona: Persona
    /// When non-nil and persona == .custom, this string is sent as the system prompt
    /// in place of `Persona.systemPrompt`.
    public var customSystemPrompt: String?

    public init(client: LLMClient?, persona: Persona, customSystemPrompt: String? = nil) {
        self.client = client
        self.persona = persona
        self.customSystemPrompt = customSystemPrompt
    }

    public func setPersona(_ p: Persona) { persona = p }
    public func setCustomSystemPrompt(_ s: String?) { customSystemPrompt = s }

    /// The effective system prompt — custom override (if persona is .custom) or the
    /// enum's built-in prompt.
    nonisolated public static func effectivePrompt(persona: Persona, override: String?) -> String {
        if persona == .custom, let o = override?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return o
        }
        return persona.systemPrompt
    }

    /// Replace the first system message with the effective prompt.
    private func applyOverride(_ messages: [LLMClient.Message]) -> [LLMClient.Message] {
        let effective = Self.effectivePrompt(persona: persona, override: customSystemPrompt)
        guard let first = messages.first, first.role == "system", first.content != effective else {
            return messages
        }
        var out = messages
        out[0] = .init(role: "system", content: effective)
        return out
    }

    // MARK: - Interventions

    public func respond(to ctx: PersonaContext) async -> String {
        guard let client else {
            return FallbackLines.line(persona: persona, level: ctx.level, distractionApp: ctx.distractionApp)
        }
        let messages = interventionMessages(for: ctx)
        do {
            let text = try await client.chat(messages: applyOverride(messages))
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? FallbackLines.line(persona: persona, level: ctx.level, distractionApp: ctx.distractionApp)
                : trimmed
        } catch {
            return FallbackLines.line(persona: persona, level: ctx.level, distractionApp: ctx.distractionApp)
        }
    }

    // MARK: - Reminders

    /// `minutesUntil`: positive = upcoming; 0 = starting now.
    /// Each call sends ONLY the current event context (no history) — keeps the request
    /// cheap and prevents prompt drift across reminders.
    public func respondReminder(title: String, notes: String? = nil, location: String? = nil, minutesUntil: Int) async -> String {
        let fallback = Self.reminderFallback(title: title, minutesUntil: minutesUntil)
        guard let client else { return fallback }
        do {
            let text = try await client.chat(messages: applyOverride(Self.reminderMessages(persona: persona, title: title, notes: notes, location: location, minutesUntil: minutesUntil)))
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        } catch {
            return fallback
        }
    }

    private static func reminderMessages(persona: Persona, title: String, notes: String?, location: String?, minutesUntil: Int) -> [LLMClient.Message] {
        var lines: [String] = ["事件标题：\(title)"]
        if let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            lines.append("备注：\(n)")
        }
        if let l = location?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty {
            lines.append("地点：\(l)")
        }
        if minutesUntil <= 0 {
            lines.append("当前状态：现在开始。请用一句话提醒用户立刻去处理，结合事件性质（会议/写作/锻炼/吃饭等）调整语气。")
        } else {
            lines.append("距离开始还有 \(minutesUntil) 分钟。请用一句话提醒用户做对应的准备（会议→把材料打开；锻炼→换衣服；吃饭→收尾手头工作；等等），结合事件性质调整。")
        }
        return [
            .init(role: "system", content: persona.systemPrompt),
            .init(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    private static func reminderFallback(title: String, minutesUntil: Int) -> String {
        if minutesUntil <= 0 { return "现在开始：\(title)" }
        if minutesUntil <= 2 { return "\(minutesUntil) 分钟后：\(title)，准备好了吗？" }
        return "再过 \(minutesUntil) 分钟：\(title)"
    }

    // MARK: - Casual greeting / acknowledgement

    public func respondGreeting(taskTitle: String?) async -> String {
        let fallback = Self.greetingFallback(taskTitle: taskTitle, persona: persona)
        guard let client else { return fallback }
        let user: String = {
            if let t = taskTitle, !t.isEmpty {
                return "用户当前在做「\(t)」。他点了你一下打招呼。请用一句话回应他。"
            }
            return "用户点了你一下打招呼。请用一句话回应他，可以问问他在做什么或鼓励他开始一段专注。"
        }()
        do {
            let text = try await client.chat(messages: applyOverride([
                .init(role: "system", content: persona.systemPrompt),
                .init(role: "user", content: user),
            ]))
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        } catch {
            return fallback
        }
    }

    private static func greetingFallback(taskTitle: String?, persona: Persona) -> String {
        switch persona {
        case .savage:        return taskTitle.map { "「\($0)」干完了？" } ?? "在的，今天打算摸还是干？"
        case .gentle:        return taskTitle.map { "你在专注「\($0)」呀，加油 💪" } ?? "在的，今天想先做点啥？"
        case .drillSergeant: return taskTitle.map { "继续「\($0)」！立刻！" } ?? "报告任务！"
        case .clown:         return taskTitle.map { "「\($0)」？哈，给爷写！" } ?? "嗨～有啥要拖延的？"
        case .calm:          return taskTitle.map { "你正在「\($0)」。" } ?? "在的，有什么任务？"
        case .custom:        return taskTitle.map { "你正在「\($0)」呢。" } ?? "嗨，今天打算做什么？"
        }
    }

    // MARK: - Streaming

    /// Yields incremental string chunks (NOT cumulative). Falls back to a single
    /// yield of the static line if no LLM is configured or the stream errors.
    public func respondStream(to ctx: PersonaContext) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                guard let client else {
                    continuation.yield(FallbackLines.line(persona: self.persona, level: ctx.level, distractionApp: ctx.distractionApp))
                    continuation.finish()
                    return
                }
                let messages = await self.interventionMessages(for: ctx)
                let stream = await client.chatStream(messages: applyOverride(messages))
                var anyChunk = false
                do {
                    for try await chunk in stream {
                        anyChunk = true
                        continuation.yield(chunk)
                    }
                    if !anyChunk {
                        continuation.yield(FallbackLines.line(persona: self.persona, level: ctx.level, distractionApp: ctx.distractionApp))
                    }
                    continuation.finish()
                } catch {
                    if !anyChunk {
                        continuation.yield(FallbackLines.line(persona: self.persona, level: ctx.level, distractionApp: ctx.distractionApp))
                    }
                    continuation.finish()
                }
            }
        }
    }

    /// Like respondReminder but streamed.
    public func reminderStream(title: String, notes: String? = nil, location: String? = nil, minutesUntil: Int) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let fallback = Self.reminderFallback(title: title, minutesUntil: minutesUntil)
                guard let client else {
                    continuation.yield(fallback); continuation.finish(); return
                }
                let messages = Self.reminderMessages(persona: self.persona, title: title, notes: notes, location: location, minutesUntil: minutesUntil)
                let stream = await client.chatStream(messages: applyOverride(messages))
                var anyChunk = false
                do {
                    for try await chunk in stream { anyChunk = true; continuation.yield(chunk) }
                    if !anyChunk { continuation.yield(fallback) }
                    continuation.finish()
                } catch {
                    if !anyChunk { continuation.yield(fallback) }
                    continuation.finish()
                }
            }
        }
    }

    public func greetingStream(taskTitle: String?) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let fallback = Self.greetingFallback(taskTitle: taskTitle, persona: self.persona)
                guard let client else {
                    continuation.yield(fallback); continuation.finish(); return
                }
                let user: String = {
                    if let t = taskTitle, !t.isEmpty {
                        return "用户当前在做「\(t)」。他点了你一下打招呼。请用一句话回应他。"
                    }
                    return "用户点了你一下打招呼。请用一句话回应他，可以问问他在做什么或鼓励他开始一段专注。"
                }()
                let stream = await client.chatStream(messages: self.applyOverride([
                    .init(role: "system", content: self.persona.systemPrompt),
                    .init(role: "user", content: user),
                ]))
                var anyChunk = false
                do {
                    for try await chunk in stream { anyChunk = true; continuation.yield(chunk) }
                    if !anyChunk { continuation.yield(fallback) }
                    continuation.finish()
                } catch {
                    if !anyChunk { continuation.yield(fallback) }
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Encouragement (right-click "鼓励一下")

    public struct UpcomingEvent: Sendable {
        public let title: String
        public let startsInMinutes: Int   // negative if currently happening
        public init(title: String, startsInMinutes: Int) {
            self.title = title; self.startsInMinutes = startsInMinutes
        }
    }

    public func encourageStream(currentTask: String?, upcoming: [UpcomingEvent]) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let fallback = Self.encourageFallback(persona: self.persona)
                guard let client else {
                    continuation.yield(fallback); continuation.finish(); return
                }
                let messages = Self.encourageMessages(persona: self.persona, currentTask: currentTask, upcoming: upcoming)
                let stream = await client.chatStream(messages: applyOverride(messages))
                var anyChunk = false
                do {
                    for try await chunk in stream { anyChunk = true; continuation.yield(chunk) }
                    if !anyChunk { continuation.yield(fallback) }
                    continuation.finish()
                } catch {
                    if !anyChunk { continuation.yield(fallback) }
                    continuation.finish()
                }
            }
        }
    }

    private static func encourageMessages(persona: Persona, currentTask: String?, upcoming: [UpcomingEvent]) -> [LLMClient.Message] {
        var lines: [String] = []
        if let t = currentTask, !t.isEmpty {
            lines.append("用户当前正在专注：「\(t)」。")
        }
        if upcoming.isEmpty {
            lines.append("今天日历上没有更多安排。")
        } else {
            lines.append("今天接下来的安排：")
            for ev in upcoming.prefix(5) {
                if ev.startsInMinutes <= 0 {
                    lines.append("- 「\(ev.title)」 进行中")
                } else if ev.startsInMinutes < 60 {
                    lines.append("- 「\(ev.title)」 \(ev.startsInMinutes) 分钟后开始")
                } else {
                    let h = ev.startsInMinutes / 60, m = ev.startsInMinutes % 60
                    lines.append("- 「\(ev.title)」 \(h)小时\(m > 0 ? "\(m)分钟" : "")后开始")
                }
            }
        }
        lines.append("请基于上面这些信息，用一两句话给用户一句具体、有针对性的鼓励或加油话——不要空泛说\"加油\"，要扣到具体安排或当前任务上。")
        return [
            .init(role: "system", content: persona.systemPrompt),
            .init(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    private static func encourageFallback(persona: Persona) -> String {
        switch persona {
        case .savage:        return "今天就这？接着干吧，别又去刷手机。"
        case .gentle:        return "今天的事一件件来，我陪着你 💛"
        case .drillSergeant: return "目标已确认！立刻执行！"
        case .clown:         return "今天份的搬砖到货啦～搬完就能躺！"
        case .calm:          return "按计划推进即可，不必焦虑。"
        case .custom:        return "今天有计划，一件件来，能搞定的。"
        }
    }

    // MARK: - Daily summary (M6)

    public struct DailyStats: Sendable {
        public let planMinutes: Int
        public let focusMinutes: Int
        public let distractMinutes: Int
        public let interruptionCount: Int
        public let topDistractApp: String?
        public init(planMinutes: Int, focusMinutes: Int, distractMinutes: Int, interruptionCount: Int, topDistractApp: String?) {
            self.planMinutes = planMinutes
            self.focusMinutes = focusMinutes
            self.distractMinutes = distractMinutes
            self.interruptionCount = interruptionCount
            self.topDistractApp = topDistractApp
        }
    }

    public func summarizeStream(stats: DailyStats) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let fallback = Self.summarizeFallback(persona: self.persona, stats: stats)
                guard let client else {
                    continuation.yield(fallback); continuation.finish(); return
                }
                let messages = Self.summarizeMessages(persona: self.persona, stats: stats)
                let stream = await client.chatStream(messages: applyOverride(messages))
                var anyChunk = false
                do {
                    for try await chunk in stream { anyChunk = true; continuation.yield(chunk) }
                    if !anyChunk { continuation.yield(fallback) }
                    continuation.finish()
                } catch {
                    if !anyChunk { continuation.yield(fallback) }
                    continuation.finish()
                }
            }
        }
    }

    private static func summarizeMessages(persona: Persona, stats: DailyStats) -> [LLMClient.Message] {
        let user = """
        请基于今日数据，用 \(persona.displayName) 的口吻写一段 60–120 字的总结，要有具体情绪和一两个可执行的下次建议。不要空泛说"加油"。
        - 计划专注：\(stats.planMinutes) 分钟
        - 实际专注：\(stats.focusMinutes) 分钟
        - 摸鱼：\(stats.distractMinutes) 分钟
        - 中断次数：\(stats.interruptionCount)
        - 最常分心应用：\(stats.topDistractApp ?? "无")
        """
        return [
            .init(role: "system", content: persona.systemPrompt),
            .init(role: "user", content: user),
        ]
    }

    private static func summarizeFallback(persona: Persona, stats: DailyStats) -> String {
        let ratio = stats.planMinutes > 0
            ? Int(Double(stats.focusMinutes) / Double(stats.planMinutes) * 100)
            : 0
        return "今日计划 \(stats.planMinutes) 分钟，专注 \(stats.focusMinutes) 分钟（\(ratio)%），摸鱼 \(stats.distractMinutes) 分钟，被打断 \(stats.interruptionCount) 次。明天试着早点关掉 \(stats.topDistractApp ?? "诱惑源")。"
    }

    // MARK: - Internal

    private func interventionMessages(for ctx: PersonaContext) -> [LLMClient.Message] {
        let user = """
        当前任务：\(ctx.taskTitle ?? "未指定")
        分心 app：\(ctx.distractionApp ?? "未知")
        分心 URL：\(ctx.distractionURL ?? "无")
        已偏离 \(ctx.distractedSeconds) 秒，干预级别 L\(ctx.level)。
        请用 \(persona.displayName)的口吻说一句提醒。
        """
        return [
            .init(role: "system", content: persona.systemPrompt),
            .init(role: "user", content: user),
        ]
    }
}
