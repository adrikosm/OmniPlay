import Compression
import Foundation

/// Decoders that never produce more than a fixed number of bytes, for sniffing save contents safely.
public enum BoundedDecode {
    /// Inflates a zlib stream (`78 xx` header) or raw deflate data into at most `limit` bytes.
    public static func inflate(_ data: Data, zlibHeader: Bool, limit: Int = 64 << 10) -> Data? {
        let payload = zlibHeader ? data.dropFirst(2) : data[...]
        guard !payload.isEmpty else { return nil }
        var out = Data(count: limit)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            payload.withUnsafeBytes { src -> Int in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
                return compression_decode_buffer(d, limit, s, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    /// LZString `decompressFromBase64`, as RPG Maker MV saves use, stopping once `limit` UTF-16 units are out. Works on
    /// units like the JavaScript original (and `LZString`): a grapheme count never grows, so it cannot bound the output.
    public static func lzStringBase64(_ text: String, limit: Int = 64 << 10) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        var reverse: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() {
            reverse[c] = i
        }
        let input = Array(text)
        guard !input.isEmpty else { return nil }
        var dictionary: [Int: [UInt16]] = [:]
        var enlargeIn = 4, dictSize = 4, numBits = 3
        var result: [UInt16] = []
        func decoded() -> String { String(decoding: result, as: UTF16.self) }
        var value = 0, position = 32, index = 1
        guard let first = reverse[input[0]] else { return nil }
        value = first
        func readBits(_ n: Int) -> Int? {
            var bits = 0, maxPower = 1 << n, power = 1
            while power != maxPower {
                let bit = value & position
                position >>= 1
                if position == 0 {
                    position = 32
                    guard index < input.count, let next = reverse[input[index]] else { return nil }
                    value = next
                    index += 1
                }
                bits |= (bit > 0 ? 1 : 0) * power
                power <<= 1
            }
            return bits
        }
        func literal(_ width: Int) -> [UInt16]? { readBits(width).map { [UInt16($0)] } }
        var entry: [UInt16]
        switch readBits(2) {
        case 0: guard let c = literal(8) else { return nil }; entry = c
        case 1: guard let c = literal(16) else { return nil }; entry = c
        default: return ""
        }
        dictionary[3] = entry
        var w = entry
        result += entry
        while result.count < limit {
            guard var c = readBits(numBits) else { return decoded() }
            switch c {
            case 0, 1:
                guard let ch = literal(c == 0 ? 8 : 16) else { return decoded() }
                dictionary[dictSize] = ch
                c = dictSize
                dictSize += 1
                enlargeIn -= 1
            case 2: return decoded()
            default: break
            }
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits; numBits += 1
            }
            if let known = dictionary[c] {
                entry = known
            } else if c == dictSize, let firstUnit = w.first {
                entry = w + [firstUnit]
            } else {
                return decoded()
            }
            result += entry
            if let firstUnit = entry.first {
                dictionary[dictSize] = w + [firstUnit]
            }
            dictSize += 1
            enlargeIn -= 1
            w = entry
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits; numBits += 1
            }
        }
        return decoded()
    }
}
