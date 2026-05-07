// swiftpwa_dialog — Win32 native dialog shim. See
// `include/swiftpwa_dialog.h` for the rationale + ABI.

#if defined(_WIN32) || defined(_WIN64)

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "swiftpwa_dialog.h"

#include <windows.h>
#include <commctrl.h>     // TaskDialogIndirect
#include <shobjidl.h>     // IFileOpenDialog / IFileSaveDialog
#include <shlobj.h>
#include <objbase.h>
#include <wrl/client.h>

#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

// MultiByteToWideChar helper not needed — we receive UTF-16 already.
// We do need WideToUtf8 for paths returned by IFileDialog (PWSTR).
char *wide_to_utf8_dup(const wchar_t *src) {
    if (!src) return nullptr;
    int n = WideCharToMultiByte(CP_UTF8, 0, src, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) return nullptr;
    char *buf = (char *)malloc((size_t)n);
    if (!buf) return nullptr;
    WideCharToMultiByte(CP_UTF8, 0, src, -1, buf, n, nullptr, nullptr);
    return buf;
}

UINT message_box_icon(swiftpwa_dialog_kind kind) {
    switch (kind) {
        case SWIFTPWA_DIALOG_WARNING: return MB_ICONWARNING;
        case SWIFTPWA_DIALOG_ERROR:   return MB_ICONERROR;
        default:                      return MB_ICONINFORMATION;
    }
}

PCWSTR task_dialog_icon(swiftpwa_dialog_kind kind) {
    switch (kind) {
        case SWIFTPWA_DIALOG_WARNING: return TD_WARNING_ICON;
        case SWIFTPWA_DIALOG_ERROR:   return TD_ERROR_ICON;
        default:                      return TD_INFORMATION_ICON;
    }
}

// COM apartment scope guard. CoInitializeEx is per-thread; we initialize
// STA on entry to each call (the file dialogs require STA) and uninit
// on exit, leaving the calling thread's apartment state as we found it.
struct ComScope {
    bool initialized = false;
    HRESULT hr = S_OK;
    ComScope() {
        hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        // RPC_E_CHANGED_MODE means a different apartment was already
        // initialized on this thread — the file dialogs still work in
        // MTA, just less ideally; the existing apartment stays.
        initialized = SUCCEEDED(hr);
    }
    ~ComScope() {
        if (initialized && hr != RPC_E_CHANGED_MODE) CoUninitialize();
    }
};

// Apply (title, default_folder, filters) to a file dialog. Common to
// open/save/folder paths.
HRESULT configure_file_dialog(
    IFileDialog *dlg,
    const wchar_t *title,
    const wchar_t *default_folder,
    int32_t n_filters,
    const swiftpwa_dialog_filter *filters
) {
    if (title && *title) dlg->SetTitle(title);

    if (default_folder && *default_folder) {
        ComPtr<IShellItem> folder;
        if (SUCCEEDED(SHCreateItemFromParsingName(
                default_folder, nullptr, IID_PPV_ARGS(&folder)))) {
            dlg->SetFolder(folder.Get());
        }
    }

    if (n_filters > 0 && filters) {
        std::vector<COMDLG_FILTERSPEC> specs;
        specs.reserve((size_t)n_filters);
        for (int32_t i = 0; i < n_filters; ++i) {
            COMDLG_FILTERSPEC fs = { filters[i].name, filters[i].spec };
            specs.push_back(fs);
        }
        dlg->SetFileTypes((UINT)specs.size(), specs.data());
    }
    return S_OK;
}

} // namespace

