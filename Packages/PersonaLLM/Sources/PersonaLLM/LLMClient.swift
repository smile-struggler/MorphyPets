import Foundation

/// OpenAI-compatible chat completion client. Set `baseURL`/`apiKey`/`model`.
public actor LLMClient {
    public struct Config: Sendable {
        public var baseURL: URL
        public var apiKey: String
        public var model: String
        public var timeout: TimeInterval

        public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 8) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.timeout = timeout
        }
    }

    public struct Message: Codable, Sendable {
        public let role: String
        public let content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    private var config: Config
    /// Plan: "统一限流（信号量 1）" — at most one outbound LLM request at a time.
    /// Implemented as a continuation queue (NOT an empty Task) — the previous
    /// `Task { }` sentinel completed immediately and caused waiters to hot-loop on
    /// the actor, deadlocking the release path.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(config: Config) {
        self.config = config
    }

    public func update(config: Config) {
        self.config = config
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { cc in waiters.append(cc) }
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            busy = false
        }
    }

    /// Non-streaming chat completion. Returns assistant content text.
    public func chat(messages: [Message], jsonMode: Bool = false) async throws -> String {
        await acquire()
        defer { release() }

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url, timeoutInterval: config.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let s = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: s)
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let msg = choices.first?["message"] as? [String: Any],
            let content = msg["content"] as? String
        else {
            throw LLMError.malformedResponse
        }
        return content
    }

    /// Streaming chat completion. Yields incremental delta strings (each yield is a
    /// new chunk, NOT the full accumulated text). Caller is responsible for joining.
    public func chatStream(messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.acquire()
                defer { Task { await self.release() } }

                let body: [String: Any] = [
                    "model": self.config.model,
                    "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    "stream": true,
                ]
                let url = self.config.baseURL.appendingPathComponent("chat/completions")
                var req = URLRequest(url: url, timeoutInterval: self.config.timeout)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("Bearer \(self.config.apiKey)", forHTTPHeaderField: "Authorization")
                do {
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.finish(throwing: LLMError.http(status: http.statusCode, body: ""))
                        return
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty
                        else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum LLMError: Error, CustomStringConvertible, LocalizedError {
    case http(status: Int, body: String)
    case malformedResponse

    public var description: String {
        switch self {
        case .http(let s, let b):
            let trimmed = b.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
            return "HTTP \(s)\(snippet.isEmpty ? "" : "：\(snippet)")"
        case .malformedResponse:
            return "响应格式无法解析"
        }
    }

    public var errorDescription: String? { description }
}
