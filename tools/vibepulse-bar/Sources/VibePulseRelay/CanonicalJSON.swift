import Foundation

/// Canonical protocol JSON: Unicode-code-point key order, no whitespace,
/// `ensure_ascii` escapes. Floats use Swift's shortest round-trip form,
/// which matches CPython `json.dumps` for finite values this codec emits.
public enum CanonicalJSON {
    public enum Value: Sendable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value])
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalid
        case nonFinite
    }

    public static func encode(_ value: Value) throws -> Data {
        var text = ""
        try write(value, into: &text, depth: 0)
        return Data(text.utf8)
    }

    public static func parse(_ data: Data) -> Result<Value, Failure> {
        var parser = Parser(Array(data))
        guard let value = parser.parseValue(depth: 0) else { return .failure(.invalid) }
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { return .failure(.invalid) }
        return .success(value)
    }

    static func encodeObject(_ fields: [String: Value]) throws -> Data {
        try encode(.object(fields))
    }
}

private let maxDepth = 64

private func write(_ value: CanonicalJSON.Value, into text: inout String, depth: Int) throws {
    if depth > maxDepth { throw CanonicalJSON.Failure.invalid }
    switch value {
    case .null:
        text += "null"
    case let .bool(flag):
        text += flag ? "true" : "false"
    case let .int(number):
        text += String(number)
    case let .double(number):
        guard number.isFinite else { throw CanonicalJSON.Failure.nonFinite }
        text += pythonFloat(number)
    case let .string(string):
        text += escaped(string)
    case let .array(items):
        text += "["
        for (index, item) in items.enumerated() {
            if index > 0 { text += "," }
            try write(item, into: &text, depth: depth + 1)
        }
        text += "]"
    case let .object(fields):
        text += "{"
        let keys = fields.keys.sorted { lhs, rhs in
            lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
        }
        for (index, key) in keys.enumerated() {
            if index > 0 { text += "," }
            text += escaped(key)
            text += ":"
            try write(fields[key]!, into: &text, depth: depth + 1)
        }
        text += "}"
    }
}

private func escaped(_ string: String) -> String {
    var out = "\""
    for scalar in string.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x20...0x7E:
            out.unicodeScalars.append(scalar)
        default:
            for unit in String(scalar).utf16 {
                out += String(format: "\\u%04x", unit)
            }
        }
    }
    out += "\""
    return out
}

/// CPython `repr` / `json.dumps` for a finite float: shortest round trip,
/// with a decimal point or exponent so the token is not an integer.
private func pythonFloat(_ value: Double) -> String {
    if value == 0 {
        return value.sign == .minus ? "-0.0" : "0.0"
    }
    let text = String(value)
    if text.contains(".") || text.contains("e") || text.contains("E") {
        return text.replacingOccurrences(of: "e", with: "e").replacingOccurrences(of: "E", with: "e")
    }
    return text + ".0"
}

private struct Parser {
    var bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseValue(depth: Int) -> CanonicalJSON.Value? {
        if depth > maxDepth { return nil }
        skipWhitespace()
        guard let byte = peek() else { return nil }
        switch byte {
        case UInt8(ascii: "n"): return consumeLiteral("null") ? .null : nil
        case UInt8(ascii: "t"): return consumeLiteral("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return consumeLiteral("false") ? .bool(false) : nil
        case UInt8(ascii: "\""): return parseString().map { .string($0) }
        case UInt8(ascii: "["): return parseArray(depth: depth)
        case UInt8(ascii: "{"): return parseObject(depth: depth)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return parseNumber()
        default: return nil
        }
    }

    mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    mutating func consumeLiteral(_ text: String) -> Bool {
        let literal = Array(text.utf8)
        guard bytes[index...].starts(with: literal) else { return false }
        index += literal.count
        return true
    }

    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func parseArray(depth: Int) -> CanonicalJSON.Value? {
        index += 1
        var items: [CanonicalJSON.Value] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            guard let item = parseValue(depth: depth + 1) else { return nil }
            items.append(item)
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if peek() == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            return nil
        }
    }

    mutating func parseObject(depth: Int) -> CanonicalJSON.Value? {
        index += 1
        var object: [String: CanonicalJSON.Value] = [:]
        var seen: [String] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\""), let key = parseString() else { return nil }
            if seen.contains(key) { return nil }
            seen.append(key)
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let value = parseValue(depth: depth + 1) else { return nil }
            object[key] = value
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if peek() == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            return nil
        }
    }

    mutating func parseString() -> String? {
        guard peek() == UInt8(ascii: "\"") else { return nil }
        index += 1
        var utf8: [UInt8] = []
        while let byte = peek() {
            index += 1
            if byte == UInt8(ascii: "\"") {
                return String(bytes: utf8, encoding: .utf8)
            }
            if byte == UInt8(ascii: "\\") {
                guard let escaped = peek() else { return nil }
                index += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                    utf8.append(escaped)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    guard appendUnicodeEscape(into: &utf8) else { return nil }
                default:
                    return nil
                }
            } else if byte < 0x20 {
                return nil
            } else {
                utf8.append(byte)
            }
        }
        return nil
    }

    mutating func appendUnicodeEscape(into utf8: inout [UInt8]) -> Bool {
        guard let unit = parseHex4() else { return false }
        let scalar: Unicode.Scalar
        if (0xD800...0xDBFF).contains(unit) {
            guard peek() == UInt8(ascii: "\\") else { return false }
            index += 1
            guard peek() == UInt8(ascii: "u") else { return false }
            index += 1
            guard let low = parseHex4(), (0xDC00...0xDFFF).contains(low) else { return false }
            let point = 0x10000 + ((Int(unit) - 0xD800) << 10) + (Int(low) - 0xDC00)
            guard let combined = Unicode.Scalar(point) else { return false }
            scalar = combined
        } else if (0xDC00...0xDFFF).contains(unit) {
            return false
        } else {
            guard let direct = Unicode.Scalar(UInt32(unit)) else { return false }
            scalar = direct
        }
        utf8.append(contentsOf: String(scalar).utf8)
        return true
    }

    mutating func parseHex4() -> UInt16? {
        var value = 0
        for _ in 0..<4 {
            guard let byte = peek() else { return nil }
            index += 1
            value *= 16
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value += Int(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value += Int(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value += Int(byte - UInt8(ascii: "A")) + 10
            default: return nil
            }
        }
        return UInt16(value)
    }

    mutating func parseNumber() -> CanonicalJSON.Value? {
        let start = index
        if peek() == UInt8(ascii: "-") { index += 1 }
        guard let first = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { return nil }
        if first == UInt8(ascii: "0") {
            index += 1
        } else {
            while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        }
        var fractional = false
        if peek() == UInt8(ascii: ".") {
            fractional = true
            index += 1
            guard let digit = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else { return nil }
            while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        }
        if let byte = peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            fractional = true
            index += 1
            if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
            guard let digit = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else { return nil }
            while let next = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) { index += 1 }
        }
        let text = String(bytes: bytes[start..<index], encoding: .utf8) ?? ""
        if !fractional {
            guard let int = Int(text) else { return nil }
            return .int(int)
        }
        guard let double = Double(text), double.isFinite else { return nil }
        return .double(double)
    }
}
