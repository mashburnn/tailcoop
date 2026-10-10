// TailCoopNative.dll - native side of TailCoop, loaded from Lua:
//     package.loadlib(dll, "luaopen_tailcoopnative")()
// which registers the TailCoop_* globals below (through UE4SS's exported Lua wrapper, see lua_bridge.h).
// All arguments are passed as strings from Lua (tc_net.lua) to keep the bridge simple.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <new>
#include <string>

#include "enginefix.h"
#include "log.h"
#include "lua_bridge.h"
#include "pose.h"
#include "tailscale.h"
#include "transport.h"
#include "ue4ss_api.h"

using RC::LuaMadeSimple::Lua;

namespace {

constexpr const char* kNativeVersion = "TailCoopNative 12";
std::string g_engineFixes = "engine fixes: not applied yet";

// Sifu's real UObject::ProcessEvent (RVA 0x1E9B300). UE4SS needs VTableLayout.ini to find it; without that,
// every UFunction call from Lua silently does nothing. Checked here so a bad install is reported loudly.
constexpr uintptr_t kRealProcessEventRva = 0x1E9B300;
const char kProcessEventSymbol[] =
    "?ProcessEventInternal@UObject@Unreal@RC@@2V?$Function@$$A6AXPEAVUObject@Unreal@RC@@PEAVUFunction@23@PEAX@Z@3@A";

std::string CheckProcessEvent() {
    HMODULE ue4ss = GetModuleHandleW(L"UE4SS.dll");
    auto* slot = ue4ss ? reinterpret_cast<uintptr_t*>(GetProcAddress(ue4ss, kProcessEventSymbol)) : nullptr;
    if (!slot) return "unknown (UE4SS export missing)";
    const uintptr_t real = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr)) + kRealProcessEventRva;
    return slot[0] == real ? "ok" : "WRONG: install VTableLayout.ini";
}

// Identity of the installed game: exe link timestamp + image size + main pak size. Both players must match.
std::string ComputeIdentity() {
    auto* base = reinterpret_cast<const uint8_t*>(GetModuleHandleW(nullptr));
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    wchar_t exePath[MAX_PATH];
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring pak(exePath);
    pak = pak.substr(0, pak.find_last_of(L'\\')) + L"\\..\\..\\Content\\Paks\\pakchunk0-WindowsNoEditor.pak";
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    unsigned long long pakSize = 0;
    if (GetFileAttributesExW(pak.c_str(), GetFileExInfoStandard, &attr)) {
        pakSize = (static_cast<unsigned long long>(attr.nFileSizeHigh) << 32) | attr.nFileSizeLow;
    }
    char buf[96];
    snprintf(buf, sizeof buf, "%08lX-%08lX-%llu", static_cast<unsigned long>(nt->FileHeader.TimeDateStamp),
             static_cast<unsigned long>(nt->OptionalHeader.SizeOfImage), pakSize);
    return buf;
}

// Reads the next string argument (stack index 1, consumed); nil/missing -> fallback.
std::string Arg(const Lua& lua, const char* fallback = "") {
    if (lua.get_stack_size() < 1) return fallback;
    if (lua.is_string(1)) return std::string(lua.get_string(1));
    lua.discard_value(1);
    return fallback;
}

int ToInt(const std::string& s, int fallback) {
    try {
        return s.empty() ? fallback : std::stoi(s);
    } catch (...) {
        return fallback;
    }
}

// TailCoop_Host(port, bindAddress, name, modVersion) -> ok, error
// bindAddress "tailscale" binds to this PC's Tailscale address (reachable only through the tailnet).
int LHost(const Lua& lua) {
    const int port = ToInt(Arg(lua), 7777);
    std::string bind = Arg(lua, "0.0.0.0");
    const std::string name = Arg(lua, "player"), mod = Arg(lua, "?");
    std::string error;
    if (bind == "tailscale") {
        bind = tc::TailscaleSelfIp();
        if (bind.empty()) error = "Tailscale is not running on this PC";
    }
    const bool ok = error.empty() && tc::Host(port, bind, name, mod, error);
    lua.set_bool(ok);
    lua.set_string(error);
    return 2;
}

// TailCoop_Join(address, port, name, modVersion) -> ok, error
int LJoin(const Lua& lua) {
    const std::string address = Arg(lua);
    const int port = ToInt(Arg(lua), 7777);
    const std::string name = Arg(lua, "player"), mod = Arg(lua, "?");
    std::string error;
    const bool ok = tc::Join(address, port, name, mod, error);
    lua.set_bool(ok);
    lua.set_string(error);
    return 2;
}

int LLeave(const Lua&) {
    tc::Leave();
    return 0;
}

// TailCoop_Send(channel "0"|"1", payload) -> ok, error
int LSend(const Lua& lua) {
    const int channel = ToInt(Arg(lua), tc::kReliable);
    const std::string payload = Arg(lua);
    std::string error;
    const bool ok = tc::Send(channel, payload, error);
    lua.set_bool(ok);
    lua.set_string(error);
    return 2;
}

