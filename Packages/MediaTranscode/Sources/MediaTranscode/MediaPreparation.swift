import Foundation
import GameCore
import ImageIO
import MediaCompat
import UniformTypeIdentifiers

/// Makes a game's media playable by its engine before it runs: every file the engine cannot decode is converted
/// once into the game's Generated layer, under the same path with the target's extension (`MediaRules`). Engines
/// read Generated ahead of the original, and each runtime maps the original name onto the converted file where the
/// game asks for it by its old extension (`remap`).
///
/// A marker in Generated remembers the plan per engine and rules version, so a later launch neither scans the game
/// again nor redoes a conversion that already exists.
public enum MediaPreparation {
    /// Bumped whenever `MediaRules` changes what it converts.
    public static let rulesVersion = 8

    public struct Conversion: Codable, Sendable, Hashable {
        /// Relative to the game root, as the game names it.
        public let source: String
        /// Relative to the Generated root.
        public let output: String
        public let target: ConversionTarget
    }

    public struct Plan: Codable, Sendable {
        public var version: Int
        public var engine: MediaEngine
        public var conversions: [Conversion]
        /// Files the engine cannot play that ship beside a form it can (intro.mkv beside intro.mp4): the old name is
        /// served from the sibling, nothing is converted. Game-relative.
        public var aliases: [String: String]
        /// Sources that could not be converted, with the reason; kept so they are not retried on every launch.
        public var failed: [String: String]
    }

    public struct Progress: Sendable {
        public let index: Int
        public let count: Int
        public let file: String
        /// Of the current file; -1 when its length is unknown.
        public let fraction: Double
        /// Waiting for the phone to cool down before the next file.
        public var cooling = false
    }

    /// Seconds between checks while the phone is too hot to convert.
    static let coolingPoll: TimeInterval = 5

    static let markerName = ".omniplay-media.json"

