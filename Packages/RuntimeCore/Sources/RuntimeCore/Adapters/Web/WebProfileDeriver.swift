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
    public var orientation: OrientationPreference = .any
    public var headerPolicy: HeaderPolicy { HeaderPolicy(coopCoep: coopCoep) }

    public static func derive(from descriptor: GameDescriptor, debug: Bool = false) -> WebProfile {
        var p = WebProfile()
        let hints = descriptor.profile.overrides
        switch descriptor.engine {
        case .rpgMakerMV:
            p.audioFileExtOgg = descriptor.mediaRequirements.contains { $0.action == .shim("audioFileExtOgg") }
            p.orientation = .landscape
        case .rpgMakerMZ:
            p.isGameActivePatch = true
            p.orientation = .landscape
            if descriptor.warnings.contains(where: {
                if case .note = $0 {
                    false
                } else {
                    false
                }
            }) {}
        case .unityWeb:
            p.coopCoep = hints["coopCoep"] == "true"
            p.forceWebGL2 = hints["forceWebGL2"] == "true"
            p.nwUndefined = false
        case .godotWeb:
            p.coopCoep = hints["coopCoep"] == "true"
            p.nwUndefined = false
        default:
            p.nwUndefined = hints["webSubFamily"] == nil
        }
        for w in descriptor.warnings {
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
        return p
    }

    /// The JSON the bootstrap script reads as `OmniPlay.profile`.
    public var json: String {
        let shimList = shims.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"nwUndefined":\(nwUndefined),"shims":[\(shimList)],"isGameActivePatch":\(isGameActivePatch),\
        "canPlayWebmFalse":\(canPlayWebmFalse),"audioFileExtOgg":\(audioFileExtOgg),\
        "imageCacheCapMB":\(imageCacheCapMB.map(String.init) ?? "null")}
        """
    }
}
