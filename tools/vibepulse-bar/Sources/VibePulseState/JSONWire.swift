import Foundation
import VibePulseSupport

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
        case let (.array(left), .array(right)): return left == right
        case let (.object(left), .object(right)):
            guard left.count == right.count else { return false }
            for index in left.indices {
                if left[index].0 != right[index].0 || left[index].1 != right[index].1 { return false }
            }
            return true
        default: return false
        }
    }

    var strict: StrictJSON.Value {
        switch self {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .int(value): return .int(value)
        case let .double(value): return .double(value)
        case let .string(value): return .string(value)
        case let .array(values): return .array(values.map(\.strict))
        case let .object(pairs):
            var object: [String: StrictJSON.Value] = [:]
            for (key, value) in pairs { object[key] = value.strict }
            return .object(object)
        }
    }
}

enum JSONWire {
    static func encode(_ value: JSONValue, asciiOnly: Bool = false) -> Data {
        var text = ""
        write(value, into: &text, asciiOnly: asciiOnly)
        text.append("\n")
        return Data(text.utf8)
    }

    static func number(_ value: Double, forceFloat: Bool) -> JSONValue {
        if !forceFloat, let integer = integral(value) { return .int(integer) }
        return .double(value)
    }

    static func integral(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < Double(Int.max) else { return nil }
        let truncated = value.rounded(.towardZero)
        guard truncated == value else { return nil }
        return Int(truncated)
    }

    private static func write(_ value: JSONValue, into text: inout String, asciiOnly: Bool) {
        switch value {
        case .null: text += "null"
        case let .bool(flag): text += flag ? "true" : "false"
        case let .int(number): text += String(number)
        case let .double(number): text += floatLiteral(number)
        case let .string(string): text += quoted(string, asciiOnly: asciiOnly)
        case let .array(items):
            text += "["
            for (index, item) in items.enumerated() {
                if index > 0 { text += "," }
                write(item, into: &text, asciiOnly: asciiOnly)
            }
            text += "]"
        case let .object(pairs):
            text += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { text += "," }
                text += quoted(pair.0, asciiOnly: asciiOnly)
                text += ":"
                write(pair.1, into: &text, asciiOnly: asciiOnly)
            }
            text += "}"
        }
    }

    /// Shortest round-trip literal. Whole floats keep a decimal point (`46.0`).
    static func floatLiteral(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == .infinity { return "Infinity" }
        if value == -.infinity { return "-Infinity" }
        var literal = String(value)
        if !literal.contains("."), !literal.contains("e"), !literal.contains("E") {
            literal += ".0"
        }
        return literal
    }

    static func quoted(_ string: String, asciiOnly: Bool) -> String {
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
            case 0x00...0x1F:
                out += String(format: "\\u%04x", scalar.value)
            default:
                if asciiOnly && scalar.value > 0x7E {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

enum PyRound {
    /// `round(x)` / `int(round(x))`: ties to even.
    static func integer(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrEven))
    }

    /// `round(x, n)` on the exact binary value, ties to even.
    static func places(_ value: Double, _ digits: Int) -> Double {
        let literal = String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
        return Double(literal) ?? value
    }
}

enum StateRead {
    case missing
    case data(Data)
    case notUTF8
    case unreadable(String)
}

enum StateIO {
    static func read(_ url: URL) -> StateRead {
        do {
            let data = try Data(contentsOf: url)
            guard String(bytes: data, encoding: .utf8) != nil else { return .notUTF8 }
            return .data(data)
        } catch let error as NSError {
            if isMissing(error) { return .missing }
            return .unreadable(errorName(error))
        }
    }

    static func isMissing(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return true }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXError.ENOENT.rawValue) { return true }
        return false
    }

    static func errorName(_ error: NSError) -> String {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            return "PermissionError"
        }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXError.EACCES.rawValue) {
            return "PermissionError"
        }
        return "OSError"
    }

    static func parseObject(_ data: Data) -> StrictJSON.Value? {
        guard case let .success(value) = StrictJSON.parse(data) else { return nil }
        return value
    }
}

public struct StatePersistenceError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}
