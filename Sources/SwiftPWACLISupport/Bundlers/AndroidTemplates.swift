import Foundation

/// Templated content for the generated Android Gradle project.
/// Kept as a single namespace because every file is small and
/// editing them in isolation (one per .swift file) would be churn.
///
/// All templates pin specific tool versions rather than tracking
/// "latest stable" — Gradle / AGP version drift is a frequent source
/// of "this scaffold worked yesterday, broken today" for end users.
/// A point release of swift-pwa can roll the pins forward; the
/// alternative (tracking-latest at scaffold time) silently breaks
/// reproducibility.
enum AndroidTemplates {
    // MARK: - Project root

    static func settingsGradleKts(label: String) -> String {
        """
        pluginManagement {
            repositories {
                google()
                mavenCentral()
                gradlePluginPortal()
            }
        }
        dependencyResolutionManagement {
            repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
            repositories {
                google()
                mavenCentral()
            }
        }

        rootProject.name = "\(label)"
        include(":app")
        """
    }

    static let rootBuildGradleKts: String = """
    // Project-level Gradle config. The Android Gradle Plugin (AGP) version
    // is pinned; bump it explicitly when rolling Android tooling forward
    // — silent tracking-latest is exactly what makes scaffolds bit-rot.
    plugins {
        id("com.android.application") version "8.5.0" apply false
        id("org.jetbrains.kotlin.android") version "2.0.0" apply false
    }
    """

    static let gradleProperties: String = """
    org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
    android.useAndroidX=true
    kotlin.code.style=official
    # AGP 8.x requires Java 17 to build; if you see a Toolchain error,
    # install JDK 17 and point JAVA_HOME at it before invoking gradlew.
    """

    // MARK: - app module

    static func appBuildGradleKts(
        packageId: String,
        versionCode: Int,
        versionName: String,
        minSdk: Int,
        targetSdk: Int,
        abis: [String],
        soBaseName: String
    ) -> String {
        let abiList = abis.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        plugins {
            id("com.android.application")
            id("org.jetbrains.kotlin.android")
        }

        android {
            namespace = "\(packageId)"
            compileSdk = \(targetSdk)

            defaultConfig {
                applicationId = "\(packageId)"
                minSdk = \(minSdk)
                targetSdk = \(targetSdk)
                versionCode = \(versionCode)
                versionName = "\(versionName)"

                ndk {
                    abiFilters += setOf(\(abiList))
                }
            }

            buildTypes {
                release {
                    isMinifyEnabled = false
                }
                debug {
                    // WebView remote-debug bridge is only useful in debug.
                    // Enabled via WebView.setWebContentsDebuggingEnabled in code.
                }
            }

            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
            kotlinOptions {
                jvmTarget = "17"
            }

            packaging {
                jniLibs {
                    // Don't strip .so files; Swift's debug info is small
                    // and the round-trip through `swift symbolicate` is
                    // worth keeping symbols around for crash triage.
                    keepDebugSymbols += setOf("**/lib\(soBaseName).so")
                }
            }

            buildFeatures {
                buildConfig = true
            }
        }

        dependencies {
            implementation("androidx.appcompat:appcompat:1.7.0")
            // WebViewAssetLoader provides the https://swift-pwa.local/
            // virtual host for asset-relative loads — the same shape
            // WebView2 has via SetVirtualHostNameToFolderMapping. Without
            // it we'd have to load via file:// which breaks fetch and
            // module imports in the page.
            implementation("androidx.webkit:webkit:1.11.0")
        }
        """
    }

    static func androidManifestXml(packageId: String, label: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android"
                  xmlns:tools="http://schemas.android.com/tools">

            <!-- INTERNET is required for WebView to fetch network resources
                 and (in dev) for `PWA_DEV_SERVER`. Bundled-only apps that
                 want to lock the network down can drop this and the
                 WebView will still resolve assets via the asset loader. -->
            <uses-permission android:name="android.permission.INTERNET"/>

            <application
                android:label="\(label)"
                android:allowBackup="true"
                android:supportsRtl="true"
                android:usesCleartextTraffic="false"
                tools:targetApi="34">
                <activity
                    android:name="\(packageId).MainActivity"
                    android:exported="true"
                    android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize|uiMode|navigation"
                    android:windowSoftInputMode="adjustResize">
                    <intent-filter>
                        <action android:name="android.intent.action.MAIN"/>
                        <category android:name="android.intent.category.LAUNCHER"/>
                    </intent-filter>
                </activity>
            </application>

        </manifest>
        """
    }

