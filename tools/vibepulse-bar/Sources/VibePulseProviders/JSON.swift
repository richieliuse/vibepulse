import CommonCrypto
import Foundation

enum JSON {
    static func object(from data: Data) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return value as? [String: Any]
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func isNull(_ value: Any?) -> Bool {
        value is NSNull || value == nil
    }

    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Finite JSON number. Booleans are rejected.
    static func finite(_ value: Any?) -> Double? {
        guard let value, !isBool(value), let number = value as? NSNumber else { return falseOrNil() }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func falseOrNil() -> Double? { nil }

    static func bool(_ value: Any?) -> Bool? {
        guard let value, isBool(value), let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    /// Top-level object keys in file order. `JSONSerialization` dictionaries do not
    /// keep order, and Grok auth tries entries in the order they were written.
    static func topLevelKeys(in data: Data) -> [String]? {
        var parser = KeyOrderParser(bytes: [UInt8](data))
        return parser.parse()
    }
}

/// Byte scanner for one JSON object. Nested keys are skipped; string bytes are decoded.
private struct KeyOrderParser {
    var bytes: [UInt8]
    var index = 0

    mutating func parse() -> [String]? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        skipWhitespace()
        guard eat(UInt8(ascii: "{")) else { return nil }
        var keys: [String] = []
        skipWhitespace()
        if eat(UInt8(ascii: "}")) {
            return finish(keys)
        }
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            keys.append(key)
            skipWhitespace()
            guard eat(UInt8(ascii: ":")) else { return nil }
            guard skipValue() else { return nil }
            skipWhitespace()
            if eat(UInt8(ascii: "}") ) { return finish(keys) }
            guard eat(UInt8(ascii: ",")) else { return nil }
        }
    }

    private mutating func finish(_ keys: [String]) -> [String]? {
        skipWhitespace()
        return index == bytes.count ? keys : nil
    }

