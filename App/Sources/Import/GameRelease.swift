import Foundation
import GameCore
import GameImport

/// Recognises a game already in the library in other files, and reads the version each release names.
enum GameRelease {
    private static let platformWords: Set = ["pc", "win", "windows", "mac", "linux", "android", "ios", "x64", "x86", "64bit"]

    /// Case-folded, without diacritics, version tokens, platform words or punctuation: "HoS v0.26d (PC)" is "hos".
    static func normalisedTitle(_ title: String) -> String {
        let tokens = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { $0.isWhitespace || "_-()[]".contains($0) }.map(String.init)
        var words: [String] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            if token == "build", i < tokens.count, tokens[i].allSatisfy(\.isNumber) {
                i += 1
                continue
            }
            if platformWords.contains(token) || isVersion(token) {
                continue
            }
            let word = token.filter { $0.isLetter || $0.isNumber }
            if !word.isEmpty {
                words.append(word)
            }
        }
        return words.joined(separator: " ")
    }

    /// `v1.2`, `0.26d`, `1.0.0`, `v3`; never a bare number, which a sequel's title can end in.
    static func isVersion(_ token: String) -> Bool { token.lowercased().wholeMatch(of: /v?\d+(\.\d+)+[a-z]?|v\d+[a-z]?/) != nil }

    /// `define config.<key> = "…"` from a loose `game/options.rpy`, read up to 256 KB.
    static func renpyDefine(_ key: String, root: URL) -> String? {
        guard let text = head(root.appending(path: "game/options.rpy"), max: 256 << 10),
              let pattern = try? Regex(#"define\s+config\.\#(key)\s*=\s*_?\(?\s*u?(["'])([^\n]+?)\1"#),
              let match = text.firstMatch(of: pattern), let value = match.output[2].substring else { return nil }
        return String(value)
    }

    /// The release's own version, best source first: Ren'Py's `config.version`, an NW.js `package.json` version that is
    /// not a placeholder, then the last version-like token of the source or folder names.
    static func version(root: URL, engine: EngineFamily, names: [String]) -> String? {
        if engine == .renpy, let version = renpyDefine("version", root: root) {
            return version
        }
        if let data = head(root.appending(path: "package.json"), max: 64 << 10).map({ Data($0.utf8) }),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String, !["1.0.0", "0.0.0", ""].contains(version) {
            return version
        }
        for name in names {
            if let token = name.split(whereSeparator: { $0.isWhitespace || "_-()[]".contains($0) }).last(where: { isVersion(String($0)) }) {
                return String(token.drop { $0 == "v" || $0 == "V" })
            }
        }
        return nil
    }

    /// Numeric components, a trailing letter as the smallest part: `0.26 < 0.26d < 0.27`.
    static func order(_ incoming: String?, _ installed: String?) -> VersionOrder {
        guard let a = incoming.flatMap(parts), let b = installed.flatMap(parts) else { return .unknown }
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : (0, ""), y = i < b.count ? b[i] : (0, "")
            if x != y {
                return x < y ? .older : .newer
            }
        }
        return .same
    }

    private static func parts(_ version: String) -> [(Int, String)]? {
        var out: [(Int, String)] = []
        for component in version.lowercased().drop(while: { $0 == "v" }).split(separator: ".") {
            guard let m = component.wholeMatch(of: /(\d+)([a-z]*)/), let n = Int(m.1) else { return nil }
            out.append((n, String(m.2)))
        }
        return out.isEmpty ? nil : out
    }

    private static func head(_ url: URL, max: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: max)).flatMap { String(bytes: $0, encoding: .utf8) }
    }
}
