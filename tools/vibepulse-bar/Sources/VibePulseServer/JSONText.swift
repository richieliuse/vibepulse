import Foundation
import VibePulseAgents
import VibePulseRelay
import VibePulseSupport

/// Ordered JSON. Bool is never a number, and null stays null.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(left), .bool(right)): return left == right
        case let (.int(left), .int(right)): return left == right
        case let (.double(left), .double(right)): return left == right
        case let (.string(left), .string(right)): return left == right
        case let (.array(left), .array(right)):
            guard left.count == right.count else { return false }
            for (lhsValue, rhsValue) in zip(left, right) where lhsValue != rhsValue { return false }
            return true
        case let (.object(left), .object(right)):
            guard left.count == right.count else { return false }
            for (lhsPair, rhsPair) in zip(left, right) {
                if lhsPair.0 != rhsPair.0 || lhsPair.1 != rhsPair.1 { return false }
            }
            return true
        default: return false
        }
    }

    var object: [String: JSONValue]? {
        guard case let .object(pairs) = self else { return nil }
        var fields: [String: JSONValue] = [:]
        for (key, value) in pairs { fields[key] = value }
        return fields
    }

    /// Finite number. Bool is rejected.
    var number: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value) where value.isFinite: return value
        default: return nil
        }
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    func encode() throws -> Data {
        var text = ""
        try write(into: &text, depth: 0)
        return Data(text.utf8)
    }

    func foundation() -> Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .string(value): return value
        case let .array(values): return values.map { $0.foundation() }
        case let .object(pairs):
            var fields: [String: Any] = [:]
            for (key, value) in pairs { fields[key] = value.foundation() }
            return fields
        }
    }

    private func write(into text: inout String, depth: Int) throws {
        if depth > 64 { throw JSONEncodeError.tooDeep }
        switch self {
        case .null:
            text += "null"
        case let .bool(value):
            text += value ? "true" : "false"
        case let .int(value):
            text += String(value)
        case let .double(value):
            guard value.isFinite else { throw JSONEncodeError.nonFinite }
            text += Self.numberText(value)
        case let .string(value):
            text += Self.escaped(value)
        case let .array(values):
            text += "["
            for (index, value) in values.enumerated() {
                if index > 0 { text += "," }
                try value.write(into: &text, depth: depth + 1)
            }
            text += "]"
        case let .object(pairs):
            text += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { text += "," }
                text += Self.escaped(pair.0)
                text += ":"
                try pair.1.write(into: &text, depth: depth + 1)
            }
            text += "}"
        }
    }

    private static func numberText(_ value: Double) -> String {
        if value.rounded(.towardZero) == value, value >= Double(Int.min), value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
    }

    private static func escaped(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F:
                out += String(format: "\\u%04x", scalar.value)
            case 0x20...0x7E:
                out.unicodeScalars.append(scalar)
            default:
                if scalar.value > 0xFFFF {
                    let adjusted = scalar.value - 0x10000
                    let high = 0xD800 + (adjusted >> 10)
                    let low = 0xDC00 + (adjusted & 0x3FF)
                    out += String(format: "\\u%04x\\u%04x", high, low)
                } else {
                    out += String(format: "\\u%04x", scalar.value)
                }
            }
        }
        out += "\""
        return out
    }

    static func from(_ value: Any) -> JSONValue {
        if value is NSNull { return .null }
        if type(of: value) == Bool.self, let flag = value as? Bool { return .bool(flag) }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        if let number = value as? NSNumber {
            if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                return double.isFinite ? .double(double) : .null
            }
            return .int(number.intValue)
        }
        if let int = value as? Int { return .int(int) }
        if let double = value as? Double { return double.isFinite ? .double(double) : .null }
        if let string = value as? String { return .string(string) }
        if let items = value as? [Any] { return .array(items.map(from)) }
        if let fields = value as? [String: Any] {
            let pairs = fields.keys.sorted().map { ($0, from(fields[$0] as Any)) }
            return .object(pairs)
        }
        return .null
    }

    static func from(strict value: StrictJSON.Value) -> JSONValue {
        switch value {
        case .null: return .null
        case let .bool(flag): return .bool(flag)
        case let .int(number): return .int(number)
        case let .double(number): return number.isFinite ? .double(number) : .null
        case let .string(text): return .string(text)
        case let .array(items): return .array(items.map(from(strict:)))
        case let .object(fields):
            return .object(fields.keys.sorted().map { ($0, from(strict: fields[$0] ?? .null)) })
        }
    }

    static func from(canonical value: CanonicalJSON.Value) -> JSONValue {
        switch value {
        case .null: return .null
        case let .bool(flag): return .bool(flag)
        case let .int(number): return .int(number)
        case let .double(number): return number.isFinite ? .double(number) : .null
        case let .string(text): return .string(text)
        case let .array(items): return .array(items.map(from(canonical:)))
        case let .object(fields):
            return .object(fields.keys.sorted().map { ($0, from(canonical: fields[$0] ?? .null)) })
        }
    }

    static func from(wire value: WireValue) -> JSONValue {
        switch value {
        case .null: return .null
        case let .bool(flag): return .bool(flag)
        case let .int(number): return .int(number)
        case let .string(text): return .string(text)
        case let .object(object): return .object(object.pairs.map { ($0.0, from(wire: $0.1)) })
        case let .array(items): return .array(items.map(from(wire:)))
        }
    }

    static func from(wire object: WireObject) -> JSONValue {
        .object(object.pairs.map { ($0.0, from(wire: $0.1)) })
    }

    func canonical() -> CanonicalJSON.Value {
        switch self {
        case .null: return .null
        case let .bool(flag): return .bool(flag)
        case let .int(number): return .int(number)
        case let .double(number): return .double(number)
        case let .string(text): return .string(text)
        case let .array(items): return .array(items.map { $0.canonical() })
        case let .object(pairs):
            var fields: [String: CanonicalJSON.Value] = [:]
            for (key, value) in pairs { fields[key] = value.canonical() }
            return .object(fields)
        }
    }
}

enum JSONEncodeError: Error {
    case tooDeep
    case nonFinite
}

func jsonObject(from data: Data) -> [String: Any]? {
    guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
        return nil
    }
    return value as? [String: Any]
}

func jsonAny(from data: Data) -> Any? {
    try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}
