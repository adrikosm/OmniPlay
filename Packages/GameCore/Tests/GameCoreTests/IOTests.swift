import Foundation
import GameCore
import Synchronization
import Testing
import TestSupport

@Suite("Streaming IO", .serialized)
struct IOTests {
    @Test("Copy and hash of 512 MiB stay under 16 MiB of footprint growth")
    func boundedCopyAndHash() async throws {
        let root = try TemporaryGameRoot(name: "io")
        let size: UInt64 = 512 << 20
        let src = try root.sparseFile("big.bin", bytes: size)
        let dst = root.url.appending(path: "copy.bin")
        let lastProgress = Mutex<Int64>(0)
        let growth = try await MemoryAssert.footprintGrowth {
            try await ChunkedCopier.copy(from: src, to: dst) { p in lastProgress.withLock { $0 = p } }
            let digest = try StreamingHasher.sha256(of: dst)
            #expect(digest.hex.count == 64)
        }
        #expect(lastProgress.withLock { $0 } == Int64(size))
        #expect(try dst.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(size))
        #expect(growth < 16 << 20, "footprint grew by \(growth >> 20) MiB")
    }

    @Test("Hash matches a known digest and the copy is byte-identical")
    func hashKnown() async throws {
        let root = try TemporaryGameRoot(name: "hash")
        let src = try root.file("a.txt", Data("abc".utf8))
        #expect(try StreamingHasher.sha256(of: src).hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let dst = root.url.appending(path: "sub/b.txt")
        try await ChunkedCopier.copy(from: src, to: dst)
        #expect(try Data(contentsOf: dst) == Data("abc".utf8))
        #expect(try BoundedReader.readHeader(url: src, bytes: 2) == Data("ab".utf8))
    }

    @Test("Cancellation leaves no partial destination")
    func cancellation() async throws {
        let root = try TemporaryGameRoot(name: "cancel")
        let src = try root.sparseFile("big.bin", bytes: 256 << 20)
        let dst = root.url.appending(path: "out/copy.bin")
        let task = Task { try await ChunkedCopier.copy(from: src, to: dst, chunk: 64 << 10) { _ in } }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let leftovers = (
            try? FileManager.default.contentsOfDirectory(atPath: root.url.appending(path: "out").path(percentEncoded: false))
        ) ??
            []
        #expect(leftovers.isEmpty)
    }

    @Test("Walker over 100k entries retains nothing")
    func walkerBounded() async throws {
        let root = try TemporaryGameRoot(name: "walk")
        let fm = FileManager.default
        for d in 0 ..< 100 {
            let dir = root.url.appending(path: "dir\(d)", directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0 ..< 1000 {
                let fd = open(dir.appending(path: "f\(f).dat").path(percentEncoded: false), O_CREAT | O_WRONLY, 0o644)
                #expect(fd >= 0)
                close(fd)
            }
        }
        var files = 0, dirs = 0
        let growth = try await MemoryAssert.footprintGrowth {
            try LazyDirectoryWalker.walk(root: root.url) { entry in
                if entry.isDirectory {
                    dirs += 1
                } else {
                    files += 1
                }
                #expect(!entry.relativePath.hasPrefix("/"))
                return .continue
            }
        }
        #expect(files == 100_000)
        #expect(dirs == 100)
        #expect(growth < 32 << 20, "footprint grew by \(growth >> 20) MiB")
    }

    @Test("Walker honours skipDescendants and stop, and reports relative paths")
    func walkerDirectives() throws {
        let root = try TemporaryGameRoot(name: "walk2")
        try root.file("Graphics/Pictures/a.png", Data([1, 2, 3]))
        try root.file("Data/Map001.rxdata")
        try root.file("skip/inner/x")
        var seen: [String] = []
        try LazyDirectoryWalker.walk(root: root.url) { e in
            seen.append(e.relativePath)
            return e.relativePath == "skip" ? .skipDescendants : .continue
        }
        #expect(seen.contains("Graphics/Pictures/a.png"))
        #expect(!seen.contains("skip/inner"))
        var count = 0
        try LazyDirectoryWalker.walk(root: root.url) { _ in count += 1; return .stop }
        #expect(count == 1)
    }

    @Test("APFS clone produces an identical file and free space is readable")
    func cloneAndSpace() async throws {
        let root = try TemporaryGameRoot(name: "clone")
        let src = try root.file("a.bin", Data(repeating: 9, count: 4096))
        let dst = root.url.appending(path: "b.bin")
        try await APFSClone.clone(from: src, to: dst)
        #expect(try Data(contentsOf: dst) == Data(repeating: 9, count: 4096))
        #expect(try VolumeSpace.available(at: root.url) > 0)
        #expect(try VolumeSpace.available(at: root.url.appending(path: "missing/deeper")) > 0)
    }
}

@Suite("Storage budget")
struct StorageBudgetTests {
    @Test("Verdicts at the boundary include the reserve and temporary multiplier")
    func boundaries() {
        let e = StorageEstimate(required: 100, temporary: 100, reason: "t")
        let need = StorageBudget.needed(for: e)
        #expect(need == 100 + 150 + StorageBudget.reserve)
        #expect(StorageBudget.check(e, available: need) == .ok(headroom: 0))
        #expect(StorageBudget.check(e, available: need - 1) == .insufficient(required: need, available: need - 1, shortfall: 1))
        #expect(StorageBudget.check(e, available: need - 1).isBlocking)
        #expect(StorageEstimate.forArchive(uncompressedSizeHint: 10).temporary == 10)
        #expect(StorageEstimate.forTranscode(inputBytes: 100, ratio: 0.5).required == 50)
    }

    @Test("require throws a structured error carrying the verdict")
    func requireThrows() throws {
        let huge = StorageEstimate(required: .max / 4, reason: "impossible import")
        #expect(throws: StorageError.self) { try StorageBudget.require(huge, at: FileManager.default.temporaryDirectory) }
        try StorageBudget.require(.forCopy(bytes: 1), at: FileManager.default.temporaryDirectory)
    }
}
