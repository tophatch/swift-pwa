import Foundation
@testable import SwiftPWACLISupport
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
        let kt = AndroidTemplates.swiftPWABridgeKt
        // The symbol the BroadcastReceiver path calls and the JNI shim
        // dispatches into `AndroidHostEventRouter`. Pinned here so a
        // rename on either side gets caught before the cross-compile
        // step that links the JNI symbols by name.
        #expect(kt.contains("external fun nativeHostEvent(json: String)"))
    }

    @Test("SwiftPWASystemPlugins maps PackageInstaller status codes to stable names")
    func systemPluginsMapsStatuses() {
        let kt = AndroidTemplates.swiftPWASystemPluginsKt
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
        let kt = AndroidTemplates.swiftPWABridgeKt
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
        let bridge = AndroidTemplates.swiftPWABridgeKt
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

    @Test("SwiftPWASystemPlugins exposes fs.* content-URI RPC methods")
    func systemPluginsContentURIDispatch() {
        let kt = AndroidTemplates.swiftPWASystemPluginsKt
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
        let kt = AndroidTemplates.swiftPWASystemPluginsKt
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
