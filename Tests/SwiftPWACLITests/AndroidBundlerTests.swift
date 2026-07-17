import Foundation
@testable import SwiftPWACLISupport
import SwiftPWACore
import Testing

/// Coverage for the bits of the Android bundler that don't actually
/// shell out to a Swift Android SDK / NDK / Gradle: manifest schema
/// round-trip, template rendering, and the signing-config resolver.
/// The full-bundle path is exercised by CI's `assembleDebug` job
/// against `Examples/HelloPWA`; this file pins the unit-level
/// behaviour we'd otherwise only catch on a regression.
@Suite("Android bundler — unit")
struct AndroidBundlerUnitTests {
    // MARK: - Manifest

    @Test("android.signing round-trips through pwa.json")
    func signingRoundTrip() throws {
        let original = PWAManifest(
            id: "com.example.hi",
            name: "Hi",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: "Hi"),
            android: .init(
                packageId: "com.example.hi",
                minSdk: 28,
                targetSdk: 34,
                abis: ["arm64-v8a"],
                versionCode: 1,
                signing: .init(
                    keystore: "release.jks",
                    keyAlias: "upload-key",
                    storeType: "pkcs12"
                )
            )
        )
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pwa-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try original.write(to: tmp)
        let raw = try String(contentsOf: tmp, encoding: .utf8)
        // Snake-case keys should reach disk.
        #expect(raw.contains("\"key_alias\""))
        #expect(raw.contains("\"store_type\""))
        let decoded = try PWAManifest.load(from: tmp)
        #expect(decoded == original)
    }

    // MARK: - Template render

    @Test("AndroidManifest references the launcher mipmap only when an icon is present")
    func manifestIconAttribute() {
        let withIcon = AndroidTemplates.androidManifestXml(packageId: "com.example.hi", label: "Hi", hasIcon: true)
        #expect(withIcon.contains("android:icon=\"@mipmap/ic_launcher\""))

        let withoutIcon = AndroidTemplates.androidManifestXml(packageId: "com.example.hi", label: "Hi", hasIcon: false)
        #expect(!withoutIcon.contains("android:icon"))
    }

    @Test("background_color: manifest theme, WebView fill, and themed status bars only when set")
    func backgroundColor() {
        // Unset → stock AppCompat theme, no WebView fill, no custom theme
        // reference. It must still be a `@style/` resource reference — a bare
        // `Theme.AppCompat.Light.NoActionBar` fails AAPT resource linking with
        // "incompatible with attribute theme (attr) reference" (the v0.7.5
        // regression this guards against).
        let plainManifest = AndroidTemplates.androidManifestXml(
            packageId: "com.example.hi", label: "Hi", hasIcon: false, customTheme: false
        )
        #expect(plainManifest.contains("android:theme=\"@style/Theme.AppCompat.Light.NoActionBar\""))
        #expect(!plainManifest.contains("android:theme=\"@style/Theme.SwiftPWA\""))
        // Guard specifically against the bare (prefix-less) form regressing.
        #expect(!plainManifest.contains("android:theme=\"Theme.AppCompat"))
        let plainActivity = AndroidTemplates.mainActivityKt(packageId: "com.example.hi", soBaseName: "Hi")
        #expect(!plainActivity.contains("setBackgroundColor"))

        // Set → manifest points at the generated theme; WebView surface filled.
        let themedManifest = AndroidTemplates.androidManifestXml(
            packageId: "com.example.hi", label: "Hi", hasIcon: false, customTheme: true
        )
        #expect(themedManifest.contains("android:theme=\"@style/Theme.SwiftPWA\""))
        let themedActivity = AndroidTemplates.mainActivityKt(
            packageId: "com.example.hi", soBaseName: "Hi",
            background: AndroidTemplates.WindowBackground(.single("#F4F7F5"))
        )
        // A single colour paints unconditionally (no night branch).
        #expect(themedActivity.contains(
            "webView.setBackgroundColor(android.graphics.Color.parseColor(\"#F4F7F5\"))"
        ))
        #expect(!themedActivity.contains("UI_MODE_NIGHT_MASK"))
    }

    @Test("light/dark pair drives a night-aware pre-paint background")
    func backgroundColorPair() throws {
        let pair = try #require(AndroidTemplates.WindowBackground(.dayNight(light: "#F4F4F2", dark: "#0C0D0E")))
        let activity = AndroidTemplates.mainActivityKt(packageId: "com.example.hi", soBaseName: "Hi", background: pair)
        // The pre-paint colour branches on the active night mode: dark colour
        // in night mode, light otherwise — so a dark-mode user never gets the
        // light flash.
        #expect(activity.contains("UI_MODE_NIGHT_MASK"))
        #expect(activity.contains("if (swiftPwaNightMode) \"#0C0D0E\" else \"#F4F4F2\""))
    }

    @Test("document_types generate VIEW + SEND intent-filters; absent leaves only LAUNCHER")
    func documentTypeIntentFilters() {
        // No document types → only the MAIN/LAUNCHER filter, no VIEW/SEND.
        let plain = AndroidTemplates.androidManifestXml(
            packageId: "com.example.hi", label: "Hi", hasIcon: false
        )
        #expect(plain.contains("android.intent.action.MAIN"))
        #expect(!plain.contains("android.intent.action.VIEW"))
        #expect(!plain.contains("android.intent.action.SEND"))

        // Declared types → an ACTION_VIEW filter and an ACTION_SEND /
        // SEND_MULTIPLE filter, each with a <data> line per (de-duped) MIME
        // type; the LAUNCHER filter is still present.
        let withTypes = AndroidTemplates.androidManifestXml(
            packageId: "com.example.hi", label: "Hi", hasIcon: false,
            documentTypes: [
                .init(mimeTypes: ["image/png", "image/jpeg"]),
                .init(mimeTypes: ["image/png"]) // dup collapses
            ]
        )
        #expect(withTypes.contains("android.intent.category.LAUNCHER"))
        #expect(withTypes.contains("<action android:name=\"android.intent.action.VIEW\"/>"))
        #expect(withTypes.contains("<action android:name=\"android.intent.action.SEND\"/>"))
        #expect(withTypes.contains("<action android:name=\"android.intent.action.SEND_MULTIPLE\"/>"))
        #expect(withTypes.contains("<data android:mimeType=\"image/png\"/>"))
        #expect(withTypes.contains("<data android:mimeType=\"image/jpeg\"/>"))
        // image/png appears once per filter (deduped) → twice total (VIEW + SEND).
        #expect(withTypes.components(separatedBy: "android:mimeType=\"image/png\"").count - 1 == 2)
    }

    @Test("bridge delivery escapes the payload as a JS string literal, not a template literal")
    func deliveryDoesNotUseTemplateLiteral() {
        // Regression: postToPage used a backtick template literal, so a payload
        // whose text contained `${…}` (e.g. fs.readText of a REST-plugin def
        // with a `${secret}` header template) was interpreted as interpolation
        // → ReferenceError in evaluateJavascript → __deliver never ran → the JS
        // promise hung forever. The fix delivers a double-quoted, JSON-escaped
        // string literal instead (org.json.JSONObject.quote), where `${…}` is
        // inert.
        let bridge = AndroidTemplates.swiftPWABridgeKt()
        // The payload is quoted safely, and __deliver is not fed a template literal.
        #expect(bridge.contains("org.json.JSONObject.quote(json)"))
        #expect(bridge.contains("__SWIFT_PWA__.__deliver($arg)"))
        #expect(!bridge.contains("__SWIFT_PWA__.__deliver(`"))
    }

    @Test("cleartext_domains: scoped network_security_config + manifest reference only when set")
    func cleartextNetworkConfig() throws {
        // Absent → no config, manifest has no networkSecurityConfig attribute
        // and cleartext stays off.
        #expect(AndroidTemplates.networkSecurityConfigXml(domains: []) == nil)
        let plain = AndroidTemplates.androidManifestXml(packageId: "com.example.hi", label: "Hi", hasIcon: false)
        #expect(!plain.contains("networkSecurityConfig"))
        #expect(plain.contains("android:usesCleartextTraffic=\"false\""))

        // Set → base-config keeps cleartext OFF, a scoped domain-config turns it
        // ON only for the listed hosts; "*.local" becomes an includeSubdomains
        // domain, a literal host does not; dups collapse.
        let xml = try #require(AndroidTemplates.networkSecurityConfigXml(
            domains: ["*.local", "192.168.1.50", "192.168.1.50"]
        ))
        #expect(xml.contains("<base-config cleartextTrafficPermitted=\"false\"/>"))
        #expect(xml.contains("<domain-config cleartextTrafficPermitted=\"true\">"))
        #expect(xml.contains("<domain includeSubdomains=\"true\">local</domain>"))
        #expect(xml.contains("<domain includeSubdomains=\"false\">192.168.1.50</domain>"))
        // 192.168.1.50 de-duped to a single entry.
        #expect(xml.components(separatedBy: ">192.168.1.50<").count - 1 == 1)

        // Manifest references it when staged.
        let staged = AndroidTemplates.androidManifestXml(
            packageId: "com.example.hi", label: "Hi", hasIcon: false, networkConfigStaged: true
        )
        #expect(staged.contains("android:networkSecurityConfig=\"@xml/network_security_config\""))
    }

    @Test("net.request is wired into the Android RPC dispatch table")
    func netRequestDispatch() {
        let kt = AndroidTemplates.swiftPWASystemPluginsKt(enableGeminiNano: false)
        #expect(kt.contains("\"net.request\" -> netRequest(json, done)"))
        #expect(kt.contains("private fun netRequest("))
    }

    @Test("secrets.* is wired into the RPC dispatch + EncryptedSharedPreferences store")
    func secretsDispatch() {
        let kt = AndroidTemplates.swiftPWASystemPluginsKt(enableGeminiNano: false)
        #expect(kt.contains("\"secrets.get\" -> secretsGet(json, done)"))
        #expect(kt.contains("\"secrets.set\" -> secretsSet(json, done)"))
        #expect(kt.contains("\"secrets.delete\" -> secretsDelete(json, done)"))
        #expect(kt.contains("EncryptedSharedPreferences.create("))
        #expect(kt.contains("import androidx.security.crypto.MasterKey"))
    }

    @Test("security-crypto is on the Gradle classpath for the secrets store")
    func secretsGradleDep() {
        let gradle = AndroidTemplates.appBuildGradleKts(
            packageId: "com.example.hi",
            versionCode: 1,
            versionName: "1.0.0",
            minSdk: 28,
            targetSdk: 34,
            abis: ["arm64-v8a", "x86_64"],
            soBaseName: "Hi",
            signing: nil
        )
        #expect(gradle.contains("androidx.security:security-crypto"))
    }

    @Test("swiftVersion(fromSDKBundleID:) parses the SDK's Swift major.minor")
    func androidSDKVersionParse() {
        // The cross-compile wraps the inner build in `swiftly run +<ver>` using
        // this — a mismatch is what shipped hollow APKs (no native .so).
        #expect(AndroidBundler.swiftVersion(fromSDKBundleID: "swift-6.2-RELEASE-android-0.1") == "6.2")
        #expect(AndroidBundler.swiftVersion(fromSDKBundleID: "swift-6.0.3-RELEASE-android") == "6.0")
        #expect(AndroidBundler.swiftVersion(fromSDKBundleID: "swift-6.10-RELEASE-android-0.2") == "6.10")
        #expect(AndroidBundler.swiftVersion(fromSDKBundleID: "android-sdk-no-version") == nil)
    }

    @Test("swiftPWAThemeXml is DayNight, fills window + bars, and picks icon luminance per mode")
    func themeXmlLuminance() throws {
        // A near-white surface wants dark (light-bar) status/navigation icons.
        let bg = try #require(AndroidTemplates.WindowBackground(.dayNight(light: "#F4F7F5", dark: "#101418")))
        #expect(bg.light.hex == "#F4F7F5")
        #expect(bg.light.lightSystemBars == true)
        #expect(bg.dark.hex == "#101418")
        #expect(bg.dark.lightSystemBars == false)
        #expect(bg.isPair)

        // The parent must be DayNight (not *.Light.*): a Light parent pins the
        // AppCompat context to light uiMode, so `prefers-color-scheme: dark`
        // never matched inside the WebView.
        let lightXml = AndroidTemplates.swiftPWAThemeXml(bg.light)
        #expect(lightXml.contains("parent=\"Theme.AppCompat.DayNight.NoActionBar\""))
        #expect(!lightXml.contains(".Light.NoActionBar"))
        #expect(lightXml.contains("<color name=\"swift_pwa_window_background\">#F4F7F5</color>"))
        #expect(lightXml.contains("<item name=\"android:windowBackground\">@color/swift_pwa_window_background</item>"))
        #expect(lightXml.contains("<item name=\"android:statusBarColor\">@color/swift_pwa_window_background</item>"))
        #expect(lightXml.contains("<item name=\"android:windowLightStatusBar\">true</item>"))

        // The values-night variant carries the dark colour + light (white) bar icons.
        let darkXml = AndroidTemplates.swiftPWAThemeXml(bg.dark)
        #expect(darkXml.contains("parent=\"Theme.AppCompat.DayNight.NoActionBar\""))
        #expect(darkXml.contains("<color name=\"swift_pwa_window_background\">#101418</color>"))
        #expect(darkXml.contains("<item name=\"android:windowLightStatusBar\">false</item>"))
    }

    @Test("a single-colour background yields identical light/dark modes")
    func themeXmlSingleColour() throws {
        let bg = try #require(AndroidTemplates.WindowBackground(.single("#123456")))
        #expect(bg.light == bg.dark)
        #expect(!bg.isPair)
        #expect(bg.light.hex == "#123456")
    }

    @Test("an unparseable background colour degrades to no theme")
    func themeXmlInvalidColour() {
        #expect(AndroidTemplates.WindowBackground(.single("not-a-hex")) == nil)
        #expect(AndroidTemplates.WindowBackground(.dayNight(light: "#F4F7F5", dark: "nope")) == nil)
    }

    @Test("appBuildGradleKts without signing skips the signingConfigs block")
    func gradleNoSigning() {
        let kts = AndroidTemplates.appBuildGradleKts(
            packageId: "com.example.hi",
            versionCode: 1,
            versionName: "1.0.0",
            minSdk: 28,
            targetSdk: 34,
            abis: ["arm64-v8a", "x86_64"],
            soBaseName: "Hi",
            signing: nil
        )
        #expect(!kts.contains("signingConfigs"))
        #expect(!kts.contains("signingConfig = signingConfigs.getByName"))
        // Sanity: the no-signing variant still emits the surrounding
        // android { } block correctly — closing brace counts must
        // balance with a kts file Gradle accepts.
        #expect(kts.contains("buildTypes {"))
        #expect(kts.contains("release {"))
    }

    @Test("Gemini Nano: Gradle deps + Kotlin dispatch present iff enabled")
    func geminiNanoCodegen() {
        func gradle(_ enable: Bool) -> String {
            AndroidTemplates.appBuildGradleKts(
                packageId: "com.example.hi",
                versionCode: 1,
                versionName: "1.0.0",
                minSdk: 28,
                targetSdk: 34,
                abis: ["arm64-v8a"],
                soBaseName: "Hi",
                signing: nil,
                enableGeminiNano: enable
            )
        }
        // The ML Kit GenAI + coroutines deps appear only when enabled.
        #expect(gradle(true).contains("com.google.mlkit:genai-prompt"))
        #expect(gradle(true).contains("kotlinx-coroutines-android"))
        #expect(!gradle(false).contains("genai-prompt"))
        // The dependency placeholder must never leak into output either way.
        #expect(!gradle(true).contains("__SWIFT_PWA_GENAI"))
        #expect(!gradle(false).contains("__SWIFT_PWA_GENAI"))

        let on = AndroidTemplates.swiftPWASystemPluginsKt(enableGeminiNano: true)
        let off = AndroidTemplates.swiftPWASystemPluginsKt(enableGeminiNano: false)
        // Dispatch cases the Swift GeminiNanoBackend RPCs into.
        for method in ["ai.gemini.info", "ai.gemini.generate", "ai.gemini.generateStream", "ai.gemini.ensureModel"] {
            #expect(on.contains("\"\(method)\""), "missing dispatch for \(method)")
            #expect(!off.contains("\"\(method)\""))
        }
        // Backing impls + the streaming back-channel push.
        #expect(on.contains("com.google.mlkit.genai.prompt.Generation.getClient()"))
        #expect(on.contains("generateContentStream"))
        #expect(on.contains("bridge.nativeHostEvent"))
        // No placeholder comment survives in either rendering.
        #expect(!on.contains("__SWIFT_PWA_GENAI"))
        #expect(!off.contains("__SWIFT_PWA_GENAI"))
        // Off variant references no GenAI symbols at all.
        #expect(!off.contains("mlkit"))
    }

    @Test("appBuildGradleKts emits signingConfigs.release when signing is set")
    func gradleWithSigning() {
        let kts = AndroidTemplates.appBuildGradleKts(
            packageId: "com.example.hi",
            versionCode: 1,
            versionName: "1.0.0",
            minSdk: 28,
            targetSdk: 34,
            abis: ["arm64-v8a"],
            soBaseName: "Hi",
            signing: .init(
                keystoreAbsolutePath: "/secrets/release.jks",
                keyAlias: "upload-key",
                storeType: "pkcs12",
                v1SigningEnabled: true,
                v2SigningEnabled: true
            )
        )
        #expect(kts.contains("signingConfigs {"))
        #expect(kts.contains("create(\"release\")"))
        #expect(kts.contains("storeFile = java.io.File(\"/secrets/release.jks\")"))
        #expect(kts.contains("storeType = \"pkcs12\""))
        #expect(kts.contains("keyAlias = \"upload-key\""))
        // Both env vars referenced — the configure-time gate that
        // makes a missing-secret CI run fail loudly rather than
        // emitting an unsigned APK.
        #expect(kts.contains("SWIFT_PWA_ANDROID_STORE_PASSWORD"))
        #expect(kts.contains("SWIFT_PWA_ANDROID_KEY_PASSWORD"))
        // The release build type pulls in the named config.
        #expect(kts.contains("signingConfig = signingConfigs.getByName(\"release\")"))
        #expect(kts.contains("enableV1Signing = true"))
        #expect(kts.contains("enableV2Signing = true"))
    }

    @Test("Windows-style backslash paths are escaped for Kotlin")
    func gradleWindowsPath() {
        let kts = AndroidTemplates.appBuildGradleKts(
            packageId: "com.example.hi",
            versionCode: 1,
            versionName: "1.0.0",
            minSdk: 28,
            targetSdk: 34,
            abis: ["arm64-v8a"],
            soBaseName: "Hi",
            signing: .init(
                keystoreAbsolutePath: #"C:\Users\me\release.jks"#,
                keyAlias: "upload-key",
                storeType: "jks",
                v1SigningEnabled: true,
                v2SigningEnabled: true
            )
        )
        // Each backslash must be doubled so Kotlin's lexer doesn't
        // interpret `\U` / `\m` / `\r` as escape sequences.
        #expect(kts.contains(#"storeFile = java.io.File("C:\\Users\\me\\release.jks")"#))
    }

    // MARK: - Signing resolver

    @Test("CLI --sign + --android-key-alias overrides empty manifest signing")
    func resolveSigningCLIOnly() throws {
        let manifest = PWAManifest(
            id: "com.example.hi",
            name: "Hi",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "Hi"),
            android: .init(packageId: "com.example.hi")
        )
        let bundler = AndroidBundler(
            manifest: manifest,
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            outputDir: URL(fileURLWithPath: "/tmp/proj/build"),
            abis: ["arm64-v8a"],
            crossCompile: false,
            pruneRuntime: false,
            signKeystoreOverride: "/secrets/release.jks",
            keyAliasOverride: "upload-key"
        )
        let signing = try bundler.resolveSigning()
        #expect(signing?.keystoreAbsolutePath == "/secrets/release.jks")
        #expect(signing?.keyAlias == "upload-key")
        #expect(signing?.storeType == "jks") // default when manifest has no storeType
    }

    @Test("relative pwa.json keystore is resolved against projectRoot")
    func resolveSigningRelativePath() throws {
        let manifest = PWAManifest(
            id: "com.example.hi",
            name: "Hi",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "Hi"),
            android: .init(
                packageId: "com.example.hi",
                signing: .init(keystore: "release.jks", keyAlias: "k")
            )
        )
        let bundler = AndroidBundler(
            manifest: manifest,
            projectRoot: URL(fileURLWithPath: "/Users/me/proj"),
            outputDir: URL(fileURLWithPath: "/Users/me/proj/build"),
            abis: ["arm64-v8a"],
            crossCompile: false,
            pruneRuntime: false,
            signKeystoreOverride: nil,
            keyAliasOverride: nil
        )
        let signing = try bundler.resolveSigning()
        #expect(signing?.keystoreAbsolutePath == "/Users/me/proj/release.jks")
    }

    @Test("missing key alias throws when keystore is configured")
    func resolveSigningMissingAlias() {
        let manifest = PWAManifest(
            id: "com.example.hi",
            name: "Hi",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "Hi"),
            android: .init(packageId: "com.example.hi")
        )
        let bundler = AndroidBundler(
            manifest: manifest,
            projectRoot: URL(fileURLWithPath: "/tmp"),
            outputDir: URL(fileURLWithPath: "/tmp/build"),
            abis: ["arm64-v8a"],
            crossCompile: false,
            pruneRuntime: false,
            signKeystoreOverride: "/secrets/release.jks",
            keyAliasOverride: nil
        )
        #expect(throws: AndroidBundlerError.self) {
            _ = try bundler.resolveSigning()
        }
    }

    @Test("unknown store_type rejected at resolve time")
    func resolveSigningUnknownStoreType() {
        let manifest = PWAManifest(
            id: "com.example.hi",
            name: "Hi",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "Hi"),
            android: .init(
                packageId: "com.example.hi",
                signing: .init(keystore: "release.jks", keyAlias: "k", storeType: "weird-vault")
            )
        )
        let bundler = AndroidBundler(
            manifest: manifest,
            projectRoot: URL(fileURLWithPath: "/tmp"),
            outputDir: URL(fileURLWithPath: "/tmp/build"),
            abis: ["arm64-v8a"],
            crossCompile: false,
            pruneRuntime: false,
            signKeystoreOverride: nil,
            keyAliasOverride: nil
        )
        #expect(throws: AndroidBundlerError.self) {
            _ = try bundler.resolveSigning()
        }
    }

    // MARK: - Kotlin scaffold (BroadcastReceiver wiring)

    @Test("SwiftPWABridge declares the nativeHostEvent JNI symbol")
    func bridgeKtDeclaresHostEvent() {
        let kt = AndroidTemplates.swiftPWABridgeKt()
        // The symbol the BroadcastReceiver path calls and the JNI shim
        // dispatches into `AndroidHostEventRouter`. Pinned here so a
        // rename on either side gets caught before the cross-compile
        // step that links the JNI symbols by name.
        #expect(kt.contains("external fun nativeHostEvent(json: String)"))
    }

    @Test("SwiftPWABridge SPA fallback: off by default, wired when enabled")
    func bridgeKtSpaFallback() {
        // Default (no opt-in): the fallback constant is false and the
        // interception path still delegates to the asset loader.
        let off = AndroidTemplates.swiftPWABridgeKt()
        #expect(off.contains("private val spaFallback = false"))
        #expect(off.contains("assetLoader.shouldInterceptRequest(request.url)"))

        // Opted in with a custom entry: the constant flips and the entry is
        // baked in for the main-frame route re-request.
        let on = AndroidTemplates.swiftPWABridgeKt(spaFallback: true, entry: "app.html")
        #expect(on.contains("private val spaFallback = true"))
        #expect(on.contains("private val spaEntry = \"app.html\""))
        // The fallback only fires for a main-frame route with no matching asset.
        #expect(on.contains("request.isForMainFrame"))
        #expect(on.contains("response?.data == null"))
        #expect(on.contains("https://swift-pwa.local/web/"))
    }

    @Test("SwiftPWASystemPlugins maps PackageInstaller status codes to stable names")
    func systemPluginsMapsStatuses() {
        let kt = AndroidTemplates.swiftPWASystemPluginsKt(enableGeminiNano: false)
        // Each status the Swift side decodes must have a mapping
        // entry; missing entries would fall through to "UNKNOWN_<n>"
        // and the Swift router would surface them as
        // `STATUS_UNKNOWN_<n>` rather than the platform constant name.
        for name in [
            "SUCCESS",
            "FAILURE",
            "FAILURE_ABORTED",
            "FAILURE_BLOCKED",
            "FAILURE_CONFLICT",
            "FAILURE_INCOMPATIBLE",
            "FAILURE_INVALID",
            "FAILURE_STORAGE"
        ] {
            #expect(kt.contains("\"\(name)\""), "missing mapping for STATUS_\(name)")
        }
    }

    @Test("SwiftPWABridge declares a setFullscreen entry point wired to WindowInsetsControllerCompat")
    func bridgeKtDeclaresFullscreen() {
        let kt = AndroidTemplates.swiftPWABridgeKt()
        #expect(kt.contains("fun setFullscreen(on: Boolean)"))
        // The body must reach the modern AndroidX API; the deprecated
        // `View.setSystemUiVisibility` flag set would compile but
        // break edge-to-edge on API 30+.
        #expect(kt.contains("WindowInsetsControllerCompat"))
        #expect(kt.contains("WindowCompat.setDecorFitsSystemWindows"))
        #expect(kt.contains("BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE"))
    }

    @Test("SwiftPWABridge declares spawnWindow + MainActivity reads the secondary intent extra")
    func bridgeKtDeclaresSpawnWindow() {
        let bridge = AndroidTemplates.swiftPWABridgeKt()
        // The Swift `AndroidAppContext.createWindow` JNI-calls this
        // entry on 2nd+ window creations; renaming either side
        // silently breaks multi-window.
        #expect(bridge.contains("fun spawnWindow(configJson: String)"))
        #expect(bridge.contains("swift-pwa.config-json"))
        #expect(bridge.contains("activity.startActivity(intent)"))

        // MainActivity is generated per-package via mainActivityKt;
        // it must recognise the secondary-Activity path via the same
        // extra key and skip spawning the Swift runtime thread (only
        // the primary owns the runtime).
        let activity = AndroidTemplates.mainActivityKt(
            packageId: "com.example.hi",
            soBaseName: "Hi"
        )
        #expect(activity.contains("\"swift-pwa.config-json\""))
        #expect(activity.contains("isSecondary = configJson != null"))
        // The onResume re-attach is what lets the primary's bridge
        // ref reclaim the global slot after the user backs out of a
        // secondary Activity.
        #expect(activity.contains("override fun onResume()"))
        #expect(activity.contains("bridge.attach()"))
    }

    @Test("build.serve mounts become InternalStoragePathHandler entries in MainActivity")
    func mainActivityServeMounts() throws {
        let activity = AndroidTemplates.mainActivityKt(
            packageId: "com.example.hi",
            soBaseName: "Hi",
            serveMounts: [
                .init(mount: "/packs", from: "data/packs"),
                .init(mount: "/thumbs", from: "cache/thumbs"),
                .init(mount: "/lib", from: "library") // bare → filesDir
            ]
        )
        // Bundle handler is present.
        #expect(activity.contains(".addPathHandler(\"/\", WebViewAssetLoader.AssetsPathHandler(this))"))
        // Each declared mount maps to an internal-storage handler under the
        // right root, prefix normalized to end with "/".
        #expect(activity.contains(
            ".addPathHandler(\"/packs/\", WebViewAssetLoader.InternalStoragePathHandler(this, File(filesDir, \"packs\").apply { mkdirs() }))"
        ))
        // Critical: served mounts must register BEFORE the catch-all "/" bundle
        // handler, or "/" shadows them (WebViewAssetLoader matches in order).
        let packsIdx = try #require(activity.range(of: ".addPathHandler(\"/packs/\""))
        let bundleIdx = try #require(activity.range(of: ".addPathHandler(\"/\", WebViewAssetLoader.AssetsPathHandler"))
        #expect(packsIdx.lowerBound < bundleIdx.lowerBound)
        #expect(activity.contains(
            ".addPathHandler(\"/thumbs/\", WebViewAssetLoader.InternalStoragePathHandler(this, File(cacheDir, \"thumbs\").apply { mkdirs() }))"
        ))
        #expect(activity.contains(
            ".addPathHandler(\"/lib/\", WebViewAssetLoader.InternalStoragePathHandler(this, File(filesDir, \"library\").apply { mkdirs() }))"
        ))
        // File import is pulled in for the handler construction.
        #expect(activity.contains("import java.io.File"))
    }

    @Test("no build.serve mounts leaves the asset loader chain unchanged")
    func mainActivityNoServeMounts() {
        let activity = AndroidTemplates.mainActivityKt(packageId: "com.example.hi", soBaseName: "Hi")
        #expect(!activity.contains("InternalStoragePathHandler"))
    }

    @Test("SwiftPWASystemPlugins exposes fs.* content-URI RPC methods")
    func systemPluginsContentURIDispatch() {
        let kt = AndroidTemplates.swiftPWASystemPluginsKt(enableGeminiNano: false)
        // Three dispatch entries the Swift `AndroidContentResolver`
        // calls into. Renaming either side silently breaks SAF I/O.
        #expect(kt.contains("\"fs.readContentUri\" ->"))
        #expect(kt.contains("\"fs.writeContentUri\" ->"))
        #expect(kt.contains("\"fs.contentUriMetadata\" ->"))
        // Underlying calls into ContentResolver — pinning the API
        // surface so a SAF change doesn't go unnoticed.
        #expect(kt.contains("activity.contentResolver.openInputStream"))
        #expect(kt.contains("activity.contentResolver.openOutputStream"))
        #expect(kt.contains("activity.contentResolver.query"))
    }

    @Test("SwiftPWASystemPlugins pushes install events on the 'updater.install' channel")
    func systemPluginsPushesInstallChannel() {
        let kt = AndroidTemplates.swiftPWASystemPluginsKt(enableGeminiNano: false)
        // Channel name pins the contract between the Kotlin
        // BroadcastReceiver and `AndroidUpdater.installEventChannel`
        // on the Swift side. Keep these two in sync.
        #expect(kt.contains("\"channel\""))
        #expect(kt.contains("\"updater.install\""))
        // Receiver actually calls the JNI symbol — covers the path
        // from "broadcast lands" to "event reaches Swift".
        #expect(kt.contains("bridge.nativeHostEvent("))
    }

    @Test("no signing anywhere returns nil (back-compat with v0.5.0 scaffolds)")
    func resolveSigningNone() throws {
        let manifest = PWAManifest(
            id: "com.example.hi",
            name: "Hi",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web"),
            window: .init(title: "Hi"),
            android: .init(packageId: "com.example.hi")
        )
        let bundler = AndroidBundler(
            manifest: manifest,
            projectRoot: URL(fileURLWithPath: "/tmp"),
            outputDir: URL(fileURLWithPath: "/tmp/build"),
            abis: ["arm64-v8a"],
            crossCompile: false,
            pruneRuntime: false,
            signKeystoreOverride: nil,
            keyAliasOverride: nil
        )
        let signing = try bundler.resolveSigning()
        #expect(signing == nil)
    }
}

