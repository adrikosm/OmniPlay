import Foundation
import GameCore
import GameDetection
import GameStore
import InputKit
import RuntimeCore
import SaveKit
import Testing
import TestSupport

@MainActor
final class FakeRuntime: GameRuntime {
    static let runtimeID = RuntimeIdentifier.web
    let capabilities = RuntimeCapabilities(canInspectState: false, canMutateState: false, pause: .backgroundVisible, multiSession: true)
    let renderSurface = RuntimeSurface.webView
    var log: [String] = []
    var verdict: TeardownVerdict = .clean
    var failPrepare = false
    func prepare(configuration _: RuntimeConfiguration) async throws {
        log.append("prepare"); if failPrepare {
            throw CoordinatorError.busy
        }
    }

    func start(in _: any RuntimeHost) async throws { log.append("start") }
    func pause() async { log.append("pause") }
    func resume() async { log.append("resume") }
    func send(_: GameInputEvent) {}
    func inspect(_: StateInspectionRequest) async throws -> StateInspectionResult { .init(path: "", json: "{}") }
    func mutate(_: StateMutation) async throws -> StateMutationResult { .init(applied: false) }
    func saveSnapshot() async throws -> SaveSnapshot { .init(
        provenance: .init(gameIdentityHash: "h", origin: .manualSnapshot),
        files: [],
        checksum: ""
    ) }
    func handleMemoryPressure(_: MemoryPressureLevel) {}
    func handleThermalState(_: ProcessInfo.ThermalState) {}
    func stop(reason _: RuntimeStopReason) async -> TeardownVerdict { log.append("stop"); return verdict }
}

@MainActor
final class FakeHost: RuntimeHost {
    let sessionID = SessionID()
    let orientationPreference = OrientationPreference.any
    var events: [RuntimeEvent] = []
    func runtimeDidEmit(_ event: RuntimeEvent) { events.append(event) }
    #if canImport(UIKit)
        let containerView = UIView()
    #endif
}

import Diagnostics

@Suite("Runtime coordinator", .serialized)
struct CoordinatorTests {
    private func request(runtime: RuntimeIdentifier? = .web) -> LaunchRequest {
        let paths = AppPaths.temporary()
        let d = GameDescriptor(title: "T", engine: .rpgMakerMV, identityHash: "h")
        let record = GameRecord(id: d.id, title: "T", engine: .rpgMakerMV)
        let res = RuntimeResolution(
            selectedRuntime: runtime,
            selectedRuntimeVersion: "webkit",
            confidence: 1,
            reason: "test",
            flags: [],
            requiredPreparation: [],
            warnings: [],
            fallbacks: [],
            slot: runtime?.slot,
            profile: .init(),
            outcome: .supported,
            manualOverride: false
        )
        return LaunchRequest(record: record, descriptor: d, resolution: res, configuration: .forGame(d, paths: paths, profile: .init()))
    }

    @Test("Launch runs prepare then start, records the session, and stop releases the adapter")
    func lifecycle() async throws {
        let coordinator = RuntimeCoordinator(store: nil)
        weak var weakRuntime: FakeRuntime?
        await coordinator.register(.web) { _ in let r = FakeRuntime(); return r }
        let host = await FakeHost()
        let req = request()
        #expect(await coordinator.preflight(req) == .ok)
        let session = try await coordinator.launch(req, host: host)
        #expect(session.runtime == .web)
        guard case .running = await coordinator.state else { Issue.record("not running"); return }
        #expect(await coordinator.holdsRuntime)
        await #expect(throws: CoordinatorError.busy) { try await coordinator.launch(req, host: host) }
        await coordinator.pause()
        guard case .paused = await coordinator.state else { Issue.record("not paused"); return }
        await coordinator.resume()
        let verdict = await coordinator.stop(reason: .userExit)
        #expect(verdict == .clean)
        #expect(await coordinator.state == .idle)
        #expect(await !(coordinator.holdsRuntime))
        _ = weakRuntime
    }

    @Test("Preflight reports missing runtimes and unbuilt factories; prepare failure ends in failed")
    func preflightAndFailures() async throws {
        let coordinator = RuntimeCoordinator(store: nil)
        let host = await FakeHost()
        #expect(await coordinator.preflight(request(runtime: nil)) == .noRuntime("test"))
        #expect(await coordinator.preflight(request()) == .notBuilt(.web))
        await #expect(throws: CoordinatorError.preflight(.notBuilt(.web))) { try await coordinator.launch(request(), host: host) }
        await coordinator.register(.web) { _ in let r = FakeRuntime(); r.failPrepare = true; return r }
        // failed is idle-class, so a new launch may be attempted
        await #expect(throws: CoordinatorError.self) { try await coordinator.launch(request(), host: host) }
        guard case .failed = await coordinator.state else { await Issue.record("expected failed, got \(coordinator.state)"); return }
        #expect(await !(coordinator.holdsRuntime))
    }

