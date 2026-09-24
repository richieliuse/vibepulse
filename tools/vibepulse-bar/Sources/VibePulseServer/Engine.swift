import Foundation

public enum EngineStart: Sendable, Equatable {
    case started(port: Int)
    case portBusy
    case failed(String)
}

/// The in-process tokenserver. Routes read the latest JSON values the
/// engine publishes; the menu reads the same values.
public final class VibePulseEngine: @unchecked Sendable {
    public private(set) var port: Int
    public var tokensJSON: [String: Any] = ["v": 2]
    public var agentJSON: [String: Any] = ["v": 2, "seq": 0, "agents": [String: Any]()]
    public var trackerJSON: [String: Any] = ["v": 1, "enabled": false]
    public var githubJSON: [String: Any] = ["v": 1, "enabled": false]
    public var diagnosticsJSON: [String: Any] = [
        "service": "torget-tokenserver",
        "engine": "native",
    ]

    private let server: HTTPServer
    private var started = false

    public init(port: Int = 8737) {
        self.port = port
        let box = EngineBox()
        self.server = HTTPServer { method, path, headers in
            box.engine?.response(method: method, path: path, headers: headers) ?? HTTPResponse(status: 500, json: ["error": "stopped"])
        }
        box.engine = self
    }

    public func start() -> EngineStart {
        guard !self.started else { return .started(port: self.port) }
        if Self.isPortTaken(UInt16(self.port)) { return .portBusy }
        do {
            try self.server.start(port: UInt16(self.port))
            self.started = true
            return .started(port: self.port)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func stop() {
        self.server.stop()
        self.started = false
    }

    func response(method: String, path: String, headers: [String: String]) -> HTTPResponse {
        let route = path.split(separator: "?").first.map(String.init) ?? path
        guard method == "GET" else {
            return HTTPResponse(status: 404, json: ["error": "not found"])
        }
        switch route {
        case "/api/tokens":
            if self.isPlaceholder, !Self.acceptsUsageTotals(headers) {
                return HTTPResponse(status: 503, json: [
                    "error": "usage totals not measured yet",
                    "usageTotals": self.tokensJSON["usageTotals"] ?? ["placeholder": true],
                ])
            }
            return HTTPResponse(status: 200, json: self.tokensJSON)
        case "/api/agent-status":
            return HTTPResponse(status: 200, json: self.agentJSON)
        case "/api/max-tracker":
            return HTTPResponse(status: 200, json: self.trackerJSON)
        case "/api/github":
            return HTTPResponse(status: 200, json: self.githubJSON)
        case "/":
            return HTTPResponse(status: 200, json: self.diagnosticsJSON)
        default:
            return HTTPResponse(status: 404, json: ["error": "not found"])
        }
    }

    private var isPlaceholder: Bool {
        guard let totals = self.tokensJSON["usageTotals"] as? [String: Any] else { return false }
        return (totals["placeholder"] as? Bool) == true
    }

    private static func acceptsUsageTotals(_ headers: [String: String]) -> Bool {
        (headers["x-vibepulse-accepts"] ?? "").lowercased().contains("usage-totals")
    }

    private static func isPortTaken(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        return !bound
    }
}

private final class EngineBox: @unchecked Sendable {
    weak var engine: VibePulseEngine?
}
