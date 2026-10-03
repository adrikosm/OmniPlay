import Diagnostics
import Foundation
import GameCore
import GameImport
import GameStore
import GameTools
import OverlayVFS
import SaveKit

/// Mods: staged with the import's own extractor and safety policy, checked against the game, installed as a folder
/// under `Overrides/mods/<id>/` that mirrors the game's root, and composed into the layer list at launch by priority.
/// The game's `Original/` is never touched; disabling a mod is a layer-list change.
extension AppModel {
    enum ModFailure: LocalizedError {
        case refused(String)
        case unsupportedFile(String)

        var errorDescription: String? {
            switch self {
            case let .refused(reason): reason
            case let .unsupportedFile(name): "\(name) cannot be installed on its own; put it in a folder or ZIP laid out like the game."
            }
        }
    }

    func modsRoot(_ game: GameID) -> URL { paths.tier(.overrides, for: game).appending(path: "mods", directoryHint: .isDirectory) }

    func mods(for game: GameID) -> [ModRecord] { (try? store?.mods.fetch(game: game)) ?? [] }

    /// Stages, checks and installs one mod (a ZIP/7z/tar, a folder, or a single script or plugin file). It goes in
    /// enabled, above the mods already there.
    @discardableResult
    func installMod(from source: URL, for game: GameRecord) async throws -> (ModRecord, ModValidation) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let root = modsRoot(game.id)
        let staging = try await stageOverlay(from: source, for: game)
        let fm = FileManager.default
        var installed = false
        defer {
            if !installed {
                try? fm.removeItem(at: staging)
            }
        }
        let engine = game.engine
        // A mod's own plugins.js would replace the game's whole list; its plugins are merged in at launch instead.
        if engine == .rpgMakerMV || engine == .rpgMakerMZ {
            try? fm.removeItem(at: staging.appending(path: "js/plugins.js"))
            try? fm.removeItem(at: staging.appending(path: "www/js/plugins.js"))
        }
        let validation = await Task.detached { ModValidator.validate(root: staging, engine: engine) }.value
        if let refusal = validation.refusal {
            throw ModFailure.refused(refusal)
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: root.appending(path: id, directoryHint: .isDirectory))
        installed = true
        var record = ModRecord(
            id: id, gameId: game.id, name: source.deletingPathExtension().lastPathComponent,
            source: source.lastPathComponent, contentType: validation.contentType.rawValue
        )
        record.priority = (mods(for: game.id).map(\.priority).max() ?? 0) + 1
        record.engineCompatJson = [engine.rawValue]
        record.filesJson = validation.files
        try store?.mods.save(record)
        writeSidecar(record)
        refreshConflicts(game.id)
        OPLog.log(
            .importer,
            .info,
            "mod \(record.name) installed as \(id): \(validation.files.count) files, \(validation.contentType.rawValue)"
        )
        return (record, validation)
    }

    /// Copies or extracts an overlay (mod or translation pack) into `Overrides/.staging-<uuid>/` with the import's own
    /// extractor and safety limits, then lines it up with the game's root. The caller installs or removes it.
    func stageOverlay(from source: URL, for game: GameRecord) async throws -> URL {
        let staging = paths.tier(.overrides, for: game.id).appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let engine = game.engine
        let gameRoot = Self.snapshot(for: game.id, paths: paths).flatMap { snapshot in
            LayerSetBuilder.forGame(snapshot.report.descriptor.withID(game.id), paths: paths).first { $0.tier == .original }?.root
        }
        let gameHasWWW = gameRoot
            .map { FileManager.default.fileExists(atPath: $0.appending(path: "www").path(percentEncoded: false)) } ?? false
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = source.pathExtension.lowercased()
        do {
            try await Task.detached {
                if isDirectory {
                    var bytes: Int64 = 0
                    try LazyDirectoryWalker.walk(root: source, skipHidden: false) { bytes += $0.fileSize; return .continue }
                    try StorageBudget.require(.forCopy(bytes: bytes), at: staging)
                    try FileManager.default.copyItem(at: source, to: staging.appending(path: source.lastPathComponent))
                } else if ["zip", "7z", "tar", "gz", "tgz", "xz", "bz2"].contains(ext) {
                    let extractor = LibArchiveExtractor()
                    try StorageBudget.require(.forArchive(uncompressedSizeHint: extractor.preflight(source).declaredBytes), at: staging)
                    _ = try extractor.extract(source, to: staging)
                } else if let place = ModValidator.placement(forSingleFile: source.lastPathComponent, engine: engine) {
                    let target = staging.appending(path: place)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                } else if ext == "json" {
                    // A lone JSON is an MTool dictionary (translation packs); it keeps its name at the pack's root.
                    try FileManager.default.copyItem(at: source, to: staging.appending(path: source.lastPathComponent))
                } else {
                    throw ModFailure.unsupportedFile(source.lastPathComponent)
                }
                // The import's own audit: a symbolic link (a picked folder can hold one) would be served from outside the game.
                _ = try PostExtractionAudit.run(root: staging, totals: RunningTotals(), sourceBytes: nil)
                try ModValidator.normalise(staging, engine: engine, gameHasWWW: gameHasWWW)
            }.value
        } catch let v as SafetyViolation {
            try? FileManager.default.removeItem(at: staging)
            throw ModFailure.refused("Rejected for safety: \(v.detail)\(v.entryPath.map { " at \($0)" } ?? "").")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// A mod that changes scripts or data changes what a save means: the saves are snapshotted before it is toggled.
    func setModEnabled(_ mod: ModRecord, _ enabled: Bool) async {
        var mod = mod
        await snapshotBeforeModChange(mod)
        mod.enabled = enabled
        try? store?.mods.save(mod)
        writeSidecar(mod)
        refreshConflicts(mod.gameId)
    }

    /// Swaps priority with the neighbour above (`up`) or below.
    func moveMod(_ mod: ModRecord, up: Bool) {
        let list = mods(for: mod.gameId) // highest priority first
        guard let i = list.firstIndex(where: { $0.id == mod.id }) else { return }
        let j = up ? i - 1 : i + 1
        guard list.indices.contains(j) else { return }
        var a = list[i], b = list[j]
        (a.priority, b.priority) = (b.priority, a.priority)
        try? store?.mods.save(a)
        try? store?.mods.save(b)
        refreshConflicts(mod.gameId)
    }

    /// Removed mods are kept for a week in `Overrides/.removed/` (out of every layer), then swept.
    func uninstallMod(_ mod: ModRecord) async {
        await snapshotBeforeModChange(mod)
        let fm = FileManager.default
        let removed = paths.tier(.overrides, for: mod.gameId).appending(path: ".removed", directoryHint: .isDirectory)
        try? fm.createDirectory(at: removed, withIntermediateDirectories: true)
        let stamp = Int(Date.now.timeIntervalSince1970)
        try? fm.moveItem(
            at: modsRoot(mod.gameId).appending(path: mod.id, directoryHint: .isDirectory),
            to: removed.appending(path: "\(mod.id)-\(stamp)")
        )
        for old in (try? fm.contentsOfDirectory(at: removed, includingPropertiesForKeys: nil)) ?? [] {
            if let seconds = old.lastPathComponent.split(separator: "-").last.flatMap({ Int($0) }), stamp - seconds > 7 * 86400 {
                try? fm.removeItem(at: old)
            }
        }
        try? store?.mods.delete(id: mod.id)
        refreshConflicts(mod.gameId)
        OPLog.log(.importer, .info, "mod \(mod.name) (\(mod.id)) removed")
    }

    func modConflicts(for game: GameID) -> [ModConflict] {
        ModConflicts.analyze(mods(for: game).filter(\.enabled).map { .init(id: $0.id, priority: $0.priority, files: $0.filesJson) })
    }

    private func refreshConflicts(_ game: GameID) {
        let conflicts = modConflicts(for: game)
        for var mod in mods(for: game) {
            let mine = conflicts.filter { $0.winner == mod.id || $0.losers.contains(mod.id) }.map(\.path)
            if mine != mod.conflictsJson {
                mod.conflictsJson = mine
                try? store?.mods.save(mod)
            }
        }
    }

    private func snapshotBeforeModChange(_ mod: ModRecord) async {
        guard ModContentType(rawValue: mod.contentType)?.affectsSaves == true else { return }
        let location = SaveLocation.forGame(mod.gameId, paths: paths)
        guard SaveVault.hasContent(location) else { return }
        let hash = Self.snapshot(for: mod.gameId, paths: paths)?.report.descriptor.identityHash ?? mod.gameId.description
        _ = try? await SaveVault.snapshot(location: location, identityHash: hash, reason: .preModBackup)
    }

    private func writeSidecar(_ mod: ModRecord) {
        let url = modsRoot(mod.gameId).appending(path: mod.id).appending(path: "mod.json")
        if let data = try? JSONEncoder().encode(mod) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Launch

    /// The enabled mods as layers, highest priority winning, for `RuntimeConfiguration`.
    func modSublayers(for game: GameID) -> [OverlaySublayer] {
        mods(for: game).filter(\.enabled).map {
            OverlaySublayer(name: "mods/\($0.id)", relativeDirectory: "mods/\($0.id)", priority: $0.priority)
        }
    }

    /// Before a launch: indexes each enabled mod's folder, and for MV/MZ composes `js/plugins.js` in Generated from the
    /// game's own list and the enabled mods' plugins (or removes a composed one no mod needs any more).
    func prepareMods(for descriptor: GameDescriptor, gameRoot: URL) async {
        let enabled = mods(for: descriptor.id).filter(\.enabled)
        let indexURL = paths.game(descriptor.id).appending(path: "index.sqlite")
        let root = modsRoot(descriptor.id)
        let generated = paths.tier(.generated, for: descriptor.id)
        let composeFor = descriptor.engine == .rpgMakerMV || descriptor.engine == .rpgMakerMZ
        await Task.detached {
            // A game shipped in NW.js layout keeps its scripts under `www/`; mods were placed to match.
            let prefix = FileManager.default.fileExists(atPath: gameRoot.appending(path: "www").path(percentEncoded: false)) ? "www/" : ""
            guard let index = try? PathIndex.open(at: indexURL) else { return }
            for mod in enabled {
                try? index.rebuild(layer: "overrides/mods/\(mod.id)", root: root.appending(path: mod.id, directoryHint: .isDirectory))
            }
            guard composeFor else { return }
            let composed = generated.appending(path: prefix + "js/plugins.js")
            let plugins = enabled.sorted { $0.priority < $1.priority }.flatMap { mod in
                mod.filesJson.filter {
                    ModValidator.webRelative($0.lowercased()).hasPrefix("js/plugins/") && $0.lowercased().hasSuffix(".js")
                }.compactMap { rel in
                    let url = root.appending(path: mod.id).appending(path: rel)
                    return (try? String(contentsOf: url, encoding: .utf8)).map {
                        PluginsJSMerger.Plugin(name: ((rel as NSString).lastPathComponent as NSString).deletingPathExtension, source: $0)
                    }
                }
            }
            let ours = (try? String(contentsOf: composed, encoding: .utf8))?.hasPrefix("// Composed by OmniPlay") ?? false
            if plugins.isEmpty {
                guard ours else { return }
                try? FileManager.default.removeItem(at: composed)
            } else {
                guard let original = try? String(contentsOf: gameRoot.appending(path: prefix + "js/plugins.js"), encoding: .utf8),
                      let text = PluginsJSMerger.compose(original: original, plugins: plugins) else {
                    OPLog.log(.importer, .error, "plugins.js could not be composed; mod plugins will not load")
                    return
                }
                try? FileManager.default.createDirectory(at: composed.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: composed, atomically: true, encoding: .utf8)
                OPLog.log(.importer, .info, "plugins.js composed with \(plugins.map(\.name))")
            }
            try? index.rebuild(layer: "generated", root: generated)
        }.value
    }
}

// MARK: - Ren'Py script inserts (RENPY-009)

extension AppModel {
    static let insertSource = ".insert"

    /// A snippet of the player's own Ren'Py code, installed as a mod (`game/zz_insert_<name>.rpy`), so it layers, orders
    /// and switches off like any other. Plain Python lines are wrapped in `init 999 python:`; anything starting with a
    /// Ren'Py statement is kept as written.
    @discardableResult
    func installInsert(named name: String, code: String, for game: GameRecord) async throws -> ModRecord {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }
        let file = FileManager.default.temporaryDirectory.appending(path: "zz_insert_\(slug.isEmpty ? "snippet" : slug).rpy")
        let statements = ["init", "label", "define", "default", "screen", "image", "transform", "style", "python", "translate", "#"]
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = statements.contains { trimmed.hasPrefix($0) } ? trimmed
            : "init 999 python:\n" + trimmed.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
            .joined(separator: "\n")
        try ("# OmniPlay script insert: \(name)\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var (record, _) = try await installMod(from: file, for: game)
        record.name = name
        record.source = Self.insertSource
        try? store?.mods.save(record)
        return record
    }

    /// The error that switched an insert off, when one did.
    func insertError(_ mod: ModRecord) -> String? { hint("modError.\(mod.id)", for: mod.gameId) }

    /// After a Ren'Py session: an enabled insert that Ren'Py's `errors.txt` or `traceback.txt` names is switched off,
    /// and the lines naming it are kept for the Mods and Ren'Py Tools screens. The rest of the game is left alone.
    func disableFailedInserts(game: GameID, logDirectory: URL) async {
        var report = ""
        for name in ["errors.txt", "traceback.txt"] {
            let url = logDirectory.appending(path: name)
            if let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 256 << 10) {
                try? handle.close()
                // A bounded native log may end mid-codepoint; preserve the readable prefix and error evidence.
                // swiftlint:disable:next optional_data_string_conversion
                report += String(decoding: data, as: UTF8.self) + "\n"
            }
        }
        guard !report.isEmpty else { return }
        for mod in mods(for: game) where mod.enabled && mod.source == Self.insertSource {
            let files = mod.filesJson.map { ($0 as NSString).lastPathComponent }
            let lines = report.split(separator: "\n").filter { line in files.contains { line.contains($0) } }
            guard !lines.isEmpty else { continue }
            let context = report.split(separator: "\n").drop { line in !files.contains { line.contains($0) } }.prefix(6)
            await setModEnabled(mod, false)
            remember(hint: "modError.\(mod.id)", value: context.joined(separator: "\n"), for: game)
            OPLog.log(.python, .error, "insert \(mod.name) switched off after a Ren'Py error: \(lines.first ?? "")")
        }
    }
}

#if DEBUG
    extension AppModel {
        /// `--debug-install-mod <path>[,<path>]` installs through `installMod`; `--debug-mods off|on` switches every mod
        /// of the first game through `setModEnabled`. Scripted mod runs only.
        func debugMods(_ game: GameRecord) async {
            for path in DebugLaunch.value(for: "--debug-install-mod")?.split(separator: ",") ?? [] {
                do {
                    let (record, validation) = try await installMod(from: URL(filePath: String(path)), for: game)
                    OPLog.log(
                        .importer,
                        .info,
                        """
                        MODPROBE installed \(record.name): \(validation.contentType.rawValue) \(validation.files) \
                        plugins=\(validation.plugins)
                        """
                    )
                } catch {
                    OPLog.log(.importer, .info, "MODPROBE refused \(path): \(error.localizedDescription)")
                }
            }
            // `--debug-install-translation <path>[,<path>]` installs through installTranslation.
            for path in DebugLaunch.value(for: "--debug-install-translation")?.split(separator: ",") ?? [] {
                do {
                    let (pack, detection) = try await installTranslation(from: URL(filePath: String(path)), for: game)
                    OPLog.log(
                        .importer,
                        .info,
                        """
                        MODPROBE translation \(pack.name): \(detection.format.rawValue) language=\(detection.language) \
                        entries=\(detection.entries) dictionary=\(detection.dictionary ?? "-")
                        """
                    )
                } catch {
                    OPLog.log(.importer, .info, "MODPROBE translation refused \(path): \(error.localizedDescription)")
                }
            }
            if let state = DebugLaunch.value(for: "--debug-translations") {
                for pack in translationPacks(for: game.id) {
                    setTranslationEnabled(pack, state == "on")
                }
            }
            // `--debug-insert "name|code"` adds a script insert through installInsert.
            if let spec = DebugLaunch.value(for: "--debug-insert"), let bar = spec.firstIndex(of: "|") {
                let name = String(spec[..<bar]), code = String(spec[spec.index(after: bar)...]).replacingOccurrences(of: "\\n", with: "\n")
                do {
                    let record = try await installInsert(named: name, code: code, for: game)
                    OPLog.log(.importer, .info, "MODPROBE insert \(record.name) as \(record.filesJson)")
                } catch {
                    OPLog.log(.importer, .info, "MODPROBE insert refused: \(error.localizedDescription)")
                }
            }
            // `--debug-check-inserts`: the post-session insert check, run on the game's latest session logs.
            if DebugLaunch.value(for: "--debug-check-inserts") != nil || ProcessInfo.processInfo.arguments
                .contains("--debug-check-inserts") {
                let sessions = (try? FileManager.default.contentsOfDirectory(
                    at: paths.logsRoot().appending(path: game.id.description), includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? []
                if let latest = sessions.max(by: {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }) {
                    await disableFailedInserts(game: game.id, logDirectory: latest)
                }
                let inserts = mods(for: game.id).filter { $0.source == Self.insertSource }
                    .map { "\($0.name)=\($0.enabled) error=\(insertError($0)?.prefix(120) ?? "-")" }
                OPLog.log(.importer, .info, "MODPROBE inserts after check: \(inserts)")
            }
            if let state = DebugLaunch.value(for: "--debug-mods") {
                for mod in mods(for: game.id) {
                    await setModEnabled(mod, state == "on")
                }
                OPLog.log(.importer, .info, "MODPROBE mods \(state): \(mods(for: game.id).map { "\($0.name)=\($0.enabled)" })")
            }
        }
    }
#endif
