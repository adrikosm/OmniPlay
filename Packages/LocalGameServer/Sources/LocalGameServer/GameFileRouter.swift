import Diagnostics
import Foundation
import GameCore
import OverlayVFS

/// Per-game response header toggles.
public struct HeaderPolicy: Sendable, Hashable {
    /// Cross-origin isolation for threaded WebAssembly builds.
    public var coopCoep = false

    public init(coopCoep: Bool = false) {
        self.coopCoep = coopCoep
    }

    func apply(to response: inout HTTPResponse) {
        response.headers.append(("X-Content-Type-Options", "nosniff"))
        response.headers.append(("Cache-Control", "private, max-age=0"))
        response.headers.append(("Accept-Ranges", "bytes"))
        if coopCoep {
            response.headers.append(("Cross-Origin-Opener-Policy", "same-origin"))
            response.headers.append(("Cross-Origin-Embedder-Policy", "require-corp"))
            response.headers.append(("Cross-Origin-Resource-Policy", "same-origin"))
        }
    }
}

/// A file the host derives from a game file on request (`?omniplay=<name>`): the derived file and its MIME type,
/// or nil to serve the original.
public typealias FileTransform = @Sendable (URL) async -> (url: URL, mime: String)?

/// Serves a game tree through the overlay resolver: case-insensitive, directory names only on `?omniplay=list`, single-range 206,
/// HEAD mirrors GET, pre-compressed `.br`/`.gz` siblings served with their encoding. The host adds POST routes and
/// file transforms for what WebKit cannot decode itself.
public struct GameFileRouter: Sendable {
    public let resolver: OverlayResolver
    public let policy: HeaderPolicy
    /// Served for `/`.
    public let defaultDocument: String?
    /// Exact paths (with the leading slash) that accept POST.
    public var postRoutes: [String: @Sendable (HTTPRequest) async -> HTTPResponse] = [:]
    /// Applied when the query names one: `x.ogg?omniplay=pcm` serves `transforms["pcm"]` of `x.ogg`.
    public var transforms: [String: FileTransform] = [:]
    /// Extensions to try, in order, when the requested file is missing: RPG Maker picks a movie or sound extension
    /// from what it believes the browser plays, and a game often ships only the other one. The sibling is served with
    /// its own MIME type.
    public var siblingExtensions: [String: [String]] = [:]
    /// Lower-cased logical paths served from another path: a file the host converted because WebKit cannot play it
    /// (`intro.ogv` → `intro.mp4` in the Generated layer).
    public var aliases: [String: String] = [:]
    /// Told the size of every file served (whole or a range), so the host can show a big game loading.
    public var onServe: (@Sendable (Int64) -> Void)?

    public init(resolver: OverlayResolver, policy: HeaderPolicy = HeaderPolicy(), defaultDocument: String? = "index.html") {
        self.resolver = resolver
        self.policy = policy
        self.defaultDocument = defaultDocument
    }

    public func acceptsPost(_ path: String) -> Bool { postRoutes[path] != nil }

