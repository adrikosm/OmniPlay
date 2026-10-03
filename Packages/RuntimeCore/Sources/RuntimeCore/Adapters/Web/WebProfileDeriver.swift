import Foundation
import GameCore
import LocalGameServer

public enum WebUserAgent: String, Sendable, Codable { case iphone, ipad, desktop }

/// The knobs the WebKit adapter reads, derived once from detection; never chosen in UI code.
public struct WebProfile: Sendable, Hashable {
    public var userAgent: WebUserAgent = .iphone
    /// `require`/`process` made undefined before game scripts run (MV/MZ then take their web path).
    public var nwUndefined = true
    /// Extra shims from the plugin scan: `nwWindow`, `processVersions`, `fsReadOnly`, `pathPosix`, `greenworks`.
    public var shims: Set<String> = []
    public var isGameActivePatch = false
    public var canPlayWebmFalse = true
    public var audioFileExtOgg = false
    public var coopCoep = false
    public var forceWebGL2 = false
    public var imageCacheCapMB: Int?
    /// Forced before the engine boots; 1 halves the pixel count of every canvas on a 3x phone.
    public var devicePixelRatio: Int?
    /// RPG Maker MV/MZ scaled to cover the screen, cropping the edges, instead of letterboxed (`screen=fill`).
    public var fill = false
    public var orientation: OrientationPreference = .any
    /// The page reads taps itself (Tyrano visual novels), so the virtual gamepad stays hidden.
    public var touchNative = false
    /// The page's `preventDefault()` on touchmove is ignored, so a tap that moves slightly still clicks (Tyrano).
    public var ignoreTouchMoveCancel = false
    /// A plain web page (2048 and the like) taller than the screen scrolls; engine canvases never overflow.
    public var pageScroll = false
    /// Every sound silenced, for scripted test runs (`OMNIPLAY_MUTE`, set by debug builds from `--mute-audio`).
    public var muted = ProcessInfo.processInfo.environment["OMNIPLAY_MUTE"] != nil
    /// Ask the engine for its own autosave slot when the player leaves (MV/MZ only).
    public var autosaveOnExit = false
    /// Lines the dictionary misses go to the host for live translation (TRANS-006, `liveTranslation=<language>`).
    public var liveTranslation = false
    /// RPG Maker MV/MZ: the scene loop can run faster (the pause menu's speed row).
    public var rpgMaker = false
    /// A KiriKiri game: served with the KrKr2 Web engine (`KiriKiriWeb`).
    public var kirikiri = false
    /// The host's pause when the page (re)loads, so a page reloaded behind the pause menu starts paused.
    public var paused = false
    public var headerPolicy: HeaderPolicy { HeaderPolicy(coopCoep: coopCoep) }

    /// What the loopback server tries when a game asks for a movie or sound under an extension it did not ship.
    /// RPG Maker asks for `.mp4` here (`canPlayWebmFalse`), and MZ often ships only `.webm`, which WebKit plays;
    /// MV asks for `.ogg` or `.m4a` and ships either. Order is preference: H.264 before WebM, then the rest.
    public static let mediaSiblings: [String: [String]] = [
        "mp4": ["m4v", "mov", "webm"], "m4v": ["mp4", "mov", "webm"], "webm": ["mp4", "m4v", "mov"], "ogv": ["mp4", "webm"],
        "ogg": ["m4a", "mp3", "wav", "opus"], "m4a": ["ogg", "mp3", "wav", "opus"], "mp3": ["ogg", "m4a", "wav"],
        "wav": ["ogg", "m4a", "mp3"],
        "rpgmvo": ["rpgmvm"], "rpgmvm": ["rpgmvo"], "ogg_": ["m4a_"], "m4a_": ["ogg_"],
    ]

    public static func derive(from descriptor: GameDescriptor, debug: Bool = false) -> WebProfile {
        var p = WebProfile()
        let hints = descriptor.profile.overrides
        let tyrano = descriptor.engine == .html5 && hints["webSubFamily"] == "tyrano"
        // Threaded WebAssembly builds need SharedArrayBuffer, which needs cross-origin isolation: detection says which
        // (Unity, Godot, LÖVE and Ren'Py web builds, and anything else that asks), whatever the family.
        p.coopCoep = hints["coopCoep"] == "true"
        switch descriptor.engine {
        case .rpgMakerMV:
            p.audioFileExtOgg = descriptor.mediaRequirements.contains { $0.action == .shim("audioFileExtOgg") }
            p.orientation = .landscape
            p.autosaveOnExit = true
            p.rpgMaker = true
        case .rpgMakerMZ:
            p.isGameActivePatch = true
            p.orientation = .landscape
            p.autosaveOnExit = true
            p.rpgMaker = true
        case .unityWeb:
            p.forceWebGL2 = hints["forceWebGL2"] == "true"
            p.nwUndefined = false
        case .godotWeb:
            p.nwUndefined = false
        case .kirikiri:
            p.kirikiri = true
            p.coopCoep = true // the engine's threads need SharedArrayBuffer
            p.touchNative = true
            p.orientation = .landscape
            p.nwUndefined = false
        default:
            p.nwUndefined = hints["webSubFamily"] == nil
            p.touchNative = tyrano
            p.ignoreTouchMoveCancel = tyrano
            p.pageScroll = descriptor.engine == .html5 && !tyrano
        }
        if let agent = hints["userAgent"].flatMap(WebUserAgent.init(rawValue:)) {
            p.userAgent = agent
        }
        if let orientation = hints["orientation"].flatMap(OrientationPreference.init(rawValue:)) {
            p.orientation = orientation
        }
        // Tyrano takes `require` plus `process` to mean NW.js and switches to desktop file paths, so its Node
        // plugins stay named in the warnings and get no shims.
        for w in descriptor.warnings where !tyrano {
            if case let .nodePlugin(_, apis) = w {
                if apis.contains(where: { $0.contains("fs") }) {
                    p.shims.insert("fsReadOnly")
                }
                if apis.contains(where: { $0.contains("path") }) {
                    p.shims.insert("pathPosix")
                }
                if apis.contains("nw.") {
                    p.shims.insert("nwWindow")
                }
                if apis.contains("process.") {
                    p.shims.insert("processVersions")
                }
                if apis.contains("greenworks") {
                    p.shims.insert("greenworks")
                }
            }
        }
        if let cap = hints["imageCacheCapMB"].flatMap(Int.init) {
            p.imageCacheCapMB = cap
        }
        p.fill = hints["screen"] == "fill"
        p.liveTranslation = p.rpgMaker && !(hints["liveTranslation"] ?? "").isEmpty
        if let dpr = hints["devicePixelRatio"].flatMap(Int.init), (1 ... 3).contains(dpr) {
            p.devicePixelRatio = dpr
        }
        return p
    }

    /// The JSON the bootstrap script reads as `OmniPlay.profile`.
    public var json: String {
        let shimList = shims.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"nwUndefined":\(nwUndefined),"shims":[\(shimList)],"isGameActivePatch":\(isGameActivePatch),\
        "canPlayWebmFalse":\(canPlayWebmFalse),"audioFileExtOgg":\(audioFileExtOgg),\
        "imageCacheCapMB":\(imageCacheCapMB.map(String.init) ?? "null"),"devicePixelRatio":\(devicePixelRatio.map(String.init) ?? "null"),\
        "ignoreTouchMoveCancel":\(ignoreTouchMoveCancel),"muted":\(muted),"fill":\(fill),\
        "liveTranslation":\(liveTranslation),"paused":\(paused)}
        """
    }
}
