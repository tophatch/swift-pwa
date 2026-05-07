import Foundation

/// Optional plugin exposing `fs.*` to JS. Not auto-installed because
/// filesystem access is the plugin most likely to be misused — apps
/// that don't need it shouldn't ship it. Pair with `DialogPlugin` for
/// "user picks a path, JS reads it" flows so the privilege model
/// (the user grants access via the picker) is preserved on hosts
/// without a sandbox.
///
/// ```swift
/// runtime.run { ctx in
///     ctx.use(FsPlugin(SystemFs()))
/// }
/// ```
public struct FsPlugin: Plugin {
    public static let pluginName = "fs"

    private let fs: any Fs

    public init(_ fs: any Fs) {
        self.fs = fs
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let fs = fs

        registry.register(
            "fs.readText",
            typed: { (args: FsPathArgs, _) async throws -> FsTextResult in
                try await FsTextResult(contents: fs.readText(path: args.path))
            }
        )

        registry.register(
            "fs.writeText",
            typed: { (args: FsWriteTextArgs, _) async throws -> EmptyResult in
                try await fs.writeText(path: args.path, contents: args.contents)
                return EmptyResult()
            }
        )

        registry.register(
            "fs.readBinary",
            typed: { (args: FsPathArgs, _) async throws -> FsBinaryResult in
                let data = try await fs.readBinary(path: args.path)
                return FsBinaryResult(dataBase64: data.base64EncodedString())
            }
        )

        registry.register(
            "fs.writeBinary",
            typed: { (args: FsWriteBinaryArgs, _) async throws -> EmptyResult in
                guard let data = Data(base64Encoded: args.dataBase64) else {
                    throw BridgeError(
                        code: BridgeError.decode,
                        message: "fs.writeBinary: dataBase64 is not valid base64"
                    )
                }
                try await fs.writeBinary(path: args.path, data: data)
                return EmptyResult()
            }
        )

        registry.register(
            "fs.exists",
            typed: { (args: FsPathArgs, _) async throws -> FsExistsResult in
                try await FsExistsResult(exists: fs.exists(path: args.path))
            }
        )

        registry.register(
            "fs.mkdir",
            typed: { (args: FsMkdirArgs, _) async throws -> EmptyResult in
                try await fs.mkdir(path: args.path, recursive: args.recursive ?? false)
                return EmptyResult()
            }
        )

        registry.register(
            "fs.remove",
            typed: { (args: FsRemoveArgs, _) async throws -> EmptyResult in
                try await fs.remove(path: args.path, recursive: args.recursive ?? false)
                return EmptyResult()
            }
        )

        registry.register(
            "fs.readDir",
            typed: { (args: FsPathArgs, _) async throws -> FsReadDirResult in
                try await FsReadDirResult(entries: fs.readDir(path: args.path))
            }
        )

        registry.register(
            "fs.copy",
            typed: { (args: FsCopyArgs, _) async throws -> EmptyResult in
                try await fs.copy(from: args.from, to: args.to)
                return EmptyResult()
            }
        )

        registry.register(
            "fs.rename",
            typed: { (args: FsCopyArgs, _) async throws -> EmptyResult in
                try await fs.rename(from: args.from, to: args.to)
                return EmptyResult()
            }
        )

        registry.register(
            "fs.metadata",
            typed: { (args: FsPathArgs, _) async throws -> FsMetadata in
                try await fs.metadata(path: args.path)
            }
        )
    }
}