    // MARK: - Kotlin

    static func mainActivityKt(packageId: String, soBaseName: String) -> String {
        """
        package \(packageId)

        import android.app.Activity
        import android.os.Bundle
        import android.webkit.WebView
        import androidx.webkit.WebViewAssetLoader
        import dev.swiftpwa.runtime.SwiftPWABridge
        import kotlin.concurrent.thread

        /// Generated by `swift-pwa build --target android`. Do not edit
        /// by hand — re-run the bundler instead. Apps that need a
        /// non-default Activity layout should derive from this class
        /// in a sibling file rather than modifying this one.
        class MainActivity : Activity() {
            private lateinit var bridge: SwiftPWABridge

            override fun onCreate(savedInstanceState: Bundle?) {
                super.onCreate(savedInstanceState)
                // Load the Swift-compiled .so. The base name matches
                // the SwiftPM target name; the loader prepends `lib`
                // and appends `.so`.
                System.loadLibrary("\(soBaseName)")

                val webView = WebView(this)
                setContentView(webView)

                if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                    WebView.setWebContentsDebuggingEnabled(true)
                }

                // The asset loader serves any URL under
                // `https://swift-pwa.local/<path>` from `assets/<path>`.
                // The bundler puts the web bundle at `assets/web/`, so
                // the Swift runtime navigates to
                // `https://swift-pwa.local/web/<entry>` to pick it up
                // (see SwiftPWAAndroid/AndroidWebViewAdapter.swift).
                val assetLoader = WebViewAssetLoader.Builder()
                    .setDomain("swift-pwa.local")
                    .addPathHandler("/", WebViewAssetLoader.AssetsPathHandler(this))
                    .build()

                bridge = SwiftPWABridge(this, webView, assetLoader)
                bridge.attach()

                // Hand control to the Swift runtime on a worker thread.
                // The runtime blocks until `quit()` is invoked; running
                // on the UI thread would deadlock the WebView's own
                // event pump.
                thread(name = "swift-pwa-runtime", isDaemon = false) {
                    swiftPwaMain()
                }
            }

            override fun onDestroy() {
                bridge.detach()
                super.onDestroy()
            }

            /// Provided by the Swift side via `@_cdecl("swiftpwa_android_main")`.
            /// See `docs/android-setup.md` for the wrapping pattern that
            /// turns the user's `configure` closure into this entry point.
            private external fun swiftPwaMain()
        }
        """
    }

    static let swiftPWABridgeKt: String = #"""
    package dev.swiftpwa.runtime

    import android.app.Activity
    import android.os.Handler
    import android.os.Looper
    import android.webkit.JavascriptInterface
    import android.webkit.WebResourceRequest
    import android.webkit.WebResourceResponse
    import android.webkit.WebView
    import android.webkit.WebViewClient
    import androidx.webkit.WebViewAssetLoader
    import androidx.webkit.WebViewCompat
    import androidx.webkit.WebViewFeature

