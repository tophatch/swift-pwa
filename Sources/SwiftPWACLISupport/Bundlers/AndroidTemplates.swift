import Foundation
import SwiftPWACore

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

    /// Project-level `build.gradle.kts`. Pins AGP + the Kotlin plugin. The
    /// Kotlin version is bumped to 2.2.0 when Gemini Nano is enabled because
    /// the `com.google.mlkit:genai-prompt` artifacts ship Kotlin 2.2.0
    /// metadata, which a 2.0.0 compiler refuses to read ("incompatible
    /// version of Kotlin"). Non-AI builds keep the conservative 2.0.0 pin.
    static func rootBuildGradleKts(enableGeminiNano: Bool = false) -> String {
        let kotlinVersion = enableGeminiNano ? "2.2.0" : "2.0.0"
        return """
        // Project-level Gradle config. The Android Gradle Plugin (AGP) version
        // is pinned; bump it explicitly when rolling Android tooling forward
        // — silent tracking-latest is exactly what makes scaffolds bit-rot.
        plugins {
            id("com.android.application") version "8.5.0" apply false
            id("org.jetbrains.kotlin.android") version "\(kotlinVersion)" apply false
        }
        """
    }

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
        signing: SigningConfig?,
        enableGeminiNano: Bool = false
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
        \(enableGeminiNano ? Self.geminiNanoGradleDeps : "")}
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

    static func androidManifestXml(
        packageId: String,
        label: String,
        hasIcon: Bool,
        customTheme: Bool = false,
        documentTypes: [PWAManifest.AndroidSection.DocumentType] = []
    ) -> String {
        // When the project ships an icon, reference the launcher mipmap the
        // bundler drops into res/mipmap/. aapt/Gradle handle density scaling
        // from the single source PNG at build time — no pre-resizing needed.
        let iconAttr = hasIcon ? "\n            android:icon=\"@mipmap/ic_launcher\"" : ""
        // `window.background_color` set → reference the generated
        // `Theme.SwiftPWA` (in res/values/swift_pwa_theme.xml) so the launch
        // window + system bars paint in that colour instead of the stock
        // light-theme white. Theme.SwiftPWA still descends from
        // Theme.AppCompat.Light.NoActionBar, so the AppCompat inflation
        // constraint below still holds.
        let themeName = customTheme ? "@style/Theme.SwiftPWA" : "@style/Theme.AppCompat.Light.NoActionBar"
        return """
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
                android:label="\(label)"\(iconAttr)
                android:allowBackup="true"
                android:supportsRtl="true"
                android:usesCleartextTraffic="false"
                android:theme="\(themeName)"
                tools:targetApi="34">
                <!-- The base theme is `Theme.AppCompat.Light.NoActionBar`
                     (directly, or via `Theme.SwiftPWA` when
                     `window.background_color` is set) because `MainActivity`
                     extends `AppCompatActivity` (required by the
                     BiometricPrompt + SAF launcher plumbing) and AppCompat
                     refuses to inflate against a non-AppCompat theme:
                     `IllegalStateException: You need to use a
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
                    </intent-filter>\(documentTypeFilters(documentTypes))
                </activity>
            </application>

        </manifest>
        """
    }

    /// The `<intent-filter>` block(s) that make the activity a handler for
    /// `android.document_types` — one `ACTION_VIEW` filter ("Open with") and
    /// one `ACTION_SEND` / `ACTION_SEND_MULTIPLE` filter (share sheet), each
    /// listing every declared MIME type as a `<data>` spec. A MIME-type-only
    /// data spec implicitly matches the `content:` and `file:` schemes, which
    /// is exactly the local-file open-with case. Returns `""` when no document
    /// types are declared, so the manifest is byte-for-byte unchanged for apps
    /// that don't opt in. The leading newline joins onto the LAUNCHER filter.
    private static func documentTypeFilters(_ documentTypes: [PWAManifest.AndroidSection.DocumentType]) -> String {
        // Flatten + de-dup the MIME types, preserving first-seen order.
        var seen = Set<String>()
        let mimeTypes = documentTypes.flatMap(\.mimeTypes).filter { seen.insert($0).inserted }
        guard !mimeTypes.isEmpty else { return "" }
        let dataLines = mimeTypes
            .map { "\n                        <data android:mimeType=\"\(xmlEscape($0))\"/>" }
            .joined()
        return """

                    <intent-filter>
                        <action android:name="android.intent.action.VIEW"/>
                        <category android:name="android.intent.category.DEFAULT"/>\(dataLines)
                    </intent-filter>
                    <intent-filter>
                        <action android:name="android.intent.action.SEND"/>
                        <action android:name="android.intent.action.SEND_MULTIPLE"/>
                        <category android:name="android.intent.category.DEFAULT"/>\(dataLines)
                    </intent-filter>
        """
    }

    /// Minimal XML attribute escaping for values spliced into the manifest.
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Resolved `window.background_color` for the Android backend, as a
    /// light/dark pair. Each mode carries a normalized opaque `#RRGGBB` and a
    /// `lightSystemBars` flag driving `windowLightStatusBar` /
    /// `windowLightNavigationBar` — true (dark icons) when that mode's surface
    /// is light, so the status/navigation glyphs stay legible. A single
    /// configured colour yields identical light and dark modes.
    struct WindowBackground {
        struct Mode: Equatable {
            var hex: String
            var lightSystemBars: Bool

            /// Relative-luminance threshold at 0.5: a light fill wants dark
            /// system-bar icons and vice-versa.
            init(_ rgb: RGBColor) {
                let (r, g, b) = rgb.bytes
                hex = String(format: "#%02X%02X%02X", r, g, b)
                let luminance = 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
                lightSystemBars = luminance > 0.5
            }
        }

        var light: Mode
        var dark: Mode

        /// True when the two modes differ — i.e. a real light/dark pair was
        /// configured, so the pre-paint background needs a night-aware branch.
        var isPair: Bool {
            light != dark
        }

        /// Build from the manifest's `background_color`, parsing both the light
        /// and dark hex. Returns `nil` if either colour is unparseable, so the
        /// build degrades to the stock theme rather than emitting a broken
        /// resource.
        init?(_ color: PWAManifest.BackgroundColor) {
            guard let lightRGB = RGBColor(hex: color.light),
                  let darkRGB = RGBColor(hex: color.dark)
            else { return nil }
            light = Mode(lightRGB)
            dark = Mode(darkRGB)
        }
    }

    /// `res/values{,-night}/swift_pwa_theme.xml` — defines `Theme.SwiftPWA`,
    /// the activity theme referenced by the manifest when
    /// `window.background_color` is set. Painting `android:windowBackground` is
    /// what kills the white launch flash before the WebView's first paint (the
    /// WebView's own `setBackgroundColor` covers the gap between inflation and
    /// first paint); matching the status + navigation bars removes the "this is
    /// just a webview" framing.
    ///
    /// The parent is `Theme.AppCompat.DayNight.NoActionBar` (not `*.Light.*`):
    /// inflating a `Light` theme on an `AppCompatActivity` pins the context to
    /// light `uiMode`, which the `WebView` inherits — so
    /// `prefers-color-scheme: dark` never matched inside the page. DayNight lets
    /// the WebView track the system setting. The bundler writes this file twice
    /// — once under `res/values/` with the light `mode`, once under
    /// `res/values-night/` with the dark `mode` — so Android picks the right
    /// window colour + system-bar glyph luminance per mode. Emitted only when a
    /// colour is configured, so non-themed apps keep the stock theme untouched.
    static func swiftPWAThemeXml(_ mode: WindowBackground.Mode) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <resources>
            <color name="swift_pwa_window_background">\(mode.hex)</color>
            <style name="Theme.SwiftPWA" parent="Theme.AppCompat.DayNight.NoActionBar">
                <item name="android:windowBackground">@color/swift_pwa_window_background</item>
                <item name="android:statusBarColor">@color/swift_pwa_window_background</item>
                <item name="android:navigationBarColor">@color/swift_pwa_window_background</item>
                <item name="android:windowLightStatusBar">\(mode.lightSystemBars)</item>
                <item name="android:windowLightNavigationBar">\(mode.lightSystemBars)</item>
            </style>
        </resources>
        """
    }

    // MARK: - Kotlin

    static func mainActivityKt(
        packageId: String,
        soBaseName: String,
        serveMounts: [PWAManifest.ServeMount] = [],
        background: WindowBackground? = nil
    ) -> String {
        // `window.background_color` set → paint the WebView's own surface to
        // match before its first paint. The activity theme's windowBackground
        // covers the launch flash up to inflation; this covers inflation →
        // first paint (the WebView is otherwise opaque white). Color.parseColor
        // accepts the same `#RRGGBB` the theme colour uses. For a light/dark
        // pair the pre-paint colour must follow the active night mode too —
        // otherwise a dark-mode user gets the light colour flashed before the
        // web content (which the DayNight theme already handles) paints.
        let backgroundColorLine = switch background {
        case .none:
            ""
        case let .some(bg) where !bg.isPair:
            "\n        webView.setBackgroundColor(android.graphics.Color.parseColor(\"\(bg.light.hex)\"))"
        case let .some(bg):
            """

                    val swiftPwaNightMode = (resources.configuration.uiMode and \
            android.content.res.Configuration.UI_MODE_NIGHT_MASK) == \
            android.content.res.Configuration.UI_MODE_NIGHT_YES
                    webView.setBackgroundColor(android.graphics.Color.parseColor(
                        if (swiftPwaNightMode) "\(bg.dark.hex)" else "\(bg.light.hex)"))
            """
        }
        return """
        package \(packageId)

        import android.content.Intent
        import android.net.Uri
        import android.os.Build
        import android.os.Bundle
        import android.webkit.WebView
        import androidx.appcompat.app.AppCompatActivity
        import androidx.webkit.WebViewAssetLoader
        import dev.swiftpwa.runtime.SwiftPWABridge
        import java.io.File
        import kotlin.concurrent.thread
        import org.json.JSONArray
        import org.json.JSONObject

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

                val webView = WebView(this)\(backgroundColorLine)
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
                // Served mounts are registered BEFORE the catch-all "/" bundle
                // handler: WebViewAssetLoader matches handlers in registration
                // order by path prefix, and "/" is a prefix of "/packs/…", so a
                // "/"-first order would let the bundle's AssetsPathHandler
                // shadow every served mount (404 from assets). Specific prefixes
                // must come first.
                val assetLoader = WebViewAssetLoader.Builder()
                    .setDomain("swift-pwa.local")\(serveHandlerLines(serveMounts))
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
                    // A file this app was opened *with* ("Open with" / share)
                    // rides in on the launch intent. Forward it now; the Swift
                    // side buffers the push until its handler is installed on
                    // the runtime thread above, so a cold-launch file isn't
                    // lost to the race.
                    handleOpenFileIntent(intent)
                }
            }

            /// Warm launch: the app is already running and the OS routes it a
            /// new document to open.
            override fun onNewIntent(intent: Intent) {
                super.onNewIntent(intent)
                setIntent(intent)
                handleOpenFileIntent(intent)
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

            /// Forward a document the OS opened the app with — `ACTION_VIEW`
            /// ("Open with") or `ACTION_SEND` / `ACTION_SEND_MULTIPLE` (share
            /// sheet) — to the Swift runtime on the `app.openFile` host-event
            /// channel, which re-emits it to JS (`on('app.openFile', …)`). The
            /// `content://` URIs carry a temporary read grant tied to this
            /// Activity, so the web app reads them via `fs.readBinary`.
            /// Secondary (spawned) windows don't own the runtime, so they skip.
            private fun handleOpenFileIntent(intent: Intent?) {
                if (intent == null || isSecondary) return
                val uris = ArrayList<String>()
                when (intent.action) {
                    Intent.ACTION_VIEW -> intent.data?.let { uris.add(it.toString()) }
                    Intent.ACTION_SEND -> streamExtra(intent)?.let { uris.add(it.toString()) }
                    Intent.ACTION_SEND_MULTIPLE ->
                        streamExtras(intent)?.forEach { uris.add(it.toString()) }
                }
                if (uris.isEmpty()) return
                val payload = JSONObject()
                    .put("channel", "app.openFile")
                    .put("paths", JSONArray(uris))
                try {
                    bridge.nativeHostEvent(payload.toString())
                } catch (t: Throwable) {
                    android.util.Log.e("swift-pwa", "failed to push app.openFile: ${t.message}")
                }
            }

            @Suppress("DEPRECATION")
            private fun streamExtra(intent: Intent): Uri? =
                if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)

            @Suppress("DEPRECATION")
            private fun streamExtras(intent: Intent): List<Uri>? =
                if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)

            /// Provided by the Swift side via `@_cdecl("swiftpwa_android_main")`.
            /// See `docs/android-setup.md` for the wrapping pattern that
            /// turns the user's `configure` closure into this entry point.
            private external fun swiftPwaMain()
        }
        """
    }

    /// Emit the `.addPathHandler(...)` chain entries for each `build.serve`
    /// mount, served from internal storage so range requests work natively.
    /// Each `from` is rooted at the Activity's `filesDir` (default, or an
    /// explicit `data/…` prefix) or `cacheDir` (a `cache/…` prefix), matching
    /// `app.dataDir()` / `app.cacheDir()`. The directory is created if absent
    /// — `InternalStoragePathHandler` requires it to exist within app storage.
    static func serveHandlerLines(_ mounts: [PWAManifest.ServeMount]) -> String {
        mounts.map { mount in
            let prefix = normalizedMountPrefix(mount.mount)
            let (root, sub) = storageRootAndSub(mount.from)
            let dirExpr = sub.isEmpty ? root : "File(\(root), \(kotlinString(sub)))"
            return """

                        .addPathHandler(\(kotlinString(
                            prefix
                        )), WebViewAssetLoader.InternalStoragePathHandler(this, \(dirExpr).apply { mkdirs() }))
            """
            // Note: leading newline + indentation chains onto the builder.
        }.joined()
    }

    /// `/packs` → `/packs/` (handler prefixes must end in `/`); strips a
    /// trailing slash duplication and guarantees a leading slash.
    private static func normalizedMountPrefix(_ raw: String) -> String {
        var p = raw
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p == "/" ? "/" : p + "/"
    }

    /// Split a `from` into (Kotlin root expr, subpath). `cache/…` → cacheDir;
    /// `data/…` or a bare path → filesDir.
    private static func storageRootAndSub(_ from: String) -> (root: String, sub: String) {
        let trimmed = from.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.first == "cache" {
            return ("cacheDir", parts.count > 1 ? parts[1] : "")
        }
        if parts.first == "data" {
            return ("filesDir", parts.count > 1 ? parts[1] : "")
        }
        return ("filesDir", trimmed)
    }

    /// Kotlin double-quoted string literal with the minimal escaping the
    /// generated paths/prefixes need.
    private static func kotlinString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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

    /// Render `SwiftPWASystemPlugins.kt`. When `enableGeminiNano` is true,
    /// splices in the ML Kit GenAI Prompt API imports, the `ai.gemini.*`
    /// dispatch cases, and their backing methods (the matching Gradle
    /// dependency is added by ``appBuildGradleKts(...)``); otherwise the three
    /// placeholders are stripped and the file references no GenAI symbols.
    static func swiftPWASystemPluginsKt(enableGeminiNano: Bool) -> String {
        swiftPWASystemPluginsKtTemplate
            .replacingOccurrences(
                of: "/*__SWIFT_PWA_GENAI_IMPORTS__*/",
                with: enableGeminiNano ? geminiNanoImportsKt : ""
            )
            .replacingOccurrences(
                of: "/*__SWIFT_PWA_GENAI_DISPATCH__*/",
                with: enableGeminiNano ? geminiNanoDispatchKt : ""
            )
            .replacingOccurrences(
                of: "/*__SWIFT_PWA_GENAI_METHODS__*/",
                with: enableGeminiNano ? geminiNanoMethodsKt : ""
            )
    }

    private static let swiftPWASystemPluginsKtTemplate: String = #"""
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
    /*__SWIFT_PWA_GENAI_IMPORTS__*/

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
        // exportFile: the create-document callback plus the bytes to
        // write into the chosen document once the user picks a location.
        private var pendingExportFile: ((String?, String?) -> Unit)? = null
        private var pendingExportBytes: ByteArray? = null

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

        // exportFile = create-document + write. Unlike saveFile (which
        // just hands back the URI), we write the supplied bytes into the
        // chosen document before resolving, so JS gets a "content saved"
        // result in one round-trip. The write is I/O, so it runs on the
        // background executor and reports back through the same callback.
        private val exportFileLauncher: ActivityResultLauncher<String> =
            appActivity.registerForActivityResult(
                ActivityResultContracts.CreateDocument("application/octet-stream")
            ) { uri ->
                val cb = pendingExportFile
                val bytes = pendingExportBytes
                pendingExportFile = null
                pendingExportBytes = null
                if (cb == null) return@registerForActivityResult
                if (uri == null) {
                    // User cancelled — null path, no error.
                    cb(JSONObject().put("path", null as String?).toString(), null)
                    return@registerForActivityResult
                }
                backgroundExecutor.execute {
                    try {
                        val out = activity.contentResolver.openOutputStream(uri, "rwt")
                            ?: run {
                                cb(null, "swift-pwa: dialog.exportFile: ContentResolver could not open $uri for writing")
                                return@execute
                            }
                        out.use { it.write(bytes ?: ByteArray(0)) }
                        cb(JSONObject().put("path", uri.toString()).toString(), null)
                    } catch (t: Throwable) {
                        cb(null, "swift-pwa: dialog.exportFile failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                }
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
                "dialog.exportFile" -> dialogExportFile(json, done)
                "dialog.openDirectory" -> dialogOpenDirectory(done)
                "biometric.canAuthenticate" -> biometricCanAuthenticate(done)
                "biometric.authenticate" -> biometricAuthenticate(json, done)
                "updater.installApk" -> updaterInstallApk(json, done)
                "fs.readContentUri" -> fsReadContentUri(json, done)
                "fs.writeContentUri" -> fsWriteContentUri(json, done)
                "fs.contentUriMetadata" -> fsContentUriMetadata(json, done)
                "fs.listZipNative" -> fsListZipNative(json, done)
                "fs.extractZipNative" -> fsExtractZipNative(json, done)
                "fs.createZipNative" -> fsCreateZipNative(json, done)
                /*__SWIFT_PWA_GENAI_DISPATCH__*/
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

        private fun dialogExportFile(json: JSONObject, done: (String?, String?) -> Unit) {
            if (pendingExportFile != null) {
                done(null, "swift-pwa: an exportFile dialog is already in flight")
                return
            }
            val name = if (json.has("defaultName") && !json.isNull("defaultName"))
                json.optString("defaultName") else "export"
            val bytes = try {
                Base64.decode(json.optString("dataBase64", ""), Base64.DEFAULT)
            } catch (t: Throwable) {
                done(null, "swift-pwa: dialog.exportFile: dataBase64 is not valid base64")
                return
            }
            pendingExportBytes = bytes
            pendingExportFile = done
            exportFileLauncher.launch(name)
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

        // -----------------------------------------------------------
        // Zip extraction (content packs) — ZIPFoundation can't build for
        // Android (Bionic libc), so the Swift `AndroidArchiveExtractor`
        // RPCs into these java.util.zip implementations. The traversal /
        // zip-bomb guards are enforced here since `ZipFile` won't.
        // -----------------------------------------------------------

        private fun fsListZipNative(json: JSONObject, done: (String?, String?) -> Unit) {
            val from = json.optString("from", "")
            if (from.isEmpty()) { done(null, "swift-pwa: fs.listZip: from is empty"); return }
            backgroundExecutor.execute {
                try {
                    val arr = org.json.JSONArray()
                    fun putEntry(name: String, isDir: Boolean, usize: Long, csize: Long) {
                        arr.put(
                            JSONObject()
                                .put("path", name)
                                .put("isDirectory", isDir)
                                .put("isSymlink", false)
                                .put("uncompressedSize", if (usize >= 0) usize else 0L)
                                .put("compressedSize", if (csize >= 0) csize else 0L)
                        )
                    }
                    if (from.startsWith("content://")) {
                        // SAF pick: no usable file path, so stream entries via the
                        // ContentResolver. ZipInputStream is sequential, so sizes
                        // come from local headers and may be 0 for streamed
                        // (data-descriptor) entries.
                        val input = activity.contentResolver.openInputStream(Uri.parse(from))
                            ?: run { done(null, "swift-pwa: fs.listZip: ContentResolver could not open $from"); return@execute }
                        input.use { raw ->
                            java.util.zip.ZipInputStream(java.io.BufferedInputStream(raw)).use { zis ->
                                var ze = zis.nextEntry
                                while (ze != null) {
                                    putEntry(ze.name, ze.isDirectory, ze.size, ze.compressedSize)
                                    zis.closeEntry()
                                    ze = zis.nextEntry
                                }
                            }
                        }
                    } else {
                        java.util.zip.ZipFile(from).use { zf ->
                            val e = zf.entries()
                            while (e.hasMoreElements()) {
                                val ze = e.nextElement()
                                putEntry(ze.name, ze.isDirectory, ze.size, ze.compressedSize)
                            }
                        }
                    }
                    done(JSONObject().put("entries", arr).toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: fs.listZip failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        private fun fsExtractZipNative(json: JSONObject, done: (String?, String?) -> Unit) {
            val from = json.optString("from", "")
            val to = json.optString("to", "")
            if (from.isEmpty() || to.isEmpty()) {
                done(null, "swift-pwa: fs.extractZip: from/to required"); return
            }
            val maxBytes = if (json.has("maxUncompressedBytes")) json.getLong("maxUncompressedBytes") else Long.MAX_VALUE
            val maxEntries = if (json.has("maxEntries")) json.getInt("maxEntries") else Int.MAX_VALUE
            val maxRatio = if (json.has("maxCompressionRatio")) json.getDouble("maxCompressionRatio") else Double.MAX_VALUE
            backgroundExecutor.execute {
                val dest = java.io.File(to)
                val staging = java.io.File(dest.parentFile, ".swift-pwa-extract-" + System.nanoTime())
                try {
                    staging.mkdirs()
                    val stagingCanon = staging.canonicalPath
                    var totalBytes = 0L
                    var count = 0

                    // Path-traversal guard: an entry's canonical path must stay
                    // inside staging. Shared by the file + stream paths.
                    fun guardedOutFile(name: String): java.io.File {
                        val outFile = java.io.File(staging, name)
                        val canon = outFile.canonicalPath
                        if (canon != stagingCanon && !canon.startsWith(stagingCanon + java.io.File.separator)) {
                            throw SecurityException("entry escapes destination (path traversal): $name")
                        }
                        return outFile
                    }

                    if (from.startsWith("content://")) {
                        // SAF pick: stream via the ContentResolver (no file path).
                        // ZipInputStream is sequential and entry sizes can be
                        // unknown until read, so enforce the byte cap *during* the
                        // copy (stronger than a header-size precheck) and apply
                        // the ratio guard only when both sizes are known.
                        val input = activity.contentResolver.openInputStream(Uri.parse(from))
                            ?: run { done(null, "swift-pwa: fs.extractZip: ContentResolver could not open $from"); return@execute }
                        input.use { raw ->
                            java.util.zip.ZipInputStream(java.io.BufferedInputStream(raw)).use { zis ->
                                var ze = zis.nextEntry
                                while (ze != null) {
                                    count++
                                    if (count > maxEntries) throw IllegalStateException("too many entries (limit $maxEntries)")
                                    val outFile = guardedOutFile(ze.name)
                                    if (ze.isDirectory) {
                                        outFile.mkdirs()
                                    } else {
                                        outFile.parentFile?.mkdirs()
                                        val usize = ze.size
                                        val csize = ze.compressedSize
                                        if (usize >= 0 && csize > 0 && usize.toDouble() / csize.toDouble() > maxRatio) {
                                            throw IllegalStateException("compression ratio exceeds limit for ${ze.name}")
                                        }
                                        java.io.FileOutputStream(outFile).use { output ->
                                            val buf = ByteArray(64 * 1024)
                                            var n = zis.read(buf)
                                            while (n >= 0) {
                                                totalBytes += n.toLong()
                                                if (totalBytes > maxBytes) throw IllegalStateException("uncompressed size exceeds limit ($maxBytes)")
                                                output.write(buf, 0, n)
                                                n = zis.read(buf)
                                            }
                                        }
                                    }
                                    zis.closeEntry()
                                    ze = zis.nextEntry
                                }
                            }
                        }
                    } else {
                        java.util.zip.ZipFile(from).use { zf ->
                            val e = zf.entries()
                            while (e.hasMoreElements()) {
                                val ze = e.nextElement()
                                count++
                                if (count > maxEntries) throw IllegalStateException("too many entries (limit $maxEntries)")
                                val outFile = guardedOutFile(ze.name)
                                val usize = if (ze.size >= 0) ze.size else 0L
                                val csize = if (ze.compressedSize > 0) ze.compressedSize else 1L
                                if (usize.toDouble() / csize.toDouble() > maxRatio) {
                                    throw IllegalStateException("compression ratio exceeds limit for ${ze.name}")
                                }
                                totalBytes += usize
                                if (totalBytes > maxBytes) throw IllegalStateException("uncompressed size exceeds limit ($maxBytes)")
                                if (ze.isDirectory) {
                                    outFile.mkdirs()
                                } else {
                                    outFile.parentFile?.mkdirs()
                                    zf.getInputStream(ze).use { input ->
                                        java.io.FileOutputStream(outFile).use { output -> input.copyTo(output) }
                                    }
                                }
                            }
                        }
                    }
                    // Commit staging → dest (move each top-level item into place).
                    dest.mkdirs()
                    staging.listFiles()?.forEach { item ->
                        val target = java.io.File(dest, item.name)
                        if (target.exists()) target.deleteRecursively()
                        if (!item.renameTo(target)) {
                            item.copyRecursively(target, overwrite = true)
                            item.deleteRecursively()
                        }
                    }
                    done(JSONObject().put("entries", count).put("uncompressedBytes", totalBytes).toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: fs.extractZip failed: ${t.javaClass.simpleName}: ${t.message}")
                } finally {
                    if (staging.exists()) staging.deleteRecursively()
                }
            }
        }

        private fun fsCreateZipNative(json: JSONObject, done: (String?, String?) -> Unit) {
            val from = json.optString("from", "")
            val to = json.optString("to", "")
            if (from.isEmpty() || to.isEmpty()) {
                done(null, "swift-pwa: fs.createZip: from/to required"); return
            }
            val compression = json.optString("compression", "stored")
            backgroundExecutor.execute {
                val src = java.io.File(from)
                if (!src.isDirectory) {
                    done(null, "swift-pwa: fs.createZip: from is not a directory: $from"); return@execute
                }
                val dest = java.io.File(to)
                val staging = java.io.File(dest.parentFile, ".swift-pwa-create-" + System.nanoTime() + ".zip")
                try {
                    staging.parentFile?.mkdirs()
                    val basePath = src.canonicalPath
                    // Walk deterministically (sorted), parent-before-child,
                    // skipping symlinks (not followed, not stored).
                    val all = ArrayList<java.io.File>()
                    fun collect(dir: java.io.File) {
                        dir.listFiles()?.sortedBy { it.name }?.forEach { f ->
                            if (java.nio.file.Files.isSymbolicLink(f.toPath())) return@forEach
                            all.add(f)
                            if (f.isDirectory) collect(f)
                        }
                    }
                    collect(src)
                    var totalBytes = 0L
                    var count = 0
                    java.util.zip.ZipOutputStream(
                        java.io.BufferedOutputStream(java.io.FileOutputStream(staging))
                    ).use { zos ->
                        // "stored" maps to deflate level 0 (single-pass, no real
                        // compression): java.util.zip's true STORED method needs
                        // a CRC pre-pass (a second read of every file), which a
                        // multi-GB pack export can't afford. "deflate" uses the
                        // default level. Output is a valid zip either way.
                        zos.setLevel(
                            if (compression == "deflate") java.util.zip.Deflater.DEFAULT_COMPRESSION else 0
                        )
                        for (f in all) {
                            val rel = f.canonicalPath
                                .removePrefix(basePath + java.io.File.separator)
                                .replace(java.io.File.separatorChar, '/')
                            if (f.isDirectory) {
                                zos.putNextEntry(java.util.zip.ZipEntry("$rel/"))
                                zos.closeEntry()
                            } else {
                                zos.putNextEntry(java.util.zip.ZipEntry(rel))
                                java.io.FileInputStream(f).use { input -> totalBytes += input.copyTo(zos) }
                                zos.closeEntry()
                            }
                            count++
                        }
                    }
                    dest.parentFile?.mkdirs()
                    if (dest.exists()) dest.delete()
                    if (!staging.renameTo(dest)) {
                        staging.copyTo(dest, overwrite = true); staging.delete()
                    }
                    done(JSONObject().put("entries", count).put("uncompressedBytes", totalBytes).toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: fs.createZip failed: ${t.javaClass.simpleName}: ${t.message}")
                } finally {
                    if (staging.exists()) staging.delete()
                }
            }
        }
        /*__SWIFT_PWA_GENAI_METHODS__*/
    }
    """#

    // MARK: - Gemini Nano (ML Kit GenAI Prompt API) Kotlin blocks

    //
    // Spliced into `SwiftPWASystemPlugins.kt` only when `ai.gemini_nano: true`.
    // These target `com.google.mlkit:genai-prompt` (beta) + AICore: the model
    // is platform-managed (no app-shipped weights), `checkStatus()` reports
    // readiness, and `download()` fetches it on demand. ML Kit symbol paths are
    // written out fully-qualified so the only imports added are kotlinx
    // coroutines; the API is beta, so the exact paths are confirmed on-device
    // against the bundled version (see docs/android-setup.md). The Swift
    // `GeminiNanoBackend` RPCs into the four `ai.gemini.*` methods below.

    /// The `app/build.gradle.kts` dependency lines for Gemini Nano, spliced
    /// into the `dependencies { }` block when `ai.gemini_nano: true`. Leading
    /// `\n` + 12-space indent so it nests under the existing entries; trailing
    /// 8-space line so the block's closing `}` lands at the right column.
    private static let geminiNanoGradleDeps: String =
        "\n            // Gemini Nano (ML Kit GenAI Prompt API) — added by ai.gemini_nano.\n"
            + "            // Drives AICore's on-device model; the API is coroutine/Flow-based.\n"
            + "            implementation(\"com.google.mlkit:genai-prompt:1.0.0-beta2\")\n"
            + "            implementation(\"org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1\")\n"
            + "        "

    private static let geminiNanoImportsKt: String = """
    import kotlinx.coroutines.CoroutineScope
    import kotlinx.coroutines.Dispatchers
    import kotlinx.coroutines.SupervisorJob
    import kotlinx.coroutines.launch
    import kotlinx.coroutines.flow.collect
    """

    private static let geminiNanoDispatchKt: String = """
    "ai.gemini.info" -> geminiInfo(done)
                "ai.gemini.generate" -> geminiGenerate(json, done)
                "ai.gemini.generateStream" -> geminiGenerateStream(json, done)
                "ai.gemini.ensureModel" -> geminiEnsureModel(json, done)
    """

    private static let geminiNanoMethodsKt: String = #"""
    // -----------------------------------------------------------
        // Gemini Nano (ML Kit GenAI Prompt API)
        // -----------------------------------------------------------

        // Background scope for the suspend/Flow GenAI calls. SupervisorJob so
        // one failed generation doesn't cancel the scope for the next.
        private val genaiScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

        // The generative client is cheap to hold and reused across calls.
        // AICore arbitrates device compute, so concurrent requests are fine.
        private val genaiModel: com.google.mlkit.genai.prompt.GenerativeModel by lazy {
            com.google.mlkit.genai.prompt.Generation.getClient()
        }

        // Gemini Nano has no separate "system" role; fold any system prompt
        // into the text part. temperature / maxOutputTokens map from the
        // cross-platform AIGenerateRequest knobs.
        private fun geminiBuildRequest(json: JSONObject): com.google.mlkit.genai.prompt.GenerateContentRequest {
            val system = json.optString("system", "")
            val prompt = json.optString("prompt", "")
            val full = if (system.isNotEmpty()) "$system\n\n$prompt" else prompt
            return com.google.mlkit.genai.prompt.generateContentRequest(
                com.google.mlkit.genai.prompt.TextPart(full)
            ) {
                if (json.has("temperature")) temperature = json.getDouble("temperature").toFloat()
                if (json.has("maxTokens")) maxOutputTokens = json.getInt("maxTokens")
            }
        }

        private fun geminiInfo(done: (String?, String?) -> Unit) {
            genaiScope.launch {
                try {
                    val status = genaiModel.checkStatus()
                    // DOWNLOADABLE / DOWNLOADING still count as available — the
                    // page routes on `available` and triggers ai.ensureModel.
                    val available = status != com.google.mlkit.genai.common.FeatureStatus.UNAVAILABLE
                    val result = JSONObject()
                        .put("available", available)
                        .put("model", "gemini-nano")
                    done(result.toString(), null)
                } catch (t: Throwable) {
                    // No AICore / GenAI on this device — report unavailable
                    // rather than failing, so the app falls back to its tier.
                    done(JSONObject().put("available", false).toString(), null)
                }
            }
        }

        private fun geminiGenerate(json: JSONObject, done: (String?, String?) -> Unit) {
            genaiScope.launch {
                try {
                    val response = genaiModel.generateContent(geminiBuildRequest(json))
                    // GenerateContentResponse.candidates: List<Candidate>; Candidate.text: String.
                    val text = response.candidates.firstOrNull()?.text ?: ""
                    done(JSONObject().put("text", text).toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: ai.gemini.generate failed: ${t.message}")
                }
            }
        }

        private fun geminiGenerateStream(json: JSONObject, done: (String?, String?) -> Unit) {
            val channel = json.optString("channel", "")
            genaiScope.launch {
                try {
                    // Each Flow chunk is a GenerateContentResponse carrying the
                    // newly-generated text in its first candidate (incremental).
                    genaiModel.generateContentStream(geminiBuildRequest(json)).collect { chunk ->
                        val delta = chunk.candidates.firstOrNull()?.text ?: ""
                        if (delta.isNotEmpty()) {
                            pushGenAiEvent(channel, JSONObject().put("type", "delta").put("text", delta))
                        }
                    }
                    pushGenAiEvent(channel, JSONObject().put("type", "done"))
                    done(null, null)
                } catch (t: Throwable) {
                    val msg = t.message ?: "generation failed"
                    pushGenAiEvent(channel, JSONObject().put("type", "error").put("message", msg))
                    done(null, "swift-pwa: ai.gemini.generateStream failed: $msg")
                }
            }
        }

        private fun geminiEnsureModel(json: JSONObject, done: (String?, String?) -> Unit) {
            val channel = json.optString("channel", "")
            genaiScope.launch {
                try {
                    val status = genaiModel.checkStatus()
                    if (status == com.google.mlkit.genai.common.FeatureStatus.AVAILABLE) {
                        pushGenAiEvent(channel, JSONObject().put("type", "done"))
                        done(null, null)
                        return@launch
                    }
                    // AICore manages the bytes; we forward a coarse progress
                    // tick per download-status emission (byte counts aren't
                    // always exposed by the beta API).
                    genaiModel.download().collect {
                        pushGenAiEvent(channel, JSONObject().put("type", "progress"))
                    }
                    pushGenAiEvent(channel, JSONObject().put("type", "done"))
                    done(null, null)
                } catch (t: Throwable) {
                    val msg = t.message ?: "download failed"
                    pushGenAiEvent(channel, JSONObject().put("type", "error").put("message", msg))
                    done(null, "swift-pwa: ai.gemini.ensureModel failed: $msg")
                }
            }
        }

        // Push a GenAI stream frame as a host event on `channel`; the Swift
        // GeminiNanoBackend's AsyncThrowingStream consumes it. Mirrors the
        // updater's pushInstallEvent.
        private fun pushGenAiEvent(channel: String, payload: JSONObject) {
            if (channel.isEmpty()) return
            payload.put("channel", channel)
            try {
                bridge.nativeHostEvent(payload.toString())
            } catch (t: Throwable) {
                android.util.Log.e("swift-pwa", "failed to push genai event: ${t.message}")
            }
        }
    """#
}
