import Foundation

public enum ActivityLabel: String, Sendable, Codable {
    case focus, distract, neutral
}

public struct ClassificationRule: Sendable {
    public let hostContains: String
    public let pathContains: String?
    public let label: ActivityLabel
    public init(hostContains: String, pathContains: String? = nil, label: ActivityLabel) {
        self.hostContains = hostContains
        self.pathContains = pathContains
        self.label = label
    }
}

public struct ActivityClassifier: Sendable {
    public var rules: [ClassificationRule]
    public var distractBundleIDs: Set<String>
    public var focusBundleIDs: Set<String>
    public var whitelistDomains: Set<String>
    /// Substrings (lowercased) that, if found in the window title, count as distraction.
    /// Used as a fallback when AX URL is unavailable (e.g. permission denied, browsers we can't read).
    public var distractTitleHints: Set<String>

    public init(
        rules: [ClassificationRule] = ActivityClassifier.defaultRules,
        distractBundleIDs: Set<String> = [],
        focusBundleIDs: Set<String> = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.TextEdit", "md.obsidian", "notion.id"],
        whitelistDomains: Set<String> = [],
        distractTitleHints: Set<String> = ActivityClassifier.defaultDistractTitleHints
    ) {
        self.rules = rules
        self.distractBundleIDs = distractBundleIDs
        self.focusBundleIDs = focusBundleIDs
        self.whitelistDomains = whitelistDomains
        self.distractTitleHints = distractTitleHints
    }

    public static let defaultDistractTitleHints: Set<String> = [
        "哔哩哔哩", "bilibili", "youtube", "抖音", "tiktok", "twitch",
        "微博", "weibo", "知乎", "小红书", "xiaohongshu", "instagram", "reddit",
        "twitter", "推特"
    ]

    public static let defaultRules: [ClassificationRule] = [
        .init(hostContains: "bilibili.com", label: .distract),
        .init(hostContains: "youtube.com", label: .distract),
        .init(hostContains: "douyin.com", label: .distract),
        .init(hostContains: "tiktok.com", label: .distract),
        .init(hostContains: "twitch.tv", label: .distract),
        .init(hostContains: "weibo.com", label: .distract),
        .init(hostContains: "zhihu.com", label: .distract),
        .init(hostContains: "xiaohongshu.com", label: .distract),
        .init(hostContains: "twitter.com", label: .distract),
        .init(hostContains: "x.com", label: .distract),
        .init(hostContains: "reddit.com", label: .distract),
        .init(hostContains: "instagram.com", label: .distract),
        .init(hostContains: "github.com", label: .focus),
        .init(hostContains: "stackoverflow.com", label: .focus),
        .init(hostContains: "overleaf.com", label: .focus),
        .init(hostContains: "notion.so", label: .focus),
        .init(hostContains: "scholar.google", label: .focus),
        .init(hostContains: "arxiv.org", label: .focus),
    ]

    public func classify(bundleID: String?, url: String?, windowTitle: String? = nil) -> ActivityLabel {
        if let bundleID, focusBundleIDs.contains(bundleID) { return .focus }
        if let bundleID, distractBundleIDs.contains(bundleID) { return .distract }
        if let url, let parsed = URL(string: url), let host = parsed.host?.lowercased() {
            if whitelistDomains.contains(where: { host.contains($0) }) { return .focus }
            let path = parsed.path
            for rule in rules {
                if host.contains(rule.hostContains) {
                    if let p = rule.pathContains, !path.contains(p) { continue }
                    return rule.label
                }
            }
        }
        // Window-title fallback (works when AX URL is unavailable).
        if let t = windowTitle?.lowercased(), !t.isEmpty {
            for hint in distractTitleHints where t.contains(hint.lowercased()) {
                return .distract
            }
        }
        return .neutral
    }
}
