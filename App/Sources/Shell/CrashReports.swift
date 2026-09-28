import Diagnostics
import Foundation
import MetricKit
import RuntimeCore

/// Apple's own crash and hang reports, from MetricKit rather than a third-party reporter. They arrive on a later
/// launch, up to a day after the fact, so each payload is filed as `metrickit-<end>.json` with the session that
/// most recently ended without teardown (where the session bundle and Diagnostics pick it up), or with this
/// launch's host log when no session is waiting for one.
final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    // Immutable after init; MetricKit calls in on its own queue.
    private let logsRoot: URL
    private let fallback: URL

    init(logsRoot: URL, fallback: URL) {
        self.logsRoot = logsRoot
        self.fallback = fallback
    }

    // ponytail: the newest tombstone wins, so a crash outside any game in the same window lands on that session.
    // Match on the payload's time range if that ever misleads.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let directory = SessionMarker.newestTombstone(logsRoot: logsRoot) ?? fallback
            let stamp = payload.timeStampEnd.formatted(.iso8601).replacingOccurrences(of: ":", with: "")
            let file = directory.appending(path: "metrickit-\(stamp).json")
            try? payload.jsonRepresentation().write(to: file, options: .atomic)
            let crashes = payload.crashDiagnostics?.count ?? 0, hangs = payload.hangDiagnostics?.count ?? 0
            OPLog.log(.crash, .error, "MetricKit: \(crashes) crash, \(hangs) hang reports → \(file.path(percentEncoded: false))")
        }
    }
}
