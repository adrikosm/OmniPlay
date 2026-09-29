import Diagnostics
import Foundation
import Network

/// Bounded loopback HTTP/1.1 server: GET/HEAD, POST for the routes a router registers, keep-alive, at most
/// `maxConnections` concurrent connections (extra get a 503), 30 s idle timeout, streamed file bodies. Binds
/// `127.0.0.1` literally, never a LAN address.
public actor HTTPServer {
    public static let maxConnections = 16
    public static let idleTimeout: Duration = .seconds(30)
    public static let chunk = 256 << 10

    public let router: any Router
    public private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var idCounter = 0
    /// False once the listener failed or was cancelled (sockets are torn down while the app is suspended).
    public var isListening: Bool { listener != nil }

    public init(router: any Router) { self.router = router }

    /// Binds the requested port, or a random one in 20000…60000 when nil or taken. Returns the bound port.
    @discardableResult
    public func start(port requested: UInt16? = nil) async throws -> UInt16 {
        var attempts = 0
        var candidate = requested ?? UInt16.random(in: 20000 ... 60000)
        while true {
            do {
                try await bind(candidate)
                port = candidate
                OPLog.log(.web, .info, "loopback server listening on 127.0.0.1:\(candidate)")
                return candidate
            } catch {
                attempts += 1
                if attempts >= 10 {
                    throw error
                }
                OPLog.log(.web, .default, "port \(candidate) unavailable (\(error)); choosing another")
                candidate = UInt16.random(in: 20000 ... 60000)
            }
        }
    }

    /// After the app returns to the foreground: rebinds the remembered port when the listener died, else no-op.
    /// Returns the port now serving, which changes only if the old one is taken.
    @discardableResult
    public func restartIfNeeded() async throws -> UInt16 {
        if isListening {
            return port
        }
        for c in connections.values {
            c.cancel()
        }
        connections.removeAll()
        let restarted = try await start(port: port == 0 ? nil : port)
        if restarted != port {
            OPLog.log(.web, .default, "loopback port changed on restart: \(port) → \(restarted)")
        }
        return restarted
    }

    private func listenerWentDown(_ listener: NWListener) {
        guard self.listener === listener else { return }
        self.listener = nil
        // A failed listener keeps its socket until cancelled.
        listener.cancel()
        OPLog.log(.web, .default, "loopback listener went down")
    }

    private func bind(_ port: UInt16) async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        do {
            try await ready(listener)
        } catch {
            // A listener that never became ready must not read as listening, or `restartIfNeeded` never rebinds.
            listener.cancel()
            if self.listener === listener {
                self.listener = nil
            }
            throw error
        }
    }

    private func ready(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready: if !resumed.withLock({ let r = $0; $0 = true; return r }) {
                        cont.resume()
                    }
                case let .failed(error):
                    if !resumed.withLock({ let r = $0; $0 = true; return r }) {
                        cont.resume(throwing: error)
                    } else if let self, let listener {
                        Task { await self.listenerWentDown(listener) }
                    }
                case .cancelled:
                    if !resumed.withLock({ let r = $0; $0 = true; return r }) {
                        cont.resume(throwing: CancellationError())
                    } else if let self, let listener {
                        Task { await self.listenerWentDown(listener) }
                    }
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values {
            c.cancel()
        }
        connections.removeAll()
        OPLog.log(.web, .info, "loopback server stopped")
    }

    public var activeConnections: Int { connections.count }

    private func accept(_ nw: NWConnection) {
        guard connections.count < Self.maxConnections else {
            let refused = HTTPConnection(nw, router: router) { _ in }
            refused.refuseBusy()
            return
        }
        let connection = HTTPConnection(nw, router: router) { [weak self] id in Task { await self?.forget(id) } }
        connections[ObjectIdentifier(connection)] = connection
        connection.run()
    }

    private func forget(_ id: ObjectIdentifier) { connections[id] = nil }
}

import Synchronization

