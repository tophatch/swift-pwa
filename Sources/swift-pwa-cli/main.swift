import SwiftPWACLISupport

// Thin executable entry. The actual command tree lives in
// `SwiftPWACLISupport.SwiftPWACLIRoot` — see the comment there for
// why the split exists.
await SwiftPWACLIRoot.main()
