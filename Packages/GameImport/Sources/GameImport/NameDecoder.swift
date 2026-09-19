import Foundation

/// Picks the header charset for archives whose entry names are not valid UTF-8. libarchive (with iconv) is the
/// judge: the first charset that decodes every name wins. Japanese Windows archives (CP932) are the common case.
/// ponytail: no plausibility scoring; add letter/CJK ratio scoring when a CP1252 false positive shows up in the corpus.
public enum NameDecoder {
    public static let candidates = ["CP932", "CP1252", "CP949"]

    /// Nil when names are already fine, or the name of the charset to pass as `hdrcharset`.
    public static func charset(for url: URL, extractor: LibArchiveExtractor) throws -> String? {
        guard try extractor.preflight(url).undecodableNames else { return nil }
        for charset in candidates where (try? extractor.preflight(url, hdrcharset: charset).undecodableNames) == false {
            return charset
        }
        return nil // libarchive falls back to raw bytes; the validator still normalises to NFC
    }
}
