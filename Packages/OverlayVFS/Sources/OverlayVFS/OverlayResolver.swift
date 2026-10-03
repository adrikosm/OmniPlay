import Diagnostics
import Foundation
import GameCore

/// One directory that participates in the union. Higher priority wins.
public struct OverlayLayer: Sendable, Hashable {
    public let tier: ContentTier
    public let root: URL
    /// Index namespace, e.g. `original`, `generated`, `overrides/mods/<id>`, `rtp`.
    public let name: String
    public let priority: Int

    public init(tier: ContentTier, root: URL, name: String, priority: Int) {
        self.tier = tier
        self.root = root
        self.name = name
        self.priority = priority
    }
}

public struct Resolution: Sendable, Hashable {
    public let url: URL
    public let layer: OverlayLayer
    public let size: Int64
    public let isDirectory: Bool
    /// The logical name as stored on disk (original case).
    public let realRelativePath: String

    init(layer: OverlayLayer, entry: IndexedEntry) {
        url = layer.root.appending(path: entry.realRel)
        self.layer = layer
        size = entry.size
        isDirectory = entry.isDir
        realRelativePath = entry.realRel
    }
}

/// Validation for logical paths coming from engines and the local server.
public enum PathPolicy {
    /// Returns the lookup key, or nil for `..`, absolute, NUL or control-character paths.
    public static func validateLogical(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return nil }
        guard path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return PathKey.normalize(parts.joined(separator: "/"))
    }
}

public enum OverlayError: Error, Equatable, Sendable {
    case invalidPath(String)
    case readOnlyTier(ContentTier)
    case noLayer(ContentTier)
}

/// The logical union `Overrides/* → Generated/ → Original/ → RTP/`. iOS has no filesystem overlay, so the
/// union is resolved here through the case-insensitive index: one lookup across the layers, the first in priority order wins.
public struct OverlayResolver: Sendable {
    public let layers: [OverlayLayer]
    public let index: PathIndex
    /// Per-session logical → logical redirects (normalized keys), consulted before any tier. One hop only.
    public let aliases: [String: String]

    public init(layers: [OverlayLayer], index: PathIndex, aliases: [String: String] = [:]) {
        self.layers = layers.sorted { $0.priority > $1.priority }
        self.index = index
        var normalized: [String: String] = [:]
        for (from, to) in aliases {
            if let f = PathPolicy.validateLogical(from), let t = PathPolicy.validateLogical(to), f != t {
                normalized[f] = t
            }
        }
        self.aliases = normalized
    }

    public func resolve(_ logicalPath: String) -> Resolution? {
        guard var key = PathPolicy.validateLogical(logicalPath) else {
            OPLog.log(.filesystem, .debug, "rejected logical path \(logicalPath)")
            return nil
        }
        if let target = aliases[key] {
            key = target
        }
        let found = (try? index.lookup(layers: layers.map(\.name), key: key)) ?? []
        for layer in layers {
            if let e = found.first(where: { $0.layer == layer.name }) {
                return Resolution(layer: layer, entry: e)
            }
        }
        return nil
    }

    /// Direct children of a logical directory merged across layers; a higher-priority layer shadows lower ones.
    /// Pages of 500 indexed rows per layer; only the set of keys already emitted is held.
    public func list(directory: String) -> AsyncStream<Resolution> {
        let key = directory.isEmpty ? "" : PathPolicy.validateLogical(directory)
        return AsyncStream { continuation in
            guard let key else { continuation.finish(); return }
            var seen = Set<String>()
            for layer in layers {
                var offset = 0
                while true {
                    guard let page = try? index.children(layer: layer.name, directoryKey: key, limit: PathIndex.batchSize, offset: offset),
                          !page.isEmpty else { break }
                    for e in page where !seen.contains(e.key) {
                        seen.insert(e.key)
                        continuation.yield(Resolution(layer: layer, entry: e))
                    }
                    offset += page.count
                }
            }
            continuation.finish()
        }
    }

    /// A URL the caller may write. Only `overrides`, `generated` and `saves` layers are writable; `Original/` never is.
    /// The entry is indexed immediately so later resolves see it.
    public func writableURL(_ logicalPath: String, in tier: ContentTier, layerName: String? = nil) throws -> URL {
        guard [.overrides, .generated, .saves].contains(tier) else { throw OverlayError.readOnlyTier(tier) }
        guard PathPolicy.validateLogical(logicalPath) != nil else { throw OverlayError.invalidPath(logicalPath) }
        guard let layer = layers.first(where: { $0.tier == tier && (layerName == nil || $0.name == layerName) })
        else { throw OverlayError.noLayer(tier) }
        let rel = logicalPath.replacingOccurrences(of: "\\", with: "/")
        let url = layer.root.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try index.upsert(layer: layer.name, relativePath: rel, isDirectory: false, size: size)
        return url
    }

    /// Index every layer that exists on disk.
    public func indexAll() throws {
        for layer in layers where FileManager.default.fileExists(atPath: layer.root.path(percentEncoded: false)) {
            try index.rebuild(layer: layer.name, root: layer.root)
        }
    }
}

/// An enabled sub-layer under `Overrides/` (a mod or translation pack). Higher priority wins inside Overrides.
public struct OverlaySublayer: Sendable, Hashable {
    public let name: String
    public let relativeDirectory: String
    public let priority: Int

    public init(name: String, relativeDirectory: String, priority: Int) {
        self.name = name
        self.relativeDirectory = relativeDirectory
        self.priority = priority
    }
}

public enum LayerSetBuilder {
    public static let hostShimPriority = 2000
    public static let generatedPriority = 300
    public static let originalPriority = 200
    public static let rtpPriority = 100

    /// Default layers for a game: host shims, enabled overlays by priority, Generated, Original, RTP when the engine uses one.
    public static func forGame(_ descriptor: GameDescriptor, paths: AppPaths, enabledOverlays: [OverlaySublayer] = []) -> [OverlayLayer] {
        let overrides = paths.tier(.overrides, for: descriptor.id)
        var layers = [OverlayLayer(
            tier: .overrides,
            root: paths.path(for: .hostShim, game: descriptor.id),
            name: "overrides/host",
            priority: hostShimPriority
        )]
        layers += enabledOverlays.map {
            OverlayLayer(
                tier: .overrides,
                root: overrides.appending(path: $0.relativeDirectory),
                name: "overrides/\($0.name)",
                priority: 1000 + $0.priority
            )
        }
        layers.append(OverlayLayer(
            tier: .generated,
            root: paths.tier(.generated, for: descriptor.id),
            name: "generated",
            priority: generatedPriority
        ))
        let originalRoot = paths.tier(.original, for: descriptor.id)
        let gameRoot = descriptor.rootRelativePath.isEmpty ? originalRoot : originalRoot.appending(
            path: descriptor.rootRelativePath,
            directoryHint: .isDirectory
        )
        layers.append(OverlayLayer(tier: .original, root: gameRoot, name: "original", priority: originalPriority))
        if let rtp = rtpFamily(for: descriptor.engine) {
            layers.append(OverlayLayer(tier: .rtp, root: paths.rtp(rtp), name: "rtp", priority: rtpPriority))
        }
        return layers
    }

    public static func rtpFamily(for engine: EngineFamily) -> RTPFamily? {
        switch engine {
        case .rpgMakerXP: .xp
        case .rpgMakerVX: .vx
        case .rpgMakerVXAce: .vxAce
        case .rpgMaker2000: .rpg2000
        case .rpgMaker2003: .rpg2003
        default: nil
        }
    }
}
