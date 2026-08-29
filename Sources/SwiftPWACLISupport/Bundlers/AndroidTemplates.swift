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
            // EncryptedSharedPreferences (Keystore-backed AES) for the
            // secrets.* plugin — the secure store the SecretsPlugin RPC writes
            // to. Present unconditionally, like the net.* / biometric wiring;
            // the capability is opt-in on the Swift side (SecretsPlugin).
            implementation("androidx.security:security-crypto:1.1.0-alpha06")
            // OkHttp for the net.ws.* WebSocket RPC — Android's HttpURLConnection
            // (which backs net.request / net.downloadFile) has no WebSocket, and
            // java.net.http isn't on Android. Present unconditionally like the rest
            // of the net.* wiring; the capability is opt-in on the Swift side
            // (AndroidNetworkClient.openWebSocket, driven by the remote-AI tier).
            implementation("com.squareup.okhttp3:okhttp:4.12.0")
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
        documentTypes: [PWAManifest.AndroidSection.DocumentType] = [],
        networkConfigStaged: Bool = false,
        webPermissions: [String] = [],
        minSdk: Int = 28
    ) -> String {
        // `permissions` in pwa.json → `uses-permission`. Emitted only for what
        // the app declares: an undeclared permission in the manifest is a Play
        // Store review question and a scarier install screen, for a capability
        // the runtime would refuse anyway.
        var androidPermissions: [AndroidUsesPermission] = []
        for permission in webPermissions {
            for entry in androidPermissionNames(for: permission, minSdk: minSdk) {
                guard let existing = androidPermissions.firstIndex(where: { $0.name == entry.name }) else {
                    androidPermissions.append(entry)
                    continue
                }
                // Two declarations can want the same Android permission on
                // different terms — `bluetooth` asks for ACCESS_FINE_LOCATION
                // capped at API 30, `geolocation` needs it uncapped forever.
                // Keeping whichever was seen first would silently break the
                // other, so the widest grant wins.
                androidPermissions[existing] = widest(androidPermissions[existing], entry)
            }
        }
        var webPermissionBlock = ""
        if !androidPermissions.isEmpty {
            let comment = "\n    <!-- permissions in pwa.json. Declaring here grants nothing on"
                + "\n         its own: the WebView still asks the app per request"
                + "\n         (WebChromeClient.onPermissionRequest), answered from"
                + "\n         ctx.permissions, and Android still prompts the user. -->"
            let lines = androidPermissions.map { "\n    " + $0.xml }.joined()
            webPermissionBlock = comment + lines
        }
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
        // `android.network.cleartext_domains` set → reference the generated
        // res/xml/network_security_config.xml. On API 28+ its base-config
        // (cleartext off) governs, so `usesCleartextTraffic` below is moot but
        // kept for older levels; the config permits cleartext only to the
        // listed hosts. Absent → no attribute, manifest byte-for-byte unchanged.
        let networkConfigAttr = networkConfigStaged
            ? "\n            android:networkSecurityConfig=\"@xml/network_security_config\""
            : ""
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
            <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>\(webPermissionBlock)

            <application
                android:label="\(label)"\(iconAttr)
                android:allowBackup="true"
                android:supportsRtl="true"
                android:usesCleartextTraffic="false"\(networkConfigAttr)
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
    /// One `<uses-permission>` line. Most need nothing but a name; Bluetooth
    /// needs both of the other two attributes, which is why this isn't a
    /// `[String]`.
    struct AndroidUsesPermission: Equatable {
        var name: String
        /// `android:usesPermissionFlags`, e.g. `neverForLocation`.
        var flags: String?
        /// `android:maxSdkVersion` — for a permission superseded on a later
        /// API level, so a modern device isn't asked for the legacy one.
        var maxSdkVersion: Int?

        var xml: String {
            var attributes = "android:name=\"\(name)\""
            if let flags { attributes += " android:usesPermissionFlags=\"\(flags)\"" }
            if let maxSdkVersion { attributes += " android:maxSdkVersion=\"\(maxSdkVersion)\"" }
            return "<uses-permission \(attributes)/>"
        }
    }

    /// The same permission asked for twice, resolved to the grant that
    /// satisfies both: no version cap beats a cap, a later cap beats an earlier
    /// one, and a flag is only kept if *both* asked for it (`neverForLocation`
    /// is a promise, and one caller keeping it while another needs the location
    /// would be a promise the app doesn't keep).
    private static func widest(
        _ a: AndroidUsesPermission, _ b: AndroidUsesPermission
    ) -> AndroidUsesPermission {
        let maxSdkVersion: Int? = if let x = a.maxSdkVersion, let y = b.maxSdkVersion { max(x, y) } else { nil }
        return AndroidUsesPermission(
            name: a.name,
            flags: a.flags == b.flags ? a.flags : nil,
            maxSdkVersion: maxSdkVersion
        )
    }

    /// The Android permissions one declared permission needs. Location
    /// declares both precision levels: with only `ACCESS_FINE_LOCATION`, the
    /// system dialog never offers the user the coarse-only choice.
    private static func androidPermissionNames(
        for webPermission: String, minSdk: Int
    ) -> [AndroidUsesPermission] {
        switch webPermission {
        // MODIFY_AUDIO_SETTINGS as well as RECORD_AUDIO: Chromium's Android
        // audio manager requires *both* before it will open a recording
        // device, and without it `getUserMedia` fails `NotReadableError`
        // ("Could not start audio source") with the runtime permission
        // granted — a failure that looks like broken hardware rather than a
        // missing declaration. It's an install-time permission, so it adds no
        // prompt and stays out of the runtime request.
        case "microphone": [
                AndroidUsesPermission(name: "android.permission.RECORD_AUDIO"),
                AndroidUsesPermission(name: "android.permission.MODIFY_AUDIO_SETTINGS")
            ]
        case "camera": [AndroidUsesPermission(name: "android.permission.CAMERA")]
        case "geolocation": [
                AndroidUsesPermission(name: "android.permission.ACCESS_FINE_LOCATION"),
                AndroidUsesPermission(name: "android.permission.ACCESS_COARSE_LOCATION")
            ]
        case "bluetooth": bluetoothPermissions(minSdk: minSdk)
        // `notifications` is already declared unconditionally above for the
        // native notifications plugin, so it adds nothing here.
        default: []
        }
    }

    /// Bluetooth is declared twice over, because Android 12 (API 31) replaced
    /// the whole scheme.
    ///
    /// Before 31 a BLE *scan* needed `ACCESS_FINE_LOCATION` — scanning reveals
    /// where you are — so an app that only ever talks to a peripheral had to
    /// ask for location anyway. From 31 there's a Bluetooth-specific pair, and
    /// `neverForLocation` is the app promising not to infer a position from
    /// scan results, which is what lets it skip the location permission.
    ///
    /// The legacy three carry `maxSdkVersion` so a modern device doesn't see
    /// them at all, and they're only emitted when the app's `minSdk` can
    /// actually reach that far back.
    private static func bluetoothPermissions(minSdk: Int) -> [AndroidUsesPermission] {
        var permissions = [
            AndroidUsesPermission(name: "android.permission.BLUETOOTH_SCAN", flags: "neverForLocation"),
            AndroidUsesPermission(name: "android.permission.BLUETOOTH_CONNECT")
        ]
        guard minSdk < 31 else { return permissions }
        permissions += [
            AndroidUsesPermission(name: "android.permission.BLUETOOTH", maxSdkVersion: 30),
            AndroidUsesPermission(name: "android.permission.BLUETOOTH_ADMIN", maxSdkVersion: 30),
            AndroidUsesPermission(name: "android.permission.ACCESS_FINE_LOCATION", maxSdkVersion: 30)
        ]
        return permissions
    }

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

    /// The `res/xml/network_security_config.xml` for
    /// `android.network.cleartext_domains`: cleartext (plain `http://`) stays
    /// **off** globally via `base-config`, and is permitted only for the listed
    /// hosts via a scoped `domain-config`. A `"*.<suffix>"` entry becomes an
    /// `includeSubdomains` domain on `<suffix>`; any other entry is a literal
    /// host. De-dups, preserving first-seen order. Returns `nil` when no usable
    /// domain remains — the caller then stages nothing and the manifest is
    /// unchanged.
    static func networkSecurityConfigXml(domains: [String]) -> String? {
        var seen = Set<String>()
        let entries = domains
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !entries.isEmpty else { return nil }
        let domainLines = entries.map { entry -> String in
            if entry.hasPrefix("*.") {
                let base = String(entry.dropFirst(2))
                return "        <domain includeSubdomains=\"true\">\(xmlEscape(base))</domain>"
            }
            return "        <domain includeSubdomains=\"false\">\(xmlEscape(entry))</domain>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Generated by swift-pwa from android.network.cleartext_domains.
             Cleartext (plain http://) stays OFF everywhere except the hosts
             below — the least-broad opt-in for reaching a LAN appliance. -->
        <network-security-config>
            <base-config cleartextTrafficPermitted="false"/>
            <domain-config cleartextTrafficPermitted="true">
        \(domainLines)
            </domain-config>
        </network-security-config>
        """
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

        import android.content.ComponentCallbacks2
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

            /// Map `onTrimMemory` bands to the normalized `system.memoryPressure`
            /// levels and push them to the Swift runtime, which re-emits on the
            /// JS event bus. Only the RUNNING_* foreground-pressure bands are
            /// forwarded — UI_HIDDEN / BACKGROUND / MODERATE are lifecycle hints
            /// about being backgrounded, not "shed caches now" pressure. This is
            /// the Android counterpart to Apple's `DispatchSource` in
            /// `SystemPlugin`.
            @Suppress("DEPRECATION")
            override fun onTrimMemory(level: Int) {
                super.onTrimMemory(level)
                if (isSecondary) return
                val normalized = when (level) {
                    ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL,
                    ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> "critical"
                    ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW,
                    ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE -> "warning"
                    else -> return
                }
                val payload = JSONObject()
                    .put("channel", "system.memoryPressure")
                    .put("level", normalized)
                try {
                    bridge.nativeHostEvent(payload.toString())
                } catch (t: Throwable) {
                    android.util.Log.e("swift-pwa", "failed to push system.memoryPressure: ${t.message}")
                }
            }

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

    /// `spaFallback` / `entry` come from `pwa.json`'s `web.spa_fallback` /
    /// `web.entry` and are baked into the generated bridge so
    /// `shouldInterceptRequest` can serve the entry document for a client-side
    /// route the `WebViewAssetLoader` would 404 (the Android counterpart to the
    /// desktop `AssetProvider` fallback).
    static func swiftPWABridgeKt(spaFallback: Bool = false, entry: String = "index.html") -> String {
        let spaEntryLiteral = kotlinString(entry)
        return #"""
        package dev.swiftpwa.runtime

        import android.app.Activity
        import android.os.Handler
        import android.os.Looper
        import android.webkit.GeolocationPermissions
        import android.webkit.JavascriptInterface
        import android.webkit.PermissionRequest
        import android.webkit.WebChromeClient
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

            // SPA history-routing fallback, baked in from pwa.json's
            // web.spa_fallback / web.entry (see AndroidTemplates.swiftPWABridgeKt).
            private val spaFallback = \#(spaFallback)
            private val spaEntry = \#(spaEntryLiteral)

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
                // The app's own JS (first-party content served from pwa://) may play
                // audio/video it generates — e.g. on-device TTS. Autoplay policies
                // exist to tame untrusted web pages; for a first-party wrapper they
                // just break `audio.play()` (silent, since a long async breaks the
                // user-gesture chain). Allow programmatic playback without a gesture.
                webView.settings.mediaPlaybackRequiresUserGesture = false
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
                        val response = assetLoader.shouldInterceptRequest(request.url)
                        // SPA history-routing fallback: a main-frame navigation to a
                        // client-side route with no file under assets/web/ (the loader
                        // returns null / a not-found with no data) loads the entry
                        // document instead of failing. Sub-resources (JS/CSS — not
                        // main-frame) and asset URLs with an extension are never masked,
                        // so a missing chunk still 404s honestly.
                        if (spaFallback && request.isForMainFrame && response?.data == null) {
                            val last = request.url.lastPathSegment ?: ""
                            if (!last.contains('.')) {
                                val entryUrl = android.net.Uri.parse(
                                    "https://swift-pwa.local/web/" + spaEntry
                                )
                                return assetLoader.shouldInterceptRequest(entryUrl)
                            }
                        }
                        return response
                    }
                    override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                        super.onPageStarted(view, url, favicon)
                        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                            view.evaluateJavascript(bridgeJs, null)
                        }
                    }
                }

                // Without a WebChromeClient at all, `onPermissionRequest` and
                // `onGeolocationPermissionsShowPrompt` take their default —
                // which is to deny, silently. That's why camera, microphone
                // and location never worked in a WebView app: the page saw
                // `NotAllowedError` / `PERMISSION_DENIED`, indistinguishable
                // from the user refusing, having never been asked.
                webView.webChromeClient = object : WebChromeClient() {
                    override fun onPermissionRequest(request: PermissionRequest) {
                        val kinds = ArrayList<String>()
                        for (resource in request.resources) {
                            when (resource) {
                                PermissionRequest.RESOURCE_AUDIO_CAPTURE -> kinds.add("microphone")
                                PermissionRequest.RESOURCE_VIDEO_CAPTURE -> kinds.add("camera")
                                // MIDI sysex and protected media are not
                                // modelled; leaving them out of `kinds` denies
                                // the whole request, which is what they got
                                // before this client existed.
                                else -> {}
                            }
                        }
                        if (kinds.size != request.resources.size) {
                            request.deny()
                            return
                        }
                        systemPlugins.requestWebPermission(kinds, request.origin.toString()) { allowed ->
                            // One request, all-or-nothing: `getUserMedia({audio,
                            // video})` arrives here as a single request carrying
                            // both resources.
                            if (allowed) request.grant(request.resources) else request.deny()
                        }
                    }

                    override fun onPermissionRequestCanceled(request: PermissionRequest) {
                        // The page navigated or dropped the request. Nothing to
                        // revoke — the parked entry resolves harmlessly if the
                        // policy answers late.
                    }

                    override fun onGeolocationPermissionsShowPrompt(
                        origin: String,
                        callback: GeolocationPermissions.Callback
                    ) {
                        systemPlugins.requestWebPermission(listOf("geolocation"), origin) { allowed ->
                            // `retain: false` — the decision isn't cached across
                            // launches, so a revoked app-level veto takes effect
                            // immediately rather than being masked by WebView's
                            // own memory of a past grant.
                            callback.invoke(origin, allowed, false)
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
                    // resolver in bridge.js. Build the argument as a double-quoted
                    // JS string literal (via org.json.JSONObject.quote), NOT a
                    // template literal: a template literal treats `${…}` as
                    // interpolation, so a payload whose text contains `${…}` — e.g.
                    // fs.readText of a file with a `${secret}` REST-header template —
                    // made JS evaluate `${secret}` → ReferenceError inside
                    // evaluateJavascript, so __deliver never ran and the JS promise
                    // hung forever (readBinary was unaffected — base64 has no `${`).
                    // Inside double quotes `${…}` is inert; this matches how the
                    // Apple/GTK/WebView2 backends already escape the payload.
                    val arg = org.json.JSONObject.quote(json)
                    webView.evaluateJavascript(
                        "globalThis.__SWIFT_PWA__.__deliver($arg)",
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
    }

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
    import android.app.ActivityManager
    import android.app.AlertDialog
    import android.app.PendingIntent
    import android.content.BroadcastReceiver
    import android.content.ClipData
    import android.content.ClipboardManager
    import android.content.Context
    import android.content.Intent
    import android.content.IntentFilter
    import android.content.pm.PackageInstaller
    import android.graphics.Bitmap
    import android.graphics.BitmapFactory
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
    import androidx.security.crypto.EncryptedSharedPreferences
    import androidx.security.crypto.MasterKey
    import org.json.JSONArray
    import org.json.JSONObject
    import java.io.ByteArrayOutputStream
    import java.io.File
    import java.io.FileOutputStream
    import java.net.HttpURLConnection
    import java.net.URL
    import java.security.MessageDigest
    import java.util.UUID
    import java.util.concurrent.ConcurrentHashMap
    import java.util.concurrent.Executors
    import okhttp3.OkHttpClient
    import okhttp3.Request
    import okhttp3.Response
    import okhttp3.WebSocket
    import okhttp3.WebSocketListener
    import okio.ByteString
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
        // Web permission requests (camera / microphone / location) waiting on
        // the Swift-side policy, keyed by the id sent with the host event.
        // A map rather than a single slot: a page may ask for the camera and
        // for location at once, and neither is modal.
        private var pendingWebPermissions = HashMap<Int, (Boolean) -> Unit>()
        private var nextWebPermissionId = 1
        // Set while the OS runtime-permission dialog is up, so a second web
        // request queues behind it instead of racing the launcher's single slot.
        private var pendingOsPermission: ((Boolean) -> Unit)? = null
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

        // Camera / microphone / location, which the WebView cannot request
        // for itself: `onPermissionRequest` fires *after* Android has already
        // decided the app has no such permission, so the app has to ask.
        private val webPermLauncher: ActivityResultLauncher<Array<String>> =
            appActivity.registerForActivityResult(
                ActivityResultContracts.RequestMultiplePermissions()
            ) { results ->
                val cb = pendingOsPermission
                pendingOsPermission = null
                // Every requested permission must land: a page asking for
                // audio *and* video can't be half-granted through one
                // MediaStream request.
                cb?.invoke(results.isNotEmpty() && results.values.all { it })
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
                "permissions.resolve" -> permissionsResolve(json, done)
                "geo.current" -> geoCurrent(json, done)
                "geo.watch.start" -> geoWatchStart(json, done)
                "geo.watch.stop" -> geoWatchStop(json, done)
                "notifications.send" -> notificationsSend(json, done)
                "dialog.message" -> dialogMessage(json, done)
                "dialog.confirm" -> dialogConfirm(json, done)
                "dialog.openFile" -> dialogOpenFile(json, done)
                "dialog.saveFile" -> dialogSaveFile(json, done)
                "dialog.exportFile" -> dialogExportFile(json, done)
                "dialog.openDirectory" -> dialogOpenDirectory(done)
                "dialog.takePersistableUri" -> dialogTakePersistableUri(json, done)
                "dialog.checkPersistedUri" -> dialogCheckPersistedUri(json, done)
                "biometric.canAuthenticate" -> biometricCanAuthenticate(done)
                "biometric.authenticate" -> biometricAuthenticate(json, done)
                "updater.installApk" -> updaterInstallApk(json, done)
                "fs.readContentUri" -> fsReadContentUri(json, done)
                "fs.writeContentUri" -> fsWriteContentUri(json, done)
                "fs.contentUriMetadata" -> fsContentUriMetadata(json, done)
                "fs.listZipNative" -> fsListZipNative(json, done)
                "fs.extractZipNative" -> fsExtractZipNative(json, done)
                "fs.createZipNative" -> fsCreateZipNative(json, done)
                "vision.preprocessImage" -> visionPreprocessImage(json, done)
                "image.decode" -> imageDecode(json, done)
                "image.encode" -> imageEncode(json, done)
                "image.capabilities" -> imageCapabilities(done)
                "net.downloadFile" -> netDownloadFile(json, done)
                "net.request" -> netRequest(json, done)
                "net.ws.open" -> netWebSocketOpen(json, done)
                "net.ws.close" -> netWebSocketClose(json, done)
                "secrets.get" -> secretsGet(json, done)
                "secrets.set" -> secretsSet(json, done)
                "secrets.delete" -> secretsDelete(json, done)
                "system.memory" -> systemMemory(done)
                "ble.availability" -> bleAvailability(done)
                "ble.scan.start" -> bleScanStart(json, done)
                "ble.scan.stop" -> bleScanStop(done)
                "ble.connect" -> bleConnect(json, done)
                "ble.disconnect" -> bleDisconnect(json, done)
                "ble.write" -> bleWrite(json, done)
                "ble.read" -> bleRead(json, done)
                "ble.setNotify" -> bleSetNotify(json, done)
                /*__SWIFT_PWA_GENAI_DISPATCH__*/
                else -> done(null, "swift-pwa: unknown rpc method $method")
            }
        }

        // -----------------------------------------------------------
        // System (device memory)
        // -----------------------------------------------------------

        // `system.memory`: a point-in-time device-memory read. `totalMem` /
        // `availMem` come from ActivityManager.MemoryInfo; `appLimitBytes` is
        // the large-heap class (getLargeMemoryClass, in MiB) — a device-tier
        // proxy, since a WebView canvas app's real pressure is usually native/
        // GPU memory, not the Java heap. `lowMemory` is the OS's own flag.
        private fun systemMemory(done: (String?, String?) -> Unit) {
            val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val info = ActivityManager.MemoryInfo()
            am.getMemoryInfo(info)
            val appLimitBytes = am.largeMemoryClass.toLong() * 1024L * 1024L
            val result = JSONObject()
                .put("physicalBytes", info.totalMem)
                .put("availableBytes", info.availMem)
                .put("appLimitBytes", appLimitBytes)
                .put("lowMemory", info.lowMemory)
                .toString()
            done(result, null)
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

        // -----------------------------------------------------------
        // Bluetooth LE (ble.*)
        // -----------------------------------------------------------

        // One GATT operation at a time, per connection. Android's stack has a
        // single outstanding request per `BluetoothGatt`, and a second one
        // issued before the first completes doesn't queue — `writeCharacteristic`
        // returns false and nothing is reported, which reads as a peripheral
        // that ignored the write. So every operation goes through this queue
        // and the next starts only when the callback for the last one arrives.
        private class GattQueue {
            private val pending = java.util.ArrayDeque<() -> Boolean>()
            private var running = false

            @Synchronized fun submit(operation: () -> Boolean) {
                pending.add(operation)
                if (!running) next()
            }

            @Synchronized fun completed() {
                running = false
                next()
            }

            @Synchronized fun clear() {
                pending.clear()
                running = false
            }

            private fun next() {
                while (!running) {
                    val operation = pending.poll() ?: return
                    running = true
                    // A `false` means the stack refused to even start it, so
                    // no callback is coming and the queue would stall here.
                    if (!operation()) running = false
                }
            }
        }

        private class BleLink(
            val address: String,
            val channel: String
        ) {
            var gatt: android.bluetooth.BluetoothGatt? = null
            var device: android.bluetooth.BluetoothDevice? = null
            /// Whether this link has ever been up. A first attempt that fails
            /// is retried differently from a drop.
            var connectedOnce = false
            val queue = GattQueue()
            /// Callbacks waiting on the operation currently in flight, keyed by
            /// characteristic UUID, so a reply resumes the right caller.
            val reads = HashMap<String, ArrayDeque<(String?, String?) -> Unit>>()
            val writes = HashMap<String, ArrayDeque<(String?, String?) -> Unit>>()
            val notifies = HashMap<String, ArrayDeque<(String?, String?) -> Unit>>()
            var released = false
        }

        private val bleLinks = HashMap<String, BleLink>()
        // Devices as the scanner handed them over. `getRemoteDevice(address)`
        // builds one from a string and assumes a public address type, so a
        // peripheral advertising a random address is unreachable that way —
        // the connection fails with the catch-all status 133 and looks like a
        // peripheral that refused. The scanner's own object carries the type.
        private val bleDiscovered = HashMap<String, android.bluetooth.BluetoothDevice>()
        private var bleScanCallback: android.bluetooth.le.ScanCallback? = null
        private var bleScanChannel: String? = null

        private fun bleAdapter(): android.bluetooth.BluetoothAdapter? {
            val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE)
                as? android.bluetooth.BluetoothManager
            return manager?.adapter
        }

        // BLUETOOTH_SCAN + BLUETOOTH_CONNECT from API 31; before that, scanning
        // was gated on ACCESS_FINE_LOCATION because scan results reveal where
        // you are. Both sets are declared in the manifest (the legacy ones
        // capped at API 30), so what's asked for here depends on the device.
        private fun blePermissions(): Array<String> =
            if (android.os.Build.VERSION.SDK_INT >= 31) {
                arrayOf(
                    android.Manifest.permission.BLUETOOTH_SCAN,
                    android.Manifest.permission.BLUETOOTH_CONNECT
                )
            } else {
                arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
            }

        private fun hasBluetoothPermission(): Boolean = blePermissions().all {
            ContextCompat.checkSelfPermission(activity, it) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }

        // Reuses the launcher the web-permission path already owns rather than
        // growing a second one: only one runtime request can be in flight, and
        // two launchers would silently drop whichever asked first.
        private fun ensureBluetoothPermission(complete: (Boolean) -> Unit) {
            if (hasBluetoothPermission()) { complete(true); return }
            if (pendingOsPermission != null) { complete(false); return }
            pendingOsPermission = { _ -> complete(hasBluetoothPermission()) }
            appActivity.runOnUiThread { webPermLauncher.launch(blePermissions()) }
        }

        private fun bleFailure(kind: String, message: String): String =
            JSONObject().put("ok", false).put("kind", kind).put("message", message).toString()

        private fun bleAvailability(done: (String?, String?) -> Unit) {
            val adapter = bleAdapter()
            val result = JSONObject()
            when {
                adapter == null ->
                    result.put("isAvailable", false).put("reason", "this device has no Bluetooth adapter")
                !adapter.isEnabled ->
                    result.put("isAvailable", false).put("reason", "Bluetooth is switched off")
                else -> result.put("isAvailable", true)
            }
            done(result.toString(), null)
        }

        private fun bleScanStart(json: JSONObject, done: (String?, String?) -> Unit) {
            val channel = json.optString("channel", "")
            if (channel.isEmpty()) {
                done(bleFailure("unavailable", "ble.scan needs a channel"), null)
                return
            }
            ensureBluetoothPermission { granted ->
                if (!granted) {
                    done(bleFailure("denied", "the user or system denied Bluetooth access"), null)
                    return@ensureBluetoothPermission
                }
                val adapter = bleAdapter()
                val scanner = adapter?.bluetoothLeScanner
                if (adapter == null || !adapter.isEnabled || scanner == null) {
                    done(bleFailure("unavailable", "Bluetooth is switched off or unavailable"), null)
                    return@ensureBluetoothPermission
                }
                if (bleScanCallback != null) {
                    done(bleFailure("unavailable", "a scan is already running"), null)
                    return@ensureBluetoothPermission
                }
                val filters = ArrayList<android.bluetooth.le.ScanFilter>()
                val services = json.optJSONArray("services")
                if (services != null) {
                    for (i in 0 until services.length()) {
                        filters.add(
                            android.bluetooth.le.ScanFilter.Builder()
                                .setServiceUuid(android.os.ParcelUuid.fromString(services.optString(i)))
                                .build()
                        )
                    }
                }
                val namePrefix = json.optString("namePrefix", "")
                val settings = android.bluetooth.le.ScanSettings.Builder()
                    .setScanMode(android.bluetooth.le.ScanSettings.SCAN_MODE_LOW_LATENCY)
                    // Every advertisement, not the first per device: RSSI has to
                    // keep updating or a picker can't show a device getting nearer.
                    .setCallbackType(android.bluetooth.le.ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                    .setReportDelay(0)
                    .build()
                val callback = object : android.bluetooth.le.ScanCallback() {
                    override fun onScanResult(callbackType: Int, result: android.bluetooth.le.ScanResult) {
                        val record = result.scanRecord
                        // `scanRecord.deviceName`, not `device.name`: the latter
                        // reads the bonded-device cache and needs
                        // BLUETOOTH_CONNECT on API 31+, throwing SecurityException
                        // during a scan that only asked to scan.
                        val name = record?.deviceName
                        if (namePrefix.isNotEmpty() && (name == null || !name.startsWith(namePrefix))) return
                        val uuids = JSONArray()
                        record?.serviceUuids?.forEach { uuids.put(it.uuid.toString()) }
                        bleDiscovered[result.device.address] = result.device
                        val advertisement = JSONObject()
                            .put("id", result.device.address)
                            .put("rssi", result.rssi)
                            .put("services", uuids)
                            .put("timestamp", System.currentTimeMillis() / 1000.0)
                        if (name != null) advertisement.put("name", name)
                        if (android.os.Build.VERSION.SDK_INT >= 26) {
                            advertisement.put("isConnectable", result.isConnectable)
                        }
                        val manufacturer = record?.manufacturerSpecificData
                        if (manufacturer != null && manufacturer.size() > 0) {
                            // Android splits this per company id; the contract
                            // carries the raw field, so put the id back in front
                            // of the bytes the way it arrives over the air.
                            val id = manufacturer.keyAt(0)
                            val bytes = manufacturer.valueAt(0) ?: ByteArray(0)
                            val combined = ByteArray(bytes.size + 2)
                            combined[0] = (id and 0xFF).toByte()
                            combined[1] = ((id shr 8) and 0xFF).toByte()
                            System.arraycopy(bytes, 0, combined, 2, bytes.size)
                            advertisement.put(
                                "manufacturerDataBase64",
                                android.util.Base64.encodeToString(combined, android.util.Base64.NO_WRAP)
                            )
                        }
                        bridge.nativeHostEvent(
                            JSONObject().put("channel", channel).put("advertisement", advertisement).toString()
                        )
                    }

                    override fun onScanFailed(errorCode: Int) {
                        bridge.nativeHostEvent(
                            JSONObject().put("channel", channel)
                                .put("failed", "the scan could not start (error $errorCode)")
                                .toString()
                        )
                    }
                }
                try {
                    scanner.startScan(filters, settings, callback)
                } catch (e: SecurityException) {
                    done(bleFailure("denied", "Bluetooth permission was revoked: ${e.message}"), null)
                    return@ensureBluetoothPermission
                }
                bleScanCallback = callback
                bleScanChannel = channel
                done(JSONObject().put("ok", true).toString(), null)
            }
        }

        private fun bleScanStop(done: (String?, String?) -> Unit) {
            val callback = bleScanCallback
            bleScanCallback = null
            bleScanChannel = null
            if (callback != null) {
                try {
                    bleAdapter()?.bluetoothLeScanner?.stopScan(callback)
                } catch (e: SecurityException) { /* the radio is already beyond our reach */ }
            }
            done(JSONObject().put("ok", true).toString(), null)
        }

        private fun bleEmit(link: BleLink, payload: JSONObject) {
            bridge.nativeHostEvent(payload.put("channel", link.channel).toString())
        }

        private fun bleConnect(json: JSONObject, done: (String?, String?) -> Unit) {
            val address = json.optString("id", "")
            val channel = json.optString("channel", "")
            if (address.isEmpty() || channel.isEmpty()) {
                done(bleFailure("notFound", "ble.connect needs an id and a channel"), null)
                return
            }
            ensureBluetoothPermission { granted ->
                if (!granted) {
                    done(bleFailure("denied", "the user or system denied Bluetooth access"), null)
                    return@ensureBluetoothPermission
                }
                val adapter = bleAdapter()
                if (adapter == null || !adapter.isEnabled) {
                    done(bleFailure("unavailable", "Bluetooth is switched off or unavailable"), null)
                    return@ensureBluetoothPermission
                }
                val device = bleDiscovered[address] ?: try {
                    adapter.getRemoteDevice(address)
                } catch (e: IllegalArgumentException) {
                    done(bleFailure("notFound", "'$address' isn't a Bluetooth address"), null)
                    return@ensureBluetoothPermission
                }
                bleLinks[address]?.let { bleReleaseLink(it) }
                val link = BleLink(address, channel)
                link.device = device
                bleLinks[address] = link
                val callback = bleGattCallback(link)
                // On the main thread: `connectGatt` from a binder or worker
                // thread is a documented source of status 133, and the RPC that
                // brought us here runs on neither.
                appActivity.runOnUiThread {
                    try {
                        // `autoConnect = false` for the first attempt, which is
                        // much faster; a later `gatt.connect()` after a drop
                        // switches the stack into its own patient retry, which
                        // is what a link that survives a drop needs.
                        link.gatt = device.connectGatt(
                            activity, false, callback, android.bluetooth.BluetoothDevice.TRANSPORT_LE
                        )
                    } catch (e: SecurityException) {
                        bleLinks.remove(address)
                    }
                }
                done(JSONObject().put("ok", true).toString(), null)
            }
        }

        private fun bleGattCallback(link: BleLink) = object : android.bluetooth.BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: android.bluetooth.BluetoothGatt, status: Int, newState: Int) {
                if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                    link.connectedOnce = true
                    bleEmit(link, JSONObject().put("kind", "state").put("connected", true))
                    link.queue.clear()
                    try { gatt.discoverServices() } catch (e: SecurityException) { }
                    return
                }
                if (newState != android.bluetooth.BluetoothProfile.STATE_DISCONNECTED) return
                link.queue.clear()
                bleFailPending(link, "the peripheral disconnected (status $status)")
                if (link.released) return
                // A GATT client that never connected can't be revived with
                // `connect()` — the stack wants the handle closed and a fresh
                // one opened. Status 133 on a first attempt is common enough on
                // Android that not retrying reads as "this peripheral doesn't
                // work", so it gets one clean reopen before falling back to the
                // patient path.
                if (!link.connectedOnce) {
                    try { gatt.close() } catch (e: SecurityException) { }
                    link.gatt = null
                    appActivity.runOnUiThread {
                        try {
                            link.gatt = link.device?.connectGatt(
                                activity, true, this, android.bluetooth.BluetoothDevice.TRANSPORT_LE
                            )
                        } catch (e: SecurityException) { }
                    }
                    return
                }
                bleEmit(
                    link,
                    JSONObject().put("kind", "state").put("connected", false)
                        .put("reason", "reconnecting (status $status)")
                )
                // The link outlives a drop, so ask for it back.
                try { gatt.connect() } catch (e: SecurityException) { }
            }

            override fun onServicesDiscovered(gatt: android.bluetooth.BluetoothGatt, status: Int) {
                val services = JSONArray()
                for (service in gatt.services) {
                    val characteristics = JSONArray()
                    for (characteristic in service.characteristics) {
                        characteristics.put(
                            JSONObject()
                                .put("uuid", characteristic.uuid.toString())
                                .put("properties", bleProperties(characteristic.properties))
                        )
                    }
                    services.put(
                        JSONObject()
                            .put("uuid", service.uuid.toString())
                            .put("isPrimary", service.type == android.bluetooth.BluetoothGattService.SERVICE_TYPE_PRIMARY)
                            .put("characteristics", characteristics)
                    )
                }
                bleEmit(link, JSONObject().put("kind", "ready").put("services", services))
            }

            override fun onCharacteristicRead(
                gatt: android.bluetooth.BluetoothGatt,
                characteristic: android.bluetooth.BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int
            ) {
                bleResume(link.reads, characteristic.uuid.toString(), status) {
                    JSONObject().put("ok", true)
                        .put("valueBase64", android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP))
                }
                link.queue.completed()
            }

            @Suppress("DEPRECATION")
            override fun onCharacteristicRead(
                gatt: android.bluetooth.BluetoothGatt,
                characteristic: android.bluetooth.BluetoothGattCharacteristic,
                status: Int
            ) {
                // The pre-API-33 overload, which hands the value back on the
                // characteristic rather than as an argument. Both exist because
                // min_sdk can be below 33; the platform calls exactly one.
                if (android.os.Build.VERSION.SDK_INT >= 33) return
                val value = characteristic.value ?: ByteArray(0)
                bleResume(link.reads, characteristic.uuid.toString(), status) {
                    JSONObject().put("ok", true)
                        .put("valueBase64", android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP))
                }
                link.queue.completed()
            }

            override fun onCharacteristicWrite(
                gatt: android.bluetooth.BluetoothGatt,
                characteristic: android.bluetooth.BluetoothGattCharacteristic,
                status: Int
            ) {
                bleResume(link.writes, characteristic.uuid.toString(), status) {
                    JSONObject().put("ok", true)
                }
                link.queue.completed()
            }

            override fun onDescriptorWrite(
                gatt: android.bluetooth.BluetoothGatt,
                descriptor: android.bluetooth.BluetoothGattDescriptor,
                status: Int
            ) {
                bleResume(link.notifies, descriptor.characteristic.uuid.toString(), status) {
                    JSONObject().put("ok", true)
                }
                link.queue.completed()
            }

            override fun onCharacteristicChanged(
                gatt: android.bluetooth.BluetoothGatt,
                characteristic: android.bluetooth.BluetoothGattCharacteristic,
                value: ByteArray
            ) {
                bleEmit(
                    link,
                    JSONObject().put("kind", "notify")
                        .put("characteristic", characteristic.uuid.toString())
                        .put("value", android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP))
                )
            }

            @Suppress("DEPRECATION")
            override fun onCharacteristicChanged(
                gatt: android.bluetooth.BluetoothGatt,
                characteristic: android.bluetooth.BluetoothGattCharacteristic
            ) {
                if (android.os.Build.VERSION.SDK_INT >= 33) return
                val value = characteristic.value ?: ByteArray(0)
                bleEmit(
                    link,
                    JSONObject().put("kind", "notify")
                        .put("characteristic", characteristic.uuid.toString())
                        .put("value", android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP))
                )
            }
        }

        private fun bleProperties(mask: Int): JSONArray {
            val names = JSONArray()
            if (mask and android.bluetooth.BluetoothGattCharacteristic.PROPERTY_READ != 0) names.put("read")
            if (mask and android.bluetooth.BluetoothGattCharacteristic.PROPERTY_WRITE != 0) names.put("write")
            if (mask and android.bluetooth.BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
                names.put("writeWithoutResponse")
            }
            if (mask and android.bluetooth.BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) names.put("notify")
            if (mask and android.bluetooth.BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) names.put("indicate")
            return names
        }

        private fun bleResume(
            table: HashMap<String, ArrayDeque<(String?, String?) -> Unit>>,
            uuid: String,
            status: Int,
            success: () -> JSONObject
        ) {
            val waiting = table[uuid.lowercase()] ?: return
            val done = waiting.removeFirstOrNull() ?: return
            if (waiting.isEmpty()) table.remove(uuid.lowercase())
            if (status == android.bluetooth.BluetoothGatt.GATT_SUCCESS) {
                done(success().toString(), null)
            } else {
                done(bleFailure("gatt", "the peripheral refused the operation (status $status)"), null)
            }
        }

        private fun bleFailPending(link: BleLink, message: String) {
            for (table in listOf(link.reads, link.writes, link.notifies)) {
                for ((_, waiting) in table) {
                    while (true) {
                        val done = waiting.removeFirstOrNull() ?: break
                        done(bleFailure("disconnected", message), null)
                    }
                }
                table.clear()
            }
        }

        private fun bleCharacteristic(
            link: BleLink, uuid: String
        ): android.bluetooth.BluetoothGattCharacteristic? {
            val gatt = link.gatt ?: return null
            for (service in gatt.services) {
                for (characteristic in service.characteristics) {
                    if (characteristic.uuid.toString().equals(uuid, ignoreCase = true)) return characteristic
                }
            }
            return null
        }

        private fun bleWrite(json: JSONObject, done: (String?, String?) -> Unit) {
            val link = bleLinks[json.optString("id", "")]
            if (link == null) { done(bleFailure("notFound", "no open link to that peripheral"), null); return }
            val uuid = json.optString("characteristic", "")
            val characteristic = bleCharacteristic(link, uuid)
            if (characteristic == null) {
                done(bleFailure("gatt", "this peripheral has no characteristic $uuid"), null)
                return
            }
            val value = android.util.Base64.decode(json.optString("valueBase64", ""), android.util.Base64.DEFAULT)
            val withResponse = json.optBoolean("withResponse", false)
            val type = if (withResponse) {
                android.bluetooth.BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            } else {
                android.bluetooth.BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            }
            link.writes.getOrPut(uuid.lowercase()) { ArrayDeque() }.addLast(done)
            link.queue.submit {
                val gatt = link.gatt
                if (gatt == null) {
                    bleResume(link.writes, uuid, -1) { JSONObject() }
                    false
                } else {
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= 33) {
                            gatt.writeCharacteristic(characteristic, value, type) ==
                                android.bluetooth.BluetoothStatusCodes.SUCCESS
                        } else {
                            @Suppress("DEPRECATION")
                            run {
                                characteristic.writeType = type
                                characteristic.value = value
                                gatt.writeCharacteristic(characteristic)
                            }
                        }
                    } catch (e: SecurityException) {
                        false
                    }
                }
            }
        }

        private fun bleRead(json: JSONObject, done: (String?, String?) -> Unit) {
            val link = bleLinks[json.optString("id", "")]
            if (link == null) { done(bleFailure("notFound", "no open link to that peripheral"), null); return }
            val uuid = json.optString("characteristic", "")
            val characteristic = bleCharacteristic(link, uuid)
            if (characteristic == null) {
                done(bleFailure("gatt", "this peripheral has no characteristic $uuid"), null)
                return
            }
            link.reads.getOrPut(uuid.lowercase()) { ArrayDeque() }.addLast(done)
            link.queue.submit {
                try { link.gatt?.readCharacteristic(characteristic) ?: false }
                catch (e: SecurityException) { false }
            }
        }

        private fun bleSetNotify(json: JSONObject, done: (String?, String?) -> Unit) {
            val link = bleLinks[json.optString("id", "")]
            if (link == null) { done(bleFailure("notFound", "no open link to that peripheral"), null); return }
            val uuid = json.optString("characteristic", "")
            val characteristic = bleCharacteristic(link, uuid)
            if (characteristic == null) {
                done(bleFailure("gatt", "this peripheral has no characteristic $uuid"), null)
                return
            }
            val enabled = json.optBoolean("enabled", true)
            // The Client Characteristic Configuration descriptor. This is the
            // part that actually reaches the peripheral:
            // `setCharacteristicNotification` only tells the local stack to stop
            // discarding the packets, so on its own it looks like a peripheral
            // that never notifies.
            val cccd = characteristic.getDescriptor(
                java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
            )
            if (cccd == null) {
                done(bleFailure("gatt", "characteristic $uuid can't notify (no CCCD)"), null)
                return
            }
            val indicate = characteristic.properties and
                android.bluetooth.BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
            val value = when {
                !enabled -> android.bluetooth.BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                indicate -> android.bluetooth.BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                else -> android.bluetooth.BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            }
            link.notifies.getOrPut(uuid.lowercase()) { ArrayDeque() }.addLast(done)
            link.queue.submit {
                val gatt = link.gatt ?: return@submit false
                try {
                    gatt.setCharacteristicNotification(characteristic, enabled)
                    if (android.os.Build.VERSION.SDK_INT >= 33) {
                        gatt.writeDescriptor(cccd, value) ==
                            android.bluetooth.BluetoothStatusCodes.SUCCESS
                    } else {
                        @Suppress("DEPRECATION")
                        run {
                            cccd.value = value
                            gatt.writeDescriptor(cccd)
                        }
                    }
                } catch (e: SecurityException) {
                    false
                }
            }
        }

        private fun bleReleaseLink(link: BleLink) {
            link.released = true
            link.queue.clear()
            bleFailPending(link, "the link was closed")
            try {
                link.gatt?.disconnect()
                link.gatt?.close()
            } catch (e: SecurityException) { /* nothing left to release */ }
            link.gatt = null
            bleLinks.remove(link.address)
        }

        private fun bleDisconnect(json: JSONObject, done: (String?, String?) -> Unit) {
            bleLinks[json.optString("id", "")]?.let { bleReleaseLink(it) }
            done(JSONObject().put("ok", true).toString(), null)
        }

        // -----------------------------------------------------------
        // Location (geo.*)
        // -----------------------------------------------------------

        // `LocationManager`, not `FusedLocationProviderClient`: fused lives in
        // Play Services, and adding a Google dependency to every generated
        // project to reach a framework API would be a poor trade — especially
        // on a device without Play Services, where fused simply isn't there.

        private var geoWatchers = HashMap<Int, android.location.LocationListener>()
        private var nextGeoWatchId = 1

        private fun locationManager(): android.location.LocationManager =
            activity.getSystemService(Context.LOCATION_SERVICE)
                as android.location.LocationManager

        private fun hasLocationPermission(): Boolean =
            ContextCompat.checkSelfPermission(
                activity, android.Manifest.permission.ACCESS_COARSE_LOCATION
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(
                    activity, android.Manifest.permission.ACCESS_FINE_LOCATION
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED

        private fun ensureLocationPermission(complete: (Boolean) -> Unit) {
            if (hasLocationPermission()) { complete(true); return }
            if (pendingOsPermission != null) { complete(false); return }
            // Re-check rather than trusting the launcher's all-granted result:
            // for location a coarse-only grant is a real yes, where for capture
            // a half-granted request is not.
            pendingOsPermission = { _ -> complete(hasLocationPermission()) }
            appActivity.runOnUiThread {
                webPermLauncher.launch(arrayOf(
                    android.Manifest.permission.ACCESS_FINE_LOCATION,
                    android.Manifest.permission.ACCESS_COARSE_LOCATION
                ))
            }
        }

        // The provider matching the requested accuracy, or null when nothing
        // usable is enabled — location switched off at the OS level, or a
        // device with no such hardware.
        private fun geoProvider(highAccuracy: Boolean): String? {
            val manager = locationManager()
            val ordered = if (highAccuracy) {
                listOf(
                    android.location.LocationManager.GPS_PROVIDER,
                    android.location.LocationManager.NETWORK_PROVIDER
                )
            } else {
                listOf(
                    android.location.LocationManager.NETWORK_PROVIDER,
                    android.location.LocationManager.GPS_PROVIDER
                )
            }
            return ordered.firstOrNull {
                try { manager.isProviderEnabled(it) } catch (e: Exception) { false }
            }
        }

        private fun geoFixJson(location: android.location.Location): JSONObject {
            val fix = JSONObject()
                .put("latitude", location.latitude)
                .put("longitude", location.longitude)
                .put("accuracy", if (location.hasAccuracy()) location.accuracy.toDouble() else 10000.0)
                .put("timestamp", location.time / 1000.0)
            if (location.hasAltitude()) fix.put("altitude", location.altitude)
            if (location.hasSpeed()) fix.put("speed", location.speed.toDouble())
            if (location.hasBearing()) fix.put("heading", location.bearing.toDouble())
            return fix
        }

        private fun geoFailure(kind: String, message: String): String =
            JSONObject().put("ok", false).put("kind", kind).put("message", message).toString()

        private fun geoCurrent(json: JSONObject, done: (String?, String?) -> Unit) {
            val high = json.optString("accuracy", "balanced") == "high"
            val timeoutMs = (json.optDouble("timeoutSeconds", 20.0) * 1000).toLong()
            val maxAgeSeconds = json.optDouble("maximumAgeSeconds", -1.0)

            ensureLocationPermission { granted ->
                if (!granted) {
                    done(geoFailure("denied", "the user or system denied location access"), null)
                    return@ensureLocationPermission
                }
                val provider = geoProvider(high)
                if (provider == null) {
                    done(geoFailure(
                        "unavailable",
                        "no location provider is enabled — location may be switched off in system settings"
                    ), null)
                    return@ensureLocationPermission
                }
                val manager = locationManager()

                // A cached position, when the caller said one is acceptable.
                // Cheap, instant, and often exactly what a page wants.
                if (maxAgeSeconds > 0) {
                    try {
                        val last = manager.getLastKnownLocation(provider)
                        if (last != null &&
                            (System.currentTimeMillis() - last.time) / 1000.0 <= maxAgeSeconds
                        ) {
                            done(JSONObject().put("ok", true).put("fix", geoFixJson(last)).toString(), null)
                            return@ensureLocationPermission
                        }
                    } catch (e: SecurityException) { /* fall through to a live request */ }
                }

                val settled = java.util.concurrent.atomic.AtomicBoolean(false)
                val handler = android.os.Handler(android.os.Looper.getMainLooper())
                var listener: android.location.LocationListener? = null
                val timeout = Runnable {
                    if (settled.compareAndSet(false, true)) {
                        listener?.let { try { manager.removeUpdates(it) } catch (e: Exception) {} }
                        done(geoFailure("timeout", "no fix within ${timeoutMs}ms"), null)
                    }
                }
                listener = android.location.LocationListener { location ->
                    if (settled.compareAndSet(false, true)) {
                        handler.removeCallbacks(timeout)
                        listener?.let { try { manager.removeUpdates(it) } catch (e: Exception) {} }
                        done(JSONObject().put("ok", true).put("fix", geoFixJson(location)).toString(), null)
                    }
                }
                try {
                    appActivity.runOnUiThread {
                        manager.requestLocationUpdates(
                            provider, 0L, 0f, listener!!, android.os.Looper.getMainLooper()
                        )
                    }
                    handler.postDelayed(timeout, timeoutMs)
                } catch (e: SecurityException) {
                    settled.set(true)
                    done(geoFailure("denied", "location permission was revoked: ${e.message}"), null)
                }
            }
        }

        private fun geoWatchStart(json: JSONObject, done: (String?, String?) -> Unit) {
            val high = json.optString("accuracy", "balanced") == "high"
            val channel = json.optString("channel", "")
            if (channel.isEmpty()) {
                done(geoFailure("unavailable", "geo.watch.start needs a channel"), null)
                return
            }
            ensureLocationPermission { granted ->
                if (!granted) {
                    done(geoFailure("denied", "the user or system denied location access"), null)
                    return@ensureLocationPermission
                }
                val provider = geoProvider(high)
                if (provider == null) {
                    done(geoFailure(
                        "unavailable",
                        "no location provider is enabled — location may be switched off in system settings"
                    ), null)
                    return@ensureLocationPermission
                }
                val id = nextGeoWatchId++
                val listener = android.location.LocationListener { location ->
                    val payload = JSONObject()
                        .put("channel", channel)
                        .put("fix", geoFixJson(location))
                    bridge.nativeHostEvent(payload.toString())
                }
                geoWatchers[id] = listener
                try {
                    appActivity.runOnUiThread {
                        locationManager().requestLocationUpdates(
                            provider, 1000L, 0f, listener, android.os.Looper.getMainLooper()
                        )
                    }
                    done(JSONObject().put("ok", true).put("id", id).toString(), null)
                } catch (e: SecurityException) {
                    geoWatchers.remove(id)
                    done(geoFailure("denied", "location permission was revoked: ${e.message}"), null)
                }
            }
        }

        private fun geoWatchStop(json: JSONObject, done: (String?, String?) -> Unit) {
            val id = json.optInt("id", -1)
            val listener = geoWatchers.remove(id)
            if (listener != null) {
                // On the UI thread and swallowing SecurityException: the
                // permission can be revoked while a watch is live, and failing
                // to *stop* would leave the sensor running.
                appActivity.runOnUiThread {
                    try { locationManager().removeUpdates(listener) } catch (e: Exception) {}
                }
            }
            done(null, null)
        }

        // -----------------------------------------------------------
        // Web permissions (camera / microphone / location)
        // -----------------------------------------------------------

        // Two gates stand between a page's `getUserMedia` and the hardware,
        // and both have to be crossed: the app's own policy (declared +
        // not vetoed, decided in Swift) and Android's runtime permission.
        // The WebView asks for the first via `WebChromeClient`; the second is
        // the app's job, because by the time `onPermissionRequest` fires
        // Android has already established the app doesn't hold it.
        //
        // The policy lives in Swift, so the answer is asynchronous: this
        // pushes a host event and parks the request until `permissions.resolve`
        // comes back. `PermissionRequest.grant` may be called from any thread
        // and at any time, so parking it costs nothing.
        fun requestWebPermission(
            kinds: List<String>,
            origin: String,
            complete: (Boolean) -> Unit
        ) {
            val id = nextWebPermissionId++
            pendingWebPermissions[id] = complete
            val array = JSONArray()
            for (kind in kinds) array.put(kind)
            val payload = JSONObject()
                .put("channel", "permissions.request")
                .put("id", id)
                .put("kinds", array)
                .put("origin", origin)
            bridge.nativeHostEvent(payload.toString())
        }

        // The Swift policy's answer. `allow: false` ends it here — a refusal
        // by the app must not surface an OS dialog, since the user would be
        // answering a question whose outcome is already decided.
        private fun permissionsResolve(json: JSONObject, done: (String?, String?) -> Unit) {
            val id = json.optInt("id", -1)
            val complete = pendingWebPermissions.remove(id)
            if (complete == null) {
                done(null, "swift-pwa: no web permission request with id $id")
                return
            }
            if (!json.optBoolean("allow", false)) {
                appActivity.runOnUiThread { complete(false) }
                done(null, null)
                return
            }

            val needed = ArrayList<String>()
            val kinds = json.optJSONArray("kinds")
            if (kinds != null) {
                for (i in 0 until kinds.length()) {
                    for (perm in osPermissionsFor(kinds.optString(i))) {
                        val held = ContextCompat.checkSelfPermission(activity, perm) ==
                            android.content.pm.PackageManager.PERMISSION_GRANTED
                        if (!held && !needed.contains(perm)) needed.add(perm)
                    }
                }
            }
            if (needed.isEmpty()) {
                appActivity.runOnUiThread { complete(true) }
                done(null, null)
                return
            }
            if (pendingOsPermission != null) {
                // The launcher holds one callback; a second dialog would drop
                // the first. Refuse rather than lose it — the page can retry.
                appActivity.runOnUiThread { complete(false) }
                done(null, null)
                return
            }
            pendingOsPermission = complete
            appActivity.runOnUiThread { webPermLauncher.launch(needed.toTypedArray()) }
            done(null, null)
        }

        // A page-level permission can need more than one Android permission,
        // and location needs both precision levels declared or the coarse-only
        // grant is never offered.
        private fun osPermissionsFor(kind: String): List<String> {
            return when (kind) {
                "microphone" -> listOf(android.Manifest.permission.RECORD_AUDIO)
                "camera" -> listOf(android.Manifest.permission.CAMERA)
                "geolocation" -> listOf(
                    android.Manifest.permission.ACCESS_FINE_LOCATION,
                    android.Manifest.permission.ACCESS_COARSE_LOCATION
                )
                else -> emptyList()
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
            "heic" -> "image/heic"
            "heif" -> "image/heif"
            "avif" -> "image/avif"
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

        // A SAF grant from a picker lasts only as long as the task, so a
        // stored `content://` URI throws on the next launch. Taking a
        // *persistable* grant is what makes it durable, and it has to
        // happen while the picker's transient grant is still alive — hence
        // the runtime asking for this right after a pick, not later.
        private fun dialogTakePersistableUri(json: JSONObject, done: (String?, String?) -> Unit) {
            val uri = Uri.parse(json.optString("uri"))
            val read = Intent.FLAG_GRANT_READ_URI_PERMISSION
            val write = Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            // A tree pick grants read+write; a read-only document pick
            // rejects the write flag outright, and losing the read grant
            // over it would be the wrong trade.
            val persisted = try {
                activity.contentResolver.takePersistableUriPermission(uri, read or write)
                true
            } catch (t: Throwable) {
                try {
                    activity.contentResolver.takePersistableUriPermission(uri, read)
                    true
                } catch (t2: Throwable) {
                    false
                }
            }
            done(JSONObject().put("persisted", persisted).toString(), null)
        }

        // Two separate questions, both of which have to hold for the URI to
        // be worth handing back: do we still have the grant (the user can
        // revoke it from Settings), and is the document still there.
        private fun dialogCheckPersistedUri(json: JSONObject, done: (String?, String?) -> Unit) {
            val raw = json.optString("uri")
            val uri = Uri.parse(raw)
            val granted = activity.contentResolver.persistedUriPermissions.any {
                it.uri.toString() == raw && it.isReadPermission
            }
            if (!granted) {
                done(JSONObject().put("persisted", false).toString(), null)
                return
            }
            val probe = if (DocumentsContract.isTreeUri(uri)) {
                DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            } else {
                uri
            }
            val exists = try {
                activity.contentResolver.query(
                    probe,
                    arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                    null, null, null
                )?.use { it.count > 0 } ?: false
            } catch (t: Throwable) {
                false
            }
            done(JSONObject().put("persisted", exists).toString(), null)
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

        // -----------------------------------------------------------
        // ai.vision.* (MobileSAMBackend) — no CoreGraphics/ImageIO on
        // Android, so image decode + resize (resize-longest-side-to-
        // targetSize, matching ImagePreprocessing.swift's Apple path) runs
        // here via BitmapFactory, and the raw RGB bytes go back to Swift
        // over the RPC bridge. The encoder graph itself does normalization/
        // padding/channel-transpose, so this only decodes + resizes.
        // -----------------------------------------------------------

        private fun visionPreprocessImage(json: JSONObject, done: (String?, String?) -> Unit) {
            val path = json.optString("path", "")
            val dataBase64 = json.optString("dataBase64", "")
            val targetSize = if (json.has("targetSize")) json.getInt("targetSize") else 1024
            if (path.isEmpty() && dataBase64.isEmpty()) {
                done(null, "swift-pwa: vision.preprocessImage: path or dataBase64 required")
                return
            }
            backgroundExecutor.execute {
                try {
                    val bitmap = when {
                        dataBase64.isNotEmpty() -> {
                            val bytes = Base64.decode(dataBase64, Base64.DEFAULT)
                            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        }
                        path.startsWith("content://") -> {
                            activity.contentResolver.openInputStream(Uri.parse(path))?.use {
                                BitmapFactory.decodeStream(it)
                            }
                        }
                        else -> BitmapFactory.decodeFile(path)
                    } ?: run {
                        done(null, "swift-pwa: vision.preprocessImage: could not decode image")
                        return@execute
                    }

                    val originalWidth = bitmap.width
                    val originalHeight = bitmap.height
                    val longSide = maxOf(originalWidth, originalHeight)
                    val scale = targetSize.toDouble() / longSide.toDouble()
                    val resizedWidth = maxOf(1, Math.round(originalWidth * scale).toInt())
                    val resizedHeight = maxOf(1, Math.round(originalHeight * scale).toInt())

                    val scaled = Bitmap.createScaledBitmap(bitmap, resizedWidth, resizedHeight, true)
                    val pixels = IntArray(resizedWidth * resizedHeight)
                    scaled.getPixels(pixels, 0, resizedWidth, 0, 0, resizedWidth, resizedHeight)

                    // ARGB_8888 int -> raw RGB bytes (the encoder graph
                    // wants HWC RGB, not ARGB — alpha is dropped).
                    val rgb = ByteArray(resizedWidth * resizedHeight * 3)
                    for (i in pixels.indices) {
                        val p = pixels[i]
                        rgb[i * 3] = ((p shr 16) and 0xFF).toByte()
                        rgb[i * 3 + 1] = ((p shr 8) and 0xFF).toByte()
                        rgb[i * 3 + 2] = (p and 0xFF).toByte()
                    }
                    val rgbBase64 = Base64.encodeToString(rgb, Base64.NO_WRAP)

                    val result = JSONObject()
                        .put("rgbBase64", rgbBase64)
                        .put("originalWidth", originalWidth)
                        .put("originalHeight", originalHeight)
                        .put("resizedWidth", resizedWidth)
                        .put("resizedHeight", resizedHeight)
                    done(result.toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: vision.preprocessImage failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        // -----------------------------------------------------------
        // ai.generateImage (LaMaBackend, SwiftPWAImageEdit) — no CoreGraphics
        // on Android, so image decode/encode for the inpaint path runs here
        // via BitmapFactory / Bitmap.compress. `image.decode` optionally
        // resizes to an exact (width, height) and returns raw RGB (channels=3)
        // or grayscale (channels=1) bytes; `image.encodePng` turns raw RGB back
        // into a PNG. Mirrors ImageCodec+Android.swift.
        // -----------------------------------------------------------

        private fun imageDecode(json: JSONObject, done: (String?, String?) -> Unit) {
            val path = json.optString("path", "")
            val dataBase64 = json.optString("dataBase64", "")
            val reqW = if (json.has("width")) json.getInt("width") else 0
            val reqH = if (json.has("height")) json.getInt("height") else 0
            val maxSide = if (json.has("maxSide")) json.getInt("maxSide") else 0
            val channels = if (json.has("channels")) json.getInt("channels") else 3
            if (path.isEmpty() && dataBase64.isEmpty()) {
                done(null, "swift-pwa: image.decode: path or dataBase64 required")
                return
            }
            backgroundExecutor.execute {
                try {
                    // Raw source bytes (for content:// too), so we can probe the
                    // bounds first and decode down-sampled — a 24-megapixel phone
                    // photo would OOM if fully materialized as an ARGB_8888 bitmap.
                    val src: ByteArray = when {
                        dataBase64.isNotEmpty() -> Base64.decode(dataBase64, Base64.DEFAULT)
                        path.startsWith("content://") ->
                            activity.contentResolver.openInputStream(Uri.parse(path))?.use { it.readBytes() }
                                ?: ByteArray(0)
                        else -> java.io.File(path).readBytes()
                    }
                    if (src.isEmpty()) {
                        done(null, "swift-pwa: image.decode: could not read image bytes")
                        return@execute
                    }
                    // 1. Probe native dimensions without allocating pixels.
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeByteArray(src, 0, src.size, bounds)
                    val nativeW = bounds.outWidth
                    val nativeH = bounds.outHeight
                    if (nativeW <= 0 || nativeH <= 0) {
                        done(null, "swift-pwa: image.decode: could not decode image")
                        return@execute
                    }
                    // 2. Target dims: explicit (reqW/reqH), else fit-to-maxSide, else native.
                    var w = if (reqW > 0) reqW else nativeW
                    var h = if (reqH > 0) reqH else nativeH
                    if (reqW <= 0 && reqH <= 0 && maxSide > 0 && maxOf(nativeW, nativeH) > maxSide) {
                        val scale = maxSide.toDouble() / maxOf(nativeW, nativeH).toDouble()
                        w = maxOf(1, Math.round(nativeW * scale).toInt())
                        h = maxOf(1, Math.round(nativeH * scale).toInt())
                    }
                    // 3. Down-sample during decode (power-of-two) close to the target,
                    //    then exact-scale — bounds peak memory to ~2× the target.
                    var sample = 1
                    while (nativeW / (sample * 2) >= w && nativeH / (sample * 2) >= h) sample *= 2
                    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
                    val bitmap = BitmapFactory.decodeByteArray(src, 0, src.size, opts) ?: run {
                        done(null, "swift-pwa: image.decode: could not decode image")
                        return@execute
                    }

                    val scaled = if (w != bitmap.width || h != bitmap.height) {
                        Bitmap.createScaledBitmap(bitmap, w, h, true)
                    } else bitmap
                    val pixels = IntArray(w * h)
                    scaled.getPixels(pixels, 0, w, 0, 0, w, h)

                    val out: ByteArray
                    if (channels == 1) {
                        out = ByteArray(w * h)
                        for (i in pixels.indices) {
                            val p = pixels[i]
                            val r = (p shr 16) and 0xFF
                            val g = (p shr 8) and 0xFF
                            val b = p and 0xFF
                            out[i] = ((299 * r + 587 * g + 114 * b) / 1000).toByte() // Rec. 601 luma
                        }
                    } else {
                        out = ByteArray(w * h * 3)
                        for (i in pixels.indices) {
                            val p = pixels[i]
                            out[i * 3] = ((p shr 16) and 0xFF).toByte()
                            out[i * 3 + 1] = ((p shr 8) and 0xFF).toByte()
                            out[i * 3 + 2] = (p and 0xFF).toByte()
                        }
                    }
                    val result = JSONObject()
                        .put("pixelsBase64", Base64.encodeToString(out, Base64.NO_WRAP))
                        .put("width", w)
                        .put("height", h)
                    done(result.toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: image.decode failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        // Which image formats BitmapFactory can decode is an API-level fact, and
        // minSdk here can be as low as 28 — HEIF landed in 28 and AVIF in 31 —
        // so this is derived at runtime rather than assumed. Reported to JS by
        // `image.info`, which a page is meant to consult before relying on a
        // format.
        private fun imageCapabilities(done: (String?, String?) -> Unit) {
            val decode = org.json.JSONArray()
            for (ext in listOf("png", "jpeg", "jpg", "gif", "bmp", "webp")) decode.put(ext)
            if (android.os.Build.VERSION.SDK_INT >= 28) {
                decode.put("heic")
                decode.put("heif")
            }
            if (android.os.Build.VERSION.SDK_INT >= 31) decode.put("avif")
            val encode = org.json.JSONArray()
            for (ext in listOf("png", "jpeg", "jpg")) encode.put(ext)
            done(JSONObject().put("decode", decode).put("encode", encode).toString(), null)
        }

        private fun imageEncode(json: JSONObject, done: (String?, String?) -> Unit) {
            val rgbBase64 = json.optString("rgbBase64", "")
            val w = if (json.has("width")) json.getInt("width") else 0
            val h = if (json.has("height")) json.getInt("height") else 0
            val format = json.optString("format", "png").lowercase()
            // Swift sends 0...1; Bitmap.compress wants 1...100.
            val quality = if (json.has("quality")) {
                Math.max(1, Math.min(100, Math.round(json.getDouble("quality") * 100).toInt()))
            } else 85
            if (rgbBase64.isEmpty() || w <= 0 || h <= 0) {
                done(null, "swift-pwa: image.encode: rgbBase64, width, height required")
                return
            }
            backgroundExecutor.execute {
                try {
                    val rgb = Base64.decode(rgbBase64, Base64.DEFAULT)
                    if (rgb.size != w * h * 3) {
                        done(null, "swift-pwa: image.encode: expected ${w * h * 3} RGB bytes, got ${rgb.size}")
                        return@execute
                    }
                    val pixels = IntArray(w * h)
                    for (i in 0 until w * h) {
                        val r = rgb[i * 3].toInt() and 0xFF
                        val g = rgb[i * 3 + 1].toInt() and 0xFF
                        val b = rgb[i * 3 + 2].toInt() and 0xFF
                        pixels[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                    }
                    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    bmp.setPixels(pixels, 0, w, 0, 0, w, h)
                    val baos = java.io.ByteArrayOutputStream()
                    if (format == "jpeg" || format == "jpg") {
                        bmp.compress(Bitmap.CompressFormat.JPEG, quality, baos)
                    } else {
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, baos)
                    }
                    val result = JSONObject()
                        .put("dataBase64", Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP))
                    done(result.toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: image.encode failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        // -----------------------------------------------------------
        // Network — download a file to a real path over Android's own
        // TLS stack (HttpURLConnection). Swift's URLSession is libcurl +
        // BoringSSL on Android and has no injectable CA trust store, so
        // any HTTPS download from Swift fails with "unable to get local
        // issuer certificate"; downloads route through here instead (the
        // Swift side calls this from a downloadable-model tier, e.g.
        // `ai.vision.ensureModel`). Cache-reuse + checksum-verify + atomic
        // rename mirror Swift's `ModelDownloader`, so the two platforms
        // behave the same. HTTPS trust is the system's — no bundled CA.
        // -----------------------------------------------------------

        private fun netDownloadFile(json: JSONObject, done: (String?, String?) -> Unit) {
            val urlString = json.optString("url", "")
            val destPath = json.optString("destPath", "")
            val sha256 = if (json.has("sha256")) json.getString("sha256").lowercase() else null
            // Optional host-event channel for byte-level progress. Absent/empty
            // ⇒ no progress pushes (plain request/response, backward compatible).
            val channel = json.optString("channel", "")
            if (urlString.isEmpty() || destPath.isEmpty()) {
                done(null, "swift-pwa: net.downloadFile: url and destPath required")
                return
            }
            backgroundExecutor.execute {
                try {
                    val dest = File(destPath)
                    // Cache reuse: an intact file (checksum match, or any
                    // file when unpinned) is returned without a network call.
                    if (dest.exists()) {
                        if (sha256 == null || sha256Hex(dest) == sha256) {
                            done(JSONObject().put("bytesWritten", dest.length()).toString(), null)
                            return@execute
                        }
                        dest.delete() // stale/corrupt — re-fetch
                    }
                    dest.parentFile?.mkdirs()
                    val part = File(destPath + ".part")

                    val conn = URL(urlString).openConnection() as HttpURLConnection
                    conn.instanceFollowRedirects = true // GitHub → objects.githubusercontent.com (https→https)
                    conn.connectTimeout = 30000
                    conn.readTimeout = 60000
                    // Optional request headers (auth, etc.), matching net.request.
                    json.optJSONObject("headers")?.let { hdrs ->
                        val keys = hdrs.keys()
                        while (keys.hasNext()) {
                            val k = keys.next()
                            conn.setRequestProperty(k, hdrs.getString(k))
                        }
                    }
                    try {
                        val code = conn.responseCode
                        if (code !in 200..299) {
                            done(null, "swift-pwa: net.downloadFile: HTTP $code for $urlString")
                            return@execute
                        }
                        // -1 when the server omits Content-Length; forwarded as
                        // null so the Swift side falls back to its pinned size.
                        val total = conn.contentLengthLong
                        val digest = MessageDigest.getInstance("SHA-256")
                        var written = 0L
                        var lastReported = 0L
                        if (channel.isNotEmpty()) pushDownloadEvent(channel, 0L, total)
                        conn.inputStream.use { input ->
                            FileOutputStream(part).use { output ->
                                val buffer = ByteArray(1 shl 16)
                                while (true) {
                                    val n = input.read(buffer)
                                    if (n < 0) break
                                    output.write(buffer, 0, n)
                                    if (sha256 != null) digest.update(buffer, 0, n)
                                    written += n
                                    // Throttle to ~1 MiB so a multi-GB file emits
                                    // a smooth bar without flooding the bridge.
                                    if (channel.isNotEmpty() && written - lastReported >= (1L shl 20)) {
                                        pushDownloadEvent(channel, written, total)
                                        lastReported = written
                                    }
                                }
                            }
                        }
                        if (sha256 != null) {
                            val got = digest.digest().joinToString("") { "%02x".format(it) }
                            if (got != sha256) {
                                part.delete()
                                done(null, "swift-pwa: net.downloadFile: checksum mismatch (expected $sha256, got $got)")
                                return@execute
                            }
                        }
                        dest.delete()
                        if (!part.renameTo(dest)) {
                            part.delete()
                            done(null, "swift-pwa: net.downloadFile: could not move into place")
                            return@execute
                        }
                        done(JSONObject().put("bytesWritten", written).toString(), null)
                    } finally {
                        conn.disconnect()
                    }
                } catch (t: Throwable) {
                    done(null, "swift-pwa: net.downloadFile failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        // A general HTTP request over Android's own stack (system TLS + CA store),
        // for `net.request` and the remote-AI providers — Swift's URLSession has
        // no injectable CA store here, so HTTPS must go through Kotlin. Any status
        // is a result (not an error): the body (success or error stream) rides
        // back base64-encoded alongside the status and response headers; only a
        // transport/IO failure is surfaced as an error.
        private fun netRequest(json: JSONObject, done: (String?, String?) -> Unit) {
            val urlString = json.optString("url", "")
            if (urlString.isEmpty()) {
                done(null, "swift-pwa: net.request: url required")
                return
            }
            val method = json.optString("method", "GET")
            val headers = json.optJSONObject("headers")
            val bodyBase64 = if (json.has("bodyBase64")) json.getString("bodyBase64") else null
            val timeoutMs = if (json.has("timeoutMs")) json.getInt("timeoutMs") else 60000
            backgroundExecutor.execute {
                try {
                    val conn = URL(urlString).openConnection() as HttpURLConnection
                    conn.instanceFollowRedirects = true
                    conn.requestMethod = method
                    conn.connectTimeout = timeoutMs
                    conn.readTimeout = timeoutMs
                    headers?.let { hdrs ->
                        val keys = hdrs.keys()
                        while (keys.hasNext()) {
                            val k = keys.next()
                            conn.setRequestProperty(k, hdrs.getString(k))
                        }
                    }
                    if (bodyBase64 != null) {
                        conn.doOutput = true
                        val bytes = Base64.decode(bodyBase64, Base64.DEFAULT)
                        conn.outputStream.use { it.write(bytes) }
                    }
                    try {
                        val code = conn.responseCode
                        // A non-2xx has its body on errorStream, not inputStream.
                        val stream = if (code in 200..299) conn.inputStream else (conn.errorStream ?: conn.inputStream)
                        val bodyBytes = stream?.use { input ->
                            val buffer = ByteArrayOutputStream()
                            val chunk = ByteArray(1 shl 16)
                            while (true) {
                                val n = input.read(chunk)
                                if (n < 0) break
                                buffer.write(chunk, 0, n)
                            }
                            buffer.toByteArray()
                        } ?: ByteArray(0)
                        val respHeaders = JSONObject()
                        for ((key, value) in conn.headerFields) {
                            if (key != null) respHeaders.put(key, value.joinToString(", "))
                        }
                        val result = JSONObject()
                            .put("status", code)
                            .put("headers", respHeaders)
                            .put("bodyBase64", Base64.encodeToString(bodyBytes, Base64.NO_WRAP))
                        done(result.toString(), null)
                    } finally {
                        conn.disconnect()
                    }
                } catch (t: Throwable) {
                    done(null, "swift-pwa: net.request failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        // -----------------------------------------------------------
        // net.ws.* — receive-only WebSocket over OkHttp.
        //
        // HttpURLConnection (net.request / net.downloadFile) has no WebSocket and
        // java.net.http isn't on Android, so this uses OkHttp. Mirrors the
        // net.downloadFile side-channel pattern: `net.ws.open` starts the socket
        // and returns immediately (OkHttp connects on its own dispatcher), then
        // every inbound frame is pushed to Swift as a host-event on the caller's
        // `channel`; a socket close / failure pushes a terminal `close` / `error`
        // frame. `net.ws.close` tears the socket down when Swift unsubscribes.
        // HTTPS/WSS trust is the system's (OkHttp uses the platform CA store) —
        // same reason downloads route through Kotlin. Used by the remote-AI tier
        // for per-step ComfyUI /ws progress; the Swift side is receive-only, so
        // there's no send path.
        // -----------------------------------------------------------

        private val webSockets = ConcurrentHashMap<String, WebSocket>()
        // No read timeout (a receive-only progress socket is idle while the box
        // computes) + a periodic ping so idle intervals keep the connection live
        // (and NAT/proxy hops don't reap it). ComfyUI runs can pause many seconds
        // between frames during sampling.
        private val wsClient by lazy {
            OkHttpClient.Builder()
                .readTimeout(0, java.util.concurrent.TimeUnit.MILLISECONDS)
                .pingInterval(20, java.util.concurrent.TimeUnit.SECONDS)
                .build()
        }

        private fun netWebSocketOpen(json: JSONObject, done: (String?, String?) -> Unit) {
            val urlString = json.optString("url", "")
            val channel = json.optString("channel", "")
            if (urlString.isEmpty() || channel.isEmpty()) {
                done(null, "swift-pwa: net.ws.open: url and channel required")
                return
            }
            try {
                val builder = Request.Builder().url(urlString)
                json.optJSONObject("headers")?.let { hdrs ->
                    val keys = hdrs.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        builder.addHeader(k, hdrs.getString(k))
                    }
                }
                val listener = object : WebSocketListener() {
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        pushWsEvent(channel, JSONObject().put("type", "text").put("text", text))
                    }

                    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                        pushWsEvent(
                            channel,
                            JSONObject().put("type", "binary")
                                .put("dataBase64", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP))
                        )
                    }

                    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                        webSockets.remove(channel)
                        pushWsEvent(channel, JSONObject().put("type", "close").put("code", code))
                    }

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        webSockets.remove(channel)
                        pushWsEvent(
                            channel,
                            JSONObject().put("type", "error")
                                .put("message", "${t.javaClass.simpleName}: ${t.message}")
                        )
                    }
                }
                val ws = wsClient.newWebSocket(builder.build(), listener)
                webSockets[channel] = ws
                done(JSONObject().put("ok", true).toString(), null)
            } catch (t: Throwable) {
                done(null, "swift-pwa: net.ws.open failed: ${t.javaClass.simpleName}: ${t.message}")
            }
        }

        private fun netWebSocketClose(json: JSONObject, done: (String?, String?) -> Unit) {
            val channel = json.optString("channel", "")
            webSockets.remove(channel)?.close(1000, "client closed")
            done(JSONObject().put("ok", true).toString(), null)
        }

        private fun pushWsEvent(channel: String, payload: JSONObject) {
            payload.put("channel", channel)
            try {
                bridge.nativeHostEvent(payload.toString())
            } catch (t: Throwable) {
                android.util.Log.e("swift-pwa", "failed to push ws event: ${t.message}")
            }
        }

        // MARK: secrets.* — Keystore-backed EncryptedSharedPreferences.
        // The Swift SecretsPlugin (opt-in) drives these over the RPC bridge; the
        // Swift side can't reach the Android Keystore directly. The prefs file
        // is encrypted at rest (AES-256-GCM values, AES-256-SIV keys) with a
        // master key held in the Keystore (hardware-backed where available).
        // Lazily built so an app that never uses secrets pays nothing, and so a
        // Keystore failure surfaces as an E_SECRETS on the first call rather
        // than at activity startup.
        private val secretPrefsLock = Any()
        private var secretPrefsInstance: android.content.SharedPreferences? = null

        private fun secretPrefs(): android.content.SharedPreferences {
            synchronized(secretPrefsLock) {
                secretPrefsInstance?.let { return it }
                val masterKey = MasterKey.Builder(activity.applicationContext)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                val prefs = EncryptedSharedPreferences.create(
                    activity.applicationContext,
                    "swift_pwa_secrets",
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )
                secretPrefsInstance = prefs
                return prefs
            }
        }

        private fun secretsGet(json: JSONObject, done: (String?, String?) -> Unit) {
            val key = json.optString("key", "")
            if (key.isEmpty()) { done(null, "swift-pwa: secrets.get: key required"); return }
            backgroundExecutor.execute {
                try {
                    val value = secretPrefs().getString(key, null)
                    // Absent key -> { value: null } (not an error), matching the
                    // SecretStore contract.
                    val result = JSONObject()
                    if (value != null) result.put("value", value) else result.put("value", JSONObject.NULL)
                    done(result.toString(), null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: secrets.get failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        private fun secretsSet(json: JSONObject, done: (String?, String?) -> Unit) {
            val key = json.optString("key", "")
            if (key.isEmpty()) { done(null, "swift-pwa: secrets.set: key required"); return }
            val value = json.optString("value", "")
            backgroundExecutor.execute {
                try {
                    secretPrefs().edit().putString(key, value).commit()
                    done(null, null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: secrets.set failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        private fun secretsDelete(json: JSONObject, done: (String?, String?) -> Unit) {
            val key = json.optString("key", "")
            if (key.isEmpty()) { done(null, "swift-pwa: secrets.delete: key required"); return }
            backgroundExecutor.execute {
                try {
                    secretPrefs().edit().remove(key).commit()
                    done(null, null)
                } catch (t: Throwable) {
                    done(null, "swift-pwa: secrets.delete failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }
        }

        private fun sha256Hex(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        // Push a byte-level download-progress frame as a host event on
        // `channel`; the Swift AndroidFileDownload forwards it to the model
        // backend's AsyncThrowingStream. Mirrors pushInstallEvent. `totalBytes`
        // is omitted when unknown (server sent no Content-Length).
        private fun pushDownloadEvent(channel: String, bytesDone: Long, totalBytes: Long) {
            val payload = JSONObject().put("channel", channel).put("bytesDone", bytesDone)
            if (totalBytes >= 0) payload.put("totalBytes", totalBytes)
            try {
                bridge.nativeHostEvent(payload.toString())
            } catch (t: Throwable) {
                android.util.Log.e("swift-pwa", "failed to push download event: ${t.message}")
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
