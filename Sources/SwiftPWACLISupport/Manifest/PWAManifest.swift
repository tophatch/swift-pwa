import Foundation

/// On-disk schema for `pwa.json`. The single source of truth; all
/// platform-specific manifests (Info.plist, .desktop, AndroidManifest)
/// are *generated* from this file.
public struct PWAManifest: Codable, Sendable, Equatable {
    public var id: String // reverse-DNS, e.g. "com.example.hello"
    public var name: String // human-readable display name; may contain spaces
    /// Explicit override for the executable / SwiftPM target name the
    /// bundlers look for. **Usually unnecessary** — the bundlers discover
    /// the built executable's name from the package itself (via `swift
    /// package describe`), so a `name` with spaces ("Field Notes") works
    /// even though the SwiftPM target ("FieldNotes") can't contain them.
    ///
    /// Set this only when automatic discovery can't pick a single answer
    /// — chiefly a package that declares **more than one executable
    /// product** (so the bundler can't tell which one is the app). It
    /// must exactly match a SwiftPM target name in `Package.swift` (no
    /// whitespace). When set, it takes precedence over discovery on every
    /// platform (macOS / iOS `.app` + `CFBundleExecutable` + xcodebuild
    /// scheme, Linux AppImage binary, Windows `.exe`, Android
    /// `lib<name>.so`). `linux.executable_name`, when set, still overrides
    /// this for the Linux backend specifically.
    public var executableName: String?
    public var version: String // e.g. "1.0.0"
    public var description: String?
    public var icon: String? // path to a 1024x1024 PNG, optional
    public var web: WebSection
    public var window: WindowSection
    public var macos: MacOSSection?
    public var ios: IOSSection?
    public var linux: LinuxSection?
    public var android: AndroidSection?
    public var updater: UpdaterSection?
    public var build: BuildSection?
    public var ai: AISection?

    /// Last-resort fallback for the executable name: `executableName`
    /// when set, otherwise `name`. The bundlers prefer
    /// `ExecutableNameResolver` (which asks SwiftPM for the real product
    /// name); this is used only when that probe can't run.
    public var binaryName: String {
        executableName ?? name
    }

    public struct WebSection: Codable, Sendable, Equatable {
        public var directory: String // path relative to project root
        public var entry: String // default "index.html"
        public init(directory: String, entry: String = "index.html") {
            self.directory = directory
            self.entry = entry
        }
    }

    public struct WindowSection: Codable, Sendable, Equatable {
        public var title: String
        public var width: Double
        public var height: Double
        public var resizable: Bool
        public var fullscreen: Bool
        /// Native window/webview background colour (hex, e.g. `"#F4F7F5"`),
        /// applied before the page's first paint to avoid a white/black
        /// flash and to match the scroll overscroll area; also used as the
        /// iOS launch-screen background. Optional — omit for the platform
        /// default (opaque white). Seeds `WindowConfig.backgroundColor` in
        /// the generated `App.swift`.
        public var backgroundColor: String?
        public init(
            title: String,
            width: Double = 1024,
            height: Double = 768,
            resizable: Bool = true,
            fullscreen: Bool = false,
            backgroundColor: String? = nil
        ) {
            self.title = title
            self.width = width
            self.height = height
            self.resizable = resizable
            self.fullscreen = fullscreen
            self.backgroundColor = backgroundColor
        }
    }

    public struct MacOSSection: Codable, Sendable, Equatable {
        public var bundleIdentifier: String? // defaults to top-level `id`
        public var category: String? // LSApplicationCategoryType
        public var minimumSystemVersion: String? // e.g. "15.0"
        public var copyright: String? // NSHumanReadableCopyright; shown under the version in the About panel
        /// Arbitrary keys merged verbatim into the generated `Info.plist`,
        /// after swift-pwa's own keys (so they override on collision). The
        /// escape hatch for anything the schema doesn't model — App
        /// Transport Security (`NSAppTransportSecurity`), usage strings
        /// (`NSCameraUsageDescription`), custom URL schemes
        /// (`CFBundleURLTypes`), etc. Use the **exact** Info.plist key
        /// names; nested objects/arrays are supported.
        ///
        /// ```json
        /// "macos": { "info_plist": {
        ///   "NSAppTransportSecurity": { "NSAllowsLocalNetworking": true }
        /// } }
        /// ```
        public var infoPlist: [String: JSONValue]?
    }

