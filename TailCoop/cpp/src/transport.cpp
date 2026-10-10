#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mstcpip.h>
#include <windows.h>

#include "transport.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <random>
#include <thread>
#include <vector>

#include "log.h"

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

namespace tc {
namespace {

using Clock = std::chrono::steady_clock;

int64_t NowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
}

constexpr uint32_t kMagic = 0x31434354;  // "TCC1"
constexpr uint16_t kProtocol = 1;
constexpr size_t kMaxPacket = 1200;  // below Tailscale's 1280 MTU
constexpr size_t kMaxInFlight = 256;
constexpr size_t kMaxQueuedReliable = 8192;
constexpr size_t kMaxQueuedUnreliable = 1024;
constexpr int64_t kPingIntervalMs = 250;
constexpr int64_t kKeepaliveMs = 100;
constexpr int64_t kTimeoutMs = 5000;
constexpr int64_t kHelloIntervalMs = 500;
constexpr int64_t kJoinTimeoutMs = 15000;

enum PacketType : uint8_t { kHello = 1, kWelcome, kReject, kData, kPing, kPong, kBye };

struct Writer {
    std::vector<uint8_t> b;
    void u8(uint8_t v) { b.push_back(v); }
    void u16(uint16_t v) { u8(uint8_t(v)); u8(uint8_t(v >> 8)); }
    void u32(uint32_t v) { u16(uint16_t(v)); u16(uint16_t(v >> 16)); }
    void u64(uint64_t v) { u32(uint32_t(v)); u32(uint32_t(v >> 32)); }
    void str(const std::string& s) {
        u16(uint16_t(s.size()));
        b.insert(b.end(), s.begin(), s.end());
    }
};

struct Reader {
    const uint8_t* p;
    size_t n;
    size_t i = 0;
    bool ok = true;
    bool need(size_t k) {
        if (i + k > n) ok = false;
        return ok;
    }
    uint8_t u8() { return need(1) ? p[i++] : 0; }
    uint16_t u16() { uint16_t lo = u8(); return uint16_t(lo | (uint16_t(u8()) << 8)); }
    uint32_t u32() { uint32_t lo = u16(); return lo | (uint32_t(u16()) << 16); }
    uint64_t u64() { uint64_t lo = u32(); return lo | (uint64_t(u32()) << 32); }
    std::string str() {
        uint16_t len = u16();
        if (!need(len)) return {};
        std::string s(reinterpret_cast<const char*>(p + i), len);
        i += len;
        return s;
    }
    bool done() const { return i >= n; }
};

struct Pending {
    std::string data;
    int64_t lastSent = 0;
    int sends = 0;
};

struct Session {
    std::mutex mu;
    SOCKET sock = INVALID_SOCKET;
    std::thread worker;
    std::atomic<bool> running{false};

    bool isHost = false;
    std::string state = "idle";
    std::string detail;
    std::string peerName;
    std::string localAddress;
    sockaddr_in peer{};
    bool hasPeer = false;
    uint32_t sessionId = 0;
    std::string myName;
    std::string modVersion;

    int64_t startedAt = 0, lastRecv = 0, lastSend = 0, lastPing = 0, lastHello = 0;
    double srtt = 0;    // smoothed RTT (RFC 6298); 0 = no sample yet
    double rttvar = 0;  // RTT variation
    int rttMs = -1;

    uint32_t nextSeq = 1;
    std::map<uint32_t, Pending> pending;
    uint32_t recvContiguous = 0;
    std::map<uint32_t, std::string> outOfOrder;
    bool needAck = false;
    std::deque<std::string> unreliableOut;
    std::deque<std::pair<int, std::string>> inbox;

