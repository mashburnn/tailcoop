#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>

#include "tailscale.h"

#include <chrono>
#include <cstdio>
#include <cwctype>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#include "log.h"

namespace tc {
namespace {

std::wstring TailscaleExe() {
    wchar_t programFiles[MAX_PATH];
    if (GetEnvironmentVariableW(L"ProgramFiles", programFiles, MAX_PATH)) {
        std::wstring path = std::wstring(programFiles) + L"\\Tailscale\\tailscale.exe";
        if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return path;
    }
    return L"tailscale.exe";  // rely on PATH
}

// Runs a console program without a window and returns its stdout ("" on failure or timeout).
std::string RunCapture(const std::wstring& args, DWORD timeoutMs) {
    SECURITY_ATTRIBUTES sa{sizeof sa, nullptr, TRUE};
    HANDLE readPipe = nullptr, writePipe = nullptr;
    if (!CreatePipe(&readPipe, &writePipe, &sa, 0)) return {};
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW si{sizeof si};
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = writePipe;
    si.hStdError = writePipe;
    si.hStdInput = nullptr;
    PROCESS_INFORMATION pi{};
    std::wstring cmd = L"\"" + TailscaleExe() + L"\" " + args;
    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(0);
    const BOOL started = CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr,
                                        nullptr, &si, &pi);
    CloseHandle(writePipe);
    std::string out;
    if (started) {
        char buf[4096];
        DWORD n = 0;
        const ULONGLONG deadline = GetTickCount64() + timeoutMs;
        for (;;) {
            DWORD available = 0;
            if (!PeekNamedPipe(readPipe, nullptr, 0, nullptr, &available, nullptr)) break;  // pipe closed
            if (available > 0) {
                if (!ReadFile(readPipe, buf, sizeof buf, &n, nullptr) || n == 0) break;
                out.append(buf, n);
            } else if (WaitForSingleObject(pi.hProcess, 20) == WAIT_OBJECT_0) {
                while (PeekNamedPipe(readPipe, nullptr, 0, nullptr, &available, nullptr) && available > 0 &&
                       ReadFile(readPipe, buf, sizeof buf, &n, nullptr) && n > 0) {
                    out.append(buf, n);
                }
                break;
            }
            if (GetTickCount64() > deadline) {
                TerminateProcess(pi.hProcess, 1);
                out.clear();
                break;
            }
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    CloseHandle(readPipe);
    return out;
}

// `tailscale status` lines: "<ip> <hostname> <user> <os> <status...>"; the first device line is this PC.
std::string ParseStatus(const std::string& text) {
    std::istringstream lines(text);
    std::string line, result;
    bool first = true;
    while (std::getline(lines, line)) {
        if (line.empty() || line[0] == '#' || line[0] < '0' || line[0] > '9') continue;
        std::istringstream cols(line);
        std::string ip, name, user, os, status;
        cols >> ip >> name >> user >> os;
        std::getline(cols, status);
        if (name.empty()) continue;
        if (first) {
            result += "self\t" + name + "\t" + ip + "\n";
            first = false;
        } else {
            const bool online = status.find("offline") == std::string::npos;
            result += "peer\t" + name + "\t" + ip + "\t" + (online ? "1" : "0") + "\t" + os + "\n";
        }
    }
    return result;
}

std::mutex g_mu;
std::string g_cache;
ULONGLONG g_lastRefresh = 0;
bool g_refreshing = false;

}  // namespace

std::string TailscalePeers() {
    std::lock_guard<std::mutex> lock(g_mu);
    const ULONGLONG now = GetTickCount64();
    if (!g_refreshing && (g_lastRefresh == 0 || now - g_lastRefresh > 5000)) {
        g_refreshing = true;
        std::thread([] {
            std::string parsed = ParseStatus(RunCapture(L"status", 5000));
            std::lock_guard<std::mutex> inner(g_mu);
            if (!parsed.empty()) g_cache = parsed;
            g_lastRefresh = GetTickCount64();
            g_refreshing = false;
        }).detach();
    }
    return g_cache;
}

std::string TailscaleSelfIp() {
    std::string out = RunCapture(L"ip -4", 3000);
    const size_t end = out.find_first_of("\r\n");
    if (end != std::string::npos) out.resize(end);
    if (out.empty() || out[0] < '0' || out[0] > '9') {
        out = TailnetAdapterIp();
        Log("tailscale: no tailscale command here; adapter address %s", out.empty() ? "none" : out.c_str());
    }
    return out;
}

std::string TailnetAdapterIp() {
    ULONG size = 16 * 1024;
    std::vector<unsigned char> buf;
    ULONG rc = ERROR_BUFFER_OVERFLOW;
    for (int tries = 0; tries < 3 && rc == ERROR_BUFFER_OVERFLOW; ++tries) {
        buf.resize(size);
        rc = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
                                  nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data()), &size);
    }
    if (rc != NO_ERROR) return {};
    // Best: an adapter that is up and named like Tailscale's ("Tailscale" on Windows, "utunN" under Wine on a Mac).
    std::string best;
    int bestScore = -1;
    for (auto* a = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data()); a; a = a->Next) {
        std::wstring names = std::wstring(a->FriendlyName ? a->FriendlyName : L"") + L" " +
                             (a->Description ? a->Description : L"");
        for (auto& ch : names) ch = static_cast<wchar_t>(towlower(ch));
        const bool named = names.find(L"tailscale") != std::wstring::npos || names.find(L"utun") != std::wstring::npos;
        const int score = (a->OperStatus == IfOperStatusUp ? 2 : 0) + (named ? 1 : 0);
        for (auto* u = a->FirstUnicastAddress; u; u = u->Next) {
            if (!u->Address.lpSockaddr || u->Address.lpSockaddr->sa_family != AF_INET) continue;
            const uint32_t ip = ntohl(reinterpret_cast<const sockaddr_in*>(u->Address.lpSockaddr)->sin_addr.s_addr);
            if ((ip & 0xFFC00000u) != 0x64400000u || score <= bestScore) continue;  // 100.64.0.0/10
            char text[16];
            snprintf(text, sizeof text, "%u.%u.%u.%u", ip >> 24, (ip >> 16) & 255u, (ip >> 8) & 255u, ip & 255u);
            best = text;
            bestScore = score;
        }
    }
    return best;
}

}  // namespace tc