/// One client connection: parse → route → write, repeated while keep-alive holds.
final class HTTPConnection: Sendable {
    private let nw: NWConnection
    private let router: any Router
    private let onClose: @Sendable (ObjectIdentifier) -> Void
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ nw: NWConnection, router: any Router, onClose: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.nw = nw
        self.router = router
        self.onClose = onClose
    }

    func run() {
        let t = Task { [self] in
            nw.start(queue: .global(qos: .userInitiated))
            defer { nw.cancel(); onClose(ObjectIdentifier(self)) }
            var buffer = Data()
            do {
                while !Task.isCancelled {
                    var request: HTTPRequest
                    let consumed: Int
                    do {
                        (request, consumed) = try HTTPRequestParser.parse(buffer)
                    } catch HTTPParseError.incomplete {
                        guard let more = try await receive() else { return }
                        buffer.append(more)
                        if buffer.count > 64 << 10 {
                            try await write(.text(431, "request too large"), head: false); return
                        }
                        continue
                    } catch HTTPParseError.headersTooLarge {
                        try await write(.text(431, "request header fields too large"), head: false); return
                    } catch HTTPParseError.bodyTooLarge {
                        try await write(.text(413, "request body too large"), head: false); return
                    } catch {
                        try await write(.text(400, "bad request"), head: false); return
                    }
                    buffer.removeFirst(consumed)
                    if request.method == "POST" {
                        let length = request.contentLength
                        while buffer.count < length {
                            guard let more = try await receive() else { return }
                            buffer.append(more)
                        }
                        request.body = Data(buffer.prefix(length))
                        buffer.removeFirst(length)
                    }
                    var response: HTTPResponse
                    if request.method == "GET" || request.method == "HEAD" {
                        response = await router.route(request)
                    } else if request.method == "POST" {
                        response = await router.post(request)
                    } else {
                        response = .text(405, "method not allowed")
                        response.headers.append(("Allow", "GET, HEAD"))
                    }
                    let keepAlive = request.keepAlive && response.status != 400
                    response.headers.append(("Connection", keepAlive ? "keep-alive" : "close"))
                    try await write(response, head: request.method == "HEAD")
                    if !keepAlive {
                        return
                    }
                }
            } catch {
                OPLog.log(.web, .debug, "connection closed: \(error)")
            }
        }
        task.withLock { $0 = t }
    }

    func refuseBusy() {
        let reply = Task { [self] in
            nw.start(queue: .global(qos: .userInitiated))
            var r = HTTPResponse.text(503, "too many connections")
            r.headers.append(("Connection", "close"))
            try? await write(r, head: false)
            nw.cancel()
        }
        // A client that never reads would otherwise hold the refused socket and this task forever.
        Task { [nw] in
            try? await Task.sleep(for: .seconds(5))
            reply.cancel()
            nw.cancel()
        }
    }

    func cancel() {
        task.withLock { $0?.cancel() }
        nw.cancel()
    }

    // MARK: I/O

    private func receive() async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { [nw] in
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, complete, error in
                            if let error {
                                cont.resume(throwing: error)
                            } else if complete,
                                      data == nil {
                                cont.resume(returning: nil)
                            } else {
                                cont.resume(returning: data ?? Data())
                            }
                        }
                    }
                } onCancel: {
                    // A task-group deadline still joins its children. Cancel the socket so receive actually returns.
                    nw.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: HTTPServer.idleTimeout)
                throw CancellationError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nw.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func write(_ response: HTTPResponse, head: Bool) async throws {
        var lines = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(response.status))\r\n"
        var headers = response.headers
        headers.append(("Content-Length", String(response.contentLength)))
        headers.append(("Date", Date.now.formatted(Self.httpDate)))
        for (k, v) in headers {
            lines += "\(k): \(v)\r\n"
        }
        lines += "\r\n"
        try await send(Data(lines.utf8))
        guard !head else { return }
        switch response.body {
        case .empty: break
        case let .data(d): try await send(d)
        case let .file(url, range, total):
            let window = range ?? 0 ... max(0, total - 1)
            guard total > 0 else { return }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(window.lowerBound))
            var remaining = window.upperBound - window.lowerBound + 1
            while remaining > 0 {
                try Task.checkCancellation()
                let want = Int(min(Int64(HTTPServer.chunk), remaining))
                // The file shrank after the headers went out: the promised Content-Length can no longer be met, and a
                // keep-alive client would read the next response as the rest of this body. Close the connection.
                guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: want) }), !chunk.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
                }
                try await send(chunk) // back-pressure: the next read waits for this send to complete
                remaining -= Int64(chunk.count)
            }
        }
    }

    private static let httpDate: Date.VerbatimFormatStyle = .init(
        format: """
        \(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT
        """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone(identifier: "GMT")!,
        calendar: Calendar(identifier: .gregorian)
    )
}
