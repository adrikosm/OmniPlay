import Foundation
import GameCore

/// The soundfont MIDI is synthesised from. RPG Maker 2000, 2003, XP and VX music (their RTPs' included) is MIDI, and
/// both mkxp-z and the EasyRPG Player play it through FluidSynth (`Frameworks/libfluidsynth.dylib`, built by
/// `Scripts/native/build-fluidsynth.sh`). The app bundles GeneralUser GS; one `.sf2` the player imports into
/// `SoundFonts/` replaces it. FluidSynth here reads `.sf2` only.
public enum MIDISoundFont {
    public static let extensions: Set<String> = ["sf2"]

    /// The soundfont to configure: the one the player imported, else the bundled one.
    public static func installed(paths: AppPaths, bundle: Bundle = .main) -> URL? {
        imported(paths: paths) ?? bundle.url(forResource: "GeneralUser-GS", withExtension: "sf2")
    }

    public static func imported(paths: AppPaths) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: paths.soundFonts(), includingPropertiesForKeys: nil)) ?? [])
            .first { extensions.contains($0.pathExtension.lowercased()) }
    }

    /// Copies a user-chosen `.sf2` into `SoundFonts/`, replacing the previous import. Soundfonts run to hundreds of
    /// megabytes, so the copy is chunked and lands under a temporary name first.
    public static func install(from file: URL, paths: AppPaths) async throws {
        guard extensions.contains(file.pathExtension.lowercased()) else { throw CocoaError(.fileReadCorruptFile) }
        let target = paths.soundFonts().appending(path: file.lastPathComponent)
        let staged = target.appendingPathExtension("part")
        try await ChunkedCopier.copy(from: file, to: staged)
        try removeImported(paths: paths)
        try FileManager.default.moveItem(at: staged, to: target)
    }

    /// Back to the bundled soundfont.
    public static func removeImported(paths: AppPaths) throws {
        while let font = imported(paths: paths) {
            try FileManager.default.removeItem(at: font)
        }
    }

    /// True when this game actually ships MIDI. `MediaRequirementAnalyzer` raises `soundfontRequired` only
    /// after it finds MIDI files for an RGSS or EasyRPG runtime, which is the signal worth acting on — the
    /// engine family alone is not, or every XP game would be told to go and find a soundfont it never needs.
    public static func isNeeded(by descriptor: GameDescriptor) -> Bool {
        descriptor.warnings.contains(.soundfontRequired)
    }

    public static func notice(for descriptor: GameDescriptor, paths: AppPaths) -> String? {
        guard isNeeded(by: descriptor), installed(paths: paths) == nil else { return nil }
        return "This game's music is MIDI. Import a soundfont in Settings to hear it."
    }
}
