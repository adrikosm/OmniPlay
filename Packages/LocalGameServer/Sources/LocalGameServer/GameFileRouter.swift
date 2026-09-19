import Diagnostics
import Foundation
import GameCore
import OverlayVFS

/// Per-game response header toggles.
public struct HeaderPolicy: Sendable, Hashable {
    /// Cross-origin isolation for threaded WebAssembly builds.
    public var coopCoep = false
    /// `no-store` in development, `private, max-age=0` otherwise.
    public var cacheControl = "private, max-age=0"

    public init(coopCoep: Bool = false, cacheControl: String = "private, max-age=0") {
        self.coopCoep = coopCoep
        self.cacheControl = cacheControl
    }

    public static func from(_ profile: CompatibilityProfile, debug: Bool) -> HeaderPolicy {
        HeaderPolicy(coopCoep: profile.overrides["coopCoep"] == "true", cacheControl: debug ? "no-store" : "private, max-age=0")
    }

    func apply(to response: inout HTTPResponse) {
        response.headers.append(("X-Content-Type-Options", "nosniff"))
        response.headers.append(("Cache-Control", cacheControl))
        response.headers.append(("Accept-Ranges", "bytes"))
        if coopCoep {
            response.headers.append(("Cross-Origin-Opener-Policy", "same-origin"))
            response.headers.append(("Cross-Origin-Embedder-Policy", "require-corp"))
            response.headers.append(("Cross-Origin-Resource-Policy", "same-origin"))
        }
    }
}

/// Serves a game tree through the overlay resolver: case-insensitive, no directory listings, single-range 206,
/// HEAD mirrors GET, pre-compressed `.br`/`.gz` siblings served with their encoding.
public struct GameFileRouter: Router {
    public let resolver: OverlayResolver
    public let policy: HeaderPolicy
    /// Served for `/`.
    public let defaultDocument: String?

    public init(resolver: OverlayResolver, policy: HeaderPolicy = HeaderPolicy(), defaultDocument: String? = "index.html") {
        self.resolver = resolver
        self.policy = policy
        self.defaultDocument = defaultDocument
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
        guard let hit = resolver.resolve(logical) else { return finish(.text(404, "not found")) }
        if hit.isDirectory {
            return finish(.text(403, "directory listing disabled"))
        }
        let size = hit.size > 0 ? hit.size : Int64((try? hit.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var response = HTTPResponse(status: 200)
        let (mime, encoding) = MIMEMap.type(for: logical)
        response.headers.append(("Content-Type", mime))
        if let encoding {
            response.headers.append(("Content-Encoding", encoding))
        }
        switch ByteRange.parse(request.headers["range"], size: size) {
        case let .satisfiable(range):
            response.status = 206
            response.headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"))
            response.body = .file(hit.url, range: range, totalSize: size)
        case .unsatisfiable:
            response = .text(416, "range not satisfiable")
            response.headers.append(("Content-Range", "bytes */\(size)"))
        case .ignore:
            response.body = .file(hit.url, range: nil, totalSize: size)
        }
        return finish(response)
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
