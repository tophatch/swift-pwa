#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore

    /// Keeps the *grant* that comes with a user-picked file or folder alive
    /// past the picker that produced it, and turns it into a token an app
    /// can store.
    ///
    /// The problem this solves: on iOS a location the user picks outside the
    /// app container is reachable only through the security-scoped `URL` the
    /// picker handed over. The scope belongs to that object — reduce it to a
    /// `String` path and the access is gone, which is why a picked folder
    /// used to come back unreadable. Sandboxed macOS has the milder version:
    /// the path works for this launch, but nothing survives a relaunch
    /// without a bookmark.
    ///
    /// So each picked URL is retained here with its scope started, keyed by
    /// the path we hand to JS, and left running for the life of the process
    /// (the picker's grant has no natural narrower scope — the web app can
    /// come back to that path at any point in the session). Bookmarks are
    /// minted from the retained URL, which is the only object still holding
    /// the grant.
    @MainActor
    final class FileGrants {
        private var urls: [String: URL] = [:]

        /// Activate and retain the grants on freshly picked URLs. Returns
        /// the paths in the same order, for handing back to JS.
        func retain(_ picked: [URL]) -> [String] {
            for url in picked {
                // A URL inside the container isn't scoped and returns false
                // here; that's not a failure, it just needs no grant. Only
                // remember the ones we actually started, so `deinit` and
                // `stopAccessing` stay balanced.
                if url.startAccessingSecurityScopedResource() {
                    if let previous = urls[url.path], previous != url {
                        previous.stopAccessingSecurityScopedResource()
                    }
                    urls[url.path] = url
                }
            }
            return picked.map(\.path)
        }

        /// Mint a token for a path, preferring a retained scoped URL over a
        /// bare path — under the sandbox they are not equivalent.
        func makeBookmark(forPath path: String) -> String? {
            let url = urls[path] ?? URL(fileURLWithPath: path)
            do {
                return try DialogBookmark.token(bookmarkData: url.bookmarkData(options: Self.creationOptions))
            } catch {
                // Not fatal: the pick itself succeeded, the caller just
                // doesn't get a durable handle to this one. Say why, since
                // the app can't see this failure any other way.
                FileHandle.standardError.writeQuietly(Data(
                    "swift-pwa: could not mint a bookmark for \(path): \(error)\n".utf8
                ))
                return nil
            }
        }

        /// Resolve a token, re-activating its grant for the session.
        func resolve(_ bookmark: String) throws -> DialogResolveBookmarkResult {
            let data: Data
            switch try DialogBookmark.payload(of: bookmark) {
            case let .bookmarkData(bytes):
                data = bytes
            case let .path(path):
                // Minted by a build of the app whose Dialog had no bookmark
                // support (or by another platform). Honour it as far as a
                // path can be honoured, and hand back a real bookmark so
                // the app upgrades its stored token.
                guard FileManager.default.fileExists(atPath: path) else {
                    return DialogResolveBookmarkResult(path: nil)
                }
                return DialogResolveBookmarkResult(
                    path: path,
                    stale: true,
                    bookmark: makeBookmark(forPath: path)
                )
            case .uri:
                throw BridgeError(
                    code: BridgeError.handler,
                    message: """
                    dialog.resolveBookmark: this token was minted on a different platform \
                    and can't be resolved here
                    """
                )
            }

            var stale = false
            let url: URL
            do {
                url = try URL(
                    resolvingBookmarkData: data,
                    options: Self.resolutionOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            } catch {
                // The location is gone, or the user revoked access in
                // Settings. Not an error the app can act on beyond asking
                // the user to pick again, which a nil path already says.
                return DialogResolveBookmarkResult(path: nil)
            }

            let path = retain([url]).first ?? url.path
            return DialogResolveBookmarkResult(
                path: path,
                stale: stale,
                bookmark: stale ? makeBookmark(forPath: path) : nil
            )
        }

        deinit {
            for url in urls.values {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // MARK: - Per-platform bookmark flavour

        #if os(macOS)
            /// An app-scoped bookmark is what survives relaunch under the
            /// App Sandbox, and it needs the
            /// `com.apple.security.files.bookmarks.app-scope` entitlement.
            /// Outside the sandbox a plain bookmark resolves fine and needs
            /// no entitlement, so don't ask for more than the app is
            /// packaged for.
            private static let sandboxed =
                ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

            private static var creationOptions: URL.BookmarkCreationOptions {
                sandboxed ? [.withSecurityScope] : []
            }

            private static var resolutionOptions: URL.BookmarkResolutionOptions {
                sandboxed ? [.withSecurityScope] : []
            }
        #else
            /// iOS has no `withSecurityScope` flavour: a plain bookmark
            /// minted from a scoped URL resolves back into a scoped URL,
            /// which is exactly what's wanted.
            private static let creationOptions: URL.BookmarkCreationOptions = []
            private static let resolutionOptions: URL.BookmarkResolutionOptions = []
        #endif
    }
#endif
