//
//  GmailHTTPTransport.swift
//  MailConnectivity
//
//  Plan v4 V4-05: the HTTP seam of the Gmail connector. The adapter never
//  touches URLSession directly; it is handed a `GmailHTTPTransport` (the
//  deterministic Gmail simulator in tests, `URLSessionGmailTransport` in the
//  app). Rules every transport keeps:
//   • ONE request per call — no hidden retries (the sync engine retries,
//     asking the network policy each time).
//   • Redirects are NEVER followed: a 3xx comes back as the response, so a
//     bearer token can never travel to another host.
//   • The body is a stream of chunks as they arrive — never one whole buffer.
//

import Foundation

public struct GmailHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public init(method: String = "GET", url: URL, headers: [String: String] = [:]) {
        self.method = method; self.url = url; self.headers = headers
    }
}

/// A response body, chunk by chunk. `onConsumed` lets a transport apply
/// back-pressure (it learns how many bytes the reader has taken).
public struct GmailByteStream: AsyncSequence, Sendable {
    public typealias Element = Data
    let chunks: AsyncThrowingStream<Data, Error>
    let onConsumed: (@Sendable (Int) -> Void)?

    public init(_ chunks: AsyncThrowingStream<Data, Error>, onConsumed: (@Sendable (Int) -> Void)? = nil) {
        self.chunks = chunks; self.onConsumed = onConsumed
    }

    /// A finished stream carrying `data` in chunks of `chunkSize` bytes.
    public static func of(_ data: Data, chunkSize: Int = 64 * 1024) -> GmailByteStream {
        let size = Swift.max(1, chunkSize)
        return GmailByteStream(AsyncThrowingStream { continuation in
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        })
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<Data, Error>.AsyncIterator
        let onConsumed: (@Sendable (Int) -> Void)?
        public mutating func next() async throws -> Data? {
            let chunk = try await base.next()
            if let chunk { onConsumed?(chunk.count) }
            return chunk
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: chunks.makeAsyncIterator(), onConsumed: onConsumed)
    }
}

public struct GmailHTTPResponse: Sendable {
    public var status: Int
    /// Header names lower-cased.
    public var headers: [String: String]
    /// The URL the response actually came from (a transport that followed a
    /// redirect would show it here — the adapter refuses such a response).
    public var url: URL?
    public var body: GmailByteStream

    public init(status: Int, headers: [String: String] = [:], url: URL?, body: GmailByteStream) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.url = url; self.body = body
    }
}

public protocol GmailHTTPTransport: Sendable {
    /// Performs exactly one request; never follows a redirect.
    func send(_ request: GmailHTTPRequest) async throws -> GmailHTTPResponse
    /// Ends the transport's session; nothing is sent afterwards.
    func invalidate()
}

extension GmailHTTPTransport {
    public func invalidate() {}
}

// MARK: - URLSession transport (the app's)

/// The production transport: an ephemeral URLSession (no cookies, no cache)
/// whose delegate refuses every redirect and streams the body with
/// back-pressure (the download is suspended while more than `highWater`
/// bytes wait to be written to the staging file).
public final class URLSessionGmailTransport: NSObject, GmailHTTPTransport, URLSessionDataDelegate, @unchecked Sendable {
    private final class TaskState {
        let task: URLSessionDataTask
        var head: CheckedContinuation<GmailHTTPResponse, Error>?
        var stream: AsyncThrowingStream<Data, Error>.Continuation?
        var buffered = 0
        var suspended = false
        init(task: URLSessionDataTask, head: CheckedContinuation<GmailHTTPResponse, Error>) { self.task = task; self.head = head }
    }

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private var session: URLSession?
    let highWater: Int
    let lowWater: Int
    private var refused = 0
    /// Redirects refused so far (diagnostics, tests).
    public var refusedRedirects: Int { lock.withLock { refused } }

    public init(configuration: URLSessionConfiguration = .ephemeral, highWater: Int = 8 << 20, lowWater: Int = 2 << 20) {
        self.highWater = highWater; self.lowWater = lowWater
        super.init()
        let config = configuration
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Ends the session (the session retains its delegate until then).
    public func invalidate() { session?.invalidateAndCancel(); session = nil }

    public func send(_ request: GmailHTTPRequest) async throws -> GmailHTTPResponse {
        guard let session else { throw URLError(.cancelled) }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: urlRequest)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GmailHTTPResponse, Error>) in
                lock.withLock { states[task.taskIdentifier] = TaskState(task: task, head: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func consumed(_ taskID: Int, _ count: Int) {
        lock.withLock {
            guard let state = states[taskID] else { return }
            state.buffered -= count
            if state.suspended, state.buffered < lowWater { state.suspended = false; state.task.resume() }
        }
    }

    // MARK: URLSession delegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never follow: the 3xx itself becomes the response.
        lock.withLock { refused += 1 }
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskIdentifier
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.onTermination = { [weak dataTask] termination in
            if case .cancelled = termination { dataTask?.cancel() }
        }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        let body = GmailByteStream(stream, onConsumed: { [weak self] count in self?.consumed(id, count) })
        let result = GmailHTTPResponse(status: http?.statusCode ?? 0, headers: headers, url: response.url, body: body)
        let head: CheckedContinuation<GmailHTTPResponse, Error>? = lock.withLock {
            guard let state = states[id] else { return nil }
            state.stream = continuation
            defer { state.head = nil }
            return state.head
        }
        completionHandler(.allow)
        head?.resume(returning: result)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard let state = states[dataTask.taskIdentifier] else { return }
            state.stream?.yield(data)
            state.buffered += data.count
            if !state.suspended, state.buffered > highWater { state.suspended = true; dataTask.suspend() }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state = lock.withLock { states.removeValue(forKey: task.taskIdentifier) }
        guard let state else { return }
        if let head = state.head {
            head.resume(throwing: error ?? URLError(.badServerResponse))
        } else if let error {
            state.stream?.finish(throwing: error)
        } else {
            state.stream?.finish()
        }
    }
}
