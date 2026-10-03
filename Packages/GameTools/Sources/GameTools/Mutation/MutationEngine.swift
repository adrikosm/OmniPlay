import Diagnostics
import Foundation
import Observation
import RuntimeCore

/// What a tool asks to do to one value. Views speak in these; the engine turns each into a `StateMutation` for the
/// running game's bridge, so no view patches runtime memory or save bytes itself.
public enum ToolOperation: Sendable, Hashable {
    case setValue(StateValue)
    case increment(by: Int)
    case toggle
    /// Item quantities: add or take away `count`, or set the quantity outright.
    case insertItem(count: Int)
    case removeItem(count: Int)
    case setQuantity(Int)
}

/// One applied change, kept for undo. Values only: nothing here holds engine objects.
public struct MutationRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let target: StateTarget
    public let before: StateValue
    public let after: StateValue
    /// Written into the game's own files (Ren'Py persistent, web storage), so it outlives the session.
    public let persistent: Bool

    /// The operation that puts the value back.
    public var inverse: StateMutation { StateMutation(target: target, operation: .set, requested: before) }
}

/// The one path every Game Tools change takes, per session: validate → back up (persistent targets) → apply through
/// the runtime's bridge → record for undo. A rejected change records nothing.
@MainActor
@Observable
public final class MutationEngine {
    public static let undoLimit = 200

    /// Snapshots the game's saves before the first change that reaches its files this session (SaveKit `.beforeEdit`).
    public typealias BackupHook = @MainActor () async throws -> Void

    public private(set) var records: [MutationRecord] = []
    /// Values the engine holds every frame, as the game accepted them. Live only: they end with the session.
    public private(set) var frozen: [StateTarget: StateValue] = [:]
    /// Watched targets and their latest values; the visible UI owns refreshes, so hidden tools do no polling.
    public private(set) var watched: [StateTarget: StateValue] = [:]

    @ObservationIgnored public let inspector: any StateInspecting
    @ObservationIgnored private let backup: BackupHook?
    @ObservationIgnored private var backedUp = false

    public static let frozenLimit = 32
    public static let watchInterval: Duration = .milliseconds(500)

    public init(inspector: any StateInspecting, backup: BackupHook? = nil) {
        self.inspector = inspector
        self.backup = backup
    }

    public var canUndo: Bool { !records.isEmpty }

    /// One page of a category, for the tools' lists.
    public func list(_ category: StateCategory, query: String?, page: StatePage) async throws -> StateInspectionResult {
        try await inspector.inspect(.list(category: category, query: query, page: page))
    }

    /// The value a target had before this session's first change to it, while that change is still on the stack.
    public func initialValue(of target: StateTarget) -> StateValue? {
        records.first { $0.target == target }?.before
    }

    /// The engine's script console, when it has one (Ren'Py).
    public var console: (any ScriptConsole)? { inspector as? any ScriptConsole }

    /// The engine's own save slots, when its bridge can load and write them (SAVE-009).
    public var slots: (any SlotEditing)? { inspector as? any SlotEditing }

    /// One target's value as the engine has it now.
    public func read(_ target: StateTarget) async throws -> StateValue? {
        try await inspector.inspect(.get(target)).entries.first?.value
    }

    /// What this game's engine can show and change.
    public var capabilities: StateCapabilities { inspector.stateCapabilities }

    @discardableResult
    public func apply(_ operation: ToolOperation, to target: StateTarget) async -> StateMutationResult {
        let needed = StateCapabilities.required(for: target)
        guard !needed.isEmpty, capabilities.isSuperset(of: needed) else {
            return finish(
                .rejected(StateMutation(target: target, requested: .null), "This game's engine has nothing of that kind."),
                record: false
            )
        }
        let current: StateEntry?
        do {
            current = try await inspector.inspect(.get(target)).entries.first
        } catch StateBridgeError.notInGame {
            return finish(.rejected(StateMutation(target: target, requested: .null), "The game has not started yet."), record: false)
        } catch {
            return finish(.rejected(StateMutation(target: target, requested: .null), String(describing: error)), record: false)
        }
        let mutation: StateMutation
        do {
            mutation = try Self.mutation(for: operation, on: target, current: current?.value ?? .null)
            try Self.validate(mutation, current: current)
        } catch {
            return finish(
                .rejected(StateMutation(target: target, requested: .null), (error as? MutationError)?.message ?? "\(error)"),
                record: false
            )
        }
        return await run(mutation, persistent: Self.isPersistent(target) || current?.persistent == true, record: true)
    }