    /// The plan for this engine: from the marker when it is current, else by scanning the game.
    public static func plan(gameRoot: URL, generatedRoot: URL, engine: MediaEngine) -> Plan {
        let marker = generatedRoot.appending(path: markerName)
        let old = (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
        if let old, old.version == rulesVersion, old.engine == engine {
            return old
        }
        let (conversions, aliases) = scan(gameRoot: gameRoot, engine: engine)
        // Outputs the new rules no longer ask for would only take space.
        let kept = Set(conversions.map(\.output))
        for c in old?.conversions ?? [] where !Task.isCancelled && !kept.contains(c.output) {
            try? FileManager.default.removeItem(at: generatedRoot.appending(path: c.output))
        }
        let plan = Plan(version: rulesVersion, engine: engine, conversions: conversions, aliases: aliases, failed: [:])
        // Saved here, not only by `run`: a game with nothing to convert never reaches `run` and would be scanned again
        // on every launch. An interrupted scan is incomplete and is not saved.
        if !Task.isCancelled {
            save(plan, generatedRoot: generatedRoot)
        }
        return plan
    }

    /// Conversions whose output does not exist yet (and that have not failed before).
    public static func pending(_ plan: Plan, generatedRoot: URL) -> [Conversion] {
        plan.conversions.filter {
            plan.failed[$0.source] == nil && !FileManager.default
                .fileExists(atPath: generatedRoot.appending(path: $0.output).path(percentEncoded: false))
        }
    }

    /// Runs every pending conversion, one at a time, and saves the plan. Call off the main actor. `progress` returns
    /// false to stop; what is finished stays.
    @discardableResult
    public static func run(
        _ plan: Plan,
        gameRoot: URL,
        generatedRoot: URL,
        progress: @escaping @Sendable (Progress) -> Bool = { _ in true }
    ) -> Plan {
        var plan = plan
        // Failed this run but may pass on another (no space, a lost hardware session): reported now, retried next launch.
        var retry: [String] = []
        let todo = pending(plan, generatedRoot: generatedRoot)
        var stopped = false
        for (i, conversion) in todo.enumerated() where !stopped {
            guard !Task.isCancelled,
                  progress(Progress(index: i, count: todo.count, file: conversion.source, fraction: 0)) else { break }
            // A critical phone waits; a hot one converts smaller and rests between files (MEDIA-004).
            while ProcessInfo.processInfo.thermalState == .critical, !stopped {
                stopped = Task.isCancelled
                    || !progress(Progress(index: i, count: todo.count, file: conversion.source, fraction: -1, cooling: true))
                if !stopped {
                    Thread.sleep(forTimeInterval: coolingPoll)
                }
            }
            if stopped {
                break
            }
            var spec = spec(for: conversion.target, engine: plan.engine)
            if ProcessInfo.processInfo.thermalState == .serious {
                Thread.sleep(forTimeInterval: 2)
                spec = spec.cooler
            }
            let input = gameRoot.appending(path: conversion.source)
            let output = generatedRoot.appending(path: conversion.output)
            // The output can reach twice the source (VP9 to H.264); past the storage reserve, nothing more is converted.
            let size = Int64((try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if case .insufficient = StorageBudget.check(.init(required: size * 2, reason: "convert media"), at: generatedRoot) {
                for rest in todo[i...] {
                    plan.failed[rest.source] = "not enough free space"
                    retry.append(rest.source)
                }
                break
            }
            do {
                if conversion.target == .png {
                    try convertImage(input, to: output)
                } else {
                    try MediaTranscoder.transcode(input, to: output, spec: spec) { fraction in
                        let go = progress(Progress(index: i, count: todo.count, file: conversion.source, fraction: fraction))
                        if !go {
                            stopped = true
                        }
                        return go
                    }
                }
                stopped = !progress(Progress(index: i, count: todo.count, file: conversion.source, fraction: 1))
            } catch let failure as MediaTranscoder.Failure where failure.cancelled {
                stopped = true
            } catch {
                plan.failed[conversion.source] = String(describing: error)
                if (error as? MediaTranscoder.Failure)?.permanent != true, (error as? ImageFailure)?.permanent != true {
                    retry.append(conversion.source)
                }
            }
        }
        // An interrupted scan is incomplete and must not become the next launch's cached plan.
        if !Task.isCancelled {
            var saved = plan
            retry.forEach { saved.failed[$0] = nil }
            save(saved, generatedRoot: generatedRoot)
        }
        return plan
    }

    /// The name the game uses (lower-cased, game-relative) → the file to serve instead, as a logical path: a
    /// conversion in Generated or a sibling in the game. Both resolve through the engine's layers.
    public static func remap(_ plan: Plan, generatedRoot: URL) -> [String: String] {
        var map: [String: String] = [:]
        for (source, sibling) in plan.aliases {
            map[source.lowercased()] = sibling
        }
        for c in plan.conversions
            where FileManager.default.fileExists(atPath: generatedRoot.appending(path: c.output).path(percentEncoded: false)) {
            map[c.source.lowercased()] = c.output
        }
        return map
    }

    /// Size and speed per engine: WebKit gets 1080p H.264 through VideoToolbox; Theora is a software codec, so mkxp-z
    /// (whose games run at 640x480 or less) gets 720p at 30 fps and Ren'Py 1080p.
    public static func spec(for target: ConversionTarget, engine: MediaEngine) -> TranscodeSpec {
        switch target {
        case .mp4: TranscodeSpec(target: .mp4H264AAC, maxWidth: 1920, maxHeight: 1080, maxFPS: 60)
        case .m4a: TranscodeSpec(target: .mp4H264AAC)
        case .ogv where engine == .mkxp: TranscodeSpec(target: .ogvTheoraVorbis, maxWidth: 1280, maxHeight: 720, maxFPS: 30)
        case .ogv: TranscodeSpec(target: .ogvTheoraVorbis, maxWidth: 1920, maxHeight: 1080, maxFPS: 60)
        case .ogg, .png: TranscodeSpec(target: .oggVorbis)
        }
    }

    /// Clears recorded failures so the next launch tries those files again.
    public static func retryFailures(generatedRoot: URL) {
        let marker = generatedRoot.appending(path: markerName)
        guard let data = try? Data(contentsOf: marker), var plan = try? JSONDecoder().decode(Plan.self, from: data) else { return }
        plan.failed = [:]
        save(plan, generatedRoot: generatedRoot)
    }

    // MARK: Scanning

    static func scan(gameRoot: URL, engine: MediaEngine) -> (conversions: [Conversion], aliases: [String: String]) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: gameRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], [:]) }
        let base = gameRoot.standardizedFileURL.path(percentEncoded: false)
        var found: [Conversion] = []
        var aliases: [String: String] = [:]
        var siblingsByDirectory: [URL: [String: String]] = [:]
        for case let url as URL in walker {
            if Task.isCancelled {
                break
            }
            autoreleasepool {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let kind = MediaRules.kind(of: url.lastPathComponent) else { return }
                var rel = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))
                while rel.hasPrefix("/") {
                    rel.removeFirst()
                }
                let probe = MediaRules.needsProbe(rel, engine: engine) ? MediaProbe.probe(url, relativePath: rel) : nil
                guard let target = MediaRules.conversion(for: rel, engine: engine, probe: probe) else { return }
                // A game that ships a playable form beside the file (intro.webm and intro.mp4) needs nothing.
                let directory = url.deletingLastPathComponent()
                let names = siblingsByDirectory[directory] ?? {
                    // Lower-cased name -> name as on disk; the first listed wins.
                    let listed = Dictionary(
                        ((try? fm.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).map { ($0.lowercased(), $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    siblingsByDirectory[directory] = listed
                    return listed
                }()
                let name = url.lastPathComponent.lowercased()
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                for ext in MediaRules.playableSiblings(for: kind, engine: engine) {
                    let sibling = stem + "." + ext
                    guard sibling != name, let real = names[sibling] else { continue }
                    let siblingProbe = MediaRules.needsProbe(real, engine: engine)
                        ? MediaProbe.probe(directory.appending(path: real), relativePath: real) : nil
                    if MediaRules.conversion(for: real, engine: engine, probe: siblingProbe) == nil {
                        let folder = rel.contains("/") ? String(rel[..<rel.lastIndex(of: "/")!]) + "/" : ""
                        aliases[rel] = folder + real
                        return
                    }
                }
                var output = MediaRules.outputPath(for: rel, target: target)
                // Generated sits in front of the game: an output named like another of its files would replace that
                // file for every read, so it keeps the source's extension too (intro.webm.mp4 beside intro.mp4).
                let outputName = (output as NSString).lastPathComponent.lowercased()
                if outputName != name, names[outputName] != nil {
                    output = rel + "." + target.fileExtension
                }
                found.append(Conversion(source: rel, output: output, target: target))
            }
        }
        // Two sources wanting one output (intro.webm and intro.mkv): the first by name keeps it.
        var taken: Set<String> = []
        found.sort { $0.source < $1.source }
        for i in found.indices where !taken.insert(found[i].output.lowercased()).inserted {
            found[i] = Conversion(
                source: found[i].source,
                output: found[i].source + "." + found[i].target.fileExtension,
                target: found[i].target
            )
        }
        return (found, aliases)
    }

    static func save(_ plan: Plan, generatedRoot: URL) {
        try? FileManager.default.createDirectory(at: generatedRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(plan) {
            try? data.write(to: generatedRoot.appending(path: markerName), options: .atomic)
        }
    }

    // MARK: Images

    public struct ImageFailure: Error, CustomStringConvertible {
        public let description: String
        /// False when writing the PNG failed, which another try may get past.
        public var permanent = true
    }

    /// Larger than any game picture: 8192 × 8192 decodes to 256 MiB, which the phone can still hold beside the engine.
    static let maxImagePixels = 8192 * 8192

    /// The first frame of any image ImageIO reads (WebP, AVIF, HEIC, TIFF, TGA...) as PNG, alpha kept. The size the file
    /// claims is checked before anything is decoded: a damaged header asking for gigabytes must not end the app.
    static func convertImage(_ input: URL, to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw ImageFailure(description: "unreadable image") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= maxImagePixels / height else {
            throw ImageFailure(description: "image size \(width)×\(height) is not plausible")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageFailure(description: "unreadable image") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = output.appendingPathExtension("partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ImageFailure(description: "cannot write PNG", permanent: false) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            throw ImageFailure(description: "cannot write PNG", permanent: false)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }
}
