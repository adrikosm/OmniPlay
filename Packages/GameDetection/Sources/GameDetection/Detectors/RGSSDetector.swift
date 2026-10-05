import Foundation
import GameCore

/// RPG Maker XP / VX / VX Ace. Archive magic is the strongest signal; Game.ini and the scripts file confirm the
/// generation; a bundled Ruby 3 DLL or mkxp.json marks an mkxp-z / Essentials-class game.
/// Rules follow Empo's GameProbe (GPLv2+, github.com/mateo-m/empo-app), re-implemented here.
/// ponytail: no Ruby grammar sniff of the scripts archive yet; the generation default picks the Ruby line.
public struct RGSSDetector: Detector {
    public let id = DetectorID.rgss
    public let version = 1
    public init() {}

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        var generation: EngineGeneration?
        var conflict = false

        for (ext, gen, family) in [
            ("rgssad", EngineGeneration.rgss1, EngineFamily.rpgMakerXP),
            ("rgss2a", .rgss2, .rpgMakerVX),
            ("rgss3a", .rgss3, .rpgMakerVXAce),
        ] {
            guard let e = ctx.glob("*.\(ext)", limit: 1).first, let h = ctx.header(e.realRel, bytes: 8), h.count == 8,
                  h.prefix(7) == Data("RGSSAD\0".utf8) else { continue }
            let v = h[h.startIndex + 7]
            let magicOK = (gen == .rgss3) == (v == 3)
            r.add(
                id,
                .magic(path: e.realRel, bytes: "RGSSAD v\(v)"),
                magicOK ? 0.98 : 0.7,
                .fileMagic,
                magicOK ? "\(e.realRel) is an encrypted RGSS archive (version \(v))" :
                    "\(e.realRel) has archive version \(v), unusual for .\(ext)"
            )
            if magicOK {
                generation = gen; r.claimFamily(family, 0.98)
            } else {
                conflict = true; generation = generation ?? gen; r.claimFamily(
                    family,
                    0.7
                )
            }
        }
        readGameIni(ctx, report: &r, generation: &generation, conflict: &conflict)
        for (name, gen) in [
            ("Data/Scripts.rxdata", EngineGeneration.rgss1),
            ("Data/Scripts.rvdata", .rgss2),
            ("Data/Scripts.rvdata2", .rgss3),
        ] where ctx.exists(name) {
            r.add(id, .present(path: name), 0.85, .fileName, "\(name) is the \(Self.family(gen).rawValue) script archive")
            if generation == nil {
                generation = gen; r.claimFamily(Self.family(gen), 0.85)
            }
        }
        guard let generation else { return r }

        var ruby: RubyLine = generation == .rgss3 ? .ruby19 : .ruby18
        if let dll = ctx.glob("*ruby3*.dll", limit: 1).first ?? ctx.glob("*msvcrt-ruby*.dll", limit: 1).first {
            ruby = .ruby31
            r.add(
                id,
                .present(path: dll.realRel),
                0.9,
                .fileName,
                "Ships its own Ruby (\(dll.realRel)); an mkxp-z or Essentials-class game"
            )
            r.partial.profileHints["syntaxTransform"] = "legacy"
        }
        if ctx.exists("mkxp.json") {
            ruby = .ruby31
            r.add(id, .present(path: "mkxp.json"), 0.85, .fileName, "mkxp.json: built for the mkxp-z fork")
            r.partial.profileHints["syntaxTransform"] = "legacy"
        }
        r.partial.generation = generation
        r.partial.saveFamily = .rgssMarshal
        r.partial.exportPlatform = facts.exeNames.isEmpty ? .unknown : .windows
        r.partial.runtimeCandidates = [RuntimeCandidate(
            runtime: .rgss(ruby: ruby),
            confidence: conflict ? 0.6 : 0.95,
            reason: "\(Self.family(generation).rawValue) runs on Ruby \(ruby.rawValue.dropFirst(4))"
        )]
        if ruby != .ruby31 {
            r.partial.runtimeCandidates.append(RuntimeCandidate(
                runtime: .rgss(ruby: .ruby31),
                confidence: 0.4,
                reason: "Ruby 3.1 with legacy syntax transform as a fallback"
            ))
        }
        if conflict {
            r.partial.runtimeCandidates.append(RuntimeCandidate(
                runtime: .rgss(ruby: generation == .rgss3 ? .ruby18 : .ruby19),
                confidence: 0.3,
                reason: "signals disagree on the generation"
            ))
        }
        return r
    }

    /// Game.ini: runtime library, title and RTP name (`ScanContext.iniText` picks the encoding).
    private func readGameIni(
        _ ctx: ScanContext,
        report r: inout DetectorReport,
        generation: inout EngineGeneration?,
        conflict: inout Bool
    ) {
        if let text = ctx.iniText("Game.ini") {
            let fields = Self.iniFields(text)
            if let lib = fields["library"] {
                let gen: EngineGeneration? = lib.uppercased().contains("RGSS1") ? .rgss1 : lib.uppercased().contains("RGSS2") ? .rgss2 : lib
                    .uppercased().contains("RGSS3") ? .rgss3 : nil
                r.add(id, .text(path: "Game.ini", excerpt: lib), 0.9, .fileContent, "Game.ini names the \(lib) runtime")
                if let gen {
                    if let g = generation, g != gen {
                        conflict = true
                    } else {
                        generation = gen
                    }
                    r.claimFamily(Self.family(gen), conflict ? 0.7 : 0.92)
                }
            }
            if let title = fields["title"], !title.isEmpty {
                // Some creators leave the executable's name there (Akumu Oni: "Akumu.exe").
                r.partial.title = title.lowercased().hasSuffix(".exe") && title.count > 4 ? String(title.dropLast(4)) : title
            }
            // Every title menu draws the windowskin first; a game that ships its own characters but not that still
            // reads the rest from the RTP (Crysalis), and the engine stops at the first missing picture.
            let ownsWindowskin = ctx.exists("Graphics/System/Window.png") || ctx.exists("Graphics/Windowskins")
            if let rtp = fields["rtp"] ?? fields["rtp1"], !rtp.isEmpty, !ownsWindowskin {
                r.partial.warnings.append(.rtpRequired(rtp))
                r.add(id, .text(path: "Game.ini", excerpt: rtp), 0.8, .fileContent, "Needs the \(rtp) RTP; its graphics are not bundled")
            }
        }
    }

    static func family(_ g: EngineGeneration) -> EngineFamily { g == .rgss1 ? .rpgMakerXP : g == .rgss2 ? .rpgMakerVX : .rpgMakerVXAce }

    static func iniFields(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
