import Darwin
import Diagnostics
import Foundation
import GameCore
import RuntimeCore

public extension RenPyEngine {
    /// `RenPy853` for `.v853`: the embedded framework and the binary inside it.
    var frameworkName: String { "RenPy" + rawValue.dropFirst() }

    /// `8.5.3` for `.v853`.
    var version: String { rawValue.dropFirst().map(String.init).joined(separator: ".") }
}

/// One Ren'Py engine framework (`Frameworks/RenPy853.framework` and its siblings), opened on the first launch
/// that needs it.
///
/// Each framework carries a whole CPython, SDL and FFmpeg; they stay apart only because each lives in its own
/// image, so the app embeds them without linking and resolves `op_renpy.h` by name. Nothing unloads again:
/// dlclose never unloads an image with Objective-C classes or thread-locals, and Python cannot be initialised
/// twice anyway. One boot per engine per process; after that, leaving a game parks Python inside Ren'Py's own
/// restart loop, and `switchGame` hands the parked engine the next one.
///
/// Like SDL's own UIKit entry point, the engine takes the main thread for the whole session and spins CFRunLoop
/// from its event pump, which keeps the host's UI and main-actor work running inside the call. It is started
/// from a run-loop block, never a main-queue block: libdispatch does not drain the main queue re-entrantly, so
/// a session started from inside one would freeze every main-actor continuation in the app.
@MainActor
public final class RenPyEngineLibrary {
    public enum Phase: Sendable, Equatable {
        case notStarted
        case running
        case exited(Int32)
    }

    public enum Failure: Error, CustomStringConvertible {
        case loadFailed(String)
        case symbolMissing(String)
        case alreadySpent

        public var description: String {
            switch self {
            case let .loadFailed(reason): "The Ren'Py engine could not be loaded: \(reason)"
            case let .symbolMissing(name): "The Ren'Py engine is incomplete (\(name) missing)."
            case .alreadySpent: "This Ren'Py engine already ran this launch. OmniPlay has to restart."
            }
        }
    }

    /// `op_renpy.h`: host → engine requests, engine → host progress.
    public enum Command: Int32 { case run = 0, pause = 1, stop = 2 }
    public enum Status: Int32 { case idle = 0, booting = 1, running = 2, paused = 3, exited = 4, parked = 5 }

    /// The host's settings for one game, handed to the engine through `op_renpy_set_session` and read by
    /// `base/omniplay_host.py`.
    public struct Session: Encodable, Sendable {
        public var basedir: String
        public var savedir: String
        public var logdir: String
        public var log: String
        public var hostdir: String
        public var cachedir: String
        public var snapshot: String
        public var overlays: [String]
        /// Park after the game instead of ending Python. False when the engine started above another parked one.
        public var keep: Bool
        /// Names the game uses (relative to game/, lower-cased) → converted files, absolute.
        public var remap: [String: String] = [:]
        /// Developer switches the player turned on (`switchNames`), read by `omniplay_host.rpy`.
        public var switches: [String: Bool] = [:]
        /// The active MTool dictionary (absolute path) and the active `tl/` language, from the translation packs.
        public var translation: String?
        public var language: String?
        /// A font with CJK glyphs (absolute path), put on the search path for translated text.
        public var cjkFont: String?
        /// Lines the dictionary misses are queued for live translation (TRANS-006).
        public var liveTranslation = false

        /// Developer mode, the Shift+O console, rollback (256 steps), skipping unseen text, skipping the splash screen.
        public static let switchNames = ["developer", "console", "rollback", "skipUnseen", "skipSplash"]

        public init(
            basedir: String,
            savedir: String,
            logdir: String,
            log: String,
            hostdir: String,
            cachedir: String,
            snapshot: String,
            overlays: [String],
            keep: Bool
        ) {
            self.basedir = basedir
            self.savedir = savedir
            self.logdir = logdir
            self.log = log
            self.hostdir = hostdir
            self.cachedir = cachedir
            self.snapshot = snapshot
            self.overlays = overlays
            self.keep = keep
        }
    }

