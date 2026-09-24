import Darwin
import Foundation
import Network

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, json: Any) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }
}

/// One-shot HTTP/1.1 listener. Every response carries Content-Length.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String, String, [String: String]) -> HTTPResponse

    private let queue = DispatchQueue(label: "se.torget.vibepulse.http")
    private var listener: NWListener?
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        listener.start(queue: self.queue)
        self.listener = listener
    }

    public func stop() {
        self.listener?.cancel()
        self.listener = nil
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: self.queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let response = self.respond(text)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func respond(_ request: String) -> Data {
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let response = self.handler(method, path, headers)
        let reason = response.status == 200 ? "OK" : (response.status == 503 ? "Service Unavailable" : "Error")
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }
}
