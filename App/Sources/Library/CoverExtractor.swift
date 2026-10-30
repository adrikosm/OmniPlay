import CoreImage
import CryptoKit
import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameImport
import GameStore
import ImageIO
import OverlayVFS
import UniformTypeIdentifiers

/// Derives a library cover from the game's own files: declared title screens, menu backgrounds, icons, pictures.
/// Each source is read through the game's path index (bounded, never the whole game), decoded as a thumbnail and
/// ranked; an icon alone becomes a composed cover. Covers are written to `Artwork/cover-<unique>.jpg`.
enum CoverExtractor {
    static let maxPixels = 1024
    static let maxSourceBytes = 32 << 20
    /// Overrides-ledger key: "1" once the player picked, cropped or removed the cover. Automatic passes leave it alone.
    static let manualKey = "cover.manual"

    /// A picture found in the game, already decoded as a thumbnail of at most `maxPixels`.
    struct Candidate: Identifiable, @unchecked Sendable {
        /// Where it came from, e.g. `www/img/titles1/Castle.rpgmvp` or `Game.exe`.
        let id: String
        let image: CGImage
        /// 1: a cover (short side 256 px or more), 2: an icon (48 to 255 px), 3: the engine's stock icon.
        let tier: Int
        let category: Int
        /// Shown as a composed cover: a square icon filled into the cover shape would lose its sides.
        var isIcon: Bool { tier > 1 || category == 2 }
    }

    /// A file worth decoding: `category` orders sources (0 declared title, 1 menu background, 2 icon, 3 picture,
    /// 4 generic fallback); `declared` sources skip the path filter.
    private struct Source {
        let path: String
        let category: Int
        var declared = false
    }

    // MARK: Player choices

    /// True once the player chose this game's cover (Photos, Files, the crop view, the pause menu) or removed it.
    static func isManual(game id: GameID, store: GameStore) -> Bool {
        (try? store.overrides.get(game: id, key: manualKey)) == "1"
    }

    /// Stores the game's cover (nil removes it and its file) and, for a player's choice, the manual flag.
    static func setCover(_ path: String?, game id: GameID, manual: Bool, store: GameStore, paths: AppPaths) {
        guard var record = try? store.games.fetch(id: id) else { return }
        if path == nil, let old = record.artworkPath {
            try? FileManager.default.removeItem(at: paths.url(forStored: old))
        }
        record.artworkPath = path
        try? store.games.update(record)
        if manual {
            try? store.overrides.set(game: id, key: manualKey, valueJson: "1")
        }
    }

    // MARK: Extraction

    /// Returns the written cover path (relative to the app root), or nil when nothing in the game decodes.
    static func extract(game id: GameID, engine: EngineFamily, rootRelativePath: String, paths: AppPaths) -> String? {
        guard let best = candidates(game: id, engine: engine, rootRelativePath: rootRelativePath, paths: paths, stopAtCover: true).first
        else { return nil }
        let image = best.isIcon ? compose(icon: best.image) : best.image
        guard let image, let path = write(cgImage: image, game: id, paths: paths) else { return nil }
        OPLog.log(.ui, .info, "cover for \(id) from \(best.id)\(best.isIcon ? " (icon, composed)" : "")")
        return path
    }