    /// Sets the value and has the engine hold it (MV/MZ every frame, RGSS every `Graphics.update`, Ren'Py every tick).
    /// Not an undo step: unfreezing is how a hold ends. Validated like any set.
    @discardableResult
    public func freeze(_ target: StateTarget, at value: StateValue) async -> StateMutationResult {
        let rejectedWith: (String) -> StateMutationResult = { .rejected(StateMutation(target: target, requested: value), $0) }
        guard capabilities.isSuperset(of: StateCapabilities.required(for: target)), !StateCapabilities.required(for: target).isEmpty else {
            return finish(rejectedWith("This game's engine has nothing of that kind."), record: false)
        }
        guard frozen[target] != nil || frozen.count < Self.frozenLimit else {
            return finish(rejectedWith("At most \(Self.frozenLimit) values can be frozen."), record: false)
        }
        guard !Self.isPersistent(target) else {
            // A hold on data the game writes to disk would keep rewriting the player's files.
            return finish(rejectedWith("Values the game keeps on disk cannot be frozen."), record: false)
        }
        let mutation = StateMutation(target: target, operation: .freeze, requested: value)
        do {
            let current = try await inspector.inspect(.get(target)).entries.first
            try Self.validate(StateMutation(target: target, operation: .set, requested: value), current: current)
        } catch {
            return finish(rejectedWith((error as? MutationError)?.message ?? "\(error)"), record: false)
        }
        let result = await run(mutation, persistent: false, record: false)
        if result.result != .rejected {
            frozen[target] = result.effectiveValue
        }
        return result
    }

    public func unfreeze(_ target: StateTarget) async {
        guard frozen.removeValue(forKey: target) != nil else { return }
        _ = await inspector.mutate(StateMutation(target: target, operation: .unfreeze, requested: .null))
    }

    public func watch(_ target: StateTarget) {
        guard watched[target] == nil else { return }
        watched[target] = .null
    }

    public func unwatch(_ target: StateTarget) {
        watched.removeValue(forKey: target)
    }

    /// The session is over; frozen values die with the engine's own tables.
    public func stop() {
        watched = [:]
        frozen = [:]
    }

    public func refreshWatches() async {
        for target in Array(watched.keys) {
            guard !Task.isCancelled else { return }
            guard let value = try? await inspector.inspect(.get(target)).entries.first?.value else { continue }
            guard !Task.isCancelled else { return }
            if watched[target] != nil, watched[target] != value {
                watched[target] = value
            }
        }
    }

    /// Undoes the newest change by setting its value back, through the same path.
    @discardableResult
    public func undo() async -> StateMutationResult? {
        guard let record = records.popLast() else { return nil }
        let result = await run(record.inverse, persistent: record.persistent, record: false)
        if result.result == .rejected {
            records.append(record)
        }
        return result
    }

    /// Snapshots the saves before this session's first change to them; false when that failed. Also for changes that
    /// reach the game's files outside `apply` (Ren'Py Tools presets).
    public func backUpOnce() async -> Bool {
        guard !backedUp, let backup else { return true }
        do {
            try await backup()
            backedUp = true
            return true
        } catch {
            return false
        }
    }

    private func run(_ mutation: StateMutation, persistent: Bool, record: Bool) async -> StateMutationResult {
        if persistent, await !backUpOnce() {
            return finish(.rejected(mutation, "The saves could not be backed up first, so nothing was changed."), record: false)
        }
        var result = await inspector.mutate(mutation)
        result.persistent = result.persistent || persistent
        OPLog.log(.runtime, .info, "tools: \(mutation.target) \(result.result.rawValue) \(result.oldValue) → \(result.effectiveValue)")
        return finish(result, record: record)
    }