    uint64_t packetsSent = 0, packetsReceived = 0, resent = 0;
};

// Never destroyed: at process exit the worker std::thread may still be running, and destroying a joinable
// std::thread calls std::terminate (closing the game crashed it with 0xC0000409 in this DLL).
Session& g = *new Session;
std::mutex g_identityMutex;
std::string g_identity = "unknown";

// Network impairment for tests (TailCoop_Simulate): drop / delay outgoing packets. Guarded by g.mu.
struct Delayed {
    int64_t due;
    std::vector<uint8_t> data;
    sockaddr_in to;
};
struct Impairment {
    double lossPercent = 0;
    int delayMs = 0;
    int jitterMs = 0;
    std::deque<Delayed> queue;
    uint64_t dropped = 0;
} g_sim;
std::mt19937 g_simRng{12345};

uint32_t RandomId() {
    static std::mt19937 rng(std::random_device{}());
    uint32_t v = 0;
    while (v == 0) v = rng();
    return v;
}

bool SameAddr(const sockaddr_in& a, const sockaddr_in& b) {
    return a.sin_port == b.sin_port && a.sin_addr.s_addr == b.sin_addr.s_addr;
}

std::string AddrString(const sockaddr_in& a) {
    char ip[64] = {};
    inet_ntop(AF_INET, &a.sin_addr, ip, sizeof ip);
    return std::string(ip) + ":" + std::to_string(ntohs(a.sin_port));
}

void Push(int channel, std::string payload) { g.inbox.emplace_back(channel, std::move(payload)); }

void ResetChannels() {
    g.nextSeq = 1;
    g.pending.clear();
    g.recvContiguous = 0;
    g.outOfOrder.clear();
    g.needAck = false;
    g.unreliableOut.clear();
    g.srtt = 0;
    g.rttvar = 0;
    g.rttMs = -1;
}

// Retransmission timeout (RFC 6298): 1 s until the first RTT sample, then SRTT + 4 * RTTVAR.
int64_t Rto() {
    if (g.srtt <= 0) return 1000;
    return int64_t(std::clamp(g.srtt + std::max(10.0, 4.0 * g.rttvar), 100.0, 2000.0));
}

Writer Header(PacketType type) {
    Writer w;
    w.u32(kMagic);
    w.u8(type);
    w.u8(0);
    w.u16(0);
    w.u32(g.sessionId);
    return w;
}

void RawSend(const std::vector<uint8_t>& data, const sockaddr_in& to) {
    sendto(g.sock, reinterpret_cast<const char*>(data.data()), int(data.size()), 0,
           reinterpret_cast<const sockaddr*>(&to), sizeof to);
}

void SendTo(const Writer& w, const sockaddr_in& to) {
    g.packetsSent++;
    if (g_sim.lossPercent <= 0 && g_sim.delayMs <= 0 && g_sim.jitterMs <= 0) {
        RawSend(w.b, to);
        return;
    }
    if (std::uniform_real_distribution<double>(0, 100)(g_simRng) < g_sim.lossPercent) {
        g_sim.dropped++;
        return;
    }
    const int jitter = g_sim.jitterMs > 0 ? std::uniform_int_distribution<int>(0, g_sim.jitterMs)(g_simRng) : 0;
    g_sim.queue.push_back({NowMs() + g_sim.delayMs + jitter, w.b, to});
}

// Sends delayed packets that are due (jitter can reorder them, like a real network).
void FlushDelayed(int64_t now) {
    for (auto it = g_sim.queue.begin(); it != g_sim.queue.end();) {
        if (it->due <= now) {
            RawSend(it->data, it->to);
            it = g_sim.queue.erase(it);
        } else {
            ++it;
        }
    }
}

void SendReject(const sockaddr_in& to, const std::string& reason) {
    Writer w = Header(kReject);
    w.str(reason);
    SendTo(w, to);
}

void SendHello() {
    Writer w = Header(kHello);
    w.u16(kProtocol);
    w.str(Identity());
    w.str(g.myName);
    w.str(g.modVersion);
    SendTo(w, g.peer);
}

void SendWelcome() {
    Writer w = Header(kWelcome);
    w.str(g.myName);
    SendTo(w, g.peer);
}

uint32_t AckBits() {
    uint32_t bits = 0;
    for (uint32_t i = 0; i < 32; ++i) {
        if (g.outOfOrder.count(g.recvContiguous + 2 + i)) bits |= 1u << i;
    }
    return bits;
}

// The partner is gone: a host goes back to waiting (the partner may rejoin), a joiner stops.
void PeerLost(const std::string& reason) {
    Log("session: %s", reason.c_str());
    Push(kSystemChannel, "disconnected|" + reason);
    ResetChannels();
    g.peerName.clear();
    if (g.isHost) {
        g.hasPeer = false;
        g.state = "hosting";
        g.detail = reason;
        g.sessionId = 0;
    } else {
        g.state = "failed";
        g.detail = reason;
    }
}

void HandleData(Reader& r) {
    const uint32_t ack = r.u32();
    const uint32_t bits = r.u32();
    if (!r.ok) return;
    for (auto it = g.pending.begin(); it != g.pending.end();) {
        const uint32_t s = it->first;
        const bool acked = s <= ack || (s >= ack + 2 && s < ack + 34 && ((bits >> (s - ack - 2)) & 1u));
        it = acked ? g.pending.erase(it) : std::next(it);
    }
    while (!r.done()) {
        const uint8_t kind = r.u8();
        const uint32_t seq = kind == kReliable ? r.u32() : 0;
        std::string payload = r.str();
        if (!r.ok) break;
        if (kind == kUnreliable) {
            Push(kUnreliable, std::move(payload));
            continue;
        }
        g.needAck = true;
        if (seq <= g.recvContiguous || seq > g.recvContiguous + 4096 || g.outOfOrder.count(seq)) continue;
        g.outOfOrder.emplace(seq, std::move(payload));
        for (auto it = g.outOfOrder.find(g.recvContiguous + 1); it != g.outOfOrder.end();
             it = g.outOfOrder.find(g.recvContiguous + 1)) {
            Push(kReliable, std::move(it->second));
            g.outOfOrder.erase(it);
            g.recvContiguous++;
        }
    }
}

void HandlePacket(const uint8_t* data, size_t n, const sockaddr_in& from) {
    Reader r{data, n};
    const uint32_t magic = r.u32();
    const uint8_t type = r.u8();
    r.u8();
    r.u16();
    const uint32_t sid = r.u32();
    if (!r.ok || magic != kMagic) return;
    g.packetsReceived++;

    if (type == kHello) {
        if (!g.isHost) return;
        const uint16_t proto = r.u16();
        const std::string ident = r.str(), name = r.str(), mod = r.str();
        if (!r.ok) return;
        std::string reason;
        if (proto != kProtocol) {
            reason = "TailCoop protocol mismatch (host " + std::to_string(kProtocol) + ", you " + std::to_string(proto) + ")";
        } else if (ident != Identity()) {
            reason = "game build mismatch (host " + Identity() + ", you " + ident + ")";
        } else if (mod != g.modVersion) {
            reason = "TailCoop version mismatch (host " + g.modVersion + ", you " + mod + ")";
        } else if (g.hasPeer && !SameAddr(from, g.peer)) {
            if (name == g.peerName) {
                // Same player from a new port: they restarted or rejoined before we noticed them leave.
                PeerLost("partner reconnected");
            } else {
                reason = "session is full";
            }
        }
        if (!reason.empty()) {
            Log("handshake: rejected %s (%s): %s", AddrString(from).c_str(), name.c_str(), reason.c_str());
            SendReject(from, reason);
            return;
        }
        if (!g.hasPeer) {
            g.peer = from;
            g.hasPeer = true;
            g.peerName = name;
            g.sessionId = RandomId();
            g.state = "connected";
            g.detail.clear();
            ResetChannels();
            Log("handshake: %s (%s) joined, session %08x", AddrString(from).c_str(), name.c_str(), g.sessionId);
            Push(kSystemChannel, "connected|" + name);
        }
        g.lastRecv = NowMs();
        SendWelcome();  // also answers a repeated HELLO whose WELCOME was lost
        return;
    }
    if (type == kWelcome) {
        if (g.isHost || g.state != "connecting" || !SameAddr(from, g.peer)) return;
        g.sessionId = sid;
        g.peerName = r.str();
        g.state = "connected";
        g.detail.clear();
        g.lastRecv = NowMs();
        Log("handshake: welcomed by %s (%s), session %08x", AddrString(from).c_str(), g.peerName.c_str(), sid);
        Push(kSystemChannel, "connected|" + g.peerName);
        return;
    }
    if (type == kReject) {
        if (g.isHost || g.state != "connecting") return;
        const std::string reason = r.str();
        Log("handshake: rejected by host: %s", reason.c_str());
        g.state = "failed";
        g.detail = reason;
        Push(kSystemChannel, "rejected|" + reason);
        return;
    }

    // Session traffic: only from the current partner, with the current session id.
    if (!g.hasPeer || g.state != "connected" || !SameAddr(from, g.peer) || sid != g.sessionId) return;
    g.lastRecv = NowMs();
    switch (type) {
        case kPing: {
            const uint64_t t = r.u64();
            Writer w = Header(kPong);
            w.u64(t);
            SendTo(w, g.peer);
            break;
        }
        case kPong: {
            const int64_t sample = NowMs() - int64_t(r.u64());
            if (r.ok && sample >= 0 && sample < 10000) {
                const double s = double(sample);
                if (g.srtt <= 0) {
                    g.srtt = s;
                    g.rttvar = s / 2;
                } else {
                    g.rttvar = 0.75 * g.rttvar + 0.25 * std::abs(g.srtt - s);
                    g.srtt = 0.875 * g.srtt + 0.125 * s;
                }
                g.rttMs = int(g.srtt + 0.5);
            }
            break;
        }
        case kData:
            HandleData(r);
            break;
        case kBye: {
            const std::string reason = r.str();
            PeerLost(reason.empty() ? "partner left" : "partner left: " + reason);
            break;
        }
        default:
            break;
    }
}

void FlushData(int64_t now) {
    const int64_t rto = Rto();
    for (int packets = 0; packets < 64; ++packets) {
        Writer w = Header(kData);
        w.u32(g.recvContiguous);
        w.u32(AckBits());
        bool any = false;
        size_t considered = 0;
        for (auto& [seq, p] : g.pending) {
            if (++considered > kMaxInFlight) break;
            if (p.lastSent != 0 && now - p.lastSent < rto) continue;
            if (w.b.size() + 1 + 4 + 2 + p.data.size() > kMaxPacket) break;
            w.u8(kReliable);
            w.u32(seq);
            w.str(p.data);
            if (p.sends > 0) g.resent++;
            p.sends++;
            p.lastSent = now;
            any = true;
        }
        while (!g.unreliableOut.empty()) {
            const std::string& s = g.unreliableOut.front();
            if (w.b.size() + 1 + 2 + s.size() > kMaxPacket) break;
            w.u8(kUnreliable);
            w.str(s);
            g.unreliableOut.pop_front();
            any = true;
        }
        if (!any && !g.needAck && now - g.lastSend < kKeepaliveMs) break;
        SendTo(w, g.peer);
        g.needAck = false;
        g.lastSend = now;
        if (!any) break;
    }
}

void Tick() {
    const int64_t now = NowMs();
    FlushDelayed(now);
    if (g.state == "connecting") {
        if (now - g.lastHello >= kHelloIntervalMs) {
            SendHello();
            g.lastHello = now;
        }
        if (now - g.startedAt > kJoinTimeoutMs) {
            g.state = "failed";
            g.detail = "no answer from " + AddrString(g.peer);
            Log("join: %s", g.detail.c_str());
            Push(kSystemChannel, "failed|" + g.detail);
        }
        return;
    }
    if (g.state != "connected") return;
    if (now - g.lastRecv > kTimeoutMs) {
        PeerLost("partner timed out");
        return;
    }
    if (now - g.lastPing >= kPingIntervalMs) {
        Writer w = Header(kPing);
        w.u64(uint64_t(now));
        SendTo(w, g.peer);
        g.lastPing = now;
    }
    FlushData(now);
}

void WorkerLoop() {
    std::vector<uint8_t> buf(2048);
    while (g.running) {
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(g.sock, &readable);
        timeval tv{0, 5000};
        select(0, &readable, nullptr, nullptr, &tv);
        for (;;) {
            sockaddr_in from{};
            int fromLen = sizeof from;
            const int n = recvfrom(g.sock, reinterpret_cast<char*>(buf.data()), int(buf.size()), 0,
                                   reinterpret_cast<sockaddr*>(&from), &fromLen);
            if (n <= 0) break;
            std::lock_guard<std::mutex> lock(g.mu);
            HandlePacket(buf.data(), size_t(n), from);
        }
        std::lock_guard<std::mutex> lock(g.mu);
        Tick();
    }
}

bool EnsureWinsock(std::string& error) {
    static bool ready = false;
    if (ready) return true;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        error = "WSAStartup failed";
        return false;
    }
    ready = true;
    return true;
}

