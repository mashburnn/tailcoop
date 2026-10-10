-- tc_timeline: how far behind the partner's game the copies of its characters play (their clock).
-- Copies blend between received states, so they must play far enough behind that the next state has always arrived.
-- A fixed 100 ms did that with room to spare. Here the lag follows what the connection needs: for every timed message
-- the partner sends (its player "p", its enemies "e"), how long after the previous one of that stream was stamped did
-- this one become usable here (send interval + transit + jitter + loss, in one number). The lag covers 95% of those,
-- plus a small margin; it rises quickly when the connection gets worse and falls slowly (copies play ~2% fast
-- meanwhile), so the change is never visible as a jump.
-- No clock sync is needed: everything is measured as our clock minus theirs.
local U = require("tc_util")

local TL = {}

local WINDOW_MS = 4000     -- needs remembered this long
local MAX_SAMPLES = 400
local PERCENTILE = 0.95
local MARGIN_MS = 4
local RETARGET_MS = 250    -- target recomputed this often
local RISE = 0.5           -- ms of lag added per ms when the target is above (copies play at half speed meanwhile)
local FALL = 0.02          -- ms of lag removed per ms when below (copies play 2% fast)
local MIN_BUFFER, MAX_BUFFER = 0, 400  -- lag limits above the fastest transit (the lag itself includes the clocks'
                                       -- difference, which between two PCs is anything: their uptimes differ)
local START_BUFFER_MS = 100  -- until enough is measured: as before

local newestOf = {}        -- stream -> newest sender clock seen
local samples = {}         -- { at (our clock), need, transit }, oldest first
local lag, target = nil, nil
local lastUpdate, lastRetarget = nil, -1e9
local minTransit = nil     -- lowest (our clock - their clock) seen lately: the clock difference + the fastest path.
                           -- Lately (the sample window), because two PCs' clocks drift apart by a few ms per minute.
TL.fixed = false           -- lab comparison: the old fixed 100 ms buffer

-- Stats for the lab report, per kind of copy (reset at each report).
local st = {}

-- Two PCs' clocks differ (by their uptimes): "behind" is then measured from the fastest transit instead, without
-- the transit itself. Two games on one PC share a clock and the full delay is shown.
local function clocksDiffer() return minTransit ~= nil and math.abs(minTransit) > 60000 end

function TL.reset()
    newestOf, samples, lag, target, lastUpdate, minTransit = {}, {}, nil, nil, nil, nil
end

-- A timed message from the partner became usable now (net pump, game thread).
function TL.observe(stream, senderClock, now)
    if not senderClock then return end
    local transit = now - senderClock
    if not minTransit or transit < minTransit then minTransit = transit end
    if not lag then lag = transit + START_BUFFER_MS end
    local prev = newestOf[stream]
    if prev and senderClock <= prev then return end  -- late / reordered: the newer one already counted
    newestOf[stream] = senderClock
    -- A stream that paused (enemy run here meanwhile, partner in a menu) restarts: a gap, not the connection's lag.
    if prev and senderClock - prev < 1000 then
        samples[#samples + 1] = { at = now, need = now - prev, transit = transit }
        if #samples > MAX_SAMPLES then table.remove(samples, 1) end
    end
end

local function retarget(now)
    while samples[1] and now - samples[1].at > WINDOW_MS do table.remove(samples, 1) end
    if #samples < 20 then return end
    local needs, fastest = {}, nil
    for i, s in ipairs(samples) do
        needs[i] = s.need
        if not fastest or s.transit < fastest then fastest = s.transit end
    end
    minTransit = fastest
    table.sort(needs)
    target = needs[math.max(1, math.ceil(#needs * PERCENTILE))] + MARGIN_MS
end

-- The partner's clock time to show now, or nil before anything arrived.
function TL.renderClock(now)
    if not lag then return nil end
    if lastUpdate ~= now then
        local dt = lastUpdate and math.min(now - lastUpdate, 100) or 0
        lastUpdate = now
        if now - lastRetarget >= RETARGET_MS then
            lastRetarget = now
            retarget(now)
        end
        if TL.fixed then
            lag = minTransit + START_BUFFER_MS
        elseif target then
            if target > lag then
                lag = math.min(target, lag + RISE * dt)
            else
                lag = math.max(target, lag - FALL * dt)
            end
            lag = math.max(minTransit + MIN_BUFFER, math.min(minTransit + MAX_BUFFER, lag))
        end
    end
    return now - lag
end

-- How far behind the copies play right now (ms, our clock minus theirs, so it includes the clock difference
-- between two PCs; in the lab both games share one clock and this is the real delay).
function TL.lag() return lag end

-- The buffer part of the lag: above the fastest transit seen.
function TL.buffer() return lag and minTransit and (lag - minTransit) or nil end

-- Lab stats: a copy of kind ("partner" / "enemy") was shown this frame; `age` = how far the shown time is past the
-- newest state it had (> 0: it ran out and held / extrapolated).
function TL.noteShown(kind, age)
    local k = st[kind]
    if not k then
        k = { frames = 0, lagSum = 0, starved = 0, longest = 0 }
        st[kind] = k
    end
    k.frames = k.frames + 1
    k.lagSum = k.lagSum + (lag or 0) - (clocksDiffer() and minTransit or 0)
    if age and age > 0 then
        k.starved = k.starved + 1
        if age > k.longest then k.longest = age end
    end
end

function TL.report()
    if not lag then return end
    local parts = {}
    for kind, k in pairs(st) do
        parts[#parts + 1] = string.format("%s %.0f ms behind, out of data in %.1f%% of frames (longest %.0f ms)", kind,
            k.lagSum / k.frames, 100 * k.starved / k.frames, k.longest)
    end
    table.sort(parts)
    local differ = clocksDiffer()
    U.log("timeline: lag now %.0f ms (fastest transit %.0f + buffer %.0f, target %s)%s%s | %s", lag, minTransit or -1,
        TL.buffer() or -1, target and string.format("%.0f", target) or "-", TL.fixed and " FIXED 100 ms buffer" or "",
        differ and " [clocks differ: 'behind' = above the fastest transit]" or "",
        #parts > 0 and table.concat(parts, " | ") or "no copies shown")
    st = {}
end

return TL
