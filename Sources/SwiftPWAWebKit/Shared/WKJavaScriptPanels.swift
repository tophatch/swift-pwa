#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import SwiftPWACore
    import WebKit
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// Which of the three JavaScript panels to show. `prompt` carries the
    /// page's `defaultValue`.
    enum JSPanel {
        case alert
        case confirm
        case prompt(defaultText: String)
    }

    extension WKWebPolicy {
        /// Show a JavaScript panel and report what the user did: `nil` for
        /// cancel or dismiss, a string for confirmation (the entered text for
        /// `prompt`, empty otherwise).
        ///
        /// Presented as a **sheet** on macOS and as a modal alert on iOS, both
        /// attached to the window the page is in rather than app-modal, so a
        /// multi-window app doesn't have one document's `confirm()` blocking
        /// another's.
        func present(
            _ panel: JSPanel,
            message: String,
            origin frame: WKFrameInfo,
            in webView: WKWebView,
            completion: @escaping (String?) -> Void
        ) {
            // Browsers name the origin on these dialogs, and the reason
            // generalises: `bridge.js` and the page's own scripts run in
            // subframes too, so a cross-origin iframe can raise a `confirm()`
            // that otherwise reads as the app's own. Named only when it isn't
            // the app's own origin — for first-party content the app *is* the
            // origin, and "pwa://localhost says" is noise.
            let attribution = crossOriginAttribution(for: frame)
            #if os(macOS)
                presentMac(panel, message: message, attribution: attribution, in: webView, completion: completion)
            #else
                presentIOS(panel, message: message, attribution: attribution, in: webView, completion: completion)
            #endif
        }

        private func crossOriginAttribution(for frame: WKFrameInfo) -> String? {
            guard !frame.isMainFrame else { return nil }
            let security = frame.securityOrigin
            guard !security.host.isEmpty else { return nil }
            let frameOrigin = WebOrigin(
                scheme: security.protocol,
                host: security.host,
                port: security.port == 0 ? nil : Int(security.port)
            )
            guard frameOrigin != appOrigin else { return nil }
            return frameOrigin.host
        }

        #if os(macOS)
            private func presentMac(
                _ panel: JSPanel,
                message: String,
                attribution: String?,
                in webView: WKWebView,
                completion: @escaping (String?) -> Void
            ) {
                let alert = NSAlert()
                alert.messageText = message
                if let attribution { alert.informativeText = "From \(attribution)" }
                alert.addButton(withTitle: "OK")
                var field: NSTextField?
                switch panel {
                case .alert:
                    break
                case .confirm:
                    alert.addButton(withTitle: "Cancel")
                case let .prompt(defaultText):
                    alert.addButton(withTitle: "Cancel")
                    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
                    input.stringValue = defaultText
                    alert.accessoryView = input
                    // Otherwise the sheet opens with the OK button focused and
                    // typing goes nowhere.
                    alert.window.initialFirstResponder = input
                    field = input
                }
                let answer: (NSApplication.ModalResponse) -> Void = { response in
                    guard response == .alertFirstButtonReturn else {
                        completion(nil)
                        return
                    }
                    completion(field?.stringValue ?? "")
                }
                // A sheet needs a window. `runModal` is the fallback rather
                // than the default because an app-modal dialog from one window
                // blocks every other window in the app.
                if let window = webView.window {
                    alert.beginSheetModal(for: window, completionHandler: answer)
                } else {
                    answer(alert.runModal())
                }
            }
        #else
            private func presentIOS(
                _ panel: JSPanel,
                message: String,
                attribution: String?,
                in webView: WKWebView,
                completion: @escaping (String?) -> Void
            ) {
                guard let presenter = Self.viewController(for: webView) else {
                    // No view controller to present from — a window that has
                    // been torn down, or a webview not in a scene yet. The
                    // page is waiting on the completion handler, so answer it.
                    RuntimeDiagnostics.emit(
                        "swift-pwa: a JavaScript dialog was raised by a webview with no view "
                            + "controller to present from; answering it as dismissed."
                    )
                    completion(nil)
                    return
                }
                let controller = UIAlertController(
                    title: attribution.map { "From \($0)" },
                    message: message,
                    preferredStyle: .alert
                )
                var field: UITextField?
                if case let .prompt(defaultText) = panel {
                    controller.addTextField { textField in
                        textField.text = defaultText
                        field = textField
                    }
                }
                if case .alert = panel {} else {
                    controller.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                        completion(nil)
                    })
                }
                controller.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                    completion(field?.text ?? "")
                })
                presenter.present(controller, animated: true)
            }

            /// The nearest view controller up the webview's responder chain,
            /// falling back to the window's root. The responder chain is
            /// preferred because an app presenting the webview inside its own
            /// controller hierarchy should get *that* controller, not the root
            /// — presenting from the root while another controller is modal
            /// silently does nothing.
            private static func viewController(for webView: WKWebView) -> UIViewController? {
                var responder: UIResponder? = webView
                while let current = responder {
                    if let controller = current as? UIViewController {
                        return controller.presentedViewController ?? controller
                    }
                    responder = current.next
                }
                return webView.window?.rootViewController
            }
        #endif
    }
#endif