bool OpenSocket(const sockaddr_in& bindAddr, std::string& error) {
    g.sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g.sock == INVALID_SOCKET) {
        error = "socket() failed: " + std::to_string(WSAGetLastError());
        return false;
    }
    // Ignore ICMP "port unreachable" (otherwise recvfrom fails with WSAECONNRESET while the host isn't up yet).
    BOOL off = FALSE;
    DWORD bytes = 0;
    WSAIoctl(g.sock, SIO_UDP_CONNRESET, &off, sizeof off, nullptr, 0, &bytes, nullptr, nullptr);
    u_long nonBlocking = 1;
    ioctlsocket(g.sock, FIONBIO, &nonBlocking);
    if (bind(g.sock, reinterpret_cast<const sockaddr*>(&bindAddr), sizeof bindAddr) != 0) {
        const int code = WSAGetLastError();
        closesocket(g.sock);
        g.sock = INVALID_SOCKET;
        error = code == WSAEADDRINUSE ? "port " + std::to_string(ntohs(bindAddr.sin_port)) + " is already in use"
                                      : "bind failed: " + std::to_string(code);
        return false;
    }
    sockaddr_in local{};
    int len = sizeof local;
    getsockname(g.sock, reinterpret_cast<sockaddr*>(&local), &len);
    g.localAddress = AddrString(local);
    return true;
}

