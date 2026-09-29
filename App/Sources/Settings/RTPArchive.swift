import Foundation
import GameCore
import GameImport

/// An RTP that arrives as a file rather than a folder: a ZIP, 7z, RAR or tar of the RTP folder, or a Windows installer
/// whose payload the importer can already read (an appended archive, or cabinets). It is unpacked under the same safety
/// limits as a game import into a staging folder, which the caller installs from and then removes. Installers that pack
/// their files another way (Inno Setup, which the official XP/VX/VX Ace RTPs use) are refused with what to do instead.
enum RTPArchive {
    struct Extracted {
        /// The unpacked files; `RTPManager.locateRoot` finds the RTP inside.
        let folder: URL
        /// Remove when done, whatever happened.
        let staging: URL
    }

    enum Failure: Error, LocalizedError {
        case notAnArchive
        case installer
        case passwordProtected
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive: "Choose the RTP folder, or a ZIP, 7z or RAR of it."
            case .installer:
                "This installer packs its files in a way OmniPlay can't unpack. On a computer, install or unpack it "
                    + "(innoextract works), zip the RTP folder, and import the ZIP."
            case .passwordProtected: "This archive is password-protected. Unpack it on a computer and import the folder or a new ZIP."
            case let .unreadable(detail): "The archive could not be unpacked: \(detail)"
            }
        }
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Unpacks `url` off the main actor's caller; throws `Failure` (or `StorageError` when the disk is too full).
    static func extract(_ url: URL, paths: AppPaths) throws -> Extracted {
        let staging = paths.importStaging(txn: UUID())
        let folder = staging.appending(path: "RTP", directoryHint: .isDirectory)
        do {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let totals: RunningTotals
            switch try ContainerSniffer.identify(url) {
            case .zip, .sevenZip, .tar, .gzip, .xz, .zstd:
                totals = try libarchive(url, to: folder, offset: 0, paths: paths)
            case .rar4, .rar5:
                totals = try rar(url, to: folder, paths: paths)
            case .cab:
                totals = try cab(url, to: folder, paths: paths)
            case .pe:
                switch try PEOverlayScanner.scan(url)?.kind {
                case .cab?:
                    totals = try cab(url, to: folder, paths: paths)
                case let .appendedZip(offset)?, let .appendedSevenZip(offset)?:
                    totals = try libarchive(url, to: folder, offset: offset, paths: paths)
                case .appendedRar?:
                    totals = try rar(url, to: folder, paths: paths)
                default:
                    throw Failure.installer
                }
            default:
                throw Failure.notAnArchive
            }
            _ = try PostExtractionAudit.run(root: folder, totals: totals, sourceBytes: size > 0 ? size : nil)
            return Extracted(folder: folder, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            switch error {
            case is Failure, is StorageError, is CancellationError: throw error
            case ImportFailure.passwordRequired, ImportFailure.passwordIncorrect: throw Failure.passwordProtected
            default: throw Failure.unreadable(String(describing: error))
            }
        }
    }

    private static func libarchive(_ url: URL, to folder: URL, offset: Int64, paths: AppPaths) throws -> RunningTotals {
        let extractor = LibArchiveExtractor()
        // Japanese releases name their files in CP932; the same judge as a game import picks the charset.
        let charset = offset == 0 ? try NameDecoder.charset(for: url, extractor: extractor) : nil
        let pre = try extractor.preflight(url, hdrcharset: charset, offset: offset)
        guard !pre.encrypted else { throw Failure.passwordProtected }
        let hint = pre.sizesKnown ? pre.declaredBytes : Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) * 4
        try StorageBudget.require(.forArchive(uncompressedSizeHint: hint), at: paths.root)
        return try extractor.extract(url, to: folder, hdrcharset: charset, offset: offset)
    }

    private static func rar(_ url: URL, to folder: URL, paths: AppPaths) throws -> RunningTotals {
        let extractor = RarExtractor()
        let pre = try extractor.preflight(url)
        guard !pre.encrypted else { throw Failure.passwordProtected }
        try StorageBudget.require(.forArchive(uncompressedSizeHint: pre.declaredBytes), at: paths.root)
        return try extractor.extract(url, to: folder)
    }

    private static func cab(_ url: URL, to folder: URL, paths: AppPaths) throws -> RunningTotals {
        let extractor = CabExtractor()
        let pre = try extractor.preflight(url)
        try StorageBudget.require(.forArchive(uncompressedSizeHint: pre.declaredBytes), at: paths.root)
        return try extractor.extract(url, to: folder)
    }
}
