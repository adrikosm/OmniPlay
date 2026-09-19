import Foundation

/// The injected scripts, loaded from the package resources and specialised with the game's profile and saves.
public enum WebRuntimeBundle {
    public static let version = 3
    public static let isolatedScripts = ["omniplay-bootstrap", "omniplay-console", "omniplay-heartbeat"]
    /// Order matters: storage runs first so localStorage is seeded before any game script reads it.
    public static let pageScripts = ["omniplay-storage", "omniplay-nw-shim", "omniplay-compat", "omniplay-input", "omniplay-pause"]

    public static func source(_ name: String, profile: WebProfile, saves: String = "{}") throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "WebRuntimeAssets") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).js"])
        }
        return try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "__OMNIPLAY_PROFILE__", with: profile.json)
            .replacingOccurrences(of: "__OMNIPLAY_SAVES__", with: saves)
    }
}
