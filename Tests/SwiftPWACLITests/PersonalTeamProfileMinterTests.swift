import Foundation
@testable import SwiftPWACLISupport
import Testing

@Suite("PersonalTeamProfileMinter")
struct PersonalTeamProfileMinterTests {
    let bundleID = "com.example.testapp"
    let team = "ABCDE12345"

    @Test("emits the three project files")
    func fileSet() {
        let files = PersonalTeamProfileMinter.projectFiles(bundleID: bundleID, team: team)
        #expect(files.keys.sorted() == [
            "App.swift",
            "Minter.xcodeproj/project.pbxproj",
            "Minter.xcodeproj/xcshareddata/xcschemes/Minter.xcscheme"
        ])
    }

    @Test("the pbxproj is a structurally valid (OpenStep) plist with the app's id + team")
    func pbxprojWellFormed() throws {
        let files = PersonalTeamProfileMinter.projectFiles(bundleID: bundleID, team: team)
        let pbxproj = try #require(files["Minter.xcodeproj/project.pbxproj"])

        // pbxproj is an OpenStep-format property list — parsing it proves the
        // braces/semicolons/quoting are balanced (the thing hand-written
        // templates get wrong).
        let obj = try PropertyListSerialization.propertyList(
            from: Data(pbxproj.utf8), options: [], format: nil
        ) as? [String: Any]
        let root = try #require(obj)
        #expect(root["objectVersion"] != nil)
        #expect(root["rootObject"] != nil)
        #expect((root["objects"] as? [String: Any])?.isEmpty == false)

        #expect(pbxproj.contains("PRODUCT_BUNDLE_IDENTIFIER = \"\(bundleID)\""))
        #expect(pbxproj.contains("DEVELOPMENT_TEAM = \(team)"))
        #expect(pbxproj.contains("CODE_SIGN_STYLE = Automatic"))
    }

    @Test("the xcscheme is valid XML and points at the same target id as the pbxproj")
    func xcschemeWellFormed() throws {
        let files = PersonalTeamProfileMinter.projectFiles(bundleID: bundleID, team: team)
        let scheme = try #require(files["Minter.xcodeproj/xcshareddata/xcschemes/Minter.xcscheme"])
        let pbxproj = try #require(files["Minter.xcodeproj/project.pbxproj"])

        // Valid XML (Xcode 16 refuses a project with no scheme; a malformed one
        // is as bad as none).
        let doc = try XMLDocument(data: Data(scheme.utf8))
        let refs = try doc.nodes(forXPath: "//BuildableReference")
        #expect(!refs.isEmpty)

        // The BlueprintIdentifier must name a PBXNativeTarget that actually
        // exists in the pbxproj — a dangling scheme silently builds nothing.
        let blueprintID = try #require(
            (refs.first as? XMLElement)?.attribute(forName: "BlueprintIdentifier")?.stringValue
        )
        #expect(pbxproj.contains("\(blueprintID) /* Minter */ = {isa = PBXNativeTarget"))
    }

    /// Team is interpolated bare (it's a 10-char alphanumeric id) and bundle id
    /// is quoted — a regression here would break signing config.
    @Test("bundle id is quoted, team is bare")
    func settingFormatting() throws {
        let pbxproj = try #require(PersonalTeamProfileMinter.projectFiles(bundleID: bundleID, team: team)[
            "Minter.xcodeproj/project.pbxproj"
        ])
        #expect(pbxproj.contains("\"\(bundleID)\""))
        #expect(!pbxproj.contains("\"\(team)\""))
    }
}
