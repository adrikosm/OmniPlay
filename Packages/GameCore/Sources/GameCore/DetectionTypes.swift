import Foundation

/// A fact that stops a game from running on this platform.
public enum Blocker: Codable, Sendable, Hashable {
    case nativeBinary(path: String)
    case gdextension([String])
    case encryptedPCK
    case csharpExport
    case nodePlugin(file: String, api: String)
}

/// Something the player should know before pressing Play.
public enum GameWarning: Codable, Sendable, Hashable {
    case nodePlugin(file: String, apis: [String])
    case multipleEntryPoints([String])
    case live2dRequiresLicensedCore
    case mediaTranscodeRequired(count: Int)
    case rtpRequired(String)
    case soundfontRequired
    case unknownVersion(String)
    case note(String)
}

public enum SaveFamily: String, Codable, Sendable, CaseIterable, Hashable {
    case webLocalStorage, webIndexedDB, rgssMarshal, renpySave, easyrpgLSD, scummvm, godotUserDir, love, unknown
}

public enum ExportPlatform: String, Codable, Sendable, CaseIterable, Hashable {
    case windows, linux, macos, android, web, unknown
}

/// What has to happen to one media file before a given runtime can play it.
public struct MediaRequirement: Codable, Sendable, Hashable {
    public enum Action: Codable, Sendable, Hashable {
        case none
        case useSibling(String)
        /// Target described as container/video/audio names, e.g. `mp4/h264/aac`.
        case transcode(target: String)
        case shim(String)
    }

    public let sourceRel: String
    public let container: String
    public let videoCodec: String?
    public let audioCodec: String?
    public let requiredForRuntime: RuntimeIdentifier
    public let action: Action

    public init(
        sourceRel: String,
        container: String,
        videoCodec: String?,
        audioCodec: String?,
        requiredForRuntime: RuntimeIdentifier,
        action: Action
    ) {
        self.sourceRel = sourceRel
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.requiredForRuntime = requiredForRuntime
        self.action = action
    }
}