bool Resolve(const std::string& address, int port, sockaddr_in& out, std::string& error) {
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    addrinfo* result = nullptr;
    if (getaddrinfo(address.c_str(), std::to_string(port).c_str(), &hints, &result) != 0 || !result) {
        error = "cannot resolve " + address;
        return false;
    }
    out = *reinterpret_cast<sockaddr_in*>(result->ai_addr);
    freeaddrinfo(result);
    return true;
}

void StartWorker() {
    g.running = true;
    g.worker = std::thread(WorkerLoop);
}

}  // namespace

void Simulate(double lossPercent, int delayMs, int jitterMs) {
    std::lock_guard<std::mutex> lock(g.mu);
    g_sim.lossPercent = std::clamp(lossPercent, 0.0, 100.0);
    g_sim.delayMs = std::max(0, delayMs);
    g_sim.jitterMs = std::max(0, jitterMs);
    Log("simulate: %.1f%% loss, %d ms delay, %d ms jitter (outgoing)", g_sim.lossPercent, g_sim.delayMs,
        g_sim.jitterMs);
}

uint64_t SimulatedDrops() {
    std::lock_guard<std::mutex> lock(g.mu);
    return g_sim.dropped;
}

void SetIdentity(const std::string& identity) {
    std::lock_guard<std::mutex> lock(g_identityMutex);
    g_identity = identity;
}

