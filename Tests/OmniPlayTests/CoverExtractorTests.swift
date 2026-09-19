import CoreGraphics
import Foundation
import GameCore
import ImageIO
@testable import OmniPlay
import OverlayVFS
import Testing
import UniformTypeIdentifiers

@Suite("Cover extraction")
struct CoverExtractorTests {
    @Test("An MV title image becomes a JPEG cover no larger than 1024 px; a title without art gets none")
    func extractsAndBounds() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appending(path: "S"), cachesRoot: root.appending(path: "C"), exportsRoot: root.appending(path: "E"))
        let id = GameID()
        let original = paths.tier(.original, for: id)
        let title = original.appending(path: "www/img/system/Title1.png")
        try FileManager.default.createDirectory(at: title.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writePNG(width: 2048, height: 1536, to: title)
        try PathIndex.open(at: paths.game(id).appending(path: "index.sqlite")).rebuild(layer: "original", root: original)

        let path = try #require(CoverExtractor.extract(game: id, engine: .rpgMakerMV, rootRelativePath: "", paths: paths))
        #expect(path.hasSuffix("Artwork/cover.jpg"))
        let source = try #require(CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(width == 1024 && height == 768, "\(width)x\(height)")

        let bare = GameID()
        try FileManager.default.createDirectory(at: paths.tier(.original, for: bare), withIntermediateDirectories: true)
        try PathIndex.open(at: paths.game(bare).appending(path: "index.sqlite")).rebuild(
            layer: "original",
            root: paths.tier(.original, for: bare)
        )
        #expect(CoverExtractor.extract(game: bare, engine: .rpgMakerMV, rootRelativePath: "", paths: paths) == nil)
    }

    private static func writePNG(width: Int, height: Int, to url: URL) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