extern "C" {

void swiftpwa_dialog_message(
    void *parent_hwnd,
    swiftpwa_dialog_kind kind,
    const wchar_t *title,
    const wchar_t *message
) {
    HWND owner = (HWND)parent_hwnd;
    MessageBoxW(
        owner,
        message ? message : L"",
        (title && *title) ? title : L"",
        MB_OK | message_box_icon(kind)
    );
}

int32_t swiftpwa_dialog_confirm(
    void *parent_hwnd,
    swiftpwa_dialog_kind kind,
    const wchar_t *title,
    const wchar_t *message,
    const wchar_t *ok_label,
    const wchar_t *cancel_label
) {
    HWND owner = (HWND)parent_hwnd;

    // If the caller didn't customise either label, MessageBoxW is
    // simpler (and themed enough on Win10/11). Otherwise fall through
    // to TaskDialogIndirect, which lets us name the buttons.
    if (!ok_label && !cancel_label) {
        int rc = MessageBoxW(
            owner,
            message ? message : L"",
            (title && *title) ? title : L"",
            MB_OKCANCEL | message_box_icon(kind)
        );
        return rc == IDOK ? 1 : 0;
    }

    TASKDIALOG_BUTTON buttons[2] = {};
    // Custom button ids start at 100 by convention to avoid the
    // standard IDOK / IDCANCEL constants.
    buttons[0].nButtonID = 100;
    buttons[0].pszButtonText = ok_label ? ok_label : L"OK";
    buttons[1].nButtonID = 101;
    buttons[1].pszButtonText = cancel_label ? cancel_label : L"Cancel";

    TASKDIALOGCONFIG cfg = {};
    cfg.cbSize = sizeof(cfg);
    cfg.hwndParent = owner;
    cfg.pszMainIcon = task_dialog_icon(kind);
    cfg.pszWindowTitle = (title && *title) ? title : nullptr;
    cfg.pszMainInstruction = nullptr;
    cfg.pszContent = message ? message : L"";
    cfg.cButtons = 2;
    cfg.pButtons = buttons;
    cfg.nDefaultButton = 100;
    cfg.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION;

    int chosen = 0;
    HRESULT hr = TaskDialogIndirect(&cfg, &chosen, nullptr, nullptr);
    if (FAILED(hr)) return 0;
    return chosen == 100 ? 1 : 0;
}

int32_t swiftpwa_dialog_open_file(
    void *parent_hwnd,
    const wchar_t *title,
    const wchar_t *default_folder,
    int32_t allow_multiple,
    int32_t n_filters,
    const swiftpwa_dialog_filter *filters,
    char ***out_paths
) {
    if (out_paths) *out_paths = nullptr;
    HWND owner = (HWND)parent_hwnd;

    ComScope com;
    ComPtr<IFileOpenDialog> dlg;
    HRESULT hr = CoCreateInstance(
        CLSID_FileOpenDialog, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)
    );
    if (FAILED(hr)) return -1;

    DWORD flags = 0;
    dlg->GetOptions(&flags);
    flags |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_FILEMUSTEXIST;
    if (allow_multiple) flags |= FOS_ALLOWMULTISELECT;
    dlg->SetOptions(flags);

    configure_file_dialog(dlg.Get(), title, default_folder, n_filters, filters);

    hr = dlg->Show(owner);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return 0;
    if (FAILED(hr)) return -1;

    ComPtr<IShellItemArray> items;
    hr = dlg->GetResults(&items);
    if (FAILED(hr) || !items) return 0;

    DWORD count = 0;
    items->GetCount(&count);
    if (count == 0) return 0;

    char **out = (char **)calloc((size_t)count + 1, sizeof(char *));
    if (!out) return -1;

    DWORD written = 0;
    for (DWORD i = 0; i < count; ++i) {
        ComPtr<IShellItem> item;
        if (FAILED(items->GetItemAt(i, &item)) || !item) continue;
        PWSTR raw = nullptr;
        if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw)) || !raw) continue;
        char *u = wide_to_utf8_dup(raw);
        CoTaskMemFree(raw);
        if (u) out[written++] = u;
    }
    out[written] = nullptr;

    if (written == 0) {
        free(out);
        return 0;
    }
    if (out_paths) *out_paths = out;
    return (int32_t)written;
}

int32_t swiftpwa_dialog_save_file(
    void *parent_hwnd,
    const wchar_t *title,
    const wchar_t *default_folder,
    const wchar_t *default_name,
    int32_t n_filters,
    const swiftpwa_dialog_filter *filters,
    char **out_path
) {
    if (out_path) *out_path = nullptr;
    HWND owner = (HWND)parent_hwnd;

    ComScope com;
    ComPtr<IFileSaveDialog> dlg;
    HRESULT hr = CoCreateInstance(
        CLSID_FileSaveDialog, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)
    );
    if (FAILED(hr)) return -1;

    DWORD flags = 0;
    dlg->GetOptions(&flags);
    flags |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_OVERWRITEPROMPT;
    dlg->SetOptions(flags);

    configure_file_dialog(dlg.Get(), title, default_folder, n_filters, filters);
    if (default_name && *default_name) dlg->SetFileName(default_name);

    hr = dlg->Show(owner);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return 0;
    if (FAILED(hr)) return -1;

    ComPtr<IShellItem> result;
    if (FAILED(dlg->GetResult(&result)) || !result) return 0;
    PWSTR raw = nullptr;
    if (FAILED(result->GetDisplayName(SIGDN_FILESYSPATH, &raw)) || !raw) return 0;
    char *u = wide_to_utf8_dup(raw);
    CoTaskMemFree(raw);
    if (!u) return -1;
    if (out_path) *out_path = u; else free(u);
    return 1;
}

int32_t swiftpwa_dialog_open_directory(
    void *parent_hwnd,
    const wchar_t *title,
    const wchar_t *default_folder,
    char **out_path
) {
    if (out_path) *out_path = nullptr;
    HWND owner = (HWND)parent_hwnd;

    ComScope com;
    ComPtr<IFileOpenDialog> dlg;
    HRESULT hr = CoCreateInstance(
        CLSID_FileOpenDialog, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)
    );
    if (FAILED(hr)) return -1;

    DWORD flags = 0;
    dlg->GetOptions(&flags);
    flags |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_PICKFOLDERS;
    dlg->SetOptions(flags);

    configure_file_dialog(dlg.Get(), title, default_folder, 0, nullptr);

    hr = dlg->Show(owner);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return 0;
    if (FAILED(hr)) return -1;

    ComPtr<IShellItem> result;
    if (FAILED(dlg->GetResult(&result)) || !result) return 0;
    PWSTR raw = nullptr;
    if (FAILED(result->GetDisplayName(SIGDN_FILESYSPATH, &raw)) || !raw) return 0;
    char *u = wide_to_utf8_dup(raw);
    CoTaskMemFree(raw);
    if (!u) return -1;
    if (out_path) *out_path = u; else free(u);
    return 1;
}

void swiftpwa_dialog_free_path(char *path) {
    if (path) free(path);
}

void swiftpwa_dialog_free_paths(char **paths) {
    if (!paths) return;
    for (char **p = paths; *p; ++p) free(*p);
    free(paths);
}

} // extern "C"

#endif // _WIN32
