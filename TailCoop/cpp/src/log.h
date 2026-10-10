// Shared logging for TailCoopNative: native\TailCoopNative.log next to the DLL (shared read access).
#pragma once

#include <windows.h>

namespace tc {

void InitLog(HMODULE self);
void Log(const char* fmt, ...);
HMODULE SelfModule();

}  // namespace tc
