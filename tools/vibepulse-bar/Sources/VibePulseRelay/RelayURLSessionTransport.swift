import Foundation

/// Ephemeral `URLSession` transport for the interaction relay.
///
/// No cache and no cookies. `timeoutIntervalForRequest` is the read timeout
/// and `timeoutIntervalForResource` is connect + read. A 3xx is an error:
/// the task delegate passes `nil` so `Location` is not requested. The body
/// is capped at 4096 bytes while it streams.
public final class RelayURLSessionTransport: @unchecked Sendable {
    private let session: URLSession
    private let bridge: RelayResponseBridge
    private let delegateQueue: OperationQueue

    public init(configuration: URLSessionConfiguration = RelayURLSessionTransport.ephemeralConfiguration()) {
        let configuration = Self.secured(configuration)
        let bridge = RelayResponseBridge()
        let queue = OperationQueue()
        queue.name = "vibepulse-relay-transport"
        queue.maxConcurrentOperationCount = 1
        self.bridge = bridge
        self.delegateQueue = queue
        self.session = URLSession(configuration: configuration, delegate: bridge, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Ephemeral configuration: memory only, no cache, no cookies.
    /// Pass the result to `init` after setting `protocolClasses` in tests.
    public static func ephemeralConfiguration(
        connectTimeout: TimeInterval = InteractionRelayLimits.defaultConnectTimeout,
        readTimeout: TimeInterval = InteractionRelayLimits.defaultReadTimeout
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = readTimeout
        configuration.timeoutIntervalForResource = connectTimeout + readTimeout
        return Self.secured(configuration)
    }

    public func send(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse {
        let urlRequest = try Self.urlRequest(request)
        return try bridge.perform(urlRequest, session: session)
    }

    private static func secured(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let protocols = configuration.protocolClasses
        let requestTimeout = configuration.timeoutIntervalForRequest
        let resourceTimeout = configuration.timeoutIntervalForResource
        let copy = (configuration.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        copy.protocolClasses = protocols
        copy.timeoutIntervalForRequest = requestTimeout
        copy.timeoutIntervalForResource = resourceTimeout
        copy.urlCache = nil
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.httpCookieAcceptPolicy = .never
        copy.urlCredentialStorage = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.waitsForConnectivity = false
        return copy
    }

    private static func urlRequest(_ request: RelayHTTPRequest) throws -> URLRequest {
        guard let components = URLComponents(string: request.url),
              let url = components.url,
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              (components.query ?? "").isEmpty,
              (components.fragment ?? "").isEmpty else {
            throw RelayAdapterError(message: "invalid relay request URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.readTimeout
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        if !request.body.isEmpty {
            urlRequest.httpBody = request.body
        }
        for (name, value) in request.headers {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }
}

final class RelayResponseBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var loads: [ObjectIdentifier: LoadState] = [:]

    func perform(_ request: URLRequest, session: URLSession) throws -> RelayHTTPResponse {
        let state = LoadState()
        let task = session.dataTask(with: request)
        let key = ObjectIdentifier(task)
        lock.lock()
        loads[key] = state
        lock.unlock()
        task.resume()
        state.finished.wait()
        lock.lock()
        loads[key] = nil
        lock.unlock()
        if state.redirect {
            throw RelayAdapterError(message: "relay redirect refused")
        }
        if state.tooLarge {
            throw RelayAdapterError(message: "relay response too large")
        }
        if let failure = state.failure {
            throw failure
        }
        guard let status = state.status else {
            throw RelayAdapterError(message: "invalid HTTP response")
        }
        return RelayHTTPResponse(status: status, headers: state.headers, body: state.body)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let state = loadState(for: dataTask)
        if let http = response as? HTTPURLResponse {
            state?.status = http.statusCode
            state?.headers = headerPairs(http)
            if (300..<400).contains(http.statusCode) {
                state?.redirect = true
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = loadState(for: dataTask), !state.redirect, !state.tooLarge else { return }
        if state.body.count + data.count > InteractionRelayLimits.maxResponseBytes {
            state.tooLarge = true
            dataTask.cancel()
            return
        }
        state.body.append(data)
    }

    /// `nil` refuses the redirect. URLSession must not send `newRequest`.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let state = loadState(for: task)
        state?.redirect = true
        state?.status = response.statusCode
        state?.headers = headerPairs(response)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = loadState(for: task) else { return }
        if state.status == nil, let http = task.response as? HTTPURLResponse {
            state.status = http.statusCode
            state.headers = headerPairs(http)
        }
        if let status = state.status, (300..<400).contains(status) {
            state.redirect = true
        }
        if state.body.count > InteractionRelayLimits.maxResponseBytes {
            state.tooLarge = true
        }
        state.failure = error
        state.finish()
    }

    private func loadState(for task: URLSessionTask) -> LoadState? {
        lock.lock()
        defer { lock.unlock() }
        return loads[ObjectIdentifier(task)]
    }

    private func headerPairs(_ response: HTTPURLResponse) -> [(String, String)] {
        response.allHeaderFields.map { key, value in
            let name = key as? String ?? String(describing: key)
            let header = value as? String ?? String(describing: value)
            return (name, header)
        }
    }
}

private final class LoadState: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    var body = Data()
    var status: Int?
    var headers: [(String, String)] = []
    var failure: Error?
    var tooLarge = false
    var redirect = false
    private var didSignal = false

    func finish() {
        if didSignal { return }
        didSignal = true
        finished.signal()
    }
}
