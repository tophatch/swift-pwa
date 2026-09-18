import ArgumentParser
import Foundation
@testable import SwiftPWACLISupport
import Testing

/// #219/#220/#238. Two things are covered here, and a third deliberately isn't.
///
/// The **flag spelling** per target, because it is the part that can be wrong
/// without failing loudly: `-L` is not understood by the MSVC linker at all,
/// and a wrong spelling there reads as a bad input file rather than a bad
/// search path.
///
/// The **resolution** of an app's declared `native_library_dirs` and
/// `native_include_dirs` — the `<abi>` substitution that makes a multi-ABI
/// Android build expressible, the refusal to pass on a directory that isn't
/// there, and that the two keys stay separate (a library directory is per-ABI,
/// a header directory usually isn't, so implying one from the other would put
/// the wrong path on the wrong search).
///
/// What isn't here: proof that the environment variable stopped reaching the
/// link step under Swift 6.4. That needs a real toolchain and a real linker,
/// and it was measured instead — on Linux 6.4.0 with a vendored
/// `libonnxruntime.so`, `LIBRARY_PATH` failing and `-Xlinker -L` linking, with
/// 6.2.0 and 6.3.1 passing both as the control.
@Suite("Native library search paths")
struct NativeLibrarySearchTests {
    private func manifest(
        android: [String]? = nil, linux: [String]? = nil, windows: [String]? = nil,
        androidInclude: [String]? = nil, linuxInclude: [String]? = nil,
        windowsInclude: [String]? = nil
    ) -> PWAManifest {
        var m = PWAManifest(
            id: "com.example.app",
            name: "App",
            version: "1.0.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: "App")
        )
        if android != nil || androidInclude != nil {
            m.android = .init(nativeLibraryDirs: android, nativeIncludeDirs: androidInclude)
        }
        if linux != nil || linuxInclude != nil {
            m.linux = decodeLinux(dirs: linux, includeDirs: linuxInclude)
        }
        if windows != nil || windowsInclude != nil {
            m.windows = .init(nativeLibraryDirs: windows, nativeIncludeDirs: windowsInclude)
        }
        return m
    }

