import Foundation

/// The injected scripts, loaded from the package resources and specialised with the game's profile and saves.
public enum WebRuntimeBundle {
    public static let version = 13
    public static let isolatedScripts = ["omniplay-bootstrap", "omniplay-console", "omniplay-heartbeat"]
    /// Order matters: storage runs first so localStorage is seeded before any game script reads it.
    public static let pageScripts = [
        "omniplay-page-console", "omniplay-storage", "omniplay-nw-shim", "omniplay-audio", "omniplay-compat", "omniplay-input",
        "omniplay-pause", "omniplay-state", "omniplay-translate",
    ]

    public static func source(_ name: String, profile: WebProfile, saves: String = "{}") throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "WebRuntimeAssets") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).js"])
        }
        var source = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "__OMNIPLAY_PROFILE__", with: profile.json)
        if source.contains("__OMNIPLAY_SAVES__") {
            // A JSON object literal treats __proto__ specially; JSON.parse preserves every game's exact storage key.
            let encoded = try JSONEncoder().encode(saves)
            guard let literal = String(data: encoded, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            source = source.replacingOccurrences(of: "__OMNIPLAY_SAVES__", with: "JSON.parse(\(literal))")
        }
        return source
    }
}
