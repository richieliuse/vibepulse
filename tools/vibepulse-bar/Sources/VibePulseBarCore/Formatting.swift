import Foundation

public enum Format {
    /// "45m", "3h 53m", "3d 20h". Minutes are the service's own resolution.
    public static func duration(minutes: Int) -> String {
        let minutes = max(0, minutes)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
    }

    public static func duration(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        return self.duration(minutes: seconds / 60)
    }

    /// "just now", "12s ago", "3m ago", "2h ago", "4d ago".
    public static func relative(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    public static func relative(since date: Date, now: Date) -> String {
        self.relative(seconds: Int(now.timeIntervalSince(date).rounded(.down)))
    }

    /// Compact token counts: 5 120 → "5.1K", 48 231 907 → "48.2M", 612 480 233 → "612M".
    public static func tokens(_ value: Double) -> String {
        let value = max(0, value)
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (scale, suffix) in units where value >= scale {
            let scaled = value / scale
            // Keep three significant digits, the same density as a menu card.
            let text = scaled >= 100 ? String(format: "%.0f", scaled.rounded(.down))
                : String(format: "%.1f", (scaled * 10).rounded(.down) / 10)
            return text + suffix
        }
        return String(Int(value))
    }

    /// Whole percent that never calls a partial window full or empty.
    public static func percent(_ value: Double) -> String {
        if value <= 0 { return "0%" }
        if value >= 100 { return "100%" }
        let shown = Int((value + 0.5).rounded(.down))
        return "\(min(99, max(1, shown)))%"
    }

    public static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    }
}
