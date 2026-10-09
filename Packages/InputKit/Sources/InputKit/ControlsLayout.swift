import Foundation

/// Where the virtual controls sit, in unit coordinates of the safe area (0…1) with sizes in points.
/// Versioned so a stored layout from an older build is recognised; the deltaskin superset is INPUT-005.
public struct ControlsLayout: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public struct Anchor: Codable, Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var size: Double
        public init(x: Double, y: Double, size: Double) {
            self.x = x
            self.y = y
            self.size = size
        }
    }

    public struct Control: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var keys: [GameKey]
        public var anchor: Anchor
        /// A tap latches the key down until the next tap (Shift to dash, Ctrl to skip). Absent in older layouts.
        public var hold: Bool?
        public init(id: String, label: String, keys: [GameKey], anchor: Anchor, hold: Bool? = nil) {
            self.id = id
            self.label = label
            self.keys = keys
            self.anchor = anchor
            self.hold = hold
        }

        /// What the button shows: the key it sends. Layouts saved before that still carry a bare A/B/X/Y.
        public var effectiveLabel: String {
            ["A", "B", "X", "Y"].contains(label) ? keys.first.map(KeyCatalog.label) ?? label : label
        }
    }

    public var version: Int
    public var dpad: Anchor
    public var buttons: [Control]
    /// The round plate the face buttons sit on, mirroring the D-pad. Absent in older layouts.
    public var plate: Anchor?

    public init(version: Int = ControlsLayout.currentVersion, dpad: Anchor, buttons: [Control], plate: Anchor? = nil) {
        self.version = version
        self.dpad = dpad
        self.buttons = buttons
        self.plate = plate
    }

    public static func decode(_ data: Data) throws -> ControlsLayout {
        let layout = try JSONDecoder().decode(ControlsLayout.self, from: data)
        guard layout.version == currentVersion else { throw DecodingError.dataCorrupted(.init(
            codingPath: [],
            debugDescription: "unsupported layout version \(layout.version)"
        )) }
        return layout
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// D-pad bottom-left; bottom-right, four face buttons in a diamond like a controller's: Y on top, X left, B right,
    /// A at the bottom under the resting thumb. Controls are anchored lower and closer to the edges for thumb ergonomics.
    static func diamond(landscape: Bool, a: [GameKey], b: [GameKey], x: [GameKey], y: [GameKey]) -> ControlsLayout {
        // Unit offsets of one 54 pt button in the safe area (about 832×419 pt landscape, 408×800 pt portrait).
        let (cx, cy, dx, dy) = landscape ? (0.90, 0.80, 54.0 / 832, 54.0 / 419) : (0.79, 0.85, 54.0 / 408, 54.0 / 800)
        func face(_ idSuffix: String, _ keys: [GameKey], _ x: Double, _ y: Double) -> Control {
            let label = keys.first.map { KeyCatalog.label(for: $0) } ?? idSuffix.uppercased()
            return Control(id: "face.\(idSuffix.lowercased())", label: label, keys: keys, anchor: Anchor(x: x, y: y, size: 54))
        }
        return ControlsLayout(
            dpad: landscape ? Anchor(x: 0.10, y: 0.80, size: 128) : Anchor(x: 0.18, y: 0.85, size: 128),
            buttons: [face("y", y, cx, cy - dy), face("x", x, cx - dx, cy), face("b", b, cx + dx, cy), face("a", a, cx, cy + dy)]
        )
    }

    /// RPG Maker: A is Z (confirm), B is Esc (cancel), X is X (menu), Y is Shift (dash), the keys the games are
    /// played with. XP is the exception for A: it reads Z as its own A input and confirms with C, Space or Enter,
    /// so there A sends Enter.
    static func rpgMaker(landscape: Bool, xp: Bool = false) -> ControlsLayout {
        diamond(landscape: landscape, a: [xp ? .enter : .keyZ], b: [.escape], x: [.keyX], y: [.shiftLeft])
    }

    /// Keyboard games on other engines (Godot, web): Enter accepts, Esc backs out, Space and Shift for action.
    static func general(landscape: Bool) -> ControlsLayout {
        diamond(landscape: landscape, a: [.enter], b: [.escape], x: [.space], y: [.shiftLeft])
    }

    public static let landscape = rpgMaker(landscape: true)
    public static let portrait = rpgMaker(landscape: false)
}

public extension ControlsLayoutSet {
    /// The built-in pad for a game's engine; a layout the player edited or a package brought wins over it.
    static func defaults(rpgMaker: Bool, xp: Bool = false) -> ControlsLayoutSet {
        rpgMaker
            ? ControlsLayoutSet(
                landscape: .rpgMaker(landscape: true, xp: xp),
                portrait: .rpgMaker(landscape: false, xp: xp),
                source: "builtin"
            )
            : ControlsLayoutSet(landscape: .general(landscape: true), portrait: .general(landscape: false), source: "builtin")
    }
}
