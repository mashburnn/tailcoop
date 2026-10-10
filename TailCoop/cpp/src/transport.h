// UDP transport between the two TailCoop players (one host, one joiner) over Tailscale.
//
// Packet = 12-byte header (magic, type, session id) + body. Session packets carry:
//   - reliable-ordered messages (sequence numbers, cumulative ack + 32-bit ack mask, resend after RTO);
//   - unreliable messages (latest-wins state, delivered as they arrive);
//   - ping/pong for RTT, keepalives, and a 5 s timeout.
// The handshake rejects joiners whose protocol, game build identity or mod version differ from the host's.
// A background thread does all socket work; the Lua-facing calls only touch queues under a mutex.
#pragma once

#include <cstdint>
#include <string>

namespace tc {

constexpr int kSystemChannel = -1;  // connected|name, disconnected|reason, rejected|reason, failed|reason
constexpr int kUnreliable = 0;
constexpr int kReliable = 1;
constexpr size_t kMaxPayload = 1100;

struct StatusInfo {
    std::string state = "idle";  // idle | hosting | connecting | connected | failed
    std::string detail;
    std::string peerName;
    std::string localAddress;
    int rttMs = -1;
    uint64_t packetsSent = 0;
    uint64_t packetsReceived = 0;
    uint64_t resent = 0;
    uint64_t pendingReliable = 0;
};

bool Host(int port, const std::string& bindAddress, const std::string& name, const std::string& modVersion,
          std::string& error);
bool Join(const std::string& address, int port, const std::string& name, const std::string& modVersion,
          std::string& error);
void Leave();
bool Send(int channel, const std::string& payload, std::string& error);
bool Poll(int& channel, std::string& payload);
StatusInfo Status();

// Test-only impairment of outgoing packets (both directions need it set to impair both ways).
void Simulate(double lossPercent, int delayMs, int jitterMs);
uint64_t SimulatedDrops();

void SetIdentity(const std::string& identity);
std::string Identity();

}  // namespace tc
