import Diagnostics
import Foundation
import Network
import Synchronization

/// Opt-in LAN upload for multi-GB folders: the phone serves one page on the local network, the browser posts
/// each file raw with its relative path, and bodies stream straight to staging in 1 MiB reads. A random token
/// guards the URL, one upload runs at a time, and the listener lives only while the screen is open.
public actor UploadServer {
    public enum Event: Sendable, Equatable {
        /// A browser opened the upload page.
        case browserConnected
        /// The size of the whole upload, as the browser states it before the first file. Display only.
        case expecting(bytes: Int64)
        case fileReceived(relativePath: String, bytes: Int64)
        case sessionCompleted(directory: URL, files: Int, bytes: Int64)
        case failed(String)
    }

    public static let chunk = 1 << 20
    public static let maxFileBytes: Int64 = 64 << 30
    public static let maxPathLength = 512

    public nonisolated let stagingRoot: URL
    public nonisolated let token: String
    public private(set) var port: UInt16 = 0
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var listener: NWListener?
    private var busy = false
    private var sessionDirectory: URL
    private var files = 0
    private var bytes: Int64 = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(stagingRoot: URL) {
        self.stagingRoot = stagingRoot
        token = String((0 ..< 6).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
        sessionDirectory = stagingRoot.appending(path: "wifi-\(UUID().uuidString)", directoryHint: .isDirectory)
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(64))
    }

    /// Binds any interface on a random high port and advertises `_omniplay._tcp` over Bonjour.
    @discardableResult
    public func start(port requested: UInt16? = nil) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let requested {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: NWEndpoint.Port(rawValue: requested)!)
        }
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: "OmniPlay", type: "_omniplay._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        self.listener = listener
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if !resumed.withLock({ let r = $0; $0 = true; return r }) {
                        cont.resume()
                    }
                case let .failed(error): if !resumed.withLock({ let r = $0; $0 = true; return r }) {
                        cont.resume(throwing: error)
                    }
                case .cancelled: if !resumed.withLock({ let r = $0; $0 = true; return r }) {
                        cont.resume(throwing: CancellationError())
                    }
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        port = listener.port?.rawValue ?? 0
        OPLog.log(.importer, .info, "wifi upload listening on port \(port)")
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values {
            c.cancel()
        }
        connections.removeAll()
        continuation.finish()
        OPLog.log(.importer, .info, "wifi upload stopped")
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection) {
        connections[ObjectIdentifier(nw)] = nw
        Task { [weak self] in
            await self?.serve(nw)
            await self?.forget(nw)
        }
    }

    private func forget(_ nw: NWConnection) { connections[ObjectIdentifier(nw)] = nil }

    private struct Head {
        let method: String
        let path: String
        let query: [String: String]
        let contentLength: Int64
    }

    private func serve(_ nw: NWConnection) async {
        nw.start(queue: .global(qos: .userInitiated))
        defer { nw.cancel() }
        do {
            var buffer = Data()
            var head: Head?
            var bodyStart = 0
            while head == nil {
                guard let more = try await Self.receive(nw) else { return }
                buffer.append(more)
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    head = try Self.parse(buffer[..<range.lowerBound])
                    bodyStart = range.upperBound
                } else if buffer.count > 16 << 10 {
                    try await Self.write(nw, 431, "text/plain", Data("request header too large".utf8)); return
                }
            }
            guard let head else { return }
            let parts = head.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.first == token else { try await Self.write(nw, 404, "text/plain", Data("not found".utf8)); return }
            switch (head.method, parts.dropFirst().first ?? "") {
            case ("GET", ""):
                continuation.yield(.browserConnected)
                try await Self.write(nw, 200, "text/html; charset=utf-8", Data(Self.page(token: token).utf8))
            case ("POST", "file"):
                try await receiveFile(head, initial: buffer[bodyStart...], nw: nw)
            case ("POST", "done"):
                guard !busy else { try await Self.write(nw, 409, "text/plain", Data("an upload is still in progress".utf8)); return }
                let (dir, n, total) = (sessionDirectory, files, bytes)
                guard n > 0 else { try await Self.write(nw, 400, "text/plain", Data("nothing uploaded".utf8)); return }
                sessionDirectory = stagingRoot.appending(path: "wifi-\(UUID().uuidString)", directoryHint: .isDirectory)
                files = 0
                bytes = 0
                continuation.yield(.sessionCompleted(directory: dir, files: n, bytes: total))
                try await Self.write(nw, 200, "text/plain", Data("ok".utf8))
            default:
                try await Self.write(nw, 404, "text/plain", Data("not found".utf8))
            }
        } catch {
            OPLog.log(.importer, .debug, "wifi connection closed: \(error)")
        }
    }

    private func receiveFile(_ head: Head, initial: Data, nw: NWConnection) async throws {
        guard !busy else { try await Self.write(nw, 409, "text/plain", Data("one upload at a time".utf8)); return }
        guard let rel = head.query["path"], let safe = Self.safeRelativePath(rel) else {
            try await Self.write(nw, 400, "text/plain", Data("bad path".utf8)); return
        }
        guard head.contentLength >= 0, head.contentLength <= Self.maxFileBytes else {
            try await Self.write(nw, 413, "text/plain", Data("file too large".utf8)); return
        }
        busy = true
        defer { busy = false }
        if files == 0, let total = head.query["total"].flatMap(Int64.init), total > 0 {
            continuation.yield(.expecting(bytes: total))
        }
        let target = sessionDirectory.appending(path: safe)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: target.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        var written: Int64 = 0
        do {
            if !initial.isEmpty {
                let slice = initial.prefix(Int(min(Int64(initial.count), head.contentLength)))
                try handle.write(contentsOf: slice)
                written += Int64(slice.count)
            }
            while written < head.contentLength {
                guard let more = try await Self.receive(nw) else { break }
                let slice = more.prefix(Int(min(Int64(more.count), head.contentLength - written)))
                try autoreleasepool { try handle.write(contentsOf: slice) }
                written += Int64(slice.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: target)
            continuation.yield(.failed("\(safe): connection dropped"))
            throw error
        }
        guard written == head.contentLength else {
            try? FileManager.default.removeItem(at: target)
            continuation.yield(.failed("\(safe): incomplete (\(written) of \(head.contentLength) bytes)"))
            try await Self.write(nw, 400, "text/plain", Data("incomplete".utf8))
            return
        }
        files += 1
        bytes += written
        continuation.yield(.fileReceived(relativePath: safe, bytes: written))
        try await Self.write(nw, 200, "text/plain", Data("ok".utf8))
    }

    // MARK: Helpers

    public static func safeRelativePath(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        guard !decoded.isEmpty, decoded.count <= maxPathLength, !decoded.hasPrefix("/"), !decoded.contains("\\"),
              decoded.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.joined(separator: "/")
    }

    private static func parse(_ headBytes: Data) throws -> Head {
        guard let text = String(bytes: headBytes, encoding: .utf8) else { throw URLError(.badServerResponse) }
        var lines = text.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ")
        guard request.count >= 2 else { throw URLError(.badServerResponse) }
        let target = String(request[1])
        let pathAndQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                query[String(kv[0])] = kv.count == 2 ? String(kv[1]).replacingOccurrences(of: "+", with: " ") : ""
            }
        }
        var length: Int64 = 0
        for line in lines {
            if line.lowercased().hasPrefix("content-length:"),
               let n = Int64(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) {
                length = n
            }
        }
        return Head(
            method: String(request[0]),
            path: String(pathAndQuery[0]).removingPercentEncoding ?? String(pathAndQuery[0]),
            query: query,
            contentLength: length
        )
    }

    private static func receive(_ nw: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            nw.receive(minimumIncompleteLength: 1, maximumLength: chunk) { data, _, complete, error in
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
    }

    private static func write(_ nw: NWConnection, _ status: Int, _ type: String, _ body: Data) async throws {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\nContent-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nw.send(content: Data(head.utf8) + body, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// The uploader: a folder or files picker; each file posts raw with its relative path, then `done`.
    static func page(token: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>OmniPlay upload</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;background:#0A0E1A;color:#F2F4F8;margin:0;padding:24px}
        h1{font-family:Georgia,serif;font-weight:600}button,input{font:inherit}
        button{background:#F5B84A;color:#0A0E1A;border:0;border-radius:24px;padding:12px 22px;font-weight:600}
        .bar{height:8px;background:#13182A;border-radius:4px;overflow:hidden;margin:16px 0}
        .bar i{display:block;height:100%;background:#F5B84A;width:0}
        p{color:#A9B2C4}#log{font:12px ui-monospace,monospace;white-space:pre-wrap;color:#A9B2C4}</style></head>
        <body><h1>Send a game to OmniPlay</h1>
        <p>Pick the game's folder (or an archive). Files go straight to this phone over your Wi-Fi; nothing leaves the network.</p>
        <p><input type="file" id="dir" webkitdirectory multiple> <input type="file" id="files" multiple></p>
        <p><button id="go">Upload</button></p><div class="bar"><i id="fill"></i></div><div id="log"></div>
        <script>
        const base = location.pathname.replace(/\\/$/, "");
        const log = (t) => { document.getElementById("log").textContent += t + "\\n"; };
        document.getElementById("go").onclick = async () => {
          const list = [...document.getElementById("dir").files, ...document.getElementById("files").files];
          if (!list.length) { log("Choose a folder or files first."); return; }
          const total = list.reduce((n, f) => n + f.size, 0); let done = 0;
          for (const f of list) {
            const rel = f.webkitRelativePath || f.name;
            const url = base + "/file?path=" + encodeURIComponent(rel) + "&total=" + total;
            const r = await fetch(url, { method: "POST", body: f, headers: { "Content-Type": "application/octet-stream" } });
            if (!r.ok) { log("Failed: " + rel + " (" + r.status + ")"); return; }
            done += f.size;
            document.getElementById("fill").style.width = Math.round(100 * done / total) + "%";
            log(rel);
          }
          const d = await fetch(base + "/done", { method: "POST" });
          log(d.ok ? "Done. OmniPlay is importing the game now." : "Finish failed (" + d.status + ")");
        };
        </script></body></html>
        """
    }
}
