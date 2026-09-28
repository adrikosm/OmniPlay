import Diagnostics
import Foundation
import InputKit

/// `GameKey` → the scancode `mkxp_injectKeyEvent` takes. The engine's scancodes are SDL's, which are USB HID
/// usages, so this is `GameKey.hidUsage`; an unknown code is dropped and logged once rather than sent as
/// something plausible.
public enum RGSSKeyMap {
    public static func scancode(for key: GameKey) -> Int32? {
        guard let code = key.hidUsage else {
            noteUnknown(key)
            return nil
        }
        return code
    }

    private nonisolated(unsafe) static var reported: Set<String> = []
    private static let reportLock = NSLock()

    private static func noteUnknown(_ key: GameKey) {
        reportLock.lock()
        let first = reported.insert(key.rawValue).inserted
        reportLock.unlock()
        if first {
            OPLog.log(.runtime, .default, "no RGSS scancode for \(key.rawValue); the key is ignored")
        }
    }
}