std::string Identity() {
    std::lock_guard<std::mutex> lock(g_identityMutex);
    return g_identity;
}

bool Host(int port, const std::string& bindAddress, const std::string& name, const std::string& modVersion,
          std::string& error) {
    Leave();
    if (!EnsureWinsock(error)) return false;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(uint16_t(port));
    if (bindAddress.empty() || bindAddress == "0.0.0.0") {
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (inet_pton(AF_INET, bindAddress.c_str(), &addr.sin_addr) != 1) {
        error = "bad bind address " + bindAddress;
        return false;
    }
    std::lock_guard<std::mutex> lock(g.mu);
    if (!OpenSocket(addr, error)) return false;
    g.isHost = true;
    g.hasPeer = false;
    g.sessionId = 0;
    g.myName = name;
    g.modVersion = modVersion;
    g.state = "hosting";
    g.detail.clear();
    g.peerName.clear();
    g.inbox.clear();
    ResetChannels();
    g.startedAt = NowMs();
    Log("host: listening on %s (%s, %s, identity %s)", g.localAddress.c_str(), name.c_str(), modVersion.c_str(),
        Identity().c_str());
    StartWorker();
    return true;
}

bool Join(const std::string& address, int port, const std::string& name, const std::string& modVersion,
          std::string& error) {
    Leave();
    if (!EnsureWinsock(error)) return false;
    sockaddr_in target{};
    if (!Resolve(address, port, target, error)) return false;
    // Bind on the interface that reaches the host: loopback for lab tests, any otherwise.
    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_port = 0;
    local.sin_addr.s_addr = (target.sin_addr.s_addr == htonl(INADDR_LOOPBACK)) ? htonl(INADDR_LOOPBACK) : htonl(INADDR_ANY);
    std::lock_guard<std::mutex> lock(g.mu);
    if (!OpenSocket(local, error)) return false;
    g.isHost = false;
    g.peer = target;
    g.hasPeer = true;
    g.sessionId = 0;
    g.myName = name;
    g.modVersion = modVersion;
    g.state = "connecting";
    g.detail.clear();
    g.peerName.clear();
    g.inbox.clear();
    ResetChannels();
    g.startedAt = NowMs();
    g.lastHello = 0;
    Log("join: %s -> %s (%s, %s, identity %s)", g.localAddress.c_str(), AddrString(target).c_str(), name.c_str(),
        modVersion.c_str(), Identity().c_str());
    StartWorker();
    return true;
}

void Leave() {
    if (!g.running) return;
    {
        std::lock_guard<std::mutex> lock(g.mu);
        if (g.state == "connected") {
            // Straight to the socket (never through the test impairment queue, which dies with the socket).
            Writer w = Header(kBye);
            w.str("");
            for (int i = 0; i < 3; ++i) RawSend(w.b, g.peer);
        }
        g_sim.queue.clear();
    }
    g.running = false;
    if (g.worker.joinable()) g.worker.join();
    std::lock_guard<std::mutex> lock(g.mu);
    closesocket(g.sock);
    g.sock = INVALID_SOCKET;
    Log("session: left (%s)", g.state.c_str());
    g.state = "idle";
    g.detail.clear();
    g.peerName.clear();
    g.hasPeer = false;
    ResetChannels();
}

bool Send(int channel, const std::string& payload, std::string& error) {
    std::lock_guard<std::mutex> lock(g.mu);
    if (g.state != "connected") {
        error = "not connected";
        return false;
    }
    if (payload.size() > kMaxPayload) {
        error = "message too large (" + std::to_string(payload.size()) + " bytes, max " + std::to_string(kMaxPayload) + ")";
        return false;
    }
    if (channel == kReliable) {
        if (g.pending.size() >= kMaxQueuedReliable) {
            error = "reliable queue full";
            return false;
        }
        g.pending.emplace(g.nextSeq++, Pending{payload});
    } else {
        g.unreliableOut.push_back(payload);
        if (g.unreliableOut.size() > kMaxQueuedUnreliable) g.unreliableOut.pop_front();
    }
    return true;
}

bool Poll(int& channel, std::string& payload) {
    std::lock_guard<std::mutex> lock(g.mu);
    if (g.inbox.empty()) return false;
    channel = g.inbox.front().first;
    payload = std::move(g.inbox.front().second);
    g.inbox.pop_front();
    return true;
}

StatusInfo Status() {
    std::lock_guard<std::mutex> lock(g.mu);
    StatusInfo s;
    s.state = g.state;
    s.detail = g.detail;
    s.peerName = g.peerName;
    s.localAddress = g.localAddress;
    s.rttMs = g.rttMs;
    s.packetsSent = g.packetsSent;
    s.packetsReceived = g.packetsReceived;
    s.resent = g.resent;
    s.pendingReliable = g.pending.size();
    return s;
}

}  // namespace tc
