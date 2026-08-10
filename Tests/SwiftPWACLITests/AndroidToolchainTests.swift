@testable import SwiftPWACLISupport
import Testing

/// Discovery is pure over injected `Probes`, so every case here runs against a
/// synthetic filesystem — no NDK, SDK, or JDK needs to exist on the test host.
@Suite("Android toolchain discovery")
struct AndroidToolchainTests {
    /// A fake filesystem: a set of directories, a set of executables, and the
    /// JDK homes that carry a `release` file.
    private static func probes(
        dirs: Set<String> = [],
        executables: Set<String> = [],
        releases: [String: String] = [:]
    ) -> AndroidToolchain.Probes {
        AndroidToolchain.Probes(
            isDirectory: { dirs.contains($0) },
            isExecutable: { executables.contains($0) },
            contentsOfDirectory: { parent in
                let prefix = parent.hasSuffix("/") ? parent : parent + "/"
                return Set(dirs.union(executables).compactMap { path -> String? in
                    guard path.hasPrefix(prefix) else { return nil }
                    return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
                }).sorted()
            },
            releaseFile: { releases[$0] }
        )
    }

    // MARK: - SDK

    @Test("takes the SDK from $ANDROID_HOME and reports it as the source")
    func sdkFromEnv() {
        let p = Self.probes(dirs: ["/opt/sdk/platform-tools"])
        let found = AndroidToolchain.sdk(env: ["ANDROID_HOME": "/opt/sdk"], probes: p)
        #expect(found?.path == "/opt/sdk")
        #expect(found?.envVar == "ANDROID_HOME")
        #expect(found?.origin == "$ANDROID_HOME (/opt/sdk)")
    }

    @Test("falls back to the standard macOS location when no env var is set")
    func sdkFromStandardLocation() {
        let p = Self.probes(dirs: ["/Users/x/Library/Android/sdk/platforms"])
        let found = AndroidToolchain.sdk(env: ["HOME": "/Users/x"], probes: p)
        #expect(found?.path == "/Users/x/Library/Android/sdk")
        #expect(found?.envVar == nil)
    }

    @Test("skips an env var pointing at a directory that isn't an SDK")
    func sdkIgnoresBogusEnv() {
        // The classic stale export: ANDROID_HOME survives an SDK move.
        let p = Self.probes(dirs: ["/gone", "/Users/x/Android/Sdk/platform-tools"])
        let found = AndroidToolchain.sdk(env: ["ANDROID_HOME": "/gone", "HOME": "/Users/x"], probes: p)
        #expect(found?.path == "/Users/x/Android/Sdk")
    }

    @Test("reports no SDK when nothing is installed")
    func sdkMissing() {
        #expect(AndroidToolchain.sdk(env: ["HOME": "/Users/x"], probes: Self.probes()) == nil)
    }

    // MARK: - NDK

    @Test("finds the SDK-manager NDK with no ANDROID_NDK_HOME set")
    func ndkUnderSDK() {
        let p = Self.probes(dirs: [
            "/opt/sdk/platform-tools",
            "/opt/sdk/ndk/27.1.12297006/toolchains/llvm/prebuilt"
        ])
        let found = AndroidToolchain.ndk(env: ["ANDROID_HOME": "/opt/sdk"], sdk: "/opt/sdk", probes: p)
        #expect(found?.path == "/opt/sdk/ndk/27.1.12297006")
    }

    @Test("picks the newest SDK-manager NDK numerically, not lexicographically")
    func ndkNewestVersion() {
        let p = Self.probes(dirs: [
            "/opt/sdk/platform-tools",
            "/opt/sdk/ndk/9.0.1/toolchains/llvm/prebuilt",
            "/opt/sdk/ndk/27.1.12297006/toolchains/llvm/prebuilt",
            "/opt/sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt"
        ])
        let found = AndroidToolchain.ndk(env: [:], sdk: "/opt/sdk", probes: p)
        #expect(found?.path == "/opt/sdk/ndk/27.1.12297006")
    }

    @Test("$ANDROID_NDK_HOME wins over an SDK-managed NDK")
    func ndkEnvWins() {
        let p = Self.probes(dirs: [
            "/opt/ndk-r27d/toolchains/llvm/prebuilt",
            "/opt/sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt"
        ])
        let found = AndroidToolchain.ndk(
            env: ["ANDROID_NDK_HOME": "/opt/ndk-r27d"], sdk: "/opt/sdk", probes: p
        )
        #expect(found?.path == "/opt/ndk-r27d")
    }

