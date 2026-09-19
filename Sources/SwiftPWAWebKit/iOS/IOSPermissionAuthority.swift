#if os(iOS)
    import Foundation
    import SwiftPWACore

    /// ``DevicePermissionAuthority`` on iOS. It exists to say *no* to one
    /// thing, honestly and in advance.
    ///
    /// There is no All-files access on iOS and there is no prospect of one: an
    /// app reaches the user's files through a document picker or a scoped
    /// bookmark, both of which hand over what the user chose and nothing else.
    /// So ``PermissionState/unavailable`` rather than ``PermissionState/denied``
    /// — an app that read `denied` would offer a button that leads nowhere, and
    /// the fix on iOS is a different design, not a prompt.
    ///
    /// Everything else is `nil`: iOS asks for the camera, the microphone and
    /// location through WebKit's own permission seam at the moment the page
    /// uses them.
    struct IOSPermissionAuthority: DevicePermissionAuthority {
        func state(of permission: DevicePermission) async -> PermissionState? {
            permission == .allFiles ? .unavailable : nil
        }

        func request(_ permission: DevicePermission) async -> PermissionState? {
            permission == .allFiles ? .unavailable : nil
        }
    }
#endif
