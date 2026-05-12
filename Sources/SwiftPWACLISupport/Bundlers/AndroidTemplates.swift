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

    /// Resolved release-signing config the bundler hands to the
    /// template. Holds the *absolute* keystore path so the generated
    /// `app/build.gradle.kts` doesn't have to reason about its own
    /// location relative to the user's project root.
    struct SigningConfig {
        var keystoreAbsolutePath: String
        var keyAlias: String
        var storeType: String // "jks" / "pkcs12"
        var v1SigningEnabled: Bool
        var v2SigningEnabled: Bool
    }

    static func appBuildGradleKts(
        packageId: String,
        versionCode: Int,
        versionName: String,
        minSdk: Int,
        targetSdk: Int,
        abis: [String],
        soBaseName: String,
        signing: SigningConfig?
    ) -> String {
        let abiList = abis.map { "\"\($0)\"" }.joined(separator: ", ")
        let signingBlockText = signing.map(signingConfigsBlock(_:)) ?? ""
        let releaseExtras = signing == nil
            ? ""
            : "            signingConfig = signingConfigs.getByName(\"release\")\n"
        let head = """
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

        """
        let buildTypesOpen = """
            buildTypes {
                release {
                    isMinifyEnabled = false

        """
        let buildTypesTail = """
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

            // No `keepDebugSymbols` override — we *want* AGP's strip pass
            // to run on the app .so. Swift binaries are unusually large
            // when unstripped (HelloPWA's `libHelloPWA.so` is ~20 MB
            // unstripped vs ~4 MB stripped — a 4× delta), and the
            // unstripped copy in `.build/<triple>/release/<Name>` stays
            // on disk for `swift symbolicate` to consume during crash
            // triage. Apps that need symbols *in* the APK (e.g. for
            // breakpad-style on-device crash capture) can override this
            // by adding `keepDebugSymbols += setOf("**/lib<name>.so")`
            // in a sibling `app/build.gradle.kts.local` and applying it
            // post-bundler.

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
            // BiometricPrompt for the SystemBiometricAuth plugin. Pulls
            // in androidx.fragment transitively, which is also what
            // AppCompatActivity / ActivityResultLauncher require for
            // the dialog plugin's SAF launchers — explicit dep here so
            // a future appcompat change can't accidentally remove it.
            implementation("androidx.biometric:biometric:1.1.0")
            implementation("androidx.activity:activity-ktx:1.9.0")
        }
        """
        return head + signingBlockText + buildTypesOpen + releaseExtras + buildTypesTail + "\n"
    }

    /// Render the `signingConfigs { create("release") { ... } }` block
    /// for the generated `app/build.gradle.kts`. Indented to sit one
    /// level inside the `android { }` block (4-space indent, matching
    /// the surrounding `defaultConfig` / `buildTypes` siblings).
    ///
    /// Passwords are read from the environment at Gradle configure
    /// time — `pwa.json` is checked in, so we deliberately keep the
    /// secret values out of the manifest. The error message points at
    /// the env var name rather than throwing a generic null deref so
    /// the user knows what knob to set.
    private static func signingConfigsBlock(_ s: SigningConfig) -> String {
        // Kotlin string literals require backslash + double-quote
        // escaping. Backslashes need doubling so a Windows path like
        // `C:\Users\me\release.jks` survives the round-trip.
        let escapedPath = s.keystoreAbsolutePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAlias = s.keyAlias
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
            signingConfigs {
                create("release") {
                    storeFile = java.io.File("\(escapedPath)")
                    storeType = "\(s.storeType)"
                    keyAlias = "\(escapedAlias)"
                    storePassword = System.getenv("SWIFT_PWA_ANDROID_STORE_PASSWORD")
                        ?: error("swift-pwa: SWIFT_PWA_ANDROID_STORE_PASSWORD not set; release signing requires it")
                    keyPassword = System.getenv("SWIFT_PWA_ANDROID_KEY_PASSWORD")
                        ?: error("swift-pwa: SWIFT_PWA_ANDROID_KEY_PASSWORD not set; release signing requires it")
                    enableV1Signing = \(s.v1SigningEnabled)
                    enableV2Signing = \(s.v2SigningEnabled)
                }
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
            <!-- POST_NOTIFICATIONS: runtime permission on API 33+ for the
                 SystemNotifications plugin. Older API levels ignore the
                 declaration. The plugin's `requestAuthorization` triggers
                 the system prompt the first time. -->
            <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
            <!-- USE_BIOMETRIC: required for BiometricPrompt on API 28+.
                 USE_FINGERPRINT covers older devices via the same plugin —
                 BiometricManager backports under the hood. -->
            <uses-permission android:name="android.permission.USE_BIOMETRIC"/>
            <uses-permission android:name="android.permission.USE_FINGERPRINT"/>
            <!-- REQUEST_INSTALL_PACKAGES: required to call
                 `PackageInstaller.Session.commit` from the AndroidUpdater
                 plugin. The user must additionally enable "Install unknown
                 apps" for the host app once via system settings — the
                 system installer surfaces a dialog routing the user there
                 if it's off. Apps that don't ship updater.installAndRelaunch
                 may delete this line, but the plugin won't work without it. -->
            <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>

            <application
                android:label="\(label)"
                android:allowBackup="true"
                android:supportsRtl="true"
                android:usesCleartextTraffic="false"
                android:theme="@style/Theme.AppCompat.Light.NoActionBar"
                tools:targetApi="34">
                <!-- Theme is `Theme.AppCompat.Light.NoActionBar` because
                     `MainActivity` extends `AppCompatActivity` (required
                     by the BiometricPrompt + SAF launcher plumbing) and
                     AppCompat refuses to inflate against a non-AppCompat
                     theme: `IllegalStateException: You need to use a
                     Theme.AppCompat theme (or descendant) with this
                     activity.` `NoActionBar` because the WebView fills
                     the screen and the system action bar would just
                     steal vertical space. Apps that need the action
                     bar can override this attribute. -->
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

        import android.os.Bundle
        import android.webkit.WebView
        import androidx.appcompat.app.AppCompatActivity
        import androidx.webkit.WebViewAssetLoader
        import dev.swiftpwa.runtime.SwiftPWABridge
        import kotlin.concurrent.thread

        /// Generated by `swift-pwa build --target android`. Do not edit
        /// by hand — re-run the bundler instead. Apps that need a
        /// non-default Activity layout should derive from this class
        /// in a sibling file rather than modifying this one.
        ///
        /// Extends `AppCompatActivity` (a `FragmentActivity` subclass)
        /// rather than the bare `Activity` so the System* plugins —
        /// notably `BiometricPrompt` and the Storage Access Framework
        /// `ActivityResultLauncher`s the dialog plugin uses — can
        /// attach. Switching to bare `Activity` will surface as
        /// `IllegalStateException: FragmentActivity required` from the
        /// first biometric / file-picker call.
        class MainActivity : AppCompatActivity() {
            private lateinit var bridge: SwiftPWABridge
            private var isSecondary: Boolean = false

            override fun onCreate(savedInstanceState: Bundle?) {
                super.onCreate(savedInstanceState)
                // Load the Swift-compiled .so. The base name matches
                // the SwiftPM target name; the loader prepends `lib`
                // and appends `.so`. Calling System.loadLibrary again
                // on a secondary Activity is harmless — Android's
                // loader dedupes on the underlying library handle.
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

                // Secondary-window mode is signalled by the
                // `swift-pwa.config-json` intent extra, set by
                // `SwiftPWABridge.spawnWindow` when the Swift side
                // calls `context.createWindow` a second time. The
                // JSON carries at least a `url` field (the content
                // the new Activity should load) and an optional
                // `title`. Secondary Activities don't spawn the
                // Swift runtime thread — there's only one runtime per
                // process; the primary owns it.
                val configJson = intent.getStringExtra("swift-pwa.config-json")
                isSecondary = configJson != null
                if (isSecondary) {
                    try {
                        val cfg = org.json.JSONObject(configJson!!)
                        if (cfg.has("title")) {
                            setTitle(cfg.getString("title"))
                        }
                        webView.loadUrl(cfg.getString("url"))
                    } catch (t: Throwable) {
                        android.util.Log.e(
                            "swift-pwa",
                            "secondary Activity could not parse config JSON: ${t.message}"
                        )
                        finish()
                    }
                } else {
                    // Hand control to the Swift runtime on a worker
                    // thread. The runtime blocks until `quit()` is
                    // invoked; running on the UI thread would
                    // deadlock the WebView's own event pump.
                    thread(name = "swift-pwa-runtime", isDaemon = false) {
                        swiftPwaMain()
                    }
                }
            }

            override fun onResume() {
                super.onResume()
                // Re-attach in case a sibling Activity took the
                // single-slot bridge ref while we were paused. The
                // C shim's `nativeAttach` is idempotent — atomic
                // exchange of the global ref — so calling it on
                // every resume is cheap and correct. Without this
                // re-attach, returning from a secondary Activity
                // would leave the primary Activity's outbound JNI
                // calls hitting a null bridge ref (silent no-op).
                bridge.attach()
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
    import android.content.Intent
    import androidx.appcompat.app.AppCompatActivity
    import androidx.core.view.WindowCompat
    import androidx.core.view.WindowInsetsCompat
    import androidx.core.view.WindowInsetsControllerCompat
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
        private val systemPlugins: SwiftPWASystemPlugins = SwiftPWASystemPlugins(activity, this)

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
        fun spawnWindow(configJson: String) {
            // Launch a fresh MainActivity instance with the config
            // JSON in an intent extra. The new Activity's onCreate
            // reads the extra, recognises it as a secondary, loads
            // the configured URL into its own WebView, and skips the
            // Swift runtime spawn. No special flags — the secondary
            // pushes onto the current task's back stack so the system
            // back button returns to the originating Activity, which
            // is the platform-native "open detail / settings view"
            // UX. Multi-instance launching across tasks (separate
            // entries in recents) would need
            // `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_MULTIPLE_TASK`
            // plus `documentLaunchMode` on the manifest — out of
            // scope for the v0.5.x multi-window cut.
            main.post {
                val intent = Intent(activity, activity.javaClass)
                    .putExtra("swift-pwa.config-json", configJson)
                try {
                    activity.startActivity(intent)
                } catch (t: Throwable) {
                    android.util.Log.e(
                        "swift-pwa",
                        "spawnWindow failed: ${t.javaClass.simpleName}: ${t.message}"
                    )
                }
            }
        }

        @Suppress("unused")
        fun setFullscreen(on: Boolean) {
            // Toggles immersive / edge-to-edge layout. The
            // `WindowInsetsControllerCompat` flavour is the
            // forward-compatible replacement for the deprecated
            // `View.setSystemUiVisibility` flag set; it works on every
            // supported API (28+) and adapts to the new behaviour on
            // API 30+ without per-version branching.
            main.post {
                val window = activity.window ?: return@post
                WindowCompat.setDecorFitsSystemWindows(window, !on)
                val controller = WindowInsetsControllerCompat(window, window.decorView)
                if (on) {
                    controller.hide(WindowInsetsCompat.Type.systemBars())
                    // Transient bars on swipe: matches the platform
                    // default for media / game immersive flows and
                    // keeps system gestures reachable.
                    controller.systemBarsBehavior =
                        WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                } else {
                    controller.show(WindowInsetsCompat.Type.systemBars())
                }
            }
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
        // Generic Swift -> Kotlin RPC for the System* plugins.
        //
        // The C shim (`swiftpwa_android_rpc`) packs a method name +
        // JSON args and calls this method. The Swift side gets the
        // result back through `nativeRpcDone`. All dispatch hops to
        // the UI thread first because most of the underlying Android
        // APIs (ClipboardManager, AlertDialog, BiometricPrompt) are
        // documented as UI-thread-only on at least some OEM builds.
        // -------------------------------------------------------------

        @Suppress("unused")
        fun rpcCall(method: String, args: String?, callback: Long, user: Long) {
            main.post {
                try {
                    systemPlugins.dispatch(method, args ?: "{}") { result, error ->
                        nativeRpcDone(result, error, callback, user)
                    }
                } catch (t: Throwable) {
                    val msg = "swift-pwa: rpc $method threw ${t.javaClass.simpleName}: ${t.message}"
                    android.util.Log.e("swift-pwa", msg, t)
                    nativeRpcDone(null, msg, callback, user)
                }
            }
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
        private external fun nativeRpcDone(
            result: String?,
            error: String?,
            callback: Long,
            user: Long
        )
        // Host events (Kotlin -> Swift, one-way) — for asynchronous
        // pushes that don't fit the request/response RPC shape:
        // PackageInstaller status broadcasts and (future) lifecycle
        // hooks. Payload is a JSON string with a `channel` field the
        // Swift `AndroidHostEventRouter` dispatches on.
        external fun nativeHostEvent(json: String)
        @Suppress("unused")
        private external fun nativeQuit(exitCode: Int)
    }
    """#

    // MARK: - System plugins (clipboard, dialog, notifications, biometric, updater)

    static let swiftPWASystemPluginsKt: String = #"""
    package dev.swiftpwa.runtime

    import android.app.Activity
    import android.app.AlertDialog
    import android.app.PendingIntent
    import android.content.BroadcastReceiver
    import android.content.ClipData
    import android.content.ClipboardManager
    import android.content.Context
    import android.content.Intent
    import android.content.IntentFilter
    import android.content.pm.PackageInstaller
    import android.net.Uri
    import android.os.Build
    import android.provider.DocumentsContract
    import android.provider.OpenableColumns
    import android.util.Base64
    import androidx.activity.result.ActivityResultLauncher
    import androidx.activity.result.contract.ActivityResultContracts
    import androidx.appcompat.app.AppCompatActivity
    import androidx.biometric.BiometricManager
    import androidx.biometric.BiometricPrompt
    import androidx.core.app.ActivityCompat
    import androidx.core.app.NotificationCompat
    import androidx.core.app.NotificationManagerCompat
    import androidx.core.content.ContextCompat
    import org.json.JSONArray
    import org.json.JSONObject
    import java.io.File
    import java.io.FileOutputStream
    import java.util.UUID
    import java.util.concurrent.Executors

    /// Backing implementation for the System* plugin RPC the Swift
    /// side dispatches via `SwiftPWABridge.rpcCall`. One method per
    /// Swift plugin entry point; each is invoked on the UI thread by
    /// the bridge's `main.post`.
    ///
    /// **`done` contract.** Every dispatch path must invoke `done`
    /// exactly once with either a JSON result string (or null) or an
    /// error message. The Swift side hangs forever if `done` is
    /// dropped, so async paths (file pickers, biometric prompt) take
    /// extra care to wire success / cancel / error to the same
    /// callback.
    class SwiftPWASystemPlugins(private val activity: Activity, private val bridge: SwiftPWABridge) {
        private val appActivity: AppCompatActivity = activity as AppCompatActivity

        private var notificationsChannelInstalled = false
        private val notificationChannelId = "swift-pwa.default"

        private val backgroundExecutor = Executors.newSingleThreadExecutor()

        // Pending callbacks for the Activity-result launchers. Only
        // one of each can be in flight at a time, which matches the
        // platform's modal-dialog UX.
        private var pendingOpenFile: ((String) -> Unit)? = null
        private var pendingSaveFile: ((String) -> Unit)? = null
        private var pendingOpenDirectory: ((String) -> Unit)? = null
        private var pendingNotificationPerm: ((Boolean) -> Unit)? = null

        // SAF launchers — registered eagerly on construction (which
        // happens during the Activity's onCreate flow) because the
        // ActivityResult API requires registration before STARTED.
        private val openFileLauncher: ActivityResultLauncher<Array<String>> =
            appActivity.registerForActivityResult(
                ActivityResultContracts.OpenMultipleDocuments()
            ) { uris ->
                val cb = pendingOpenFile
                pendingOpenFile = null
                val arr = JSONArray()
                uris.forEach { uri ->
                    arr.put(uri.toString())
                }
                val result = JSONObject().put("paths", arr).toString()
                cb?.invoke(result)
            }

        private val saveFileLauncher: ActivityResultLauncher<String> =
            appActivity.registerForActivityResult(
                ActivityResultContracts.CreateDocument("application/octet-stream")
            ) { uri ->
                val cb = pendingSaveFile
                pendingSaveFile = null
                val result = JSONObject().put("path", uri?.toString()).toString()
                cb?.invoke(result)
            }

        private val openDirectoryLauncher: ActivityResultLauncher<Uri?> =
            appActivity.registerForActivityResult(
                ActivityResultContracts.OpenDocumentTree()
            ) { uri ->
                val cb = pendingOpenDirectory
                pendingOpenDirectory = null
                val result = JSONObject().put("path", uri?.toString()).toString()
                cb?.invoke(result)
            }

        private val notificationPermLauncher: ActivityResultLauncher<String> =
            appActivity.registerForActivityResult(
                ActivityResultContracts.RequestPermission()
            ) { granted ->
                val cb = pendingNotificationPerm
                pendingNotificationPerm = null
                cb?.invoke(granted)
            }

        // Receiver for PackageInstaller status broadcasts. Lazily
        // registered on first install attempt; stays for the
        // Activity's lifetime once installed.
        private var packageInstallerReceiverRegistered = false
        private val packageInstallerAction = "dev.swiftpwa.runtime.INSTALL_RESULT"

        // -----------------------------------------------------------
        // Dispatch
        // -----------------------------------------------------------

        fun dispatch(method: String, args: String, done: (String?, String?) -> Unit) {
            val json = JSONObject(args)
            when (method) {
                "clipboard.read" -> done(clipboardRead(), null)
                "clipboard.write" -> {
                    clipboardWrite(json.optString("text", ""))
                    done(null, null)
                }
                "clipboard.clear" -> {
                    clipboardClear()
                    done(null, null)
                }
                "notifications.requestAuthorization" -> notificationsRequestAuth(done)
                "notifications.send" -> notificationsSend(json, done)
                "dialog.message" -> dialogMessage(json, done)
                "dialog.confirm" -> dialogConfirm(json, done)
                "dialog.openFile" -> dialogOpenFile(json, done)
                "dialog.saveFile" -> dialogSaveFile(json, done)
                "dialog.openDirectory" -> dialogOpenDirectory(done)
                "biometric.canAuthenticate" -> biometricCanAuthenticate(done)
                "biometric.authenticate" -> biometricAuthenticate(json, done)
                "updater.installApk" -> updaterInstallApk(json, done)
                "fs.readContentUri" -> fsReadContentUri(json, done)
                "fs.writeContentUri" -> fsWriteContentUri(json, done)
                "fs.contentUriMetadata" -> fsContentUriMetadata(json, done)
                else -> done(null, "swift-pwa: unknown rpc method $method")
            }
        }

        // -----------------------------------------------------------
        // Clipboard
        // -----------------------------------------------------------

        private fun clipboardManager(): ClipboardManager =
            activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

        private fun clipboardRead(): String {
            val cm = clipboardManager()
            val clip = cm.primaryClip
            val text = if (clip != null && clip.itemCount > 0) {
                clip.getItemAt(0).coerceToText(activity)?.toString()
            } else null
            return JSONObject().put("text", text).toString()
        }

        private fun clipboardWrite(text: String) {
            clipboardManager().setPrimaryClip(ClipData.newPlainText("swift-pwa", text))
        }

        private fun clipboardClear() {
            val cm = clipboardManager()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                cm.clearPrimaryClip()
            } else {
                // API 26 / 27: no explicit clear; replacing with an
                // empty clip is the canonical workaround.
                cm.setPrimaryClip(ClipData.newPlainText("", ""))
            }
        }

        // -----------------------------------------------------------
        // Notifications
        // -----------------------------------------------------------

        private fun ensureNotificationChannel() {
            if (notificationsChannelInstalled) return
            // NotificationCompat handles the API < 26 fall-through by
            // making channel creation a no-op; the call is safe on
            // every supported floor.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = android.app.NotificationChannel(
                    notificationChannelId,
                    "Default",
                    android.app.NotificationManager.IMPORTANCE_DEFAULT
                )
                val nm = activity.getSystemService(android.app.NotificationManager::class.java)
                nm?.createNotificationChannel(channel)
            }
            notificationsChannelInstalled = true
        }

        private fun notificationsAuthorized(): Boolean {
            return NotificationManagerCompat.from(activity).areNotificationsEnabled()
        }

        private fun notificationsRequestAuth(done: (String?, String?) -> Unit) {
            // API 33+: POST_NOTIFICATIONS is a runtime permission.
            // Older API levels: notifications work by default; the
            // user can still toggle them off in system settings, in
            // which case `areNotificationsEnabled` returns false.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val perm = android.Manifest.permission.POST_NOTIFICATIONS
                val already = ContextCompat.checkSelfPermission(activity, perm) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                if (already) {
                    done(JSONObject().put("granted", notificationsAuthorized()).toString(), null)
                    return
                }
                if (pendingNotificationPerm != null) {
                    done(null, "swift-pwa: a notification permission request is already in flight")
                    return
                }
                pendingNotificationPerm = { granted ->
                    val resolved = granted && notificationsAuthorized()
                    done(JSONObject().put("granted", resolved).toString(), null)
                }
                notificationPermLauncher.launch(perm)
            } else {
                done(JSONObject().put("granted", notificationsAuthorized()).toString(), null)
            }
        }

        private fun notificationsSend(json: JSONObject, done: (String?, String?) -> Unit) {
            ensureNotificationChannel()
            val title = json.optString("title", "")
            val body = if (json.has("body") && !json.isNull("body")) json.optString("body") else null
            val sound = json.optBoolean("sound", false)
            val id = (System.currentTimeMillis() and 0x7FFFFFFF).toInt()
            val builder = NotificationCompat.Builder(activity, notificationChannelId)
                .setSmallIcon(activity.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setAutoCancel(true)
            if (body != null) builder.setContentText(body)
            if (!sound) builder.setSilent(true)
            try {
                NotificationManagerCompat.from(activity).notify(id, builder.build())
            } catch (e: SecurityException) {
                // POST_NOTIFICATIONS denied on API 33+; surface a
                // structured error rather than silently no-op.
                done(null, "swift-pwa: notification denied (POST_NOTIFICATIONS not granted)")
                return
            }
            done(JSONObject().put("id", id.toString()).toString(), null)
        }

        // -----------------------------------------------------------
        // Dialog
        // -----------------------------------------------------------

        private fun iconForKind(kind: String?): Int = when (kind) {
            "warning" -> android.R.drawable.ic_dialog_alert
            "error" -> android.R.drawable.stat_notify_error
            else -> android.R.drawable.ic_dialog_info
        }

        private fun dialogMessage(json: JSONObject, done: (String?, String?) -> Unit) {
            val title = if (json.has("title") && !json.isNull("title")) json.optString("title") else null
            val message = json.optString("message", "")
            val kind = if (json.has("kind") && !json.isNull("kind")) json.optString("kind") else null
            AlertDialog.Builder(activity)
                .setTitle(title)
                .setMessage(message)
                .setIcon(iconForKind(kind))
                .setPositiveButton(android.R.string.ok) { d, _ ->
                    d.dismiss()
                    done(null, null)
                }
                .setOnCancelListener { done(null, null) }
                .show()
        }

        private fun dialogConfirm(json: JSONObject, done: (String?, String?) -> Unit) {
            val title = if (json.has("title") && !json.isNull("title")) json.optString("title") else null
            val message = json.optString("message", "")
            val ok = if (json.has("okLabel") && !json.isNull("okLabel"))
                json.optString("okLabel") else activity.getString(android.R.string.ok)
            val cancel = if (json.has("cancelLabel") && !json.isNull("cancelLabel"))
                json.optString("cancelLabel") else activity.getString(android.R.string.cancel)
            val kind = if (json.has("kind") && !json.isNull("kind")) json.optString("kind") else null
            var resolved = false
            val resolve = { ack: Boolean ->
                if (!resolved) {
                    resolved = true
                    done(JSONObject().put("ok", ack).toString(), null)
                }
            }
            AlertDialog.Builder(activity)
                .setTitle(title)
                .setMessage(message)
                .setIcon(iconForKind(kind))
                .setPositiveButton(ok) { d, _ -> d.dismiss(); resolve(true) }
                .setNegativeButton(cancel) { d, _ -> d.dismiss(); resolve(false) }
                .setOnCancelListener { resolve(false) }
                .show()
        }

        private fun mimeTypesFor(filters: JSONArray?): Array<String> {
            if (filters == null || filters.length() == 0) return arrayOf("*/*")
            val collected = mutableSetOf<String>()
            for (i in 0 until filters.length()) {
                val f = filters.optJSONObject(i) ?: continue
                val exts = f.optJSONArray("extensions") ?: continue
                for (j in 0 until exts.length()) {
                    val ext = exts.optString(j).lowercase()
                    val mime = mimeForExtension(ext)
                    collected.add(mime)
                }
            }
            return if (collected.isEmpty()) arrayOf("*/*") else collected.toTypedArray()
        }

        private fun mimeForExtension(ext: String): String = when (ext) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "svg" -> "image/svg+xml"
            "pdf" -> "application/pdf"
            "txt" -> "text/plain"
            "json" -> "application/json"
            "csv" -> "text/csv"
            "html", "htm" -> "text/html"
            "xml" -> "application/xml"
            "zip" -> "application/zip"
            "mp3" -> "audio/mpeg"
            "mp4" -> "video/mp4"
            "mov" -> "video/quicktime"
            "wav" -> "audio/wav"
            else -> "*/*"
        }

        private fun dialogOpenFile(json: JSONObject, done: (String?, String?) -> Unit) {
            if (pendingOpenFile != null) {
                done(null, "swift-pwa: an openFile dialog is already in flight")
                return
            }
            val mimes = mimeTypesFor(json.optJSONArray("filters"))
            pendingOpenFile = { result -> done(result, null) }
            // OpenMultipleDocuments accepts the same array shape for
            // single + multi; the `multiple` flag is honoured at
            // result-handler level by simply returning all picked URIs.
            openFileLauncher.launch(mimes)
        }

        private fun dialogSaveFile(json: JSONObject, done: (String?, String?) -> Unit) {
            if (pendingSaveFile != null) {
                done(null, "swift-pwa: a saveFile dialog is already in flight")
                return
            }
            val name = if (json.has("defaultName") && !json.isNull("defaultName"))
                json.optString("defaultName") else "untitled"
            pendingSaveFile = { result -> done(result, null) }
            saveFileLauncher.launch(name)
        }

        private fun dialogOpenDirectory(done: (String?, String?) -> Unit) {
            if (pendingOpenDirectory != null) {
                done(null, "swift-pwa: an openDirectory dialog is already in flight")
                return
            }
            pendingOpenDirectory = { result -> done(result, null) }
            openDirectoryLauncher.launch(null)
        }

        // -----------------------------------------------------------
        // Biometric
        // -----------------------------------------------------------

        private fun biometricCanAuthenticate(done: (String?, String?) -> Unit) {
            val mgr = BiometricManager.from(activity)
            val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.BIOMETRIC_WEAK
            val result = mgr.canAuthenticate(authenticators)
            val (available, reason) = when (result) {
                BiometricManager.BIOMETRIC_SUCCESS -> true to null
                BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> false to "no biometric hardware"
                BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> false to "biometric hardware unavailable"
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> false to "no biometrics enrolled"
                BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED ->
                    false to "biometric security update required"
                else -> false to "biometrics not available (code $result)"
            }
            // Android doesn't expose fingerprint vs face vs iris at
            // the API level — `unknown` is the honest answer when
            // available, `none` when not.
            val kind = if (available) "unknown" else "none"
            val out = JSONObject()
                .put("available", available)
                .put("kind", kind)
            if (reason != null) out.put("reason", reason)
            done(out.toString(), null)
        }

        private fun biometricAuthenticate(json: JSONObject, done: (String?, String?) -> Unit) {
            val reason = json.optString("reason", "Authenticate")
            val executor = ContextCompat.getMainExecutor(activity)
            var resolved = false
            val resolve = { authenticated: Boolean, error: String? ->
                if (!resolved) {
                    resolved = true
                    val out = JSONObject().put("authenticated", authenticated)
                    if (error != null) out.put("error", error)
                    done(out.toString(), null)
                }
            }
            val callback = object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    val isCancel = errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                        errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                        errorCode == BiometricPrompt.ERROR_CANCELED
                    resolve(false, if (isCancel) "cancelled" else errString.toString())
                }
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    resolve(true, null)
                }
                override fun onAuthenticationFailed() {
                    // Don't terminate on a single failed attempt — the
                    // system prompt allows retries until the user
                    // dismisses or hits the lockout. `onAuthenticationError`
                    // fires the terminal event.
                }
            }
            val prompt = BiometricPrompt(appActivity, executor, callback)
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Authenticate")
                .setSubtitle(reason)
                .setAllowedAuthenticators(
                    BiometricManager.Authenticators.BIOMETRIC_STRONG or
                        BiometricManager.Authenticators.BIOMETRIC_WEAK
                )
                .setNegativeButtonText(activity.getString(android.R.string.cancel))
                .build()
            prompt.authenticate(info)
        }

        // -----------------------------------------------------------
        // Updater install (PackageInstaller.Session)
        // -----------------------------------------------------------

        private fun updaterInstallApk(json: JSONObject, done: (String?, String?) -> Unit) {
            val path = json.optString("path", "")
            if (path.isEmpty()) {
                done(null, "swift-pwa: updater.installApk: path is empty")
                return
            }
            val file = File(path)
            if (!file.exists() || !file.canRead()) {
                done(null, "swift-pwa: updater.installApk: file does not exist or is not readable: $path")
                return
            }
            // The session-write phase is I/O — push to a worker thread
            // so we don't stall the UI thread for a 30 MB APK copy.
            // The commit itself is fire-and-forget (the system shows
            // its own UI), so we resolve `done` once commit() returns
            // — accept / reject is reported via the broadcast
            // receiver, which we don't currently wait on.
            backgroundExecutor.execute {
                try {
                    val installer = activity.packageManager.packageInstaller
                    val params = PackageInstaller.SessionParams(
                        PackageInstaller.SessionParams.MODE_FULL_INSTALL
                    )
                    val sessionId = installer.createSession(params)
                    installer.openSession(sessionId).use { session ->
                        file.inputStream().use { input ->
                            session.openWrite("base.apk", 0, file.length()).use { out ->
                                input.copyTo(out)
                                session.fsync(out)
                            }
                        }
                        registerInstallerReceiverIfNeeded()
                        val intent = Intent(packageInstallerAction).setPackage(activity.packageName)
                        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                        } else {
                            PendingIntent.FLAG_UPDATE_CURRENT
                        }
                        val pending = PendingIntent.getBroadcast(activity, 0, intent, flags)
                        session.commit(pending.intentSender)
                    }
                    done(null, null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: updater.installApk failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        private fun registerInstallerReceiverIfNeeded() {
            if (packageInstallerReceiverRegistered) return
            packageInstallerReceiverRegistered = true
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
                    if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        if (confirm != null) {
                            confirm.flags = confirm.flags or Intent.FLAG_ACTIVITY_NEW_TASK
                            try {
                                activity.startActivity(confirm)
                            } catch (t: Throwable) {
                                android.util.Log.e(
                                    "swift-pwa",
                                    "failed to launch package-installer confirmation: ${t.message}"
                                )
                            }
                        }
                        pushInstallEvent("PENDING_USER_ACTION", null)
                    } else {
                        val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                        android.util.Log.i("swift-pwa", "package install status=$status msg=$msg")
                        pushInstallEvent(installStatusName(status), msg)
                    }
                }
            }
            val filter = IntentFilter(packageInstallerAction)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                activity.registerReceiver(receiver, filter)
            }
        }

        // Stable status-code → name mapping for the install-event
        // payload. Mirrors `PackageInstaller.STATUS_*` constants;
        // unknown / negative codes round-trip as their raw integer so
        // the Swift side can still surface them as
        // `STATUS_UNKNOWN_<code>` rather than swallowing the signal.
        private fun installStatusName(status: Int): String = when (status) {
            PackageInstaller.STATUS_SUCCESS              -> "SUCCESS"
            PackageInstaller.STATUS_FAILURE              -> "FAILURE"
            PackageInstaller.STATUS_FAILURE_ABORTED      -> "FAILURE_ABORTED"
            PackageInstaller.STATUS_FAILURE_BLOCKED      -> "FAILURE_BLOCKED"
            PackageInstaller.STATUS_FAILURE_CONFLICT     -> "FAILURE_CONFLICT"
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "FAILURE_INCOMPATIBLE"
            PackageInstaller.STATUS_FAILURE_INVALID      -> "FAILURE_INVALID"
            PackageInstaller.STATUS_FAILURE_STORAGE      -> "FAILURE_STORAGE"
            else                                         -> "UNKNOWN_$status"
        }

        private fun pushInstallEvent(status: String, message: String?) {
            val payload = JSONObject()
                .put("channel", "updater.install")
                .put("status", status)
            if (message != null) payload.put("message", message)
            try {
                bridge.nativeHostEvent(payload.toString())
            } catch (t: Throwable) {
                android.util.Log.e(
                    "swift-pwa",
                    "failed to push install event: ${t.message}"
                )
            }
        }

        // -----------------------------------------------------------
        // Fs — content:// URI support
        //
        // SAF dialog results are `content://` URIs that
        // SystemFs.readBinary / writeBinary / metadata route through
        // here instead of trying to open them as filesystem paths.
        // Each entry point is I/O — push to the background executor
        // so the UI thread isn't blocked on a media-store read.
        // -----------------------------------------------------------

        private fun fsReadContentUri(json: JSONObject, done: (String?, String?) -> Unit) {
            val uri = json.optString("uri", "")
            if (uri.isEmpty()) {
                done(null, "swift-pwa: fs.readContentUri: uri is empty")
                return
            }
            backgroundExecutor.execute {
                try {
                    val parsed = Uri.parse(uri)
                    val bytes = activity.contentResolver.openInputStream(parsed)?.use {
                        it.readBytes()
                    } ?: run {
                        done(null, "swift-pwa: fs.readContentUri: ContentResolver could not open $uri")
                        return@execute
                    }
                    val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                    val result = JSONObject().put("dataBase64", b64).toString()
                    done(result, null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: fs.readContentUri failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        private fun fsWriteContentUri(json: JSONObject, done: (String?, String?) -> Unit) {
            val uri = json.optString("uri", "")
            val b64 = json.optString("dataBase64", "")
            if (uri.isEmpty()) {
                done(null, "swift-pwa: fs.writeContentUri: uri is empty")
                return
            }
            backgroundExecutor.execute {
                try {
                    val bytes = Base64.decode(b64, Base64.DEFAULT)
                    val parsed = Uri.parse(uri)
                    // Mode "rwt" truncates the existing document
                    // before writing — matches the desktop semantics
                    // of `writeBinary` overwriting in place. SAF
                    // requires the URI to have been issued by
                    // OpenDocument / CreateDocument; arbitrary
                    // content:// authorities can refuse "w" mode.
                    val out = activity.contentResolver.openOutputStream(parsed, "rwt")
                        ?: run {
                            done(null, "swift-pwa: fs.writeContentUri: ContentResolver could not open $uri for writing")
                            return@execute
                        }
                    out.use { it.write(bytes) }
                    done(null, null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: fs.writeContentUri failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        private fun fsContentUriMetadata(json: JSONObject, done: (String?, String?) -> Unit) {
            val uri = json.optString("uri", "")
            if (uri.isEmpty()) {
                done(null, "swift-pwa: fs.contentUriMetadata: uri is empty")
                return
            }
            backgroundExecutor.execute {
                try {
                    val parsed = Uri.parse(uri)
                    // OpenableColumns.SIZE is universally supported
                    // for openable content URIs; LAST_MODIFIED comes
                    // from DocumentsContract.Document and is
                    // available for SAF-issued document URIs but may
                    // be missing on legacy providers. Both columns
                    // are queried in one cursor pass.
                    val projection = arrayOf(
                        OpenableColumns.SIZE,
                        DocumentsContract.Document.COLUMN_LAST_MODIFIED
                    )
                    var size: Long = -1L
                    var modified: Long? = null
                    activity.contentResolver.query(parsed, projection, null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
                                size = cursor.getLong(sizeIdx)
                            }
                            val modIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                            if (modIdx >= 0 && !cursor.isNull(modIdx)) {
                                modified = cursor.getLong(modIdx)
                            }
                        }
                    }
                    val payload = JSONObject().put("size", if (size < 0) 0 else size)
                    if (modified != null) payload.put("modified", modified)
                    done(payload.toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: fs.contentUriMetadata failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }
    }
    """#
}
