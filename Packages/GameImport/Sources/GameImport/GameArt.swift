import Foundation
import GameCore

/// Pictures inside a game's own files, for its library cover: RPG Maker MV/MZ encrypted images, a Windows program's
/// icon and Godot's imported textures. Every input is untrusted: sizes are capped and every offset and count is
/// checked against the bytes actually read, so a damaged file gives nil, never a read past the buffer.
public enum GameArt {
    static let maxRPGMakerImage = 32 << 20
    static let maxResourceSection = 16 << 20
    static let maxIcon = 4 << 20
    static let maxEntries = 4096

    /// An MV `.rpgmvp` or MZ `.png_`: a 16-byte `RPGMV` header, then the PNG with its first 16 bytes XORed with the
    /// project key. Those 16 bytes are the same in every PNG (signature, IHDR length and tag), so they are put back
    /// as they are and `System.json`'s key is not needed.
    public static func rpgMakerImage(_ data: Data) -> Data? {
        let magic: [UInt8] = [0x52, 0x50, 0x47, 0x4D, 0x56, 0, 0, 0] // "RPGMV\0\0\0"
        guard data.count > 32, data.count <= maxRPGMakerImage, data.prefix(8).elementsEqual(magic) else { return nil }
        let pngHead: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52]
        return Data(pngHead) + data.dropFirst(32)
    }

    /// Programs whose icon is never the game's: Chromium and Unity helpers, NW.js itself, uninstallers.
    public static func isHelperProgram(_ name: String) -> Bool {
        let n = (name as NSString).deletingPathExtension.lowercased()
        return n == "notification_helper" || n == "nw" || n == "crashpad_handler" || n.hasPrefix("unitycrashhandler")
            || n.hasPrefix("unins")
    }

    /// The largest icon of a Windows program: PNG bytes as stored, or a one-image `.ico` around a DIB.
    public static func peIcon(_ url: URL) -> Data? {
        guard !isHelperProgram(url.lastPathComponent), let head = try? BoundedReader.readHeader(url: url, bytes: 64 << 10),
              let section = resourceSection(head) else { return nil }
        guard section.size > 0, section.size <= maxResourceSection, let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(section.offset))) != nil, let rsrc = try? h.read(upToCount: section.size) else { return nil }
        return peIcon(rsrc: rsrc, virtualAddress: section.virtualAddress)
    }

    /// `.rsrc`'s place in the file from the PE section table: (file offset, raw size, RVA).
    static func resourceSection(_ h: Data) -> (offset: Int, size: Int, virtualAddress: Int)? {
        guard let e = u32(h, 0x3C), h.count >= 0x40, h.prefix(2).elementsEqual([0x4D, 0x5A]), u32(h, e) == 0x0000_4550,
              let sections = u16(h, e + 6), let optSize = u16(h, e + 20) else { return nil }
        let table = e + 24 + optSize
        for i in 0 ..< min(sections, 96) {
            let s = table + i * 40
            guard s + 40 <= h.count else { return nil }
            let name = h[h.startIndex + s ..< h.startIndex + s + 8].prefix { $0 != 0 }
            if name.elementsEqual(".rsrc".utf8), let rva = u32(h, s + 12), let raw = u32(h, s + 16), let ptr = u32(h, s + 20) {
                return (ptr, raw, rva)
            }
        }
        return nil
    }

    /// The resource tree of `.rsrc` (bytes of the section, `virtualAddress` its RVA): type 14 `RT_GROUP_ICON`, the
    /// widest entry (0 means 256), then its type 3 `RT_ICON`.
    public static func peIcon(rsrc: Data, virtualAddress: Int) -> Data? {
        let r = Data(rsrc) // zero-based indices
        /// The entries of the directory at `offset`: (id, offset, isDirectory).
        func entries(_ offset: Int) -> [(id: Int, offset: Int, dir: Bool)]? {
            guard let named = u16(r, offset + 12), let ids = u16(r, offset + 14), named + ids <= maxEntries else { return nil }
            var out: [(Int, Int, Bool)] = []
            for i in 0 ..< named + ids {
                guard let id = u32(r, offset + 16 + i * 8), let target = u32(r, offset + 20 + i * 8) else { return nil }
                out.append((id, target & 0x7FFF_FFFF, target & 0x8000_0000 != 0))
            }
            return out
        }
        /// The first leaf under `entry`, at most two directories further (name, then language).
        func leaf(_ entry: (id: Int, offset: Int, dir: Bool), depth: Int = 1) -> Data? {
            if !entry.dir {
                guard let rva = u32(r, entry.offset), let size = u32(r, entry.offset + 4), size > 0, size <= maxIcon else { return nil }
                let start = rva - virtualAddress
                guard start >= 0, start <= r.count - size else { return nil }
                return r.subdata(in: start ..< start + size)
            }
            guard depth < 3, let first = entries(entry.offset)?.first else { return nil }
            return leaf(first, depth: depth + 1)
        }
        guard let types = entries(0), let group = types.first(where: { $0.id == 14 && $0.dir }).flatMap({ leaf($0) }),
              let icons = types.first(where: { $0.id == 3 && $0.dir }).flatMap({ entries($0.offset) }),
              let count = u16(group, 4), group.count >= 6 + count * 14 else { return nil }
        // GRPICONDIRENTRY: width, height, colours, reserved, planes, bit count, bytes, id (14 bytes).
        var best: (width: Int, bits: Int, at: Int)?
        for i in 0 ..< count {
            let at = 6 + i * 14
            let width = group[at] == 0 ? 256 : Int(group[at])
            let bits = u16(group, at + 6) ?? 0
            if best.map({ (width, bits) > ($0.width, $0.bits) }) ?? true {
                best = (width, bits, at)
            }
        }
        guard let best, let id = u16(group, best.at + 12), let entry = icons.first(where: { $0.id == id }),
              let image = leaf(entry, depth: 2) else { return nil }
        if image.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return image
        }
        // ICONDIR (reserved, type 1, one image) and an ICONDIRENTRY: the group's first 12 bytes, then the offset 22.
        var ico = Data([0, 0, 1, 0, 1, 0])
        ico.append(group.subdata(in: best.at ..< best.at + 8))
        ico.append(contentsOf: withUnsafeBytes(of: UInt32(image.count).littleEndian, Array.init))
        ico.append(contentsOf: withUnsafeBytes(of: UInt32(22).littleEndian, Array.init))
        return ico + image
    }

    /// A Godot imported texture, 3.x `.stex` (`GDST`) or 4.x `.ctex` (`GST2`), when it stores a PNG or WebP: the
    /// embedded file from its signature on. VRAM-compressed textures give nil.
    public static func godotTexture(_ data: Data) -> Data? {
        let d = Data(data)
        guard d.count > 16, d.starts(with: Array("GDST".utf8)) || d.starts(with: Array("GST2".utf8)) else { return nil }
        let window = d.prefix(64)
        if let png = window.firstRange(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
            return d.subdata(in: png.lowerBound ..< d.count)
        }
        if let riff = window.firstRange(of: Data("RIFF".utf8)), riff.lowerBound + 12 <= d.count,
           d[riff.lowerBound + 8 ..< riff.lowerBound + 12].elementsEqual("WEBP".utf8) {
            return d.subdata(in: riff.lowerBound ..< d.count)
        }
        return nil
    }

    private static func u16(_ d: Data, _ o: Int) -> Int? {
        guard o >= 0, o <= d.count - 2 else { return nil }
        return Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }.littleEndian)
    }

    private static func u32(_ d: Data, _ o: Int) -> Int? {
        guard o >= 0, o <= d.count - 4 else { return nil }
        return Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian)
    }
}
