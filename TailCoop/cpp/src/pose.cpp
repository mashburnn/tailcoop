#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include "pose.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <cwctype>
#include <deque>
#include <unordered_map>
#include <vector>

#include "log.h"
#include "transport.h"
#include "ue4ss_api.h"

namespace tc::pose {
namespace {

using RC::Unreal::FProperty;
using RC::Unreal::UFunction;
using RC::Unreal::UObject;

// Engine memory layouts (UE 4.26, x64, vectorized FTransform).
struct TArrayRaw {
    void* data;
    int32_t num;
    int32_t max;
};
constexpr int kTransformSize = 48;  // FQuat (16) + translation (16) + scale (16)
constexpr int kSnapshotOffsetNames = 0x10;
constexpr int kSnapshotOffsetValid = 0x30;
constexpr int kParmsBuffer = 0x60;  // >= SnapshotPose (0x38) and ApplyPoseFromSnapshot (0x40) parameters
constexpr int kMaxBones = 512;
constexpr int kRotationsPerPart = 230;
constexpr float kTransStep = 0.05f;   // cm per unit of the 16-bit translation
constexpr float kTransSendThreshold = 0.25f;

UFunction* g_snapshotFn = nullptr;
UFunction* g_applyFn = nullptr;
UFunction* g_refPoseFn = nullptr;
FProperty* g_snapshotParam = nullptr;  // SnapshotPose's FPoseSnapshot parameter (constructs/destroys buffers)

struct Skeleton {
    int num = 0;
    std::vector<int> listed;                  // bone indices sent / applied, in bone order
    std::vector<std::array<float, 3>> ref;    // reference local translation per listed bone
    uint32_t hash = 0;
    std::vector<uint32_t> lastSent;           // sender: rotations as last sent (deltas are against these)
    int sinceKey = 0;
};

using TransList = std::vector<std::pair<uint16_t, std::array<int16_t, 3>>>;

// A full pose at one sender time (rotations of every listed bone, packed).
struct Pose {
    uint32_t clock = 0;
    uint32_t hash = 0;
    int total = 0;
    std::vector<uint32_t> rot;
    TransList trans;
    bool complete() const { return total > 0; }
};

// What the receiver knows of one sender: messages only carry the bones that changed, applied onto `cur`.
struct Stream {
    uint32_t hash = 0;
    int total = 0;
    std::vector<uint32_t> cur;
    std::vector<uint8_t> have;
    int haveCount = 0;
    bool started = false;
    uint32_t lastClock = 0;
    TransList trans;
    std::deque<Pose> snaps;  // oldest first
};
struct Target {
    unsigned char* buffer = nullptr;  // persistent FPoseSnapshot (+ return value) for ApplyPoseFromSnapshot
    uintptr_t templateMesh = 0;
    Skeleton skel;
};

std::unordered_map<uintptr_t, Skeleton> g_senders;
std::unordered_map<uintptr_t, Target> g_targets;
std::unordered_map<std::string, Stream> g_streams;

struct Counters {
    uint64_t captured = 0, bytes = 0, bonesSent = 0, keyframes = 0, partsIn = 0, posesIn = 0, applied = 0, mismatch = 0,
             errors = 0;
} g_count;

FProperty* FirstParam(UFunction* fn) {
    return reinterpret_cast<FProperty*>(reinterpret_cast<RC::Unreal::UStruct*>(fn)->GetChildProperties());
}

// --- guarded engine calls (no C++ objects with destructors in here) ----------------------------------------

// Snapshot of `mesh` into plain arrays. Returns the bone count, 0 if the snapshot isn't valid, -1 on a crash.
int SnapshotGuarded(UObject* mesh, float (*q)[4], float (*t)[3], uint64_t* names) {
    alignas(16) unsigned char parms[kParmsBuffer];
    memset(parms, 0, sizeof parms);
    __try {
        g_snapshotParam->InitializeValue(parms);
        mesh->ProcessEvent(g_snapshotFn, parms);
        const auto* lt = reinterpret_cast<const TArrayRaw*>(parms);
        const auto* bn = reinterpret_cast<const TArrayRaw*>(parms + kSnapshotOffsetNames);
        int n = 0;
        if (parms[kSnapshotOffsetValid] && lt->num == bn->num && lt->num > 0 && lt->num <= kMaxBones) {
            n = lt->num;
            const auto* d = static_cast<const unsigned char*>(lt->data);
            for (int i = 0; i < n; ++i) {
                memcpy(q[i], d + i * kTransformSize, 16);
                memcpy(t[i], d + i * kTransformSize + 16, 12);
            }
            memcpy(names, bn->data, sizeof(uint64_t) * n);
        }
        g_snapshotParam->DestroyValue(parms);
        return n;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

bool RefPoseGuarded(UObject* mesh, int boneIndex, float out[3]) {
    alignas(16) unsigned char parms[32];
    memset(parms, 0, sizeof parms);
    memcpy(parms, &boneIndex, 4);
    __try {
        mesh->ProcessEvent(g_refPoseFn, parms);
        memcpy(out, parms + 4, 12);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Fills a persistent buffer with `mesh`'s current snapshot (all bones, engine-allocated arrays).
bool TemplateGuarded(UObject* mesh, unsigned char* buffer) {
    __try {
        g_snapshotParam->InitializeValue(buffer);
        mesh->ProcessEvent(g_snapshotFn, buffer);
        return buffer[kSnapshotOffsetValid] != 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ApplyGuarded(UObject* poseable, unsigned char* buffer) {
    __try {
        poseable->ProcessEvent(g_applyFn, buffer);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

void DestroyGuarded(unsigned char* buffer) {
    __try {
        g_snapshotParam->DestroyValue(buffer);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
}

// --- skeleton ------------------------------------------------------------------------------------------------

std::wstring Lower(std::wstring s) {
    for (auto& c : s) c = static_cast<wchar_t>(std::towlower(c));
    return s;
}

// IK targets, camera and VFX helpers aren't skinned: not worth sending.
bool IsListed(const std::wstring& lower) {
    return lower.find(L"_ik") == std::wstring::npos && lower.rfind(L"ik_", 0) != 0 &&
           lower.find(L"cam_joint") == std::wstring::npos && lower.find(L"vfx") == std::wstring::npos &&
           lower.find(L"capsule") == std::wstring::npos;
}

bool BuildSkeleton(UObject* mesh, int num, const uint64_t* names, Skeleton& out) {
    out = Skeleton{};
    out.num = num;
    uint32_t hash = 2166136261u;
    for (int i = 0; i < num; ++i) {
        uint64_t raw = names[i];
        const std::wstring name = Lower(reinterpret_cast<RC::Unreal::FName*>(&raw)->ToString());
        if (!IsListed(name)) continue;
        std::array<float, 3> ref{};
        if (!RefPoseGuarded(mesh, i, ref.data())) return false;
        out.listed.push_back(i);
        out.ref.push_back(ref);
        for (wchar_t c : name) hash = (hash ^ static_cast<uint32_t>(c)) * 16777619u;
        hash = (hash ^ 0x7Cu) * 16777619u;
    }
    out.hash = hash;
    return !out.listed.empty();
}

// --- quaternion packing ----------------------------------------------------------------------------------------

constexpr float kRange = 0.70710678f;

uint32_t PackQuat(const float in[4]) {
    float q[4] = {in[0], in[1], in[2], in[3]};
    const float len = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (len < 1e-6f) return 3u << 30;  // identity
    for (float& c : q) c /= len;
    int m = 0;
    for (int i = 1; i < 4; ++i) {
        if (std::fabs(q[i]) > std::fabs(q[m])) m = i;
    }
    if (q[m] < 0) {
        for (float& c : q) c = -c;
    }
    uint32_t out = static_cast<uint32_t>(m) << 30;
    int shift = 20;
    for (int i = 0; i < 4; ++i) {
        if (i == m) continue;
        const float n = std::clamp(q[i] / kRange, -1.0f, 1.0f);
        const uint32_t v = static_cast<uint32_t>(std::lround((n + 1.0f) * 0.5f * 1023.0f));
        out |= (v & 1023u) << shift;
        shift -= 10;
    }
    return out;
}

void UnpackQuat(uint32_t v, float q[4]) {
    const int m = static_cast<int>(v >> 30);
    int shift = 20;
    float sum = 0;
    for (int i = 0; i < 4; ++i) {
        if (i == m) continue;
        const float c = ((static_cast<float>((v >> shift) & 1023u) / 1023.0f) * 2.0f - 1.0f) * kRange;
        q[i] = c;
        sum += c * c;
        shift -= 10;
    }
    q[m] = std::sqrt(std::max(0.0f, 1.0f - sum));
}

void Nlerp(const float a[4], const float b[4], float alpha, float out[4]) {
    const float dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    const float sb = dot < 0 ? -1.0f : 1.0f;
    float len = 0;
    for (int i = 0; i < 4; ++i) {
        out[i] = a[i] * (1 - alpha) + b[i] * sb * alpha;
        len += out[i] * out[i];
    }
    len = std::sqrt(len);
    if (len > 1e-6f) {
        for (int i = 0; i < 4; ++i) out[i] /= len;
    }
}

int16_t QuantTrans(float v) {
    return static_cast<int16_t>(std::clamp(std::lround(v / kTransStep), -32767L, 32767L));
}

template <typename T>
void Put(std::string& s, T v) {
    s.append(reinterpret_cast<const char*>(&v), sizeof v);
}

template <typename T>
bool Get(const std::string& s, size_t& at, T& v) {
    if (at + sizeof v > s.size()) return false;
    memcpy(&v, s.data() + at, sizeof v);
    at += sizeof v;
    return true;
}

// Packed rotations differ by more than quantization noise (1 step of any component, or another largest component).
bool Differs(uint32_t a, uint32_t b) {
    if ((a >> 30) != (b >> 30)) return true;
    for (int shift = 0; shift <= 20; shift += 10) {
        const int da = static_cast<int>((a >> shift) & 1023u) - static_cast<int>((b >> shift) & 1023u);
        if (da > 1 || da < -1) return true;
    }
    return false;
}

// One received message: its bones go into the sender's stream; once the stream knows every bone, the result is
// kept as the pose at this message's time.
void Ingest(const std::string& id, uint32_t clock, uint32_t hash, int total, bool key, bool hasTrans,
            TransList&& trans, int start, int count, const uint8_t* mask, const uint32_t* rot, int nRot) {
    if (total <= 0 || total > kMaxBones || start < 0 || start + count > total) return;
    ++g_count.partsIn;
    Stream& s = g_streams[id];
    if (s.hash != hash || s.total != total) {
        s = Stream{};
        s.hash = hash;
        s.total = total;
        s.cur.assign(total, 0);
        s.have.assign(total, 0);
    }
    // Late packets (unreliable channel): never step back in time.
    if (s.started && static_cast<int32_t>(clock - s.lastClock) < 0) return;
    s.started = true;
    s.lastClock = clock;
    int k = 0;
    for (int i = 0; i < count && k < nRot; ++i) {
        if (!key && !(mask[i >> 3] & (1u << (i & 7)))) continue;
        const int b = start + i;
        s.cur[b] = rot[k++];
        if (!s.have[b]) {
            s.have[b] = 1;
            ++s.haveCount;
        }
    }
    if (hasTrans) s.trans = std::move(trans);
    if (s.haveCount < total) return;
    Pose* p = s.snaps.empty() || s.snaps.back().clock != clock ? nullptr : &s.snaps.back();
    if (!p) {
        s.snaps.push_back(Pose{});
        p = &s.snaps.back();
        p->clock = clock;
        ++g_count.posesIn;
        while (s.snaps.size() > 8) s.snaps.pop_front();
    }
    p->hash = hash;
    p->total = total;
    p->rot = s.cur;
    p->trans = s.trans;
}
float g_q[kMaxBones][4];
float g_t[kMaxBones][3];
uint64_t g_names[kMaxBones];

}  // namespace

bool Init(uintptr_t snapshotFn, uintptr_t applyFn, uintptr_t refPoseFn, std::string& error) {
    if (!snapshotFn || !applyFn || !refPoseFn) {
        error = "missing function";
        return false;
    }
    g_snapshotFn = reinterpret_cast<UFunction*>(snapshotFn);
    g_applyFn = reinterpret_cast<UFunction*>(applyFn);
    g_refPoseFn = reinterpret_cast<UFunction*>(refPoseFn);
    g_snapshotParam = FirstParam(g_snapshotFn);
    if (!g_snapshotParam || g_snapshotParam->GetSize() != 0x38) {
        error = "unexpected SnapshotPose parameter";
        g_snapshotFn = nullptr;
        return false;
    }
    return true;
}

size_t Capture(uintptr_t meshAddr, const std::string& id, uint32_t clock, bool send, std::string& error) {
    if (!g_snapshotFn) {
        error = "not initialized";
        return 0;
    }
    if (id.empty() || id.size() > 200) {
        error = "bad id";
        return 0;
    }
    auto* mesh = reinterpret_cast<UObject*>(meshAddr);
    const int n = SnapshotGuarded(mesh, g_q, g_t, g_names);
    if (n <= 0) {
        error = n < 0 ? "snapshot crashed (caught)" : "no valid pose";
        ++g_count.errors;
        return 0;
    }
    Skeleton& skel = g_senders[meshAddr];
    if (skel.num != n) {
        if (!BuildSkeleton(mesh, n, g_names, skel)) {
            g_senders.erase(meshAddr);
            error = "skeleton unreadable";
            return 0;
        }
        tc::Log("pose: sender skeleton %zu of %d bones listed, hash %08X", skel.listed.size(), n, skel.hash);
    }
    const int total = static_cast<int>(skel.listed.size());
    std::vector<uint32_t> rot(total);
    TransList trans;
    for (int i = 0; i < total; ++i) {
        const int b = skel.listed[i];
        rot[i] = PackQuat(g_q[b]);
        const auto& r = skel.ref[i];
        const float dx = g_t[b][0] - r[0], dy = g_t[b][1] - r[1], dz = g_t[b][2] - r[2];
        if (trans.size() < 20 && dx * dx + dy * dy + dz * dz > kTransSendThreshold * kTransSendThreshold) {
            trans.push_back({static_cast<uint16_t>(i),
                             {QuantTrans(g_t[b][0]), QuantTrans(g_t[b][1]), QuantTrans(g_t[b][2])}});
        }
    }
    // Only bones that changed since they were last sent; every 15th pose (~0.5 s) all of them, which also repairs
    // whatever a lost packet left stale on the other side.
    const bool key = skel.lastSent.size() != rot.size() || ++skel.sinceKey >= 15;
    if (key) {
        skel.lastSent = rot;
        skel.sinceKey = 0;
    }
    std::vector<uint8_t> changed(total, key ? 1 : 0);
    int nChanged = key ? total : 0;
    if (!key) {
        for (int i = 0; i < total; ++i) {
            if (Differs(rot[i], skel.lastSent[i])) {
                changed[i] = 1;
                skel.lastSent[i] = rot[i];
                ++nChanged;
            }
        }
    }
    const size_t header = 2 + 1 + id.size() + 4 + 4 + 2 + 1 + 1 + 2 + 2;
    size_t bytes = 0;
    int start = 0;
    bool first = true;
    do {
        // Greedy part: as many bones as fit (mask bit each, 4 bytes per changed one).
        const size_t transBytes = first ? trans.size() * 8 : 0;
        size_t used = header + transBytes;
        int end = start;
        while (end < total) {
            const size_t extra = ((end - start) % 8 == 0 ? 1 : 0) + (changed[end] ? 4 : 0);
            if (used + extra > tc::kMaxPayload) break;
            used += extra;
            ++end;
        }
        std::string msg;
        msg.push_back(kMagic);
        msg.push_back('Q');
        msg.push_back(static_cast<char>(id.size()));
        msg += id;
        Put(msg, clock);
        Put(msg, skel.hash);
        Put(msg, static_cast<uint16_t>(total));
        msg.push_back(static_cast<char>((key ? 1 : 0) | (first ? 2 : 0)));
        msg.push_back(static_cast<char>(first ? trans.size() : 0));
        if (first) {
            for (const auto& t : trans) {
                Put(msg, t.first);
                for (int16_t v : t.second) Put(msg, v);
            }
        }
        Put(msg, static_cast<uint16_t>(start));
        Put(msg, static_cast<uint16_t>(end - start));
        std::string mask((end - start + 7) / 8, '\0');
        for (int i = start; i < end; ++i) {
            if (changed[i]) mask[(i - start) >> 3] |= static_cast<char>(1u << ((i - start) & 7));
        }
        msg += mask;
        for (int i = start; i < end; ++i) {
            if (changed[i]) Put(msg, rot[i]);
        }
        if (send) {
            if (!tc::Send(tc::kUnreliable, msg, error)) return 0;
        } else {
            Receive(msg);
        }
        bytes += msg.size();
        start = end;
        first = false;
    } while (start < total);
    ++g_count.captured;
    g_count.bytes += bytes;
    g_count.bonesSent += static_cast<uint64_t>(nChanged);
    if (key) ++g_count.keyframes;
    return bytes;
}

void Receive(const std::string& payload) {
    size_t at = 2;
    if (payload.size() < 3 || payload[0] != kMagic || payload[1] != 'Q') return;
    const auto idLen = static_cast<uint8_t>(payload[at++]);
    if (at + idLen > payload.size()) return;
    const std::string id = payload.substr(at, idLen);
    at += idLen;
    uint32_t clock = 0, hash = 0;
    uint16_t total = 0, start = 0, count = 0;
    uint8_t flags = 0, nTrans = 0;
    if (!Get(payload, at, clock) || !Get(payload, at, hash) || !Get(payload, at, total) || !Get(payload, at, flags) ||
        !Get(payload, at, nTrans)) {
        return;
    }
    TransList trans(nTrans);
    for (auto& t : trans) {
        if (!Get(payload, at, t.first) || !Get(payload, at, t.second[0]) || !Get(payload, at, t.second[1]) ||
            !Get(payload, at, t.second[2])) {
            return;
        }
    }
    if (!Get(payload, at, start) || !Get(payload, at, count)) return;
    const size_t maskBytes = (static_cast<size_t>(count) + 7) / 8;
    if (at + maskBytes > payload.size()) return;
    const auto* mask = reinterpret_cast<const uint8_t*>(payload.data() + at);
    at += maskBytes;
    const bool key = (flags & 1) != 0;
    int expected = 0;
    for (int i = 0; i < count; ++i) {
        if (key || (mask[i >> 3] & (1u << (i & 7)))) ++expected;
    }
    if (at + static_cast<size_t>(expected) * 4 != payload.size()) return;
    std::vector<uint32_t> rot(expected);
    if (expected > 0) memcpy(rot.data(), payload.data() + at, static_cast<size_t>(expected) * 4);
    Ingest(id, clock, hash, total, key, (flags & 2) != 0, std::move(trans), start, count, mask, rot.data(), expected);
}
std::string Apply(uintptr_t poseableAddr, uintptr_t templateMesh, const std::string& id, uint32_t renderClock,
                  int* ageMs) {
    *ageMs = 0;
    if (!g_snapshotFn) return "not initialized";
    auto found = g_streams.find(id);
    const Pose* newest = nullptr;
    if (found != g_streams.end()) {
        for (const auto& p : found->second.snaps) {
            if (p.complete()) newest = &p;
        }
    }
    if (!newest) return "none";
    *ageMs = static_cast<int32_t>(renderClock - newest->clock);

    Target& tgt = g_targets[poseableAddr];
    if (!tgt.buffer || tgt.templateMesh != templateMesh) {
        if (tgt.buffer) {
            DestroyGuarded(tgt.buffer);
            _aligned_free(tgt.buffer);
        }
        tgt = Target{};
        tgt.buffer = static_cast<unsigned char*>(_aligned_malloc(kParmsBuffer, 16));
        memset(tgt.buffer, 0, kParmsBuffer);
        tgt.templateMesh = templateMesh;
        if (!TemplateGuarded(reinterpret_cast<UObject*>(templateMesh), tgt.buffer)) {
            ++g_count.errors;
            return "template snapshot failed";
        }
        const auto* lt = reinterpret_cast<const TArrayRaw*>(tgt.buffer);
        const auto* bn = reinterpret_cast<const TArrayRaw*>(tgt.buffer + kSnapshotOffsetNames);
        if (lt->num != bn->num || lt->num <= 0 || lt->num > kMaxBones ||
            !BuildSkeleton(reinterpret_cast<UObject*>(templateMesh), lt->num, static_cast<const uint64_t*>(bn->data),
                           tgt.skel)) {
            tgt.skel = Skeleton{};
            return "template skeleton unreadable";
        }
        tc::Log("pose: target skeleton %zu of %d bones listed, hash %08X", tgt.skel.listed.size(), lt->num,
                tgt.skel.hash);
    }
    if (tgt.skel.listed.empty()) return "template skeleton unreadable";
    if (newest->hash != tgt.skel.hash || newest->total != static_cast<int>(tgt.skel.listed.size())) {
        ++g_count.mismatch;
        return "mismatch";
    }

    // Poses around renderClock (a <= renderClock <= b); past the newest: hold the newest.
    const Pose* a = nullptr;
    const Pose* b = nullptr;
    for (const auto& p : found->second.snaps) {
        if (!p.complete() || p.hash != newest->hash) continue;
        if (static_cast<int32_t>(p.clock - renderClock) <= 0) {
            a = &p;
        } else if (!b) {
            b = &p;
        }
    }
    if (!a) a = b;
    if (!b) b = a;
    float alpha = 0;
    if (a != b) alpha = static_cast<float>(static_cast<int32_t>(renderClock - a->clock)) /
                        static_cast<float>(std::max<int32_t>(1, static_cast<int32_t>(b->clock - a->clock)));
    alpha = std::clamp(alpha, 0.0f, 1.0f);

    auto transOf = [](const Pose* p, int listedIndex, float out[3]) {
        for (const auto& t : p->trans) {
            if (t.first == listedIndex) {
                for (int k = 0; k < 3; ++k) out[k] = t.second[k] * kTransStep;
                return true;
            }
        }
        return false;
    };

    auto* lt = reinterpret_cast<TArrayRaw*>(tgt.buffer);
    auto* data = static_cast<unsigned char*>(lt->data);
    const int total = static_cast<int>(tgt.skel.listed.size());
    for (int i = 0; i < total; ++i) {
        float qa[4], qb[4], q[4];
        UnpackQuat(a->rot[i], qa);
        UnpackQuat(b->rot[i], qb);
        Nlerp(qa, qb, alpha, q);
        float t[3] = {tgt.skel.ref[i][0], tgt.skel.ref[i][1], tgt.skel.ref[i][2]};
        float ta[3], tb[3];
        const bool hasA = transOf(a, i, ta), hasB = transOf(b, i, tb);
        if (hasA && hasB) {
            for (int k = 0; k < 3; ++k) t[k] = ta[k] + (tb[k] - ta[k]) * alpha;
        } else if (hasA || hasB) {
            memcpy(t, hasA ? ta : tb, sizeof t);
        }
        unsigned char* tr = data + tgt.skel.listed[i] * kTransformSize;
        memcpy(tr, q, 16);
        memcpy(tr + 16, t, 12);
    }
    if (!ApplyGuarded(reinterpret_cast<UObject*>(poseableAddr), tgt.buffer)) {
        ++g_count.errors;
        return "apply crashed (caught)";
    }
    ++g_count.applied;
    return "ok";
}

void Forget(uintptr_t component) {
    g_senders.erase(component);
    auto it = g_targets.find(component);
    if (it != g_targets.end()) {
        if (it->second.buffer) {
            DestroyGuarded(it->second.buffer);
            _aligned_free(it->second.buffer);
        }
        g_targets.erase(it);
    }
}

std::string Stats() {
    char buf[320];
    snprintf(buf, sizeof buf, "captured %llu (%llu bytes, %.0f bones/pose, %llu keyframes), parts in %llu, poses in %llu, applied %llu, mismatch %llu, errors %llu",
             static_cast<unsigned long long>(g_count.captured), static_cast<unsigned long long>(g_count.bytes),
             g_count.captured ? static_cast<double>(g_count.bonesSent) / g_count.captured : 0.0,
             static_cast<unsigned long long>(g_count.keyframes),
             static_cast<unsigned long long>(g_count.partsIn), static_cast<unsigned long long>(g_count.posesIn),
             static_cast<unsigned long long>(g_count.applied), static_cast<unsigned long long>(g_count.mismatch),
             static_cast<unsigned long long>(g_count.errors));
    return buf;
}

}  // namespace tc::pose
