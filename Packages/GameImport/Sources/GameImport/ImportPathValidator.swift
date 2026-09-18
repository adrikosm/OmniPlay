import Foundation

public enum ImportPathError: Error, Equatable, Sendable {
    case empty
    case absolute
    case traversal
    case controlCharacter
    case tooLong
    case tooManyComponents
}

/// Normalises and validates one archive entry path before extraction (design authority §13.3–13.4):
/// `\` → `/`, reject absolute paths and `..`, strip control characters, sanitise Windows reserved
/// names and trailing dots/spaces, store NFC, enforce length limits. Never prefix-compares
/// filesystem paths — the result is a *relative* path the importer joins under the staging root.
public struct ImportPathValidator: Sendable {
    public let limits: ImportLimits

    public init(limits: ImportLimits = .default) {
        self.limits = limits
    }

    private static let reservedNames: Set<String> = {
        var names: Set = ["CON", "PRN", "AUX", "NUL"]
        for n in 1 ... 9 {
            names.insert("COM\(n)")
            names.insert("LPT\(n)")
        }
        return names
    }()

    public func validate(_ rawPath: String) throws -> String {
        let unified = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !unified.isEmpty else { throw ImportPathError.empty }
        guard !unified.hasPrefix("/") else { throw ImportPathError.absolute }
        guard unified.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw ImportPathError.controlCharacter
        }

        var components: [String] = []
        for raw in unified.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(raw)
            if component == "." {
                continue
            }
            if component == ".." {
                throw ImportPathError.traversal
            }
            components.append(Self.sanitize(component))
        }
        guard !components.isEmpty else { throw ImportPathError.empty }
        guard components.count <= limits.maxPathComponents else { throw ImportPathError.tooManyComponents }

        let normalised = components.joined(separator: "/").precomposedStringWithCanonicalMapping
        guard normalised.utf8.count <= limits.maxPathBytes else { throw ImportPathError.tooLong }
        return normalised
    }

    private static func sanitize(_ component: String) -> String {
        var result = component
        while let last = result.last, last == "." || last == " " {
            result.removeLast()
        }
        if result.isEmpty {
            return "_"
        }
        let stem = result.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? result
        if reservedNames.contains(stem.uppercased()) {
            result = "_" + result
        }
        return result
    }
}