    private func finish(_ result: StateMutationResult, record: Bool) -> StateMutationResult {
        if record, result.result != .rejected, result.oldValue != result.effectiveValue {
            records.append(MutationRecord(
                id: UUID(), target: result.target, before: result.oldValue, after: result.effectiveValue,
                persistent: result.persistent
            ))
            if records.count > Self.undoLimit {
                records.removeFirst(records.count - Self.undoLimit)
            }
        }
        return result
    }

    // MARK: - Operations and validation

    struct MutationError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static func mutation(for operation: ToolOperation, on target: StateTarget, current: StateValue) throws -> StateMutation {
        switch operation {
        case let .setValue(value): return StateMutation(target: target, operation: .set, requested: value)
        case let .increment(by): return StateMutation(target: target, operation: .add, requested: .int(by))
        case .toggle: return StateMutation(target: target, operation: .toggle, requested: .null)
        case let .insertItem(count), let .removeItem(count):
            guard count > 0 else { throw MutationError("Enter a quantity above zero.") }
            guard case .item = target,
                  case let .int(have) = current else { throw MutationError("Only item quantities can be added or removed.") }
            let delta = if case .insertItem = operation {
                count
            } else {
                -count
            }
            return StateMutation(target: target, operation: .set, requested: .int(max(0, have + delta)))
        case let .setQuantity(n):
            guard case .item = target else { throw MutationError("Only items have a quantity.") }
            return StateMutation(target: target, operation: .set, requested: .int(n))
        }
    }

    /// Checks the change against what is there now: same kind of value, nothing the bridge reports as read-only or as
    /// an engine object, and the floors every engine shares (no negative gold or counts, level at least 1). Upper caps
    /// are the engine's own: a clamped value comes back `partial`.
    static func validate(_ mutation: StateMutation, current: StateEntry?) throws {
        if let current {
            guard current.editable else { throw MutationError("This value is read-only.") }
            if case .engineObject = current.value {
                throw MutationError("This is an engine object; it can be viewed, not edited.")
            }
        }
        let existing = current?.value ?? .null
        switch mutation.operation {
        case .toggle:
            guard case .bool = existing else { throw MutationError("Only on/off values can be toggled.") }
            return
        case .add:
            guard existing.number != nil else { throw MutationError("Only numbers can be increased.") }
        case .unfreeze:
            return
        case .set, .freeze:
            guard existing == .null || sameKind(existing, mutation.requested) else {
                throw MutationError("This value holds \(existing.kindName), not \(mutation.requested.kindName).")
            }
        }
        let resulting: Double? = switch (mutation.operation, existing.number, mutation.requested.number) {
        case let (.add, have?, delta?): have + delta
        case let (_, _, value?): value
        default: nil
        }
        guard let resulting else { return }
        switch mutation.target {
        case .gold, .item:
            if resulting < 0 {
                throw MutationError("This cannot go below zero.")
            }
        case let .actorProperty(_, property):
            switch property {
            case .level where resulting < 1: throw MutationError("Level starts at 1.")
            case .hp, .mp, .tp, .exp: if resulting < 0 {
                    throw MutationError("This cannot go below zero.")
                }
            default: break
            }
        default: break
        }
    }

    /// Ints and doubles are both numbers; a switch accepts 0 and 1 from a numeric field.
    static func sameKind(_ a: StateValue, _ b: StateValue) -> Bool {
        switch (a, b) {
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double), (.bool, .bool), (.string, .string),
             (.list, .list), (.dict, .dict): true
        case (.bool, .int(0)), (.bool, .int(1)): true
        default: false
        }
    }

    /// Targets that live in the game's own files rather than in the running session.
    static func isPersistent(_ target: StateTarget) -> Bool {
        switch target {
        case .renpyPersistent, .webStorageKey: true
        default: false
        }
    }
}

extension StateValue {
    var number: Double? {
        switch self {
        case let .int(i): Double(i)
        case let .double(d): d
        default: nil
        }
    }

    var kindName: String {
        switch self {
        case .bool: "on/off"
        case .int, .double: "a number"
        case .string: "text"
        case .list: "a list"
        case .dict: "a set of values"
        case .engineObject: "an engine object"
        case .unsupported: "an unsupported value"
        case .null: "nothing"
        }
    }
}
