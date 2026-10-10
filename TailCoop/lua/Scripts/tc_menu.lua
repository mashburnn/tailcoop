-- tc_menu: adds CO-OP to Sifu's title menu (BP_Menu_Startup_C), right after Story, using the game's own
-- title button widget so it looks native. The CO-OP submenu reuses the same MenuBox column: the original
-- buttons are collapsed while it is open and restored on Back.
local U = require("tc_util")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")

local M = {}

local MENU_CLASS = "BP_Menu_Startup_C"
local BUTTON_CLASS = "/Game/UI/Blueprints/Buttons/BP_Btn_TitleBtn.BP_Btn_TitleBtn_C"
local VISIBLE, COLLAPSED = 0, 1

-- Modes become selectable as their test gates pass (see TailCoop\TESTLOG.md).
M.ENABLED_MODES = { training = true, arena = true, story = false }

local state = {
    menuAddr = nil,      -- address of the menu we injected into
    coopButton = nil,
    actions = {},        -- button address -> function
    page = nil,          -- nil = original menu, else the submenu page name
    pageButtons = {},    -- buttons we created for the current page
    savedVisibility = {},-- original child -> visibility while the submenu is open
}

local function buttonClass()
    return StaticFindObject(BUTTON_CLASS)
end

local function widgetLibrary()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
end

