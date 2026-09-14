#if os(macOS) && SWIFT_PWA_DRIVER

    import AppKit

    /// The window used in **driver builds** on macOS. It does two things a
    /// plain `NSWindow` doesn't: it stops driver-injected input making the
    /// system alert sound, and — in a backgrounded run only — it lets itself be
    /// parked outside every display.
    ///
    /// ## The alert sound
    ///
    /// AppKit's rule: a `keyDown` that nobody in the responder chain handles ends
    /// at `NSResponder.noResponder(for:)`, whose default implementation
    /// **beeps**. That is right for a person pressing a key nothing responds to,
    /// and wrong for a scripted run — `drive type` produced an audible beep on the
    /// host for *every* keystroke the page didn't consume, which undercuts the
    /// driver's promise that you can leave a run going while you keep using the
    /// machine. Reported by an adopter, who heard a dozen in one pass.
    ///
    /// **Why matching by timestamp rather than a flag around `sendEvent`.** A key
    /// event's fate isn't known synchronously: WebKit ships it to the web process,
    /// and only when that comes back unhandled does the UI process re-send it
    /// through the responder chain — a later turn of the main loop, long after any
    /// scope around `sendEvent(_:)` has exited. (Measured: four keys sent, four
    /// `noResponder(keyDown:)` calls, all after the fact.) So each injected event
    /// registers its timestamp — `ProcessInfo.systemUptime` at construction,
    /// unique per event — and `noResponder` swallows the beep only for an event
    /// it recognises. A key the *user* presses still beeps, in a debug build as in
    /// a release one.
    final class DriverWindow: NSWindow {
        /// Whether this window may sit outside every display — set only for a
        /// backgrounded driven run (``DriverBackground``), where the window is
        /// parked far off screen so a suite can run without taking over the
        /// machine.
        ///
        /// AppKit constrains a *titled* window's frame to a screen, keeping its
        /// title bar reachable — which is right for a window a person owns and
        /// is precisely what drags a parked one back into view. Overriding the
        /// constraint is the only way to stay off screen, so it is scoped to
        /// the one mode that asks for it rather than applied to every driver
        /// build.
        var allowsOffscreenPlacement = false

        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            allowsOffscreenPlacement ? frameRect : super.constrainFrameRect(frameRect, to: screen)
        }

        /// Timestamps of events the driver injected, with the uptime at which
        /// each was registered so stale entries can age out. Main-thread only —
        /// events are injected and dispatched there — hence no locking.
        private nonisolated(unsafe) static var injected: [(timestamp: TimeInterval, registeredAt: TimeInterval)] = []

        /// How long an injected event stays recognisable. The re-send happens on
        /// the next few turns of the main loop; seconds is already generous, and
        /// the only cost of a long window is that a *real* unhandled keypress
        /// within it stays silent.
        private static let recognitionWindow: TimeInterval = 5

        /// Called by `WKWebViewAdapter` for every event it injects.
        static func willInject(_ event: NSEvent) {
            let now = ProcessInfo.processInfo.systemUptime
            injected.removeAll { now - $0.registeredAt > recognitionWindow }
            injected.append((event.timestamp, now))
            // Bounded regardless of how chatty a run is.
            if injected.count > 64 { injected.removeFirst(injected.count - 64) }
        }

        private static func isInjected(_ event: NSEvent?) -> Bool {
            guard let event else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            injected.removeAll { now - $0.registeredAt > recognitionWindow }
            return injected.contains { $0.timestamp == event.timestamp }
        }

        /// Guards the one re-entrant path: dispatching a key equivalent can end
        /// in `noResponder` again if nothing implements the action.
        private nonisolated(unsafe) static var dispatchingKeyEquivalent = false

        /// An injected event that reaches here was declined by the whole
        /// responder chain, the page included — which is exactly the point at
        /// which a real keystroke would be offered to the main menu.
        ///
        /// The driver injects with `NSWindow.sendEvent`, one level below the
        /// `NSApplication.sendEvent` step that dispatches menu key equivalents,
        /// so without this a driven ⌘V could only ever do nothing, whatever the
        /// Edit menu contains. Doing it here rather than before delivery keeps
        /// AppKit's real order: measured against a genuine keystroke, a page
        /// that handles ⌘A and calls `preventDefault` keeps the key, and
        /// offering the menu first would take it away.
        ///
        /// Driver builds only, and that is the whole scope of it: a released
        /// app's keystrokes arrive through `NSApplication.sendEvent`, which
        /// consults `mainMenu` itself.
        ///
        /// **The app has to be active for this to do anything**, which is the
        /// one place the driver can't keep its "needn't be frontmost" promise.
        /// A menu item's action is sent with a `nil` target, and AppKit routes
        /// those through `NSApp.keyWindow` — an inactive app has none, so
        /// nothing can receive `paste:` and `performKeyEquivalent` returns
        /// false. Measured: backgrounded, `active=false key=nil` and ⌘A does
        /// nothing; activated, the same keystroke selects the field. Not a gap
        /// worth simulating — dispatching down the driven window's chain by
        /// hand gets past the routing but still fails WebKit's own
        /// `validateUserInterfaceItem`, and forcing past *that* would have the
        /// driver report an editing capability a real user doesn't have.
        /// `swift-pwa drive type --activate` brings the app forward first.
        @MainActor
        private func offerToMainMenu(_ event: NSEvent?) -> Bool {
            guard !Self.dispatchingKeyEquivalent,
                  let event, event.type == .keyDown,
                  event.modifierFlags.contains(.command),
                  let menu = NSApp.mainMenu
            else { return false }
            Self.dispatchingKeyEquivalent = true
            defer { Self.dispatchingKeyEquivalent = false }
            return menu.performKeyEquivalent(with: event)
        }

        override func noResponder(for eventSelector: Selector) {
            let event = NSApp.currentEvent
            let suppress = Self.isInjected(event)
            var handledByMenu = false
            if suppress, eventSelector == #selector(NSResponder.keyDown(with:)) {
                handledByMenu = MainActor.assumeIsolated { offerToMainMenu(event) }
            }
            if ProcessInfo.processInfo.environment["SWIFT_PWA_DRIVER_TRACE"] != nil {
                FileHandle.standardError.writeQuietly(Data("""
                swift-pwa driver: noResponder(\(eventSelector)) \
                ts=\(event?.timestamp.description ?? "nil") suppressed=\(suppress) \
                menu=\(handledByMenu)\n
                """.utf8))
            }
            guard !suppress else { return }
            super.noResponder(for: eventSelector)
        }
    }

#endif
