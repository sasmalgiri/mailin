//
//  GraphTransport.swift
//  MailConnectivity
//
//  Plan v4 V4-06: the HTTP seam of the Microsoft Graph connector. The
//  adapter never touches URLSession directly: it hands one GET at a time to
//  an injected `GraphHTTPTransport` (a deterministic Graph simulator in the
//  tests, `URLSessionGraphTransport` in the app). The transport
//   • NEVER follows redirects — a 3xx comes back as the response, so the
//     adapter decides whether the next host may see the bearer token;
//   • streams the body chunk by chunk (MIME from `/$value` is written to the
//     `RawByteSink` as it arrives, never buffered whole);
//   • keeps no cookies, cache or credentials of its own.
//

import Foundation

public struct GraphHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]

    public init(method: String = "GET", url: URL, headers: [String: String]) {
        self.method = method; self.url = url; self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct GraphHTTPResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    /// The body, in the chunks the network delivered.
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// A JSON page or error body. `guardBytes` protects against a malformed
    /// endless response; it is not a mailbox limit (a Graph page of 1,000
    /// message references is well under 1 MiB).
    public func collect(guardBytes: Int = 64 << 20) async throws -> Data {
        var out = Data()
        for try await chunk in body {
            out.append(chunk)
            if out.count > guardBytes {
                throw MailProviderError.permanent("Microsoft Graph sent a JSON response larger than \(guardBytes >> 20) MiB.")
            }
        }
        return out
    }
}

public protocol GraphHTTPTransport: Sendable {
    /// Sends one request. MUST NOT follow redirects (return the 3xx as is)
    /// and MUST NOT add credentials of its own.
    func send(_ request: GraphHTTPRequest) async throws -> GraphHTTPResponse
}

// MARK: - URLSession

/// The app's transport: an ephemeral session (no cookies, no URL cache), a
/// delegate that refuses every redirect, and the body streamed as delivered.
/// The network-policy check happens in the adapter before each `send`.
public final class URLSessionGraphTransport: NSObject, GraphHTTPTransport, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var response: CheckedContinuation<GraphHTTPResponse, Error>?
        var body: AsyncThrowingStream<Data, Error>.Continuation
        var stream: AsyncThrowingStream<Data, Error>
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession?

    public init(timeout: TimeInterval = 120) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session?.invalidateAndCancel() }

    public func send(_ request: GraphHTTPRequest) async throws -> GraphHTTPResponse {
        guard let session else { throw MailProviderError.transient("the network session is closed") }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: urlRequest)
        let id = task.taskIdentifier
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (response: CheckedContinuation<GraphHTTPResponse, Error>) in
                lock.withLock { pending[id] = Pending(response: response, body: continuation, stream: stream) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // Redirects are never followed: the 3xx is delivered to the adapter.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] { headers["\(key)".lowercased()] = "\(value)" }
        let entry: (CheckedContinuation<GraphHTTPResponse, Error>, AsyncThrowingStream<Data, Error>)? = lock.withLock {
            guard var p = pending[dataTask.taskIdentifier], let waiting = p.response else { return nil }
            p.response = nil
            pending[dataTask.taskIdentifier] = p
            return (waiting, p.stream)
        }
        if let (waiting, stream) = entry {
            waiting.resume(returning: GraphHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: stream))
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let body = lock.withLock { pending[dataTask.taskIdentifier]?.body }
        body?.yield(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let entry = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        guard let entry else { return }
        if let waiting = entry.response {
            waiting.resume(throwing: error ?? MailProviderError.transient("the connection closed without a response"))
        }
        if let error { entry.body.finish(throwing: error) } else { entry.body.finish() }
    }
}
