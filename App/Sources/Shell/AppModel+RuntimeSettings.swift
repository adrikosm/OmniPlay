import Diagnostics
import GameCore
import GameTools

/// The Runtime page's per-game start-up settings, kept in the overrides ledger as `profile.<key>`.
extension AppModel {
    func runtimeSetting(_ setting: RuntimeSetting, for id: GameID) -> String {
        (try? store?.overrides.get(game: id, key: setting.ledgerKey)).flatMap(\.self) ?? ""
    }

    /// A Runtime-page choice by profile key, nil when left automatic.
    func profileValue(_ key: String, for id: GameID) -> String? {
        (try? store?.overrides.get(game: id, key: RuntimeSettings.prefix + key)).flatMap(\.self).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A `profile.<key>` choice made outside the Runtime page (live translation's source language); "" clears it.
    func setProfileValue(_ key: String, _ value: String, for id: GameID) {
        try? store?.overrides.set(game: id, key: RuntimeSettings.prefix + key, valueJson: value)
    }

    func setRuntimeSetting(_ setting: RuntimeSetting, to value: String, for id: GameID) {
        try? store?.overrides.set(game: id, key: setting.ledgerKey, valueJson: value)
        OPLog.log(.runtime, .info, "runtime setting \(setting.key) = \(value.isEmpty ? "automatic" : value)")
    }
}