    /// Every picture worth offering, best first. With `stopAtCover`, scanning ends after the first source category
    /// that gave a cover, which is all `extract` needs. `onEach` sees candidates as they decode, in source order.
    static func candidates(
        game id: GameID,
        engine: EngineFamily,
        rootRelativePath: String,
        paths: AppPaths,
        stopAtCover: Bool = false,
        onEach: ((Candidate) -> Void)? = nil
    ) -> [Candidate] {
        guard let index = try? PathIndex.open(at: paths.game(id).appending(path: "index.sqlite")) else { return [] }
        let original = paths.tier(.original, for: id)
        let root = rootRelativePath.isEmpty ? original : original.appending(path: rootRelativePath, directoryHint: .isDirectory)
        let files = Files(index: index, root: root)
        var found: [Candidate] = [], seen: Set<String> = [], pixels: Set<SHA256Digest> = []
        var coverCategory: Int?
        for source in sources(engine: engine, files: files) where seen.insert(source.path.lowercased()).inserted {
            if Task.isCancelled {
                break
            }
            if stopAtCover, let coverCategory, source.category > coverCategory {
                break
            }
            guard source.declared || !rejected(source.path),
                  let data = files.decodable(source.path), let image = thumbnail(data) else { continue }
            let short = min(image.width, image.height), long = max(image.width, image.height)
            guard short >= 48, Double(long) / Double(short) <= 3.5,
                  let bytes = image.dataProvider?.data as Data?, pixels.insert(SHA256.hash(data: bytes)).inserted else { continue }
            let stock = stockIcons.contains(SHA256.hash(data: data).hexString)
            let candidate = Candidate(id: source.path, image: image, tier: stock ? 3 : short >= 256 ? 1 : 2, category: source.category)
            found.append(candidate)
            onEach?(candidate)
            if candidate.tier == 1, coverCategory == nil {
                coverCategory = source.category
            }
        }
        return found.sorted { ($0.tier, $0.category, -$0.image.width * $0.image.height) < ($1.tier, $1.category, -$1.image.width * $1.image.height) }
    }

    /// Paths that are never cover art: RPG Maker system sheets, tiles, sprites, faces, fonts.
    static func rejected(_ path: String) -> Bool {
        let words = ["iconset", "tile", "window", "font", "battlebacks", "animations", "sv_actors", "sv_enemies", "characters", "faces"]
        return path.lowercased().split(separator: "/").contains { part in words.contains { part.hasPrefix($0) } }
    }

    /// SHA-256 of the bytes handed to the decoder for engines' stock icons, from real files: the RPG Maker MV
    /// default `icon/icon.png`, NW.js's `Game.exe` icon (an MZ build), the Godot 4 and 3 Windows export icons
    /// (`platform/windows/godot.ico`), Godot's `icon.png`, `misc/logo/icon.png` and `main/app_icon.png` (3.6/4.4,
    /// 4.7). They win only when nothing else exists.
    static let stockIcons: Set<String> = [
        "e1875cdc887df7d42c111fc0f013eeb9e986707a86b84114c5ac2cd6b40d6e72",
        "382df7538aaafc68c28c1277af8f37862d3b5e5b215ac21bb8adbb3bc98b8e23",
        "49d3b250037563bc18fb92ddcd57d6cb7f8251244a4c9d9c8de33749b2b8faa0",
        "4cfba7dc3995f235e3356dc52eb20e7fda79c667227b5f71a63468a87c162c3e",
        "cadd1301338fb2910434468448e0bbf43d9b94fdc34eac6b0db12f1e99ac96fe",
        "4c7157447b020ecb1a0cb755fe0569620247bf5def9f7c4409f063ac479509a9",
        "a312e43de46fa2687786b57b61c5e39596614543856dbf75b8072406866ff121",
        "bc626acf7b04ab704d55911d955f83959ee5921c5f3914d89c5bc1d8332159f7",
    ]

    // MARK: Sources per engine

