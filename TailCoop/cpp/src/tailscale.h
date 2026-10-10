// Tailscale helpers: this PC's tailnet address and the list of tailnet devices, from the tailscale CLI.
#pragma once

#include <string>

namespace tc {

// "self\t<name>\t<ip>\n" then "peer\t<name>\t<ip>\t<1 online|0 offline>\t<os>\n" per device. Returns the
// cached result and refreshes it in the background when older than a few seconds ("" until the first run).
std::string TailscalePeers();

// This PC's Tailscale IPv4 (runs `tailscale ip -4`, ~50 ms; else from the network adapters), or "" if Tailscale
// isn't available.
std::string TailscaleSelfIp();

// This PC's Tailscale IPv4 from its network adapters alone (an address in 100.64.0.0/10), or "". Works where the
// tailscale command can't run, e.g. a game under CrossOver/Wine on a Mac running the Mac's Tailscale app.
std::string TailnetAdapterIp();

}  // namespace tc
