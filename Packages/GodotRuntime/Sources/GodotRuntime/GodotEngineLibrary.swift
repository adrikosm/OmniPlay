import Darwin
import Diagnostics
import Foundation
import GameCore

/// An embedded Godot engine, opened on its first launch: Godot 4.7 (`Frameworks/Godot.framework`, `op_godot.h`),
/// Godot 4.4 (`Frameworks/Godot44.framework`, `op_godot44.h`) or Godot 3 (`Frameworks/Godot3.framework`, `op_godot3.h`).
///
/// Godot's iOS platform expects to be the app; each framework's shim does what Godot's own export template does at
/// launch, and OmniPlay hosts Godot's view. `Main` sets up once per process, so a Godot session spends its slot.
@MainActor
public final class GodotEngineLibrary {
    /// Which engine: the framework and its shim's symbol prefix.
    public enum Engine: String, Sendable, CaseIterable {
        case godot4, godot44, godot3

        var framework: String {
            switch self {
            case .godot4: "Godot"
            case .godot44: "Godot44"
            case .godot3: "Godot3"
            }
        }

        var prefix: String { "op_\(framework.lowercased())" }
        /// Godot 4's shims hand over their view controller, Godot 3's a window whose root it is.
        var surfaceSymbol: String { self == .godot3 ? "_window" : "_view_controller" }
        /// The engine for a version bucket.
        public init(bucket: GodotBucket) {
            self = switch bucket {
            case .v36: .godot3
            case .v44: .godot44
            case .v47: .godot4
            }
        }
    }

    public enum Command: Int32 { case run = 0, pause = 1, stop = 2 }
    public enum Status: Int32 { case idle = 0, setUp, running, paused, stopped, failed }

    public enum Failure: Error, CustomStringConvertible {
        case loadFailed(String)
        case symbolMissing(String)
        case setupFailed(Int32)
        case alreadySpent

        public var description: String {
            switch self {
            case let .loadFailed(reason): "Godot could not be loaded: \(reason)"
            case let .symbolMissing(name): "Godot is incomplete (\(name) missing)."
            case let .setupFailed(code): "Godot refused the game (error \(code)); see the session log."
            case .alreadySpent: "Godot already ran a game this launch. OmniPlay has to restart."
            }
        }
    }

    private struct API {
        let version: @convention(c) () -> UnsafePointer<CChar>?
        let setup: @convention(c) (
            Int32,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> Int32
        let surface: @convention(c) () -> UnsafeMutableRawPointer?
        let request: @convention(c) (Int32) -> Void
        let status: @convention(c) () -> Int32
        let frames: @convention(c) () -> UInt
        let appEvent: @convention(c) (Int32) -> Void
        /// Absent from frameworks built before the touch controls could drive Godot.
        let key: (@convention(c) (UnsafePointer<CChar>?, Int32) -> Void)?
    }

    public let engine: Engine
    public let binaryURL: URL
    private var api: API?
    private static var opened: [Engine: GodotEngineLibrary] = [:]

    public static func bundled(_ engine: Engine, in bundle: Bundle = .main) -> GodotEngineLibrary? {
        if let library = opened[engine] {
            return library
        }
        guard let binary = bundle.privateFrameworksURL?.appending(path: "\(engine.framework).framework/\(engine.framework)"),
              FileManager.default.fileExists(atPath: binary.path(percentEncoded: false)) else { return nil }
        let library = GodotEngineLibrary(engine: engine, binaryURL: binary)
        opened[engine] = library
        return library
    }

    private init(engine: Engine, binaryURL: URL) {
        self.engine = engine
        self.binaryURL = binaryURL
    }

    private func load() throws -> API {
        if let api {
            return api
        }
        guard let handle = dlopen(binaryURL.path(percentEncoded: false), RTLD_NOW | RTLD_LOCAL) else {
            throw Failure.loadFailed(dlerror().map { String(cString: $0) } ?? "unknown dlopen error")
        }
        func symbol<T>(_ name: String, as _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw Failure.symbolMissing(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        let p = engine.prefix
        let api = try API(
            version: symbol("\(p)_version", as: (@convention(c) () -> UnsafePointer<CChar>?).self),
            setup: symbol(
                "\(p)_setup",
                as: (@convention(c) (
                    Int32,
                    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                    UnsafePointer<CChar>?,
                    UnsafePointer<CChar>?
                ) -> Int32).self
            ),
            surface: symbol(p + engine.surfaceSymbol, as: (@convention(c) () -> UnsafeMutableRawPointer?).self),
            request: symbol("\(p)_request", as: (@convention(c) (Int32) -> Void).self),
            status: symbol("\(p)_status", as: (@convention(c) () -> Int32).self),
            frames: symbol("\(p)_frames", as: (@convention(c) () -> UInt).self),
            appEvent: symbol("\(p)_app_event", as: (@convention(c) (Int32) -> Void).self),
            key: try? symbol("\(p)_key", as: (@convention(c) (UnsafePointer<CChar>?, Int32) -> Void).self)
        )
        self.api = api
        OPLog.log(.runtime, .info, "loaded \(engine.framework) \(api.version().map { String(cString: $0) } ?? "?")")
        return api
    }

    public var isAvailable: Bool { status == .idle }
    public var status: Status { api.flatMap { Status(rawValue: $0.status()) } ?? .idle }
    public var frames: UInt { api?.frames() ?? 0 }

    /// Sets Godot up for one game; `arguments` is Godot's own command line without argv[0].
    public func setup(arguments: [String], userDirectory: URL, cacheDirectory: URL) throws {
        let api = try load()
        guard isAvailable else { throw Failure.alreadySpent }
        // strdup'd and never freed: Godot keeps argv for the life of the process.
        var argv = (["godot"] + arguments).map { strdup($0) } + [nil]
        let code = api.setup(
            Int32(argv.count - 1),
            &argv,
            userDirectory.path(percentEncoded: false),
            cacheDirectory.path(percentEncoded: false)
        )
        guard code == 0 else { throw Failure.setupFailed(code) }
    }

    /// Godot's view controller (Godot 4) or the window holding it (Godot 3); its display link finishes start-up and
    /// draws every frame once it is on screen.
    public func surface() -> UnsafeMutableRawPointer? { api?.surface() }
    public func request(_ command: Command) { api?.request(command.rawValue) }
    /// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active, 4 memory warning.
    public func appEvent(_ event: Int32) { api?.appEvent(event) }
    /// A key by Godot's own name ("Up", "Z", "Shift").
    public func key(_ name: String, pressed: Bool) { api?.key?(name, pressed ? 1 : 0) }
}
