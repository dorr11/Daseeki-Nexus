-- Daseeki Nexus — ui_instancespanel.lua
-- The INSTANCES PANEL — the lower-left panel of the control-panel dashboard's panel
-- layer (owner round-6). It REPLACES the retired Instances TAB (ui_tab_instances.lua):
-- the tab dissolves into this compact panel that sits beside the timers panel in the
-- bottom row of the Characters screen. Content: per-account instance-cap meters (hour
-- + day rolling windows) + a short newest-first recent-entries list.
--
-- The proven view-model logic is re-housed here verbatim from the retired tab as
-- ns.InstancesUI (meter-state classification, cap model, money/ago/row formatting,
-- entry gather/filter, account sort, class lookup) — all pure and headless-tested.
--
-- AESTHETIC (control-panel + round-4 pop pass): flat token fills, uppercase micro
-- labels at `muted`, borderLite edges, attention-inverted meter tokens (calm under
-- cap, amber at warn, danger at cap). No grain/serif. All colors via theme tokens.
--
-- Clean-room build on our own DaseekiUI stack. No third-party code or identifiers.

local ADDON, ns = ...
local UI = DaseekiUI                 -- nil under the headless harness; only ever
local Dashboard = ns.Dashboard       -- dereferenced inside function bodies below.

local InstancesUI = {}
ns.InstancesUI = InstancesUI
local InstancesPanel = {}
ns.InstancesPanel = InstancesPanel

-- ════════════════════════════════════════════════════════════════════════════
--  PURE VIEW-MODEL LOGIC (frame-free → headless-tested). Re-housed verbatim from
--  the retired ui_tab_instances.lua.
-- ════════════════════════════════════════════════════════════════════════════

-- Attention-inverted token per meter state: calm under cap, amber at warn, danger cap.
local STATE_TOKEN = { ok = "muted", warn = "warn", cap = "danger" }
function InstancesUI.StateToken(state) return STATE_TOKEN[state] or "muted" end

-- Classify a rolling-window count against its cap + warn threshold. Pure.
function InstancesUI.MeterState(count, cap, warn)
    count = count or 0
    if cap and count >= cap then return "cap" end
    if warn and count >= warn then return "warn" end
    return "ok"
end

-- Seconds until a rolling-window slot re-opens (nextSlotAt - now), floored at 0. Pure.
function InstancesUI.NextSlotSeconds(nextSlotAt, nowE)
    if not nextSlotAt then return nil end
    local rem = nextSlotAt - (nowE or 0)
    if rem < 0 then rem = 0 end
    return math.floor(rem)
end