    public struct IOSSection: Codable, Sendable, Equatable {
        public var bundleIdentifier: String?
        public var minimumSystemVersion: String? // e.g. "18.0"
        /// `UIDeviceFamily` — which device idioms the app supports
        /// (`1` = iPhone, `2` = iPad). Defaults to `[1, 2]` (universal): a
        /// thin-client WebView app is device-agnostic, and omitting the key
        /// makes iOS treat the app as iPhone-only and letterbox it on iPad.
        /// Override here to ship phone-only (`[1]`) or iPad-only (`[2]`).
        public var deviceFamily: [Int]?
        /// Arbitrary keys merged into the generated iOS `Info.plist`, after
        /// swift-pwa's own (override on collision). See
        /// ``MacOSSection/infoPlist``.
        public var infoPlist: [String: JSONValue]?
    }

    /// On-device AI configuration for the `ai.*` plugin.
    public struct AISection: Codable, Sendable, Equatable {
        /// Bundle the portable on-device **llama.cpp** backend
        /// (`SwiftPWALlama` / `LlamaBackend`) into the build. When `true`,
        /// `swift-pwa build` sets `SWIFT_PWA_LLAMA=1` for the underlying
        /// `swift build` / `xcodebuild`, so SwiftPM pulls in the prebuilt
        /// llama xcframework (`.binaryTarget`, downloaded + checksum-verified
        /// once, cached) and the app can `ctx.use(AIPlugin(LlamaBackend(...)))`.
        ///
        /// Off by default — keeps the ~30MB Apple-only binary out of builds
        /// that don't want it. **Apple (macOS / iOS) only** for now; ignored
        /// (with a warning) for other targets. Apps that only use Apple
        /// Foundation Models don't need this.
        public var localLlama: Bool?

        /// Bundle the **Android Gemini Nano** backend (`SwiftPWAGeminiNano` /
        /// `GeminiNanoBackend`) into the build — the platform built-in
        /// on-device model (via ML Kit GenAI's Prompt API, backed by AICore),
        /// the Android counterpart to Apple Foundation Models. When `true` on
        /// `--target android`, `swift-pwa build` sets `SWIFT_PWA_GEMINI_NANO=1`
        /// for the underlying `swift build` (so SwiftPM pulls in the
        /// `SwiftPWAGeminiNano` target) **and** the generated Gradle scaffold
        /// adds the `com.google.mlkit:genai-prompt` dependency + the Kotlin
        /// dispatch the backend RPCs into. The app then wires
        /// `ctx.use(AIPlugin(GeminiNanoBackend()))`.
        ///
        /// No app-shipped weights — AICore manages the model and downloads it
        /// on demand (surfaced through `ai.ensureModel`). Off by default.
        /// **Android only**; ignored (with a warning) for other targets.
        public var geminiNano: Bool?

        public init(localLlama: Bool? = nil, geminiNano: Bool? = nil) {
            self.localLlama = localLlama
            self.geminiNano = geminiNano
        }
    }

    public struct LinuxSection: Codable, Sendable, Equatable {
        public var desktopCategories: [String]? // e.g. ["Utility"]
        public var executableName: String? // defaults to top-level `id` last component
    }

