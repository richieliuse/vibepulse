import Foundation

/// Loopback reads of the tokenserver. Loopback clients are never counted as
/// the panel (`_record_panel_poll`), so polling from here cannot make a dead
/// panel look alive in the service's own diagnostics.
public struct TokenServerClient: Sendable {
    public enum FetchError: Error, Equatable, LocalizedError {
        case unreachable(String)
        case http(Int)
        case undecodable

        public var errorDescription: String? {
            switch self {
            case let .unreachable(reason): "Not reachable: \(reason)"
            case let .http(code): "HTTP \(code)"
            case .undecodable: "Unexpected response"
            }
        }
    }

    public let port: Int
    private let session: URLSession

    public init(port: Int, timeout: TimeInterval = 4) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration)
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(self.port)")! }

    public func diagnostics() async throws -> ServerDiagnostics {
        let data = try await self.get("/")
        guard let diagnostics = ServerDiagnostics(data: data) else { throw FetchError.undecodable }
        return diagnostics
    }

    public func tokens() async throws -> TokensSnapshot {
        let data = try await self.get("/api/tokens")
        guard let tokens = TokensSnapshot(data: data) else { throw FetchError.undecodable }
        return tokens
    }

    public func agentStatus() async throws -> AgentStatusSnapshot {
        let data = try await self.get("/api/agent-status")
        guard let status = AgentStatusSnapshot(data: data) else { throw FetchError.undecodable }
        return status
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: self.baseURL.appendingPathComponent(path == "/" ? "" : path))
        // Without this, a warming-up service answers 503 instead of a
        // labelled placeholder (lesson 2026-09-10); with it, placeholders
        // arrive marked `usageTotals.placeholder` and are shown as such.
        request.setValue("usage-totals", forHTTPHeaderField: "X-VibePulse-Accepts")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw FetchError.unreachable((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FetchError.undecodable }
        guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
        return data
    }
}
