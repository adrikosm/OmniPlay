import GameCore

/// A start-up setting the player may change for one game on the Runtime page's advanced section. Each is a profile
/// override the runtime already reads; the page stores the choice as `profile.<key>` in the overrides ledger and
/// launch copies it into the profile over any hint. The Ruby line is not here: it is a runtime choice of its own
/// (`.rgss(ruby:)`), so the picker covers it. Network access is left out on purpose.
public struct RuntimeSetting: Sendable, Hashable, Identifiable {
    public struct Option: Sendable, Hashable {
        public let value: String
        public let title: String
    }

    /// The profile key, e.g. `imageCacheCapMB`.
    public let key: String
    public let title: String
    public let detail: String
    /// The first option is the default and stores nothing.
    public let options: [Option]
    public var id: String { key }

    /// The ledger key the choice is stored under.
    public var ledgerKey: String { RuntimeSettings.prefix + key }
}

public enum RuntimeSettings {
    public static let prefix = "profile."

    private static func option(_ value: String, _ title: String) -> RuntimeSetting.Option { .init(value: value, title: title) }
    private static let automatic = option("", "Automatic")

    private static let mouseSpeed = RuntimeSetting(
        key: "mouseSpeed", title: "Touchpad speed", detail: "How far the cursor travels for a finger's move, in touchpad mode.",
        options: [option("", "Normal"), option("0.6", "Slow"), option("1.6", "Fast"), option("2.4", "Fastest")]
    )

    /// mkxp-z's scaler: smooth by default, nearest-neighbour for pixel art. No whole-multiple mode: mkxp-z sizes its
    /// window in points, where 640×480 never fits. EasyRPG gets neither: its nearest path mixes points and pixels on
    /// iOS and draws a quarter-size picture in a corner, and its default is already whole steps then a smooth fit.
    private static let picture = RuntimeSetting(
        key: "scaling", title: "Picture",
        detail: "Both fill the screen, keeping the game's shape. Sharp keeps pixels crisp instead of smoothing them.",
        options: [option("", "Smooth"), option("nearest", "Sharp")]
    )

    /// Fit letterboxes; Fill covers the screen at the game's own shape and crops what overflows. RPG Maker only:
    /// MV/MZ through the compat bundle, XP/VX/VX Ace through mkxp-z patch 0005.
    private static let screen = RuntimeSetting(
        key: "screen", title: "Screen",
        detail: "Fit shows the whole picture with bars at the sides. Fill removes the bars by cutting off the picture's edges.",
        options: [option("", "Fit"), option("fill", "Fill (crops edges)")]
    )

    /// Desktop web games that turn phones away ("not mobile-friendly") by reading the user agent.
    private static let browser = RuntimeSetting(
        key: "userAgent", title: "Browser",
        detail: "Desktop tells the game it runs on a computer. Try it if the game refuses phones.",
        options: [option("", "iPhone"), option("desktop", "Desktop")]
    )

    static let web: [RuntimeSetting] = [
        screen,
        browser,
        .init(
            key: "mouseMode",
            title: "Mouse",
            detail: "Touchpad moves a cursor like a laptop's; for games that react to the mouse hovering.",
            options: [option("", "Direct"), option("touchpad", "Touchpad")]
        ),
        mouseSpeed,
        .init(
            key: "imageCacheCapMB",
            title: "Image memory cap",
            detail: "Drops the least recently used pictures past the cap. Helps large games that run out of memory.",
            options: [automatic, option("128", "128 MB"), option("256", "256 MB"), option("512", "512 MB")]
        ),
        .init(
            key: "devicePixelRatio",
            title: "Render scale",
            detail: "Lower is faster and softer.",
            options: [automatic, option("1", "1×"), option("2", "2×"), option("3", "3×")]
        ),
        .init(
            key: "coopCoep",
            title: "Cross-origin isolation",
            detail: "Some games need it for threads; it can stop others loading remote content.",
            options: [automatic, option("true", "On")]
        ),
    ]

    static let rgss: [RuntimeSetting] = [
        .init(
            key: "mouseMode",
            title: "Mouse",
            detail: "Direct: a tap clicks where it lands. Touchpad moves a cursor. Off keeps taps from clicking.",
            options: [option("", "Direct"), option("touchpad", "Touchpad"), option("off", "Off")]
        ),
        mouseSpeed,
        screen,
        picture,
        .init(
            key: "syntaxCompatibilityMode",
            title: "Script compatibility",
            detail: "How old Ruby syntax is rewritten before scripts run.",
            options: [automatic, option("legacy", "Legacy"), option("custom", "Custom"), option("disabled", "Off")]
        ),
        .init(
            key: "fixedFramerate",
            title: "Frame rate",
            detail: "Fixes the game's frame rate instead of the one it asks for.",
            options: [automatic, option("30", "30 fps"), option("60", "60 fps")]
        ),
        .init(
            key: "useInGameKeyboard",
            title: "In-game keyboard",
            detail: "Uses the game's own name-entry screen instead of the system keyboard.",
            options: [automatic, option("true", "On")]
        ),
    ]

    static let scummvm: [RuntimeSetting] = [
        .init(
            key: "mouseMode",
            title: "Mouse",
            detail: "Touchpad moves ScummVM's cursor by a finger's travel; Direct clicks where you tap.",
            options: [option("", "Touchpad"), option("direct", "Direct")]
        ),
    ]

    static let easyrpg: [RuntimeSetting] = [
        .init(
            key: "encoding",
            title: "Text encoding",
            detail: "For games whose text shows as garbage.",
            options: [
                automatic,
                option("1252", "Western (1252)"),
                option("932", "Japanese (Shift-JIS)"),
                option("936", "Chinese Simplified (GBK)"),
                option("949", "Korean (949)"),
                option("1251", "Cyrillic (1251)"),
            ]
        ),
    ]

    /// Godot 4 only (Godot 3 has one renderer). Automatic is the game's own choice: Metal on the phone for Forward+ and
    /// Mobile projects. Compatibility is Godot's OpenGL ES 3 renderer, the way out when a game's Metal path fails.
    static let godot4: [RuntimeSetting] = [
        .init(
            key: "renderer",
            title: "Renderer",
            detail: "Compatibility uses OpenGL. Try it if the game shows a black screen or glitches; 3D may look simpler.",
            options: [automatic, option("opengl3", "Compatibility")]
        ),
    ]

    /// The settings the runtime reads, empty for runtimes with none.
    public static func available(for runtime: RuntimeIdentifier?, engine: EngineFamily? = nil) -> [RuntimeSetting] {
        switch runtime {
        case .web:
            let rpgMaker = engine == .rpgMakerMV || engine == .rpgMakerMZ
            // RPG Maker's touch handling reads the phone's user agent; Fill is RPG Maker only.
            return web.filter { $0 != (rpgMaker ? browser : screen) }
        case .rgss: return rgss
        case .easyrpg: return easyrpg
        case .scummvm: return scummvm
        case let .godot(bucket): return bucket == .v36 ? [] : godot4
        default: return []
        }
    }

    /// The stored choices as profile overrides: `profile.<key>` rows become `<key>`, empty values are dropped.
    public static func overrides(from ledger: [(key: String, value: String)]) -> [String: String] {
        var result: [String: String] = [:]
        for row in ledger where row.key.hasPrefix(prefix) && !row.value.isEmpty {
            result[String(row.key.dropFirst(prefix.count))] = row.value
        }
        return result
    }
}
