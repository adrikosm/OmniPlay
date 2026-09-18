/// OSLog categories, one per subsystem (design authority §18). Every log line in the app and in
/// every package goes through one of these so a session export can be filtered per engine.
public enum LogCategory: String, CaseIterable, Sendable, Codable {
    case importer
    case detection
    case runtime
    case filesystem
    case web
    case javascript
    case ruby
    case python
    case godot
    case scummvm
    case renderer
    case audio
    case save
    case memory
    case media
    case crash
    case compatibility
}
