-- Daseeki Network — ui_tab_timers.lua
-- The "Timers" tab (spec §3): a World Buff Timers section (Rend, Ony-Horde,
-- Ony-Alliance) with live status + off-CD stamp + a pop-log popup per buff, a
-- Songflowers section (10 Felwood nodes with respawn/UP?/no-data states), and a
-- throttled Broadcast Timers button. Refreshes once per second while visible.

local ADDON, ns = ...
local UI = DaseekiUI
local Dashboard = ns.Dashboard

local ROW_H = 26

local function fstr(parent, key)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    return f
end

local function anchorOf(state)
    if not state then return 0 end
    return math.max(state.lastPop or 0, state.lastKilled or 0)
end

-- World-buff rows: {logKey, icon slot, label}.
local WB_ROWS = {
    { key = "rend", logKey = "rend", slot = 2, label = "Rend (Warchief's)" },
    { key = "onyH", logKey = "onyH", slot = 1, label = "Onyxia — Horde" },
    { key = "onyA", logKey = "onyA", slot = 1, label = "Onyxia — Alliance" },
}

----------------------------------------------------------------------
-- Pop-log popup (shared instance; retargeted per buff).
----------------------------------------------------------------------

local function ensurePopLog()
    if Dashboard._popLog then return Dashboard._popLog end
    local p = CreateFrame("Frame", "DaseekiNetworkPopLog", UIParent, "BackdropTemplate")
    p:SetFrameStrata("DIALOG")
    p:SetSize(320, 300)
    p:SetPoint("CENTER")
    p:SetMovable(true); p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function(self) self:StartMoving() end)
    p:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    p:Hide()
    tinsert(UISpecialFrames, "DaseekiNetworkPopLog")
    UI.Skin(p, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("ground"))
        self:SetBackdropBorderColor(UI.Color("accent"))
    end)
    local title = fstr(p, "header")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -10)
    p.title = title
    local close = UI.MakeButton(p, { text = "X", variant = "quiet", width = 22, height = 20,
        onClick = function() p:Hide() end })
    close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)

    local scroll = CreateFrame("ScrollFrame", nil, p)
    scroll:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -36)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -12, 12)
    scroll:SetClipsChildren(true)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1); scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 28)))
    end)
    p._child = child
    p._lines = {}
    Dashboard._popLog = p
    return p
end

