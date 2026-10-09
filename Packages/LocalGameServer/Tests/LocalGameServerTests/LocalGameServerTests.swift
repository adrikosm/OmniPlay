import Foundation
import GameCore
import LocalGameServer
import Network
import OverlayVFS
import Testing
import TestSupport

/// The loopback server is the surface every web game talks to; this exercises the real socket for
/// the paths that matter — case-insensitive lookup, MIME, ranges, and the refusals.
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
        // Names only, and only on request: the NW.js fs shim's readdirSync. Traversal is refused before listing.
        let (list, names) = try await get(port, "/www?omniplay=list")
        #expect(list.statusCode == 200 && (try? JSONDecoder().decode([String].self, from: names))?.contains("index.html") == true)
        #expect(try await get(port, "/www/..%2F..?omniplay=list").0.statusCode == 400)
        #expect(try await get(port, "/www/..%2F..%2Fetc/passwd").0.statusCode == 400)
        #expect(try await get(port, "/").0.statusCode == 404) // no index.html at the mv-basic root; www/index.html is the entry
        // Bodies reach only routes a runtime registers; this router has none.
        #expect(try await get(port, "/www/index.html", method: "POST").0.statusCode == 405)
        let (mp4, _) = try await get(port, "/www/movies/intro.mp4", headers: ["Range": "bytes=4-7"])
        #expect(mp4.statusCode == 206 && mp4.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 4-7/") == true)
        try await verifyUploadCommitBoundary()
    }

    /// A second browser request must not hand an unfinished directory to import while a file is still arriving.
    private func verifyUploadCommitBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        let server = UploadServer(stagingRoot: root)
        let port = try await server.start()
        defer { Task { await server.stop() }; try? FileManager.default.removeItem(at: root) }
        let base = "/\(server.token)"
        #expect(try await get(port, base + "/file?path=first.txt", method: "POST").0.statusCode == 200)
        let folder = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let partial = folder.appending(path: "second.txt")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        let request = "POST \(base)/file?path=second.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\na"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: partial.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(try await get(port, base + "/done", method: "POST").0.statusCode == 409)
        connection.cancel()
        var status = 409
        while status == 409, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            status = try await get(port, base + "/done", method: "POST").0.statusCode
        }
        #expect(status == 200)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "first.txt").path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
}
