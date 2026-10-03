import Foundation

/// The Ruby OmniPlay runs in every RGSS game ahead of the game's own scripts (mkxp-z `preloadScript`), written into
/// the session's managed folder.
enum RGSSHostScripts {
    /// `omniplay_saves.rb` always: the game folder is sealed, so saves a game writes beside itself go to its save
    /// folder. `omniplay_bridge.rb` always: the typed state bridge the Game Tools use (mkxp-z patch 0002 calls it). `omniplay_media.rb`
    /// when media was converted before launch (AppModel+Media), mapping the old names, with
    /// or without extension, onto the converted files.
    /// `omniplay_translate.rb` when a translation pack's MTool dictionary is active (`translation`, an absolute path).
    static func install(in managed: URL, mediaRemap json: String?, translation: String? = nil) throws -> [URL] {
        var scripts: [URL] = []
        for name in ["omniplay_saves", "omniplay_bridge"] {
            guard let bundled = Bundle.module.url(forResource: name, withExtension: "rb", subdirectory: "Ruby") else { continue }
            let copy = managed.appending(path: "\(name).rb")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: bundled, to: copy)
            scripts.append(copy)
        }
        if let data = json?.data(using: .utf8),
           let remap = try? JSONDecoder().decode([String: String].self, from: data), !remap.isEmpty,
           let template = Bundle.module.url(forResource: "omniplay_media", withExtension: "rb", subdirectory: "Ruby"),
           let source = try? String(contentsOf: template, encoding: .utf8) {
            let script = managed.appending(path: "omniplay_media.rb")
            try source.replacingOccurrences(of: "__TABLE__", with: rubyTable(remap)).write(to: script, atomically: true, encoding: .utf8)
            scripts.append(script)
        }
        if let translation, let template = Bundle.module.url(forResource: "omniplay_translate", withExtension: "rb", subdirectory: "Ruby"),
           let source = try? String(contentsOf: template, encoding: .utf8) {
            let script = managed.appending(path: "omniplay_translate.rb")
            try source.replacingOccurrences(of: "__DICTIONARY__", with: escaped(translation)).write(
                to: script,
                atomically: true,
                encoding: .utf8
            )
            scripts.append(script)
        }
        return scripts
    }

    /// A Ruby hash literal for `omniplay_media.rb`: each source by its full name and by its name without extension
    /// (how RGSS scripts usually refer to files), both lower-cased, to the converted file.
    static func rubyTable(_ remap: [String: String]) -> String {
        func literal(_ s: String) -> String { "\"" + escaped(s) + "\"" }
        var entries: [String: String] = [:]
        for (source, output) in remap {
            entries[source] = output
            if let dot = source.lastIndex(of: "."), !source[dot...].contains("/"), entries[String(source[..<dot])] == nil {
                entries[String(source[..<dot])] = output
            }
        }
        let pairs = entries.sorted { $0.key < $1.key }.map { "\(literal($0.key)) => \(literal($0.value))" }
        return "{" + pairs.joined(separator: ", ") + "}"
    }

    /// The inside of a double-quoted Ruby string: backslash, quote and `#` (interpolation) escaped.
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "#", with: "\\#")
    }
}
