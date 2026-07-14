#pragma once
// The Zstandard headers. zstd's public API is all plain (non-variadic) C
// functions, so — unlike the libsecret shim — no wrapper is needed; Swift
// imports and calls ZSTD_* directly. `<zstd.h>` resolves from the default
// include path (libzstd-dev on Linux installs it to /usr/include; on Windows
// the vendored package's include dir is added to INCLUDE by the CLI). Linking
// is driven by the `link "zstd"` directive in module.modulemap.
#include <zstd.h>
