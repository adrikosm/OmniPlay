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
        public init(id: String, label: String, keys: [GameKey], anchor: Anchor) {
            self.id = id
            self.label = label
            self.keys = keys
            self.anchor = anchor
        }
    }

    public var version: Int
    public var dpad: Anchor
    public var buttons: [Control]

    public init(version: Int = ControlsLayout.currentVersion, dpad: Anchor, buttons: [Control]) {
        self.version = version
        self.dpad = dpad
        self.buttons = buttons
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

    /// Thumb zones: D-pad bottom-left, face buttons bottom-right, page keys above them.
    public static let landscape = ControlsLayout(
        dpad: Anchor(x: 0.14, y: 0.70, size: 168),
        buttons: [
            Control(id: "ok", label: "OK", keys: [.keyZ], anchor: Anchor(x: 0.90, y: 0.62, size: 68)),
            Control(id: "cancel", label: "Cancel", keys: [.keyX], anchor: Anchor(x: 0.80, y: 0.80, size: 60)),
            Control(id: "shift", label: "Dash", keys: [.shiftLeft], anchor: Anchor(x: 0.78, y: 0.50, size: 52)),
            Control(id: "menu", label: "Menu", keys: [.escape], anchor: Anchor(x: 0.92, y: 0.88, size: 48)),
            Control(id: "pageUp", label: "Q", keys: [.pageUp], anchor: Anchor(x: 0.74, y: 0.20, size: 44)),
            Control(id: "pageDown", label: "W", keys: [.pageDown], anchor: Anchor(x: 0.90, y: 0.20, size: 44)),
        ]
    )

    public static let portrait = ControlsLayout(
        dpad: Anchor(x: 0.22, y: 0.82, size: 160),
        buttons: [
            Control(id: "ok", label: "OK", keys: [.keyZ], anchor: Anchor(x: 0.86, y: 0.78, size: 64)),
            Control(id: "cancel", label: "Cancel", keys: [.keyX], anchor: Anchor(x: 0.70, y: 0.88, size: 56)),
            Control(id: "shift", label: "Dash", keys: [.shiftLeft], anchor: Anchor(x: 0.68, y: 0.70, size: 50)),
            Control(id: "menu", label: "Menu", keys: [.escape], anchor: Anchor(x: 0.88, y: 0.93, size: 46)),
            Control(id: "pageUp", label: "Q", keys: [.pageUp], anchor: Anchor(x: 0.62, y: 0.60, size: 44)),
            Control(id: "pageDown", label: "W", keys: [.pageDown], anchor: Anchor(x: 0.90, y: 0.60, size: 44)),
        ]
    )
}
