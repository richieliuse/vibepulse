import Foundation

/// Lenient, typed reads over a decoded JSON object.
///
/// The tokenserver contract is additive and uses `null` for honest absence,
/// so one unexpected field must never discard the whole payload. Every
/// accessor returns `nil` on a missing key, a `null`, or a type mismatch.
struct JSONReader {
    let object: [String: Any]

    init(_ object: [String: Any]) {
        self.object = object
    }

    init?(data: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else { return nil }
        self.object = object
    }

    func double(_ key: String) -> Double? {
        guard let number = self.object[key] as? NSNumber, !Self.isBool(number) else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    func int(_ key: String) -> Int? {
        guard let value = self.double(key), value >= Double(Int.min), value <= Double(Int.max) else {
            return nil
        }
        return Int(value.rounded())
    }

    func bool(_ key: String) -> Bool? {
        guard let number = self.object[key] as? NSNumber, Self.isBool(number) else { return nil }
        return number.boolValue
    }

    func string(_ key: String) -> String? {
        self.object[key] as? String
    }

    func reader(_ key: String) -> JSONReader? {
        (self.object[key] as? [String: Any]).map(JSONReader.init)
    }

    func array(_ key: String) -> [Any]? {
        self.object[key] as? [Any]
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