    /// `LinuxSection` has no memberwise initializer to call, so build one the
    /// way an app does — through the manifest decoder.
    private func decodeLinux(dirs: [String]?, includeDirs: [String]? = nil) -> PWAManifest.LinuxSection {
        func list(_ entries: [String]) -> String {
            "[" + entries.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        }
        var fields: [String] = []
        if let dirs { fields.append("\"native_library_dirs\": \(list(dirs))") }
        if let includeDirs { fields.append("\"native_include_dirs\": \(list(includeDirs))") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(
            PWAManifest.LinuxSection.self,
            from: Data("{\(fields.joined(separator: ", "))}".utf8)
        )
    }

    private func withDirs(_ relative: [String], _ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("native-lib-\(UUID().uuidString)")
        for rel in relative {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(rel), withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    // MARK: - Flag spelling

    @Test("Linux, macOS and Android take a clang/ld -L search path")
    func posixSpelling() {
        let dirs = [URL(fileURLWithPath: "/opt/vendor/lib")]
        for target in [BuildTarget.linux, .macos, .ios, .android] {
            #expect(
                NativeLibrarySearch.linkerArgs(for: dirs, target: target)
                    == ["-Xlinker", "-L/opt/vendor/lib"]
            )
        }
    }

    @Test("Windows takes /LIBPATH:, which is what link.exe understands")
    func windowsSpelling() {
        let args = NativeLibrarySearch.linkerArgs(
            for: [URL(fileURLWithPath: #"C:\Vendor\lib"#)], target: .windows
        )
        #expect(args.count == 2)
        #expect(args[0] == "-Xlinker")
        #expect(args[1].hasPrefix("/LIBPATH:"))
        #expect(args[1].hasSuffix("Vendor\\lib"))
    }

    @Test("Each directory becomes its own flag pair, in order")
    func onePairPerDirectory() {
        let args = NativeLibrarySearch.linkerArgs(
            for: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")], target: .linux
        )
        #expect(args == ["-Xlinker", "-L/a", "-Xlinker", "-L/b"])
    }

    @Test("No directories, no flags")
    func emptyIsEmpty() {
        #expect(NativeLibrarySearch.linkerArgs(for: [], target: .linux).isEmpty)
    }

    // MARK: - Declared directories

    @Test("<abi> is substituted per ABI, which is what a multi-ABI build needs")
    func abiSubstitution() throws {
        try withDirs(["Vendor/sqlite/arm64-v8a", "Vendor/sqlite/x86_64"]) { root in
            let m = manifest(android: ["Vendor/sqlite/<abi>"])
            let arm = try NativeLibrarySearch.declaredDirs(
                manifest: m, target: .android, projectRoot: root, abi: "arm64-v8a"
            )
            let x86 = try NativeLibrarySearch.declaredDirs(
                manifest: m, target: .android, projectRoot: root, abi: "x86_64"
            )
            #expect(arm.map(\.lastPathComponent) == ["arm64-v8a"])
            #expect(x86.map(\.lastPathComponent) == ["x86_64"])
        }
    }

    @Test("A relative path resolves against the project root")
    func relativeToProjectRoot() throws {
        try withDirs(["Vendor/sqlite"]) { root in
            let dirs = try NativeLibrarySearch.declaredDirs(
                manifest: manifest(linux: ["Vendor/sqlite"]), target: .linux, projectRoot: root
            )
            #expect(dirs.count == 1)
            #expect(dirs[0].path == root.appendingPathComponent("Vendor/sqlite").path)
        }
    }

    @Test("A directory that isn't there fails the build, naming the entry")
    func missingDirectoryThrows() throws {
        try withDirs([]) { root in
            #expect(throws: ValidationError.self) {
                try NativeLibrarySearch.declaredDirs(
                    manifest: manifest(linux: ["Vendor/nope"]), target: .linux, projectRoot: root
                )
            }
        }
    }

    @Test("A file where a directory was named is not accepted")
    func fileIsNotADirectory() throws {
        try withDirs([]) { root in
            try Data("x".utf8).write(to: root.appendingPathComponent("libfoo.so"))
            #expect(throws: ValidationError.self) {
                try NativeLibrarySearch.declaredDirs(
                    manifest: manifest(linux: ["libfoo.so"]), target: .linux, projectRoot: root
                )
            }
        }
    }

    @Test("<abi> off Android is a build error, not a directory literally named <abi>")
    func abiPlaceholderOffAndroid() throws {
        try withDirs(["Vendor/sqlite"]) { root in
            #expect(throws: ValidationError.self) {
                try NativeLibrarySearch.declaredDirs(
                    manifest: manifest(linux: ["Vendor/sqlite/<abi>"]), target: .linux, projectRoot: root
                )
            }
        }
    }

    @Test("A target the app declared nothing for contributes nothing")
    func undeclaredIsEmpty() throws {
        try withDirs(["Vendor/sqlite"]) { root in
            let otherTarget = try NativeLibrarySearch.declaredDirs(
                manifest: manifest(linux: ["Vendor/sqlite"]), target: .windows, projectRoot: root
            )
            #expect(otherTarget.isEmpty)
            let nothingDeclared = try NativeLibrarySearch.declaredDirs(
                manifest: manifest(), target: .linux, projectRoot: root
            )
            #expect(nothingDeclared.isEmpty)
        }
    }

    // MARK: - Host builds (dev / drive / the headless catalog dump)

    @Test("A tier swift-pwa resolved reaches a host build's link step")
    func hostArgsCarryTierDirs() throws {
        try withDirs([]) { root in
            let args = try NativeLibrarySearch.hostLinkerArgs(
                manifest: manifest(), projectRoot: root, extra: [URL(fileURLWithPath: "/opt/onnx")]
            )
            #expect(args.count == 2)
            #expect(args[1].contains("/opt/onnx"))
        }
    }

    @Test("Nothing declared and no tier means no flags, on any host")
    func hostArgsEmptyByDefault() throws {
        try withDirs([]) { root in
            let args = try NativeLibrarySearch.hostLinkerArgs(manifest: manifest(), projectRoot: root)
            #expect(args.isEmpty)
            let env = try NativeLibrarySearch.hostRuntimeEnvironment(manifest: manifest(), projectRoot: root)
            #expect(env.isEmpty)
        }
    }

    // MARK: - What gets staged

    @Test("Shared libraries are staged, including SONAME'd spellings; archives aren't")
    func stageableLibraries() throws {
        try withDirs(["lib"]) { root in
            let dir = root.appendingPathComponent("lib")
            for name in [
                "libsqlite3.so", "libsqlite3.so.0", "libsqlite3.a", "sqlite3.dll",
                "notes.source", "README.md"
            ] {
                try Data("x".utf8).write(to: dir.appendingPathComponent(name))
            }
            let linux = NativeLibrarySearch.stageableLibraries(in: dir, target: .linux)
                .map(\.lastPathComponent)
            #expect(linux == ["libsqlite3.so", "libsqlite3.so.0"])

            let windows = NativeLibrarySearch.stageableLibraries(in: dir, target: .windows)
                .map(\.lastPathComponent)
            #expect(windows == ["sqlite3.dll"])
        }
    }

    @Test("A directory with nothing loadable in it stages nothing, quietly")
    func nothingToStage() throws {
        try withDirs(["lib"]) { root in
            let dir = root.appendingPathComponent("lib")
            try Data("x".utf8).write(to: dir.appendingPathComponent("libsqlite3.a"))
            #expect(NativeLibrarySearch.stageableLibraries(in: dir, target: .android).isEmpty)
        }
    }

    // MARK: - Manifest decoding

    @Test("pwa.json's snake_case key reaches all three sections")
    func decodesFromManifest() throws {
        let json = """
        {
          "id": "com.example.app", "name": "App", "version": "1.0.0",
          "web": { "directory": "web", "entry": "index.html" },
          "window": {
            "title": "App", "width": 800, "height": 600,
            "resizable": true, "fullscreen": false
          },
          "android": {
            "native_library_dirs": ["Vendor/sqlite/<abi>"],
            "native_include_dirs": ["Vendor/sqlite/include"]
          },
          "linux": {
            "native_library_dirs": ["Vendor/sqlite/linux"],
            "native_include_dirs": ["Vendor/sqlite/include"]
          },
          "windows": {
            "native_library_dirs": ["Vendor/sqlite/win"],
            "native_include_dirs": ["Vendor/sqlite/include"]
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let m = try decoder.decode(PWAManifest.self, from: Data(json.utf8))
        #expect(m.android?.nativeLibraryDirs == ["Vendor/sqlite/<abi>"])
        #expect(m.linux?.nativeLibraryDirs == ["Vendor/sqlite/linux"])
        #expect(m.windows?.nativeLibraryDirs == ["Vendor/sqlite/win"])
        #expect(m.android?.nativeIncludeDirs == ["Vendor/sqlite/include"])
        #expect(m.linux?.nativeIncludeDirs == ["Vendor/sqlite/include"])
        #expect(m.windows?.nativeIncludeDirs == ["Vendor/sqlite/include"])
    }

    // MARK: - Header search paths (#238)

    @Test("Every target takes -Xcc -I, one pair per directory, in order")
    func includeSpelling() {
        let args = NativeLibrarySearch.compilerArgs(
            for: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        )
        #expect(args == ["-Xcc", "-I/a", "-Xcc", "-I/b"])
        #expect(NativeLibrarySearch.compilerArgs(for: []).isEmpty)
    }

    @Test("The two keys are separate: neither implies the other")
    func keysDoNotImplyEachOther() throws {
        try withDirs(["Vendor/sqlite/arm64-v8a", "Vendor/sqlite/include"]) { root in
            let m = manifest(
                android: ["Vendor/sqlite/<abi>"], androidInclude: ["Vendor/sqlite/include"]
            )
            let libs = try NativeLibrarySearch.declaredDirs(
                manifest: m, target: .android, projectRoot: root, abi: "arm64-v8a"
            )
            let headers = try NativeLibrarySearch.declaredDirs(
                manifest: m, target: .android, projectRoot: root, abi: "arm64-v8a", kind: .include
            )
            #expect(libs.map(\.lastPathComponent) == ["arm64-v8a"])
            #expect(headers.map(\.lastPathComponent) == ["include"])

            // Declaring only libraries puts nothing on the header path — which
            // is the point of the split: an arm64 lib directory holds no
            // headers, so implying one from the other would widen the include
            // search for nothing.
            let libsOnly = manifest(android: ["Vendor/sqlite/<abi>"])
            #expect(try NativeLibrarySearch.declaredDirs(
                manifest: libsOnly, target: .android, projectRoot: root,
                abi: "arm64-v8a", kind: .include
            ).isEmpty)
        }
    }

    @Test("<abi> is substituted for headers too, so the keys behave alike")
    func includeAbiSubstitution() throws {
        try withDirs(["Vendor/sqlite/arm64-v8a/include"]) { root in
            let m = manifest(androidInclude: ["Vendor/sqlite/<abi>/include"])
            let dirs = try NativeLibrarySearch.declaredDirs(
                manifest: m, target: .android, projectRoot: root, abi: "arm64-v8a", kind: .include
            )
            #expect(dirs.first?.path.hasSuffix("Vendor/sqlite/arm64-v8a/include") == true)
        }
    }

    @Test("A missing header directory names native_include_dirs, not its sibling")
    func missingIncludeDirectoryNamesItsOwnKey() throws {
        try withDirs([]) { root in
            let m = manifest(linuxInclude: ["Vendor/sqlite/include"])
            #expect(throws: ValidationError.self) {
                try NativeLibrarySearch.declaredDirs(
                    manifest: m, target: .linux, projectRoot: root, kind: .include
                )
            }
            do {
                _ = try NativeLibrarySearch.declaredDirs(
                    manifest: m, target: .linux, projectRoot: root, kind: .include
                )
            } catch {
                #expect("\(error)".contains("linux.native_include_dirs"))
            }
        }
    }

    @Test("A host build gets the app's declared headers where the platform offers them")
    func hostIncludeArgs() throws {
        try withDirs(["Vendor/sqlite/include"]) { root in
            let m = manifest(
                linuxInclude: ["Vendor/sqlite/include"], windowsInclude: ["Vendor/sqlite/include"]
            )
            let args = try NativeLibrarySearch.hostCompilerArgs(manifest: m, projectRoot: root)
            #if os(Linux) || os(Windows)
                let expected = root.appendingPathComponent("Vendor/sqlite/include").path
                #expect(args == ["-Xcc", "-I" + expected])
            #else
                // Apple doesn't offer the key — a `.binaryTarget` xcframework
                // carries its own headers — so there is nothing to add.
                #expect(args.isEmpty)
            #endif
            #expect(try NativeLibrarySearch.hostCompilerArgs(
                manifest: manifest(), projectRoot: root
            ).isEmpty)
        }
    }
}
