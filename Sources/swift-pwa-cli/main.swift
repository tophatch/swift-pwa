import SwiftPWACLISupport

// Thin executable entry. The actual command tree lives in
// `SwiftPWACLISupport.SwiftPWACLIRoot` — see the comment there for
// why the split exists. We dispatch through `SwiftPWACLIEntry.run()`
// rather than calling `SwiftPWACLIRoot.main()` directly because the
// wrapper is `@available`-annotated, which forces overload resolution
// to pick SwiftArgumentParser's async `main()` even on hosts that
// have no SwiftPM deployment-target concept (Windows, Linux). See
// the doc comment on `SwiftPWACLIEntry` for the full story.
await SwiftPWACLIEntry.run()