    private struct API {
        let version: @convention(c) () -> UnsafePointer<CChar>?
        let run: @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let request: @convention(c) (Int32) -> Void
        let status: @convention(c) () -> Int32
        let window: @convention(c) () -> UnsafeMutableRawPointer?
        let appEvent: @convention(c) (Int32) -> Void
        let setSession: @convention(c) (UnsafePointer<CChar>?) -> Void
        let setStatus: @convention(c) (Int32) -> Void
    }

    typealias StateReplyFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

    /// The state mailbox (`op_renpy_state_*`); absent from frameworks built before it, which then offer no Game Tools.
    private struct StateAPI {
        let request: @convention(c) (UnsafePointer<CChar>?, StateReplyFunction?, UnsafeMutableRawPointer?) -> Int32
        let cancel: @convention(c) () -> UnsafeMutableRawPointer?
    }

    public let engine: RenPyEngine
    public let frameworkURL: URL
    public private(set) var phase: Phase = .notStarted
    /// Called on the main actor if Python itself ends, which spends the engine for the rest of the process. Set by
    /// whichever adapter is playing, since one engine outlives many of them.
    public var onExit: (@MainActor (Int32) -> Void)?
    private var api: API?
    private var stateAPI: StateAPI?

    private static var opened: [RenPyEngine: RenPyEngineLibrary] = [:]

    /// The framework for `engine` when this build embeds it.
    public static func bundled(_ engine: RenPyEngine, in bundle: Bundle = .main) -> RenPyEngineLibrary? {
        if let library = opened[engine] {
            return library
        }
        guard let frameworks = bundle.privateFrameworksURL else { return nil }
        let url = frameworks.appending(path: "\(engine.frameworkName).framework", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.appending(path: engine.frameworkName).path(percentEncoded: false)) else {
            return nil
        }
        let library = RenPyEngineLibrary(engine: engine, frameworkURL: url)
        opened[engine] = library
        return library
    }

    private init(engine: RenPyEngine, frameworkURL: URL) {
        self.engine = engine
        self.frameworkURL = frameworkURL
    }

    /// The engine binary; also argv[0] for the engine, which finds its `base/` folder beside it.
    public var binaryURL: URL { frameworkURL.appending(path: engine.frameworkName) }

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
        let api = try API(
            version: symbol("op_renpy_version", as: (@convention(c) () -> UnsafePointer<CChar>?).self),
            run: symbol("op_renpy_run", as: (@convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32).self),
            request: symbol("op_renpy_request", as: (@convention(c) (Int32) -> Void).self),
            status: symbol("op_renpy_status", as: (@convention(c) () -> Int32).self),
            window: symbol("op_renpy_window", as: (@convention(c) () -> UnsafeMutableRawPointer?).self),
            appEvent: symbol("op_renpy_app_event", as: (@convention(c) (Int32) -> Void).self),
            setSession: symbol("op_renpy_set_session", as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self),
            setStatus: symbol("op_renpy_set_status", as: (@convention(c) (Int32) -> Void).self)
        )
        self.api = api
        if let request = dlsym(handle, "op_renpy_state_request"), let cancel = dlsym(handle, "op_renpy_state_cancel") {
            stateAPI = StateAPI(
                request: unsafeBitCast(
                    request,
                    to: (@convention(c) (UnsafePointer<CChar>?, StateReplyFunction?, UnsafeMutableRawPointer?) -> Int32).self
                ),
                cancel: unsafeBitCast(cancel, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
            )
        }
        OPLog.log(.python, .info, "loaded \(engine.frameworkName) (Ren'Py \(api.version().map { String(cString: $0) } ?? "?"))")
        return api
    }

    /// True when this engine can take a game now: never started, or parked after the last one.
    public var isAvailable: Bool { phase == .notStarted || (phase == .running && status == .parked) }

    /// Whether a game on this engine may park it afterwards. Engines nest on the main thread: one booted while
    /// another is parked runs inside the parked one's wait loop, which can only resume once the newer engine's call
    /// has returned. A newer engine that parked too would bury the older one for the rest of the process, so it
    /// ends Python with its game instead (`.slotSpent`) and the older engine stays reusable.
    public var mayPark: Bool {
        phase == .running || !Self.opened.values.contains { $0 !== self && $0.phase == .running }
    }