local function showPopLog(logKey, titleText)
    local p = ensurePopLog()
    p.title:SetText(titleText)
    local child = p._child
    for _, l in ipairs(p._lines) do l:Hide() end
    local logs = ns.Store.GetTimers().logs or {}
    local list = logs[logKey] or {}
    local W = p:GetWidth() - 24
    child:SetWidth(W)
    local y = 0
    local nowE = Dashboard.Now()
    if #list == 0 then
        local l = p._lines[1] or fstr(child, "muted"); p._lines[1] = l
        l:ClearAllPoints(); l:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0); l:SetWidth(W)
        l:SetText("No pops recorded this reset."); l:Show()
        y = 20
    else
        for i = 1, math.min(#list, 50) do
            local e = list[i]
            local l = p._lines[i]
            if not l then l = fstr(child, "body"); l:SetJustifyH("LEFT"); l:SetWordWrap(false); p._lines[i] = l end
            l:ClearAllPoints()
            l:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            l:SetWidth(W)
            local tag = e.killed and Dashboard.Colored("NPC Killed","danger") or (e.quest and Dashboard.Colored("Quest","ok") or Dashboard.Colored("Pop","muted"))
            local when = date("%m/%d %H:%M", e.epoch or nowE)
            local ago = Dashboard.FormatDuration(nowE - (e.epoch or nowE))
            l:SetText(("%s  %s  %s  (%s ago)"):format(when, tag, e.who or "?", ago))
            l:Show()
            y = y + 18
        end
    end
    child:SetHeight(math.max(y, 1))
    p:Show()
end

----------------------------------------------------------------------
-- Tab registration
----------------------------------------------------------------------

Dashboard.RegisterTab("timers", function(host)
    local obj = {}
    local box = UI.FlatFrame(host, "inset", "border")
    box:SetAllPoints(host)

    -- World Buff Timers section.
    local wbHdr = UI.MakeSectionHeader(box, "World Buff Timers")
    wbHdr:SetPoint("TOPLEFT", box, "TOPLEFT", 12, -10)
    wbHdr:SetPoint("TOPRIGHT", box, "TOPRIGHT", -12, -10)

    local wbRows = {}
    local prev
    for i, def in ipairs(WB_ROWS) do
        local r = CreateFrame("Frame", nil, box)
        r:SetHeight(ROW_H)
        if prev then
            r:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -2)
            r:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -2)
        else
            r:SetPoint("TOPLEFT", wbHdr, "BOTTOMLEFT", 0, -4)
            r:SetPoint("TOPRIGHT", wbHdr, "BOTTOMRIGHT", 0, -4)
        end
        r._def = def
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", r, "LEFT", 2, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.icon:SetTexture(Dashboard.AURA_META[def.slot].icon)
        r.name = fstr(r, "body"); r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0); r.name:SetText(def.label)
        r.status = fstr(r, "body"); r.status:SetPoint("LEFT", r.name, "RIGHT", 12, 0)
        r.log = UI.MakeButton(r, { text = "Log", variant = "quiet", width = 44, height = 20,
            onClick = function() showPopLog(def.logKey, def.label .. " — Pop Log") end })
        r.log:SetPoint("RIGHT", r, "RIGHT", 2, 0)
        r.stamp = fstr(r, "small"); r.stamp:SetPoint("RIGHT", r.log, "LEFT", -10, 0); r.stamp:SetJustifyH("RIGHT")
        wbRows[i] = r
        prev = r
    end

    -- Songflowers section.
    local sfHdr = UI.MakeSectionHeader(box, "Songflowers (Felwood)")
    sfHdr:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -12)
    sfHdr:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -12)

    -- Scroll the songflower list (10 rows) so a short window still fits.
    local sfScroll = CreateFrame("ScrollFrame", nil, box)
    sfScroll:SetPoint("TOPLEFT", sfHdr, "BOTTOMLEFT", 0, -4)
    sfScroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -12, 40)
    sfScroll:SetClipsChildren(true)
    sfScroll:EnableMouseWheel(true)
    local sfChild = CreateFrame("Frame", nil, sfScroll)
    sfChild:SetSize(1, 1); sfScroll:SetScrollChild(sfChild)
    sfScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, sfChild:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 28)))
    end)

    local sfRows = {}
    local nodes = ns.Timers and ns.Timers.NODES and ns.Timers.NODES.flower or {}
    for i = 1, #nodes do
        local r = CreateFrame("Frame", nil, sfChild)
        r:SetHeight(20)
        r:SetPoint("TOPLEFT", sfChild, "TOPLEFT", 0, -((i - 1) * 20))
        r:SetPoint("TOPRIGHT", sfChild, "TOPRIGHT", 0, -((i - 1) * 20))
        local num = fstr(r, "small"); num:SetPoint("LEFT", r, "LEFT", 2, 0); num:SetWidth(20)
        num:SetText(tostring(i))
        r.name = fstr(r, "body"); r.name:SetPoint("LEFT", num, "RIGHT", 4, 0)
        r.name:SetText(nodes[i].label or ("Node " .. i))
        r.state = fstr(r, "body"); r.state:SetPoint("RIGHT", r, "RIGHT", 2, 0); r.state:SetJustifyH("RIGHT")
        r._nodeKey = "flower" .. i
        sfRows[i] = r
    end
    sfChild:SetHeight(math.max(#nodes * 20, 1))
    sfScroll:SetScript("OnSizeChanged", function() sfChild:SetWidth(sfScroll:GetWidth()) end)

    -- Broadcast Timers button (bottom).
    local bcast = UI.MakeButton(box, {
        text = "Broadcast Timers", width = 160, height = 24,
        onClick = function(self)
            local nowT = GetTime()
            if obj._lastBcast and (nowT - obj._lastBcast) < 60 then
                ns:Print("broadcast throttled (60s).")
                return
            end
            if ns.Mesh and ns.Mesh.BroadcastTimers and ns.Timers then
                ns:SafeCall(ns.Mesh.BroadcastTimers, ns.Timers.GetSnapshot())
                obj._lastBcast = nowT
                ns:Print("timers broadcast to guild/mesh.")
            else
                ns:Print("mesh broadcast arrives in a later update.")
            end
        end,
    })
    bcast:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 12, 10)
    local bcastHint = fstr(box, "small")
    bcastHint:SetPoint("LEFT", bcast, "RIGHT", 10, 0)
    bcastHint:SetText("Sends your timer data to the mesh (throttled 60s).")
    bcastHint:SetTextColor(UI.Color("faint"))

    -- Refresh routine.
    function obj.Refresh()
        local T = ns.Timers
        local nowE = Dashboard.Now()
        for _, r in ipairs(wbRows) do
            local def = r._def
            local state = T and T.state and T.state[def.key]
            local anchor = anchorOf(state)
            local info = T and T.ComputeCD and T.ComputeCD(def.key, anchor, nowE)
            if not info or anchor <= 0 then
                r.status:SetText("no data"); r.status:SetTextColor(UI.Color("faint"))
                r.stamp:SetText("")
            elseif info.ready then
                r.status:SetText("Can Pop"); r.status:SetTextColor(UI.Color("ok"))
                r.stamp:SetText("")
            else
                local rem = info.remaining or 0
                local killed = state.lastKilled and state.lastKilled >= (state.lastPop or 0)
                if rem <= 20 * 60 then
                    r.status:SetText((killed and "Killed · " or "") .. Dashboard.FormatDuration(rem))
                    r.status:SetTextColor(UI.Color("danger"))
                    r.status._pulse = true
                else
                    r.status:SetText(Dashboard.FormatDuration(rem))
                    r.status:SetTextColor(UI.Color("accent"))
                    r.status._pulse = false
                end
                r.stamp:SetText("off CD " .. date("%H:%M", info.nextAt))
                r.stamp:SetTextColor(UI.Color("muted"))
            end
        end
        for _, r in ipairs(sfRows) do
            local ns_state = T and T.GetNodeState and T.GetNodeState(r._nodeKey)
            if not ns_state or ns_state.state == "unknown" then
                r.state:SetText("No data"); r.state:SetTextColor(UI.Color("faint"))
            elseif ns_state.state == "down" then
                r.state:SetText("Respawn " .. Dashboard.FormatDuration(ns_state.remaining))
                r.state:SetTextColor(UI.Color("accent"))
            else -- up
                r.state:SetText("UP?"); r.state:SetTextColor(UI.Color("ok"))
            end
        end
    end

    -- 1s ticker + red-status pulse while the tab is visible.
    local accum = 0
    host:SetScript("OnUpdate", function(self, elapsed)
        accum = accum + elapsed
        local a = 0.5 + 0.5 * math.abs(math.sin(GetTime() * 3))
        for _, r in ipairs(wbRows) do
            if r.status._pulse then r.status:SetAlpha(a) else r.status:SetAlpha(1) end
        end
        if accum >= 1 then accum = 0; ns:SafeCall(obj.Refresh) end
    end)
    -- A hidden frame receives no OnUpdate, so the ticker pauses automatically
    -- when another tab is shown; no explicit teardown needed.

    box:SetScript("OnSizeChanged", function() obj.Refresh() end)
    return obj
end)
