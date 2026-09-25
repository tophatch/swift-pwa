import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The reason a `devicectl` launch was refused, dug out of its JSON (#224).
///
/// Both fixtures are real document shapes with the identifying parts replaced:
/// the first was measured here against a locked device, the second is the shape
/// an adopter reported. They differ in every detail that matters — depth, which
/// `userInfo` key carries the sentence, and whether there's a short token at the
/// leaf at all — which is why the reader walks to the leaf instead of matching
/// on a table of error codes.
@Suite("devicectl error reporting")
struct DeviceCtlErrorTests {
    /// Measured: `devicectl device process launch` against a device that hasn't
    /// been unlocked since boot, so the pairing tunnel can't come up. The leaf
    /// carries only `NSLocalizedDescription` and no `BSErrorCodeDescription`.
    static let lockedTunnel = Data("""
    {
      "error": {
        "code": 10003,
        "domain": "com.apple.dt.CoreDeviceError",
        "userInfo": {
          "NSLocalizedDescription": { "string": "The operation failed because the device was still locked." },
          "NSUnderlyingError": { "error": {
            "code": 1016,
            "domain": "com.apple.dt.RemotePairingError",
            "userInfo": {
              "NSLocalizedDescription": { "string": "The device has not been unlocked recently" }
            }
          } }
        }
      },
      "info": { "outcome": "failed" }
    }
    """.utf8)

    /// Measured: a launch against a device whose screen is locked while the
    /// pairing tunnel is up — the case the issue reported. Three links deep,
    /// and note the *middle* one also carries a sentence, in service-delegate
    /// jargon ("denied by service delegate (SBMainWorkspace) for reason:
    /// Locked"). Taking the deepest gets the sentence written for a person.
    static let lockedScreen = Data("""
    {
      "error": {
        "code": 10002,
        "domain": "com.apple.dt.CoreDeviceError",
        "userInfo": {
          "BundleIdentifier": { "string": "com.example.app" },
          "NSLocalizedDescription": { "string": "The application failed to launch." },
          "NSUnderlyingError": { "error": {
            "code": 1,
            "domain": "FBSOpenApplicationServiceErrorDomain",
            "userInfo": {
              "BSErrorCodeDescription": { "string": "RequestDenied" },
              "FBSOpenApplicationRequestID": { "string": "0x15f3" },
              "NSLocalizedDescription": { "string": "The request to open \\"com.example.app\\" failed." },
              "NSLocalizedFailureReason": { "string": "The request was denied by service delegate (SBMainWorkspace) for reason: Locked (\\"Unable to launch com.example.app because the device was not, or could not be, unlocked\\")." },
              "NSUnderlyingError": { "error": {
                "code": 7,
                "domain": "FBSOpenApplicationErrorDomain",
                "userInfo": {
                  "BSErrorCodeDescription": { "string": "Locked" },
                  "NSLocalizedFailureReason": { "string": "Unable to launch com.example.app because the device was not, or could not be, unlocked." }
                }
              } }
            }
          } }
        }
      },
      "info": { "outcome": "failed" }
    }
    """.utf8)

    /// Measured: a launch on a live tunnel naming a bundle id that isn't
    /// installed. The useful sentence is on the *outermost* link and the leaf
    /// is LaunchServices bookkeeping with no message at all — so "print the
    /// leaf" prints nothing here, which is why the reader wants the deepest
    /// link that actually carries a sentence.
    static let notInstalled = Data("""
    {
      "error": {
        "code": 10002,
        "domain": "com.apple.dt.CoreDeviceError",
        "userInfo": {
          "BundleIdentifier": { "string": "com.example.app" },
          "NSLocalizedDescription": { "string": "The application failed to launch." },
          "NSLocalizedFailureReason": { "string": "The requested application com.example.app is not installed." },
          "NSLocalizedRecoverySuggestion": { "string": "Provide a valid bundle identifier." },
          "NSUnderlyingError": { "error": {
            "code": -10814,
            "domain": "NSOSStatusErrorDomain",
            "userInfo": {
              "_LSFile": { "string": "LSBindingEvaluator.mm" },
              "_LSLine": { "int": 1975 }
            }
          } }
        }
      },
      "info": { "outcome": "failed" }
    }
    """.utf8)

    @Test("skips a leaf that carries no sentence, rather than reporting nothing")
    func messagelessLeaf() {
        let chain = DeviceCtlError.chain(fromJSON: Self.notInstalled)
        #expect(chain.count == 2)
        #expect(chain.last?.message == nil)
        #expect(DeviceCtlError.reason(chain) == "The requested application com.example.app is not installed.")
    }

    @Test("reads the leaf reason, not the generic outermost one")
    func leafReason() {
        let chain = DeviceCtlError.chain(fromJSON: Self.lockedScreen)
        #expect(chain.count == 3)
        #expect(chain.first?.domain == "com.apple.dt.CoreDeviceError")
        #expect(chain.last?.shortDescription == "Locked")
        let reason = DeviceCtlError.reason(chain)
        #expect(reason?.contains("could not be, unlocked") == true)
        // The failure this guards: reporting the outermost message tells the
        // user the launch failed, which is the one thing they already know.
        #expect(reason != "The application failed to launch.")
        // Nor the middle link's, which says the same thing in service-delegate
        // jargon — "deepest with a sentence" is what separates them.
        #expect(reason?.hasPrefix("Unable to launch") == true)
    }

    @Test("falls back to NSLocalizedDescription where a link has no failure reason")
    func descriptionFallback() {
        let chain = DeviceCtlError.chain(fromJSON: Self.lockedTunnel)
        #expect(chain.count == 2)
        #expect(chain.last?.shortDescription == nil)
        #expect(DeviceCtlError.reason(chain) == "The device has not been unlocked recently")
    }

    @Test("a locked device is not reported as an untrusted developer")
    func lockedIsNotTrust() {
        #expect(!DeviceCtlError.mentionsUntrustedDeveloper(DeviceCtlError.chain(fromJSON: Self.lockedScreen)))
        #expect(!DeviceCtlError.mentionsUntrustedDeveloper(DeviceCtlError.chain(fromJSON: Self.lockedTunnel)))
    }

    @Test("the trust paragraph is offered when devicectl says the profile isn't trusted")
    func trustWordingMatches() {
        let json = Data("""
        {
          "error": {
            "code": 10002,
            "domain": "com.apple.dt.CoreDeviceError",
            "userInfo": {
              "NSLocalizedDescription": { "string": "The application failed to launch." },
              "NSUnderlyingError": { "error": {
                "code": 3,
                "domain": "FBSOpenApplicationErrorDomain",
                "userInfo": {
                  "NSLocalizedFailureReason": { "string": "The request to open \\"com.example.app\\" failed. This app could not be installed because its integrity could not be verified, it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user." }
                }
              } }
            }
          }
        }
        """.utf8)
        #expect(DeviceCtlError.mentionsUntrustedDeveloper(DeviceCtlError.chain(fromJSON: json)))
    }

    @Test("a document devicectl never wrote yields no reason rather than a wrong one")
    func noDocument() {
        #expect(DeviceCtlError.chain(fromJSON: Data()).isEmpty)
        #expect(DeviceCtlError.chain(fromJSON: Data("not json".utf8)).isEmpty)
        #expect(DeviceCtlError.chain(fromJSON: Data("{\"info\":{\"outcome\":\"success\"}}".utf8)).isEmpty)
        #expect(DeviceCtlError.reason([]) == nil)
    }

    @Test("accepts an untagged userInfo value")
    func untaggedValue() {
        // Defensive: the document tags each value with its type today. If a
        // schema revision drops the tag, degrade to reading it rather than to
        // reporting nothing.
        let json = Data("""
        { "error": { "code": 1, "domain": "d", "userInfo": { "NSLocalizedDescription": "plain" } } }
        """.utf8)
        #expect(DeviceCtlError.reason(DeviceCtlError.chain(fromJSON: json)) == "plain")
    }

    // MARK: - A dropped connection (#260)

    /// Measured: `devicectl device install app` to a network-paired iPad after
    /// five idle minutes; one and three minutes installed. A single link, and
    /// the whole reason is in it.
    static let disconnectedAfterConnecting = Data("""
    {
      "error": {
        "code": 4000,
        "domain": "com.apple.dt.CoreDeviceError",
        "userInfo": {
          "DeviceIdentifier": { "string": "00000000-0000-0000-0000-000000000000" },
          "NSLocalizedDescription": { "string": "The device disconnected immediately after connecting." }
        }
      },
      "info": { "outcome": "failed" }
    }
    """.utf8)

    /// Reported: the same install on two other network-paired devices after a
    /// long build, rebuilt here from `devicectl`'s rendering of the chain. The
    /// same outer code as the one above, with different words and three more
    /// links under it.
    static let connectionReset = Data("""
    {
      "error": {
        "code": 4000,
        "domain": "com.apple.dt.CoreDeviceError",
        "userInfo": {
          "NSLocalizedDescription": { "string": "A connection to this device could not be established." },
          "NSUnderlyingError": { "error": {
            "code": 1,
            "domain": "com.apple.CoreDevice.ControlChannelConnectionError",
            "userInfo": {
              "NSLocalizedDescription": { "string": "Internal logic error: Connection was invalidated" },
              "NSUnderlyingError": { "error": {
                "code": 0,
                "domain": "com.apple.CoreDevice.ControlChannelConnectionError",
                "userInfo": {
                  "NSLocalizedDescription": { "string": "Transport error" },
                  "NSUnderlyingError": { "error": {
                    "code": 54,
                    "domain": "Network.NWError",
                    "userInfo": {
                      "NSLocalizedDescription": { "string": "The operation couldn't be completed. (Network.NWError error 54 - Connection reset by peer)" }
                    }
                  } }
                }
              } }
            }
          } }
        }
      },
      "info": { "outcome": "failed" }
    }
    """.utf8)

    @Test("both measured spellings of a dropped connection are retried")
    func droppedConnectionIsRetried() {
        #expect(DeviceCtlError.isDroppedConnection(DeviceCtlError.chain(fromJSON: Self.disconnectedAfterConnecting)))
        #expect(DeviceCtlError.isDroppedConnection(DeviceCtlError.chain(fromJSON: Self.connectionReset)))
    }

    @Test("a failure the device has to fix is not retried")
    func otherFailuresAreNotRetried() {
        for fixture in [Self.lockedTunnel, Self.lockedScreen, Self.notInstalled, Data()] {
            #expect(!DeviceCtlError.isDroppedConnection(DeviceCtlError.chain(fromJSON: fixture)))
        }
    }

    @Test("an install failure says what went wrong, and what to do when the caller knows")
    func failureDescription() {
        let chain = DeviceCtlError.chain(fromJSON: Self.disconnectedAfterConnecting)
        var failure = DeviceInstall.Failure(device: "iPad", reason: DeviceCtlError.reason(chain), retried: true)
        #expect(failure.description == """
        couldn't install on iPad — The device disconnected immediately after connecting. (after one retry)
        """)
        failure.recovery = "Re-run with --no-build."
        #expect(failure.description.hasSuffix("(after one retry)\nRe-run with --no-build."))
    }
}
