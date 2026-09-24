import Foundation

/// Turns the engine's in-memory JSON into the menu's value types.
/// The menu never fetches these over HTTP.
public enum MenuReading {
    public static func tokens(_ json: [String: Any]) -> TokensSnapshot? {
        guard let data = plistData(json) else { return nil }
        return TokensSnapshot(data: data)
    }

    public static func agents(_ json: [String: Any]) -> AgentStatusSnapshot? {
        guard let data = plistData(json) else { return nil }
        return AgentStatusSnapshot(data: data)
    }

    public static func diagnostics(_ json: [String: Any]) -> ServerDiagnostics? {
        guard let data = plistData(json) else { return nil }
        return ServerDiagnostics(data: data)
    }

    private static func plistData(_ json: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(json) else { return nil }
        return try? JSONSerialization.data(withJSONObject: json)
    }
}
