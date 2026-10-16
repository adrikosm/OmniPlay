#if canImport(WebKit) && canImport(UIKit)
    import Diagnostics
    import Foundation
    import WebKit

    /// Receives typed messages from the isolated world and navigation callbacks; never evaluates page strings.
    @MainActor
    final class MessageBridge: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
        static let handlers = [
            "omniplay.console",
            "omniplay.save",
            "omniplay.heartbeat",
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
        var prepareNavigation: (@MainActor (WKWebView, URL?) async throws -> Void)?

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
                // Every line lands in web-console.log; only errors also go to host.log, so a chatty page cannot rotate
                // the session's own lines out of it.
                if level == "error" {
                    OPLog.log(.javascript, .error, "\(text)", session: session)
                } else {
                    OPLog.logger(.javascript).debug("\(text, privacy: .public)")
                }
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
                try await prepareNavigation?(webView, navigationAction.request.url)
                return .allow
            } catch is CancellationError {
                return .cancel
            } catch {
                onEvent(.navigationFailed(String(describing: error)))
                return .cancel
            }
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) { onEvent(.processTerminated) }

        // MARK: The page's alert, confirm and prompt

        // Without these WebKit answers every confirm() with Cancel, so a game's own "Delete this save?" never deleted.
        // Each one is answered exactly once; with nowhere to show it (a menu closing) the page gets Cancel at once.

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame _: WKFrameInfo) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume() })
                if !Self.present(alert, over: webView) {
                    done.resume()
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame _: WKFrameInfo
        ) async -> Bool {
            await withCheckedContinuation { done in
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: false) })
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume(returning: true) })
                if !Self.present(alert, over: webView) {
                    done.resume(returning: false)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame _: WKFrameInfo
        ) async -> String? {
            await withCheckedContinuation { done in
                let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
                alert.addTextField { $0.text = defaultText }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: nil) })
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                    done.resume(returning: alert?.textFields?.first?.text ?? "")
                })
                if !Self.present(alert, over: webView) {
                    done.resume(returning: nil)
                }
            }
        }

        /// On the top-most screen showing now; false when there is none to show it on.
        static func present(_ alert: UIAlertController, over webView: WKWebView) -> Bool {
            var top = webView.window?.rootViewController
            while let next = top?.presentedViewController, !next.isBeingDismissed {
                top = next
            }
            guard let top, !top.isBeingDismissed, top.viewIfLoaded?.window != nil else { return false }
            top.present(alert, animated: true)
            return true
        }
    }
#endif
