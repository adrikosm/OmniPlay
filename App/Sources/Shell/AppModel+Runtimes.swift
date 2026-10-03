import Diagnostics
import EasyRPGRuntime
import Foundation
import GameCore
import GodotRuntime
import RenPyRuntime
import RGSSRuntime
import RuntimeCore
import ScummVMRuntime

/// The native runtimes this build carries, registered with the coordinator and the resolver's registry at launch.
/// Each registers only when its engine is actually in the binary, so the resolver never offers what cannot run.
extension AppModel {
    /// The three Ruby lines are one islanded engine and one boot: the adapter refuses a second launch and
    /// `SessionSlot.diesWith` spends the siblings. Registering each line separately is still right, because the
    /// resolver picks a line per game and the descriptor is what it matches against.
    func registerRGSS(with coordinator: RuntimeCoordinator) async {
        guard RGSSEngineProcess.isLinked else {
            OPLog.log(.runtime, .info, "RGSS engine not linked in this build")
            return
        }
        let assets = Bundle.main.resourceURL?.appending(path: "Assets.bundle", directoryHint: .isDirectory)
            ?? Bundle.main.bundleURL
        let support = RGSSEngineInfo.support()
        OPLog.log(.runtime, .info, "RGSS engine: \(support), assets \(assets.lastPathComponent)")
        var generations: [EngineGeneration] = []
        if support.xp {
            generations.append(.rgss1)
        }
        if support.vx {
            generations.append(.rgss2)
        }
        if support.vxAce {
            generations.append(.rgss3)
        }
        for line in RubyLine.allCases {
            await coordinator.register(.rgss(ruby: line)) { [weak self] _ in
                let runtime = RGSSRuntime(ruby: line, assets: assets)
                runtime.onFailure = { message in self?.runtimeFailure = message }
                return runtime
            }
            await registry.register(.init(
                id: .rgss(ruby: line),
                families: [.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce],
                generations: generations,
                version: "mkxp-z ruby \(line.rawValue.dropFirst(4))",
                flags: [.saves, .mods, .translationPacks, .cheats, .fastForward, .screenshot],
                availability: .bundled
            ))
        }
    }

    /// One engine per Python line, registered only when its framework is in the bundle. For a line this build
    /// does not carry, the resolver falls back to the newest engine and says so in a warning.
    func registerRenPy(with coordinator: RuntimeCoordinator) async {
        for engine in RenPyEngine.allCases {
            guard RenPyEngineLibrary.bundled(engine) != nil,
                  let planned = RuntimeRegistry.planned.first(where: { $0.id == .renpy(engine: engine) }) else { continue }
            await coordinator.register(.renpy(engine: engine)) { _ in
                RenPyRuntime(engine: engine)
            }
            await registry.register(.init(
                id: planned.id,
                families: planned.supportedFamilies,
                generations: planned.supportedGenerations,
                version: engine.version,
                flags: [.saves, .persistentData, .screenshot],
                availability: .bundled
            ))
            OPLog.log(.runtime, .info, "Ren'Py \(engine.version) engine bundled")
        }
    }

    /// RPG Maker 2000 and 2003, registered only when the Player's framework is in the bundle.
    func registerEasyRPG(with coordinator: RuntimeCoordinator) async {
        guard EasyRPGEngineLibrary.bundled() != nil,
              let planned = RuntimeRegistry.planned.first(where: { $0.id == .easyrpg }) else { return }
        await coordinator.register(.easyrpg) { [weak self] _ in
            let runtime = EasyRPGRuntime()
            runtime.onFailure = { message in self?.runtimeFailure = message }
            return runtime
        }
        await registry.register(.init(
            id: .easyrpg,
            families: planned.supportedFamilies,
            generations: planned.supportedGenerations,
            version: "0.8.1.1",
            flags: [.saves, .screenshot],
            availability: .bundled
        ))
        OPLog.log(.runtime, .info, "EasyRPG Player bundled")
    }

    /// ScummVM, registered only when its framework is in the bundle. Its detection becomes the authority for the
    /// ScummVM detector here too, since imports can arrive before any game has started it.
    func registerScummVM(with coordinator: RuntimeCoordinator) async {
        guard ScummVMEngineLibrary.bundled() != nil,
              let planned = RuntimeRegistry.planned.first(where: { $0.id == .scummvm }) else { return }
        let configFile = paths.cachesRoot.appending(path: "scummvm/scummvm.ini")
        ScummVMEngineLibrary.installDetection(configFile: configFile, muted: ProcessInfo.processInfo.environment["OMNIPLAY_MUTE"] != nil)
        await coordinator.register(.scummvm) { [weak self] _ in
            let runtime = ScummVMRuntime(configFile: configFile) { [weak self] in
                self.flatMap { MIDISoundFont.installed(paths: $0.paths) }
            }
            runtime.onFailure = { message in self?.runtimeFailure = message }
            return runtime
        }
        await registry.register(.init(
            id: .scummvm,
            families: planned.supportedFamilies,
            generations: planned.supportedGenerations,
            // Not read from the library: that would load all of ScummVM at app launch.
            version: "2026.3.0",
            flags: [.saves, .screenshot],
            availability: .bundled
        ))
        OPLog.log(.runtime, .info, "ScummVM bundled")
    }

    /// Godot 4 (4.7 bucket) and Godot 3 (3.6 bucket), each registered when its framework is in the bundle.
    func registerGodot(with coordinator: RuntimeCoordinator) async {
        struct Lane { let bucket: GodotBucket, engine: GodotEngineLibrary.Engine, version: String }
        for lane in [Lane(bucket: .v47, engine: .godot4, version: "4.7.2"), Lane(bucket: .v36, engine: .godot3, version: "3.6.3")] {
            let (bucket, engine, version) = (lane.bucket, lane.engine, lane.version)
            guard GodotEngineLibrary.bundled(engine) != nil,
                  let planned = RuntimeRegistry.planned.first(where: { $0.id == .godot(bucket: bucket) }) else { continue }
            await coordinator.register(.godot(bucket: bucket)) { _ in
                GodotRuntime(bucket: bucket)
            }
            await registry.register(.init(
                id: .godot(bucket: bucket),
                families: planned.supportedFamilies,
                generations: planned.supportedGenerations,
                version: version,
                flags: [.saves, .screenshot],
                availability: .bundled
            ))
            OPLog.log(.runtime, .info, "Godot \(version) bundled")
        }
    }
}
