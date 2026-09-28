import Darwin
import Diagnostics
import Foundation
import GameCore
import RuntimeCore

/// The embedded EasyRPG Player (`Frameworks/EasyRPG.framework`), opened on the first RPG Maker 2000/2003 launch.
///
/// Like the Ren'Py engines it carries its own SDL, so the app embeds it without linking and resolves `op_easyrpg.h`
/// by name; it never unloads, since dlclose leaves an image with Objective-C classes in place. One boot per process
/// for now: whether `Player::Exit` followed by another `Player::Init` runs clean is `TEST-009`'s question, and
/// `SessionSlot.easyrpg` stays `.one` until the phone answers it.
///
/// The Player takes the main thread for the whole session and spins CFRunLoop from SDL's event pump, which keeps
/// the host's UI and main-actor work running inside the call (`EngineMainThread.run`).
@MainActor
public final class EasyRPGEngineLibrary {
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
            case let .loadFailed(reason): "The EasyRPG Player could not be loaded: \(reason)"
            case let .symbolMissing(name): "The EasyRPG Player is incomplete (\(name) missing)."
            case .alreadySpent: "EasyRPG already ran this launch. OmniPlay has to restart."
            }
        }
    }

    /// `op_easyrpg.h`: host → Player requests, Player → host progress.
    public enum Command: Int32 { case run = 0, pause = 1, stop = 2 }
    public enum Status: Int32 { case idle = 0, booting = 1, running = 2, paused = 3, exited = 4 }

    private struct API {
        let version: @convention(c) () -> UnsafePointer<CChar>?
        let run: @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let request: @convention(c) (Int32) -> Void
        let status: @convention(c) () -> Int32
        let frames: @convention(c) () -> UInt
        let key: @convention(c) (Int32, Int32) -> Void
        let snapshot: @convention(c) (UnsafePointer<CChar>?) -> Int32
        let window: @convention(c) () -> UnsafeMutableRawPointer?
        let appEvent: @convention(c) (Int32) -> Void
    }

    public let binaryURL: URL
    public private(set) var phase: Phase = .notStarted
    private var api: API?
    private static var opened: EasyRPGEngineLibrary?

    /// The framework when this build embeds it.
    public static func bundled(in bundle: Bundle = .main) -> EasyRPGEngineLibrary? {
        if let opened {
            return opened
        }
        guard let binary = bundle.privateFrameworksURL?.appending(path: "EasyRPG.framework/EasyRPG"),
              FileManager.default.fileExists(atPath: binary.path(percentEncoded: false)) else { return nil }
        let library = EasyRPGEngineLibrary(binaryURL: binary)
        opened = library
        return library
    }

    private init(binaryURL: URL) {
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
        let api = try API(
            version: symbol("op_easyrpg_version", as: (@convention(c) () -> UnsafePointer<CChar>?).self),
            run: symbol("op_easyrpg_run", as: (@convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32).self),
            request: symbol("op_easyrpg_request", as: (@convention(c) (Int32) -> Void).self),
            status: symbol("op_easyrpg_status", as: (@convention(c) () -> Int32).self),
            frames: symbol("op_easyrpg_frames", as: (@convention(c) () -> UInt).self),
            key: symbol("op_easyrpg_key", as: (@convention(c) (Int32, Int32) -> Void).self),
            snapshot: symbol("op_easyrpg_snapshot", as: (@convention(c) (UnsafePointer<CChar>?) -> Int32).self),
            window: symbol("op_easyrpg_window", as: (@convention(c) () -> UnsafeMutableRawPointer?).self),
            appEvent: symbol("op_easyrpg_app_event", as: (@convention(c) (Int32) -> Void).self)
        )
        self.api = api
        OPLog.log(.runtime, .info, "loaded EasyRPG Player \(api.version().map { String(cString: $0) } ?? "?")")
        return api
    }

    /// The Player release the framework reports; loads it on first use.
    public func reportedVersion() throws -> String {
        try load().version().map { String(cString: $0) } ?? "unknown"
    }

    public var isAvailable: Bool { phase == .notStarted }

    /// Hands the main thread to the Player and returns at once; `exited` follows when the Player's call returns.
    public func boot(arguments: [String], exited: @escaping @MainActor (Int32) -> Void) throws {
        let api = try load()
        guard isAvailable else { throw Failure.alreadySpent }
        phase = .running
        // strdup'd and never freed: the Player keeps argv for the life of the process.
        let argv = (["easyrpg-player"] + arguments).map { strdup($0) } + [nil]
        // Handed to the run-loop block, which runs on this same main thread; nothing else ever touches it.
        nonisolated(unsafe) let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argv.count)
        buffer.initialize(from: argv, count: argv.count)
        let argc = Int32(argv.count - 1)
        EngineMainThread.run {
            api.run(argc, buffer)
        } exited: { status in
            self.phase = .exited(status)
            exited(status)
        }
    }

    public func request(_ command: Command) { api?.request(command.rawValue) }
    public var status: Status { api.flatMap { Status(rawValue: $0.status()) } ?? .idle }
    public var frames: UInt { api?.frames() ?? 0 }
    public func key(_ scancode: Int32, down: Bool) { api?.key(scancode, down ? 1 : 0) }
    /// Writes the current frame as a PNG; only meaningful while the Player is paused.
    public func snapshot(to url: URL) -> Bool { api?.snapshot(url.path(percentEncoded: false)) == 1 }
    /// SDL's window for the game once the Player has opened it.
    public func window() -> UnsafeMutableRawPointer? { api?.window() }
    /// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active, 4 memory warning.
    public func appEvent(_ event: Int32) { api?.appEvent(event) }
}

/// Which RPG Maker 2000/2003 RTP a folder holds, answered by the Player's own RTP tables (`RTP::Detect`: eleven
/// official and fan releases, a thousand-odd file names between them) rather than a port of them.
public struct EasyRPGRTPMatch: Sendable, Equatable {
    public let family: RTPFamily
    public let name: String
    public let found: Int
    public let expected: Int

    public var summary: String { "\(name), \(found) of \(expected) files" }

    /// Loads the framework if needed; nothing else of the Player starts. Call it only while no 2000/2003 game runs.
    public static func identify(_ folder: URL, bundle: Bundle = .main) -> EasyRPGRTPMatch? {
        guard let binary = bundle.privateFrameworksURL?.appending(path: "EasyRPG.framework/EasyRPG"),
              let handle = dlopen(binary.path(percentEncoded: false), RTLD_NOW | RTLD_LOCAL),
              let pointer = dlsym(handle, "op_easyrpg_rtp_detect") else { return nil }
        typealias Detect = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32
        var out = [CChar](repeating: 0, count: 256)
        guard unsafeBitCast(pointer, to: Detect.self)(folder.path(percentEncoded: false), &out, Int32(out.count)) == 1 else { return nil }
        let fields = String(cString: out).split(separator: "\t").map(String.init)
        guard fields.count == 4, let found = Int(fields[2]), let expected = Int(fields[3]) else { return nil }
        return EasyRPGRTPMatch(family: fields[0] == "2003" ? .rpg2003 : .rpg2000, name: fields[1], found: found, expected: expected)
    }
}