    /// Android-specific configuration. Defaults are aggressive — the
    /// generated Gradle scaffold targets API 34 (min 26) and includes
    /// only the ABIs the host can build natively. Anything not set
    /// falls back to a sensible value derived from the top-level
    /// fields (package id from `id`, label from `name`, etc.).
    ///
    /// Example:
    /// ```json
    /// "android": {
    ///   "package_id": "com.example.hello",
    ///   "min_sdk": 26,
    ///   "target_sdk": 34,
    ///   "abis": ["arm64-v8a", "x86_64"],
    ///   "version_code": 1
    /// }
    /// ```
    public struct AndroidSection: Codable, Sendable, Equatable {
        /// Java-style package id baked into `applicationId` and the
        /// `package` attribute on the generated `AndroidManifest.xml`.
        /// Defaults to the top-level `id` if it already looks like a
        /// package id (contains a dot); otherwise to
        /// `dev.swiftpwa.<id>`.
        public var packageId: String?
        /// Minimum SDK the generated Gradle scaffold accepts, *and*
        /// the API level the cross-compile triple is built against.
        /// Defaults to 28 (Android 9) — the floor of the Swift
        /// Android SDK 6.2 distribution (the older API 24 floor was
        /// dropped in that release). Values below 28 are clamped
        /// when constructing the cross-compile triple, with a
        /// printed warning, since SwiftPM would otherwise silently
        /// resolve to the wrong-arch resource path.
        public var minSdk: Int?
        /// Target SDK declared in the manifest. Defaults to 34
        /// (Android 14) — the current Play Store minimum.
        public var targetSdk: Int?
        /// ABIs to include in `jniLibs/`. Defaults to
        /// `["arm64-v8a", "x86_64"]`. The CLI errors out if the host
        /// toolchain can't produce a `.so` for any listed ABI; the
        /// caller can drop entries to scope down to whatever they
        /// have.
        public var abis: [String]?
        /// `versionCode` for the manifest. Defaults to 1 if unset;
        /// production apps should bump this with each release. The
        /// human-readable `versionName` comes from the top-level
        /// `version`.
        public var versionCode: Int?
        public init(
            packageId: String? = nil,
            minSdk: Int? = nil,
            targetSdk: Int? = nil,
            abis: [String]? = nil,
            versionCode: Int? = nil,
            signing: AndroidSigningSection? = nil
        ) {
            self.packageId = packageId
            self.minSdk = minSdk
            self.targetSdk = targetSdk
            self.abis = abis
            self.versionCode = versionCode
            self.signing = signing
        }

        /// Release signing configuration. When set, the generated
        /// `app/build.gradle.kts` declares a `signingConfigs.release`
        /// block referencing this keystore + alias and applies it to
        /// the `release` build type. Passwords are *not* stored here
        /// — the generated Gradle script reads them from the
        /// `SWIFT_PWA_ANDROID_STORE_PASSWORD` and
        /// `SWIFT_PWA_ANDROID_KEY_PASSWORD` environment variables and
        /// fails the configure step with a clear error if either is
        /// missing. CI machines set the two env vars before invoking
        /// `./gradlew assembleRelease`; dev machines can do the same
        /// in their shell profile or under an `op run` / `direnv`
        /// wrapper. See `docs/android-setup.md` for the wiring.
        public var signing: AndroidSigningSection?
    }

    /// Release signing configuration referenced by the generated
    /// Gradle scaffold. Holds only the *non-secret* fields: the
    /// keystore path (relative to the project root, or absolute) and
    /// the alias inside it. Passwords are deliberately out of scope —
    /// `pwa.json` is checked in, so anything sensitive here would
    /// leak.
    public struct AndroidSigningSection: Codable, Sendable, Equatable {
        /// Path to the keystore file. Relative paths are resolved
        /// against the project root (the directory containing
        /// `pwa.json`). The bundler bakes the resolved absolute path
        /// into the generated `app/build.gradle.kts` so the Gradle
        /// project — which lives under `build/<name>-android/` and is
        /// regenerated on every `swift-pwa build` — doesn't need to
        /// know where the keystore physically lives.
        public var keystore: String
        /// Alias of the key inside the keystore. Required by
        /// `keytool -genkeypair` and matched verbatim by the generated
        /// `signingConfigs.release.keyAlias = "..."` line.
        public var keyAlias: String
        /// Keystore format. Defaults to `"jks"`. `"pkcs12"` is the
        /// `keytool` default since JDK 9 and is what most modern
        /// pipelines produce; both are accepted by the AGP signing
        /// task.
        public var storeType: String?
        /// Enable v1 (JAR) signature scheme. Defaults to true. Only
        /// relevant for distributions that need to install on devices
        /// older than API 24 (Android 7.0) — every newer Android
        /// release also accepts v2/v3, which the AGP task adds in
        /// parallel by default.
        public var v1SigningEnabled: Bool?
        /// Enable v2 (full APK) signature scheme. Defaults to true.
        /// AGP would set this on automatically; the field exists so
        /// pipelines that disable it for a niche reason (e.g. a third-
        /// party signing tool that re-signs only with v3+) can express
        /// that.
        public var v2SigningEnabled: Bool?

