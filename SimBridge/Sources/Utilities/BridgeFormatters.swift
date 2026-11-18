import Foundation

enum BridgeFormatters {
    private static let trLocale = Locale(identifier: "tr_TR")

    private static let shortTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = trLocale
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()

    private static let shortRelativeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = trLocale
        df.doesRelativeDateFormatting = true
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    private static let monthDayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = trLocale
        df.dateFormat = "d MMM"
        return df
    }()

    private static let fullDateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = trLocale
        df.dateFormat = "d MMMM yyyy HH:mm:ss"
        return df
    }()

    private static let sectionDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = trLocale
        df.dateFormat = "d MMMM yyyy"
        return df
    }()

    static func shortTime(ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return shortTimeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

    static func fullDateTime(ms: Int64) -> String {
        guard ms > 0 else { return "Bilinmiyor" }
        return fullDateTimeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

    static func recentCallDate(ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return shortRelativeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

    static func threadTimestamp(ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return shortTimeFormatter.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "Dün"
        }
        return monthDayFormatter.string(from: date)
    }

    static func chatDayHeader(ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Bugün"
        }
        if cal.isDateInYesterday(date) {
            return "Dün"
        }
        return sectionDateFormatter.string(from: date)
    }

    static func dayBucket(ms: Int64) -> Date {
        let date = Date(timeIntervalSince1970: Double(max(0, ms)) / 1000.0)
        return Calendar.current.startOfDay(for: date)
    }

    static func callDuration(seconds: Int64) -> String {
        guard seconds > 0 else { return "0 sn" }
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if hrs > 0 {
            return "\(hrs) sa \(mins) dk"
        }
        if mins > 0 {
            return secs > 0 ? "\(mins) dk \(secs) sn" : "\(mins) dk"
        }
        return "\(secs) sn"
    }

    static func liveTimer(sinceMs: Int64, now: Date = Date()) -> String {
        guard sinceMs > 0 else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince1970 - Double(sinceMs) / 1000.0))
        let hrs = elapsed / 3600
        let mins = (elapsed % 3600) / 60
        let secs = elapsed % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    static func initials(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 2, let a = words[0].first, let b = words[1].first, a.isLetter || b.isLetter {
            return String([a, b]).uppercased()
        }
        let letters = trimmed.filter { $0.isLetter }
        if let first = letters.first {
            return String(first).uppercased()
        }
        return "#"
    }

    static func filterDialable(_ input: String) -> String {
        input.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
    }

    private static let gsm7BasicChars: Set<Character> = Set(
        "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ ÆæßÉ!\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
    )
    private static let gsm7ExtendedChars: Set<Character> = Set("^{}\\[~]|€\u{000C}")

    /// Computes exact GSM-7 (160/153, extended chars = 2) vs UCS-2 (70/67) SMS segment counts.
    static func smsSegmentInfo(for text: String) -> (chars: Int, segments: Int, isUnicode: Bool) {
        if text.isEmpty {
            return (0, 0, false)
        }
        var gsmLength = 0
        var isUnicode = false
        for ch in text {
            if gsm7BasicChars.contains(ch) {
                gsmLength += 1
            } else if gsm7ExtendedChars.contains(ch) {
                gsmLength += 2
            } else {
                isUnicode = true
                break
            }
        }
        if isUnicode {
            let uLen = text.utf16.count
            let segs = uLen <= 70 ? 1 : (uLen + 66) / 67
            return (uLen, segs, true)
        }
        let segs = gsmLength <= 160 ? 1 : (gsmLength + 152) / 153
        return (gsmLength, segs, false)
    }

    private static let linkDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func extractWebUrls(from text: String) -> [URL] {
        guard !text.isEmpty, let detector = linkDetector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var urls: [URL] = []
        var seen: Set<String> = []
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let url = match?.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return
            }
            let abs = url.absoluteString
            if seen.insert(abs).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    static func shortUrlLabel(_ url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let path = url.path
            if path.count > 1 && path.count <= 18 {
                return "\(cleanHost)\(path)"
            }
            return cleanHost
        }
        return url.absoluteString
    }
}
