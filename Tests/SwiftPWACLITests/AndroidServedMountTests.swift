@testable import SwiftPWACLISupport
import Testing

/// #213 / #214: the generated Kotlin is the only place these two capabilities
/// exist, and neither can be exercised without a device — so these pin the
/// plumbing that would otherwise rot silently. What they can't check is that
/// it *works*; that is `Scripts/verify-android-served-mounts.sh`.
@Suite("Android served mounts + lifecycle (generated Kotlin)")
struct AndroidServedMountTests {
    private var bridge: String {
        AndroidTemplates.swiftPWABridgeKt()
    }
    private var activity: String {
        AndroidTemplates.mainActivityKt(packageId: "com.example.app", soBaseName: "App")
    }

    // MARK: - #213 served directories

    @Test("the mount table is consulted before the asset loader")
    func mountsWinOverTheBundle() {
        let intercept = bridge.range(of: "override fun shouldInterceptRequest")
        let consult = bridge.range(of: "servedMountResponse(request)?.let { return capToRange(request, it) }")
        let assetLoader = bridge.range(of: "assetLoader.shouldInterceptRequest(request.url)")
        #expect(intercept != nil)
        // Order is the whole behaviour: `/` is a prefix of every mount, so the
        // bundle handler answering first would shadow every served mount.
        if let consult, let assetLoader {
            #expect(consult.lowerBound < assetLoader.lowerBound)
        } else {
            Issue.record("the served-mount consult is missing from shouldInterceptRequest")
        }
    }

    @Test("the resolver is a JNI call, not a Kotlin-side copy of the mount table")
    func resolutionIsOwnedBySwift() {
        // One mount table, in Core, shared with the other four backends. A
        // Kotlin copy would need a sync protocol and could go stale between a
        // `serveDirectory` call and the request that follows it.
        #expect(bridge.contains("private external fun nativeResolveMount(url: String): String?"))
        #expect(bridge.contains("nativeResolveMount(request.url.toString())"))
    }

    /// The Range story is a measured platform limit, not an oversight — and
    /// the obvious implementation is worse than none, so pin the shape.
    @Test("a mount answers with a plain 200 stream, not a 206")
    func plainTwoHundred() {
        // A 206 from `shouldInterceptRequest` is rejected by the WebView before
        // the page sees it (`TypeError: Failed to fetch`, nothing logged
        // anywhere). Chromium ranges the stream itself over a 200.
        #expect(!bridge.contains("206, \"Partial Content\""))
        #expect(!bridge.contains("416, \"Range Not Satisfiable\""))
        // And no claim that a 206 is available, since none ever is.
        #expect(!bridge.contains("headers[\"Accept-Ranges\"]"))
        #expect(bridge.contains("WebResourceResponse(type, charset, FileInputStream(File("))
    }

    @Test("only GET is served from a mount")
    func readOnly() {
        #expect(bridge.contains("if (!request.method.equals(\"GET\", ignoreCase = true)) return null"))
    }

    @Test("the charset is split off the MIME type")
    func mimeIsSplit() {
        // Core spells them together ("text/css; charset=utf-8") and
        // WebResourceResponse wants them apart — passing the whole string as
        // the type makes the WebView refuse the resource.
        #expect(bridge.contains("val semicolon = mime.indexOf(';')"))
    }

    // MARK: - #214 lifecycle

    @Test("onResume and onPause push the window's foreground state")
    func lifecycleIsPushed() {
        #expect(activity.contains("pushLifecycle(\"resumed\")"))
        #expect(activity.contains("pushLifecycle(\"paused\")"))
        #expect(activity.contains("JSONObject().put(\"channel\", \"window.lifecycle\").put(\"state\", state)"))
    }

    @Test("a spawned secondary window doesn't report the primary's lifecycle")
    func secondaryWindowsSkip() {
        let body = activity.range(of: "private fun pushLifecycle(state: String) {")
        let guardLine = activity.range(of: "if (isSecondary || !hasBridge) return")
        if let body, let guardLine {
            #expect(guardLine.lowerBound > body.lowerBound)
        } else {
            Issue.record("pushLifecycle does not guard on the secondary role")
        }
    }

    @Test("pause is pushed before super.onPause")
    func pauseIsPushedEarly() {
        // So an app that re-locks on being backgrounded has its handler queued
        // while this process is still scheduled.
        let push = activity.range(of: "pushLifecycle(\"paused\")")
        let sup = activity.range(of: "super.onPause()")
        if let push, let sup {
            #expect(push.lowerBound < sup.lowerBound)
        } else {
            Issue.record("onPause does not push the lifecycle state")
        }
    }
}