    private static func sources(engine: EngineFamily, files: Files) -> [Source] {
        var out: [Source] = []
        func glob(_ pattern: String, _ category: Int, limit: Int = 8) {
            out += files.glob(pattern, limit: limit).filter(isImageName).map { Source(path: $0, category: category) }
        }
        func declared(_ path: String?, _ category: Int) {
            if let path, let real = files.real(path) {
                out.append(Source(path: real, category: category, declared: true))
            }
        }
        switch engine {
        case .rpgMakerMV, .rpgMakerMZ:
            for www in ["www/", ""] {
                let system = files.json(www + "data/System.json")
                if let title = system?["title1Name"] as? String, !title.isEmpty {
                    for ext in ["png", "rpgmvp", "png_"] {
                        declared("\(www)img/titles1/\(title).\(ext)", 0)
                    }
                }
                glob("\(www)img/titles1/*", 1)
                glob("\(www)img/parallaxes/*", 1, limit: 6)
                declared(www + "icon/icon.png", 2)
                glob("\(www)img/pictures/*", 3)
            }
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            glob("graphics/titles*/*", 1)
            glob("graphics/system/title*", 1)
        case .rpgMaker2000, .rpgMaker2003:
            glob("title/*", 1)
        case .renpy:
            let scripts = ["game/options.rpy", "game/gui.rpy"].compactMap { files.text($0) }.joined(separator: "\n")
            declared(define("gui.main_menu_background", in: scripts).map { "game/" + $0 }, 0)
            glob("game/gui/main_menu.*", 1)
            glob("game/images/*title*", 1)
            glob("game/images/bg*", 1)
            declared("game/presplash.png", 1); declared("game/presplash.jpg", 1)
            declared("game/web-presplash.png", 1); declared("game/web-presplash.jpg", 1)
            declared(define("config.window_icon", in: scripts).map { "game/" + $0 }, 2)
            declared("game/gui/window_icon.png", 2)
            declared("android-icon_foreground.png", 2)
        case .godot:
            out += godotIcon(files)
            glob("icon.png", 4)
        default:
            glob("data/bgimage/title*", 0)
            glob("data/bgimage/*", 1)
        }
        out += webIcons(files)
        // Any engine: the programs' own icons and loose icon files at the top level.
        for name in files.topLevel(ext: "exe").filter({ !GameArt.isHelperProgram($0) }).prefix(4) {
            out.append(Source(path: name, category: 2, declared: true))
        }
        declared("icon.ico", 2)
        out += files.topLevel(ext: "icns").prefix(2).map { Source(path: $0, category: 2, declared: true) }
        // The older generic guesses, last.
        for pattern in ["icon.png", "favicon.png", "icon/icon.png", "*title*.png", "*cover*.png"] {
            glob(pattern, 4, limit: 4)
        }
        return out.sorted { $0.category < $1.category }
    }

