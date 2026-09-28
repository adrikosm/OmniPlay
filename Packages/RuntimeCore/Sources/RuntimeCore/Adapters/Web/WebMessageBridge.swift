#if canImport(WebKit) && canImport(UIKit)
    import Diagnostics
    import Foundation
    import WebKit

    /// Receives typed messages from the isolated world and navigation callbacks; never evaluates page strings.
    @MainActor
    final class MessageBridge: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        static let handlers = [
            "omniplay.console",
            "omniplay.save",
            "omniplay.heartbeat",
            "omniplay.state",
            "omniplay.fs",
            "omniplay.translate",
        ]

        enum Event {
            case heartbeat, booted, console(level: String, message: String), navigationFailed(String), processTerminated
            case saveFailed(String)
            case missedText(String)
        }

        private let session: SessionID
        private let saves: SaveBridge?
        private let onEvent: @MainActor (Event) -> Void
        var prepareNavigation: (@MainActor (WKWebView) async throws -> Void)?

        init(session: SessionID, saves: SaveBridge?, onEvent: @escaping @MainActor (Event) -> Void) {
            self.session = session
            self.saves = saves
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
            case "omniplay.translate":
                if let text = body["text"] as? String, text.count <= 2000 {
                    onEvent(.missedText(text))
                }
            default: break
            }
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor (Any?, String?) -> Void
        ) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let op = body["op"] as? String, let kind = body["kind"] as? String,
                  let key = body["key"] as? String, let saves else {
                replyHandler(nil, "Invalid save message")
                return
            }
            let value = body["value"] as? String
            Task {
                do {
                    try await saves.handle(op: op, kind: kind, key: key, value: value)
                    replyHandler(true, nil)
                } catch {
                    OPLog.log(.save, .error, "Web save operation failed: \(error)", session: session)
                    if case SaveBridge.Failure.incompleteSeed = error {
                        onEvent(.navigationFailed(String(describing: error)))
                        replyHandler(nil, String(describing: error))
                        return
                    }
                    let detail = SaveBridge.playerMessage(for: error)
                    onEvent(.saveFailed(detail))
                    replyHandler(nil, detail)
                }
            }
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
            onEvent(.navigationFailed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame == true else { return .allow }
            do {
                try await prepareNavigation?(webView)
                return .allow
            } catch is CancellationError {
                return .cancel
            } catch {
                onEvent(.navigationFailed(String(describing: error)))
                return .cancel
            }
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) { onEvent(.processTerminated) }
    }
#endif
