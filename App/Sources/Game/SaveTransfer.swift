import Diagnostics
import Foundation
import GameCore
import GameImport
import SaveKit

/// Moves saves in and out of a game: ZIP export to the Files-visible folder, import of a ZIP, a folder or loose
/// save files. Every imported file is validated first; foreign or wrong-family saves need explicit confirmation.
struct SaveTransfer: Sendable {
    struct Target: Sendable {
        let id: GameID
        let title: String
        let engine: EngineFamily
        let family: SaveFamily
        let slotPattern: String?
        let identityHash: String
        /// The game's own folder (Original plus its root), where MZ's System.json names the game in its storage keys.
        let gameRoot: URL
    }

    enum Collision: Sendable { case replace, nextFreeSlot }

    enum Outcome: Sendable, Equatable {
        case installed(slots: Int, persistent: Int)
        /// Nothing was installed; the caller shows these and retries with `confirmed: true`.
        case needsConfirmation([String])
        case nothingRecognised([String])
    }

    static let saveExtensions: Set<String> = ["rpgsave", "rmmzsave", "rxdata", "rvdata", "rvdata2", "save", "lsd", "webstorage"]

    let paths: AppPaths
    let target: Target
    var location: SaveLocation { SaveLocation.forGame(target.id, paths: paths) }

