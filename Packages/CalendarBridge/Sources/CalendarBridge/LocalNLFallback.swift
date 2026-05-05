import Foundation

/// Lightweight Chinese NL → event parser for when the LLM is unavailable.
/// Recognizes patterns like:
///   "明天下午3点 跟导师 meeting 1小时"
///   "今晚 8 点 写代码"
///   "周三上午 10 点 30 分 站会 30 分钟"
public enum LocalNLFallback {
    /// Split input on Chinese/Western commas + "和/还有/然后" and parse each piece;
    /// returns all drafts that parsed successfully.
    public static func parseAll(_ input: String, now: Date = Date()) -> [NLEventDraft] {
        let separators = CharacterSet(charactersIn: ",，;；\n")
        var pieces: [String] = []
        for raw in input.components(separatedBy: separators) {
            // Further split on connectives that don't take punctuation.
            var parts = [raw]
            for token in ["然后", "还有", "再", "和"] {
                parts = parts.flatMap { $0.components(separatedBy: token) }
            }
            for p in parts {
                let t = p.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { pieces.append(t) }
            }
        }
        if pieces.count <= 1 {
            return parse(input, now: now).map { [$0] } ?? []
        }
        return pieces.compactMap { parse($0, now: now) }
    }

    public static func parse(_ input: String, now: Date = Date()) -> NLEventDraft? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let cal = Calendar.current

        // 0. relative time: "N秒后/N分钟后/N小时后/半小时后" — supports Chinese numerals.
        if let rel = parseRelative(text, now: now) {
            return rel
        }

        // 1. day offset
        var day = cal.startOfDay(for: now)
        if text.contains("后天") {
            day = cal.date(byAdding: .day, value: 2, to: day) ?? day
        } else if text.contains("明天") || text.contains("明早") || text.contains("明晚") {
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        } else if let weekday = parseWeekday(text) {
            let today = cal.component(.weekday, from: now)
            var diff = weekday - today
            if diff <= 0 { diff += 7 }
            day = cal.date(byAdding: .day, value: diff, to: day) ?? day
        }

        // 2. period adjustment for "下午/晚上/中午"
        let pmBoost: Int = {
            if text.contains("下午") || text.contains("傍晚") { return 12 }
            if text.contains("晚上") || text.contains("今晚") || text.contains("明晚") { return 12 }
            if text.contains("中午") { return 12 }
            return 0
        }()

        // 3. hour & minute via regex like "8点", "10:30", "10 点 30 分"
        var hour: Int?
        var minute: Int = 0
        if let m = firstMatch(in: text, pattern: #"(\d{1,2})\s*[点:：]\s*(\d{1,2})?"#) {
            hour = Int(m[1]) ?? nil
            if m.count > 2, let mm = Int(m[2]) { minute = mm }
        } else if let m = firstMatch(in: text, pattern: #"(\d{1,2})\s*点(?:半)?"#) {
            hour = Int(m[1]) ?? nil
            if text.contains("点半") { minute = 30 }
        }
        guard var h = hour else { return nil }
        if pmBoost > 0 && h < 12 { h += pmBoost }
        if h >= 24 { h -= 24 }

        guard let start = cal.date(bySettingHour: h, minute: minute, second: 0, of: day) else {
            return nil
        }

        // 4. duration: explicit ("X 小时/X 分钟/半小时") wins; else common sense from title.
        // (Compute it after the title is cleaned below.)

        // 5. title — strip away matched temporal tokens; what's left is title.
        var title = text
        let strips = [
            "后天","明天","明早","明晚","今晚","今早","下午","上午","中午","晚上","傍晚","点半",
            "半小时","小时","分钟",
        ]
        for s in strips { title = title.replacingOccurrences(of: s, with: " ") }
        title = title.replacingOccurrences(
            of: #"\d{1,2}\s*[点:：]\s*\d{0,2}"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(of: #"\d+"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = "新事件" }

        let duration = explicitDuration(in: text) ?? commonSenseDuration(forTitle: title)
        return NLEventDraft(title: title, start: start, end: start.addingTimeInterval(duration), notes: nil)
    }