        public init(
            keystore: String,
            keyAlias: String,
            storeType: String? = nil,
            v1SigningEnabled: Bool? = nil,
            v2SigningEnabled: Bool? = nil
        ) {
            self.keystore = keystore
            self.keyAlias = keyAlias
            self.storeType = storeType
            self.v1SigningEnabled = v1SigningEnabled
            self.v2SigningEnabled = v2SigningEnabled
        }
    }

    /// Auto-updater configuration. Optional — apps that don't ship
    /// in-app updates (e.g. App Store / Mac App Store distribution,
    /// Microsoft Store MSIX) leave this section out. The runtime side
    /// (`UpdaterPlugin` + a backend `Updater`) is opt-in regardless;
    /// this section primarily configures the *publishing* side (CLI
    /// manifest signing, planned in v0.4) and documents the runtime's
    /// expected wiring.
    ///
    /// Example:
    /// ```json
    /// "updater": {
    ///   "endpoint": "https://updates.example.com/{{target}}/{{current_version}}",
    ///   "public_key": "RWQf6...",
    ///   "pubkey_algorithm": "ed25519",
    ///   "auto_check": true,
    ///   "check_interval_seconds": 21600,
    ///   "windows": { "install_mode": "passive" },
    ///   "linux":   { "appimage_strategy": "in_place" }
    /// }
    /// ```
    public struct UpdaterSection: Codable, Sendable, Equatable {
        /// HTTPS URL of the JSON manifest endpoint. May contain
        /// `{{target}}` and `{{current_version}}` placeholders.
        public var endpoint: String

        /// Base64 of the raw 32-byte Ed25519 public key. Required for
        /// macOS / Windows / Linux backends; ignored on iOS (where
        /// `itms-services://` validates the .ipa via Apple's signing
        /// chain). Minisign-format key parsing is a planned follow-up.
        public var publicKey: String?

        /// Signature algorithm. Only `"ed25519"` is supported today;
        /// the field exists so the schema can extend without a
        /// breaking change.
        public var pubkeyAlgorithm: String?

        /// Whether the runtime should poll on its own. Defaults to
        /// false — most apps want to drive checks from a menu item or
        /// foregrounding event rather than a timer.
        public var autoCheck: Bool?

        /// Polling cadence when `auto_check` is true.
        public var checkIntervalSeconds: Int?

        public var windows: WindowsUpdater?
        public var linux: LinuxUpdater?

        public struct WindowsUpdater: Codable, Sendable, Equatable {
            /// `"passive"` (no UI, no reboot prompts; default) or
            /// `"silent"` (no UI at all). Reserved for the Windows
            /// updater backend (pending in v0.4).
            public var installMode: String?
        }

        public struct LinuxUpdater: Codable, Sendable, Equatable {
            /// `"in_place"` (atomic-rename onto the running AppImage's
            /// path; default) or `"side_by_side"` (write next to the
            /// running AppImage and let the launcher pick it up next
            /// time). Reserved for the Linux updater backend (pending
            /// in v0.4).
            public var appimageStrategy: String?
        }
    }

    /// Build-lifecycle configuration. Optional — apps with no codegen /
    /// asset step leave it out.
    ///
    /// Example:
    /// ```json
    /// "build": { "prebuild": "node scripts/build-packs-index.mjs" }
    /// ```
    public struct BuildSection: Codable, Sendable, Equatable {
        /// A command run from the project root *before* `web/` is staged
        /// into the bundle, on every `swift-pwa build` (and therefore on
        /// every cloud release that calls it). Use it for the step that
        /// produces part of `web/` — a sprite-atlas packer, an esbuild /
        /// Tailwind pass, a generated index file. A non-zero exit aborts
        /// the build, so a half-baked `web/` never ships.
        ///
        /// It runs through the platform shell (`/bin/sh -c` on macOS /
        /// Linux, `cmd /c` on Windows), so the string can use pipes /
        /// redirection / `&&`. That also means it's host-shell-divergent:
        /// keep it to a portable invocation (`node …`, `npm run build`)
        /// if the same `pwa.json` drives a cross-platform CI matrix.
        /// Skip it for a fast local iteration with `build --skip-prebuild`.
        public var prebuild: String?

