#if os(macOS) || os(iOS)
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif
    import SwiftPWACore
    import WebKit

    /// The `WKWebView` every Apple window uses: a plain one plus the page's
    /// part in the platform's text-selection UI (`selection.*`).
    ///
    /// A subclass because both menus are built by overriding a responder
    /// method on the view itself — `buildMenu(with:)` for the iOS edit menu,
    /// `willOpenMenu(_:with:)` for the macOS context menu. Neither has a
    /// delegate or configuration spelling.
    ///
    /// **Selection gestures on iOS.** Once WebKit takes a finger for a
    /// selection handle, the page gets its `touchstart` and nothing after —
    /// not even the `touchend` (measured on an iPhone 17 Pro: that one
    /// arrives at the *next* touch). A gesture recognizer that only watches
    /// still sees the finger lift, to the frame. What it can't see is whether
    /// a touch is a selection gesture, so two signals decide that:
    ///
    /// - the edit menu hiding while a finger is down and the page isn't
    ///   scrolling — WebKit hides it when a handle is picked up and shows it
    ///   again when it's let go;
    /// - a finger held still for ``longPressDelay`` — WebKit's long press,
    ///   which made the selection about 0.7 s in on the same iPhone.
    ///
    /// On the Mac a mouse press stays visible to the page, so `bridge.js`
    /// reports it there instead.
    class SelectionWebView: WKWebView {
        /// Set by the adapter straight after `init`; `nil` only in between.
        nonisolated(unsafe) var selection: WebViewSelection?

        #if os(iOS)
            static let longPressDelay: Duration = .milliseconds(500)

            private var fingerDown = false
            private var longPress: Task<Void, Never>?

            override init(frame: CGRect, configuration: WKWebViewConfiguration) {
                super.init(frame: frame, configuration: configuration)
                let observer = SelectionTouchObserver(target: nil, action: nil)
                observer.webView = self
                addGestureRecognizer(observer)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) is not used")
            }

            func fingerWentDown() {
                fingerDown = true
                longPress?.cancel()
                longPress = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.longPressDelay)
                    guard !Task.isCancelled, let self, fingerDown else { return }
                    selection?.gesture(.began)
                }
            }

            /// Movement past the slop makes the touch a scroll or a drag, not
            /// a long press. A handle drag still reports, through the menu.
            func fingerMoved() {
                longPress?.cancel()
            }

            func fingerLifted() {
                fingerDown = false
                longPress?.cancel()
                selection?.gesture(.ended)
            }

            /// The menu also hides for a scroll, which isn't a selection
            /// gesture; the scroll view is already dragging by then, and isn't
            /// for a handle drag.
            func editMenuWillDismiss() {
                if fingerDown, !scrollView.isDragging { selection?.gesture(.began) }
            }

            override func buildMenu(with builder: any UIMenuBuilder) {
                super.buildMenu(with: builder)
                guard let actions = selection?.actions, !actions.isEmpty else { return }
                let items = actions.map { action in
                    UIAction(title: action.title) { [weak self] _ in
                        self?.selection?.actionChosen(action.id)
                    }
                }
                let menu = UIMenu(
                    title: "",
                    identifier: UIMenu.Identifier("dev.swiftpwa.selection"),
                    options: .displayInline,
                    children: items
                )
                builder.insertSibling(menu, beforeMenu: .standardEdit)
            }
        #endif

        #if os(macOS)
            /// WebKit's identifier on the selection menu's *Copy* item. Not in
            /// the SDK headers, but it is what WebKit stamps on the item, and the
            /// exact match matters: a link's menu has `…CopyLink` and an image's
            /// `…CopyImage`, and the page's actions don't belong on either.
            static let copySelectionItem = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")

            override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
                super.willOpenMenu(menu, with: event)
                addSelectionActions(to: menu)
            }

            /// The page's items, then a separator, ahead of WebKit's own — on a
            /// selection's menu only.
            func addSelectionActions(to menu: NSMenu) {
                guard let actions = selection?.actions, !actions.isEmpty,
                      menu.items.contains(where: { $0.identifier == Self.copySelectionItem })
                else { return }
                for (index, action) in actions.enumerated() {
                    let item = NSMenuItem(
                        title: action.title,
                        action: #selector(chooseSelectionAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = action.id
                    menu.insertItem(item, at: index)
                }
                menu.insertItem(.separator(), at: actions.count)
            }

            @objc private func chooseSelectionAction(_ sender: NSMenuItem) {
                guard let id = sender.representedObject as? String else { return }
                selection?.actionChosen(id)
            }
        #endif
    }

    #if os(iOS)
        /// Watches touches on the webview without taking part: it never
        /// recognizes, never cancels or delays a touch, and lets every other
        /// recognizer — WebKit's own — run alongside. A finger only; a
        /// trackpad or mouse press reaches the page, which reports it.
        private final class SelectionTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
            weak var webView: SelectionWebView?
            private var tracked: UITouch?
            private var start: CGPoint = .zero

            override init(target: Any?, action: Selector?) {
                super.init(target: target, action: action)
                cancelsTouchesInView = false
                delaysTouchesBegan = false
                delaysTouchesEnded = false
                allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                    NSNumber(value: UITouch.TouchType.pencil.rawValue)
                ]
                delegate = self
            }

            /// Without this, WebKit's handle recognizer taking the touch
            /// would fail this one, and the lift would go unseen.
            func gestureRecognizer(
                _: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
            ) -> Bool {
                true
            }

            override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
            override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }
            override func shouldBeRequiredToFail(by _: UIGestureRecognizer) -> Bool { false }
            override func shouldRequireFailure(of _: UIGestureRecognizer) -> Bool { false }

            override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
                guard tracked == nil, let touch = touches.first else { return }
                tracked = touch
                start = touch.location(in: webView)
                webView?.fingerWentDown()
            }

            override func touchesMoved(_ touches: Set<UITouch>, with _: UIEvent) {
                guard let tracked, touches.contains(tracked) else { return }
                let point = tracked.location(in: webView)
                if hypot(point.x - start.x, point.y - start.y) > 10 { webView?.fingerMoved() }
            }

            override func touchesEnded(_ touches: Set<UITouch>, with _: UIEvent) {
                finish(touches)
            }

            override func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent) {
                finish(touches)
            }

            private func finish(_ touches: Set<UITouch>) {
                guard let tracked, touches.contains(tracked) else { return }
                self.tracked = nil
                webView?.fingerLifted()
                // Never recognized, so it has to fail for UIKit to reset it
                // for the next touch.
                state = .failed
            }
        }
    #endif
#endif