    /// Match "N 秒/分钟/小时 后 + 标题"，包括中文数字（"十秒后刷牙"）。
    private static func parseRelative(_ text: String, now: Date) -> NLEventDraft? {
        // Capture: number (digits or chinese), unit, optional title trail.
        // We look for "<num><unit>后<title>" anywhere in text.
        let unitMap: [(String, TimeInterval)] = [
            ("秒", 1), ("分钟", 60), ("分", 60), ("小时", 3600), ("个小时", 3600), ("钟头", 3600),
        ]
        // Find "...<num><unit>后..."
        let numPattern = #"([0-9]+|[零一二两三四五六七八九十百千]+)"#
        for (unit, secs) in unitMap {
            let pat = numPattern + unit + "后"
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let m = re.firstMatch(in: text, range: range),
                  let numRange = Range(m.range(at: 1), in: text),
                  let fullRange = Range(m.range, in: text)
            else { continue }
            let numStr = String(text[numRange])
            guard let n = parseChineseOrArabicInt(numStr), n > 0 else { continue }
            let offset = TimeInterval(n) * secs
            let start = now.addingTimeInterval(offset)
            // title = text minus the matched span; clean whitespace.
            var title = text
            title.removeSubrange(fullRange)
            title = title
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if title.isEmpty { title = "提醒" }
            // Duration: explicit ("20 分钟的会") wins; else common sense from title.
            let duration = explicitDuration(in: title) ?? commonSenseDuration(forTitle: title)
            return NLEventDraft(title: title, start: start, end: start.addingTimeInterval(duration), notes: nil)
        }
        // "半小时后" special case
        if let r = text.range(of: "半小时后") {
            let start = now.addingTimeInterval(30 * 60)
            var title = text
            title.removeSubrange(r)
            title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if title.isEmpty { title = "提醒" }
            let duration = explicitDuration(in: title) ?? commonSenseDuration(forTitle: title)
            return NLEventDraft(title: title, start: start, end: start.addingTimeInterval(duration), notes: nil)
        }
        return nil
    }

    /// Pull an explicit duration ("20 分钟的会" / "1 小时" / "半小时" / "1h") out of title.
    /// Returns seconds if found, else nil.
    static func explicitDuration(in text: String) -> TimeInterval? {
        if text.contains("半小时") || text.contains("半个小时") { return 30 * 60 }
        let numPattern = #"([0-9]+|[零一二两三四五六七八九十百千]+)"#
        // hours
        for unit in ["小时", "个小时", "钟头", "h"] {
            let pat = numPattern + unit
            if let m = matchOnce(text, pat),
               let n = parseChineseOrArabicInt(m[1]) {
                return TimeInterval(n) * 3600
            }
        }
        // minutes
        for unit in ["分钟", "min"] {
            let pat = numPattern + unit
            if let m = matchOnce(text, pat),
               let n = parseChineseOrArabicInt(m[1]) {
                return TimeInterval(n) * 60
            }
        }
        return nil
    }

    /// Common-sense duration based on activity keywords in the title. Mirrors the
    /// hints we give to the LLM so fallback parses feel similar.
    static func commonSenseDuration(forTitle title: String) -> TimeInterval {
        // (keywords, minutes) — first match wins; ordered most-specific first.
        let table: [([String], Int)] = [
            (["看电影", "电影"], 120),
            (["午饭", "晚饭", "晚餐", "午餐", "聚餐", "吃饭", "用餐"], 30),
            (["早饭", "早餐"], 20),
            (["开会", "会议", "meeting", "站会", "周会", "例会", "上课", "面试"], 60),
            (["健身", "锻炼", "跑步", "跳绳", "瑜伽", "撸铁"], 60),
            (["写代码", "写作业", "学习", "写论文", "看书", "阅读", "复习"], 60),
            (["通勤", "路上", "去往", "赶过去"], 30),
            (["刷牙", "洗漱", "洗脸", "洗澡"], 10),
            (["喝水", "吃药", "拿快递", "倒垃圾", "充电", "打卡"], 5),
        ]
        for (keys, mins) in table {
            for k in keys where title.contains(k) {
                return TimeInterval(mins * 60)
            }
        }
        return 30 * 60
    }

    private static func matchOnce(_ text: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: text) else { groups.append(""); continue }
            groups.append(String(text[r]))
        }
        return groups
    }

    /// Parses "23" or "十", "二十", "三十五" into Int. Returns nil if unrecognized.
    private static func parseChineseOrArabicInt(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        // Handle simple forms: 十=10, 十X=10+X, X十=X*10, X十Y=X*10+Y, plus 百/千.
        if s == "十" { return 10 }
        var total = 0
        var current = 0
        for ch in s {
            if let d = digits[ch] {
                current = d
            } else if ch == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
            } else if ch == "百" {
                total += (current == 0 ? 1 : current) * 100
                current = 0
            } else if ch == "千" {
                total += (current == 0 ? 1 : current) * 1000
                current = 0
            } else {
                return nil
            }
        }
        total += current
        return total > 0 ? total : nil
    }

    private static func parseWeekday(_ text: String) -> Int? {
        // Calendar.weekday: 1=Sunday … 7=Saturday
        let map: [(String, Int)] = [
            ("周日", 1), ("周一", 2), ("周二", 3), ("周三", 4), ("周四", 5), ("周五", 6), ("周六", 7),
            ("星期日", 1), ("星期一", 2), ("星期二", 3), ("星期三", 4), ("星期四", 5), ("星期五", 6), ("星期六", 7),
        ]
        for (key, val) in map where text.contains(key) { return val }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: text) else { groups.append(""); continue }
            groups.append(String(text[r]))
        }
        return groups
    }
}
