// Volumetric-lightmap registry crash (EXCEPTION_ACCESS_VIOLATION writing 0x8 at Sifu+0x1ea9871, seen 3 times while a
// level loads).
//
// Sifu keeps a global TMap from each FPrecomputedVolumetricLightmap to a weak pointer (registry at 0x1458799b0). A
// lightmap adds itself in its constructor, which runs on the async loading thread when a ULevel is loaded
// (s.AsyncLoadingThreadEnabled=True), while the game thread looks entries up in UWorld::AddToWorld ->
// ULevel::InitializeRenderingResources -> FPrecomputedVolumetricLightmap::AddToScene, and every frame. The map has
// no lock, so a lookup that races an add/rehash can come back "not found", and the four lookups then use a null
// element (weak pointer at +8).
//
// Each lookup already compares the index to -1; only the not-found branch target is changed (one byte each), so it
// skips the element access, the way the code's own "weak pointer not valid" paths go. These branches only ever run
// in the case that used to crash.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include "enginefix.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace tc {
namespace {

struct BytePatch {
    uint32_t rva;       // of the JZ instruction (74 xx)
    uint8_t original;   // its displacement now
    uint8_t patched;    // displacement past the element access
    const char* what;
};

constexpr uint32_t kTimeDateStamp = 0x668BCFEC;
constexpr uint32_t kSizeOfImage = 0x06295000;

const BytePatch kPatches[] = {
    {0x35b8039, 0x11, 0x20, "AddToScene: skip storing the weak pointer"},
    {0x35d12e8, 0x11, 0x21, "frame update: treat as not valid"},
    {0x35d1344, 0x11, 0x77, "frame update: skip the re-registration check"},
    {0x35d138f, 0x0f, 0x18, "frame update: skip storing the weak pointer"},
};

}  // namespace

std::string ApplyEngineFixes() {
    auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->FileHeader.TimeDateStamp != kTimeDateStamp || nt->OptionalHeader.SizeOfImage != kSizeOfImage) {
        return "engine fixes: not for this game build (skipped)";
    }
    int applied = 0, already = 0, mismatch = 0;
    for (const BytePatch& p : kPatches) {
        uint8_t* jz = base + p.rva;
        if (jz[0] != 0x74 || (jz[1] != p.original && jz[1] != p.patched)) {
            ++mismatch;
            continue;
        }
        if (jz[1] == p.patched) {
            ++already;
            continue;
        }
        DWORD oldProtect = 0;
        if (!VirtualProtect(jz + 1, 1, PAGE_EXECUTE_READWRITE, &oldProtect)) {
            ++mismatch;
            continue;
        }
        jz[1] = p.patched;  // a single aligned byte: a thread running here sees the old or the new jump, both valid
        VirtualProtect(jz + 1, 1, oldProtect, &oldProtect);
        FlushInstructionCache(GetCurrentProcess(), jz, 2);
        ++applied;
    }
    char buf[160];
    snprintf(buf, sizeof buf, "engine fixes: volumetric lightmap registry %d/%zu applied%s%s", applied + already,
             sizeof kPatches / sizeof kPatches[0], already ? " (some were already)" : "",
             mismatch ? " - UNEXPECTED BYTES, not patched" : "");
    return buf;
}

}  // namespace tc