        /// A command run from the project root *after* the platform artifact
        /// is produced, on every `swift-pwa build`. Use it for an
        /// "after bundling" step the CLI doesn't do itself — patching the
        /// generated `Info.plist`, extra code-signing, emitting a checksum.
        /// The absolute path to the produced artifact (the `.app` / `.ipa` /
        /// `.AppImage` / Windows bundle dir / Android Gradle project) is
        /// passed in the **`SWIFT_PWA_ARTIFACT`** environment variable, and
        /// `SWIFT_PWA_TARGET` carries the target name. A non-zero exit fails
        /// the build. Same shell semantics as `prebuild`; skip it with
        /// `build --skip-postbuild`.
        public var postbuild: String?

        /// Directories served on the bundle origin under an app-chosen path
        /// prefix (e.g. `/packs`), so page JS can reference runtime-imported
        /// content with an origin-relative URL on every backend. On **desktop**
        /// `ctx.serveDirectory(_:at:)` is the imperative equivalent and is read
        /// at `configure()` time; on **Android** the `WebViewAssetLoader` is
        /// built at Activity-init (before any Swift runs), so mounts that must
        /// exist at startup have to be declared here — the bundler wires each
        /// into the generated Kotlin as an `addPathHandler`. See the
        /// content-packs design doc.
        ///
        /// ```json
        /// "build": { "serve": [ { "mount": "/packs", "from": "data/packs" } ] }
        /// ```
        public var serve: [ServeMount]?

        public init(prebuild: String? = nil, postbuild: String? = nil, serve: [ServeMount]? = nil) {
            self.prebuild = prebuild
            self.postbuild = postbuild
            self.serve = serve
        }
    }

    /// One served-directory declaration (see ``BuildSection/serve``).
    public struct ServeMount: Codable, Sendable, Equatable {
        /// The origin-relative path prefix page JS uses (e.g. `/packs`). Must
        /// not be the bundle root `/`.
        public var mount: String
        /// Source directory, relative to the per-app **data** dir by default
        /// (`data/packs` → `<dataDir>/packs`). A `cache/…` prefix roots it at
        /// the **cache** dir instead. These are the only two roots an Android
        /// app can serve from without a runtime path.
        public var from: String

        public init(mount: String, from: String) {
            self.mount = mount
            self.from = from
        }
    }

    public static func load(from url: URL) throws -> PWAManifest {
        // `Data(contentsOf: fileURL)` is unreliable on swift-corelibs-
        // foundation under Windows: the file URL is routed through a
        // URL-loading path that returns NSCocoaError 260 ("file
        // doesn't exist") even when the file does exist. Read via
        // path string for `file://` URLs to go straight through
        // `CreateFileW` / `fopen` — works identically on every host.
        // (Apple Foundation's `Data(contentsOf:)` is fine, but
        // routing the same way there too keeps the behavior uniform.)
        let data: Data
        if url.isFileURL {
            guard let bytes = FileManager.default.contents(atPath: url.path) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: 260,
                    userInfo: [
                        NSFilePathErrorKey: url.path,
                        NSLocalizedDescriptionKey: "Couldn't read pwa.json at \(url.path)"
                    ]
                )
            }
            data = bytes
        } else {
            data = try Data(contentsOf: url)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PWAManifest.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(self).write(to: url)
    }
}

/// A JSON value of arbitrary shape, used for the `info_plist` passthrough
/// (see ``PWAManifest/MacOSSection/infoPlist``). Codable so it rides along
/// in the manifest; `plistValue` lowers it to the `Any` graph
/// `PropertyListSerialization` accepts.
///
/// Note: `pwa.json` is decoded with `.convertFromSnakeCase`, which is a
/// no-op for keys that contain no underscores — i.e. every conventional
/// CamelCase Info.plist key (`NSAppTransportSecurity`, `CFBundleURLTypes`)
/// passes through unchanged. Avoid underscores in passthrough keys.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            // Bool before Int: JSON `true`/`false` decode as Bool, numbers don't.
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value in pwa.json passthrough"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// The `Any` graph for `PropertyListSerialization`. `.null` has no
    /// plist representation, so a null leaf is dropped by the caller.
    public var plistValue: Any? {
        switch self {
        case let .string(s): s
        case let .bool(b): b
        case let .int(i): i
        case let .double(d): d
        case let .array(a): a.compactMap(\.plistValue)
        case let .object(o): o.reduce(into: [String: Any]()) { acc, kv in
                if let v = kv.value.plistValue { acc[kv.key] = v }
            }
        case .null: nil
        }
    }
}
