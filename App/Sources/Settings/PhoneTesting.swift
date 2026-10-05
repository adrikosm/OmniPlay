import Diagnostics
import Foundation
import GameCore
import GameImport
import GameStore
import UIKit
import UserNotifications

/// Tools for the phone pass that ship in the release build: a large synthetic game to import (PERF-002/004), a
/// memory warning on demand (PERF-007), the signing expiry (BUILD-009) and a backup of everything before a reinstall.
enum PhoneTesting {
    // MARK: Large test game

    /// An MV-shaped game of `gigabytes` in Documents/OmniPlay/Test games, ready to import from Files. Bodies are
    /// sparse (the size is declared, not written) except one file in fifty, which gets real bytes so hashing and
    /// copying have work to do. Mirrors `Scripts/make-large-fixture.py --mode mv-like`.
    static func makeLargeGame(gigabytes: Int, documents: URL, progress: @Sendable (Double) -> Void) throws -> URL {
        let fm = FileManager.default
        let root = documents.appending(path: "OmniPlay/Test games/Large test game \(gigabytes) GB", directoryHint: .isDirectory)
        try? fm.removeItem(at: root)
        let total = Int64(gigabytes) << 30, count = gigabytes * 3000
        // Folder and its share of the size; the extension follows the folder.
        let folders: [(String, Double)] = [
            ("www/img/pictures", 0.35), ("www/img/tilesets", 0.1), ("www/img/characters", 0.05),
            ("www/audio/bgm", 0.2), ("www/audio/se", 0.05), ("www/movies", 0.2), ("www/data", 0.05),
        ]
        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        var made = 0
        for (folder, share) in folders {
            let ext = folder.contains("img") ? "png" : folder.contains("audio") ? "ogg" : folder.hasSuffix("movies") ? "webm" : "json"
            let dir = root.appending(path: folder, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let files = max(1, Int(Double(count) * share)), size = Int64(Double(total) * share) / Int64(files)
            for i in 0 ..< files {
                let url = dir.appending(path: "\(dir.lastPathComponent)_\(String(format: "%06d", i)).\(ext)")
                guard fm.createFile(atPath: url.path(percentEncoded: false), contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                if made % 50 == 0 {
                    var left = size
                    while left > 0 {
                        let n = Int(min(left, Int64(block.count)))
                        try handle.write(contentsOf: block.prefix(n))
                        left -= Int64(n)
                    }
                } else {
                    try handle.truncate(atOffset: UInt64(size))
                }
                made += 1
                if made % 500 == 0 {
                    progress(Double(made) / Double(count))
                }
            }
        }
        let markers = [
            "www/index.html": "<!DOCTYPE html><html><head><title>Large</title></head>"
                + "<body><script src='js/rpg_core.js'></script></body></html>",
            "www/js/rpg_core.js": "// rpg_core.js v1.6.2\nUtils.RPGMAKER_NAME = \"MV\";\nUtils.RPGMAKER_VERSION = \"1.6.2\";\n",
            "www/js/plugins.js": "var $plugins =\n[\n];\n",
            "www/data/System.json": #"{"gameTitle": "Large Synthetic", "hasEncryptedImages": false, "#
                + #""hasEncryptedAudio": false, "encryptionKey": ""}"#,
            "package.json": #"{"name": "large", "main": "www/index.html"}"#,
        ]
        for (rel, text) in markers {
            let url = root.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        OPLog.log(.importer, .info, "made a \(gigabytes) GB test game with \(made) files at \(root.path(percentEncoded: false))")
        return root
    }

    // MARK: Memory warning

    /// The memory warning iOS sends when the phone runs short, sent now. A private call; fine for a personal build.
    @MainActor
    static func simulateMemoryWarning() {
        OPLog.log(.memory, .default, "memory warning requested from Settings → Testing")
        UIApplication.shared.perform(NSSelectorFromString("_performMemoryWarning"))
    }

    // MARK: Signing expiry

    /// When the build's provisioning profile stops working: seven days after a Personal Team build. Nil on the
    /// simulator, which has no profile.
    static let signingExpiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound ..< end.upperBound], format: nil)
              as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    /// A notification a day before the build expires, so it can be rebuilt before OmniPlay stops opening.
    static func remindBeforeExpiry() async {
        guard let expiry = signingExpiry else { return }
        OPLog.log(.runtime, .info, "this build is signed until \(expiry.formatted(.iso8601))")
        let remindAt = expiry.addingTimeInterval(-86400)
        let center = UNUserNotificationCenter.current()
        guard remindAt > .now, await (try? center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "OmniPlay expires tomorrow"
        content.body = "Rebuild and install it from your Mac before then; your games and saves stay on the phone."
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: remindAt)
        try? await center.add(UNNotificationRequest(
            identifier: "signing-expiry",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        ))
    }

    // MARK: Export everything

    /// One ZIP in Documents with every game's saves and overrides (mods, translations, settings), rescued saves, the
    /// library database and the app's preferences: what a reinstall or a new phone needs. Game files are not
    /// included; they come back by importing the games again. Staged with APFS clones, so staging costs no space.
    static func exportEverything(paths: AppPaths, store: GameStore) throws -> URL {
        let fm = FileManager.default
        let staging = paths.cachesRoot.appending(path: "Export-everything-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appending(path: "Database"), withIntermediateDirectories: true)
        try store.backup(to: staging.appending(path: "Database/omniplay.sqlite"))
        for game in (try? fm.contentsOfDirectory(at: paths.games(), includingPropertiesForKeys: nil)) ?? [] {
            for part in ["Saves", "Overrides"] where fm.fileExists(atPath: game.appending(path: part).path(percentEncoded: false)) {
                let target = staging.appending(path: "Games/\(game.lastPathComponent)/\(part)")
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: game.appending(path: part), to: target)
            }
        }
        if fm.fileExists(atPath: paths.rescuedSaves().path(percentEncoded: false)) {
            try fm.copyItem(at: paths.rescuedSaves(), to: staging.appending(path: "RescuedSaves"))
        }
        if let id = Bundle.main.bundleIdentifier, let prefs = UserDefaults.standard.persistentDomain(forName: id) {
            try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
                .write(to: staging.appending(path: "Preferences.plist"))
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let zip = paths.exportsRoot.deletingLastPathComponent().appending(path: "OmniPlay-Everything-\(stamp).zip")
        let readme = "OmniPlay backup: Database (the library), Games/<id>/Saves and Overrides, RescuedSaves, Preferences.\n"
        let entries = try ArchiveWriter().zip(directory: staging, to: zip, prefix: "OmniPlay", extras: [("README.txt", Data(readme.utf8))])
        OPLog.log(.save, .info, "exported everything: \(entries) files → \(zip.path(percentEncoded: false))")
        return zip
    }
}
