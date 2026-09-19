import GameImport
import Testing

@Suite("libarchive link")
struct LibArchiveLinkTests {
    @Test("The static build reports zlib, bzip2, lzma and zstd support")
    func versionDetails() {
        let details = LibArchive.versionDetails
        print("archive_version_details:", details)
        #expect(details.hasPrefix("libarchive 3.8."))
        for backend in ["zlib/", "liblzma/", "bz2lib/", "libzstd/"] {
            #expect(details.contains(backend), "missing \(backend)")
        }
        #expect(LibArchive.versionNumber >= 3_008_000)
    }
}
