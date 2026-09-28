import CMkxpBridge
import Foundation
import GameCore
import OverlayVFS

/// The per-game engine configuration OmniPlay writes for mkxp-z: a managed `mkxp.json` outside the imported
/// tree, plus the values the bridge takes as a struct. Pure, so the JSON can be read without an engine.
///
/// Overlay precedence is the engine's `patches` array, not its `RTP` array. `sharedstate.cpp` mounts
/// `patches` first, then the game archive, then the game folder, then `RTP`; PhysFS reads in mount order, so
/// `patches` is the only list that can outrank `Original/`. `RTP` keeps its own meaning as the bottom tier.
public struct RGSSSessionConfig: Sendable, Hashable {
    public let rgssVersion: Int
    public let ruby: RubyLine
    public let gameFolder: URL
    public let title: String
    /// Overlay roots above the game folder, highest priority first: Overrides/host, mods, translations, Generated.
    public let patches: [URL]
    /// Search roots below the game folder: the imported RTP for this family, when it has one.
    public let rtp: [URL]
    public let soundFont: URL?
    public let joiplayCompat: Bool
    public let networkEnabled: Bool
    public let useInGameKeyboard: Bool
    public let fixedFramerate: Int
    /// The Runtime page's Picture choice: `nearest` turns smoothing off.
    public let sharp: Bool
    /// Cover the screen and crop the overflow instead of letterboxing (`screen=fill`, mkxp-z patch 0005).
    public let fill: Bool
    /// OmniPlay's own preload scripts (the save redirect), run after the engine's bundled ones.
    public var hostPreloads: [URL] = []

    /// The engine's bundled compatibility scripts are not listed in `preloadScript`: it loads them from
    /// `Assets.bundle` itself and gates them per Ruby line (`win32_wrap_encoding.rb` is Ruby 1.9 and up), and
    /// listing that folder again re-runs all of them on whichever line the game got, which ends an XP session on
    /// Ruby 1.8 in a wall of syntax errors. The key carries only OmniPlay's own `hostPreloads`.
    public init(
        descriptor: GameDescriptor,
        ruby: RubyLine,
        layers: [OverlayLayer],
        gameFolder: URL,
        soundFont: URL? = nil
    ) {
        rgssVersion = Self.rgssVersion(for: descriptor)
        self.ruby = ruby
        self.gameFolder = gameFolder
        title = descriptor.title
        let overrides = descriptor.profile.overrides
        // PhysFS refuses to mount a path that is not there and mkxp turns that into a fatal engine error, so
        // a layer whose directory has not been created yet — no mods enabled, nothing generated — is left out.
        patches = Self.existing(layers.filter { $0.tier == .overrides || $0.tier == .generated })
        rtp = Self.existing(layers.filter { $0.tier == .rtp })
        self.soundFont = soundFont
        // Games built against JoiPlay's own shims ask for them by name; the detector records the hint.
        joiplayCompat = overrides["joiplayCompat"] == "true"
        networkEnabled = overrides["networkEnabled"] == "true"
        useInGameKeyboard = overrides["useInGameKeyboard"] == "true"
        fixedFramerate = Int(overrides["fixedFramerate"] ?? "") ?? 0
        sharp = overrides["scaling"] == "nearest"
        fill = overrides["screen"] == "fill"
    }

    /// RGSS generation → 1 (XP), 2 (VX), 3 (VX Ace); the engine family decides when the generation is unknown.
    public static func rgssVersion(for descriptor: GameDescriptor) -> Int {
        switch descriptor.generation {
        case .rgss1: return 1
        case .rgss2: return 2
        case .rgss3: return 3
        default: break
        }
        switch descriptor.engine {
        case .rpgMakerXP: return 1
        case .rpgMakerVX: return 2
        default: return 3
        }
    }

