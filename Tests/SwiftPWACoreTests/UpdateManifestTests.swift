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
        // No floor ⇒ optional update.
        #expect(info?.mandatory == false)
    }

    // MARK: - min_supported_version kill-switch

    @Test("min_supported_version decodes from the wire")
    func minSupportedDecodes() throws {
        let json = """
        {
          "version": "0.4.0",
          "min_supported_version": "0.3.0",
          "platforms": { "darwin-aarch64": { "url": "https://x/a.tgz", "signature": "S" } }
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.minSupportedVersion == "0.3.0")
    }

    @Test("update is mandatory when the running build is below the floor")
    func mandatoryBelowFloor() throws {
        let manifest = try UpdateManifest(
            version: "0.4.0",
            minSupportedVersion: "0.3.0",
            platforms: ["darwin-aarch64": .init(url: #require(URL(string: "https://x/a.tgz")), signature: "S")]
        )
        // 0.2.0 < floor 0.3.0 ⇒ mandatory.
        #expect(manifest.updateInfo(for: "darwin-aarch64", currentVersion: "0.2.0")?.mandatory == true)
        // 0.3.0 == floor ⇒ not below it ⇒ optional.
        #expect(manifest.updateInfo(for: "darwin-aarch64", currentVersion: "0.3.0")?.mandatory == false)
        // 0.3.5 > floor ⇒ optional.
        #expect(manifest.updateInfo(for: "darwin-aarch64", currentVersion: "0.3.5")?.mandatory == false)
    }

    @Test("mandatory defaults false with no floor and survives a Codable round-trip")
    func mandatoryRoundTrip() throws {
        let manifest = try UpdateManifest(
            version: "0.4.0",
            platforms: ["darwin-aarch64": .init(url: #require(URL(string: "https://x/a.tgz")), signature: "S")]
        )
        let info = try #require(manifest.updateInfo(for: "darwin-aarch64", currentVersion: "0.2.0"))
        #expect(info.mandatory == false)
        // A mandatory info round-trips through Codable with the flag intact.
        let url = try #require(URL(string: "https://x/a.tgz"))
        let floored = UpdateManifest(
            version: "0.4.0",
            minSupportedVersion: "0.3.0",
            platforms: ["darwin-aarch64": .init(url: url, signature: "S")]
        )
        let mandatory = try #require(floored.updateInfo(for: "darwin-aarch64", currentVersion: "0.2.0"))
        let decoded = try JSONDecoder().decode(UpdateInfo.self, from: JSONEncoder().encode(mandatory))
        #expect(decoded.mandatory == true)
        // Absent `mandatory` key ⇒ false (tolerant decode for hand-built infos).
        let legacy = """
        { "version": "0.4.0", "current_version": "0.2.0", "download_url": "https://x/a.tgz",
          "signature": "S", "target": "darwin-aarch64" }
        """
        #expect(try JSONDecoder().decode(UpdateInfo.self, from: Data(legacy.utf8)).mandatory == false)
    }

    // MARK: - delta (binary-patch) entries

    @Test("deltas decode from the wire (additive)")
    func deltasDecode() throws {
        let json = """
        {
          "version": "0.4.0",
          "platforms": {
            "linux-x86_64-appimage": {
              "url": "https://x/MyApp-0.4.0.AppImage",
              "signature": "S",
              "deltas": [
                { "from": "0.3.0", "url": "https://x/0.3.0-to-0.4.0.zstpatch",
                  "size": 229, "base_sha256": "abc123" },
                { "from": "0.3.1", "url": "https://x/0.3.1-to-0.4.0.zstpatch" }
              ]
            }
          }
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        let deltas = try #require(manifest.platforms["linux-x86_64-appimage"]?.deltas)
        #expect(deltas.count == 2)
        #expect(deltas[0].from == "0.3.0")
        #expect(deltas[0].size == 229)
        #expect(deltas[0].baseSHA256 == "abc123")
        // Optional fields tolerate absence.
        #expect(deltas[1].from == "0.3.1")
        #expect(deltas[1].size == nil)
        #expect(deltas[1].baseSHA256 == nil)
    }

    @Test("a manifest without deltas decodes with deltas == nil")
    func deltasAbsent() throws {
        let json = """
        { "version": "0.4.0",
          "platforms": { "linux-x86_64-appimage": { "url": "https://x/a", "signature": "S" } } }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.platforms["linux-x86_64-appimage"]?.deltas == nil)
    }

    @Test("encoding omits the deltas key when nil (byte-stable with older manifests)")
    func deltasOmittedWhenNil() throws {
        let url = try #require(URL(string: "https://x/a"))
        let manifest = UpdateManifest(
            version: "0.4.0",
            platforms: ["linux-x86_64-appimage": .init(url: url, signature: "S")]
        )
        let data = try JSONEncoder().encode(manifest)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("deltas"))
    }

    @Test("updateInfo selects the delta whose from matches the running version")
    func updateInfoSelectsDelta() throws {
        let full = try #require(URL(string: "https://x/MyApp-0.4.0.AppImage"))
        let patch30 = try #require(URL(string: "https://x/0.3.0.zstpatch"))
        let patch31 = try #require(URL(string: "https://x/0.3.1.zstpatch"))
        let manifest = UpdateManifest(
            version: "0.4.0",
            platforms: ["linux-x86_64-appimage": .init(
                url: full, signature: "S",
                deltas: [
                    .init(from: "0.3.0", url: patch30, size: 229, baseSHA256: "aaa"),
                    .init(from: "0.3.1", url: patch31, size: 100, baseSHA256: "bbb")
                ]
            )]
        )
        // Running 0.3.1 ⇒ picks the 0.3.1 delta.
        let info = try #require(manifest.updateInfo(for: "linux-x86_64-appimage", currentVersion: "0.3.1"))
        #expect(info.delta?.url == patch31)
        #expect(info.delta?.size == 100)
        #expect(info.delta?.baseSHA256 == "bbb")
        // The full download URL is still present (the fallback path).
        #expect(info.downloadURL == full)
    }

    @Test("updateInfo yields delta == nil when no from matches (full-download fallback)")
    func updateInfoNoDeltaMatch() throws {
        let full = try #require(URL(string: "https://x/MyApp-0.4.0.AppImage"))
        let patch = try #require(URL(string: "https://x/0.3.0.zstpatch"))
        let manifest = UpdateManifest(
            version: "0.4.0",
            platforms: ["linux-x86_64-appimage": .init(
                url: full, signature: "S",
                deltas: [.init(from: "0.3.0", url: patch)]
            )]
        )
        // Running 0.2.0 — no delta from 0.2.0 ⇒ nil ⇒ full download.
        let info = try #require(manifest.updateInfo(for: "linux-x86_64-appimage", currentVersion: "0.2.0"))
        #expect(info.delta == nil)
        #expect(info.downloadURL == full)
    }

    @Test("DeltaInfo survives a UpdateInfo Codable round-trip with the snake_case key")
    func deltaInfoRoundTrip() throws {
        let full = try #require(URL(string: "https://x/a"))
        let patch = try #require(URL(string: "https://x/p.zstpatch"))
        let info = UpdateInfo(
            version: "0.4.0", currentVersion: "0.3.0",
            downloadURL: full, signature: "S", target: "linux-x86_64-appimage",
            delta: .init(url: patch, size: 42, baseSHA256: "deadbeef")
        )
        let data = try JSONEncoder().encode(info)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("base_sha256"))
        let decoded = try JSONDecoder().decode(UpdateInfo.self, from: data)
        #expect(decoded.delta?.url == patch)
        #expect(decoded.delta?.size == 42)
        #expect(decoded.delta?.baseSHA256 == "deadbeef")
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
