import Foundation
@testable import SwiftPWACore
import Testing

@Suite("UpdateManifest")
struct UpdateManifestTests {
    @Test("decodes the documented Tauri-compatible shape")
    func decode() throws {
        let json = """
        {
          "version": "0.4.0",
          "pub_date": "2026-05-12T10:00:00Z",
          "notes": "Bug fixes.",
          "platforms": {
            "darwin-aarch64": {
              "url": "https://updates.example.com/0.4.0/darwin-aarch64.app.tar.gz",
              "signature": "AAAA"
            },
            "windows-x86_64-msix": {
              "url": "https://updates.example.com/0.4.0/x64.msix",
              "signature": "BBBB"
            }
          }
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.version == "0.4.0")
        #expect(manifest.pubDate == "2026-05-12T10:00:00Z")
        #expect(manifest.platforms["darwin-aarch64"]?.signature == "AAAA")
        #expect(manifest.platforms["windows-x86_64-msix"]?.url
            == URL(string: "https://updates.example.com/0.4.0/x64.msix"))
    }

    @Test("updateInfo(for:currentVersion:) returns nil for unknown targets")
    func unknownTarget() throws {
        let manifest = try UpdateManifest(
            version: "1.0.0",
            platforms: ["darwin-aarch64": .init(url: #require(URL(string: "https://x")), signature: "")]
        )
        #expect(manifest.updateInfo(for: "linux-x86_64-appimage", currentVersion: "0.9.0") == nil)
    }

    @Test("updateInfo carries through the right fields")
    func updateInfoPassthrough() throws {
        let manifest = try UpdateManifest(
            version: "1.0.0",
            pubDate: "2026-01-01T00:00:00Z",
            notes: "hello",
            platforms: ["darwin-aarch64": .init(url: #require(URL(string: "https://x/a.tgz")), signature: "S")]
        )
        let info = manifest.updateInfo(for: "darwin-aarch64", currentVersion: "0.9.0")
        #expect(info?.version == "1.0.0")
        #expect(info?.currentVersion == "0.9.0")
        #expect(info?.pubDate == "2026-01-01T00:00:00Z")
        #expect(info?.notes == "hello")
        #expect(info?.signature == "S")
        #expect(info?.target == "darwin-aarch64")
    }

    // MARK: - UpdaterEvent codable round-trip

    @Test("UpdaterEvent encodes as a tagged union")
    func eventEncoding() throws {
        let info = try UpdateInfo(
            version: "0.4.0",
            currentVersion: "0.3.0",
            downloadURL: #require(URL(string: "https://x")),
            signature: "S",
            target: "darwin-aarch64"
        )
        let cases: [UpdaterEvent] = [
            .checking,
            .available(info),
            .upToDate,
            .downloadProgress(bytesDownloaded: 1024, contentLength: 4096),
            .downloadProgress(bytesDownloaded: 1024, contentLength: nil),
            .readyToInstall,
            .error(code: "E_HANDLER", message: "boom")
        ]
        for event in cases {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(UpdaterEvent.self, from: data)
            #expect(decoded == event)
            // Verify the wire shape includes a "type" discriminator.
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["type"] != nil)
        }
    }

    // MARK: - version comparison

    @Test("UpdaterVersion.isNewer handles core, length, and pre-release")
    func versionCompare() {
        #expect(UpdaterVersion.isNewer("0.4.0", than: "0.3.0"))
        #expect(UpdaterVersion.isNewer("0.4.1", than: "0.4.0"))
        #expect(UpdaterVersion.isNewer("1.0.0", than: "0.99.99"))
        #expect(!UpdaterVersion.isNewer("0.3.0", than: "0.3.0"))
        #expect(!UpdaterVersion.isNewer("0.3.0", than: "0.4.0"))
        // length: "1.0" treated as "1.0.0"
        #expect(!UpdaterVersion.isNewer("1.0", than: "1.0.0"))
        // pre-release: 1.0.0 > 1.0.0-beta1
        #expect(UpdaterVersion.isNewer("1.0.0", than: "1.0.0-beta1"))
        #expect(!UpdaterVersion.isNewer("1.0.0-beta1", than: "1.0.0"))
        #expect(UpdaterVersion.isNewer("1.0.0-beta2", than: "1.0.0-beta1"))
    }
}
