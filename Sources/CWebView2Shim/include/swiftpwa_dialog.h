// swiftpwa_dialog — Win32 native dialogs behind a flat C ABI.
//
// Why a C++ shim and not raw Swift: the Vista+ file dialogs
// (`IFileOpenDialog` / `IFileSaveDialog`) are COM, which Swift on
// Windows can call but only by manually unrolling each interface's
// vtable indirection. `MessageBoxW` is fine to call from Swift, but we
// want a single place that handles UTF-16 conversion and the COM
// lifetime juggling so the Swift side is free of `IShellItem*` and
// `CoTaskMemFree`. C++/COM is ~80 lines of boilerplate; doing it from
// Swift is several hundred.
//
// Lives in the same target as `swiftpwa_toast.h` and
// `swiftpwa_webview2.h` so we don't grow a third Swift system-library
// target for one .cpp.

#ifndef SWIFT_PWA_DIALOG_SHIM_H
#define SWIFT_PWA_DIALOG_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Severity hint. Mirrors Swift's `DialogKind` and maps onto the
// `MB_ICON*` flag for `MessageBoxW`.
typedef enum {
    SWIFTPWA_DIALOG_INFO = 0,
    SWIFTPWA_DIALOG_WARNING = 1,
    SWIFTPWA_DIALOG_ERROR = 2,
} swiftpwa_dialog_kind;

// Show a single-button informational dialog. Blocks until the user
// dismisses. `parent` may be NULL.
void swiftpwa_dialog_message(
    void *parent_hwnd,
    swiftpwa_dialog_kind kind,
    const wchar_t *title,
    const wchar_t *message);

// Show a Cancel / OK confirmation dialog. Returns 1 if the user picked
// OK, 0 otherwise. `ok_label` / `cancel_label` may be NULL — Win32's
// MessageBoxW doesn't actually let us customise the labels, so we
// route through TaskDialogIndirect when either label is non-NULL and
// fall back to the simpler MessageBoxW otherwise.
int32_t swiftpwa_dialog_confirm(
    void *parent_hwnd,
    swiftpwa_dialog_kind kind,
    const wchar_t *title,
    const wchar_t *message,
    const wchar_t *ok_label,
    const wchar_t *cancel_label);

// File-dialog filter. `name` is the human-readable label ("Images");
// `spec` is a Win32 filter pattern joined by `;` ("*.png;*.jpg"). Both
// are owned by the caller for the duration of the dialog call.
typedef struct {
    const wchar_t *name;
    const wchar_t *spec;
} swiftpwa_dialog_filter;

// Show the open-file dialog. On success, writes a freshly-allocated
// UTF-8 path array to `*out_paths` (NULL-terminated; both the array
// and each entry must be released via `swiftpwa_dialog_free_paths`)
// and returns the number of paths picked. On cancel, writes NULL and
// returns 0. On error, returns -1.
int32_t swiftpwa_dialog_open_file(
    void *parent_hwnd,
    const wchar_t *title,
    const wchar_t *default_folder,
    int32_t allow_multiple,
    int32_t n_filters,
    const swiftpwa_dialog_filter *filters,
    char ***out_paths);

// Show the save-file dialog. On success, writes a freshly-allocated
// UTF-8 path to `*out_path` (release via `swiftpwa_dialog_free_path`)
// and returns 1. On cancel, writes NULL and returns 0. On error,
// returns -1.
int32_t swiftpwa_dialog_save_file(
    void *parent_hwnd,
    const wchar_t *title,
    const wchar_t *default_folder,
    const wchar_t *default_name,
    int32_t n_filters,
    const swiftpwa_dialog_filter *filters,
    char **out_path);

// Show the directory-picker dialog. Same return convention as
// `swiftpwa_dialog_save_file`.
int32_t swiftpwa_dialog_open_directory(
    void *parent_hwnd,
    const wchar_t *title,
    const wchar_t *default_folder,
    char **out_path);

// Free a path returned via `swiftpwa_dialog_save_file` /
// `swiftpwa_dialog_open_directory`.
void swiftpwa_dialog_free_path(char *path);

// Free a path array returned via `swiftpwa_dialog_open_file`.
void swiftpwa_dialog_free_paths(char **paths);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // SWIFT_PWA_DIALOG_SHIM_H
