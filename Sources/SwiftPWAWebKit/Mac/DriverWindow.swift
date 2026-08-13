#if os(macOS) && SWIFT_PWA_DRIVER

    import AppKit

    /// The window used in **driver builds** on macOS. It exists to stop
    /// driver-injected input making the system alert sound.
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

        override func noResponder(for eventSelector: Selector) {
            let event = NSApp.currentEvent
            let suppress = Self.isInjected(event)
            if ProcessInfo.processInfo.environment["SWIFT_PWA_DRIVER_TRACE"] != nil {
                FileHandle.standardError.writeQuietly(Data("""
                swift-pwa driver: noResponder(\(eventSelector)) \
                ts=\(event?.timestamp.description ?? "nil") suppressed=\(suppress)\n
                """.utf8))
            }
            guard !suppress else { return }
            super.noResponder(for: eventSelector)
        }
    }

#endif
