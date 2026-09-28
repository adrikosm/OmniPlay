import CMkxpBridge
import Foundation

/// What the linked mkxp-z build can run. On the Mac the bridge is the header's no-op stubs (mask 0, empty strings);
/// on iOS the values come from the engine objects the app links.
public enum RGSSEngineInfo {
    public struct Support: Sendable, Hashable, CustomStringConvertible {
        public let mask: Int
        public let rubyVersion: String
        public var xp: Bool { mask & 1 != 0 }
        public var vx: Bool { mask & 2 != 0 }
        public var vxAce: Bool { mask & 4 != 0 }
        public var isLinked: Bool { mask != 0 }
        public var description: String {
            guard isLinked else { return "not linked" }
            let versions = [xp ? "1" : nil, vx ? "2" : nil, vxAce ? "3" : nil].compactMap(\.self).joined(separator: "/")
            return "RGSS \(versions), Ruby \(rubyVersion)"
        }
    }

    public static func support() -> Support {
        let mask = Int(mkxp_getSupportedRGSSVersionMask())
        let ruby = mkxp_getRubyVersion().map { String(cString: $0) } ?? ""
        return Support(mask: mask, rubyVersion: ruby)
    }
}
