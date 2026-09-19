import Diagnostics
import GameCore
import GameImport
import GameStore
import SwiftUI

enum AppTab: Hashable { case library, importGames, settings }

/// App-wide state: storage paths, the library database, the import coordinator, and which tab is up.
/// Launch work runs off the main actor; the UI shows an overlay when it takes longer than 300 ms.
@Observable @MainActor
final class AppModel {
    enum Phase: Equatable {
        case launching
        case ready
        case storeFailed(String)
    }

    let paths: AppPaths
    private(set) var phase: Phase = .launching
    private(set) var store: GameStore?
    private(set) var importer: ImportCoordinator
    private(set) var imports: ImportsModel?
    var selectedTab: AppTab = .library

    init(paths: AppPaths = HostSession.shared.paths) {
        self.paths = paths
        importer = ImportCoordinator(paths: paths)
        #if DEBUG
            switch DebugLaunch.value(for: "--tab") {
            case "import": selectedTab = .importGames
            case "settings": selectedTab = .settings
            default: break
            }
        #endif
    }

    func launch() async {
        let paths = paths
        let result = await Task.detached(priority: .userInitiated) { () -> Result<GameStore, Error> in
            do {
                try paths.ensureLayout()
                let store = try GameStore.open(paths: paths)
                ImportCoordinator.sweepStaleStaging(paths: paths)
                return .success(store)
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(store):
            self.store = store
            imports = ImportsModel(
                coordinator: importer,
                pipeline: ImportPipeline(paths: paths, store: store, session: HostSession.shared.sessionID)
            )
            phase = .ready
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--sample-library") {
                    SampleLibrary.insert(into: store)
                }
                if let folder = DebugLaunch.value(for: "--import-folder") {
                    await imports?.enqueue(URL(
                        filePath: folder,
                        directoryHint: .isDirectory
                    ))
                }
            #endif
            OPLog.log(.ui, .info, "app ready", session: HostSession.shared.sessionID)
        case let .failure(error):
            phase = .storeFailed(String(describing: error))
            OPLog.log(.ui, .fault, "store failed to open: \(error)", session: HostSession.shared.sessionID)
        }
    }

    /// Deletes only the library database; game files under `Games/` are untouched. Then relaunches.
    func resetLibraryDatabase() async {
        phase = .launching
        let db = paths.database().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: db)
        await launch()
    }
}

#if DEBUG
    /// Launch arguments used by the simulator review scripts; compiled out of release builds.
    enum DebugLaunch {
        static func value(for flag: String) -> String? {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        static var openFirstGame: Bool { ProcessInfo.processInfo.arguments.contains("--open-first-game") }
    }
#endif
