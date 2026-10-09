import Foundation

/// The keys the layout editor offers, grouped the way players look for them.
public enum KeyCatalog {
    public struct Group: Sendable, Identifiable {
        public let title: String
        public let keys: [(key: GameKey, name: String)]
        public var id: String { title }
    }

    public static let groups: [Group] = [
        Group(title: "RPG Maker", keys: [
            (.enter, "Enter · Confirm"), (.keyZ, "Z · Confirm"), (.keyX, "X · Menu"), (.escape, "Esc · Cancel"),
            (.shiftLeft, "Shift · Dash"), (.pageUp, "Page Up · Previous"), (.pageDown, "Page Down · Next"),
            (.controlLeft, "Ctrl · Skip"), (.space, "Space"),
        ]),
        Group(title: "Letters", keys: (UInt8(ascii: "A") ... UInt8(ascii: "Z")).map {
            let letter = String(UnicodeScalar($0))
            return (GameKey(rawValue: "Key" + letter), letter)
        }),
        Group(title: "Numbers", keys: (0 ... 9).map { (GameKey(rawValue: "Digit\($0)"), "\($0)") }),
        Group(title: "Function keys", keys: (1 ... 12).map { (GameKey(rawValue: "F\($0)"), "F\($0)") }),
        Group(title: "Other", keys: [
            (.tab, "Tab"), (.backspace, "Backspace"), (.altLeft, "Alt"), (.home, "Home"), (.end, "End"),
            (.insert, "Insert"), (.delete, "Delete"), (.arrowUp, "Up"), (.arrowDown, "Down"),
            (.arrowLeft, "Left"), (.arrowRight, "Right"),
        ]),
    ]

    /// A short label for a new button: the key's own name without the RPG Maker meaning.
    public static func label(for key: GameKey) -> String {
        name(for: key).map { String($0.split(separator: " · ").first ?? Substring($0)) } ?? key.rawValue
    }

    /// What a key does, for the remap rows: "Confirm" for Enter, or the key's own name when it has no role.
    public static func action(for key: GameKey) -> String {
        name(for: key).map { String($0.split(separator: " · ").last ?? Substring($0)) } ?? key.rawValue
    }

    private static func name(for key: GameKey) -> String? {
        groups.lazy.compactMap { $0.keys.first { $0.key == key }?.name }.first
    }
}

/// Edits the layout editor makes, kept apart from the view so positions stay normalised, on the grid and on screen.
public extension ControlsLayout {
    /// Positions snap to this fraction of the screen.
    static let grid = 0.02
    static let sizeRange = 44.0 ... 200.0

    static func snapped(_ value: Double) -> Double {
        min(max((value / grid).rounded() * grid, 0.02), 0.98)
    }

    /// Moves the D-pad (`id == nil`) or a button to a normalised point, snapped.
    mutating func move(_ id: String?, to x: Double, _ y: Double) {
        let (nx, ny) = (Self.snapped(x), Self.snapped(y))
        update(id) { $0.x = nx; $0.y = ny }
    }

    mutating func resize(_ id: String?, to size: Double) {
        let clamped = min(max(size.rounded(), Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        update(id) { $0.size = clamped }
    }

    /// Remaps a button and updates its label to reflect the assigned keybinding.
    mutating func setKey(_ key: GameKey, for id: String) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        buttons[index].keys = [key]
        buttons[index].label = KeyCatalog.label(for: key)
    }

    enum FaceArrangement: Sendable { case diamond, row }

    /// The four face buttons, Y X B A: the built-in ones by id, or the first four of an older or imported layout.
    var faceIDs: [String] {
        let ids = ["face.y", "face.x", "face.b", "face.a"].filter { id in buttons.contains { $0.id == id } }
        return ids.count == 4 ? ids : Array(buttons.prefix(4).map(\.id))
    }

    /// Diamond when the four sit on different rows, row when they share one.
    var faceArrangement: FaceArrangement {
        let ys = Set(buttons.filter { faceIDs.contains($0.id) }.map { ($0.anchor.y * 100).rounded() })
        return ys.count == 1 ? .row : .diamond
    }

    /// Lays the face buttons out again around their current centre, edge to edge. `canvas` is the safe area in
    /// points, so a button's own size turns into the right unit step on each axis.
    mutating func arrangeFaces(_ arrangement: FaceArrangement, canvas: (width: Double, height: Double)) {
        let ids = faceIDs
        let faces = buttons.filter { ids.contains($0.id) }
        guard faces.count == 4, canvas.width > 0, canvas.height > 0 else { return }
        let size = faces.map(\.anchor.size).max() ?? 54
        let (dx, dy) = (size / canvas.width, size / canvas.height)
        var cx = faces.map(\.anchor.x).reduce(0, +) / 4
        var cy = faces.map(\.anchor.y).reduce(0, +) / 4
        // Y X B A: a diamond around the centre, or one row with A nearest the right edge.
        let spots: [(Double, Double)] = switch arrangement {
        case .diamond: [(0, -dy), (-dx, 0), (dx, 0), (0, dy)]
        case .row: [(-1.5 * dx, 0), (-0.5 * dx, 0), (0.5 * dx, 0), (1.5 * dx, 0)]
        }
        let spanX = (arrangement == .row ? 2 : 1) * dx
        cx = min(max(cx, spanX + dx / 2), 1 - spanX - dx / 2)
        cy = min(max(cy, dy * 1.5), 1 - dy * 1.5)
        for (id, spot) in zip(ids, spots) {
            if let index = buttons.firstIndex(where: { $0.id == id }) {
                buttons[index].anchor.x = cx + spot.0
                buttons[index].anchor.y = cy + spot.1
            }
        }
    }

    /// Adds a button for `key` near the middle and returns its id.
    @discardableResult
    mutating func add(_ key: GameKey) -> String {
        let id = "user.\(UUID().uuidString.prefix(8))"
        buttons.append(Control(id: id, label: KeyCatalog.label(for: key), keys: [key], anchor: Anchor(x: 0.5, y: 0.5, size: 56)))
        return id
    }

    /// A copy of the button, offset so both stay visible; returns the copy's id.
    @discardableResult
    mutating func duplicate(_ id: String) -> String? {
        guard var copy = buttons.first(where: { $0.id == id }) else { return nil }
        copy.id = "user.\(UUID().uuidString.prefix(8))"
        copy.anchor.x = Self.snapped(copy.anchor.x > 0.5 ? copy.anchor.x - 0.1 : copy.anchor.x + 0.1)
        buttons.append(copy)
        return copy.id
    }

    mutating func setHold(_ hold: Bool, for id: String) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        buttons[index].hold = hold ? true : nil
    }

    mutating func remove(_ id: String) {
        buttons.removeAll { $0.id == id }
    }

    func anchor(_ id: String?) -> Anchor? {
        guard let id else { return dpad }
        return buttons.first { $0.id == id }?.anchor
    }

    private mutating func update(_ id: String?, _ change: (inout Anchor) -> Void) {
        guard let id else { return change(&dpad) }
        if let index = buttons.firstIndex(where: { $0.id == id }) {
            change(&buttons[index].anchor)
        }
    }
}