// TailCoop_Poll() -> channel, payload | nil. Pose messages (binary) are handled here and never reach Lua.
int LPoll(const Lua&  lua) {
    int channel = 0;
    std::string payload;
    for (;;) {
        if (!tc::Poll(channel, payload)) {
            lua.set_nil();
            return 1;
        }
        if (channel != tc::kUnreliable || payload.empty() || payload[0] != tc::pose::kMagic) break;
        tc::pose::Receive(payload);
    }
    lua.set_integer(channel);
    lua.set_string(payload);
    return 2;
}

// TailCoop_Status() -> state, detail, peerName, rttMs, sent, received, resent, pendingReliable, localAddress
int LStatus(const Lua& lua) {
    const tc::StatusInfo s = tc::Status();
    lua.set_string(s.state);
    lua.set_string(s.detail);
    lua.set_string(s.peerName);
    lua.set_integer(s.rttMs);
    lua.set_integer(static_cast<long long>(s.packetsSent));
    lua.set_integer(static_cast<long long>(s.packetsReceived));
    lua.set_integer(static_cast<long long>(s.resent));
    lua.set_integer(static_cast<long long>(s.pendingReliable));
    lua.set_string(s.localAddress);
    return 9;
}

int LPeers(const Lua& lua) {
    lua.set_string(tc::TailscalePeers());
    return 1;
}

// TailCoop_Simulate(lossPercent, delayMs, jitterMs) -> drops so far. Test-only network impairment.
int LSimulate(const Lua& lua) {
    double loss = 0;
    try {
        loss = std::stod(Arg(lua, "0"));
    } catch (...) {
    }
    const int delay = ToInt(Arg(lua), 0), jitter = ToInt(Arg(lua), 0);
    tc::Simulate(loss, delay, jitter);
    lua.set_integer(static_cast<long long>(tc::SimulatedDrops()));
    return 1;
}

