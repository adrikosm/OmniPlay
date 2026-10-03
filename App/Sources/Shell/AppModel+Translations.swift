import Diagnostics
import Foundation
import GameCore
import GameStore
import GameTools
import OverlayVFS

/// Translation packs: staged like mods, recognised by format, installed under `Overrides/translations/<id>/`, and
/// layered below mods (a mod wins over a pack where both replace a file). One pack per language is active at a time;
/// every MTool dictionary counts as one language slot. At launch the runtime is told which dictionary and which Ren'Py
/// language to use.
extension AppModel {
    func translationsRoot(_ game: GameID) -> URL {
        paths.tier(.overrides, for: game).appending(path: "translations", directoryHint: .isDirectory)
    }

    func translationPacks(for game: GameID) -> [TranslationPackRecord] { (try? store?.translations.fetch(game: game)) ?? [] }

    @discardableResult
    func installTranslation(from source: URL, for game: GameRecord) async throws -> (TranslationPackRecord, TranslationDetection) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let staging = try await stageOverlay(from: source, for: game)
        var installed = false
        defer {
            if !installed {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        let engine = game.engine
        let validation = await Task.detached { ModValidator.validate(root: staging, engine: engine) }.value
        if let binary = validation.nativeBinaries.first {
            throw ModFailure.refused("It contains a program for another platform (\(binary)); packs can only replace game files.")
        }
        let original = detectedOriginal(for: game.id) ?? paths.tier(.original, for: game.id)
        let detection = await Task.detached {
            TranslationFormatDetector.detect(root: staging, files: validation.files, engine: engine) { rel in
                FileManager.default.fileExists(atPath: original.appending(path: rel).path(percentEncoded: false))
            }
        }.value
        if let refusal = detection.refusal {
            throw ModFailure.refused(refusal)
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let root = translationsRoot(game.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: root.appending(path: id, directoryHint: .isDirectory))
        installed = true
        var record = TranslationPackRecord(
            id: id, gameId: game.id, name: source.deletingPathExtension().lastPathComponent, source: source.lastPathComponent,
            contentType: detection.dictionary ?? "", format: detection.format.rawValue, language: detection.language
        )
        record.priority = (translationPacks(for: game.id).map(\.priority).max() ?? 0) + 1
        record.engineCompatJson = [engine.rawValue]
        record.filesJson = validation.files
        try store?.translations.save(record)
        activate(record) // the newest pack of its language is the one in use
        OPLog.log(
            .importer,
            .info,
            "translation \(record.name) installed as \(id): \(detection.format.rawValue) \(detection.language) \(detection.entries) entries"
        )
        return (record, detection)
    }

    /// Turns a pack on and every other pack of the same language off.
    func activate(_ pack: TranslationPackRecord) {
        for var other in translationPacks(for: pack.gameId) where other.id != pack.id && other.language == pack.language && other.enabled {
            other.enabled = false
            try? store?.translations.save(other)
        }
        var pack = pack
        pack.enabled = true
        try? store?.translations.save(pack)
    }

    func setTranslationEnabled(_ pack: TranslationPackRecord, _ enabled: Bool) {
        if enabled {
            activate(pack)
        } else {
            var pack = pack
            pack.enabled = false
            try? store?.translations.save(pack)
        }
    }

    func removeTranslation(_ pack: TranslationPackRecord) {
        try? FileManager.default.removeItem(at: translationsRoot(pack.gameId).appending(path: pack.id, directoryHint: .isDirectory))
        try? store?.translations.delete(id: pack.id)
    }

    /// Files an enabled pack and an enabled mod both replace; the mod wins.
    func translationConflicts(for game: GameID) -> [ModConflict] {
        let mods = mods(for: game).filter(\.enabled)
            .map { ModConflicts.Input(id: $0.id, priority: 1000 + $0.priority, files: $0.filesJson) }
        let packs = translationPacks(for: game).filter(\.enabled).map { ModConflicts.Input(
            id: $0.id,
            priority: 500 + $0.priority,
            files: $0.filesJson
        ) }
        return ModConflicts.analyze(mods + packs)
            .filter { conflict in packs.contains { $0.id == conflict.winner || conflict.losers.contains($0.id) } }
    }

    // MARK: Launch

    /// Enabled packs as layers, below every mod (1000+) and above Generated (300).
    func translationSublayers(for game: GameID) -> [OverlaySublayer] {
        translationPacks(for: game).filter(\.enabled).map {
            OverlaySublayer(name: "translations/\($0.id)", relativeDirectory: "translations/\($0.id)", priority: -500 + $0.priority)
        }
    }

    /// Indexes the enabled packs and says which dictionary and language the runtime should use:
    /// `translationDictionary` (the MTool file as the game sees it, for the web page), `translationDictionaryFile`
    /// (its absolute path, for RGSS and Ren'Py) and `translationLanguage` (a Ren'Py `tl/` language).
    func prepareTranslations(for game: GameID, profile: inout CompatibilityProfile) async {
        let enabled = translationPacks(for: game).filter(\.enabled)
        let root = translationsRoot(game)
        let indexURL = paths.game(game).appending(path: "index.sqlite")
        await Task.detached {
            guard let index = try? PathIndex.open(at: indexURL) else { return }
            for pack in enabled {
                try? index.rebuild(
                    layer: "overrides/translations/\(pack.id)",
                    root: root.appending(path: pack.id, directoryHint: .isDirectory)
                )
            }
        }.value
        if let dictionary = enabled.first(where: { $0.format == TranslationFormat.mtoolJSON.rawValue }), !dictionary.contentType.isEmpty {
            profile.overrides["translationDictionary"] = dictionary.contentType
            profile.overrides["translationDictionaryFile"] = root.appending(path: dictionary.id).appending(path: dictionary.contentType)
                .path(percentEncoded: false)
            // A CJK font for engines without glyph fallback; Ren'Py uses it when the dictionary's text is CJK (TRANS-005).
            if let font = Bundle.main.url(forResource: "wqymicrohei", withExtension: "ttf", subdirectory: "Assets.bundle/Fonts") {
                profile.overrides["cjkFontFile"] = font.path(percentEncoded: false)
            }
        }
        if let tl = enabled.first(where: { $0.format == TranslationFormat.renpyTL.rawValue && !$0.language.isEmpty }) {
            profile.overrides["translationLanguage"] = tl.language
        }
    }

    /// TRANS-006: lines the running game's dictionaries miss go to a `LiveTranslator` for the source language chosen in
    /// Translations; its cache lives with the game's persistent data. The page gets the cache on its first miss, when
    /// it is certainly listening.
    func startLiveTranslation(_ descriptor: GameDescriptor) async {
        guard let source = descriptor.profile.overrides["liveTranslation"], !source.isEmpty,
              let host = await coordinator?.liveTranslationHost else { return }
        let translator = LiveTranslator(
            source: Locale.Language(identifier: source),
            cacheFolder: paths.tier(.saves, for: descriptor.id).appending(path: "persistent/translation-cache", directoryHint: .isDirectory)
        ) { [weak host] in host?.deliverTranslations($0) }
        var primed = false
        host.onMissedText = { [weak host] text in
            if !primed {
                primed = true
                host?.deliverTranslations(translator.cached)
            }
            translator.submit(text)
        }
        OPLog.log(.runtime, .info, "live translation from \(source), \(translator.cached.count) cached")
    }
}
