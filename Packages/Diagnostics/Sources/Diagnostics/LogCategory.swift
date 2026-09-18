/// OSLog categories, one per subsystem. Every log line goes through one of these so a session
/// export can be filtered per engine.
public enum LogCategory: String, CaseIterable, Sendable, Codable {
    case importer, detection, runtime, filesystem, web, javascript, ruby, python, godot, scummvm
    case renderer, audio, save, memory, media, crash, compatibility, ui
}
