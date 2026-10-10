-- TailCoop: two-player online co-op for Sifu over Tailscale.
-- Lua holds the game logic; TailCoop.dll (UE4SS C++ mod) provides the UDP transport.
local U = require("tc_util")

local cfg = U.loadConfig()
U.log("TailCoop %s starting: system=%s role=%s peer=%s:%d mode=%s test=%s userdir=%s",
    U.modVersion(), cfg.system, cfg.role, cfg.peer, cfg.port, cfg.mode, cfg.test, tostring(cfg.userdir))

-- Must come first: without the native ProcessEvent fix, Lua UFunction calls do nothing in Sifu.
U.nativeReady = U.loadNative()
if not U.nativeReady then
    U.log("WARNING: ProcessEvent fix not applied; UFunction calls from Lua will not work")
end

U.try("session", function() require("tc_session").start() end)
U.try("flow", function() require("tc_flow").start() end)
U.try("presence", function() require("tc_presence").start() end)
U.try("moves", function() require("tc_moves").start() end)
U.try("enemies", function() require("tc_enemies").start() end)
U.try("gear", function() require("tc_gear").start() end)
U.try("aggro", function() require("tc_aggro").start() end)
U.try("turns", function() require("tc_turns").start() end)
U.try("training", function() require("tc_training").start() end)
U.try("arena", function() require("tc_arena").start() end)
U.try("menu", function() require("tc_menu").start() end)

-- Development builds only (tc_trace / tc_devtests aren't part of the released mod).
if cfg.system ~= "0" then
    if cfg.trace ~= false then U.try("trace", function() require("tc_trace").start() end) end
    U.try("devtests", function() require("tc_devtests").run(cfg.test) end)
end