    @Test("resolves llvm-strip across the prebuilt host flavours")
    func ndkToolLookup() {
        let p = Self.probes(executables: ["/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"])
        #expect(
            AndroidToolchain.ndkTool("llvm-strip", ndk: "/ndk", probes: p)
                == "/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
        )
        #expect(AndroidToolchain.ndkTool("llvm-readelf", ndk: "/ndk", probes: p) == nil)
    }

    @Test("compares dotted versions numerically")
    func versionCompare() {
        #expect(AndroidToolchain.compareVersions("27.1.12297006", "9.0.1") == .orderedDescending)
        #expect(AndroidToolchain.compareVersions("26.3.11579264", "27.0.0") == .orderedAscending)
        #expect(AndroidToolchain.compareVersions("27.1", "27.1.0") == .orderedSame)
    }

    // MARK: - JDK

    @Test("finds Homebrew's keg-only openjdk@17, which java_home can't see")
    func jdkHomebrewKegOnly() {
        // The exact state that broke a real deploy: openjdk@17 installed, but
        // keg-only — not symlinked into /Library/Java/JavaVirtualMachines, not
        // on PATH, no JAVA_HOME.
        let home = "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
        let p = Self.probes(
            dirs: ["/opt/homebrew/opt/openjdk@17"],
            executables: ["\(home)/bin/java"],
            releases: [home: "JAVA_VERSION=\"17.0.19\"\n"]
        )
        #expect(AndroidToolchain.jdk(env: [:], probes: p)?.path == home)
    }

    @Test("prefers JDK 17 over a newer one (the generated project targets 17)")
    func jdkPrefers17() {
        let jdk17 = "/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home"
        let jdk21 = "/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home"
        let p = Self.probes(
            dirs: ["/Library/Java/JavaVirtualMachines/jdk-17.jdk", "/Library/Java/JavaVirtualMachines/jdk-21.jdk"],
            executables: ["\(jdk17)/bin/java", "\(jdk21)/bin/java"],
            releases: [jdk17: "JAVA_VERSION=\"17.0.19\"", jdk21: "JAVA_VERSION=\"21.0.5\""]
        )
        #expect(AndroidToolchain.jdk(env: [:], probes: p)?.path == jdk17)
    }

    @Test("never picks a JDK below 17 — AGP 8.5 can't run on it")
    func jdkRejectsOld() {
        let jdk8 = "/usr/lib/jvm/java-8-openjdk-amd64"
        let p = Self.probes(
            dirs: ["/usr/lib/jvm/java-8-openjdk-amd64"],
            executables: ["\(jdk8)/bin/java"],
            releases: [jdk8: "JAVA_VERSION=\"1.8.0_402\""]
        )
        #expect(AndroidToolchain.jdk(env: [:], probes: p) == nil)
    }

    @Test("falls back to Android Studio's bundled JBR")
    func jdkAndroidStudioJBR() {
        let jbr = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
        let p = Self.probes(
            executables: ["\(jbr)/bin/java"],
            releases: [jbr: "JAVA_VERSION=\"21.0.5\""]
        )
        #expect(AndroidToolchain.jdk(env: [:], probes: p)?.path == jbr)
    }

    @Test("rejects a JAVA_HOME with no release file (the macOS /usr/bin/java stub)")
    func jdkRejectsStubPrefix() {
        // /usr/bin/java exists on every Mac and is executable even with no JDK
        // installed; only the missing `release` file tells them apart.
        let p = Self.probes(executables: ["/usr/bin/java"])
        #expect(AndroidToolchain.isJDK("/usr", probes: p) == false)
    }

    @Test("parses the major version from both release-file shapes")
    func jdkVersionParse() {
        #expect(AndroidToolchain.jdkMajorVersion(fromRelease: "JAVA_VERSION=\"17.0.19\"\nOS_ARCH=\"aarch64\"") == 17)
        #expect(AndroidToolchain.jdkMajorVersion(fromRelease: "JAVA_VERSION=\"1.8.0_402\"") == 8)
        #expect(AndroidToolchain.jdkMajorVersion(fromRelease: "OS_ARCH=\"aarch64\"") == nil)
    }

    @Test("ranks JDKs: 17 best, in-range newest next, above-range last, below-range unusable")
    func jdkRanking() throws {
        let rank = AndroidToolchain.jdkPreferenceRank
        #expect(rank(17) == 0)
        #expect(rank(11) == nil)
        #expect(try #require(rank(21)) < #require(rank(18)))
        #expect(try #require(rank(22)) < #require(rank(23)))
        #expect(try #require(rank(23)) < #require(rank(25)))
        #expect(try #require(rank(nil)) > #require(rank(25)))
    }

    // MARK: - Gradle environment

    @Test("overrides only what the ambient environment lacks")
    func gradleEnvironmentOverrides() {
        let discovered = AndroidToolchain.Found(path: "/jdk17", envVar: nil)
        let envSDK = AndroidToolchain.Found(path: "/opt/sdk", envVar: "ANDROID_HOME")
        let foundSDK = AndroidToolchain.Found(path: "/Users/x/Library/Android/sdk", envVar: nil)

        // Ambient JDK + exported ANDROID_HOME: nothing to override.
        #expect(AndroidToolchain.gradleEnvironment(java: .ambient, sdk: envSDK).isEmpty)

        let overrides = AndroidToolchain.gradleEnvironment(java: .discovered(discovered), sdk: foundSDK)
        #expect(overrides["JAVA_HOME"] == "/jdk17")
        #expect(overrides["ANDROID_HOME"] == "/Users/x/Library/Android/sdk")
        #expect(overrides["ANDROID_SDK_ROOT"] == "/Users/x/Library/Android/sdk")
    }

    // MARK: - local.properties

    @Test("writes sdk.dir — and never ndk.dir, which AGP would CXX1104 about")
    func localPropertiesContent() throws {
        let properties = try #require(AndroidToolchain.localProperties(
            sdk: AndroidToolchain.Found(path: "/opt/sdk", envVar: nil)
        ))
        #expect(properties.contains("sdk.dir=/opt/sdk"))
        // AGP version-matches any ndk.dir against its default android.ndkVersion
        // and warns per module task; the project has no C/C++ sources, so the
        // property is pure noise.
        #expect(!properties.contains("ndk.dir"))
    }

    @Test("emits nothing when no SDK was found")
    func localPropertiesEmpty() {
        #expect(AndroidToolchain.localProperties(sdk: nil) == nil)
    }

    @Test("escapes backslashes so a Windows sdk.dir survives .properties parsing")
    func localPropertiesEscaping() throws {
        let properties = try #require(AndroidToolchain.localProperties(
            sdk: AndroidToolchain.Found(path: #"C:\Users\x\AppData\Local\Android\Sdk"#, envVar: nil)
        ))
        #expect(properties.contains(#"sdk.dir=C:\\Users\\x\\AppData\\Local\\Android\\Sdk"#))
    }
}