-- GetChildrenCount/GetChildAt instead of GetAllChildren: a TArray returned by value comes back empty in UE4SS.
local function children(panel)
    local list = {}
    for i = 0, panel:GetChildrenCount() - 1 do
        local w = panel:GetChildAt(i)
        if U.valid(w) then list[#list + 1] = w end
    end
    return list
end

local function nameOf(widget)
    return widget:GetFName():ToString()
end

-- Snapshot of a vertical box slot's layout, as plain values so it survives the slot being destroyed.
local function slotLayout(widget)
    local s = widget.Slot
    if not U.valid(s) then return nil end
    local p = s.Padding
    return {
        padding = { Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom },
        h = s.HorizontalAlignment,
        v = s.VerticalAlignment,
        size = { SizeRule = s.Size.SizeRule, Value = s.Size.Value },
    }
end

local function applyLayout(slot, layout)
    if not (layout and U.valid(slot)) then return end
    slot:SetPadding(layout.padding)
    slot:SetHorizontalAlignment(layout.h)
    slot:SetVerticalAlignment(layout.v)
    slot:SetSize(layout.size)
end

-- Sifu's menu Blueprint binds each built-in button's click delegate (m_OnClick, signature (button, bool)) to a
-- handler. Ours are bound to MenuBox:HasChild(button), which has the same parameter layout, has no side effects,
-- and lets the HasChild hook below see which button was activated (mouse, keyboard and gamepad all go through it).
local function newButton(menu, label, action)
    local btn = widgetLibrary():Create(menu, buttonClass(), U.playerController())
    if not U.valid(btn) then error("could not create title button for " .. label) end
    btn.TxtTitle = FText(label)
    btn:BPE_OnSynchronizeProperties()
    btn:SetVisibility(VISIBLE)
    if action then
        state.actions[btn:GetAddress()] = action
        btn.m_OnClick:Add(menu.MenuBox, "HasChild")
    else
        btn:SetIsEnabled(false) -- status line
    end
    return btn
end

local function focus(btn)
    U.try("focus", function()
        btn:SetKeyboardFocus()
        btn:BPF_SetSelected(true, true)
    end)
end

-- Inserts CO-OP after Story by removing the later buttons and re-adding them (UMG has no insert-at-index
-- for Blueprint). Each button keeps its original slot layout.
local function inject(menu)
    local box = menu.MenuBox
    local list = children(box)
    local names = {}
    for _, w in ipairs(list) do names[#names + 1] = nameOf(w) end
    U.log("menu: MenuBox order before: %s", table.concat(names, ", "))

    local storyIndex
    for i, w in ipairs(list) do
        if nameOf(w) == "BtnStory" then storyIndex = i end
    end
    storyIndex = storyIndex or 0

    local referenceLayout = slotLayout(list[math.max(storyIndex, 1)])
    local tail = {}
    for i = storyIndex + 1, #list do
        tail[#tail + 1] = { widget = list[i], layout = slotLayout(list[i]) }
        box:RemoveChild(list[i])
    end

    state.coopButton = newButton(menu, "CO-OP", function() M.openPage(menu, "root") end)
    applyLayout(box:AddChildToVerticalBox(state.coopButton), referenceLayout)
    for _, t in ipairs(tail) do
        applyLayout(box:AddChildToVerticalBox(t.widget), t.layout)
    end

    names = {}
    for _, w in ipairs(children(box)) do names[#names + 1] = nameOf(w) end
    U.log("menu: MenuBox order after: %s", table.concat(names, ", "))
end

-- Submenu -------------------------------------------------------------------------------------------

local function clearPage(menu)
    local box = menu.MenuBox
    for _, b in ipairs(state.pageButtons) do
        state.actions[b:GetAddress()] = nil
        box:RemoveChild(b)
    end
    state.pageButtons = {}
end

-- Saved visibilities are keyed by widget address: UE4SS returns a new Lua wrapper for every lookup, so the
-- wrapper itself can't be a table key.
local function showOriginal(menu)
    for _, saved in pairs(state.savedVisibility) do
        if U.valid(saved.widget) then saved.widget:SetVisibility(saved.visibility) end
    end
    state.savedVisibility = {}
end

local function rememberAndHide(w)
    local addr = w:GetAddress()
    if state.savedVisibility[addr] == nil then
        state.savedVisibility[addr] = { widget = w, visibility = w:GetVisibility() }
    end
    w:SetVisibility(COLLAPSED)
end

local function hideOriginal(menu)
    -- Everything in MenuBox except the current page's buttons (those are in state.actions; CO-OP is too, so
    -- it's hidden explicitly).
    for _, w in ipairs(children(menu.MenuBox)) do
        if not state.actions[w:GetAddress()] then rememberAndHide(w) end
    end
    if U.valid(state.coopButton) then rememberAndHide(state.coopButton) end
end

local function closeSubmenu(menu)
    clearPage(menu)
    showOriginal(menu)
    state.page = nil
    if U.valid(state.coopButton) then focus(state.coopButton) end
end

local PARENT = { root = nil, host = "root", join = "root", lobby_host = "host", lobby_join = "join" }

local function back(menu)
    local parent = PARENT[state.page]
    if state.page == "lobby_host" or state.page == "lobby_join" then S.leave() end
    if parent then M.openPage(menu, parent) else closeSubmenu(menu) end
end

local function hostLobby(menu, mode)
    local ok, err = S.host(mode)
    state.lastError = not ok and tostring(err) or nil
    M.openPage(menu, "lobby_host")
end

local function joinLobby(menu, address)
    state.joinTarget = address
    local ok, err = S.join(address)
    state.lastError = not ok and tostring(err) or nil
    M.openPage(menu, "lobby_join")
end

local function upper(s) return tostring(s or ""):upper() end

-- Live pages are rebuilt when what they show changes: the session for the lobbies, the tailnet for JOIN.
-- Static pages return nil.
local function pageKey(page)
    if page == "join" then return TailCoop_Peers and TailCoop_Peers() or "" end
    if page ~= "lobby_host" and page ~= "lobby_join" then return nil end
    local st = S.status()
    return table.concat({ st.state, st.peer or "", st.detail or "", S.mode or "", state.lastError or "" }, "|")
end

local PAGES = {
    root = function(menu)
        return {
            { "HOST GAME", function() M.openPage(menu, "host") end },
            { "JOIN GAME", function() M.openPage(menu, "join") end },
            { "BACK", function() back(menu) end },
        }
    end,
    host = function(menu)
        local function mode(label, key)
            if M.ENABLED_MODES[key] then
                return { label, function() hostLobby(menu, key) end }
            end
            return { label .. " (SOON)" }
        end
        return {
            mode("TRAINING ROOM", "training"),
            mode("ARENA", "arena"),
            mode("STORY", "story"),
            { "BACK", function() back(menu) end },
        }
    end,
    join = function(menu)
        local items, listed = {}, {}
        local net = N.tailnet()
        for _, p in ipairs(net.peers) do
            if p.online then
                items[#items + 1] = { "JOIN " .. upper(p.name) .. " (" .. p.ip .. ")", function() joinLobby(menu, p.ip) end }
                listed[p.ip] = true
            end
        end
        -- Lab: the other system on this PC (or a -Peer address from the launcher). Otherwise the partner's address
        -- from TailCoop.ini ("peer = 100.x.y.z"), for games that can't list the tailnet (under CrossOver/Wine the
        -- tailscale command isn't reachable).
        local configured = U.config.peer ~= "" and (U.config.system ~= "0" or U.config.peer ~= "127.0.0.1")
        if configured and not listed[U.config.peer] then
            local label = U.config.peer == "127.0.0.1" and "JOIN THIS PC (127.0.0.1)" or ("JOIN " .. U.config.peer)
            items[#items + 1] = { label, function() joinLobby(menu, U.config.peer) end }
        end
        if #items == 0 then items[#items + 1] = { "NO TAILSCALE DEVICES FOUND (SET PEER IN TAILCOOP.INI)" } end
        items[#items + 1] = { "BACK", function() back(menu) end }
        return items
    end,
    lobby_host = function(menu)
        local st = S.status()
        local mode = F.MODE_LABEL[S.mode] or upper(S.mode)
        if st.state == "connected" then
            return {
                { "PARTNER: " .. upper(st.peer) },
                { "START " .. mode, function() F.hostStart(S.mode) end },
                { "CANCEL", function() back(menu) end },
            }
        elseif st.state == "hosting" then
            return {
                { "HOSTING " .. mode .. " ON " .. upper(st.localAddress) },
                { st.detail ~= "" and upper(st.detail) or "WAITING FOR PARTNER..." },
                { "CANCEL", function() back(menu) end },
            }
        end
        return {
            { "CANNOT HOST: " .. upper(state.lastError or st.detail) },
            { "BACK", function() back(menu) end },
        }
    end,
    lobby_join = function(menu)
        local st = S.status()
        if st.state == "connected" then
            return {
                { "CONNECTED TO " .. upper(st.peer) },
                { S.mode and ("HOST PICKED " .. (F.MODE_LABEL[S.mode] or upper(S.mode)) .. ", WAITING FOR START")
                    or "WAITING FOR THE HOST..." },
                { "LEAVE", function() back(menu) end },
            }
        elseif st.state == "connecting" then
            return {
                { "CONNECTING TO " .. upper(state.joinTarget) .. "..." },
                { "CANCEL", function() back(menu) end },
            }
        end
        return {
            { "COULD NOT JOIN: " .. upper(state.lastError or (st.detail ~= "" and st.detail) or st.state) },
            { "BACK", function() back(menu) end },
        }
    end,
}

function M.openPage(menu, page, ctx)
    clearPage(menu)
    hideOriginal(menu)
    state.page = page
    local box = menu.MenuBox
    local layout = state.coopButton and slotLayout(state.coopButton)
    local first
    for _, item in ipairs(PAGES[page](menu, ctx or {})) do
        local btn = newButton(menu, item[1], item[2])
        applyLayout(box:AddChildToVerticalBox(btn), layout)
        state.pageButtons[#state.pageButtons + 1] = btn
        if item[2] and not first then first = btn end
    end
    if first then focus(first) end
    state.renderedKey = pageKey(page)
    U.log("menu: page %s", page)
end

-- Wiring --------------------------------------------------------------------------------------------

-- Runs the action of one of our buttons (once per press, even if two events report it).
local lastActivation = 0
local function activate(btn, how)
    local action = U.valid(btn) and state.actions[btn:GetAddress()] or nil
    if not action then return false end
    local now = os.clock()
    if now - lastActivation < 0.2 then return true end
    lastActivation = now
    U.log("menu: activated %s (%s)", btn.TxtTitle:ToString(), how)
    U.onGameThread("menu action", action)
    return true
end

local ticks = 0

-- The live menu is the instance whose MenuBox actually holds buttons (FindFirstOf can return templates).
local function liveMenu()
    local best
    for _, m in ipairs(FindAllOf(MENU_CLASS) or {}) do
        -- Objects being torn down during a map change can fail lookups: skip them.
        local ok, usable, inViewport = pcall(function()
            local box = m.MenuBox
            return U.valid(m) and U.valid(box) and box:GetChildrenCount() > 0, m:IsInViewport()
        end)
        if ok and usable and (best == nil or inViewport) then best = m end
    end
    return best
end

local function tick()
    ticks = ticks + 1
    -- In a level (training, arena...) there's no title menu: don't walk every object looking for it (up to 5 ms).
    if F.activity then return false end
    local menu = liveMenu()
    if not U.valid(menu) or not U.valid(menu.MenuBox) then return false end
    local addr = menu:GetAddress()
    if state.menuAddr ~= addr then
        -- New title menu instance (first boot or back from a level): inject once its buttons exist.
        if #children(menu.MenuBox) == 0 then return false end
        state.menuAddr = addr
        state.page = nil
        state.pageButtons = {}
        state.savedVisibility = {}
        state.actions = {}
        if not state.clickHooked then
            -- Registered here (game thread, after startup) rather than at mod load: patching a hot engine function
            -- like PanelWidget:HasChild from the Lua thread during startup can crash the game.
            state.clickHooked = true
            RegisterHook("/Script/UMG.PanelWidget:HasChild", function(ctx, content)
                local ok, btn = pcall(function() return content:get() end)
                if ok and U.valid(btn) and state.actions[btn:GetAddress()] then
                    activate(btn, "click")
                end
            end)
        end
        inject(menu)
        -- Lab dev shortcut (Run.ps1 -Role host|join): go through the same menu code a player would click.
        local role = U.config.role
        if (role == "host" or role == "join") and U.config.test ~= "g2" and not state.autoDone then
            state.autoDone = true
            U.log("menu: auto %s (lab shortcut)", role)
            M.openPage(menu, "root")
            if role == "host" then hostLobby(menu, U.config.mode) else joinLobby(menu, U.config.peer) end
        end
        if not state.backHooked then
            -- The Blueprint overrides BPE_HandleNavigationBack, so the native declaration's hook never fires;
            -- hook the override (only possible once the Blueprint class is loaded).
            state.backHooked = true
            U.try("menu back hook", function()
                RegisterHook(menu:GetClass():GetFullName():match("%s(.+)$") .. ":BPE_HandleNavigationBack", function(ctx)
                    if state.page then
                        -- Hook parameters are only valid during the hook: resolve the object now, act later.
                        local owner = ctx:get()
                        U.onGameThread("menu back", function() back(owner) end)
                    end
                end)
                U.log("menu: back hook on the title menu Blueprint")
            end)
        end
    elseif state.page then
        -- Live pages follow the session (partner joined/left, mode picked, errors) and the tailnet list.
        local key = pageKey(state.page)
        if key and key ~= state.renderedKey then M.openPage(menu, state.page) end
        -- Lab shortcut: the auto host presses START 3 s after the partner connects, once the title screen has been
        -- passed (m_eCurrentState leaves IIS = "press any button").
        if U.config.role == "host" and state.autoDone and state.page == "lobby_host" and S.connected()
            and not state.autoStarted then
            local okState, menuState = pcall(function() return menu.m_eCurrentState end)
            local pastTitle = not okState or menuState ~= 0
            state.autoStartAt = state.autoStartAt or (os.time() + 3)
            if pastTitle and os.time() >= state.autoStartAt then
                state.autoStarted = true
                U.log("menu: auto START %s (menu state %s)", tostring(S.mode), tostring(menuState))
                F.hostStart(S.mode)
            end
        end
        -- The game re-shows its buttons on some events (save loaded...); keep them hidden while we're open.
        local ours = {}
        for _, b in ipairs(state.pageButtons) do ours[b:GetAddress()] = true end
        for _, w in ipairs(children(menu.MenuBox)) do
            if not ours[w:GetAddress()] and w:GetVisibility() ~= COLLAPSED then rememberAndHide(w) end
        end
    end
    return false
end

function M.start()
    -- Click (HasChild) and Back hooks are registered from tick() once the title menu exists.
    U.poll("menu tick", 500, tick)
    U.log("menu: watching for the title menu")
end

return M
