import Foundation
import GameCore

/// Games ScummVM plays: adventure games (SCUMM, SCI, AGI, AGS, Wintermute and the rest of the engines the framework
/// carries) and interactive fiction. ScummVM's own detection (MD5 tables over file headers) is the authority; the
/// signatures here only decide whether a folder is worth asking it about, and stand in when it cannot be asked.
public struct ScummVMDetector: Detector {
    /// What ScummVM's detection said about a folder.
    public struct Identity: Sendable, Equatable {
        public var engineID: String
        public var gameID: String
        public var title: String
        public var language: String
        public var platform: String

        public init(engineID: String, gameID: String, title: String, language: String, platform: String) {
            (self.engineID, self.gameID, self.title, self.language, self.platform) = (engineID, gameID, title, language, platform)
        }
    }

    public enum Answer: Sendable, Equatable {
        case recognised(Identity)
        case unrecognised
        /// ScummVM could not be asked now (busy with a game, or failed to start); the signatures decide.
        case unavailable
    }

    /// ScummVM's detection, set once by the app when its framework is bundled. Without it (tests, a build without
    /// ScummVM) the signatures decide alone.
    public nonisolated(unsafe) static var identify: (@Sendable (URL) -> Answer)?

    public let id = DetectorID.scummvm
    public let version = 1
    public init() {}

    /// File names that mark a data set, lower-case: exact names, then extensions. Interactive fiction is one file.
    static let markerNames: [String: String] = [
        "acsetup.cfg": "ags", "ac2game.dat": "ags",
        "000.lfl": "scumm", "disk01.lec": "scumm",
        "resource.map": "sci", "resmap.000": "sci", "resmap.001": "sci",
        "logdir": "agi", "words.tok": "agi",
        "data.dcp": "wintermute",
        "sky.dnr": "sky", "sky.dsk": "sky",
        "queen.1": "queen", "queen.1c": "queen",
        "disk1.vga": "lure",
        "packet.001": "drascula",
        "dreamweb.r00": "dreamweb",
        "vol.cat": "cge",
        "msn_data.000": "supernova",
        "gamepc": "agos", "simon.gme": "agos",
    ]
    static let markerExtensions: [String: String] = [
        "ags": "ags",
        "z1": "glk", "z2": "glk", "z3": "glk", "z4": "glk", "z5": "glk", "z6": "glk", "z7": "glk", "z8": "glk",
        "zblorb": "glk", "zlb": "glk", "ulx": "glk", "gblorb": "glk", "glb": "glk",
        "000": "scumm", "la0": "scumm", "he0": "scumm", "sm0": "scumm",
    ]
    /// The tail an AGS game's executable carries when its data is appended to it.
    static let agsExeTail = Data("CLIB\u{1}\u{2}\u{3}\u{4}SIGE".utf8)

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        let found = signature(ctx, facts: facts)
        // ScummVM knows far more games than any signature list here. A folder no other family's layout claims is
        // worth asking it about too; one that looks like another engine is not.
        guard found != nil || (Self.identify != nil && facts.markers.isEmpty && facts.indexHTMLCandidates.isEmpty && !facts.hasWWW)
        else { return r }
        let (marker, hint) = found ?? ("", "")
        if found != nil {
            r.add(id, .present(path: marker), 0.7, .fileName, "\(marker) looks like a \(hint) data set")
        }

        switch Self.identify?(ctx.root) ?? .unavailable {
        case .unrecognised where found == nil, .unavailable where found == nil:
            return DetectorReport()
        case .unrecognised:
            r.claimFamily(.scummvm, 0.5)
            r.unsupported = "ScummVM does not recognise this game (\(marker) looked like \(hint) data)."
            return r
        case let .recognised(game):
            r.add(
                id,
                .text(path: marker.isEmpty ? "." : marker, excerpt: "\(game.engineID):\(game.gameID)"),
                0.95,
                .fileContent,
                "ScummVM identifies \(game.title) (\(game.engineID))"
            )
            r.claimFamily(.scummvm, 0.95)
            r.partial.title = game.title
            r.partial.profileHints["scummvm.engineid"] = game.engineID
            r.partial.profileHints["scummvm.gameid"] = game.gameID
            if !game.language.isEmpty {
                r.partial.profileHints["scummvm.language"] = game.language
            }
            if !game.platform.isEmpty {
                r.partial.profileHints["scummvm.platform"] = game.platform
            }
        case .unavailable:
            r.claimFamily(.scummvm, 0.8)
            r.partial.profileHints["scummvm.enginehint"] = hint
        }
        r.partial.saveFamily = .scummvm
        r.partial.runtimeCandidates = [RuntimeCandidate(runtime: .scummvm, confidence: 0.9, reason: "ScummVM plays this game")]
        return r
    }

    private func signature(_ ctx: ScanContext, facts: StructureFacts) -> (String, String)? {
        let top = ctx.children("", limit: 512).filter { !$0.isDir }
            .map { ($0.realRel, ($0.realRel as NSString).lastPathComponent.lowercased()) }
        // Names before extensions: an SCI game's resource.000 is not SCUMM data, its resource.map says so.
        if let (path, name) = top.first(where: { Self.markerNames[$0.1] != nil }) {
            return (path, Self.markerNames[name]!)
        }
        // An extension alone is weak (a web game's `model.glb` is glTF, not Glk): it counts only where no page is.
        if facts.indexHTMLCandidates.isEmpty,
           let (path, name) = top.first(where: { Self.markerExtensions[($0.1 as NSString).pathExtension] != nil }) {
            return (path, Self.markerExtensions[(name as NSString).pathExtension]!)
        }
        for exe in facts.exeNames {
            if let url = ctx.url(exe), Self.hasAGSTail(url) {
                return (exe, "ags")
            }
        }
        return nil
    }

    static func hasAGSTail(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(agsExeTail.count),
              (try? handle.seek(toOffset: size - UInt64(agsExeTail.count))) != nil,
              let tail = try? handle.read(upToCount: agsExeTail.count) else { return false }
        return tail == agsExeTail
    }
}