    /// `define <name> = "<value>"` in Ren'Py script text.
    private static func define(_ name: String, in text: String) -> String? {
        let pattern = "define\\s+" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// NW.js `package.json`, web manifests (largest icon first), Tauri's `bundle.icon`, the entry page's icon links
    /// and `og:image`.
    private static func webIcons(_ files: Files) -> [Source] {
        var out: [Source] = []
        func add(_ path: String?, _ category: Int) {
            if let path, let real = files.real(path) {
                out.append(Source(path: real, category: category, declared: true))
            }
        }
        for dir in ["", "www/"] {
            if let window = files.json(dir + "package.json")?["window"] as? [String: Any] {
                add((window["icon"] as? String).flatMap { resolve($0, from: dir) }, 2)
            }
            for name in ["manifest.json", "site.webmanifest", "manifest.webmanifest"] {
                let icons = (files.json(dir + name)?["icons"] as? [[String: Any]]) ?? []
                let sized = icons.compactMap { icon -> (String, Int)? in
                    guard let src = icon["src"] as? String else { return nil }
                    let size = (icon["sizes"] as? String)?.split(separator: "x").first.flatMap { Int($0) } ?? 0
                    return (src, size)
                }
                for (src, _) in sized.sorted(by: { $0.1 > $1.1 }).prefix(2) {
                    add(resolve(src, from: dir), 2)
                }
            }
            if let html = files.text(dir + "index.html") {
                for (pattern, category) in [
                    ("<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)", 1),
                    ("<link[^>]+rel=[\"'](?:apple-touch-icon|icon|shortcut icon)[\"'][^>]+href=[\"']([^\"']+)", 2),
                    ("<link[^>]+href=[\"']([^\"']+)[\"'][^>]+rel=[\"'](?:apple-touch-icon|icon|shortcut icon)[\"']", 2),
                ] {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(3) {
                        if let range = Range(match.range(at: 1), in: html) {
                            add(resolve(String(html[range]), from: dir), category)
                        }
                    }
                }
            }
        }
        for config in ["src-tauri/tauri.conf.json", "tauri.conf.json"] {
            let json = files.json(config)
            let icons = ((json?["bundle"] as? [String: Any])?["icon"] as? [String]) ?? []
            for icon in icons.filter({ !$0.hasSuffix(".icns") }).reversed().prefix(2) {
                add(resolve(icon, from: (config as NSString).deletingLastPathComponent + "/"), 2)
            }
        }
        return out
    }

    /// Godot's `application/config/icon`: the file itself, then the texture its `.import` points at, loose first and
    /// then inside the pack (a `.pck`, or the one at the end of a program). Stored as `pack:<path>` sources.
    private static func godotIcon(_ files: Files) -> [Source] {
        guard let pack = files.godotPack() else { return [] }
        var icon = GodotPCKDetector.projectConfig(url: pack.url, packStart: pack.offset)[GodotPCKDetector.iconKey] ?? "res://icon.png"
        if icon.hasPrefix("uid://") {
            icon = GodotPCKDetector.resolveUID(icon, url: pack.url, packStart: pack.offset) ?? ""
        }
        let bare = icon.hasPrefix("res://") ? String(icon.dropFirst(6)) : icon
        guard !bare.isEmpty, !bare.contains("..") else { return [] }
        var out: [Source] = []
        if let real = files.real(bare) {
            out.append(Source(path: real, category: 2, declared: true))
        }
        if let text = files.text(bare + ".import") ?? GodotPCKDetector.packEntry(url: pack.url, packStart: pack.offset, path: bare + ".import", maxBytes: 64 << 10)
            .flatMap({ String(data: $0, encoding: .utf8) }),
            let texture = importedTexture(text) {
            if let real = files.real(texture) {
                out.append(Source(path: real, category: 2, declared: true))
            }
            out.append(Source(path: "pack:" + texture, category: 2, declared: true))
        }
        out.append(Source(path: "pack:" + bare, category: 2, declared: true))
        return out
    }

    /// The `path="res://…"` line of a Godot `.import` file (not a VRAM `path.s3tc=` variant).
    static func importedTexture(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("path=\"res://") {
            let path = line.dropFirst("path=\"res://".count).prefix { $0 != "\"" }
            return path.contains("..") ? nil : String(path)
        }
        return nil
    }

    /// `href` relative to the directory `dir` ("" or "www/"), without query or fragment; nil for remote, data or
    /// escaping URLs.
    static func resolve(_ href: String, from dir: String) -> String? {
        let clean = String(href.prefix { $0 != "?" && $0 != "#" }).removingPercentEncoding ?? href
        guard !clean.isEmpty, !clean.contains(":"), !clean.hasPrefix("//") else { return nil }
        var parts: [Substring] = clean.hasPrefix("/") ? [] : dir.split(separator: "/")
        for part in clean.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if parts.popLast() == nil { return nil }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    private static func isImageName(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "bmp", "gif", "ico", "icns", "rpgmvp", "png_"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The game's files through its path index, every read bounded.
    private struct Files {
        let index: PathIndex
        let root: URL

        func url(_ real: String) -> URL { root.appending(path: real) }

        /// The real spelling of `path`, when the game has that file.
        func real(_ path: String) -> String? {
            guard let entry = try? index.lookup(layer: "original", key: PathKey.normalize(path)), !entry.isDir else { return nil }
            return entry.realRel
        }

        func glob(_ pattern: String, limit: Int) -> [String] {
            ((try? index.glob(layer: "original", pattern: pattern, limit: limit)) ?? []).filter { !$0.isDir }.map(\.realRel)
        }

        /// Files at the top of the game with this extension.
        func topLevel(ext: String) -> [String] {
            ((try? index.children(layer: "original", directoryKey: "")) ?? [])
                .filter { !$0.isDir && ($0.realRel as NSString).pathExtension.lowercased() == ext }.map(\.realRel)
        }

        func data(_ real: String, cap: Int) -> Data? {
            guard let handle = try? FileHandle(forReadingFrom: url(real)) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: cap + 1), data.count <= cap else { return nil }
            return data
        }

        func text(_ path: String) -> String? {
            real(path).flatMap { data($0, cap: 256 << 10) }.flatMap { String(data: $0, encoding: .utf8) }
        }

        func json(_ path: String) -> [String: Any]? {
            guard let real = real(path), var data = data(real, cap: 1 << 20) else { return nil }
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                data = data.dropFirst(3)
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        /// Bytes ImageIO can decode: MV/MZ images decrypted, Godot textures unwrapped, a program's icon extracted.
        func decodable(_ path: String) -> Data? {
            if path.hasPrefix("pack:") {
                guard let pack = godotPack() else { return nil }
                let data = GodotPCKDetector.packEntry(url: pack.url, packStart: pack.offset, path: String(path.dropFirst(5)))
                return data.flatMap { GameArt.godotTexture($0) ?? $0 }
            }
            switch (path as NSString).pathExtension.lowercased() {
            case "exe": return GameArt.peIcon(url(path))
            case "rpgmvp", "png_": return data(path, cap: CoverExtractor.maxSourceBytes).flatMap(GameArt.rpgMakerImage)
            case "stex", "ctex": return data(path, cap: CoverExtractor.maxSourceBytes).flatMap(GameArt.godotTexture)
            default: return data(path, cap: CoverExtractor.maxSourceBytes)
            }
        }

        /// The Godot pack: a top-level `.pck`, else the one at the end of a top-level program.
        func godotPack() -> (url: URL, offset: Int64)? {
            if let pck = topLevel(ext: "pck").first {
                return (url(pck), 0)
            }
            for exe in topLevel(ext: "exe").prefix(4) {
                if case let .godotPCK(offset, _)? = (try? PEOverlayScanner.scan(url(exe)))?.kind {
                    return (url(exe), offset)
                }
            }
            return nil
        }
    }

    // MARK: Pictures

    /// A thumbnail of the frame with the most pixels (an `.ico`'s 256 px image, not its 16 px first frame).
    static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source)
    }

    static func thumbnail(_ source: CGImageSource) -> CGImage? {
        var best = 0, bestArea = -1
        for i in 0 ..< min(CGImageSourceGetCount(source), 64) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let area = ((props?[kCGImagePropertyPixelWidth] as? Int) ?? 0) * ((props?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
            if area > bestArea {
                (best, bestArea) = (i, area)
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary)
    }

    /// A cover from an icon alone: the icon filled and blurred behind, darkened, and the icon itself centred at 256 px
    /// with rounded corners and a soft shadow. Icons of 64 px or less are scaled without smoothing, so pixel art
    /// stays sharp.
    static func compose(icon: CGImage) -> CGImage? {
        let width = 600, height = Int((600 / Theme.coverAspect).rounded())
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1))
        ctx.fill(bounds)
        let fill = max(bounds.width / CGFloat(icon.width), bounds.height / CGFloat(icon.height))
        let filled = CIImage(cgImage: icon)
            .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 40)
        let shift = CGAffineTransform(
            translationX: -(CGFloat(icon.width) * fill - bounds.width) / 2,
            y: -(CGFloat(icon.height) * fill - bounds.height) / 2
        )
        if let blurred = CIContext().createCGImage(filled.transformed(by: shift), from: bounds) {
            ctx.draw(blurred, in: bounds)
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        ctx.fill(bounds)
        let side: CGFloat = 256
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: CGColor(gray: 0, alpha: 0.55))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.interpolationQuality = max(icon.width, icon.height) <= 64 ? .none : .high
        let aspect = CGFloat(icon.width) / CGFloat(icon.height)
        let drawn = aspect >= 1 ? CGSize(width: side * aspect, height: side) : CGSize(width: side, height: side / aspect)
        ctx.draw(icon, in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        return ctx.makeImage()
    }

    // MARK: Writing

    /// Downsamples any image file into `Artwork/cover-<unique>.jpg`; returns nil if it cannot be decoded.
    static func write(source: URL, game id: GameID, paths: AppPaths) -> String? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let image = thumbnail(src) else { return nil }
        return write(cgImage: image, game: id, paths: paths)
    }

    /// Writes `image` as the game's cover. Each cover gets a new name, because the library and the game page reload
    /// a cover only when its stored path changes: a picture written over the same `cover.jpg` kept showing the old
    /// one. Older covers are removed.
    static func write(cgImage picture: CGImage, game id: GameID, paths: AppPaths) -> String? {
        guard picture.width >= 16, picture.height >= 16, let image = opaque(picture) else { return nil }
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

    /// JPEG has no transparency: a see-through picture goes over the canvas colour instead of turning white.
    private static func opaque(_ image: CGImage) -> CGImage? {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else { return image }
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1))
        ctx.fill(bounds)
        ctx.draw(image, in: bounds)
        return ctx.makeImage()
    }

    /// Earlier covers of this game, including the `cover.jpg` older builds wrote.
    private static func removeOlderCovers(in dir: URL, keeping name: String) {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        for item in items where item != name && item.hasPrefix("cover") && item.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: dir.appending(path: item))
        }
    }
}

private extension SHA256Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
