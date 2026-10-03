import Diagnostics
import Foundation
import GameCore
import LocalGameServer
import OverlayVFS

/// KiriKiri 2/Z games in the web runtime, through KrKr2 Web (Kirikiroid2's krkr2 core as WebAssembly, with its
/// replacements for the plugins commercial games load). The engine's page and WebAssembly come from the app bundle
/// (`KrKr2Web/`, built by `Scripts/native/build-kirikiri.sh`) as an extra layer over the game; OmniPlay's patch to the
/// page reads every game file with Range requests from a manifest and keeps saves with the host.
public enum KiriKiriWeb {
    public static let bundleFolder = "KrKr2Web"
    public static let layerName = "engine/krkr2"

    /// The engine's files in the app bundle, when this build carries them.
    public static func engineRoot(bundle: Bundle = .main) -> URL? {
        guard let url = bundle.resourceURL?.appending(path: bundleFolder, directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: url.appending(path: "index.html").path(percentEncoded: false)) else { return nil }
        return url
    }

    /// Above the game's own layers: the engine's page wins over anything a game might ship by the same name.
    static func layer(root: URL) -> OverlayLayer {
        OverlayLayer(tier: .overrides, root: root, name: layerName, priority: 1500)
    }

    /// The page to open: every game file from `/omniplay-files`, saves with the host, and where startup.tjs lives
    /// (the archive holding it, or the folder of a loose project).
    static func entry(startup: String?) -> String {
        var query = "omniplay=1&files=/omniplay-files"
        if let startup {
            let folder = startup.lowercased().hasSuffix(".tjs") ? (startup as NSString).deletingLastPathComponent : startup
            let path = "/" + folder
            // `+`, `&` and `=` mean something in a query, so a name like `data+.xp3` must not keep them bare.
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
            query += "&startup=" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
        }
        return "index.html?" + query
    }

    /// The game's files as the page registers them: `[{path, size}]`, paths rooted at the game with a leading slash.
    static func manifest(gameRoot: URL) -> Data {
        var files: [[String: Any]] = []
        try? LazyDirectoryWalker.walk(root: gameRoot) { entry in
            if !entry.isDirectory {
                files.append(["path": "/" + entry.relativePath, "size": entry.fileSize])
            }
            return .continue
        }
        return (try? JSONSerialization.data(withJSONObject: files)) ?? Data("[]".utf8)
    }

    /// All of a game's KiriKiri saves together, as they are sent to the page in one response.
    static let maxSavesBytes = 64 << 20

    /// POST routes for the page: the manifest, and the game's saves in `saves` (its `Saves/slots`), read and written
    /// by path. Paths come from the page, so each is validated as a logical path before it touches the disk.
    /// The page cannot tell the player anything, so `onUnreadableSaves` (the game must not start) and `onSaveFailure`
    /// (a write was lost) carry the player's message to the host.
    static func routes(
        gameRoot: URL,
        saves: URL,
        session: SessionID,
        onUnreadableSaves: @escaping @Sendable (String) -> Void,
        onSaveFailure: @escaping @Sendable (String) -> Void
    ) -> [String: @Sendable (HTTPRequest) async -> HTTPResponse] {
        let json = [("Content-Type", "application/json")]
        return [
            "/omniplay-files": { _ in
                HTTPResponse(status: 200, headers: json, body: .data(manifest(gameRoot: gameRoot)))
            },
            "/omniplay-saves": { _ in
                // Every save goes out in one body, so the total is bounded, not just each file. Past the bound the
                // page gets an error rather than a partial list it would take for "these are all the saves".
                var files: [[String: String]] = []
                var total = 0
                var complete = true
                try? LazyDirectoryWalker.walk(root: saves) { entry in
                    guard !entry.isDirectory else { return .continue }
                    guard total + Int(entry.fileSize) <= maxSavesBytes,
                          let data = try? SmallFileGuard.read(entry.url, maxBytes: maxSavesBytes) else {
                        complete = false
                        return .stop
                    }
                    total += data.count
                    files.append(["path": "/" + entry.relativePath, "data": data.base64EncodedString()])
                    return .continue
                }
                guard complete, let body = try? JSONSerialization.data(withJSONObject: files) else {
                    OPLog.log(.save, .error, "kirikiri saves could not all be read (\(total) bytes so far)", session: session)
                    onUnreadableSaves(SaveBridge.Failure.incompleteSeed("Together they pass the 64 MB limit, or one could not be read.")
                        .description)
                    return .text(500, "saves could not all be read")
                }
                return HTTPResponse(status: 200, headers: json, body: .data(body))
            },
            "/omniplay-save": { request in
                guard let raw = request.query["path"], raw.hasPrefix("/"),
                      PathPolicy.validateLogical(String(raw.dropFirst())) != nil else { return .text(400, "bad save path") }
                let target = saves.appending(path: String(raw.dropFirst()))
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try request.body.write(to: target, options: .atomic)
                    OPLog.log(.save, .info, "kirikiri save \(raw) (\(request.body.count) bytes)", session: session)
                    return .text(200, "ok")
                } catch {
                    OPLog.log(.save, .error, "kirikiri save \(raw) failed: \(error)", session: session)
                    onSaveFailure(SaveBridge.playerMessage(for: error))
                    return .text(500, "save failed")
                }
            },
        ]
    }
}
