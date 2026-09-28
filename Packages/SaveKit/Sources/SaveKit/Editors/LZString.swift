import Foundation

/// LZString `compressToBase64`, as RPG Maker MV writes its saves (the MIT-licensed lz-string 1.4 algorithm). Decoding
/// is `BoundedDecode.lzStringBase64`. Works on UTF-16 code units like the JavaScript original; the dictionary is keyed
/// by (prefix code, next unit) instead of by strings, which gives the same codes.
public enum LZString {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// As RPG Maker MV's bundled lz-string (the 1.3 line) writes it: compress to 16-bit units, then base64 of their
    /// big-endian bytes. The bit stream is the one lz-string 1.4 writes in 6-bit steps, padded to 16 bits instead of 6,
    /// which both decoder generations read; 1.4's shorter padding can lose the end marker in a 1.3 decoder.
    public static func compressToBase64(_ input: String) -> String {
        var units: [UInt16] = []
        _ = compress(Array(input.utf16), bitsPerChar: 16) { value in
            units.append(UInt16(value))
            return " "
        }
        var bytes = Data(capacity: units.count * 2)
        for unit in units {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        return bytes.base64EncodedString()
    }

    /// The whole text, or nil when the stream is malformed or would exceed `limit` UTF-16 units. Strict, unlike the
    /// sniffing decoder in `BoundedDecode`: an editor must never write back a save it only half read.
    public static func decompressFromBase64(_ text: String, limit: Int = 128 << 20) -> String? {
        var reverse = [Int](repeating: -1, count: 128)
        for (i, c) in alphabet.enumerated() {
            reverse[Int(c.asciiValue!)] = i
        }
        let input = Array(text.utf8).filter { $0 != UInt8(ascii: "=") }
        guard !input.isEmpty else { return nil }
        func next(_ index: Int) -> Int? {
            guard index < input.count else { return 0 }
            let byte = Int(input[index])
            return byte < 128 && reverse[byte] >= 0 ? reverse[byte] : nil
        }
        guard var value = next(0) else { return nil }
        var position = 32, index = 1, malformed = false
        func read(_ n: Int) -> Int {
            var bits = 0, power = 1
            for _ in 0 ..< n {
                let bit = value & position
                position >>= 1
                if position == 0 {
                    position = 32
                    guard let v = next(index) else { malformed = true; return 0 }
                    value = v
                    index += 1
                }
                if bit > 0 {
                    bits |= power
                }
                power <<= 1
            }
            return bits
        }
        var dictionary: [[UInt16]] = [[], [], []]
        var enlargeIn = 4, numBits = 3
        let first: UInt16
        switch read(2) {
        case 0: first = UInt16(read(8))
        case 1: first = UInt16(read(16))
        default: return ""
        }
        dictionary.append([first])
        var w: [UInt16] = [first]
        var result: [UInt16] = [first]
        while true {
            guard index <= input.count, !malformed else { return nil }
            var c = read(numBits)
            switch c {
            case 0, 1:
                dictionary.append([UInt16(read(c == 0 ? 8 : 16))])
                c = dictionary.count - 1
                enlargeIn -= 1
            case 2:
                return malformed ? nil : String(decoding: result, as: UTF16.self)
            default: break
            }
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
            let entry: [UInt16]
            if c < dictionary.count {
                entry = dictionary[c]
            } else if c == dictionary.count {
                entry = w + [w[0]]
            } else {
                return nil
            }
            result += entry
            guard result.count <= limit, !entry.isEmpty else { return nil }
            dictionary.append(w + [entry[0]])
            enlargeIn -= 1
            w = entry
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }
    }

    static func compress(_ units: [UInt16], bitsPerChar: Int, char: (Int) -> Character) -> String {
        var singles: [UInt16: Int] = [:]
        var pairs: [Int: Int] = [:]
        var pending = Set<UInt16>()
        var dictSize = 3, numBits = 2, enlargeIn = 2
        var output = ""
        output.reserveCapacity(units.count / 2)
        var value = 0, position = 0

        func bit(_ b: Int) {
            value = (value << 1) | b
            if position == bitsPerChar - 1 {
                position = 0
                output.append(char(value))
                value = 0
            } else {
                position += 1
            }
        }
        func bits(_ v: Int, _ count: Int) {
            var v = v
            for _ in 0 ..< count {
                bit(v & 1)
                v >>= 1
            }
        }
        func grow() {
            enlargeIn -= 1
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }
        // w: the current phrase, as its code, and its unit when it is a single unit.
        var wCode: Int?
        var wUnit: UInt16?
        func emit() {
            guard let code = wCode else { return }
            if let unit = wUnit, pending.contains(unit) {
                if unit < 256 {
                    bits(0, numBits)
                    bits(Int(unit), 8)
                } else {
                    bits(1, numBits)
                    bits(Int(unit), 16)
                }
                grow()
                pending.remove(unit)
            } else {
                bits(code, numBits)
            }
            grow()
        }

        for c in units {
            if singles[c] == nil {
                singles[c] = dictSize
                dictSize += 1
                pending.insert(c)
            }
            guard let w = wCode else {
                wCode = singles[c]
                wUnit = c
                continue
            }
            let key = w << 16 | Int(c)
            if let code = pairs[key] {
                wCode = code
                wUnit = nil
                continue
            }
            emit()
            pairs[key] = dictSize
            dictSize += 1
            wCode = singles[c]
            wUnit = c
        }
        emit()
        bits(2, numBits)
        // Flush the last partial character.
        while true {
            value <<= 1
            if position == bitsPerChar - 1 {
                output.append(char(value))
                break
            }
            position += 1
        }
        return output
    }
}
