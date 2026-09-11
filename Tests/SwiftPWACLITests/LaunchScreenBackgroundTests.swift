import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The iOS launch screen is the one Apple surface that paints *before* the
/// runtime exists, so its light/dark handling is a build-time concern.
@Suite("iOS launch screen background")
struct LaunchScreenBackgroundTests {
    @Test("one colour is written into the storyboard, needing no catalog")
    func singleColourIsInline() {
        let xml = IPABundler.launchStoryboardXML(background: .single("#F4F7F5"))
        #expect(xml.contains("red=\"0.956"))
        #expect(!xml.contains("name=\"\(IPABundler.launchBackgroundName)\""))
        #expect(IPABundler.launchBackgroundColorSetJSON(.single("#F4F7F5")) == nil)
    }

    @Test("no background colour still yields a valid storyboard")
    func noColour() {
        let xml = IPABundler.launchStoryboardXML(background: nil)
        #expect(xml.contains("<color key=\"backgroundColor\""))
        #expect(IPABundler.launchBackgroundColorSetJSON(nil) == nil)
    }

    @Test("a pair is referenced by name so UIKit can resolve it at launch")
    func pairIsNamed() {
        let background = PWAManifest.BackgroundColor.dayNight(light: "#F4F4F2", dark: "#0C0D0E")
        let xml = IPABundler.launchStoryboardXML(background: background)
        #expect(xml.contains("<color key=\"backgroundColor\" name=\"LaunchBackground\"/>"))
        // The inline components must be gone, or the storyboard would carry a
        // second, contradictory colour.
        #expect(!xml.contains("customColorSpace=\"sRGB\""))
    }

    @Test("the colour set carries both appearances")
    func colorSetHasBothAppearances() throws {
        let json = try #require(
            IPABundler.launchBackgroundColorSetJSON(.dayNight(light: "#F4F4F2", dark: "#0C0D0E"))
        )
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let colors = try #require(parsed?["colors"] as? [[String: Any]])
        #expect(colors.count == 2)
        // The variant without an `appearances` key is the light one — that's
        // how an asset catalog spells "any appearance".
        let light = try #require(colors.first { $0["appearances"] == nil })
        let dark = try #require(colors.first { $0["appearances"] != nil })
        func red(_ entry: [String: Any]) -> String? {
            ((entry["color"] as? [String: Any])?["components"] as? [String: Any])?["red"] as? String
        }
        #expect(red(light) == "0xF4")
        #expect(red(dark) == "0x0C")
    }

    @Test("a pair with unparseable hex falls back to no colour set")
    func badHexNoColorSet() {
        #expect(IPABundler.launchBackgroundColorSetJSON(.dayNight(light: "#F4F4F2", dark: "nope")) == nil)
    }
}
