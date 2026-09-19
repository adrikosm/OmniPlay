import Foundation
import GameCore
import GameImport
import Testing
import TestSupport

@Suite("ASAR extraction")
struct AsarExtractorTests {
    @Test("The Electron fixture unpacks byte-identical, including the unpacked sibling")
    func fixture() throws {
        let root = try TemporaryGameRoot(name: "asar")
        defer { root.remove() }
        let asar = Fixtures.url("electron-asar/resources/app.asar")
        let header = try AsarExtractor.header(of: asar)
        #expect((header.json["files"] as? [String: Any])?.keys.sorted() == ["data", "img", "index.html", "js", "package.json"])
        let out = root.url.appending(path: "app")
        let totals = try AsarExtractor().extract(asar, to: out)
        #expect(totals.entries == 8 && totals.writtenBytes > 0)
        #expect(try String(contentsOf: out.appending(path: "js/game.js"), encoding: .utf8).contains("getElementById"))
        #expect(try Data(contentsOf: out.appending(path: "img/icon.png")) ==
            Data(contentsOf: Fixtures.url("mv-basic/www/img/system/Title1.png")))
        let pattern = Data((0 ..< 64).flatMap { _ in (0 ..< 256).map { UInt8($0) } })
        #expect(try Data(contentsOf: out.appending(path: "data/big.bin")) == pattern)
    }

    @Test("Traversal names and implausible headers are refused")
    func malformed() throws {
        let root = try TemporaryGameRoot(name: "asar-bad")
        defer { root.remove() }
        let bad = root.url.appending(path: "bad.asar")
        try Self.asar(["../evil.txt": Data("x".utf8)]).write(to: bad)
        #expect(throws: SafetyViolation.self) { try AsarExtractor().extract(bad, to: root.url.appending(path: "out")) }
        let short = root.url.appending(path: "short.asar")
        try Data([4, 0, 0, 0, 1]).write(to: short)
        #expect(throws: ImportFailure.self) { try AsarExtractor.header(of: short) }
    }

    /// Minimal ASAR writer mirroring the fixture script.
    static func asar(_ files: [String: Data]) throws -> Data {
        var tree: [String: Any] = [:]
        var body = Data()
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            tree[path] = ["size": data.count, "offset": String(body.count)]
            body.append(data)
        }
        let header = try JSONSerialization.data(withJSONObject: ["files": tree])
        let pad = (4 - header.count % 4) % 4
        var out = Data()
        func u32(_ v: Int) { var le = UInt32(v).littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        let pickle = 4 + header.count + pad
        u32(4); u32(pickle + 4); u32(pickle); u32(header.count)
        out.append(header); out.append(Data(count: pad)); out.append(body)
        return out
    }
}
