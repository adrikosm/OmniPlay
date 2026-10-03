import GameCore
import GameStore
import ImageIO
import SwiftUI

/// A cover downsampled through ImageIO to the tile's pixel size. Never decodes a full-size bitmap.
struct CoverImage: View {
    let path: String?
    let engine: EngineFamily
    var maxPixels: CGFloat = 512
    /// Set on shelves and pages: a game without art gets box art made from its title instead of a blank.
    var title: String?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                // Bounded by the tile: the fill-scaled image must never grow the layout.
                Color.clear.overlay(Image(decorative: image, scale: 1).resizable().scaledToFill()).clipped()
            } else {
                CoverPlaceholder(engine: engine, title: title)
            }
        }
        .task(id: path) {
            guard let path else {
                image = nil
                return
            }
            let max = Int(maxPixels)
            // Each cover is written under a new name, so a path never comes back with other pixels.
            let key = "\(max) \(path)" as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            image = nil
            let url = HostSession.shared.paths.url(forStored: path)
            let thumbnail = await Task.detached { Self.thumbnail(url, maxPixels: max) }.value
            guard !Task.isCancelled else { return }
            if let thumbnail {
                Self.cache.setObject(thumbnail, forKey: key)
            }
            image = thumbnail
        }
    }

    /// Decoded tiles, so returning to the library or scrolling back does not decode (and flash) them again.
    private static let cache = NSCache<NSString, CGImage>()

    nonisolated static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A game without a cover: a slate gradient, a little lighter or darker per title so neighbours differ, with the
/// title set in white. Without a title, just the engine glyph.
struct CoverPlaceholder: View {
    let engine: EngineFamily
    var title: String?

    var body: some View {
        let seed = (title ?? "").unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        let lift = Double(seed % 5) * 0.025
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Theme.slateTop, Theme.slateBottom],
                startPoint: UnitPoint(x: 0.3, y: 0),
                endPoint: UnitPoint(x: 0.7, y: 1)
            )
            .brightness(lift)
            Image(systemName: engine.glyph)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(Theme.s3)
            if let title {
                Text(title)
                    .font(.system(.headline, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .padding(Theme.s3)
            }
        }
        .accessibilityHidden(true)
    }
}

extension GameRecord {
    /// "Ren'Py 8.3": the engine and the first parts of its version. Builds carry long version strings
    /// (Ren'Py's 8.5.3.26051504); players know the first two or three parts.
    func engineName(versionParts: Int = 2) -> String {
        guard let version else { return engine.displayName }
        return engine.displayName + " " + version.split(separator: ".").prefix(versionParts).joined(separator: ".")
    }
}

extension EngineFamily {
    /// Friendly name shown to players; version buckets are appended separately.
    var displayName: String {
        switch self {
        case .rpgMakerMV: "RPG Maker MV"
        case .rpgMakerMZ: "RPG Maker MZ"
        case .rpgMakerXP: "RPG Maker XP"
        case .rpgMakerVX: "RPG Maker VX"
        case .rpgMakerVXAce: "RPG Maker VX Ace"
        case .rpgMaker2000: "RPG Maker 2000"
        case .rpgMaker2003: "RPG Maker 2003"
        case .renpy: "Ren'Py"
        case .html5: "HTML5"
        case .godot: "Godot"
        case .scummvm: "ScummVM"
        case .love: "LÖVE"
        case .onscripter: "ONScripter"
        case .tic80: "TIC-80"
        case .flash: "Flash"
        case .unityWeb: "Unity Web"
        case .godotWeb: "Godot Web"
        case .unityNative: "Unity"
        case .unreal: "Unreal Engine"
        case .gameMaker: "GameMaker"
        case .clickteam: "Clickteam Fusion"
        case .bakin: "RPG Developer Bakin"
        case .smileGameBuilder: "Smile Game Builder"
        case .srpgStudio: "SRPG Studio"
        case .pixelGameMakerMV: "Pixel Game Maker MV"
        case .kirikiri: "KiriKiri"
        case .yuris: "YU-RIS"
        case .artemis: "Artemis"
        case .siglus: "SiglusEngine"
        case .unknown: "Unknown engine"
        }
    }

    var glyph: String {
        switch tier {
        case .core: "gamecontroller"
        case .breadth: "puzzlepiece.extension"
        case .opportunistic: "cube"
        case .refused: "questionmark.square.dashed"
        }
    }
}

extension PlayabilityGrade {
    var label: String {
        switch self {
        case .refused: "Unsupported"
        case .loadable: "Needs preparation"
        case .intro, .menu, .ingame: "Partly playable"
        case .playable: "Ready"
        }
    }

    /// Only a game that cannot run is worth colouring; every other state reads in the secondary text colour.
    var tint: Color { self == .refused ? Theme.danger : Theme.textSecondary }
}
