import Darwin
import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var headerLists: [String: [String]]
    public var body: Data
    public var bodyComplete: Bool
    public var advertisedLength: Int
    public var peer: String
    public var isAlive: @Sendable () -> Bool = { true }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public func headerValues(_ name: String) -> [String] {
        headerLists[name.lowercased()] ?? []
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String?

    public init(status: Int, json: Any) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        self.contentType = "application/json"
    }

    public init(status: Int, body: Data, contentType: String?) {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    static func json(_ status: Int, _ value: JSONValue) -> HTTPResponse {
        let body = (try? value.encode()) ?? Data("{\"error\":\"internal server error\"}".utf8)
        return HTTPResponse(status: status, body: body, contentType: "application/json")
    }

    public static func emptyOK() -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(), contentType: nil)
    }
}

/// One IPv4 listener on `0.0.0.0`. Each accepted connection is one thread.
/// Above `connectionCap` the headers are drained and the answer is an empty 503.
public final class HTTPServer: @unchecked Sendable {
    public static let headerDrainLimit = 8 * 1024
    public static let bodyDrainLimit = 65_536
    public static let busyDrainSeconds: TimeInterval = 0.05
    public static let headerReadSeconds: TimeInterval = 5
    public static let bodyReadSeconds: TimeInterval = 2

    public typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse

    private let handler: Handler
    private let connectionCap: Int
    private let listenerQueue = DispatchQueue(label: "se.torget.vibepulse.http.listen")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var inFlight = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(connectionCap: Int = 32, handler: @escaping Handler) {
        self.connectionCap = max(1, connectionCap)
        self.handler = handler
    }

    /// Binds `0.0.0.0`. `port` 0 asks the kernel for an ephemeral port.
    /// The returned port is the one the listener actually opened.
    public func start(port: UInt16) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let internet = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            internet.version = .v4
        }
        let requested: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters, on: requested)
        let ready = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case let .failed(error):
                failure.error = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.admit(connection)
        }
        listener.start(queue: listenerQueue)
        guard ready.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = failure.error {
            listener.cancel()
            throw error
        }
        guard let actual = listener.port else {
            listener.cancel()
            throw POSIXError(.EADDRNOTAVAIL)
        }
        stateLock.lock()
        self.listener = listener
        stateLock.unlock()
        return actual.rawValue
    }

    public func stop() {
        stateLock.lock()
        let listener = self.listener
        self.listener = nil
        let open = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        listener?.cancel()
        for connection in open {
            connection.cancel()
        }
    }

    private func admit(_ connection: NWConnection) {
        stateLock.lock()
        let allowed = inFlight < connectionCap
        if allowed { inFlight += 1 }
        connections[ObjectIdentifier(connection)] = connection
        stateLock.unlock()
        Thread.detachNewThread { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            if !allowed {
                self.rejectBusy(connection)
                self.forget(connection)
                return
            }
            defer { self.release(connection) }
            self.serve(connection)
        }
    }

    private func release(_ connection: NWConnection) {
        stateLock.lock()
        inFlight = max(0, inFlight - 1)
        connections.removeValue(forKey: ObjectIdentifier(connection))
        stateLock.unlock()
        connection.cancel()
    }

    private func forget(_ connection: NWConnection) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        stateLock.unlock()
        connection.cancel()
    }

    private func rejectBusy(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "se.torget.vibepulse.http.busy")
        connection.start(queue: queue)
        let pull = Pull(connection)
        let deadline = Date().addingTimeInterval(Self.busyDrainSeconds)
        _ = pull.readUntilHeader(limit: Self.headerDrainLimit, deadline: deadline)
        let bytes = Data(Self.busyResponse.utf8)
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: bytes, completion: .contentProcessed { _ in
            sent.signal()
        })
        _ = sent.wait(timeout: .now() + 0.2)
    }

    private func serve(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "se.torget.vibepulse.http.conn")
        let alive = AliveFlag()
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                alive.value = false
            default:
                break
            }
        }
        connection.start(queue: queue)
        let pull = Pull(connection)
        let headerDeadline = Date().addingTimeInterval(Self.headerReadSeconds)
        guard let header = pull.readUntilHeader(limit: Self.bodyDrainLimit, deadline: headerDeadline),
              let requestLine = parseRequest(header, peer: peerAddress(connection), pull: pull, isAlive: { alive.value })
        else {
            send(HTTPResponse(status: 400, body: Data("{\"error\":\"bad request\"}".utf8), contentType: "application/json"), on: connection)
            return
        }
        let response = handler(requestLine)
        send(response, on: connection)
    }

    private func parseRequest(_ head: String, peer: String, pull: Pull, isAlive: @escaping @Sendable () -> Bool) -> HTTPRequest? {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]
        var lists: [String: [String]] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            lists[name, default: []].append(value)
        }
        var firstHeaders: [String: String] = [:]
        for (name, values) in lists {
            firstHeaders[name] = values.first
        }
        let advertised = Self.contentLength(firstHeaders["content-length"])
        let toRead = min(max(0, advertised), Self.bodyDrainLimit)
        let body: Data
        if toRead == 0 {
            body = Data()
        } else {
            let deadline = Date().addingTimeInterval(Self.bodyReadSeconds)
            body = pull.read(count: toRead, deadline: deadline) ?? Data()
        }
        let complete = body.count == advertised && advertised <= Self.bodyDrainLimit
        return HTTPRequest(
            method: method,
            path: path,
            headers: firstHeaders,
            headerLists: lists,
            body: body,
            bodyComplete: complete || advertised == 0,
            advertisedLength: max(0, advertised),
            peer: peer,
            isAlive: isAlive
        )
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.0 \(response.status) \(reason(response.status))\r\n"
        if let contentType = response.contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n\r\n"
        var bytes = Data(head.utf8)
        bytes.append(response.body)
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: bytes, completion: .contentProcessed { _ in
            sent.signal()
        })
        _ = sent.wait(timeout: .now() + 2)
    }

    private func peerAddress(_ connection: NWConnection) -> String {
        guard case let .hostPort(host, _) = connection.endpoint else { return "" }
        let text = "\(host)"
        if let zone = text.firstIndex(of: "%") {
            return String(text[..<zone])
        }
        return text
    }

    private static func contentLength(_ value: String?) -> Int {
        guard let value, let number = Int(value), number >= 0 else { return 0 }
        return number
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    private static let busyResponse = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
}

