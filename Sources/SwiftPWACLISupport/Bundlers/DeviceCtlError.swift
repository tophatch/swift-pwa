import Foundation

/// One link in a `devicectl` error chain.
struct DeviceCtlFailure: Equatable {
    let domain: String
    let code: Int
    /// FrontBoard's short token for the condition — `Locked`, `RequestDenied`.
    /// Carried by the `FBSOpenApplication*` domains and absent from most others.
    let shortDescription: String?
    /// The sentence written for a human, if this link carries one.
    let message: String?
}

/// Reads the reason out of a `devicectl --json-output` document.
///
/// `devicectl` exits non-zero with a status and nothing else a caller can act
/// on, so a caller holding only that status has to guess at the cause — and a
/// guess that names one cause is wrong for every other one (#224). The
/// structured document carries the real reason, nested: each `NSUnderlyingError`
/// is more specific than its parent, so the leaf is the answer.
enum DeviceCtlError {
    /// Every link, outermost error first.
    ///
    /// The outermost is typically the generic one ("The application failed to
    /// launch."), so the interesting end of the chain is the last element.
    static func chain(fromJSON data: Data) -> [DeviceCtlFailure] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? [String: Any]
        else { return [] }
        var chain: [DeviceCtlFailure] = []
        var node: [String: Any]? = error
        // Bounded rather than an open `while let`: the document is machine-written
        // and shouldn't contain a cycle, but a cycle here would hang the CLI on a
        // failure path — the worst place to find out.
        while let current = node, chain.count < 16 {
            let userInfo = current["userInfo"] as? [String: Any] ?? [:]
            chain.append(
                DeviceCtlFailure(
                    domain: current["domain"] as? String ?? "",
                    code: current["code"] as? Int ?? 0,
                    shortDescription: string(userInfo["BSErrorCodeDescription"]),
                    // `NSLocalizedFailureReason` is the fuller sentence where a
                    // link has both; `NSLocalizedDescription` is all some links
                    // carry, and a launch refused by a locked device has been
                    // measured in both shapes.
                    message: string(userInfo["NSLocalizedFailureReason"])
                        ?? string(userInfo["NSLocalizedDescription"])
                )
            )
            node = (userInfo["NSUnderlyingError"] as? [String: Any])?["error"] as? [String: Any]
        }
        return chain
    }

    /// The most specific sentence the chain carries, or `nil` if it carries
    /// none — the deepest link with a message, since a parent's is generic.
    static func reason(_ chain: [DeviceCtlFailure]) -> String? {
        chain.last { $0.message?.isEmpty == false }?.message
    }

    /// Whether this is the failure a visit to Settings actually fixes.
    ///
    /// Matched on `devicectl`'s own wording rather than on an error code,
    /// because the untrusted case is unmeasured here: reproducing it means
    /// un-trusting a development team on a device, which takes out every other
    /// development build on it at the same time. Wording is the weaker signal
    /// and a localized build could leave it matching nothing — so it only ever
    /// *adds* a paragraph, and the real reason is printed either way.
    static func mentionsUntrustedDeveloper(_ chain: [DeviceCtlFailure]) -> Bool {
        chain.contains {
            ($0.message ?? "").localizedCaseInsensitiveContains("not been explicitly trusted")
        }
    }

    /// `userInfo` values arrive type-tagged (`{"string": "…"}`) in the
    /// document's own schema. A bare string is accepted too, so a schema
    /// revision that drops the tag degrades to working rather than to silence.
    private static func string(_ value: Any?) -> String? {
        if let tagged = value as? [String: Any] { return tagged["string"] as? String }
        return value as? String
    }
}
