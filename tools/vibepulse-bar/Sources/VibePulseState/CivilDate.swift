import Foundation

/// Calendar date arithmetic with no clock and no time zone.
struct CivilDate: Equatable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// `YYYY-MM-DD` only. Python's wider `fromisoformat` forms are not written.
    static func parse(_ text: String) -> CivilDate? {
        guard text.count == 10, text.utf8.count == 10 else { return nil }
        let bytes = Array(text.utf8)
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else { return nil }
        guard let year = Int(text.prefix(4)), let month = Int(text.dropFirst(5).prefix(2)),
              let day = Int(text.suffix(2)), month >= 1, month <= 12, day >= 1 else { return nil }
        let lengths = [31, isLeap(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= lengths[month - 1] else { return nil }
        return CivilDate(year: year, month: month, day: day)
    }

    static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    }

    var serial: Int { Self.daysFromCivil(year: year, month: month, day: day) }

    func adding(days: Int) -> CivilDate {
        Self.civil(from: serial + days)
    }

    /// Monday = 1 … Sunday = 7. 1970-01-01 is Thursday.
    var isoWeekday: Int {
        let raw = serial % 7
        let mod = raw >= 0 ? raw : raw + 7
        return (mod + 3) % 7 + 1
    }

    var isoYearWeek: (year: Int, week: Int) {
        let thursday = adding(days: 4 - isoWeekday)
        let isoYear = thursday.year
        let jan4 = CivilDate(year: isoYear, month: 1, day: 4)
        let week1Monday = jan4.adding(days: 1 - jan4.isoWeekday)
        let week = (serial - week1Monday.serial) / 7 + 1
        return (isoYear, week)
    }

    var weekKey: String {
        let iso = isoYearWeek
        return String(format: "%d-W%02d", iso.year, iso.week)
    }

    static func monday(ofWeekKey key: String) -> CivilDate? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].hasPrefix("W"), parts[1].count == 3 else { return nil }
        guard let year = Int(parts[0]), let week = Int(parts[1].dropFirst()) else { return nil }
        let jan4 = CivilDate(year: year, month: 1, day: 4)
        let week1Monday = jan4.adding(days: 1 - jan4.isoWeekday)
        let monday = week1Monday.adding(days: (week - 1) * 7)
        let iso = monday.isoYearWeek
        guard iso.year == year, iso.week == week else { return nil }
        return monday
    }

    static func local(epoch: TimeInterval, timeZone: TimeZone = .current) -> CivilDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: epoch))
        return CivilDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    static func today(timeZone: TimeZone = .current) -> CivilDate {
        local(epoch: Date().timeIntervalSince1970, timeZone: timeZone)
    }

    // Howard Hinnant, days_from_civil / civil_from_days.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var year = year
        year -= month <= 2 ? 1 : 0
        let era = (year >= 0 ? year : year - 399) / 400
        let yoe = year - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civil(from z: Int) -> CivilDate {
        let shifted = z + 719468
        let era = (shifted >= 0 ? shifted : shifted - 146096) / 146097
        let doe = shifted - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp + (mp < 10 ? 3 : -9)
        return CivilDate(year: y + (month <= 2 ? 1 : 0), month: month, day: day)
    }
}
