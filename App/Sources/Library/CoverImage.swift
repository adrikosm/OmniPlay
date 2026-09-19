import GameCore
import ImageIO
import SwiftUI

/// A cover downsampled through ImageIO to the tile's pixel size. Never decodes a full-size bitmap.
struct CoverImage: View {
    let path: String?
    let engine: EngineFamily
    var maxPixels: CGFloat = 512
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                // Bounded by the tile: the fill-scaled image must never grow the layout.
                Color.clear.overlay(Image(decorative: image, scale: 1).resizable().scaledToFill()).clipped()
            } else {
                CoverPlaceholder(engine: engine)
            }
        }
        .task(id: path) {
            guard let path else { image = nil; return }
            let url = HostSession.shared.paths.url(forStored: path)
            let max = Int(maxPixels)
            image = await Task.detached { Self.thumbnail(url, maxPixels: max) }.value
        }
    }

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

/// Engine glyph on a tinted gradient when a game has no cover yet.
struct CoverPlaceholder: View {
    let engine: EngineFamily

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.inkRaised, Theme.ink], startPoint: .top, endPoint: .bottom)
            Image(systemName: engine.glyph)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.lantern.opacity(0.85))
        }
        .accessibilityHidden(true)
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
        case .wolfRPG: "Wolf RPG Editor"
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

    var tint: Color {
        switch self {
        case .refused: Theme.danger
        case .loadable: Theme.textSecondary
        case .intro, .menu, .ingame: Theme.lantern
        case .playable: Color(red: 0.55, green: 0.85, blue: 0.62)
        }
    }
}