    private mutating func skipValue() -> Bool {
        skipWhitespace()
        guard let byte = peek() else { return false }
        switch byte {
        case UInt8(ascii: "\""): return parseString() != nil
        case UInt8(ascii: "{"): return skipContainer(UInt8(ascii: "{"), UInt8(ascii: "}"))
        case UInt8(ascii: "["): return skipContainer(UInt8(ascii: "["), UInt8(ascii: "]"))
        case UInt8(ascii: "t"): return consume("true")
        case UInt8(ascii: "f"): return consume("false")
        case UInt8(ascii: "n"): return consume("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return skipNumber()
        default: return false
        }
    }

    private mutating func skipContainer(_ open: UInt8, _ close: UInt8) -> Bool {
        guard eat(open) else { return false }
        skipWhitespace()
        if eat(close) { return true }
        let object = open == UInt8(ascii: "{")
        while true {
            if object {
                guard parseString() != nil else { return false }
                skipWhitespace()
                guard eat(UInt8(ascii: ":")) else { return false }
            }
            guard skipValue() else { return false }
            skipWhitespace()
            if eat(close) { return true }
            guard eat(UInt8(ascii: ",")) else { return false }
        }
    }

    private mutating func parseString() -> String? {
        guard eat(UInt8(ascii: "\"")) else { return nil }
        var units: [UInt16] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return string(from: units)
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { return nil }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                    units.append(UInt16(escaped))
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"):
                    guard let unit = hex4() else { return nil }
                    units.append(unit)
                default:
                    return nil
                }
                continue
            }
            if byte < 0x20 { return nil }
            guard let scalar = utf8Scalar() else { return nil }
            append(scalar, to: &units)
        }
        return nil
    }

    private func string(from units: [UInt16]) -> String {
        if units.isEmpty { return "" }
        return units.withUnsafeBufferPointer { buffer in
            String(utf16CodeUnits: buffer.baseAddress!, count: buffer.count)
        }
    }

    private func append(_ scalar: Unicode.Scalar, to units: inout [UInt16]) {
        let value = scalar.value
        if value <= 0xFFFF {
            units.append(UInt16(value))
        } else {
            let shifted = value - 0x10000
            units.append(UInt16(0xD800 + (shifted >> 10)))
            units.append(UInt16(0xDC00 + (shifted & 0x3FF)))
        }
    }

    private mutating func utf8Scalar() -> Unicode.Scalar? {
        guard let first = peek() else { return nil }
        let width: Int
        let bits: UInt32
        let minimum: UInt32
        if first < 0x80 {
            index += 1
            return Unicode.Scalar(first)
        } else if first & 0xE0 == 0xC0 {
            width = 2
            bits = UInt32(first & 0x1F)
            minimum = 0x80
        } else if first & 0xF0 == 0xE0 {
            width = 3
            bits = UInt32(first & 0x0F)
            minimum = 0x800
        } else if first & 0xF8 == 0xF0 {
            width = 4
            bits = UInt32(first & 0x07)
            minimum = 0x10000
        } else {
            return nil
        }
        index += 1
        var value = bits
        for _ in 1..<width {
            guard let next = peek(), next & 0xC0 == 0x80 else { return nil }
            index += 1
            value = (value << 6) | UInt32(next & 0x3F)
        }
        guard value >= minimum, value <= 0x10FFFF, value < 0xD800 || value > 0xDFFF else { return nil }
        return Unicode.Scalar(value)
    }

    private mutating func hex4() -> UInt16? {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = peek() else { return nil }
            index += 1
            let digit: UInt16
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
            value = (value << 4) | digit
        }
        return value
    }

    private mutating func skipNumber() -> Bool {
        if peek() == UInt8(ascii: "-") { index += 1 }
        guard let first = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { return false }
        if first == UInt8(ascii: "0") {
            index += 1
        } else {
            while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        }
        if peek() == UInt8(ascii: ".") {
            index += 1
            guard let digit = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else { return false }
            while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
            guard let digit = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else { return false }
            while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        }
        return true
    }

    private mutating func consume(_ literal: String) -> Bool {
        let bytes = Array(literal.utf8)
        guard self.bytes[index...].starts(with: bytes) else { return false }
        index += bytes.count
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private mutating func eat(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        index += 1
        return true
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
}

enum QuotaIdentity {
    static func make(provider: String, scope: String, raw: String? = nil) -> String {
        let stable = raw ?? "default-v1"
        let material = Data("\(provider)\u{0}\(scope)\u{0}\(stable)".utf8)
        return hex(material)
    }

    static func hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum Instants {
    /// Python `datetime.fromisoformat` after `Z` → `+00:00`.
    /// Naive values are interpreted in `naiveZone` (local for transcripts, UTC for Grok).
    static func parse(_ raw: String, naiveZone: TimeZone) -> TimeInterval? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("Z") {
            text.removeLast()
            text += "+00:00"
        }
        let zone: TimeZone
        let body: String
        if let split = splitOffset(text) {
            guard let parsedZone = TimeZone(secondsFromGMT: split.seconds) else { return nil }
            zone = parsedZone
            body = split.body
        } else {
            zone = naiveZone
            body = text
        }
        guard let parts = dateParts(body) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        components.hour = parts.hour
        components.minute = parts.minute
        components.second = parts.second
        components.nanosecond = parts.nanosecond
        return calendar.date(from: components)?.timeIntervalSince1970
    }

    private struct DateParts {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
        var nanosecond: Int
    }

    private static func splitOffset(_ text: String) -> (body: String, seconds: Int)? {
        guard let index = text.lastIndex(where: { $0 == "+" || $0 == "-" }),
              text.distance(from: text.startIndex, to: index) > 10 else { return nil }
        let sign: Int = text[index] == "-" ? -1 : 1
        let rest = text[text.index(after: index)...]
        let pieces = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let hours: Int
        let minutes: Int
        if pieces.count == 2 {
            guard let h = Int(pieces[0]), let m = Int(pieces[1]), pieces[0].count == 2, pieces[1].count == 2 else {
                return nil
            }
            hours = h
            minutes = m
        } else if pieces.count == 1, pieces[0].count == 4, let h = Int(pieces[0].prefix(2)), let m = Int(pieces[0].suffix(2)) {
            hours = h
            minutes = m
        } else if pieces.count == 1, pieces[0].count == 2, let h = Int(pieces[0]) {
            hours = h
            minutes = 0
        } else {
            return nil
        }
        guard (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
        return (String(text[..<index]), sign * (hours * 3600 + minutes * 60))
    }

    private static func dateParts(_ body: String) -> DateParts? {
        let separator: Character?
        if body.contains("T") {
            separator = "T"
        } else if body.contains(" ") {
            separator = " "
        } else {
            separator = nil
        }
        let dateText: String
        let timeText: String
        if let separator, let index = body.firstIndex(of: separator) {
            dateText = String(body[..<index])
            timeText = String(body[body.index(after: index)...])
        } else {
            dateText = body
            timeText = ""
        }
        let dateBits = dateText.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard dateBits.count == 3, let year = Int(dateBits[0]), let month = Int(dateBits[1]), let day = Int(dateBits[2]),
              dateBits[0].count == 4, dateBits[1].count == 2, dateBits[2].count == 2 else { return nil }
        if timeText.isEmpty {
            return DateParts(year: year, month: month, day: day, hour: 0, minute: 0, second: 0, nanosecond: 0)
        }
        let fractionSplit = timeText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard fractionSplit.count == 1 || fractionSplit.count == 2 else { return nil }
        let clock = fractionSplit[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard clock.count == 3, let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]),
              clock[0].count == 2, clock[1].count == 2, clock[2].count == 2 else { return nil }
        var nanosecond = 0
        if fractionSplit.count == 2 {
            let digits = fractionSplit[1]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let padded = digits.count >= 9 ? String(digits.prefix(9)) : digits + String(repeating: "0", count: 9 - digits.count)
            nanosecond = Int(padded) ?? 0
        }
        return DateParts(year: year, month: month, day: day, hour: hour, minute: minute, second: second, nanosecond: nanosecond)
    }
}

enum ResetTime {
    static func epoch(json value: Any?, now: TimeInterval, naiveZone: TimeZone = .current) -> Int? {
        if let number = JSON.finite(value) {
            return epoch(number: number, now: now)
        }
        if let text = JSON.string(value) {
            return epoch(text: text, now: now, naiveZone: naiveZone)
        }
        return nil
    }

    static func epoch(text: String, now: TimeInterval, naiveZone: TimeZone = .current) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) {
            return epoch(number: number, now: now)
        }
        guard let instant = Instants.parse(trimmed, naiveZone: naiveZone) else { return nil }
        return intEpoch(instant)
    }

    static func epoch(number: Double, now: TimeInterval) -> Int? {
        guard number.isFinite, number >= 0 else { return nil }
        let absolute = number > 1_000_000_000 ? number : now + number
        return intEpoch(absolute)
    }

    static func minutes(until resetAt: Int, now: TimeInterval) -> Int {
        max(0, roundInt((Double(resetAt) - now) / 60))
    }

    static func roundInt(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrEven))
    }

    static func round1(_ value: Double) -> Double {
        let text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        return Double(text) ?? value
    }

    private static func intEpoch(_ value: Double) -> Int? {
        guard value.isFinite, let int = Int(exactly: value.rounded(.towardZero)) else { return nil }
        return int
    }
}

enum RetryAfter {
    static func seconds(_ value: String?, now: TimeInterval) -> Int {
        guard let value else { return 0 }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whole = integer(text), whole >= 0 {
            return whole
        }
        guard let when = httpDate(text) else { return 0 }
        return max(0, ResetTime.roundInt(when - now))
    }

    /// Python `int()` accepts `+42`, `4_2`, and surrounding whitespace.
    static func integer(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "+-0123456789_")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let stripped = trimmed.replacingOccurrences(of: "_", with: "")
        return Int(stripped)
    }

    static func httpDate(_ text: String) -> TimeInterval? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)?.timeIntervalSince1970
    }
}