-- Countdown numerals as M:SS. Pure.
function InstancesUI.FormatMSS(sec)
    sec = math.max(0, math.floor(sec or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Assemble a per-account meter model from the engine's WindowCounts shape. Pure.
function InstancesUI.MeterModel(counts, nowE, caps)
    counts = counts or {}
    local E = caps or ns.Instances or {}
    local hCap, hWarn = E.HOURLY_CAP or 5,  E.WARN_HOURLY or 4
    local dCap, dWarn = E.DAILY_CAP or 30,  E.WARN_DAILY  or 27
    local hState = InstancesUI.MeterState(counts.hour, hCap, hWarn)
    local dState = InstancesUI.MeterState(counts.day,  dCap, dWarn)
    local model = {
        hour = { count = counts.hour or 0, cap = hCap, state = hState,
                 token = InstancesUI.StateToken(hState), atCap = (hState == "cap") },
        day  = { count = counts.day or 0,  cap = dCap, state = dState,
                 token = InstancesUI.StateToken(dState), atCap = (dState == "cap") },
    }
    if model.hour.atCap then model.hour.countdown = InstancesUI.NextSlotSeconds(counts.nextHourSlotAt, nowE) end
    if model.day.atCap  then model.day.countdown  = InstancesUI.NextSlotSeconds(counts.nextDaySlotAt,  nowE) end
    return model
end

-- Signed copper -> "Ng Ms" / "Ms Nc" / "Nc" (compact register cell). Pure.
function InstancesUI.FormatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    local sign = ""
    if copper < 0 then sign = "-"; copper = -copper end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%s%dg %ds", sign, g, s) end
    if s > 0 then return string.format("%s%ds %dc", sign, s, c) end
    return string.format("%s%dc", sign, c)
end

-- "just now" under a minute, else "<duration> ago". Pure.
function InstancesUI.AgoText(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec < 60 then return "just now" end
    local D = ns.Dashboard
    local dur = (D and D.FormatDuration and D.FormatDuration(sec)) or (math.floor(sec / 60) .. "m")
    return dur .. " ago"
end

-- Assemble one register-row model from an entry + resolved class. Pure.
function InstancesUI.RowModel(entry, nameRealm, classTag, nowE)
    entry = entry or {}
    local D = ns.Dashboard
    local ago = (nowE or 0) - (entry.t or 0)
    if ago < 0 then ago = 0 end
    local gold = entry.gold or 0
    local xp = entry.xp or 0
    return {
        agoText   = InstancesUI.AgoText(ago),
        nameRealm = nameRealm,
        classTag  = classTag,
        name      = (D and D.ShortName and D.ShortName(nameRealm))
                    or (nameRealm and nameRealm:match("^([^%-]+)")) or nameRealm,
        instance  = entry.name or "?",
        durText   = (D and D.FormatDuration and D.FormatDuration(entry.dur or 0)) or (math.floor(entry.dur or 0) .. "s"),
        gold      = gold,
        goldText  = InstancesUI.FormatMoney(gold),
        goldToken = (gold < 0) and "danger" or "muted",
        xp        = xp,
        xpText    = (xp ~= 0) and ((xp > 0 and "+" or "") .. xp .. " xp") or nil,
        merged    = entry.merged and true or false,
    }
end

-- Flatten every account/character's entries into one newest-first list. Pure.
function InstancesUI.GatherEntries(instancesData)
    local out = {}
    if type(instancesData) == "table" then
        for aid, charMap in pairs(instancesData) do
            if type(charMap) == "table" then
                for nameRealm, crec in pairs(charMap) do
                    local entries = crec and crec.entries
                    if type(entries) == "table" then
                        for i = 1, #entries do
                            local e = entries[i]
                            if type(e) == "table" then
                                out[#out + 1] = { aid = aid, nameRealm = nameRealm, entry = e, t = e.t or 0 }
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        if a.aid ~= b.aid then return tostring(a.aid) < tostring(b.aid) end
        return tostring(a.nameRealm) < tostring(b.nameRealm)
    end)
    return out
end

-- Scope (single account or all) + "this character" modifier. Pure.
function InstancesUI.FilterEntries(list, scope, selfNameRealm)
    scope = scope or {}
    local out = {}
    for _, item in ipairs(list or {}) do
        local ok = true
        if scope.aid and item.aid ~= scope.aid then ok = false end
        if ok and scope.thisChar and item.nameRealm ~= selfNameRealm then ok = false end
        if ok then out[#out + 1] = item end
    end
    return out
end

-- Account ids sorted numerically (falls back to string order). Pure.
function InstancesUI.SortedAccountIDs(accountsMap)
    local ids = {}
    for aid in pairs(accountsMap or {}) do ids[#ids + 1] = aid end
    table.sort(ids, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
    end)
    return ids
end

-- nameRealm -> classTag lookup across every account's characters + homeless. Pure.
function InstancesUI.ClassLookup(data)
    local map = {}
    local accounts = data and data.accounts
    if type(accounts) == "table" then
        local function scan(t)
            if type(t) ~= "table" then return end
            for nameRealm, rec in pairs(t) do
                if type(rec) == "table" and rec.classTag then map[nameRealm] = rec.classTag end
            end
        end
        for _, bucket in pairs(accounts) do
            scan(bucket.characters)
            scan(bucket.homeless)
        end
    end
    return map
end

-- Per-character EXPERIENCE / REST row (owner round-10 item 2). Consumes the record
-- fields the engine agent is adding concurrently (rec.xp / rec.xpMax / rec.restedXP)
-- GUARDEDLY — an absent field renders "—" so this is safe before the engine lands.
-- A level-60 character shows just "Level 60" (no xp / rested). Rested% is restedXP as a
-- percent of xpMax, "N% (Max)" at >= 150%. Pure/headless-tested.
local EMDASH = "\226\128\148"
function InstancesUI.ExpRow(rec, nameRealm, classTag)
    rec = rec or {}
    local D = ns.Dashboard
    local name = (D and D.ShortName and D.ShortName(nameRealm))
                 or (nameRealm and nameRealm:match("^([^%-]+)")) or nameRealm
    local level = rec.level or 0
    local maxed = level >= 60
    local xpText, restedText
    if not maxed then
        local xp, xpMax, rested = rec.xp, rec.xpMax, rec.restedXP
        if xp and xpMax and xpMax > 0 then xpText = ("%d/%d"):format(xp, xpMax) else xpText = EMDASH end
        if rested and xpMax and xpMax > 0 then
            local pct = math.floor(rested / xpMax * 100 + 0.5)
            restedText = (pct >= 150) and (pct .. "% (Max)") or (pct .. "%")
        else
            restedText = EMDASH
        end
    end
    return { nameRealm = nameRealm, classTag = classTag, name = name, level = level,
             maxed = maxed, levelText = "Level " .. level, xpText = xpText, restedText = restedText }
end

-- All characters { nameRealm, classTag, level } ordered by LEVEL desc then name asc,
-- with an "All" sentinel { all = true } prepended (owner round-10 item 3 dropdown).
-- Pure over a Store.GetData() shape.
function InstancesUI.CharList(data)
    local out = {}
    local accounts = data and data.accounts
    if type(accounts) == "table" then
        local function scan(t)
            if type(t) ~= "table" then return end
            for nameRealm, rec in pairs(t) do
                if type(rec) == "table" then
                    out[#out + 1] = { nameRealm = nameRealm, classTag = rec.classTag, level = rec.level or 0 }
                end
            end
        end
        for _, bucket in pairs(accounts) do
            scan(bucket.characters)
            scan(bucket.homeless)
        end
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return tostring(a.nameRealm) < tostring(b.nameRealm)
    end)
    table.insert(out, 1, { all = true, label = "All" })
    return out
end

-- ════════════════════════════════════════════════════════════════════════════
--  COMPACT PANEL (in-game only; UI is non-nil there)
-- ════════════════════════════════════════════════════════════════════════════

local PAD        = 10
local METER_H    = 18
local METER_GAP  = 2
local REC_H      = 17
local REC_GAP    = 1
local MAX_METERS = 8
local MAX_REC    = 40

local function tag(frame, id)
    if ns.Audit and ns.Audit.Tag and frame then ns.Audit.Tag(frame, id) end
    return frame
end
local function fstr(parent, key, justify)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(Dashboard.Font(key))   -- round-11 item 2: ARIALN dashboard type
    if justify then f:SetJustifyH(justify) end
    return f
end
local function microLabel(parent, text)
    local l = fstr(parent, "microLabel")
    l:SetTextColor(UI.Color("muted"))   -- pop pass
    if text then l:SetText(text) end
    return l
end

-- Build the instances panel into `host` (a raised panel frame from ui_cards). Returns
-- a controller with :Refresh() and .frame.
function InstancesPanel.Attach(host)
    local P = { _meters = {}, _rows = {} }
    P.frame = host

    P.view = "instances"       -- "instances" | "exp"  (owner round-10 item 2)
    P.selectedChar = nil       -- nil = All  (owner round-10 item 3)

    -- Header: INSTANCES | EXP toggle (left) + caps meta (right).
    local toggle = CreateFrame("Frame", nil, host)
    toggle:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -PAD); toggle:SetHeight(14)
    tag(toggle, "instances.header")
    P._tSegs = {}
    local function makeTSeg(key, text)
        local b = CreateFrame("Button", nil, toggle)
        local l = fstr(b, "microLabel"); l:SetPoint("LEFT", b, "LEFT", 0, 0); l:SetText(text)
        b:SetSize((l:GetStringWidth() or 40) + 2, 14); b._lbl = l; b._key = key
        b:SetScript("OnClick", function() P.view = key; P.Refresh() end)
        function b:Apply(active) self._lbl:SetTextColor(UI.Color(active and "accent" or "muted")) end
        P._tSegs[#P._tSegs + 1] = b
        return b
    end
    local segI = makeTSeg("instances", "INSTANCES"); segI:SetPoint("LEFT", toggle, "LEFT", 0, 0)
    local sep = fstr(toggle, "microLabel"); sep:SetText("|"); sep:SetTextColor(UI.Color("faint"))
    sep:SetPoint("LEFT", segI, "RIGHT", 6, 0)
    local segE = makeTSeg("exp", "EXP"); segE:SetPoint("LEFT", sep, "RIGHT", 6, 0)

    local meta = fstr(host, "microLabel", "RIGHT")
    meta:SetPoint("TOPRIGHT", host, "TOPRIGHT", -PAD, -PAD)
    meta:SetTextColor(UI.Color("muted"))
    P.meta = meta

    -- Character DROPDOWN (round-10 item 3): filters BOTH views to a selected character
    -- ("All" default). Below the toggle. Clicking opens a scrollable popup of all chars
    -- (level desc, name asc) + "All" at top; the cap meters below stay global.
    local dd = CreateFrame("Button", nil, host, "BackdropTemplate")
    dd:SetHeight(17)
    dd:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -(PAD + 18))
    dd:SetPoint("RIGHT", host, "RIGHT", -PAD, 0)
    UI.Skin(dd, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP); self:SetBackdropColor(UI.Color("inset")); self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)
    dd.label = fstr(dd, "small"); dd.label:SetPoint("LEFT", dd, "LEFT", 7, 0); dd.label:SetText("All")
    local ddArrow = fstr(dd, "small"); ddArrow:SetPoint("RIGHT", dd, "RIGHT", -6, 0); ddArrow:SetText("\226\150\190")
    ddArrow:SetTextColor(UI.Color("muted"))
    tag(dd, "instances.charselect")
    P.dd = dd
    -- Popup list (own frame, DIALOG strata; 10 rows visible, scroll for the rest).
    local DD_ROW_H, DD_VIS = 16, 10
    local pop = CreateFrame("Frame", nil, dd, "BackdropTemplate")
    pop:SetFrameStrata("DIALOG"); pop:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -1); pop:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", 0, -1)
    pop:SetHeight(DD_VIS * DD_ROW_H + 4)
    UI.Skin(pop, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP); self:SetBackdropColor(UI.Color("ground")); self:SetBackdropBorderColor(UI.Color("accent"))
    end)
    pop:Hide()
    local popScroll = CreateFrame("ScrollFrame", nil, pop); popScroll:SetPoint("TOPLEFT", 2, -2); popScroll:SetPoint("BOTTOMRIGHT", -2, 2)
    popScroll:SetClipsChildren(true); popScroll:EnableMouseWheel(true)
    local popChild = CreateFrame("Frame", nil, popScroll); popChild:SetSize(1, 1); popScroll:SetScrollChild(popChild)
    popScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, popChild:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(maxs, self:GetVerticalScroll() - delta * DD_ROW_H * 2)))
    end)
    P._ddRows = {}
    local function ddRebuild()
        local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
        local list = InstancesUI.CharList(data)
        local W = popScroll:GetWidth(); if W < 1 then W = dd:GetWidth() - 4 end
        popChild:SetWidth(W)
        for _, r in ipairs(P._ddRows) do r:Hide() end
        local y = 0
        for i, item in ipairs(list) do
            local r = P._ddRows[i]
            if not r then
                r = CreateFrame("Button", nil, popChild)
                r:SetHeight(DD_ROW_H)
                r.txt = fstr(r, "small"); r.txt:SetPoint("LEFT", r, "LEFT", 6, 0); r.txt:SetWordWrap(false)
                r.txt:SetPoint("RIGHT", r, "RIGHT", -6, 0); r.txt:SetJustifyH("LEFT")
                r:SetScript("OnEnter", function(self) self.txt:SetTextColor(UI.Color("accent")) end)
                P._ddRows[i] = r
            end
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", popChild, "TOPLEFT", 0, -y); r:SetPoint("TOPRIGHT", popChild, "TOPRIGHT", 0, -y)
            if item.all then
                r.txt:SetText("All"); r.txt:SetTextColor(UI.Color("text"))
                r._sel = nil
                r:SetScript("OnLeave", function(self) self.txt:SetTextColor(UI.Color("text")) end)
            else
                local cr, cg, cb = Dashboard.ClassColor(item.classTag)
                r.txt:SetText(("%s  \194\183 %d"):format((item.nameRealm:match("^([^%-]+)") or item.nameRealm), item.level))
                if cr then r.txt:SetTextColor(cr, cg, cb) else r.txt:SetTextColor(UI.Color("text")) end
                r._sel = item.nameRealm
                r:SetScript("OnLeave", function(self) if cr then self.txt:SetTextColor(cr, cg, cb) else self.txt:SetTextColor(UI.Color("text")) end end)
            end
            r:SetScript("OnClick", function(self) P.selectedChar = self._sel; pop:Hide(); P.Refresh() end)
            r:Show()
            y = y + DD_ROW_H
        end
        popChild:SetHeight(math.max(y, 1))
    end
    dd:SetScript("OnClick", function() if pop:IsShown() then pop:Hide() else ddRebuild(); pop:Show() end end)
    P._ddRebuild = ddRebuild

    -- Meters container (per-account rows + ALL row) — GLOBAL, below the dropdown.
    local METERS_TOP = PAD + 40
    local metersTop = CreateFrame("Frame", nil, host)
    metersTop:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -METERS_TOP)
    metersTop:SetPoint("RIGHT", host, "RIGHT", -PAD, 0)
    metersTop:SetHeight(1)
    tag(metersTop, "instances.meters")
    P.metersTop, P._metersTop = metersTop, METERS_TOP

    local function makeMeterRow()
        local r = CreateFrame("Frame", nil, host)
        r:SetHeight(METER_H)
        r.label = fstr(r, "small"); r.label:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.day = fstr(r, "numeral", "RIGHT"); r.day:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.hour = fstr(r, "numeral", "RIGHT"); r.hour:SetPoint("RIGHT", r.day, "LEFT", -14, 0)
        return r
    end
    local function getMeter(i)
        local r = P._meters[i]; if not r then r = makeMeterRow(); P._meters[i] = r end; return r
    end
    P._makeMeterRow = makeMeterRow

    -- Recent-entries scroll list below the meters (compact: name · instance · ago).
    local recLbl = microLabel(host, "RECENT")
    P.recLbl = recLbl
    local scroll = CreateFrame("ScrollFrame", nil, host)
    scroll:SetClipsChildren(true); scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll); child:SetSize(1, 1); scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 30)))
    end)
    P._scroll, P._child = scroll, child
    tag(scroll, "instances.recent")
    local emptyFS = fstr(child, "muted"); emptyFS:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -2)
    emptyFS:SetText("No instance entries recorded."); emptyFS:Hide()
    P._empty = emptyFS

    local function makeRecRow()
        local r = CreateFrame("Frame", nil, child)
        r:SetHeight(REC_H)
        r.name = fstr(r, "small"); r.name:SetPoint("LEFT", r, "LEFT", 0, 0); r.name:SetWordWrap(false)
        r.ago = fstr(r, "microLabel", "RIGHT"); r.ago:SetPoint("RIGHT", r, "RIGHT", 0, 0); r.ago:SetTextColor(UI.Color("muted"))
        r.inst = fstr(r, "small"); r.inst:SetPoint("LEFT", r.name, "RIGHT", 8, 0)
        r.inst:SetPoint("RIGHT", r.ago, "LEFT", -8, 0); r.inst:SetWordWrap(false); r.inst:SetJustifyH("LEFT")
        r.inst:SetTextColor(UI.Color("muted"))
        return r
    end
    local function getRec(i)
        local r = P._rows[i]; if not r then r = makeRecRow(); P._rows[i] = r end; return r
    end

    -- EXP rows (round-10 item 2): class-colored name · level · xp cur/total · rested%.
    P._expRows = {}
    local function makeExpRow()
        local r = CreateFrame("Frame", nil, child)
        r:SetHeight(REC_H)
        r.name = fstr(r, "small"); r.name:SetPoint("LEFT", r, "LEFT", 0, 0); r.name:SetWordWrap(false)
        r.rested = fstr(r, "numeral", "RIGHT"); r.rested:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.xp = fstr(r, "numeral", "RIGHT"); r.xp:SetPoint("RIGHT", r.rested, "LEFT", -12, 0)
        r.lvl = fstr(r, "microLabel"); r.lvl:SetPoint("LEFT", r.name, "RIGHT", 8, 0); r.lvl:SetTextColor(UI.Color("muted"))
        return r
    end
    local function getExp(i)
        local r = P._expRows[i]; if not r then r = makeExpRow(); P._expRows[i] = r end; return r
    end

    -- Resolve a character record (for xp/rested fields) across all account buckets.
    local function resolveRec(data, nameRealm)
        local accounts = data and data.accounts
        if type(accounts) ~= "table" then return nil end
        for _, b in pairs(accounts) do
            local rec = (b.characters and b.characters[nameRealm]) or (b.homeless and b.homeless[nameRealm])
            if rec then return rec end
        end
    end

    function P.Refresh()
        local nowE = (Dashboard and Dashboard.Now and Dashboard.Now()) or (GetServerTime and GetServerTime()) or 0
        local Inst = ns.Instances
        local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
        local view = (Inst and Inst.AllAccounts and Inst.AllAccounts(nowE)) or { accounts = {}, total = {} }

        -- Meta caps line.
        local hCap = (Inst and Inst.HOURLY_CAP) or 5
        local dCap = (Inst and Inst.DAILY_CAP) or 30
        meta:SetText(("caps %d/hr \194\183 %d/day"):format(hCap, dCap))

        -- Meter rows: one per account (numerically sorted), then the ALL total row.
        local aids = InstancesUI.SortedAccountIDs(view.accounts)
        local n, prev = 0, nil
        local function placeMeter(label, counts)
            if n >= MAX_METERS then return end
            n = n + 1
            local r = getMeter(n)
            r:ClearAllPoints()
            if prev then r:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -METER_GAP); r:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -METER_GAP)
            else r:SetPoint("TOPLEFT", metersTop, "TOPLEFT", 0, 0); r:SetPoint("TOPRIGHT", metersTop, "TOPRIGHT", 0, 0) end
            local m = InstancesUI.MeterModel(counts, nowE, Inst)
            r.label:SetText(label); r.label:SetTextColor(UI.Color("text"))
            local hTxt = ("Hr %d/%d"):format(m.hour.count, m.hour.cap)
            if m.hour.countdown then hTxt = hTxt .. " " .. InstancesUI.FormatMSS(m.hour.countdown) end
            r.hour:SetText(hTxt); r.hour:SetTextColor(UI.Color(m.hour.token))
            local dTxt = ("Day %d/%d"):format(m.day.count, m.day.cap)
            if m.day.countdown then dTxt = dTxt .. " " .. InstancesUI.FormatMSS(m.day.countdown) end
            r.day:SetText(dTxt); r.day:SetTextColor(UI.Color(m.day.token))
            r:Show()
            prev = r
        end
        for _, aid in ipairs(aids) do placeMeter("Acct " .. aid, view.accounts[aid]) end
        placeMeter("All", view.total)
        for j = n + 1, #P._meters do P._meters[j]:Hide() end

        -- Toggle + dropdown repaint.
        for _, seg in ipairs(P._tSegs) do seg:Apply(P.view == seg._key) end
        dd.label:SetText(P.selectedChar and (P.selectedChar:match("^([^%-]+)") or P.selectedChar) or "All")

        -- List label + scroll region, positioned below the (global) meters.
        local metersH = n * METER_H + math.max(0, n - 1) * METER_GAP
        local listTop = P._metersTop + metersH + 8
        local isExp = (P.view == "exp")
        recLbl:SetText(isExp and "EXPERIENCE" or "RECENT")
        recLbl:ClearAllPoints(); recLbl:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -listTop)
        scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -(listTop + 15))
        scroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -PAD, PAD)

        local classMap = InstancesUI.ClassLookup(data or {})
        local W = scroll:GetWidth(); if W < 1 then W = host:GetWidth() - 2 * PAD end
        child:SetWidth(W)
        for _, r in ipairs(P._rows) do r:Hide() end
        for _, r in ipairs(P._expRows) do r:Hide() end
        local y, shown = 0, 0

        if isExp then
            -- EXP view: per-character xp / rested rows, filtered by the dropdown.
            local list = InstancesUI.CharList(data)
            for _, item in ipairs(list) do
                if not item.all and (not P.selectedChar or item.nameRealm == P.selectedChar) then
                    local m = InstancesUI.ExpRow(resolveRec(data, item.nameRealm), item.nameRealm, item.classTag)
                    shown = shown + 1
                    local r = getExp(shown)
                    r:ClearAllPoints(); r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y); r:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                    local cr, cg, cb = Dashboard.ClassColor(m.classTag)
                    r.name:SetText(m.name or "?")
                    if cr then r.name:SetTextColor(cr, cg, cb) else r.name:SetTextColor(UI.Color("text")) end
                    r.lvl:SetText(m.levelText)
                    r.xp:SetText(m.xpText or ""); r.xp:SetTextColor(UI.Color("muted"))
                    r.rested:SetText(m.restedText or ""); r.rested:SetTextColor(UI.Color("muted"))
                    r:Show()
                    y = y + REC_H + REC_GAP
                end
            end
            P._empty:SetText("No characters."); P._empty:SetShown(shown == 0)
        else
            -- INSTANCES view: recent entries (newest first), filtered by the dropdown.
            local all = InstancesUI.GatherEntries((data and data.instances) or {})
            for i = 1, #all do
                local item = all[i]
                if shown >= MAX_REC then break end
                if (not P.selectedChar) or (item.nameRealm == P.selectedChar) then
                    local model = InstancesUI.RowModel(item.entry, item.nameRealm, classMap[item.nameRealm], nowE)
                    shown = shown + 1
                    local r = getRec(shown)
                    r:ClearAllPoints(); r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y); r:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                    local cr, cg, cb = Dashboard.ClassColor(model.classTag)
                    r.name:SetText(model.name or "?")
                    if cr then r.name:SetTextColor(cr, cg, cb) else r.name:SetTextColor(UI.Color("text")) end
                    r.inst:SetText(model.instance)
                    r.ago:SetText(model.agoText)
                    r:Show()
                    y = y + REC_H + REC_GAP
                end
            end
            P._empty:SetText("No instance entries recorded."); P._empty:SetShown(shown == 0)
        end
        child:SetHeight(math.max(y, 1))
    end

    P.Refresh()
    return P
