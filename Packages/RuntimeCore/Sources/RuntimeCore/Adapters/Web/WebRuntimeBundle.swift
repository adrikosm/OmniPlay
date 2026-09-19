import Foundation

/// The injected scripts, loaded from the package resources and specialised with the game's profile.
public enum WebRuntimeBundle {
    public static let version = 1
    public static let isolatedScripts = ["omniplay-bootstrap", "omniplay-console", "omniplay-heartbeat"]
    public static let pageScripts = ["omniplay-nw-shim", "omniplay-compat"]

    public static func source(_ name: String, profile: WebProfile) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "WebRuntimeAssets") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).js"])
        }
        return try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "__OMNIPLAY_PROFILE__", with: profile.json)
    }
}