    /// Bridge object owned by `MainActivity`. Provides the JS<->Swift
    /// channel via `addJavascriptInterface` plus the outbound calls
    /// the Swift side makes to drive the WebView (loadUrl, evaluateJs,
    /// runOnMain). All native methods are JNI-bound to the C shim
    /// under `Sources/CSwiftPWAAndroidJNI/swiftpwa_android.c`.
    ///
    /// The class name + method signatures are pinned by the JNI
    /// symbol mangling on the C side. Do not rename without updating
    /// `swiftpwa_android.c` in lockstep.
    class SwiftPWABridge(
        private val activity: Activity,
        private val webView: WebView,
        assetLoader: WebViewAssetLoader
    ) {
        private val main = Handler(Looper.getMainLooper())

        init {
            // bridge.js needs to run *before* any page script —
            // otherwise the page's `__SWIFT_PWA__.invoke(...)` calls
            // race with the bridge installation. AndroidX webkit's
            // `WebViewCompat.addDocumentStartJavaScript` (added in
            // androidx.webkit 1.5+, gated on
            // `WebViewFeature.DOCUMENT_START_SCRIPT`) is the
            // equivalent of WebKit's `addUserScript(atDocumentStart)`
            // and is what we want. The previous version injected via
            // `WebViewClient.onPageStarted` + `evaluateJavascript`,
            // which fires too late — page scripts can run first and
            // see an undefined `__SWIFT_PWA__`. We fall back to the
            // late-injection path on devices whose System WebView
            // doesn't support the document-start API (Chrome/WebView
            // ≥ ~83 covers it; the fallback exists for older OEM
            // forks).
            val bridgeJs = activity.assets.open("swift_pwa/bridge.js")
                .bufferedReader().use { it.readText() }

            webView.settings.javaScriptEnabled = true
            webView.settings.domStorageEnabled = true
            webView.addJavascriptInterface(JsBridge(this), "__SwiftPWA__post")

            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(
                    webView,
                    bridgeJs,
                    setOf("https://swift-pwa.local")
                )
            } else {
                android.util.Log.w(
                    "swift-pwa",
                    "DOCUMENT_START_SCRIPT unsupported on this WebView; falling back to onPageStarted (page scripts may race the bridge)"
                )
            }

            webView.webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(
                    view: WebView,
                    request: WebResourceRequest
                ): WebResourceResponse? {
                    return assetLoader.shouldInterceptRequest(request.url)
                }
                override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                    super.onPageStarted(view, url, favicon)
                    if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                        view.evaluateJavascript(bridgeJs, null)
                    }
                }
            }
        }

        // -------------------------------------------------------------
        // Lifecycle
        // -------------------------------------------------------------

        fun attach() {
            nativeAttach(this)
        }

        fun detach() {
            nativeDetach()
        }

        // -------------------------------------------------------------
        // Outbound (called by Swift via JNI)
        // -------------------------------------------------------------

        @Suppress("unused") // called from JNI
        fun postToPage(json: String) {
            main.post {
                // PostWebMessage equivalent: deliver via the global
                // resolver in bridge.js.
                val safe = json.replace("\\", "\\\\").replace("`", "\\`")
                webView.evaluateJavascript(
                    "globalThis.__SWIFT_PWA__.__deliver(`$safe`)",
                    null
                )
            }
        }

        @Suppress("unused")
        fun loadUrl(url: String) {
            android.util.Log.i("swift-pwa", "loadUrl: $url")
            main.post { webView.loadUrl(url) }
        }

        @Suppress("unused")
        fun setTitle(title: String) {
            // Updates the action-bar / task-list label. No-op on
            // apps that hide the action bar via theme.
            main.post { activity.title = title }
        }

        @Suppress("unused")
        fun evaluateJs(snippet: String, callback: Long, user: Long) {
            main.post {
                webView.evaluateJavascript(snippet) { result ->
                    // result is a JSON-encoded string or "null"; pass
                    // it through to the C side which forwards to the
                    // Swift continuation.
                    nativeEvalDone(result, null, callback, user)
                }
            }
        }

        @Suppress("unused")
        fun openDevTools() {
            // Android WebView doesn't expose a programmatic DevTools
            // window; remote debugging is the only path. We surface
            // the URL the developer should visit on their host so the
            // call has a visible effect even though we can't open a
            // window from here.
            main.post {
                val msg = "swift-pwa: open chrome://inspect on a connected host to debug this WebView"
                android.util.Log.i("swift-pwa", msg)
            }
        }

        @Suppress("unused")
        fun runOnMain(box: Long) {
            main.post { nativeRunMain(box) }
        }

        // -------------------------------------------------------------
        // Inbound: JS -> Java -> Swift
        // -------------------------------------------------------------

        private class JsBridge(private val outer: SwiftPWABridge) {
            @JavascriptInterface
            fun postMessage(json: String) {
                outer.nativeIngest(json)
            }
        }

        // -------------------------------------------------------------
        // JNI
        // -------------------------------------------------------------

        private external fun nativeAttach(self: SwiftPWABridge)
        private external fun nativeDetach()
        private external fun nativeIngest(json: String)
        private external fun nativeEvalDone(
            result: String?,
            error: String?,
            callback: Long,
            user: Long
        )
        private external fun nativeRunMain(box: Long)
        @Suppress("unused")
        private external fun nativeQuit(exitCode: Int)
    }
    """#
}