    @Test("A slotSpent verdict marks the ledger and a one-shot slot then requires a restart")
    func slotSpent() async throws {
        let coordinator = RuntimeCoordinator(store: nil)
        await coordinator.register(.rgss(ruby: .ruby18)) { _ in let r = FakeRuntime(); r.verdict = .slotSpent; return r }
        let host = await FakeHost()
        var req = request(runtime: .rgss(ruby: .ruby18))
        _ = try await coordinator.launch(req, host: host)
        #expect(await coordinator.stop(reason: .userExit) == .slotSpent)
        req = request(runtime: .rgss(ruby: .ruby18))
        guard case .slotSpent = await coordinator.preflight(req) else { Issue.record("slot not spent"); return }
    }
}

@Suite("Web watchdog and profile")
struct WebSupportTests {
    @Test("Heartbeat gaps and terminations drive reload, then give-up after three in ten minutes")
    func watchdog() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var w = WebProcessWatchdog(now: t0)
        #expect(w.tick(now: t0.addingTimeInterval(5)) == .none)
        _ = w.handle(.heartbeat, now: t0.addingTimeInterval(6))
        #expect(w.tick(now: t0.addingTimeInterval(13)) == .none)
        guard case .reloadAndAutoload = w.tick(now: t0.addingTimeInterval(15)) else { Issue.record("no reload"); return }
        #expect(w.tick(now: t0.addingTimeInterval(16)) == .none) // already suspected, no double fire
        _ = w.handle(.pageBooted, now: t0.addingTimeInterval(20))
        guard case .reloadAndAutoload = w.handle(.terminated, now: t0.addingTimeInterval(30))
        else { Issue.record("no reload on terminate"); return }
        guard case .giveUp = w.handle(.terminated, now: t0.addingTimeInterval(40)) else { Issue.record("no give up"); return }
        var paused = WebProcessWatchdog(now: t0)
        _ = paused.handle(.paused, now: t0)
        #expect(paused.tick(now: t0.addingTimeInterval(100)) == .none)
        var old = WebProcessWatchdog(now: t0)
        _ = old.handle(.terminated, now: t0)
        _ = old.handle(.terminated, now: t0.addingTimeInterval(1))
        guard case .reloadAndAutoload = old.handle(.terminated, now: t0.addingTimeInterval(700))
        else { Issue.record("window not sliding"); return }
    }

    @Test("Web profiles derive per family and the bundle scripts load with the profile inlined")
    func profile() throws {
        var mz = GameDescriptor(title: "mz", engine: .rpgMakerMZ, identityHash: "h")
        mz.warnings = [.nodePlugin(file: "js/plugins/NwFs.js", apis: ["require('fs'", "path."])]
        let p = WebProfile.derive(from: mz)
        #expect(p.isGameActivePatch && p.nwUndefined && p.shims == ["fsReadOnly", "pathPosix"] && p.orientation == .landscape)
        var unity = GameDescriptor(title: "u", engine: .unityWeb, identityHash: "h")
        unity.profile = CompatibilityProfile(overrides: ["coopCoep": "true", "forceWebGL2": "true"])
        let u = WebProfile.derive(from: unity)
        #expect(u.coopCoep && u.forceWebGL2 && !u.nwUndefined && u.headerPolicy.coopCoep)
        var mv = GameDescriptor(title: "mv", engine: .rpgMakerMV, identityHash: "h")
        mv.mediaRequirements = [MediaRequirement(
            sourceRel: "a.ogg",
            container: "ogg",
            videoCodec: nil,
            audioCodec: "vorbis",
            requiredForRuntime: .web,
            action: .shim("audioFileExtOgg")
        )]
        #expect(WebProfile.derive(from: mv).audioFileExtOgg)
        for name in WebRuntimeBundle.isolatedScripts + WebRuntimeBundle.pageScripts {
            let src = try WebRuntimeBundle.source(name, profile: p)
            #expect(!src.contains("__OMNIPLAY_PROFILE__"), Comment(rawValue: name))
        }
        #expect(try WebRuntimeBundle.source("omniplay-nw-shim", profile: p).contains("\"shims\":[\"fsReadOnly\",\"pathPosix\"]"))
    }
}