// TailCoop_Clock() -> milliseconds on a steady clock (Lua's os.time is seconds and os.clock is CPU time).
int LClock(const Lua& lua) {
    using namespace std::chrono;
    lua.set_integer(duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
    return 1;
}

// Raw reads of game memory, for struct fields UE4SS's Lua can't reach (fields inherited from a parent struct).
// A bad address returns false instead of crashing the game.
bool SafeRead(uintptr_t address, void* out, size_t size) {
    __try {
        memcpy(out, reinterpret_cast<const void*>(address), size);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

uintptr_t ToAddress(const std::string& s) {
    try {
        return s.empty() ? 0 : static_cast<uintptr_t>(std::stoull(s, nullptr, 0));
    } catch (...) {
        return 0;
    }
}

// TailCoop_Peek(address, offset, kind "u8"|"i32"|"f32"|"ptr") -> number | nil. Numbers are passed as strings.
int LPeek(const Lua& lua) {
    const uintptr_t base = ToAddress(Arg(lua)), offset = ToAddress(Arg(lua));
    const std::string kind = Arg(lua, "u8");
    if (base < 0x10000) {
        lua.set_nil();
        return 1;
    }
    union {
        uint8_t u8;
        int32_t i32;
        float f32;
        uint64_t ptr;
    } v{};
    const size_t size = kind == "ptr" ? 8 : (kind == "u8" ? 1 : 4);
    if (!SafeRead(base + offset, &v, size)) {
        lua.set_nil();
        return 1;
    }
    if (kind == "f32") {
        lua.set_number(v.f32);
    } else if (kind == "i32") {
        lua.set_integer(v.i32);
    } else if (kind == "ptr") {
        lua.set_integer(static_cast<long long>(v.ptr));
    } else {
        lua.set_integer(v.u8);
    }
    return 1;
}

bool SafeWrite(uintptr_t address, const void* in, size_t size) {
    __try {
        memcpy(reinterpret_cast<void*>(address), in, size);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// TailCoop_PokeFloats(address, offset, v1, v2, ...) -> ok. Writes consecutive floats (e.g. an FVector).
int LPokeFloats(const Lua& lua) {
    const uintptr_t base = ToAddress(Arg(lua)), offset = ToAddress(Arg(lua));
    float values[8];
    size_t n = 0;
    while (n < 8 && lua.get_stack_size() >= 1) {
        float v = 0;
        try {
            v = std::stof(Arg(lua, "0"));
        } catch (...) {
        }
        values[n++] = v;
    }
    lua.set_bool(base >= 0x10000 && n > 0 && SafeWrite(base + offset, values, n * sizeof(float)));
    return 1;
}

// TailCoop_PokeU8(address, offset, value) -> ok. Writes one byte (e.g. an entry of Sifu's faction table).
int LPokeU8(const Lua& lua) {
    const uintptr_t base = ToAddress(Arg(lua)), offset = ToAddress(Arg(lua));
    const int value = ToInt(Arg(lua), -1);
    const auto byte = static_cast<uint8_t>(value);
    lua.set_bool(base >= 0x10000 && value >= 0 && value <= 255 && SafeWrite(base + offset, &byte, 1));
    return 1;
}

void FullNameInto(const RC::Unreal::UObject* object, std::wstring* out) { *out = object->GetFullName(nullptr); }

bool SafeFullName(const RC::Unreal::UObject* object, std::wstring* out) {
    __try {
        FullNameInto(object, out);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// TailCoop_ObjectPath(address) -> "/Game/.../Asset.Asset" | nil (the object's full name without the class).
int LObjectPath(const Lua& lua) {
    const uintptr_t address = ToAddress(Arg(lua));
    std::wstring name;
    if (address < 0x10000 || !SafeFullName(reinterpret_cast<const RC::Unreal::UObject*>(address), &name) ||
        name.empty()) {
        lua.set_nil();
        return 1;
    }
    const size_t space = name.find(L' ');
    if (space != std::wstring::npos) name.erase(0, space + 1);
    std::string utf8(WideCharToMultiByte(CP_UTF8, 0, name.c_str(), static_cast<int>(name.size()), nullptr, 0,
                                         nullptr, nullptr),
                     '\0');
    WideCharToMultiByte(CP_UTF8, 0, name.c_str(), static_cast<int>(name.size()), utf8.data(),
                        static_cast<int>(utf8.size()), nullptr, nullptr);
    lua.set_string(utf8);
    return 1;
}

// Struct parameters as text --------------------------------------------------------------------------------
// Unreal's own text form of a property value (what copy/paste in the editor uses): names, asset paths, gameplay tags,
// arrays and maps all survive the trip to another process; actor references are paths the receiver can rewrite.
// Only a function's FIRST parameter is supported (e.g. FightingCharacter:Hitted(FHitDescription)); its size is
// checked against what the caller expects, so a wrong function can't be fed the wrong struct.

// PPF_IncludeTransient: hit data (FHitDescription) is all Transient, which text export skips by default.
constexpr int32_t kPortFlags = 0x00020000;

std::string Utf8(const std::wstring& w) {
    std::string s(WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr),
                  '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), s.data(), static_cast<int>(s.size()), nullptr,
                        nullptr);
    return s;
}

std::wstring Wide(const std::string& s) {
    std::wstring w(MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), w.data(), static_cast<int>(w.size()));
    return w;
}

// Stand-in for the engine's FOutputDevice that ImportText reports problems to: every virtual is a no-op that only
// counts the call (Logf ends in a virtual Serialize). Saves passing a null device, which the engine dereferences.
int g_importWarnings = 0;
intptr_t CountingNoop() {
    ++g_importWarnings;
    return 0;
}
void* g_nullDeviceVtable[32];
struct NullOutputDevice {
    void** vtable;
    bool flags[8];
};
NullOutputDevice g_nullDevice{};

RC::Unreal::FProperty* FirstParam(RC::Unreal::UFunction* function) {
    auto* fn = reinterpret_cast<RC::Unreal::UStruct*>(function);
    return reinterpret_cast<RC::Unreal::FProperty*>(fn->GetChildProperties());
}

// Returns false on an access violation (bad address / layout) instead of taking the game down.
bool ExportGuarded(RC::Unreal::UFunction* function, const void* value, int expectedSize, std::wstring* out, int* size) {
    alignas(16) unsigned char storage[sizeof(RC::Unreal::FString)];
    __try {
        RC::Unreal::FProperty* prop = FirstParam(function);
        if (!prop) return false;
        *size = prop->GetSize();
        if (*size != expectedSize) return true;
        auto* text = new (storage) RC::Unreal::FString();
        prop->ExportTextItem(*text, value, nullptr, nullptr, kPortFlags, nullptr);
        if (text->Data() && text->Num() > 1) out->assign(text->Data(), text->Num() - 1);
        text->~FString();
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// TailCoop_ExportParam(functionAddress, valueAddress, expectedSize) -> text | nil, error
int LExportParam(const Lua& lua) {
    auto* function = reinterpret_cast<RC::Unreal::UFunction*>(ToAddress(Arg(lua)));
    const void* value = reinterpret_cast<const void*>(ToAddress(Arg(lua)));
    const int expected = ToInt(Arg(lua), -1);
    std::wstring text;
    int size = -1;
    if (!function || !value) {
        lua.set_nil();
        lua.set_string("bad address");
        return 2;
    }
    if (!ExportGuarded(function, value, expected, &text, &size)) {
        lua.set_nil();
        lua.set_string("crashed while exporting (caught)");
        return 2;
    }
    if (size != expected) {
        lua.set_nil();
        lua.set_string("parameter size " + std::to_string(size) + ", expected " + std::to_string(expected));
        return 2;
    }
    lua.set_string(Utf8(text));
    return 1;
}

// Imports texts[i] into the function's i-th parameter (i < count) of a fresh buffer and calls `function` on `object`.
// 0 = ok, 1 = crashed (caught; *stage says where), 2 = parameter size mismatch, 3 = a text didn't import.
constexpr int kMaxImported = 4;
int CallGuarded(RC::Unreal::UObject* object, RC::Unreal::UFunction* function, const wchar_t* const* texts,
                const int* sizes, int count, unsigned char* params, int* stage) {
    RC::Unreal::FProperty* props[kMaxImported] = {};
    int built = 0;
    __try {
        // Only the imported parameters are constructed/destroyed, through their properties (UStruct::InitializeStruct
        // is a UObject-side virtual and Sifu's vtable is shifted there); the rest of the buffer stays zeroed.
        *stage = 1;
        RC::Unreal::FField* field = reinterpret_cast<RC::Unreal::UStruct*>(function)->GetChildProperties();
        for (int i = 0; i < count; ++i) {
            if (!field) return 2;
            props[i] = reinterpret_cast<RC::Unreal::FProperty*>(field);
            if (props[i]->GetSize() != sizes[i]) return 2;
            field = RC::Unreal::FieldWalker::Next(field);
        }
        for (int i = 0; i < count; ++i) {
            unsigned char* value = params + props[i]->GetOffset_Internal();
            *stage = 2;
            props[i]->InitializeValue(value);
            built = i + 1;
            *stage = 3;
            if (!props[i]->ImportText(texts[i], value, kPortFlags, nullptr,
                                      reinterpret_cast<RC::Unreal::FOutputDevice*>(&g_nullDevice))) {
                for (int j = 0; j < built; ++j) props[j]->DestroyValue(params + props[j]->GetOffset_Internal());
                return 3;
            }
        }
        *stage = 4;
        object->ProcessEvent(function, params);
        *stage = 5;
        for (int j = 0; j < built; ++j) props[j]->DestroyValue(params + props[j]->GetOffset_Internal());
        return 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 1;
    }
}
// Watched calls: every ProcessEvent of a watched function has its first parameter exported as text and queued for
// Lua (TailCoop_PollCaptured). The hot path (every ProcessEvent in the game) is a scan of a few atomics.
constexpr int kMaxWatched = 8;
std::atomic<void*> g_watchFns[kMaxWatched];
std::atomic<int> g_watchSizes[kMaxWatched];
std::atomic<int> g_watchCount{0};
struct Captured {
    uintptr_t context;
    uintptr_t function;
    std::string text;
};
std::mutex g_capturedMutex;
std::deque<Captured> g_captured;
bool g_preCallbackRegistered = false;

bool ExportFromParms(RC::Unreal::UFunction* function, const unsigned char* parms, int size, std::wstring* out) {
    __try {
        RC::Unreal::FProperty* prop = FirstParam(function);
        if (!prop) return false;
        int got = 0;
        return ExportGuarded(function, parms + prop->GetOffset_Internal(), size, out, &got) && got == size;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

void OnProcessEvent(RC::Unreal::UObject* context, RC::Unreal::UFunction* function, void* parms) {
    const int count = g_watchCount.load(std::memory_order_acquire);
    if (count == 0 || !parms) return;
    int size = 0;
    for (int i = 0; i < count; ++i) {
        if (g_watchFns[i].load(std::memory_order_relaxed) == function) {
            size = g_watchSizes[i].load(std::memory_order_relaxed);
            break;
        }
    }
    if (size == 0) return;
    std::wstring text;
    if (!ExportFromParms(function, static_cast<const unsigned char*>(parms), size, &text)) return;
    std::lock_guard<std::mutex> lock(g_capturedMutex);
    if (g_captured.size() >= 64) g_captured.pop_front();
    g_captured.push_back({reinterpret_cast<uintptr_t>(context), reinterpret_cast<uintptr_t>(function), Utf8(text)});
}

// TailCoop_WatchParam(functionAddress, expectedSize) -> ok, error
int LWatchParam(const Lua& lua) {
    void* function = reinterpret_cast<void*>(ToAddress(Arg(lua)));
    const int size = ToInt(Arg(lua), 0);
    if (!function || size <= 0) {
        lua.set_bool(false);
        lua.set_string("bad arguments");
        return 2;
    }
    if (!g_preCallbackRegistered) {
        g_preCallbackRegistered = true;
        RC::Unreal::Hook::RegisterProcessEventPreCallback(&OnProcessEvent);
        tc::Log("ProcessEvent pre-callback registered");
    }
    const int count = g_watchCount.load();
    for (int i = 0; i < count; ++i) {
        if (g_watchFns[i].load() == function) {
            lua.set_bool(true);
            lua.set_string("");
            return 2;
        }
    }
    if (count >= kMaxWatched) {
        lua.set_bool(false);
        lua.set_string("too many watched functions");
        return 2;
    }
    g_watchFns[count].store(function);
    g_watchSizes[count].store(size);
    g_watchCount.store(count + 1, std::memory_order_release);
    lua.set_bool(true);
    lua.set_string("");
    return 2;
}

// Hit guard: our player's hits on the partner's character are refused. Every hit a character takes is first put to
// its HitComponent's BPE_ValidateHit(FHitResult, FHitRequest) -> bool (a native event, so it goes through
// ProcessEvent); after it ran, if the target is the guarded HitComponent and the request's instigator is our player,
// its answer becomes false. Enemies' hits on the partner's character are untouched.
// (Sifu 1.28: FHitRequest at parameter offset 0x90, its m_Instigator weak pointer at +0xE4 (object index first),
// ReturnValue at 0x4E0; UObject::InternalIndex at +0xC.)
constexpr size_t kValidateRequest = 0x90, kRequestInstigator = 0xE4, kValidateReturn = 0x4E0, kObjectIndex = 0xC;
std::atomic<void*> g_guardFn{nullptr}, g_guardTarget{nullptr};
std::atomic<int32_t> g_guardAttacker{-1};
std::atomic<long long> g_guardBlocked{0}, g_guardSeen{0}, g_guardCalls{0};
bool g_postCallbackRegistered = false;

void GuardCheck(RC::Unreal::UObject* context, RC::Unreal::UFunction* function, void* parms) {
    if (!parms || function != g_guardFn.load(std::memory_order_relaxed)) return;
    g_guardCalls.fetch_add(1, std::memory_order_relaxed);
    if (context != g_guardTarget.load(std::memory_order_relaxed)) return;
    g_guardSeen.fetch_add(1, std::memory_order_relaxed);
    auto* p = static_cast<unsigned char*>(parms);
    int32_t instigator = -1;
    memcpy(&instigator, p + kValidateRequest + kRequestInstigator, sizeof instigator);
    const int32_t attacker = g_guardAttacker.load(std::memory_order_relaxed);
    if (attacker >= 0 && instigator == attacker && p[kValidateReturn] != 0) {
        p[kValidateReturn] = 0;
        g_guardBlocked.fetch_add(1, std::memory_order_relaxed);
    }
}

void OnProcessEventPost(RC::Unreal::UObject* context, RC::Unreal::UFunction* function, void* parms) {
    __try {
        GuardCheck(context, function, parms);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
}

// TailCoop_GuardHits(validateFn, targetHitComponent, attackerObject) -> ok. All "0": guard off.
int LGuardHits(const Lua& lua) {
    void* fn = reinterpret_cast<void*>(ToAddress(Arg(lua)));
    void* target = reinterpret_cast<void*>(ToAddress(Arg(lua)));
    const uintptr_t attacker = ToAddress(Arg(lua));
    int32_t index = -1;
    if (attacker && !SafeRead(attacker + kObjectIndex, &index, sizeof index)) {
        lua.set_bool(false);
        return 1;
    }
    if (!g_postCallbackRegistered && fn) {
        g_postCallbackRegistered = true;
        RC::Unreal::Hook::RegisterProcessEventPostCallback(&OnProcessEventPost);
        tc::Log("ProcessEvent post-callback registered (hit guard)");
    }
    g_guardAttacker.store(index);
    g_guardTarget.store(target);
    g_guardFn.store(fn);
    lua.set_bool(true);
    return 1;
}

// TailCoop_GuardStats() -> hits validated on the guarded target, hits refused, hits validated on anyone
int LGuardStats(const Lua& lua) {
    lua.set_integer(g_guardSeen.load());
    lua.set_integer(g_guardBlocked.load());
    lua.set_integer(g_guardCalls.load());
    return 3;
}

// Is a UObject still alive at this address? Lua keeps references to game objects across frames; once the engine has
// destroyed and garbage-collected one, even UE4SS's IsValid reads freed memory (its index field) and crashes on the
// garbage (read at 0xffffffffffffffff, seen in Arena challenges). Here: the index is read under SEH and the engine's
// object array must still hold this very address at that index, not marked pending kill / unreachable.
constexpr uintptr_t kObjObjects = 0x10;     // FUObjectArray::ObjObjects (TUObjectArray)
constexpr uintptr_t kNumElements = 0x14;    // TUObjectArray::NumElements
constexpr uintptr_t kItemSize = 0x18;       // FUObjectItem: Object, Flags, ClusterRootIndex, SerialNumber
constexpr int32_t kChunkElements = 64 * 1024;
constexpr int32_t kPendingKill = 1 << 29, kUnreachable = 1 << 28;  // EInternalObjectFlags

bool ObjectLive(uintptr_t object) {
    static const uintptr_t array = reinterpret_cast<uintptr_t>(RC::Unreal::FUObjectArray::GetGUObjectArrayAddress());
    if (!array || object < 0x10000) return false;
    int32_t index = -1, numElements = 0;
    uintptr_t chunks = 0, chunk = 0;
    if (!SafeRead(object + kObjectIndex, &index, sizeof index) || index < 0) return false;
    if (!SafeRead(array + kObjObjects, &chunks, sizeof chunks) || !chunks) return false;
    if (!SafeRead(array + kObjObjects + kNumElements, &numElements, sizeof numElements) || index >= numElements) return false;
    if (!SafeRead(chunks + static_cast<uintptr_t>(index / kChunkElements) * sizeof(uintptr_t), &chunk, sizeof chunk) || !chunk) {
        return false;
    }
    struct {
        uintptr_t object;
        int32_t flags;
    } item{};
    if (!SafeRead(chunk + static_cast<uintptr_t>(index % kChunkElements) * kItemSize, &item, 12)) return false;
    return item.object == object && (item.flags & (kPendingKill | kUnreachable)) == 0;
}

// TailCoop_Live(address) -> bool
int LLive(const Lua& lua) {
    lua.set_bool(ObjectLive(ToAddress(Arg(lua))));
    return 1;
}

// TailCoop_ObjectCount() -> number of slots in use in the engine's object array (lab sanity check of the layout).
int LObjectCount(const Lua& lua) {
    const uintptr_t array = reinterpret_cast<uintptr_t>(RC::Unreal::FUObjectArray::GetGUObjectArrayAddress());
    int32_t n = -1;
    if (array) SafeRead(array + kObjObjects + kNumElements, &n, sizeof n);
    lua.set_integer(n);
    return 1;
}

// TailCoop_PollCaptured() -> contextAddress, functionAddress, text | nil
int LPollCaptured(const Lua& lua) {
    Captured c;
    {
        std::lock_guard<std::mutex> lock(g_capturedMutex);
        if (g_captured.empty()) {
            lua.set_nil();
            return 1;
        }
        c = std::move(g_captured.front());
        g_captured.pop_front();
    }
    lua.set_integer(static_cast<long long>(c.context));
    lua.set_integer(static_cast<long long>(c.function));
    lua.set_string(c.text);
    return 3;
}

int ParmsSizeGuarded(RC::Unreal::UFunction* function) {
    __try {
        return function->GetParmsSize();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

// TailCoop_CallImported(objectAddress, functionAddress, text1, size1 [, text2, size2 ...]) -> ok, error, importWarnings
// Each text is imported into the function's next parameter (in declaration order); sizes guard against mismatches.
int LCallImported(const Lua& lua) {
    auto* object = reinterpret_cast<RC::Unreal::UObject*>(ToAddress(Arg(lua)));
    auto* function = reinterpret_cast<RC::Unreal::UFunction*>(ToAddress(Arg(lua)));
    std::wstring texts[kMaxImported];
    const wchar_t* textPtrs[kMaxImported] = {};
    int sizes[kMaxImported] = {};
    int count = 0;
    while (count < kMaxImported && lua.get_stack_size() >= 2) {
        texts[count] = Wide(Arg(lua));
        sizes[count] = ToInt(Arg(lua), -1);
        textPtrs[count] = texts[count].c_str();
        ++count;
    }
    if (!object || !function || count == 0) {
        lua.set_bool(false);
        lua.set_string("bad arguments");
        lua.set_integer(0);
        return 3;
    }
    if (!g_nullDevice.vtable) {
        for (void*& slot : g_nullDeviceVtable) slot = reinterpret_cast<void*>(&CountingNoop);
        g_nullDevice.vtable = g_nullDeviceVtable;
    }
    const int parmsSize = ParmsSizeGuarded(function);
    if (parmsSize <= 0 || parmsSize > 64 * 1024) {
        lua.set_bool(false);
        lua.set_string("bad parameter size " + std::to_string(parmsSize));
        lua.set_integer(0);
        return 3;
    }
    auto* params = static_cast<unsigned char*>(_aligned_malloc(parmsSize, 16));
    memset(params, 0, parmsSize);
    g_importWarnings = 0;
    int stage = 0;
    const int rc = CallGuarded(object, function, textPtrs, sizes, count, params, &stage);
    // After a crash mid-call the buffer may hold half-built values: leak it rather than free memory they point into.
    if (rc != 1) _aligned_free(params);
    static const char* kErrors[] = {"", "crashed (caught) at stage ", "parameter size mismatch", "text didn't import"};
    lua.set_bool(rc == 0);
    lua.set_string(rc == 0 ? "" : (std::string(kErrors[rc]) + (rc == 1 ? std::to_string(stage) : "")));
    lua.set_integer(g_importWarnings);
    return 3;
}
// Pose sync (pose.h) -------------------------------------------------------------------------------------------

// TailCoop_PoseInit(snapshotPoseFn, applyPoseFromSnapshotFn, getRefPosePositionFn) -> ok, error
int LPoseInit(const Lua& lua) {
    const uintptr_t a = ToAddress(Arg(lua)), b = ToAddress(Arg(lua)), c = ToAddress(Arg(lua));
    std::string error;
    lua.set_bool(tc::pose::Init(a, b, c, error));
    lua.set_string(error);
    return 2;
}

// TailCoop_PoseSend(meshAddress, id, clock [, "store"]) -> bytes | nil, error. "store": loopback instead of sending.
int LPoseSend(const Lua& lua) {
    const uintptr_t mesh = ToAddress(Arg(lua));
    const std::string id = Arg(lua);
    const auto clock = static_cast<uint32_t>(std::stoull("0" + Arg(lua, "0")) & 0xFFFFFFFFu);
    const bool send = Arg(lua, "send") != "store";
    std::string error;
    const size_t bytes = tc::pose::Capture(mesh, id, clock, send, error);
    if (bytes == 0) {
        lua.set_nil();
        lua.set_string(error);
        return 2;
    }
    lua.set_integer(static_cast<long long>(bytes));
    return 1;
}

// TailCoop_PoseApply(poseableAddress, templateMeshAddress, id, renderClock) -> status, ageMs
int LPoseApply(const Lua& lua) {
    const uintptr_t poseable = ToAddress(Arg(lua)), templ = ToAddress(Arg(lua));
    const std::string id = Arg(lua);
    const auto clock = static_cast<uint32_t>(std::stoull("0" + Arg(lua, "0")) & 0xFFFFFFFFu);
    int age = 0;
    lua.set_string(tc::pose::Apply(poseable, templ, id, clock, &age));
    lua.set_integer(age);
    return 2;
}

int LPoseForget(const Lua& lua) {
    tc::pose::Forget(ToAddress(Arg(lua)));
    return 0;
}

int LPoseStats(const Lua& lua) {
    lua.set_string(tc::pose::Stats());
    return 1;
}

// TailCoop_Place(actor, K2_SetActorLocationAndRotation, x, y, z, yaw) -> ok, microseconds in the engine (on failure:
// -1 bad arguments, or minus the function's parameter size)
// Moves a copy every frame (teleport, no sweep) with one ProcessEvent. The parameter block is laid out here
// (AActor::K2_SetActorLocationAndRotation, UE 4.26: NewLocation 0x0, NewRotation 0xC, bSweep 0x18,
// SweepHitResult 0x1C, bTeleport 0xA8, ReturnValue 0xA9) instead of UE4SS building it from Lua tables and converting
// the hit result back (~90 us a call). The function's parameter size is checked once: UE counts it up to the end of
// the last parameter (ReturnValue at 0xA9 -> 0xAA), without trailing padding.
constexpr int kPlaceParmsSize = 0xAA;
constexpr int kPlaceBufferSize = 0xB0;

int PlaceGuarded(RC::Unreal::UObject* actor, RC::Unreal::UFunction* function, unsigned char* params) {
    __try {
        actor->ProcessEvent(function, params);
        return 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

float ToFloat(const std::string& s) {
    try {
        return s.empty() ? 0.0f : std::stof(s);
    } catch (...) {
        return 0.0f;
    }
}

int LPlace(const Lua& lua) {
    static RC::Unreal::UFunction* checked = nullptr;
    auto* actor = reinterpret_cast<RC::Unreal::UObject*>(ToAddress(Arg(lua)));
    auto* function = reinterpret_cast<RC::Unreal::UFunction*>(ToAddress(Arg(lua)));
    float location[3], rotation[3] = {0.0f, 0.0f, 0.0f};
    for (float& v : location) v = ToFloat(Arg(lua));
    rotation[1] = ToFloat(Arg(lua));
    if (!actor || !function) {
        lua.set_bool(false);
        lua.set_integer(-1);
        return 2;
    }
    if (function != checked) {
        const int size = ParmsSizeGuarded(function);
        if (size != kPlaceParmsSize) {
            lua.set_bool(false);
            lua.set_integer(-size);  // a wrong function: its parameter size, negated
            return 2;
        }
        checked = function;
    }
    alignas(16) unsigned char params[kPlaceBufferSize] = {};
    memcpy(params, location, sizeof location);
    memcpy(params + 0xC, rotation, sizeof rotation);
    params[0xA8] = 1;  // bTeleport
    const auto t0 = std::chrono::steady_clock::now();
    const bool ok = PlaceGuarded(actor, function, params) == 0;
    const auto us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0);
    lua.set_bool(ok);
    lua.set_integer(static_cast<long long>(us.count()));  // time spent in the engine's move
    return 2;
}

// TailCoop_ReadAnim(animInstance, subInstance...) -> "tracks|last|subs": everything tc_anim's action watcher needs from
// a UPlayerAnim and its order sub-instances (GenericPlayAnimBP_C : UPlayAnimSubAnimInstance) in one call, instead of
// ~50 single reads (offsets: game 1.28, see tc_anim.lua).
//   tracks: "k,animPtr,order,mirror,startRatio,rate;" per in-progress swapper track, k = struct*2 + slot + 1
//   last:   "animPtr,mirror,cursorRatio"
//   subs:   "animPtr,order,alpha,mirror,startRatio,rate;" per sub-instance given (animPtr 0 if unreadable)
bool CopyGuarded(uintptr_t from, void* to, size_t size) {
    __try {
        memcpy(to, reinterpret_cast<const void*>(from), size);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

template <typename T>
T At(const unsigned char* block, size_t offset) {
    T v;
    memcpy(&v, block + offset, sizeof v);
    return v;
}

int LReadAnim(const Lua& lua) {
    constexpr uint32_t kFirst = 0x940, kLast = 0xE78;  // m_AttackStruct .. m_fLastActionAnimCursor
    static const uint32_t kStructs[] = {0x940, 0xBA0, 0xC40, 0xDD0, 0xF20};
    const uintptr_t inst = ToAddress(Arg(lua));
    uintptr_t subs[16];
    int nSubs = 0;
    while (lua.get_stack_size() >= 1 && nSubs < 16) subs[nSubs++] = ToAddress(Arg(lua));
    while (lua.get_stack_size() >= 1) lua.discard_value(1);

    std::string out;
    out.reserve(256);
    char buf[128];
    static unsigned char block[0x1000];
    const bool okInst = inst >= 0x10000 && CopyGuarded(inst + kFirst, block, 0xFB0 - kFirst);
    if (okInst) {
        for (int s = 0; s < 5; ++s) {
            for (int n = 0; n < 2; ++n) {
                const size_t base = kStructs[s] - kFirst;
                if (!block[base + 0x51 + n]) continue;
                const size_t c = base + (n == 0 ? 0x58 : 0x70);
                const auto anim = At<uint64_t>(block, c);
                if (!anim) continue;
                snprintf(buf, sizeof buf, "%d,%llu,%u,%u,%.3f,%.3f;", s * 2 + n + 1,
                         static_cast<unsigned long long>(anim), block[c + 0x10], block[c + 8] ? 1u : 0u,
                         At<float>(block, c + 0xC), At<float>(block, c + 0x14));
                out += buf;
            }
        }
    }
    out += '|';
    if (okInst) {
        snprintf(buf, sizeof buf, "%llu,%u,%.3f",
                 static_cast<unsigned long long>(At<uint64_t>(block, 0xE68 - kFirst)), block[0xE70 - kFirst] ? 1u : 0u,
                 At<float>(block, 0xE74 - kFirst));
        out += buf;
    }
    (void)kLast;
    out += '|';
    for (int i = 0; i < nSubs; ++i) {
        unsigned char sub[0x30];
        if (subs[i] >= 0x10000 && CopyGuarded(subs[i] + 0x630, sub, sizeof sub)) {
            snprintf(buf, sizeof buf, "%llu,%u,%.3f,%u,%.3f,%.3f;", static_cast<unsigned long long>(At<uint64_t>(sub, 0)),
                     sub[0x24], At<float>(sub, 0x28), sub[8] ? 1u : 0u, At<float>(sub, 0xC), At<float>(sub, 0x14));
            out += buf;
        } else {
            out += "0,0,0,0,0,1;";
        }
    }
    lua.set_string(out);
    return 1;
}

// TailCoop_ClockUs() -> microseconds on a steady clock (profiling).
int LClockUs(const Lua& lua) {
    using namespace std::chrono;
    lua.set_integer(duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count());
    return 1;
}

// "windows", or "wine <version>" under Wine / CrossOver (ntdll then exports wine_get_version).
std::string Platform() {
    using WineVersion = const char*(__cdecl*)();
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    auto* version = ntdll ? reinterpret_cast<WineVersion>(GetProcAddress(ntdll, "wine_get_version")) : nullptr;
    return version ? std::string("wine ") + version() : "windows";
}

// TailCoop_Diagnostics() -> one line for the log
int LDiagnostics(const Lua& lua) {
    const std::string tailnet = tc::TailnetAdapterIp();
    lua.set_string(std::string(kNativeVersion) + " identity=" + tc::Identity() + " processevent=" + CheckProcessEvent() +
                   " platform=" + Platform() + " tailnet-adapter=" + (tailnet.empty() ? "none" : tailnet) + " | " +
                   g_engineFixes);
    return 1;
}

}  // namespace

extern "C" __declspec(dllexport) int luaopen_tailcoopnative(lua_State* state) {
    tc::SetIdentity(ComputeIdentity());
    g_engineFixes = tc::ApplyEngineFixes();
    tc::Log("%s", g_engineFixes.c_str());
    Lua lua(state);
    struct Entry {
        const char* name;
        int (*fn)(const Lua&);
    };
    const Entry entries[] = {
        {"TailCoop_Host", LHost},     {"TailCoop_Join", LJoin},     {"TailCoop_Leave", LLeave},
        {"TailCoop_Send", LSend},     {"TailCoop_Poll", LPoll},     {"TailCoop_Status", LStatus},
        {"TailCoop_Peers", LPeers},   {"TailCoop_Diagnostics", LDiagnostics}, {"TailCoop_Simulate", LSimulate},
        {"TailCoop_Clock", LClock},   {"TailCoop_Peek", LPeek},     {"TailCoop_ObjectPath", LObjectPath},
        {"TailCoop_PokeFloats", LPokeFloats}, {"TailCoop_ExportParam", LExportParam},
        {"TailCoop_CallImported", LCallImported}, {"TailCoop_WatchParam", LWatchParam},
        {"TailCoop_PollCaptured", LPollCaptured}, {"TailCoop_PoseInit", LPoseInit},
        {"TailCoop_PoseSend", LPoseSend},         {"TailCoop_PoseApply", LPoseApply},
        {"TailCoop_PoseForget", LPoseForget},     {"TailCoop_PoseStats", LPoseStats},
        {"TailCoop_ClockUs", LClockUs},           {"TailCoop_ReadAnim", LReadAnim},
        {"TailCoop_Place", LPlace},               {"TailCoop_PokeU8", LPokeU8},
        {"TailCoop_GuardHits", LGuardHits},       {"TailCoop_GuardStats", LGuardStats},
        {"TailCoop_Live", LLive},                 {"TailCoop_ObjectCount", LObjectCount},
    };
    for (const Entry& e : entries) {
        lua.register_function(e.name, e.fn);
    }
    tc::TailscalePeers();  // start the first refresh early
    tc::Log("lua functions registered (%s, identity %s, ProcessEvent %s)", kNativeVersion, tc::Identity().c_str(),
            CheckProcessEvent().c_str());
    return 0;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        tc::InitLog(module);
        tc::Log("TailCoopNative loaded");
    }
    return TRUE;
}
