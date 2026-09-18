#if os(macOS) || os(iOS)
    import AuthenticationServices
    import Foundation
    import SwiftPWACore
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// ``AuthorizationSessionPresenter`` backed by `ASWebAuthenticationSession`
    /// — the OS's own sign-in browser on macOS and iOS.
    ///
    /// Worth using rather than opening Safari and catching the scheme ourselves,
    /// for three reasons that are all invisible until they bite:
    ///
    /// - **The cookie-sharing prompt.** The session asks "Do you want to allow
    ///   … to use … to sign in?", and on yes it shares Safari's cookie jar. That
    ///   is the difference between an already-signed-in user tapping once and
    ///   typing a password again on a phone keyboard.
    /// - **Cancellation is observable.** Dismissing the sheet calls back with
    ///   `canceledLogin`, so the app can return to its signed-out state
    ///   immediately. An externally opened browser gives no such signal — the
    ///   app finds out at the timeout, five minutes later.
    /// - **The callback doesn't leave the app.** iOS routes it straight back
    ///   instead of through `openURL`, so it never touches the `app.openURL`
    ///   channel and can't be seen by anything else listening there.
    ///
    /// **Scheme callbacks only.** There is no http-loopback variant, so a
    /// desktop build using a loopback redirect goes through the default browser
    /// even on a Mac — which is the right way round, since the loopback receiver
    /// exists precisely for the desktop client types.
    public final class SystemAuthorizationSession: NSObject, AuthorizationSessionPresenter, @unchecked Sendable {
        /// Whether to ask the OS for a private browsing session (no shared
        /// cookies, and no prompt about sharing them).
        ///
        /// Off by default, because the shared session is the one users want: it
        /// is what makes "Sign in with Google" a single tap on a device already
        /// signed into Google. Worth turning on for an app that expects several
        /// accounts, where a shared session silently signs them back into the
        /// one they were trying to leave.
        private let ephemeral: Bool

        public init(ephemeral: Bool = false) {
            self.ephemeral = ephemeral
            super.init()
        }

        public func present(authorizationURL: URL, callbackScheme: String) async throws -> URL {
            // One continuation, resumed exactly once, by whichever of three
            // things gets there first: the session's completion handler, a
            // `start()` that refused to present, or **cancellation**.
            //
            // That third one is not belt-and-braces. `OAuthAuthorizer` applies
            // `timeoutMs` by racing this call in a task group, and a task group
            // does not return until every child has finished — so a continuation
            // that simply leaks when its task is cancelled hangs the whole
            // `authorize` call forever, long after the timeout fired. Measured
            // on a cabled iPad: the sheet presented, nothing redirected, the
            // 6-second timeout elapsed, and the caller waited 180 seconds for a
            // promise that never settled. `session.cancel()` alone doesn't fix
            // it — a session whose sheet is up answers its completion handler,
            // but one that never presented has nothing to answer with.
            // Wait for a scene the OS will accept as an anchor before starting.
            //
            // `ASWebAuthenticationSession` refuses any window whose scene isn't
            // `.foregroundActive`, and a freshly launched app is
            // `.foregroundInactive` for a moment — long enough that an
            // `auth.authorize` fired from a startup path, or straight off a deep
            // link, fails with error 3 and the message "The operation couldn't
            // be completed". Measured on a cabled iPad: the same call that fails
            // immediately after launch succeeds six seconds later. Waiting a
            // beat is the difference between a working sign-in button and one
            // that works only if the user idles first.
            await Self.waitForPresentableScene()

            let outcome = PendingCallback()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    outcome.attach(continuation)
                    Task {
                        await MainThread.run {
                            let session = ASWebAuthenticationSession(
                                url: authorizationURL,
                                callbackURLScheme: callbackScheme
                            ) { callbackURL, error in
                                if let callbackURL {
                                    outcome.finish(.success(callbackURL))
                                    return
                                }
                                outcome.finish(.failure(self.bridgeError(from: error)))
                            }
                            session.presentationContextProvider = self
                            session.prefersEphemeralWebBrowserSession = self.ephemeral
                            self.store(session)
                            // `start()` returning false means the session could
                            // not be presented at all — no anchor, or a URL it
                            // refuses. Reported rather than left to hang, but
                            // the completion handler's own error is better when
                            // it arrives, so this only wins if it gets there
                            // first.
                            guard session.start() else {
                                outcome.finish(.failure(BridgeError(
                                    code: BridgeError.authRedirect,
                                    message: "couldn't present the sign-in browser — anchor: \(self.anchorDiagnostic)"
                                )))
                                return
                            }
                        }
                    }
                }
            } onCancel: {
                outcome.finish(.failure(BridgeError(
                    code: BridgeError.cancelled, message: "the sign-in was cancelled"
                )))
                Task { await MainThread.run { self.cancelCurrent() } }
            }
        }

        /// Poll briefly for a `.foregroundActive` scene. Bounded, and it never
        /// fails: if the app genuinely isn't active — presenting from the
        /// background, a driver run on a sleeping device — starting anyway
        /// produces the anchor diagnostic, which says more than a timeout of
        /// our own would.
        private static func waitForPresentableScene() async {
            #if os(iOS)
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    let active = await MainThread.run {
                        UIApplication.shared.connectedScenes.contains {
                            ($0 as? UIWindowScene)?.activationState == .foregroundActive
                        }
                    }
                    if active { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            #endif
        }

        /// The live session, held because `ASWebAuthenticationSession` is not
        /// retained by the system while it runs: dropping it dismisses the sheet
        /// and the completion handler never fires, which reads as a sign-in that
        /// vanished.
        private let lock = NSLock()
        private var current: ASWebAuthenticationSession?
        private var anchorNote = "the anchor was never asked for"

        private func store(_ session: ASWebAuthenticationSession) {
            lock.withLock { current = session }
        }

        private func cancelCurrent() {
            let session = lock.withLock { () -> ASWebAuthenticationSession? in
                defer { current = nil }
                return current
            }
            session?.cancel()
        }

        /// What `presentationAnchor` last handed back, for the error message.
        private var anchorDiagnostic: String {
            lock.lock()
            defer { lock.unlock() }
            return anchorNote
        }

        private func noteAnchor(_ note: String) {
            lock.lock()
            anchorNote = note
            lock.unlock()
        }

        func bridgeError(from error: (any Error)?) -> BridgeError {
            let code = (error as? NSError)?.code
            if code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                return BridgeError(code: BridgeError.authCancelled, message: "the sign-in window was dismissed")
            }
            // `presentationContextInvalid` arrives as "The operation couldn't be
            // completed. (…error 3.)" and names neither the window nor the
            // reason, which makes it undiagnosable from a device. Say what the
            // anchor actually was.
            let detail = error?.localizedDescription ?? "the sign-in session ended without a callback"
            if code == ASWebAuthenticationSessionError.presentationContextInvalid.rawValue
                || code == ASWebAuthenticationSessionError.presentationContextNotProvided.rawValue
            {
                return BridgeError(code: BridgeError.authRedirect, message: "\(detail) — anchor: \(anchorDiagnostic)")
            }
            return BridgeError(code: BridgeError.authRedirect, message: detail)
        }
    }

    #if os(iOS)
        extension SystemAuthorizationSession {
            static func describe(_ state: UIScene.ActivationState) -> String {
                switch state {
                case .foregroundActive: "foregroundActive"
                case .foregroundInactive: "foregroundInactive"
                case .background: "background"
                case .unattached: "unattached"
                @unknown default: "unknown(\(state.rawValue))"
                }
            }
        }
    #endif

    /// A `CheckedContinuation` that can be resumed from three places and must be
    /// resumed exactly once — a second resume traps the process outright
    /// (`SWIFT TASK CONTINUATION MISUSE`, signal 5, which is how a cabled iPad
    /// took the whole app down on the first real run), and zero resumes hangs
    /// the caller.
    ///
    /// Lock-guarded rather than actor-isolated because one of the three callers
    /// is a cancellation handler, which runs on whatever thread cancelled.
    /// `finish` before `attach` is legal and remembered, since cancellation can
    /// beat the continuation into existence.
    private final class PendingCallback: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, any Error>?
        private var pending: Result<URL, any Error>?
        private var done = false

        func attach(_ continuation: CheckedContinuation<URL, any Error>) {
            lock.lock()
            if let pending {
                done = true
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ outcome: Result<URL, any Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            guard let continuation else {
                pending = outcome
                lock.unlock()
                return
            }
            done = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: outcome)
        }
    }

    extension SystemAuthorizationSession: ASWebAuthenticationPresentationContextProviding {
        /// The window the sheet anchors to.
        ///
        /// **A window on a scene that isn't foreground-active is rejected**, and
        /// the rejection is opaque: the session answers
        /// `ASWebAuthenticationSessionError.presentationContextInvalid` (code 3)
        /// with the message "The operation couldn't be completed", naming
        /// neither the window nor the reason. Measured on a cabled iPad, where a
        /// driver-launched app whose scene had not finished activating failed
        /// exactly this way — so foreground-active scenes are preferred over
        /// merely-connected ones rather than taking whatever comes first.
        ///
        /// A fresh, unattached window is a deliberate last resort rather than a
        /// crash: `presentationAnchor` is non-optional, and an app running
        /// headless (a driver session, an agent catalog dump) has no key window
        /// to give. It too produces code 3, which the caller reports — the
        /// alternative is a trap inside a framework callback.
        public func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                #if os(macOS)
                    NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
                #else
                    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    let active = scenes.filter { $0.activationState == .foregroundActive }
                    let pool = (active.isEmpty ? scenes : active).flatMap(\.windows)
                    let anchor = pool.first(where: \.isKeyWindow) ?? pool.first ?? UIWindow()
                    // Name the states rather than counting them: "active=0" is
                    // true of a sleeping device, a backgrounded app and an app
                    // that is plainly on screen but whose scene hasn't been
                    // handed first-responder status, and those need different
                    // answers.
                    let states = scenes.map { Self.describe($0.activationState) }.joined(separator: ",")
                    noteAnchor(
                        "scenes=[\(states)] windows=\(pool.count) key=\(anchor.isKeyWindow) "
                            + "scene=\(anchor.windowScene == nil ? "none" : "yes") "
                            + "size=\(Int(anchor.bounds.width))x\(Int(anchor.bounds.height))"
                    )
                    return anchor
                #endif
            }
        }
    }
#endif