/// Coverage for the stale-incremental-cross-compile guard: fingerprinting the
/// swift-pwa runtime ABI surface and wiping `.build/<triple>` when it changes.
/// Prevents the value-witness-copy SIGSEGV that a mid-struct layout change
/// (e.g. PR #49's `WindowConfig`) produced from a stale Android build cache.
@Suite("Android bundler — ABI-fingerprint cache guard")
struct AndroidBundlerCacheGuardTests {
    private let triple = "aarch64-unknown-linux-android28"

    /// Build a fake consumer project with a git-checkout-shaped swift-pwa
    /// runtime tree and a populated `.build/<triple>` cache. Returns the project
    /// root and the one source file the tests mutate.
    private func makeProject() throws -> (root: URL, source: URL) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pwa-abi-\(UUID().uuidString)")
        let core = root.appendingPathComponent(".build/checkouts/swift-pwa/Sources/SwiftPWACore")
        try fm.createDirectory(at: core, withIntermediateDirectories: true)
        let source = core.appendingPathComponent("WindowConfig.swift")
        try "public struct WindowConfig { public var title: String }".write(
            to: source, atomically: true, encoding: .utf8
        )
        try fm.createDirectory(
            at: root.appendingPathComponent(".build/\(triple)"), withIntermediateDirectories: true
        )
        return (root, source)
    }

    @Test("fingerprint is stable for unchanged sources and shifts when they change")
    func fingerprintStability() throws {
        let (root, source) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = AndroidBundler.runtimeABIFingerprint(projectRoot: root)
        let b = AndroidBundler.runtimeABIFingerprint(projectRoot: root)
        #expect(a == b) // deterministic across calls (not Swift's randomized hashValue)

        try "public struct WindowConfig { public var origin: Int?; public var title: String }"
            .write(to: source, atomically: true, encoding: .utf8)
        let c = AndroidBundler.runtimeABIFingerprint(projectRoot: root)
        #expect(c != a) // a real content change moves the digest
    }

    @Test("locateSwiftPWASources finds the runtime tree under .build/checkouts")
    func locatesSources() throws {
        let (root, _) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AndroidBundler.locateSwiftPWASources(projectRoot: root)
        #expect(found?.appendingPathComponent("SwiftPWACore").lastPathComponent == "SwiftPWACore")
    }

    @Test("guard wipes a pre-stamp cache, then leaves an unchanged one alone")
    func cleanOnFirstThenNoop() throws {
        let fm = FileManager.default
        let (root, _) = try makeProject()
        defer { try? fm.removeItem(at: root) }
        let tripleDir = root.appendingPathComponent(".build/\(triple)")
        let marker = tripleDir.appendingPathComponent("stale.o")
        try "old".write(to: marker, atomically: true, encoding: .utf8)

        // No stamp yet (a cache predating the guard) → must clean.
        AndroidBundler.cleanStaleCrossCompileCacheIfNeeded(projectRoot: root, triple: triple)
        #expect(!fm.fileExists(atPath: marker.path)) // stale object wiped
        let stamp = tripleDir.appendingPathComponent(".swiftpwa-abi-fingerprint")
        #expect(fm.fileExists(atPath: stamp.path)) // fresh stamp written

        // A new object with the stamp matching current sources → no clean.
        try "new".write(to: marker, atomically: true, encoding: .utf8)
        AndroidBundler.cleanStaleCrossCompileCacheIfNeeded(projectRoot: root, triple: triple)
        #expect(fm.fileExists(atPath: marker.path)) // preserved: incremental stays fast
    }

    @Test("guard re-cleans after the runtime sources change")
    func cleanAfterSourceChange() throws {
        let fm = FileManager.default
        let (root, source) = try makeProject()
        defer { try? fm.removeItem(at: root) }
        let tripleDir = root.appendingPathComponent(".build/\(triple)")

        // Stamp the cache against the current sources.
        AndroidBundler.cleanStaleCrossCompileCacheIfNeeded(projectRoot: root, triple: triple)
        let marker = tripleDir.appendingPathComponent("obj.o")
        try "x".write(to: marker, atomically: true, encoding: .utf8)

        // Change a core type's layout → next guard run must wipe the cache.
        try "public struct WindowConfig { public var origin: Int?; public var title: String }"
            .write(to: source, atomically: true, encoding: .utf8)
        AndroidBundler.cleanStaleCrossCompileCacheIfNeeded(projectRoot: root, triple: triple)
        #expect(!fm.fileExists(atPath: marker.path))
    }
}
