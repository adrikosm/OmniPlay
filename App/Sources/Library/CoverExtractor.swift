import Diagnostics
import Foundation
import GameCore
import ImageIO
import OverlayVFS
import UniformTypeIdentifiers

/// Derives a library cover from the game's own title art. Candidates are globbed through the game's path index
/// per engine family, decoded as a bounded thumbnail (never the full bitmap) and written to `Artwork/cover-<unique>.jpg`.
enum CoverExtractor {
    static let maxPixels = 1024

    /// Case-insensitive glob patterns in preference order. Later families fall back to a generic icon.
    static func candidates(for engine: EngineFamily) -> [String] {
        switch engine {
        case .rpgMakerMV: [
                "www/img/system/title1.png",
                "www/img/titles1/*.png",
                "img/system/title1.png",
                "img/titles1/*.png",
                "icon/icon.png",
            ]
        case .rpgMakerMZ: ["img/titles1/*.png", "img/system/title1.png", "icon/icon.png"]
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce: [
                "graphics/titles1/*.png",
                "graphics/titles/*.png",
                "graphics/titles/*.jpg",
                "graphics/system/title.png",
            ]
        case .renpy: [
                "game/gui/main_menu.png",
                "game/gui/main_menu.jpg",
                "game/images/*title*.png",
                "game/images/*/*title*.png",
                "game/gui/window_icon.png",
            ]
        case .rpgMaker2000, .rpgMaker2003: ["title/*.png", "title/*.bmp", "title/*.xyz"]
        case .godot, .godotWeb: ["icon.png", "*.png"]
        // Tyrano keeps its title art in data/bgimage; a bare `*title*.png` would find its TITLE role button first.
        default: [
                "data/bgimage/title*.jpg",
                "data/bgimage/title*.png",
                "icon.png",
                "favicon.png",
                "icon/icon.png",
                "*title*.png",
                "*cover*.png",
            ]
        }
    }

    /// Returns the written cover path (relative to the app root), or nil when no candidate decodes.
    static func extract(game id: GameID, engine: EngineFamily, rootRelativePath: String, paths: AppPaths) -> String? {
        let gameRoot = paths.game(id)
        guard let index = try? PathIndex.open(at: gameRoot.appending(path: "index.sqlite")) else { return nil }
        let original = paths.tier(.original, for: id)
        let originalRoot = rootRelativePath.isEmpty ? original : original.appending(path: rootRelativePath, directoryHint: .isDirectory)
        for pattern in candidates(for: engine) {
            for entry in (try? index.glob(layer: "original", pattern: pattern, limit: 8)) ?? [] where !entry.isDir {
                let source = originalRoot.appending(path: entry.realRel)
                if let path = write(source: source, game: id, paths: paths) {
                    OPLog.log(.ui, .info, "cover for \(id) from \(entry.realRel)")
                    return path
                }
            }
        }
        return nil
    }

    /// Downsamples any image file into `Artwork/cover-<unique>.jpg`; returns nil if it cannot be decoded. Each cover
    /// gets a new name, because the library and the game page reload a cover only when its stored path changes: a
    /// picture written over the same `cover.jpg` kept showing the old one. Older covers are removed.
    static func write(source: URL, game id: GameID, paths: AppPaths) -> String? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary), image.width >= 16,
              image.height >= 16 else { return nil }
        let dir = paths.tier(.artwork, for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "cover-\(UUID().uuidString.prefix(8).lowercased()).jpg"
        let out = dir.appending(path: name)
        let temp = dir.appending(path: ".\(name)")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(dest), (try? FileManager.default.moveItem(at: temp, to: out)) != nil else {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        removeOlderCovers(in: dir, keeping: name)
        return paths.stored(out)
    }

    /// Earlier covers of this game, including the `cover.jpg` older builds wrote.
    private static func removeOlderCovers(in dir: URL, keeping name: String) {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        for item in items where item != name && item.hasPrefix("cover") && item.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: dir.appending(path: item))
        }
    }
}
