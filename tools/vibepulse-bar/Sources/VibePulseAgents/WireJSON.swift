import Foundation

/// Ordered JSON value. Key order follows insertion, matching the agent-status wire.
public enum WireValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case object(WireObject)
    case array([WireValue])
}

extension WireValue: Equatable {
    public static func == (lhs: WireValue, rhs: WireValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(left), .bool(right)): return left == right
        case let (.int(left), .int(right)): return left == right
        case let (.string(left), .string(right)): return left == right
        case let (.object(left), .object(right)): return left == right
        case let (.array(left), .array(right)): return left == right
        default: return false
        }
    }
}

public struct WireObject: Sendable {
    public private(set) var pairs: [(String, WireValue)]

    public init(_ pairs: [(String, WireValue)]) {
        self.pairs = pairs
    }

    public func value(_ key: String) -> WireValue? {
        self.pairs.first { $0.0 == key }?.1
    }

    public func object(_ key: String) -> WireObject? {
        if case let .object(value) = self.value(key) { return value }
        return nil
    }

    public func string(_ key: String) -> String? {
        if case let .string(value) = self.value(key) { return value }
        return nil
    }

    public func int(_ key: String) -> Int? {
        if case let .int(value) = self.value(key) { return value }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        if case let .bool(value) = self.value(key) { return value }
        return nil
    }

    public func array(_ key: String) -> [WireValue]? {
        if case let .array(value) = self.value(key) { return value }
        return nil
    }
}

extension WireObject: Equatable {
    public static func == (lhs: WireObject, rhs: WireObject) -> Bool {
        guard lhs.pairs.count == rhs.pairs.count else { return false }
        for (left, right) in zip(lhs.pairs, rhs.pairs) {
            if left.0 != right.0 || left.1 != right.1 { return false }
        }
        return true
    }
}

extension WireObject: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        for (key, value) in self.pairs {
            let codingKey = WireKey(key)
            if case .null = value {
                try container.encodeNil(forKey: codingKey)
            } else {
                try container.encode(value, forKey: codingKey)
            }
        }
    }
}

extension WireValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .int(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .object(value):
            try value.encode(to: encoder)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                if case .null = value {
                    try container.encodeNil()
                } else {
                    try container.encode(value)
                }
            }
        }
    }
}

struct WireKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