    /// `Documents/OmniPlay/Saves-Export/<title>-<date>.zip`, visible in Files.
    func export() async throws -> URL {
        try location.ensure()
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: false))
            .replacingOccurrences(
                of: ":",
                with: ""
            )
        let safeTitle = target.title.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted)
            .joined().trimmingCharacters(in: .whitespaces)
        let destination = paths.exportsRoot.appending(path: "\(safeTitle.isEmpty ? "saves" : safeTitle)-\(stamp).zip")
        try FileManager.default.createDirectory(at: paths.exportsRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let staging = location.root.appending(path: ".export-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in ["slots", "persistent"]
            where FileManager.default.fileExists(atPath: location.root.appending(path: name).path(percentEncoded: false)) {
            try await APFSClone.clone(from: location.root.appending(path: name), to: staging.appending(path: name))
        }
        let manifest = try SaveExportManifest(
            engine: target.engine, family: target.family, gameID: target.id, titleHash: target.identityHash, title: target.title,
            entries: SaveExportManifest.entries(for: SaveLocation(savesRoot: staging))
        )
        try ArchiveWriter().zip(directory: staging, to: destination, extras: [(SaveExportManifest.fileName, encoder.encode(manifest))])
        OPLog.log(.save, .info, "exported saves of \(target.title) → \(destination.lastPathComponent)")
        return destination
    }

    /// The import's files under `staging/tree`: a folder copied, a ZIP extracted through the import's safety limits,
    /// or a single file placed as a slot.
    private static func stage(_ source: URL, into staging: URL) throws -> URL {
        let fm = FileManager.default
        let tree = staging.appending(path: "tree")
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isDir)
        if isDir.boolValue {
            try fm.copyItem(at: source, to: tree)
        } else if !saveExtensions.contains(source.pathExtension.lowercased()), (try? ContainerSniffer.identify(source)) == .zip {
            // A Ren'Py `.save` is itself a ZIP; picked on its own it is one save, not an archive of them.
            _ = try LibArchiveExtractor().extract(source, to: tree)
        } else {
            try fm.createDirectory(at: tree.appending(path: "slots"), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: tree.appending(path: "slots/\(source.lastPathComponent)"))
        }
        return tree
    }

    /// Imports from a ZIP, a folder or a single save file. Nothing is written unless every file is recognised and,
    /// when a warning applies, `confirmed` is true.
    func importSaves(from source: URL, collision: Collision, confirmed: Bool) async throws -> Outcome {
        let fm = FileManager.default
        let staging = paths.tier(.importStaging, for: target.id).appending(path: "saves-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tree = try Self.stage(source, into: staging)
        var manifest: SaveExportManifest?
        var slotFiles: [URL] = []
        var persistentFiles: [(URL, String)] = []
        // Ren'Py's `persistent` and `sync/` sit beside the slots: kept at their own path, never renamed into a slot.
        var slotData: [(URL, String)] = []
        try LazyDirectoryWalker.walk(root: tree) { entry in
            guard !entry.isDirectory else { return .continue }
            if entry.url.lastPathComponent == SaveExportManifest.fileName {
                // From an untrusted archive: read within the small-file bound, never whole.
                manifest = (try? SmallFileGuard.read(entry.url, maxBytes: 1 << 20)).flatMap { try? JSONDecoder().decode(
                    SaveExportManifest.self,
                    from: $0
                ) }
            } else if let range = entry.relativePath.range(of: "persistent/") {
                persistentFiles.append((entry.url, String(entry.relativePath[range.upperBound...])))
            } else if let range = entry.relativePath.range(of: "slots/"), !SaveSlots.isSlot(entry.url.lastPathComponent) {
                slotData.append((entry.url, String(entry.relativePath[range.upperBound...])))
            } else if Self.saveExtensions.contains(entry.url.pathExtension.lowercased()) || entry.relativePath.contains("slots/") {
                slotFiles.append(entry.url)
            }
            return .continue
        }
        guard !slotFiles.isEmpty || !persistentFiles.isEmpty || !slotData.isEmpty
        else { return .nothingRecognised(["No save files found in \(source.lastPathComponent)."]) }
        // RPG Maker MV/MZ saves from the PC editions go under the keys the web runtime reads, with their entries in the
        // game's save list (DesktopWebSaves); copied in under their own names they were never found, or stopped the game.
        var desktop = DesktopPlan()
        if let matcher = Self.desktopEdition(for: target.engine, gameID: "") {
            var pc = slotFiles.filter { DesktopWebSaves.name(of: $0.lastPathComponent, edition: matcher) != nil }
            // An OmniPlay export holds the web keys themselves; its save list never replaces the game's own. With slots it
            // takes the PC path, so the list is merged and colliding slots move to free numbers; without, it is left out.
            let webGlobal = persistentFiles.map(\.0).filter { Self.webName(of: $0.lastPathComponent, engine: target.engine) == .global }
            let webSlots = slotFiles.filter { Self.webName(of: $0.lastPathComponent, engine: target.engine) != nil }
            persistentFiles.removeAll { webGlobal.contains($0.0) }
            if !webGlobal.isEmpty, !webSlots.isEmpty {
                pc += webSlots + webGlobal
            }
            if !pc.isEmpty {
                slotFiles.removeAll { pc.contains($0) }
                switch planDesktop(pc, replace: collision == .replace) {
                case let .success(plan): desktop = plan
                case let .failure(refusal): return .nothingRecognised(refusal.reasons)
                }
            }
        }
        let (warnings, refused) = check(slotFiles + slotData.map(\.0), manifest: manifest)
        guard refused.isEmpty else { return .nothingRecognised(refused) }
        if !warnings.isEmpty, !confirmed {
            return .needsConfirmation(Array(Set(warnings)).sorted())
        }

        let existing = Set((try? fm.contentsOfDirectory(atPath: location.slots.path(percentEncoded: false))) ?? [])
        var occupied = existing.union(slotFiles.map(\.lastPathComponent))
        var plan: [(URL, URL)] = []
        for file in slotFiles {
            var name = file.lastPathComponent
            if collision == .nextFreeSlot, existing.contains(name) || plan.contains(where: { $0.1.lastPathComponent == name }) {
                guard let free = SlotNaming.duplicateName(for: name, existing: occupied, pattern: target.slotPattern) else {
                    throw RestoreError.noFreeSlot(name)
                }
                name = free
            }
            occupied.insert(name)
            plan.append((file, location.slots.appending(path: name)))
        }
        var dataCount = persistentFiles.count
        for (file, rel) in slotData {
            let destination = location.slots.appending(path: rel)
            if collision == .nextFreeSlot, fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                continue
            }
            plan.append((file, destination))
            dataCount += 1
        }
        for (file, rel) in persistentFiles {
            plan.append((file, location.persistent.appending(path: rel)))
        }
        try location.ensure()
        let txn = SafePersistTransaction(location: location, identityHash: target.identityHash)
        let (mapping, writes) = (plan, desktop.writes)
        // The snapshot holds the saves from before the import: an ordinary pre-edit backup, pruned like the others.
        try await txn.run(targets: mapping.map(\.1) + writes.map(\.1)) { staging in
            for (file, destination) in mapping {
                let staged = staging.url(for: destination)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: file, to: staged)
            }
            for (data, destination) in writes {
                try data.write(to: staging.url(for: destination), options: .atomic)
            }
        }
        OPLog.log(.save, .info, "imported \(plan.count + writes.count) save files into \(target.title)")
        return .installed(slots: plan.count - dataCount + desktop.slots, persistent: dataCount + desktop.persistent)
    }

    /// Refusals name files that are not saves; warnings name saves from another engine or another game.
    private func check(_ slotFiles: [URL], manifest: SaveExportManifest?) -> (warnings: [String], refused: [String]) {
        var warnings: [String] = []
        var refused: [String] = []
        for file in slotFiles {
            let name = file.lastPathComponent
            let v = SaveValidator.validate(
                file: file,
                family: target.family,
                expectedTitleHash: target.identityHash,
                manifestTitleHash: manifest?.titleHash
            )
            if !v.isAcceptable {
                refused.append("\(name): \(v.warnings.first ?? "unrecognised")"); continue
            }
            if !v.matchesFamily {
                warnings.append("\(name) is a \(v.format.rawValue) save; this game uses \(target.family.rawValue).")
            }
            if case let .foreign(hash) = v.titleMatch {
                warnings.append("\(name) was exported from a different game (\(hash.prefix(12))). Loading it here can misbehave.")
            }
        }
        if let manifest, manifest.titleHash != target.identityHash, !warnings.contains(where: { $0.contains("different game") }) {
            warnings.append("This export came from \"\(manifest.title)\", not from \(target.title).")
        }
        return (warnings, refused)
    }

    // MARK: PC saves of RPG Maker MV/MZ

    struct DesktopPlan {
        var writes: [(Data, URL)] = []
        var slots = 0
        var persistent = 0
    }

    struct Refusal: Error {
        let reasons: [String]
    }

    static func desktopEdition(for engine: EngineFamily, gameID: String) -> DesktopWebSaves.Edition? {
        switch engine {
        case .rpgMakerMV: .mv
        case .rpgMakerMZ: .mz(gameID: gameID)
        default: nil
        }
    }

    /// Reads, checks and places PC saves: every slot must decode as a save and be listed in a `global` file imported
    /// with it; the slots land on their own numbers (or the first free ones) and their entries are merged into the
    /// game's save list. `config` files are left out: they hold the PC's volume and options, not progress.
    func planDesktop(_ files: [URL], replace: Bool) -> Result<DesktopPlan, Refusal> {
        let refuse = { (reason: String) in Result<DesktopPlan, Refusal>.failure(Refusal(reasons: [reason])) }
        let edition: DesktopWebSaves.Edition
        if target.engine == .rpgMakerMZ {
            guard let id = Self.mzGameID(location: location, gameRoot: target.gameRoot) else {
                return refuse("This game's MZ save key could not be found. Start the game once in OmniPlay, then import again.")
            }
            edition = .mz(gameID: id)
        } else {
            edition = .mv
        }
        let globalName = edition == .mv ? "global.rpgsave" : "global.rmmzsave"
        var slots: [Int: Data] = [:]
        var incomingGlobal: [Any]?
        for file in files {
            guard let raw = try? SmallFileGuard.read(file, maxBytes: SaveFileStore.maxBytes),
                  let web = DesktopWebSaves.webBytes(raw, edition: edition) else {
                return refuse(DesktopWebSaves.Failure.notASave(file.lastPathComponent).description)
            }
            switch DesktopWebSaves.name(of: file.lastPathComponent, edition: edition) ?? Self.webName(
                of: file.lastPathComponent,
                engine: target.engine
            ) {
            case let .slot(n)?:
                guard (try? RPGMakerSaveDocument(data: web)) != nil else {
                    return refuse(DesktopWebSaves.Failure.notASave(file.lastPathComponent).description)
                }
                slots[n] = web
            case .global?:
                guard let list = DesktopWebSaves.decodeGlobal(web, edition: edition) else {
                    return refuse(DesktopWebSaves.Failure.notASave(file.lastPathComponent).description)
                }
                incomingGlobal = list
            case .config?, nil:
                continue
            }
        }
        guard !slots.isEmpty else { return refuse("There are no save slots (file1, file2, …) in what was picked.") }
        guard let incomingGlobal else {
            return refuse("Include \(globalName) from the same save folder: the game lists its saves from it.")
        }
        let globalURL = location.root.appending(path: DesktopWebSaves.relativePath(.global, edition: edition))
        var existingGlobal: [Any]?
        if FileManager.default.fileExists(atPath: globalURL.path(percentEncoded: false)) {
            guard let data = try? SmallFileGuard.read(globalURL, maxBytes: SaveFileStore.maxBytes),
                  let list = DesktopWebSaves.decodeGlobal(data, edition: edition) else {
                return refuse("The game's own save list could not be read, so nothing was imported.")
            }
            existingGlobal = list
        }
        // Taken: a slot file already here, or an entry the game's save list still shows.
        var occupied = Set(((try? FileManager.default.contentsOfDirectory(atPath: location.slots.path(percentEncoded: false))) ?? [])
            .compactMap { name -> Int? in
                let stem = (name as NSString).deletingPathExtension
                return DesktopWebSaves.slotNumber(inKey: SaveKey.decodeWebStorage(stem) ?? stem, edition: edition)
            })
        for (index, entry) in (existingGlobal ?? []).enumerated() where index > 0 && !(entry is NSNull) {
            occupied.insert(index)
        }
        do {
            let moves = try DesktopWebSaves.placements(incoming: Array(slots.keys), occupied: occupied, replace: replace)
            let merged = try DesktopWebSaves.mergeGlobal(existing: existingGlobal, incoming: incomingGlobal, moves: moves)
            var plan = DesktopPlan()
            for (from, to) in moves {
                plan.writes.append((slots[from]!, location.root.appending(path: DesktopWebSaves.relativePath(.slot(to), edition: edition))))
            }
            let globalData = try DesktopWebSaves.encodeGlobal(merged, edition: edition)
            plan.writes.append((globalData, globalURL))
            plan.slots = moves.count
            plan.persistent = 1
            return .success(plan)
        } catch let failure as DesktopWebSaves.Failure {
            return refuse(failure.description)
        } catch {
            return refuse("The save list could not be written: \(error.localizedDescription)")
        }
    }

    /// A slot or the save list under the key the web runtime stores (`ls.<base64 of "RPG File3">.rpgsave`,
    /// `rmmzsave.<id>.global.rmmzsave`), read through the PC name so the same slot bounds apply. Config stays nil.
    static func webName(of fileName: String, engine: EngineFamily) -> DesktopWebSaves.Name? {
        let stem = (fileName as NSString).deletingPathExtension
        let pcStem: String? = switch engine {
        case .rpgMakerMV: SaveKey.decodeWebStorage(stem).flatMap { $0.hasPrefix("RPG ") ? String($0.dropFirst(4)) : nil }
        case .rpgMakerMZ: stem.hasPrefix("rmmzsave.") ? stem.split(separator: ".").last.map(String.init) : nil
        default: nil
        }
        guard let pcStem, let edition = desktopEdition(for: engine, gameID: ""),
              let name = DesktopWebSaves.name(of: pcStem + "." + (fileName as NSString).pathExtension, edition: edition),
              name != .config else { return nil }
        return name
    }

    /// MZ puts `$dataSystem.advanced.gameId` into every storage key: from a key this game already saved under, else
    /// from its System.json (bounded read).
    static func mzGameID(location: SaveLocation, gameRoot: URL) -> String? {
        for folder in [location.slots, location.persistent.appending(path: "webIndexedDB")] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            for name in names where name.hasPrefix("rmmzsave.") {
                let parts = name.split(separator: ".")
                if parts.count >= 3, !parts[1].isEmpty {
                    return String(parts[1])
                }
            }
        }
        for rel in ["data/System.json", "www/data/System.json"] {
            let url = gameRoot.appending(path: rel)
            guard let data = try? SmallFileGuard.read(url),
                  let system = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let advanced = system["advanced"] as? [String: Any],
                  let id = (advanced["gameId"] as? NSNumber)?.int64Value else { continue }
            return String(id)
        }
        return nil
    }
}
