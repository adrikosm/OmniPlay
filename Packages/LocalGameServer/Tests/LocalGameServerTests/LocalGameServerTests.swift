import Foundation
import GameCore
import LocalGameServer
import Network
import OverlayVFS
import Testing
import TestSupport

@Suite("HTTP parsing and ranges")
struct HTTPParsingTests {
    @Test("Requests parse with lower-cased headers; pipelined bytes stay in the buffer")
    func parse() throws {
        let raw = Data("GET /www/index.html?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-9\r\n\r\nGET /next HTTP/1.1\r\n\r\n".utf8)
        let (req, consumed) = try HTTPRequestParser.parse(raw)
        #expect(req.method == "GET" && req.path == "/www/index.html" && req.headers["range"] == "bytes=0-9" && req.keepAlive)
        let (second, _) = try HTTPRequestParser.parse(raw.dropFirst(consumed))
        #expect(second.target == "/next")
        #expect(throws: HTTPParseError.incomplete) { try HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nHost".utf8)) }
        #expect(throws: HTTPParseError.headersTooLarge) { try HTTPRequestParser.parse(Data(repeating: 0x41, count: 9000)) }
        #expect(throws: HTTPParseError.malformed("request line")) { try HTTPParserProbe.parse("GARBAGE\r\n\r\n") }
        #expect(throws: HTTPParseError.malformed("request body not accepted")) {
            try HTTPParserProbe.parse("GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\n")
        }
        let (v10, _) = try HTTPParserProbe.parse("GET / HTTP/1.0\r\n\r\n")
        #expect(!v10.keepAlive)
        #expect(try HTTPParserProbe.parse("GET /a%20b HTTP/1.1\r\n\r\n").0.path == "/a b")
    }

    @Test("Byte ranges follow RFC 9110 for a 100-byte resource")
    func ranges() {
        #expect(ByteRange.parse("bytes=0-9", size: 100) == .satisfiable(0 ... 9))
        #expect(ByteRange.parse("bytes=90-", size: 100) == .satisfiable(90 ... 99))
        #expect(ByteRange.parse("bytes=-10", size: 100) == .satisfiable(90 ... 99))
        #expect(ByteRange.parse("bytes=50-500", size: 100) == .satisfiable(50 ... 99))
        #expect(ByteRange.parse("bytes=100-", size: 100) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=5-2", size: 100) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=0-1,5-6", size: 100) == .ignore)
        #expect(ByteRange.parse(nil, size: 100) == .ignore)
        #expect(ByteRange.parse("items=0-1", size: 100) == .ignore)
    }

    @Test("MIME types and pre-compressed encodings")
    func mime() {
        #expect(MIMEMap.type(for: "Build/x.wasm") == ("application/wasm", nil))
        #expect(MIMEMap.type(for: "Build/x.wasm.br") == ("application/wasm", "br"))
        #expect(MIMEMap.type(for: "Build/x.data.gz") == ("application/octet-stream", "gzip"))
        #expect(MIMEMap.type(for: "img/Actor1.rpgmvp").0 == "application/octet-stream")
        #expect(MIMEMap.type(for: "weird.zzz").0 == "application/octet-stream")
    }
}

enum HTTPParserProbe {
    static func parse(_ s: String) throws -> (HTTPRequest, Int) { try HTTPRequestParser.parse(Data(s.utf8)) }
}

@Suite("Loopback server", .serialized)
struct LoopbackServerTests {
    struct Served { let server: HTTPServer, port: UInt16, index: PathIndex }
    private func serve(_ root: URL, policy: HeaderPolicy = HeaderPolicy()) async throws -> Served {
        let index = try PathIndex.open(at: FileManager.default.temporaryDirectory.appending(path: "lgs-\(UUID().uuidString).sqlite"))
        try index.build(layer: "original", root: root)
        let resolver = OverlayResolver(layers: [OverlayLayer(tier: .original, root: root, name: "original", priority: 1)], index: index)
        let server = HTTPServer(router: GameFileRouter(resolver: resolver, policy: policy))
        let port = try await server.start()
        return Served(server: server, port: port, index: index)
    }

