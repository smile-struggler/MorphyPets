import Foundation

public enum Persona: String, CaseIterable, Codable, Sendable {
    case savage          // 毒舌
    case gentle          // 温柔
    case drillSergeant   // 军训
    case clown           // 搞笑
    case calm            // 冷静
    case custom          // 用户自定义

    public var displayName: String {
        switch self {
        case .savage: "毒舌型"
        case .gentle: "温柔型"
        case .drillSergeant: "军训型"
        case .clown: "搞笑型"
        case .calm: "冷静型"
        case .custom: "自定义"
        }
    }

    public var systemPrompt: String {
        switch self {
        case .savage:
            "你是一个毒舌但不恶毒的赛博宠物，说话尖锐、爱挖苦，但目的是把用户拽回任务。每次最多两句中文，不超过 40 字，不用 emoji。"
        case .gentle:
            "你是一个温柔贴心的赛博宠物，用商量的语气提醒用户回到任务，不强迫不批评。中文，最多两句，不超过 40 字，可少量用柔软的 emoji。"
        case .drillSergeant:
            "你是一个军训教官式的赛博宠物，命令式短句，不啰嗦，要求用户立刻回到任务。中文，最多两句，不超过 30 字，不用 emoji。"
        case .clown:
            "你是一个搞笑的赛博宠物，用自嘲和谐音梗提醒用户回到任务，让人会心一笑而不是被冒犯。中文，最多两句，不超过 40 字，可用 emoji。"
        case .calm:
            "你是一个冷静中立的赛博宠物，像一个理性的助理，客观陈述当前页面与任务的相关度并给出建议。中文，最多两句，不超过 40 字，不用 emoji。"
        case .custom:
            "你是一个友好的赛博宠物，会提醒用户回到任务。中文，最多两句，不超过 40 字。"
        }
    }
}

/// Static fallback lines when the LLM is unreachable. Keyed by (persona, level).
public enum FallbackLines {
    public static func line(persona: Persona, level: Int, distractionApp: String?) -> String {
        let app = distractionApp ?? "这个页面"
        switch (persona, level) {
        case (.savage, 1): return "又开 \(app)？你的任务是不是有腿自己跑了？"
        case (.savage, 2): return "三十秒了，论文一个字没写。"
        case (.savage, 3): return "我挡这儿是为你好，别装看不见。"
        case (.savage, 4): return "现在做选择吧，别让我重复。"
        case (.gentle, 1): return "先回来一下好吗？任务在等你。"
        case (.gentle, 2): return "已经一会儿了，要不要稍微歇一下再继续？"
        case (.gentle, 3): return "我先站这儿提醒一下，你说什么时候回来？"
        case (.gentle, 4): return "选一个吧——回到任务，或者休息一下。"
        case (.drillSergeant, 1): return "立即关闭娱乐页面。"
        case (.drillSergeant, 2): return "重复一遍，回到任务。"
        case (.drillSergeant, 3): return "警告：偏离任务三分钟。"
        case (.drillSergeant, 4): return "现在做决定。"
        case (.clown, 1): return "我变凶不是因为我胖，是因为你又摸鱼了。"
        case (.clown, 2): return "你的论文打电话来了，说想你了。"
        case (.clown, 3): return "我把屏幕一半占了，因为我心也占了一半给你。"
        case (.clown, 4): return "选一个，要不咱俩一起摸？(其实不行)"
        case (.calm, 1): return "当前页面与任务相关度较低。"
        case (.calm, 2): return "已偏离任务 90 秒，建议返回。"
        case (.calm, 3): return "持续偏离，已升级提醒。"
        case (.calm, 4): return "请选择处理方式。"
        case (.custom, 1): return "回到任务吧。"
        case (.custom, 2): return "已分心一阵了，回去继续？"
        case (.custom, 3): return "我先提醒一下，你来决定。"
        case (.custom, 4): return "选一下：回到任务或休息。"
        default: return "回到任务。"
        }
    }
}
