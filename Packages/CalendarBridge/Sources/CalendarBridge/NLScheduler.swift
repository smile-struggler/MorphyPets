import Foundation
import PersonaLLM

public struct NLEventDraft: Codable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let notes: String?
}

public actor NLScheduler {
    private let llm: LLMClient

    public init(llm: LLMClient) {
        self.llm = llm
    }

    /// Parse Chinese natural-language input — possibly containing MULTIPLE events in one
    /// utterance — into a list of structured drafts via LLM (json_object mode).
    public func parse(_ input: String, now: Date = Date(), tz: TimeZone = .current) async throws -> [NLEventDraft] {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        isoFmt.timeZone = tz
        let nowISO = isoFmt.string(from: now)

        let system = """
        把中文日程拆为 JSON：{"events":[{"title","start","end","notes"}]}。
        title 不含时间词；start/end 用 ISO8601 含时区。
        当前时间 \(nowISO)（\(tz.identifier)）。相对时间（X秒/分钟/小时后、半小时后）必须基于此时间加偏移；绝对时间（明天/周三/下午3点）按此日期推算。
        时长：用户明示（"20分钟的会"=20m，"半小时"=30m，"1小时"=60m）优先；否则按常识——刷牙/洗漱 10m、早饭 20m、吃饭 30m、开会/上课/学习/写代码 60m、健身 60m、看电影 120m、其它 30m。
        多事件全部输出，按 start 升序。仅输出 JSON。
        """
        let raw = try await llm.chat(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: input),
            ],
            jsonMode: true
        )
        guard let data = raw.data(using: .utf8) else {
            throw NLSchedulerError.cannotParse(raw)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Tolerate either {"events":[...]} or a bare array, or a single object (legacy).
        let drafts: [NLEventDraft]
        if let wrapper = try? decoder.decode(EventsWrapper.self, from: data), !wrapper.events.isEmpty {
            drafts = wrapper.events
        } else if let arr = try? decoder.decode([NLEventDraft].self, from: data), !arr.isEmpty {
            drafts = arr
        } else if let one = try? decoder.decode(NLEventDraft.self, from: data) {
            drafts = [one]
        } else {
            throw NLSchedulerError.cannotParse(raw)
        }

        // Sanity check: if the input contains relative-time markers ("X秒后/X分钟后/X小时后/半小时后")
        // but the LLM produced a start that drifts more than 6 hours from "now", treat the parse
        // as wrong and let the caller fall back. This catches the model's tendency to snap to 14:00.
        let relativeMarkers = ["秒后", "分钟后", "分后", "小时后", "钟头后", "半小时后"]
        let isRelative = relativeMarkers.contains { input.contains($0) }
        if isRelative {
            for d in drafts {
                if abs(d.start.timeIntervalSince(now)) > 6 * 3600 {
                    throw NLSchedulerError.cannotParse(
                        "LLM 忽略了'当前时间'，把相对时间放到了 \(d.start)；已忽略此次结果"
                    )
                }
            }
        }
        return drafts
    }

    private struct EventsWrapper: Codable {
        let events: [NLEventDraft]
    }
}

public enum NLSchedulerError: Error {
    case cannotParse(String)
}
