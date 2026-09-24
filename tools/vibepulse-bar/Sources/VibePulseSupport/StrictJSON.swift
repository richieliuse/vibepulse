import Foundation

public enum StrictJSON {
    /// JSON null, bool, int, double, string, array, object.
    /// Bool is never an int. A JSON integer stays an Int when it fits.
    public enum Value: Sendable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value])
    }

    public enum ParseError: Error, Equatable {
        case invalid
        case trailing
    }

    public static func parse(_ data: Data) -> Result<Value, ParseError> {
        var parser = Parser(Array(data))
        guard let value = parser.parseValue() else { return .failure(.invalid) }
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { return .failure(.trailing) }
        return .success(value)
    }

    public static func object(_ data: Data) -> [String: Value]? {
        guard case let .success(.object(object)) = parse(data) else { return nil }
        return object
    }
}

extension StrictJSON.Value {
    public var object: [String: StrictJSON.Value]? {
        if case let .object(value) = self { return value }
        return nil
    }
    public var array: [StrictJSON.Value]? {
        if case let .array(value) = self { return value }
        return nil
    }
    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }
    public var int: Int? {
        if case let .int(value) = self { return value }
        return nil
    }
    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
    /// Finite number, bool rejected. JSON ints are included.
    public var number: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value) where value.isFinite: return value
        default: return nil
        }
    }
}

private struct Parser {
    var bytes: [UInt8]
    var index = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseValue() -> StrictJSON.Value? {
        skipWhitespace()
        guard let byte = peek() else { return nil }
        switch byte {
        case UInt8(ascii: "n"): return consumeLiteral("null") ? .null : nil
        case UInt8(ascii: "t"): return consumeLiteral("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return consumeLiteral("false") ? .bool(false) : nil
        case UInt8(ascii: "\""): return parseString().map { .string($0) }
        case UInt8(ascii: "["): return parseArray()
        case UInt8(ascii: "{"): return parseObject()
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return parseNumber()
        default: return nil
        }
    }

    mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
    }

    mutating func consumeLiteral(_ text: String) -> Bool {
        let literal = Array(text.utf8)
        guard bytes[index...].starts(with: literal) else { return false }
        index += literal.count
        return true
    }

    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func parseArray() -> StrictJSON.Value? {
        index += 1
        var items: [StrictJSON.Value] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            guard let item = parseValue() else { return nil }
            items.append(item)
            skipWhitespace()
            if peek() == UInt8(ascii: ",") { index += 1; continue }
            if peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
            return nil
        }
    }

    mutating func parseObject() -> StrictJSON.Value? {
        index += 1
        var object: [String: StrictJSON.Value] = [:]
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\""), let key = parseString() else { return nil }
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let value = parseValue() else { return nil }
            object[key] = value
            skipWhitespace()
            if peek() == UInt8(ascii: ",") { index += 1; continue }
            if peek() == UInt8(ascii: "}") { index += 1; return .object(object) }
            return nil
        }
    }

    mutating func parseString() -> String? {
        guard peek() == UInt8(ascii: "\"") else { return nil }
        index += 1
        var out: [UInt8] = []
        while let byte = peek() {
            index += 1
            if byte == UInt8(ascii: "\"") { return String(bytes: out, encoding: .utf8) }
            if byte == UInt8(ascii: "\\") {
                guard let escaped = peek() else { return nil }
                index += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard let scalar = parseHex4() else { return nil }
                    let encoded = String(scalar).utf8
                    out.append(contentsOf: encoded)
                default: return nil
                }
            } else if byte < 0x20 {
                return nil
            } else {
                out.append(byte)
            }
        }
        return nil
    }

    mutating func parseHex4() -> Unicode.Scalar? {
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
        return Unicode.Scalar(value)
    }

    mutating func parseNumber() -> StrictJSON.Value? {
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
        if !fractional, let int = Int(text) { return .int(int) }
        guard let double = Double(text), double.isFinite else { return nil }
        return .double(double)
    }
}
