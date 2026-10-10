-- tc_hits: Sifu hits as Unreal text (TailCoopNative exports/imports struct parameters through UE4SS).
-- A hit is FHitDescription { m_Request (FHitRequest), m_Result (FHitResult), m_ImpactResult (FImpactResult) };
-- its text form holds asset paths and actor paths, so it can be moved to the other game with the actors swapped.
local U = require("tc_util")

local H = {}

H.SIZE = { description = 1440, request = 1104, result = 140, impact = 192 }  -- 0x5A0, 0x450, 0x8C, 0xC0

-- Top-level members of a struct's text form "(a=...,b=(...),c="...")" -> { a = "...", b = "(...)", ... } plus the
-- names in order. Respects nesting and quoted strings.
function H.members(text)
    local out, order = {}, {}
    if type(text) ~= "string" or text:sub(1, 1) ~= "(" then return out, order end
    local depth, i, n = 0, 2, #text
    local nameStart, valueStart, name = 2, nil, nil
    local quote = nil
    while i <= n do
        local ch = text:sub(i, i)
        if quote then
            if ch == "\\" then
                i = i + 1
            elseif ch == quote then
                quote = nil
            end
        elseif ch == '"' or ch == "'" then
            quote = ch
        elseif ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            if depth == 0 then
                if name then
                    out[name] = text:sub(valueStart, i - 1)
                    order[#order + 1] = name
                end
                break
            end
            depth = depth - 1
        elseif ch == "=" and depth == 0 and not name then
            name, valueStart = text:sub(nameStart, i - 1), i + 1
        elseif ch == "," and depth == 0 then
            if name then
                out[name] = text:sub(valueStart, i - 1)
                order[#order + 1] = name
            end
            name, nameStart = nil, i + 1
        end
        i = i + 1
    end
    return out, order
end

-- The object path an actor appears under in exported text (e.g. ".../ArenaMode_Menu:PersistentLevel.BP_X_C_123").
function H.pathOf(actor)
    local ok, full = pcall(function() return actor:GetFullName() end)
    return ok and full and full:match("%s(.+)$") or nil
end

-- Replaces every occurrence of a plain (non-pattern) string.
function H.replace(text, from, to)
    if not from or from == "" then return text end
    local out, i = {}, 1
    while true do
        local s, e = text:find(from, i, true)
        if not s then break end
        out[#out + 1] = text:sub(i, s - 1)
        out[#out + 1] = to
        i = e + 1
    end
    out[#out + 1] = text:sub(i)
    return table.concat(out)
end

-- The most-derived override of `funcName` on obj's class chain (what the engine itself calls), or nil.
-- Looked up once per class and function name: a StaticFindObject that finds nothing (every Blueprint level above the
-- one declaring the function) took ~35 ms, a hitch at every enemy handover.
local functionCache = {}  -- "classAddress:name" -> function object
function H.functionFor(obj, funcName)
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not (ok and U.valid(cls)) then return nil end
    local key = tostring(cls:GetAddress()) .. ":" .. funcName
    local cached = functionCache[key]
    if cached and U.valid(cached) then return cached end
    -- From the object itself: the engine finds it in its own function table, most-derived class first, at no cost.
    -- (Every Arena enemy variant is its own class: the walk below cost ~35 ms per missing level, per new variant.)
    local okF, fn = pcall(function()
        local f = obj[funcName]
        return f and f:GetFullName():find("^Function ") and f or nil
    end)
    if okF and fn and U.valid(fn) then
        functionCache[key] = fn
        return fn
    end
    while ok and U.valid(cls) do
        local path = cls:GetFullName():match("%s(.+)$")
        local fn = path and StaticFindObject(path .. ":" .. funcName)
        if U.valid(fn) then
            functionCache[key] = fn
            return fn
        end
        ok, cls = pcall(function() return cls:GetSuperStruct() end)
    end
    return nil
end

return H
