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
