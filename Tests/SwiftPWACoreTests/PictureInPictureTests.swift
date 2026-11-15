@testable import SwiftPWACore
import Testing

@Suite("picture in picture opt-in")
struct PictureInPictureTests {
    @Test("the bundle's Info.plist opts in")
    func fromBundle() {
        #expect(PictureInPicture.isRequested(info: [PictureInPicture.infoPlistKey: true], environment: [:]))
        #expect(!PictureInPicture.isRequested(info: [PictureInPicture.infoPlistKey: false], environment: [:]))
        #expect(!PictureInPicture.isRequested(info: nil, environment: [:]))
    }

    /// A bare binary under `drive` or `dev` has no Info.plist, so the tooling
    /// passes the opt-in instead. Test builds are debug builds, which honour it.
    @Test("the tooling's environment opts in an unbundled run")
    func fromTooling() {
        #expect(PictureInPicture.isRequested(info: nil, environment: [PictureInPicture.environmentVariable: "1"]))
        #expect(!PictureInPicture.isRequested(info: nil, environment: [PictureInPicture.environmentVariable: "0"]))
    }
}
