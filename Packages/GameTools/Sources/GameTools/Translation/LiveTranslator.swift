import Diagnostics
import Foundation
import Translation

/// Live machine translation of game text the dictionaries missed (TRANS-006), with Apple's on-device Translation.
/// Engines hand over lines as they are drawn; they are batched (at most 50, a short pause after the last), translated
/// with the language pack already installed on the device, cached per language pair, and handed back. The game shows
/// the original until the translation arrives. Nothing leaves the device: the packs are system assets.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class LiveTranslator {
    public static let batchLimit = 50
    /// English is the only target (user decision, 27 Sep 2026), whatever the device language.
    public static let english = Locale.Language(identifier: "en")
    /// The cache file's ceiling; past it the oldest half is dropped.
    static let cacheLimit = 8 << 20

    private let source: Locale.Language
    private let target: Locale.Language
    private let cacheURL: URL
    private let deliver: @MainActor ([String: String]) -> Void
    private var cache: [String: String] = [:]
    /// Insertion order, for dropping the oldest entries.
    private var order: [String] = []
    private var queued: [String] = []
    private var asked: Set<String> = []
    private var flushing: Task<Void, Never>?
    private var failed = false

    /// `cacheFolder` is the game's persistent data folder; the file is named after the pair, e.g. `ja-en.json`.
    public init(
        source: Locale.Language,
        target: Locale.Language = LiveTranslator.english,
        cacheFolder: URL,
        deliver: @escaping @MainActor ([String: String]) -> Void
    ) {
        self.source = source
        self.target = target
        self.deliver = deliver
        cacheURL = cacheFolder.appending(path: "\(source.minimalIdentifier)-\(target.minimalIdentifier).json")
        load()
    }

    /// Whether the pack for this pair is on the device; the switch is hidden when the pair is unsupported.
    public static func status(
        from source: Locale.Language,
        to target: Locale.Language = LiveTranslator.english
    ) async -> LanguageAvailability
        .Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    /// Everything already translated, for the engine to start with.
    public var cached: [String: String] { cache }

    /// A line the engine could not translate from its dictionaries.
    public func submit(_ text: String) {
        guard !failed, !text.isEmpty, text.count <= 2000, cache[text] == nil, asked.insert(text).inserted else { return }
        queued.append(text)
        if queued.count >= Self.batchLimit {
            flushing?.cancel()
            flushing = Task { await flush() }
        } else if flushing == nil {
            flushing = Task {
                try? await Task.sleep(for: .milliseconds(150))
                await flush()
            }
        }
    }

    private func flush() async {
        defer { flushing = nil }
        while !queued.isEmpty {
            let batch = Array(queued.prefix(Self.batchLimit))
            queued.removeFirst(batch.count)
            do {
                let fresh = try await Self.translate(batch, from: source, to: target)
                remember(fresh)
                deliver(fresh)
            } catch {
                // The pack went missing or the framework refused: live translation stops for this session, and the
                // cache keeps serving what it has.
                failed = true
                queued.removeAll()
                OPLog.log(.runtime, .error, "live translation stopped: \(error)")
                return
            }
        }
    }

    /// Off the main actor, with its own session: the framework's types are not Sendable, so nothing of theirs is kept.
    @concurrent
    private static func translate(
        _ batch: [String],
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> [String: String] {
        let session = TranslationSession(installedSource: source, target: target)
        let responses = try await session.translations(from: batch.map { .init(sourceText: $0, clientIdentifier: $0) })
        var out: [String: String] = [:]
        for response in responses {
            out[response.clientIdentifier ?? response.sourceText] = response.targetText
        }
        return out
    }

    // MARK: Cache

    private func load() {
        guard let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.cacheLimit,
              let data = try? Data(contentsOf: cacheURL),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return }
        for pair in pairs where pair.count == 2 {
            cache[pair[0]] = pair[1]
            order.append(pair[0])
        }
    }

    private func remember(_ fresh: [String: String]) {
        for (key, value) in fresh where cache.updateValue(value, forKey: key) == nil {
            order.append(key)
        }
        var pairs = order.compactMap { key in cache[key].map { [key, $0] } }
        var data = (try? JSONEncoder().encode(pairs)) ?? Data()
        if data.count > Self.cacheLimit {
            let dropped = order.prefix(order.count / 2)
            dropped.forEach { cache[$0] = nil }
            order.removeFirst(dropped.count)
            pairs = order.compactMap { key in cache[key].map { [key, $0] } }
            data = (try? JSONEncoder().encode(pairs)) ?? Data()
        }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
