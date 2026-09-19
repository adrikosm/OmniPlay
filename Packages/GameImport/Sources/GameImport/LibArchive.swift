import CLibArchive
import Foundation

/// The vendored libarchive build, as Swift sees it.
public enum LibArchive {
    /// e.g. `libarchive 3.8.9 zlib/1.2.12 liblzma/5.8.4 bz2lib/1.0.8 libzstd/1.5.7`
    public static var versionDetails: String { String(cString: archive_version_details()) }
    public static var versionNumber: Int { Int(archive_version_number()) }
}