private final class FailureBox: @unchecked Sendable {
    var error: Error?
}

private final class Pull: @unchecked Sendable {
    let connection: NWConnection
    var buffer = Data()

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func readUntilHeader(limit: Int, deadline: Date) -> String? {
        let marker = Data("\r\n\r\n".utf8)
        while Date() < deadline && buffer.count < limit {
            if let range = buffer.range(of: marker) {
                let split = range.upperBound
                let head = buffer.prefix(upTo: split)
                let rest = Data(buffer.suffix(from: split))
                guard let text = String(data: head, encoding: .utf8) else { return nil }
                buffer = rest
                return text
            }
            guard let chunk = once(deadline: deadline), !chunk.isEmpty else { break }
            let room = limit - buffer.count
            buffer.append(chunk.prefix(room))
        }
        guard let range = buffer.range(of: marker) else { return nil }
        let split = range.upperBound
        let head = buffer.prefix(upTo: split)
        let rest = Data(buffer.suffix(from: split))
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        buffer = rest
        return text
    }

    func read(count: Int, deadline: Date) -> Data? {
        while buffer.count < count && Date() < deadline {
            guard let chunk = once(deadline: deadline) else { return Data(buffer.prefix(count)) }
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let taken = Data(buffer.prefix(count))
        buffer.removeFirst(min(count, buffer.count))
        return taken
    }

    private func once(deadline: Date) -> Data? {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return nil }
        let box = ReceiveBox()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
            box.data = data ?? Data()
            box.eof = error != nil || (complete && (data?.isEmpty ?? true))
            box.semaphore.signal()
        }
        if box.semaphore.wait(timeout: .now() + remaining) == .timedOut {
            connection.cancel()
            _ = box.semaphore.wait(timeout: .now() + 0.2)
            return nil
        }
        if box.eof && box.data.isEmpty { return Data() }
        return box.data
    }
}

private final class AliveFlag: @unchecked Sendable {
    var value = true
}

private final class ReceiveBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var data = Data()
    var eof = false
}