end

-- ════════════════════════════════════════════════════════════════════════════
--  SELF-TEST  (suite "instancesui"): the view-model matrix, re-housed verbatim.
-- ════════════════════════════════════════════════════════════════════════════

local function testInstancesUI(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local IU = ns.InstancesUI

    ck(IU.MeterState(0, 5, 4) == "ok",   "0/5 -> ok")
    ck(IU.MeterState(3, 5, 4) == "ok",   "3/5 -> ok (below warn)")
    ck(IU.MeterState(4, 5, 4) == "warn", "4/5 -> warn (== warn threshold)")
    ck(IU.MeterState(5, 5, 4) == "cap",  "5/5 -> cap (== cap)")
    ck(IU.MeterState(6, 5, 4) == "cap",  "6/5 -> cap (over)")
    ck(IU.MeterState(26, 30, 27) == "ok",   "26/30 -> ok")
    ck(IU.MeterState(27, 30, 27) == "warn", "27/30 -> warn")
    ck(IU.MeterState(30, 30, 27) == "cap",  "30/30 -> cap")

    ck(IU.StateToken("ok")   == "muted",  "ok  -> calm (muted)")
    ck(IU.StateToken("warn") == "warn",   "warn -> amber")
    ck(IU.StateToken("cap")  == "danger", "cap -> danger")

    local caps = { HOURLY_CAP = 5, WARN_HOURLY = 4, DAILY_CAP = 30, WARN_DAILY = 27 }
    local T = 1000000
    local m1 = IU.MeterModel({ hour = 2, day = 10, nextHourSlotAt = T + 100 }, T, caps)
    ck(m1.hour.state == "ok" and m1.hour.token == "muted", "model: hour ok calm")
    ck(m1.hour.countdown == nil, "model: no countdown under cap")
    local m2 = IU.MeterModel({ hour = 5, day = 10, nextHourSlotAt = T + 293 }, T, caps)
    ck(m2.hour.atCap == true and m2.hour.token == "danger", "model: hour capped danger")
    ck(m2.hour.countdown == 293, "model: hourly countdown = nextHourSlotAt - now")
    local m3 = IU.MeterModel({ hour = 4, day = 28 }, T, caps)
    ck(m3.hour.state == "warn" and m3.day.state == "warn", "model: warn band hour + day")
    local m4 = IU.MeterModel({ hour = 3, day = 30, nextDaySlotAt = T + 60 }, T, caps)
    ck(m4.day.atCap == true and m4.day.countdown == 60, "model: daily cap countdown")

    ck(IU.NextSlotSeconds(T + 125, T) == 125, "next-slot seconds")
    ck(IU.NextSlotSeconds(T - 10, T) == 0, "past slot clamps to 0")
    ck(IU.NextSlotSeconds(nil, T) == nil, "no slot time -> nil")
    ck(IU.FormatMSS(293) == "4:53", "293s -> 4:53")
    ck(IU.FormatMSS(5) == "0:05", "5s -> 0:05")
    ck(IU.FormatMSS(0) == "0:00", "0s -> 0:00")

    ck(IU.FormatMoney(12345) == "1g 23s", "positive gold -> g/s")
    ck(IU.FormatMoney(-5000) == "-50s 0c", "negative gold shows sign")
    ck(IU.FormatMoney(0) == "0c", "zero copper")

    local rN = IU.RowModel({ t = T - 120, name = "Molten Core", dur = 3600, gold = 25000, xp = 1500, merged = false }, "Alt-Realm", "MAGE", T)
    ck(rN.instance == "Molten Core", "row: instance name")
    ck(rN.merged == false, "row: non-merged flag false")
    ck(rN.goldToken == "muted", "row: positive gold reads calm")
    ck(rN.classTag == "MAGE", "row: carries class for colouring")
    ck(rN.xpText == "+1500 xp", "row: positive xp cell")
    ck(rN.agoText:find("ago") ~= nil, "row: ago text formatted")
    local rM = IU.RowModel({ t = T - 30, name = "Zul'Gurub", dur = 60, gold = -1200, xp = 0, merged = true }, "Alt-Realm", "WARLOCK", T)
    ck(rM.merged == true, "row: merged flag true")
    ck(rM.goldToken == "danger", "row: negative gold reads danger")
    ck(rM.xpText == nil, "row: zero xp -> no xp cell")
    ck(rM.agoText == "just now", "row: sub-60s -> just now")

    local data = { accounts = {
            ["1"] = { characters = { ["A-R"] = { classTag = "ROGUE" } }, homeless = { ["H-R"] = { classTag = "PRIEST" } } },
        }, instances = {
            ["1"] = { ["A-R"] = { entries = { { t = T - 10, name = "MC" }, { t = T - 50, name = "MC" } } } },
            ["2"] = { ["B-R"] = { entries = { { t = T - 5, name = "BWL" } } } },
        } }
    local all = IU.GatherEntries(data.instances)
    ck(#all == 3, "gather: 3 entries across accounts (got " .. #all .. ")")
    ck(all[1].entry.name == "BWL", "gather: newest first (BWL t-5 leads)")
    ck(all[#all].entry.t == T - 50, "gather: oldest last")
    ck(#IU.FilterEntries(all, { aid = "1" }, "A-R") == 2, "filter: scope acct 1 -> 2")
    local fc = IU.FilterEntries(all, { thisChar = true }, "B-R")
    ck(#fc == 1 and fc[1].nameRealm == "B-R", "filter: this-character")
    local ids = IU.SortedAccountIDs({ ["10"] = {}, ["2"] = {}, ["1"] = {} })
    ck(ids[1] == "1" and ids[2] == "2" and ids[3] == "10", "account ids sorted numerically")
    local cl = IU.ClassLookup(data)
    ck(cl["A-R"] == "ROGUE" and cl["H-R"] == "PRIEST", "class lookup maps nameRealm -> class")

    -- ExpRow (round-10 item 2): guards absent engine fields; level-60 = just Level 60.
    local EM = "\226\128\148"
    local r60 = IU.ExpRow({ level = 60, xp = 1, xpMax = 2, restedXP = 3 }, "Max-R", "WARRIOR")
    ck(r60.maxed == true and r60.levelText == "Level 60", "exp: level 60 -> maxed / Level 60")
    ck(r60.xpText == nil and r60.restedText == nil, "exp: level 60 has no xp/rested")
    local rMid = IU.ExpRow({ level = 40, xp = 8000, xpMax = 16000, restedXP = 24000 }, "Mid-R", "MAGE")
    ck(rMid.levelText == "Level 40", "exp: level text")
    ck(rMid.xpText == "8000/16000", "exp: xp cur/total")
    ck(rMid.restedText == "150% (Max)", "exp: rested 24000/16000 = 150% (Max)")
    local rLow = IU.ExpRow({ level = 20, xp = 500, xpMax = 4000, restedXP = 800 }, "Low-R", "ROGUE")
    ck(rLow.restedText == "20%", "exp: rested 800/4000 = 20%")
    local rNone = IU.ExpRow({ level = 30 }, "None-R", "PRIEST")   -- engine fields absent
    ck(rNone.xpText == EM and rNone.restedText == EM, "exp: absent engine fields -> em-dash")

    -- CharList (round-10 item 3): level desc, then name asc, "All" sentinel at top.
    local cdata = { accounts = {
        ["1"] = { characters = { ["Bee-R"] = { classTag = "MAGE", level = 60 },
                                 ["Ann-R"] = { classTag = "ROGUE", level = 60 },
                                 ["Cee-R"] = { classTag = "PRIEST", level = 42 } } },
    } }
    local list = IU.CharList(cdata)
    ck(list[1].all == true and list[1].label == "All", "charlist: All sentinel at top")
    ck(list[2].nameRealm == "Ann-R" and list[3].nameRealm == "Bee-R",
        "charlist: level 60 block ordered by name asc (Ann before Bee)")
    ck(list[4].nameRealm == "Cee-R" and list[4].level == 42, "charlist: lower level last")
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("instancesui", function(verbose)
        local fails = {}
        local ok = pcall(testInstancesUI, fails)
        local passed = ok and #fails == 0
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS instancesui/view model")
            elseif not ok then ns:Print("  FAIL instancesui/view model :: error in test")
            else for _, f in ipairs(fails) do ns:Print("  FAIL instancesui/view model :: " .. f) end end
        end
        return passed
    end)
end