    public func post(_ request: HTTPRequest) async -> HTTPResponse {
        guard let handler = postRoutes[request.path] else {
            var response = HTTPResponse.text(405, "method not allowed")
            response.headers.append(("Allow", "GET, HEAD"))
            return finish(response)
        }
        return await finish(handler(request))
    }

    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        var logical = request.path
        while logical.hasPrefix("/") {
            logical.removeFirst()
        }
        if logical.isEmpty {
            guard let doc = defaultDocument else { return finish(.text(404, "not found")) }; logical = doc
        }
        guard PathPolicy.validateLogical(logical) != nil else { return finish(.text(400, "bad path")) }
        guard let (found, hit) = resolve(logical) else { return finish(.text(404, "not found")) }
        logical = found
        if hit.isDirectory {
            guard request.query["omniplay"] == "list" else { return finish(.text(403, "directory listing disabled")) }
            // Names only, for the NW.js `fs.readdirSync` shim: NW games list their own folders on the desktop.
            var names: [String] = []
            for await child in resolver.list(directory: found) {
                names.append((child.realRelativePath as NSString).lastPathComponent)
            }
            let json = (try? JSONEncoder().encode(names)) ?? Data("[]".utf8)
            return finish(HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .data(json)))
        }
        var file = hit.url
        var size = hit.size > 0 ? hit.size : Int64((try? hit.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var (mime, encoding) = MIMEMap.type(for: logical)
        if let name = request.query["omniplay"], let transform = transforms[name], let derived = await transform(hit.url) {
            file = derived.url
            mime = derived.mime
            encoding = nil
            size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var response = HTTPResponse(status: 200)
        response.headers.append(("Content-Type", mime))
        if let encoding {
            response.headers.append(("Content-Encoding", encoding))
        }
        switch ByteRange.parse(request.headers["range"], size: size) {
        case let .satisfiable(range):
            response.status = 206
            response.headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"))
            response.body = .file(file, range: range, totalSize: size)
        case .unsatisfiable:
            response = .text(416, "range not satisfiable")
            response.headers.append(("Content-Range", "bytes */\(size)"))
        case .ignore:
            response.body = .file(file, range: nil, totalSize: size)
        }
        if case let .file(_, range, total) = response.body {
            onServe?(range.map { $0.upperBound - $0.lowerBound + 1 } ?? total)
        }
        return finish(response)
    }

    /// The requested file, or the first sibling under another media extension.
    private func resolve(_ logical: String) -> (String, Resolution)? {
        if let alias = aliases[logical.lowercased()], let hit = resolver.resolve(alias), !hit.isDirectory {
            return (alias, hit)
        }
        if let hit = resolver.resolve(logical) {
            return (logical, hit)
        }
        guard let dot = logical.lastIndex(of: "."), !logical[dot...].contains("/") else { return nil }
        let stem = logical[..<dot]
        for ext in siblingExtensions[logical[logical.index(after: dot)...].lowercased()] ?? [] {
            let sibling = stem + "." + ext
            if let hit = resolver.resolve(sibling), !hit.isDirectory {
                return (sibling, hit)
            }
        }
        return nil
    }

    private func finish(_ response: HTTPResponse) -> HTTPResponse {
        var r = response
        policy.apply(to: &r)
        return r
    }
}

/// Content types by extension; unknown types are octet-stream, never sniffed.
public enum MIMEMap {
    static let table: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "wasm": "application/wasm", "txt": "text/plain; charset=utf-8",
        "xml": "application/xml", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif", "ico": "image/x-icon", "ogg": "audio/ogg", "oga": "audio/ogg", "opus": "audio/ogg", "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "wav": "audio/wav", "webm": "video/webm", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "ogv": "video/ogg",
        "ttf": "font/ttf", "otf": "font/otf", "woff": "font/woff", "woff2": "font/woff2", "pck": "application/octet-stream",
        "data": "application/octet-stream",
        "unityweb": "application/octet-stream", "ks": "text/plain; charset=utf-8", "rpgmvp": "application/octet-stream",
        "rpgmvo": "application/octet-stream",
        "rpgmvm": "application/octet-stream", "png_": "application/octet-stream", "ogg_": "application/octet-stream",
        "m4a_": "application/octet-stream",
    ]

    /// `(type, contentEncoding)`: `x.wasm.br` → `application/wasm` + `br`.
    public static func type(for path: String) -> (String, String?) {
        var name = path.split(separator: "/").last.map(String.init) ?? path
        var encoding: String?
        if name.hasSuffix(".br") {
            encoding = "br"; name.removeLast(3)
        } else if name.hasSuffix(".gz") {
            encoding = "gzip"; name.removeLast(3)
        }
        let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        return (table[ext] ?? "application/octet-stream", encoding)
    }
}
