import Foundation

/// Injected HTTP. Implementations must not follow redirects: a 3xx is a finished response.
public protocol QuotaHTTPTransport {
    func send(_ request: QuotaHTTPRequest) throws -> QuotaHTTPResponse
}

public struct QuotaHTTPRequest: Equatable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 15) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct QuotaHTTPResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

public struct QuotaHTTPResult {
    public var status: Int
    public var payload: [String: Any]?
    public var retryAfter: Int

    public init(status: Int, payload: [String: Any]?, retryAfter: Int) {
        self.status = status
        self.payload = payload
        self.retryAfter = retryAfter
    }
}

public enum QuotaHTTP {
    public static let maxBodyBytes = 1024 * 1024

    public static func retryAfterSeconds(_ value: String?, now: TimeInterval) -> Int {
        RetryAfter.seconds(value, now: now)
    }

    /// Shared JSON request used by Cursor and Grok. `status` is 0 when the connection failed
    /// or the body exceeds 1 MiB. A JSON value that is not an object yields a nil payload.
    public static func exchange(
        url: String,
        method: String = "GET",
        headers: [String: String],
        body: Data? = nil,
        timeout: TimeInterval = 15,
        now: TimeInterval = 0,
        transport: any QuotaHTTPTransport
    ) -> QuotaHTTPResult {
        let request = QuotaHTTPRequest(url: url, method: method, headers: headers, body: body, timeout: timeout)
        let response: QuotaHTTPResponse
        do {
            response = try transport.send(request)
        } catch {
            return QuotaHTTPResult(status: 0, payload: nil, retryAfter: 0)
        }
        if response.status >= 300 {
            let retry = retryAfterSeconds(response.header("Retry-After"), now: now)
            return QuotaHTTPResult(status: response.status, payload: nil, retryAfter: retry)
        }
        if response.body.count > maxBodyBytes {
            return QuotaHTTPResult(status: 0, payload: nil, retryAfter: 0)
        }
        let status = response.status == 0 ? 200 : response.status
        guard let payload = JSON.object(from: response.body) else {
            return QuotaHTTPResult(status: status, payload: nil, retryAfter: 0)
        }
        return QuotaHTTPResult(status: status, payload: payload, retryAfter: 0)
    }
}

/// Already-fetched `security` outcome. Tests pass this value; they do not spawn `security`.
public struct KeychainCommandResult: Equatable {
    public enum Failure: String, Equatable {
        case binaryMissing
        case timeout
        case spawnFailed
    }

    public var failure: Failure?
    public var spawnErrorName: String?
    public var exitCode: Int32?
    public var stdout: String

    public init(failure: Failure? = nil, spawnErrorName: String? = nil, exitCode: Int32? = nil, stdout: String = "") {
        self.failure = failure
        self.spawnErrorName = spawnErrorName
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

public protocol KeychainReading {
    func genericPassword(service: String) -> KeychainCommandResult
}

/// Already-fetched process listing. Tests pass command lines; they do not spawn `pgrep` or `ps`.
public protocol ProcessInspecting {
    func processIDs(matching pattern: String) -> [String]
    func commandLine(pid: String) -> String?
}

public protocol CursorStateReading {
    /// Raw `ItemTable.value` for `cursorAuth/accessToken`, or nil when the row/database is absent.
    func value(forKey key: String, inDatabase path: String) -> Data?
}