    /// Which Ruby line the resolver picked, with the profile's advanced override winning when it names one.
    public static func ruby(for descriptor: GameDescriptor, resolved: RubyLine) -> RubyLine {
        guard let raw = descriptor.profile.overrides["rubyOverride"], let line = RubyLine(rawValue: raw) else { return resolved }
        return line
    }

    /// Ruby 3.1 parses 1.8/1.9-era scripts through the legacy transform; the native old Rubies need none.
    /// `syntaxCompatibilityMode` in the profile overrides the default for a game with mixed grammar.
    public var syntaxTransform: MKXPSyntaxTransformMode { ruby == .ruby31 ? MKXP_SYNTAX_TRANSFORM_LEGACY : MKXP_SYNTAX_TRANSFORM_DISABLED }

    public static func syntaxTransform(named name: String?) -> MKXPSyntaxTransformMode? {
        switch name {
        case "disabled": MKXP_SYNTAX_TRANSFORM_DISABLED
        case "custom": MKXP_SYNTAX_TRANSFORM_CUSTOM
        case "legacy": MKXP_SYNTAX_TRANSFORM_LEGACY
        default: nil
        }
    }

    public var rubyVersion: MKXPRubyVersion {
        switch ruby {
        case .ruby18: MKXP_RUBY_18
        case .ruby19: MKXP_RUBY_19
        case .ruby31: MKXP_RUBY_31
        }
    }

    /// `mkxp.json` as the engine's `Config::read` expects it (top-level keys, forward slashes, absolute paths).
    public var json: [String: Any] {
        var out: [String: Any] = [
            "rgssVersion": rgssVersion,
            "gameFolder": path(gameFolder),
            "windowTitle": title,
            "patches": patches.map(path),
            "RTP": rtp.map(path),
            "pathCache": true,
            "useScriptNames": true,
            // An integer (0 nearest, 1 bilinear): mkxp reads it `as_integer`, and a bool fell back to its default 0.
            "smoothScaling": sharp ? 0 : 1,
            "fixedAspectRatio": true,
            "fillScreen": fill,
            "preferMetalRenderer": true,
            // The host owns settings, the pause menu and the reset gesture; the engine's own must stay out.
            "enableSettings": false,
            "displayFPS": false,
            "printFPS": false,
            "allowSymlinks": false,
            "fontSub": Self.cjkFontSubstitutes,
        ]
        if let soundFont {
            out["midiSoundFont"] = path(soundFont)
        }
        if fixedFramerate > 0 {
            out["fixedFramerate"] = fixedFramerate
        }
        if !hostPreloads.isEmpty {
            out["preloadScript"] = hostPreloads.map(path)
        }
        return out
    }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    /// Windows' CJK fonts, which iOS does not have, drawn with the shared pool's WenQuanYi Micro Hei instead of the
    /// Latin-only fallback (TRANS-005). mkxp matches these lower-cased.
    static let cjkFontSubstitutes: [String] = [
        "simhei", "simsun", "nsimsun", "microsoft yahei", "黑体", "宋体", "微软雅黑",
        "pmingliu", "mingliu", "microsoft jhenghei", "新細明體", "細明體",
        "ms gothic", "ms pgothic", "ms mincho", "ms pmincho", "meiryo", "ｍｓ ゴシック", "ｍｓ ｐゴシック", "ｍｓ 明朝", "ｍｓ ｐ明朝", "メイリオ",
        "dotum", "gulim", "batang", "malgun gothic", "돋움", "굴림", "바탕", "맑은 고딕",
    ].map { "\($0)>WenQuanYi Micro Hei" }

    public func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "mkxp.json")
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Layer roots that exist on disk, highest priority first.
    static func existing(_ layers: [OverlayLayer]) -> [URL] {
        layers.sorted { $0.priority > $1.priority }.map(\.root).filter {
            var isDirectory: ObjCBool = false
            let there = FileManager.default.fileExists(atPath: $0.path(percentEncoded: false), isDirectory: &isDirectory)
            return there && isDirectory.boolValue
        }
    }
}
