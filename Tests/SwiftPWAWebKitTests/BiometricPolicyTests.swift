#if os(macOS) || os(iOS)
    import LocalAuthentication
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing

    @Suite("BiometricPolicy")
    struct BiometricPolicyTests {
        @Test("allowDeviceCredential swaps in the policy that accepts a passcode")
        func policySelection() {
            #expect(BiometricPolicy.laPolicy(allowDeviceCredential: false) == .deviceOwnerAuthenticationWithBiometrics)
            #expect(BiometricPolicy.laPolicy(allowDeviceCredential: true) == .deviceOwnerAuthentication)
        }

        @Test("Face ID with no usage description is a problem")
        func faceIDMissingDescription() {
            let problem = BiometricPolicy.faceIDUsageDescriptionProblem(kind: .faceID, usageDescription: nil)
            #expect(problem?.contains("NSFaceIDUsageDescription") == true)
        }

        @Test("an empty usage description counts as missing")
        func faceIDEmptyDescription() {
            #expect(BiometricPolicy.faceIDUsageDescriptionProblem(kind: .faceID, usageDescription: "") != nil)
        }

        @Test("Face ID with a usage description is fine")
        func faceIDPresent() {
            #expect(BiometricPolicy.faceIDUsageDescriptionProblem(kind: .faceID, usageDescription: "Unlock") == nil)
        }

        @Test("the check only applies to Face ID")
        func otherKinds() {
            for kind in [BiometricKind.touchID, .opticID, .none, .unknown] {
                #expect(BiometricPolicy.faceIDUsageDescriptionProblem(kind: kind, usageDescription: nil) == nil)
            }
        }
    }
#endif
