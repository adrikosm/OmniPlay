#if canImport(WebKit) && canImport(UIKit)
    import Diagnostics
    import Foundation
    import WebKit

    /// Receives typed messages from the isolated world and navigation callbacks; never evaluates page strings.
    @MainActor
    final class MessageBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let handlers = ["omniplay.console", "omniplay.save", "omniplay.heartbeat", "omniplay.state", "omniplay.fs"]

        enum Event {
            case heartbeat, booted, console(level: String, message: String), navigationFailed(String), processTerminated
            case save(op: String, kind: String, key: String, value: String?)
        }

        private let session: SessionID
        private let onEvent: @MainActor (Event) -> Void

        init(session: SessionID, onEvent: @escaping @MainActor (Event) -> Void) {
            self.session = session
            self.onEvent = onEvent
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            switch message.name {
            case "omniplay.heartbeat": onEvent(body["booted"] as? Bool == true ? .booted : .heartbeat)
            case "omniplay.console":
                let level = (body["level"] as? String ?? "log").prefix(8)
                let text = (body["message"] as? String ?? "").prefix(4096)
                OPLog.log(.javascript, level == "error" ? .error : .debug, "\(text)", session: session)
                onEvent(.console(level: String(level), message: String(text)))
            case "omniplay.save":
                onEvent(.save(
                    op: body["op"] as? String ?? "",
                    kind: body["kind"] as? String ?? "ls",
                    key: (body["key"] as? String ?? "").prefix(256).description,
                    value: body["value"] as? String
                ))
            default: break
            }
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
            onEvent(.navigationFailed(error.localizedDescription))
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) { onEvent(.processTerminated) }
    }
#endif