    /// Hands the main thread to Ren'Py and returns at once. The call behind it lasts as long as Python does, which
    /// is normally the rest of the process: games end by parking, not by returning.
    public func boot(session: Session, arguments: [String], environment: [String: String?]) throws {
        let api = try load()
        guard phase == .notStarted else { throw Failure.alreadySpent }
        // The engine reads its settings from the process environment when Python starts. Every key is written,
        // unset ones included, so nothing a previous engine left behind leaks into this one.
        apply(environment)
        try hand(session, to: api)
        phase = .running
        // strdup'd and never freed: the engine keeps argv for the life of the process.
        let argv = ([binaryURL.path(percentEncoded: false)] + arguments).map { strdup($0) } + [nil]
        // Handed to the run-loop block, which runs on this same main thread; nothing else ever touches it.
        nonisolated(unsafe) let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argv.count)
        buffer.initialize(from: argv, count: argv.count)
        let argc = Int32(argv.count - 1)
        EngineMainThread.run("Ren'Py \(engine.version)") {
            api.run(argc, buffer)
        } exited: { status in
            self.phase = .exited(status)
            self.onExit?(status)
        }
    }

    /// Starts `session` on the parked engine: Ren'Py's restart loop, waiting in `get_alternate_base`, picks it up
    /// within a tenth of a second. SDL reads its hints (the orientations) from the process environment each time.
    public func switchGame(session: Session, environment: [String: String?]) throws {
        guard let api, isAvailable, phase == .running else { throw Failure.alreadySpent }
        apply(environment)
        try hand(session, to: api)
        // Booting until the new game's first interaction says running; parked again means it ended first.
        api.setStatus(Status.booting.rawValue)
        api.request(Command.run.rawValue)
    }

    private func apply(_ environment: [String: String?]) {
        for (key, value) in environment {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    private func hand(_ session: Session, to api: API) throws {
        var json = try JSONEncoder().encode(session)
        json.append(0)
        json.withUnsafeBytes { api.setSession($0.baseAddress?.assumingMemoryBound(to: CChar.self)) }
    }

    public func request(_ command: Command) { api?.request(command.rawValue) }

    public var status: Status { api.flatMap { Status(rawValue: $0.status()) } ?? .idle }

    /// SDL's window for the game once Ren'Py has opened it.
    public func window() -> UnsafeMutableRawPointer? { api?.window() }

    /// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active, 4 memory warning.
    public func appEvent(_ event: Int32) { api?.appEvent(event) }

    /// Sends one typed state request (StateWire JSON) to the game and returns the JSON reply. Python answers it at
    /// its next tick, running or paused (`base/omniplay_state.py`). The mailbox holds one request; a second (Variables
    /// asks for its list while another lookup is out) waits its turn within the same timeout instead of failing.
    public func stateRequest(_ json: String, timeout: Duration = .seconds(2)) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                return try await post(json, timeout: timeout)
            } catch MailboxBusy.busy {
                guard ContinuousClock.now < deadline else { throw StateBridgeError.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private enum MailboxBusy: Error { case busy }

    private func post(_ json: String, timeout: Duration) async throws -> String {
        guard let state = stateAPI, phase == .running, status == .running || status == .paused else {
            throw StateBridgeError.notInGame
        }
        let reply = StateReply()
        return try await withCheckedThrowingContinuation { continuation in
            reply.continuation = continuation
            let context = Unmanaged.passRetained(reply).toOpaque()
            let accepted = json.withCString { text in
                state.request(text, { context, answer in
                    guard let context else { return }
                    Unmanaged<StateReply>.fromOpaque(context).takeRetainedValue()
                        .finish(.success(answer.map { String(cString: $0) } ?? ""))
                }, context)
            }
            guard accepted != 0 else {
                Unmanaged<StateReply>.fromOpaque(context).release()
                reply.finish(.failure(MailboxBusy.busy))
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                // Still unanswered, so the request in the mailbox is this one: take it back.
                guard reply.pending, let context = state.cancel() else { return }
                Unmanaged<StateReply>.fromOpaque(context).takeRetainedValue().finish(.failure(StateBridgeError.timedOut))
            }
        }
    }
}

/// One state request's reply, delivered once: by the engine's answer or by the timeout.
private final class StateReply: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<String, Error>?

    var pending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
