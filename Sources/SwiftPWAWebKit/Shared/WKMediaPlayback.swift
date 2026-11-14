#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Foundation
    import SwiftPWACore
    import WebKit

    /// How a page's `<audio>` and `<video>` play: the way they do in the
    /// platform's browser, on first-party content the browser would trust.
    @MainActor
    enum WKMediaPlayback {
        static func configure(
            _ cfg: WKWebViewConfiguration,
            pictureInPicture: Bool = PictureInPicture.isRequested()
        ) {
            // Let the app's own JS (first-party content from pwa://) play media
            // it generates — e.g. on-device TTS — without a user gesture.
            // Autoplay policies exist to tame untrusted web pages; for a
            // first-party wrapper they just break `audio.play()` (a long async
            // between the tap and playback drops the user-activation, so the
            // play is rejected and stays silent). Empty set = no media type
            // requires a gesture.
            cfg.mediaTypesRequiringUserActionForPlayback = []
            // Off by default in a WKWebView, which leaves `requestFullscreen`
            // undefined and takes the fullscreen button off `<video controls>`.
            // Safari has it on.
            cfg.preferences.isElementFullscreenEnabled = true
            #if os(iOS)
                // Off by default on iPhone, where every `<video>` then leaves
                // the page to play full screen and `playsinline` is ignored.
                // A page that wants full screen still asks per element.
                cfg.allowsInlineMediaPlayback = true
                cfg.allowsPictureInPictureMediaPlayback = true
            #else
                if pictureInPicture { enablePictureInPicture(on: cfg.preferences) }
            #endif
        }

        #if os(macOS)
            /// macOS has no public spelling of this (the configuration property
            /// is iOS-only), and without it `requestPictureInPicture()` rejects
            /// with NotSupportedError even though `pictureInPictureEnabled` says
            /// true. It is private API, so it runs only for an app that opted in,
            /// and a missing selector leaves picture in picture off rather than
            /// raising — KVC on an unknown key would end the app.
            private static func enablePictureInPicture(on preferences: WKPreferences) {
                let selector = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
                guard preferences.responds(to: selector),
                      let method = class_getInstanceMethod(type(of: preferences), selector)
                else {
                    FileHandle.standardError.writeQuietly(Data("""
                    swift-pwa: macos.picture_in_picture is set, but this macOS's WebKit has no way to turn \
                    picture in picture on; a <video> will report it as unsupported.

                    """.utf8))
                    return
                }
                // A `BOOL` argument can't travel through `perform(_:with:)`.
                typealias SetBool = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
                let implementation = unsafeBitCast(method_getImplementation(method), to: SetBool.self)
                implementation(preferences, selector, ObjCBool(true))
            }
        #endif
    }
#endif