    private func get(
        _ port: UInt16,
        _ path: String,
        headers: [String: String] = [:],
        method: String = "GET"
    ) async throws -> (HTTPURLResponse, Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http, data)
    }

    @Test("Serves fixture files case-insensitively with MIME, HEAD, 404, 403 and rejects traversal")
    func basics() async throws {
        let served = try await serve(Fixtures.url("mv-basic"))
        let (server, port, index) = (served.server, served.port, served.index)
        defer { Task { await server.stop() }; try? FileManager.default.removeItem(at: index.url) }
        let (r, body) = try await get(port, "/WWW/JS/RPG_CORE.JS")
        #expect(r.statusCode == 200 && r.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/javascript") == true)
        #expect(String(bytes: body, encoding: .utf8)?.contains("1.6.2") == true)
        #expect(r.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        let (head, headBody) = try await get(port, "/www/index.html", method: "HEAD")
        #expect(head.statusCode == 200 && headBody.isEmpty && head.value(forHTTPHeaderField: "Content-Length") != "0")
        #expect(try await get(port, "/nope.txt").0.statusCode == 404)
        #expect(try await get(port, "/www").0.statusCode == 403)
        #expect(try await get(port, "/www/..%2F..%2Fetc/passwd").0.statusCode == 400)
        #expect(try await get(port, "/").0.statusCode == 404) // no index.html at the mv-basic root; www/index.html is the entry
        let (mp4, _) = try await get(port, "/www/movies/intro.mp4", headers: ["Range": "bytes=4-7"])
        #expect(mp4.statusCode == 206 && mp4.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 4-7/") == true)
    }

    @Test("206 windows are byte-exact against a 10 MiB file and full responses stream whole")
    func ranges() async throws {
        let root = try TemporaryGameRoot(name: "range")
        var bytes = Data(count: 10 << 20)
        for i in stride(from: 0, to: bytes.count, by: 4096) {
            bytes[i] = UInt8(truncatingIfNeeded: i / 4096)
        }
        try root.file("big.bin", bytes)
        let served = try await serve(root.url)
        let (server, port, index) = (served.server, served.port, served.index)
        defer { Task { await server.stop() }; try? FileManager.default.removeItem(at: index.url) }
        let (r, part) = try await get(port, "/big.bin", headers: ["Range": "bytes=4096-8191"])
        #expect(r.statusCode == 206 && part.count == 4096 && part.first == 1)
        let (tail, tailBytes) = try await get(port, "/big.bin", headers: ["Range": "bytes=-100"])
        #expect(tail.statusCode == 206 && tailBytes.count == 100)
        let (bad, _) = try await get(port, "/big.bin", headers: ["Range": "bytes=99999999-"])
        #expect(bad.statusCode == 416)
        let (full, all) = try await get(port, "/big.bin")
        #expect(full.statusCode == 200 && all.count == bytes.count && all == bytes)
    }

    @Test("COOP/COEP headers follow the policy; pre-compressed sibling gets Content-Encoding")
    func headers() async throws {
        let served = try await serve(Fixtures.url("unity-web-min"), policy: HeaderPolicy(coopCoep: true, cacheControl: "no-store"))
        defer { Task { await served.server.stop() }; try? FileManager.default.removeItem(at: served.index.url) }
        let (r, _) = try await get(served.port, "/index.html")
        #expect(r.value(forHTTPHeaderField: "Cross-Origin-Opener-Policy") == "same-origin")
        #expect(r.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy") == "require-corp")
        #expect(r.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        // HEAD only: the fixture's .br bytes are not real Brotli, and URLSession would try to decode a GET body.
        let (br, _) = try await get(served.port, "/Build/x.framework.js.br", method: "HEAD")
        #expect(br.value(forHTTPHeaderField: "Content-Encoding") == "br")
        #expect(br.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/javascript") == true)
    }

    @Test("Connections beyond the limit get 503; unsupported methods 405; server restarts after stop")
    func limits() async throws {
        let served = try await serve(Fixtures.url("mv-basic"))
        let (server, port, index) = (served.server, served.port, served.index)
        defer { try? FileManager.default.removeItem(at: index.url) }
        // Hold 16 idle connections open, then the 17th must be refused.
        var held: [NWConnection] = []
        for _ in 0 ..< HTTPServer.maxConnections {
            let c = try NWConnection(host: "127.0.0.1", port: #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
            c.start(queue: .global())
            held.append(c)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await server.activeConnections == HTTPServer.maxConnections)
        let extra = try NWConnection(host: "127.0.0.1", port: #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        extra.start(queue: .global())
        let reply: Data? = try await withCheckedThrowingContinuation { cont in
            extra.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: data)
                }
            }
        }
        #expect(reply.flatMap { String(bytes: $0, encoding: .utf8) }?.hasPrefix("HTTP/1.1 503") == true)
        held.forEach { $0.cancel() }
        extra.cancel()
        try await Task.sleep(for: .milliseconds(300))
        let (post, _) = try await get(port, "/www/index.html", method: "POST")
        #expect(post.statusCode == 405 && post.value(forHTTPHeaderField: "Allow") == "GET, HEAD")
        await server.stop()
        let again = try await server.start(port: port)
        #expect(again == port)
        #expect(try await get(port, "/www/index.html").0.statusCode == 200)
        await server.stop()
    }
}
