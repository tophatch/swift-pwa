// Copied into the probe app by the thumbnail verification scripts.
import Foundation
import SwiftPWA
#if os(Windows)
    import WinSDK
#endif

struct ProbePathArgs: Decodable { let path: String }
struct ProbeCloudState: Encodable { let state: String }

@MainActor
func registerProbes(_ ctx: any AppContext) {
    ctx.use(DialogPlugin(SystemDialog()))
    ctx.use(FsPlugin(SystemFs()))
    // Whether a cloud file's bytes are here, asked without reading it: the
    // instrument for "a thumbnail never downloads".
    ctx.registry.register("probe.cloudState", typed: { (args: ProbePathArgs, _) -> ProbeCloudState in
        ProbeCloudState(state: cloudState(args.path))
    })
}

func cloudState(_ path: String) -> String {
    #if canImport(Darwin)
        var info = stat()
        guard stat(path, &info) == 0 else { return "missing" }
        // SF_DATALESS: a File Provider item whose contents aren't on disk.
        var state = info.st_flags & 0x4000_0000 != 0 ? "dataless" : "local"
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        switch values?.ubiquitousItemDownloadingStatus {
        case .some(.notDownloaded): state += " notDownloaded"
        case .some(.downloaded): state += " downloaded"
        case .some(.current): state += " current"
        default: break
        }
        return state
    #elseif os(Windows)
        let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        guard attributes != INVALID_FILE_ATTRIBUTES else { return "missing" }
        // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: a cloud placeholder.
        return attributes & 0x0040_0000 != 0 ? "placeholder" : "local"
    #else
        return FileManager.default.fileExists(atPath: path) ? "local" : "missing"
    #endif
}
