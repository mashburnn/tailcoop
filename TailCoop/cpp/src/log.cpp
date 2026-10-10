#include "log.h"

#include <share.h>

#include <cstdarg>
#include <cstdio>
#include <cwchar>
#include <mutex>

namespace tc {
namespace {

HMODULE g_self = nullptr;
FILE* g_log = nullptr;
std::mutex g_logMutex;

}  // namespace

void InitLog(HMODULE self) { g_self = self; }

HMODULE SelfModule() { return g_self; }

void Log(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (!g_log) {
        wchar_t path[MAX_PATH];
        GetModuleFileNameW(g_self, path, MAX_PATH);
        wchar_t* slash = wcsrchr(path, L'\\');
        if (slash) wcscpy_s(slash + 1, MAX_PATH - (slash + 1 - path), L"TailCoopNative.log");
        // A player's install keeps its log across sessions: over 2 MB it becomes TailCoopNative.log.old.
        WIN32_FILE_ATTRIBUTE_DATA info;
        if (GetFileAttributesExW(path, GetFileExInfoStandard, &info) &&
            (info.nFileSizeHigh > 0 || info.nFileSizeLow > 2u * 1024 * 1024)) {
            wchar_t old[MAX_PATH + 8];
            swprintf_s(old, L"%s.old", path);
            MoveFileExW(path, old, MOVEFILE_REPLACE_EXISTING);
        }
        g_log = _wfsopen(path, L"a", _SH_DENYNO);  // shared, so Lua and tools can read it while the game runs
        if (!g_log) return;
    }
    SYSTEMTIME t;
    GetLocalTime(&t);
    fprintf(g_log, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list args;
    va_start(args, fmt);
    vfprintf(g_log, fmt, args);
    va_end(args);
    fputc('\n', g_log);
    fflush(g_log);
}

}  // namespace tc
