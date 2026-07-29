-- Daseeki Nexus — ui_tab_instances.lua
-- The "Instances" tab — NovaInstanceTracker absorption wave 2/2 (UI). Field Ledger
-- dress (BRAND_SPEC LAW), codes ONLY against the merged engine API in instances.lua:
--   Instances.WindowCounts(aid, nowE) -> { hour, day, nextHourSlotAt, nextDaySlotAt }
--   Instances.AllAccounts(nowE)       -> { accounts = { [aid] = counts }, total = { hour, day } }
--   constants HOURLY_CAP / DAILY_CAP / WARN_HOURLY / WARN_DAILY
--   entry shape { t, name, mapID, dur, gold, xp, merged } in
--     DaseekiNexusData.instances[aid][nameRealm].entries
--
-- Owner-locked shape (NEXUS_INSTANCES_DESIGN.md UI section, BRAND_SPEC §5/§6/§7/§8):
--   * Header = per-account cap METERS — one line per account with data
--     ("Acct 1 · 3/5 hour · 12/30 day"), telemetry numerals for the counts, with
--     ATTENTION INVERSION: under-cap is calm (muted), >=WARN is amber (warn), AT
--     cap is danger (red) + a "next slot M:SS" countdown ticking off nextHourSlotAt.
--     Plus an ALL row (cross-account totals — the net-new view a single-account
--     tracker never had; shown as plain totals, no false per-account cap on the sum).
--   * Entry REGISTER (pooled rows, newest first, all accounts mixed): time-ago ·
--     character (class-colored) · instance name · duration · gold/xp deltas
--     (microLabel; NEGATIVE gold reads danger) · "(merged)" faint tag. Chip row =
--     per-account scope chips (from data) + a "This character" modifier toggle.
--     Empty state plain copy: "No instance entries recorded."
--
-- Ledger dress: UI.PaintLedgerGround (grain + vignette + the window's ONE bronze
-- keyline); ceremonial section headers carry their one bronze hairline; each row
-- carries a single bottom border hairline; text/numerals live on child frames with
-- flat fills so no glyph ever sits on the grain (§4 layering). Repaints in place on
-- the engine's INSTANCES_CHANGED event (added additively in instances.lua) and on a
-- 1s visible-only ticker (like the Timers tab) so capped countdowns tick.
--
-- Clean-room build on our own DaseekiUI/Ledger stack. No third-party code.

local ADDON, ns = ...
local UI = DaseekiUI                 -- nil under the headless harness; only ever
local Store = ns.Store               -- dereferenced inside function bodies below.

----------------------------------------------------------------------
-- PURE view model (fully self-testable; no live client API, no frames). Exposed on
-- ns so the "instancesui" self-test exercises the meter-state matrix + row assembly.
----------------------------------------------------------------------

local InstancesUI = {}
ns.InstancesUI = InstancesUI

-- Attention-inverted token per meter state (BRAND_SPEC §5/§8): calm under cap,
-- amber at the warn band, danger at the cap.
local STATE_TOKEN = { ok = "muted", warn = "warn", cap = "danger" }
function InstancesUI.StateToken(state) return STATE_TOKEN[state] or "muted" end

-- Classify a rolling-window count against its cap + warn threshold. Pure.
--   count >= cap  -> "cap"   (danger; slot exhausted)
--   count >= warn -> "warn"  (amber)
--   otherwise     -> "ok"    (calm)
function InstancesUI.MeterState(count, cap, warn)
    count = count or 0
    if cap and count >= cap then return "cap" end
    if warn and count >= warn then return "warn" end
    return "ok"
end

-- Seconds until a rolling-window slot re-opens (nextSlotAt - now), floored at 0.
-- nil slot time -> nil (nothing aging out). Pure.
function InstancesUI.NextSlotSeconds(nextSlotAt, nowE)
    if not nextSlotAt then return nil end
    local rem = nextSlotAt - (nowE or 0)
    if rem < 0 then rem = 0 end
    return math.floor(rem)
end

-- Countdown numerals as M:SS (telemetry). Pure.
function InstancesUI.FormatMSS(sec)
    sec = math.max(0, math.floor(sec or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Assemble a per-account meter model from the engine's WindowCounts shape. Caps +
-- warn thresholds come from the engine (Instances.*), overridable for the test.
-- A countdown is populated ONLY when that window is at cap (a slot is exhausted).
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

-- "just now" under a minute, else "<duration> ago". Uses the shared shell formatter
-- when present (harness-safe fallback otherwise). Pure.
function InstancesUI.AgoText(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec < 60 then return "just now" end
    local D = ns.Dashboard
    local dur = (D and D.FormatDuration and D.FormatDuration(sec)) or (math.floor(sec / 60) .. "m")
    return dur .. " ago"
end

-- Assemble one register row model from an entry + resolved class. NEGATIVE gold is
-- flagged danger (spent in-run); a positive/zero delta is calm (attention inversion).
-- A zero xp delta yields no xp cell. Pure.
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

-- Flatten every account/character's entries into one newest-first list. Pure over a
-- DaseekiNexusData.instances table. Each item = { aid, nameRealm, entry, t }.
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
    -- Newest first; ties broken deterministically (account asc, then name asc).
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

-- Account ids sorted numerically (falls back to string order for non-numeric). Pure.
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

-- nameRealm -> classTag lookup across every account's characters + homeless. Pure
-- over a Store.GetData() shape; best-effort (a nameRealm with no record renders in
-- the default text color). Pure.
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

----------------------------------------------------------------------
-- Metrics (UI only; reached in-game where UI is non-nil).
----------------------------------------------------------------------

local PAD        = 10
local HEADER_H   = 26
local METER_ROW_H = 20
local METER_GAP   = 2
local REG_ROW_H   = 24
local REG_GAP     = 2

-- Raise a color toward white (brighten pulse for a capped countdown — §8, never dims).
local function brighten(r, g, b, t)
    t = t or 0.35
    return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

local function selfNameRealm()
    local name = (UnitName and UnitName("player")) or "player"
    local realm = ((GetRealmName and GetRealmName()) or ""):gsub("%s+", "")
    return name .. "-" .. realm
end

local function fstr(parent, key)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    return f
end

-- Ceremonial section header (MORPHEUS >=16 + its one bronze hairline via the kit),
-- with a right-aligned microLabel meta caption. Returns header, meta.
local function sectionHeader(parent, title)
    local h = UI.MakeSectionHeader(parent, title)
    local meta = fstr(h, "microLabel")
    meta:SetJustifyH("RIGHT")
    meta:SetPoint("TOPRIGHT", h, "TOPRIGHT", 0, -4)
    meta:SetTextColor(UI.Color("faint"))
    h._meta = meta
    return h, meta
end

----------------------------------------------------------------------
-- Meter row (per-account cap line + the ALL totals line).
----------------------------------------------------------------------

local function makeMeterRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(METER_ROW_H)
    -- Flat fill so numerals sit on flat colour, never on the grain (§4).
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(r)
    UI.Skin(r.bg, function(self) self:SetColorTexture(UI.Color("ground")) end)

    r.acct = fstr(r, "microLabel"); r.acct:SetPoint("LEFT", r, "LEFT", 4, 0); r.acct:SetJustifyH("LEFT")
    r.hourNum = fstr(r, "numeral");   r.hourNum:SetPoint("LEFT", r.acct, "RIGHT", 12, 0)
    r.hourLbl = fstr(r, "microLabel"); r.hourLbl:SetPoint("LEFT", r.hourNum, "RIGHT", 3, 0)
    r.hourLbl:SetText("hour"); r.hourLbl:SetTextColor(UI.Color("faint"))
    r.sep = fstr(r, "microLabel"); r.sep:SetPoint("LEFT", r.hourLbl, "RIGHT", 8, 0)
    r.dayNum = fstr(r, "numeral");   r.dayNum:SetPoint("LEFT", r.sep, "RIGHT", 8, 0)
    r.dayLbl = fstr(r, "microLabel"); r.dayLbl:SetPoint("LEFT", r.dayNum, "RIGHT", 3, 0)
    r.dayLbl:SetText("day"); r.dayLbl:SetTextColor(UI.Color("faint"))
    -- Next-slot countdown (only when capped), right-aligned, danger + brighten pulse.
    r.cd = fstr(r, "numeral"); r.cd:SetPoint("RIGHT", r, "RIGHT", -4, 0); r.cd:SetJustifyH("RIGHT")
    return r
end

-- Value a meter row. kind "account" = cap meters + countdown; kind "all" = plain
-- cross-account totals (no per-account cap on the sum, no countdown).
local function setMeterRow(r, label, counts, nowE, kind)
    r.acct:SetText(label)
    r.sep:SetText(ns.Dashboard.Colored("·", "faint"))
    if kind == "all" then
        r.acct:SetTextColor(UI.Color("text"))
        r.hourNum:SetText(tostring(counts.hour or 0)); r.hourNum:SetTextColor(UI.Color("text"))
        r.dayNum:SetText(tostring(counts.day or 0));   r.dayNum:SetTextColor(UI.Color("text"))
        r.cd:SetText(""); r.cd._pulse = false
        return
    end
    r.acct:SetTextColor(UI.Color("muted"))
    local m = InstancesUI.MeterModel(counts, nowE)
    r.hourNum:SetText(m.hour.count .. "/" .. m.hour.cap); r.hourNum:SetTextColor(UI.Color(m.hour.token))
    r.dayNum:SetText(m.day.count .. "/" .. m.day.cap);    r.dayNum:SetTextColor(UI.Color(m.day.token))
    -- Prefer the hourly countdown when the hour is capped, else the daily one.
    local cd = m.hour.atCap and m.hour.countdown or (m.day.atCap and m.day.countdown or nil)
    if cd ~= nil then
        r.cd:SetText("next slot " .. InstancesUI.FormatMSS(cd))
        r.cd:SetTextColor(UI.Color("danger"))
        r.cd._pulse = true
    else
        r.cd:SetText(""); r.cd._pulse = false
    end
end

----------------------------------------------------------------------
-- Register row (pooled; one bottom border hairline per row — §6).
----------------------------------------------------------------------

local function makeRegRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(REG_ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(r)
    UI.Skin(r.bg, function(self) self:SetColorTexture(UI.Color("panel")) end)

    r.ago  = fstr(r, "microLabel"); r.ago:SetPoint("LEFT", r, "LEFT", 6, 0); r.ago:SetWidth(66); r.ago:SetJustifyH("LEFT"); r.ago:SetWordWrap(false)
    r.name = fstr(r, "body");       r.name:SetPoint("LEFT", r.ago, "RIGHT", 6, 0); r.name:SetWidth(94); r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
    r.inst = fstr(r, "body");       r.inst:SetPoint("LEFT", r.name, "RIGHT", 6, 0); r.inst:SetJustifyH("LEFT"); r.inst:SetWordWrap(false)
    -- Right group: merged tag · xp · gold · duration.
    r.merged = fstr(r, "microLabel"); r.merged:SetPoint("RIGHT", r, "RIGHT", -6, 0); r.merged:SetJustifyH("RIGHT")
    r.xp   = fstr(r, "microLabel"); r.xp:SetPoint("RIGHT", r.merged, "LEFT", -8, 0); r.xp:SetJustifyH("RIGHT")
    r.gold = fstr(r, "microLabel"); r.gold:SetPoint("RIGHT", r.xp, "LEFT", -8, 0); r.gold:SetJustifyH("RIGHT")
    r.dur  = fstr(r, "numeral");    r.dur:SetPoint("RIGHT", r.gold, "LEFT", -12, 0); r.dur:SetJustifyH("RIGHT")

    r.rule = UI.Hairline(r, { token = "border" })
    r.rule:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 4, 0)
    r.rule:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -4, 0)
    return r
end

local function setRegRow(r, model)
    r.ago:SetText(model.agoText);  r.ago:SetTextColor(UI.Color("faint"))
    r.name:SetText(ns.Dashboard.ColoredName(model.nameRealm, model.classTag))
    r.inst:SetText(model.instance); r.inst:SetTextColor(UI.Color("text"))
    r.dur:SetText(model.durText);  r.dur:SetTextColor(UI.Color("muted"))
    r.gold:SetText(model.goldText); r.gold:SetTextColor(UI.Color(model.goldToken))
    if model.xpText then r.xp:SetText(model.xpText); r.xp:SetTextColor(UI.Color("muted")) else r.xp:SetText("") end
    if model.merged then r.merged:SetText("(merged)"); r.merged:SetTextColor(UI.Color("faint")) else r.merged:SetText("") end
end

----------------------------------------------------------------------
-- Scope chip (per-account + "This character" modifier).
----------------------------------------------------------------------

local function makeChip(parent, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetHeight(18)
    b._lbl = b:CreateFontString(nil, "OVERLAY")
    b._lbl:SetFontObject(UI.fonts.microLabel)
    b._lbl:SetPoint("LEFT", b, "LEFT", 8, 0)
    b:SetScript("OnClick", onClick)
    function b:Apply(active, text)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color(active and "brand" or "control", active and 0.85 or 1))
        self:SetBackdropBorderColor(UI.Color(active and "brand" or "controlBorder"))
        self._lbl:SetText(text)
        self._lbl:SetTextColor(UI.Color(active and "text" or "muted"))
        self:SetWidth((self._lbl:GetStringWidth() or 30) + 16)
    end
    return b
end

----------------------------------------------------------------------
-- Tab registration — the "Instances" screen.
----------------------------------------------------------------------

ns.Dashboard.RegisterTab("instances", function(host)
    local obj = {}
    local Dashboard = ns.Dashboard
    local Instances = ns.Instances
    local pane = { scopeAid = nil, thisChar = false, meterRows = {}, regRows = {}, chips = {} }

    -- Ledger ground for the whole page (grain + vignette + the window's ONE bronze
    -- keyline). Rows/cells carry their own flat fills so glyphs never sit on grain.
    local box = UI.FlatFrame(host, "ground", "border")
    box:SetAllPoints(host)
    UI.PaintLedgerGround(box, { keyline = true })

    ------------------------------------------------------------------
    -- Caps section — per-account meters + ALL totals.
    ------------------------------------------------------------------
    local capHdr, capMeta = sectionHeader(box, "Instance caps")
    capHdr:SetPoint("TOPLEFT", box, "TOPLEFT", PAD, -PAD)
    capHdr:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PAD, -PAD)
    capMeta:SetText("per account · rolling window")

    local function getMeterRow(i)
        local r = pane.meterRows[i]
        if not r then r = makeMeterRow(box); pane.meterRows[i] = r end
        return r
    end

    ------------------------------------------------------------------
    -- Register section — header (repositioned below the meters each refresh),
    -- chip row, scroll list of pooled entry rows.
    ------------------------------------------------------------------
    local regHdr, regMeta = sectionHeader(box, "Recent entries")

    local chipRow = UI.FlatFrame(box, "panel", "border")
    chipRow:SetPoint("TOPLEFT", regHdr, "BOTTOMLEFT", 0, -4)
    chipRow:SetPoint("TOPRIGHT", regHdr, "BOTTOMRIGHT", 0, -4)
    chipRow:SetHeight(26)

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", chipRow, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -PAD, PAD)
    scroll:SetClipsChildren(true)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1); scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 30)))
    end)
    pane.scroll, pane.child = scroll, child

    local emptyLabel = fstr(child, "muted")
    emptyLabel:SetPoint("TOPLEFT", child, "TOPLEFT", 6, -6)
    emptyLabel:Hide()

    local function getRegRow(i)
        local r = pane.regRows[i]
        if not r then r = makeRegRow(child); pane.regRows[i] = r end
        return r
    end

    -- Chip layout: [All] [Acct N…] | [This character]. Rebuilt each refresh so new
    -- accounts appearing in the data get a chip.
    local function layoutChips(aids)
        for _, c in ipairs(pane.chips) do c:Hide() end
        local used, x = 0, 8
        local function chip(text, active, onClick)
            used = used + 1
            local c = pane.chips[used]
            if not c then c = makeChip(chipRow, onClick); pane.chips[used] = c end
            c:SetScript("OnClick", onClick)
            c:Apply(active, text)
            c:ClearAllPoints(); c:SetPoint("LEFT", chipRow, "LEFT", x, 0)
            c:Show()
            x = x + c:GetWidth() + 5
        end
        chip("ALL", pane.scopeAid == nil, function() pane.scopeAid = nil; obj.Refresh() end)
        for _, aid in ipairs(aids) do
            local a = aid
            chip("ACCT " .. a, pane.scopeAid == a, function() pane.scopeAid = a; obj.Refresh() end)
        end
        -- Faint separator before the modifier toggle.
        local sep = chipRow._sep
        if not sep then
            sep = chipRow:CreateFontString(nil, "OVERLAY"); sep:SetFontObject(UI.fonts.microLabel)
            sep:SetText("|"); chipRow._sep = sep
        end
        sep:SetTextColor(UI.Color("faint"))
        sep:ClearAllPoints(); sep:SetPoint("LEFT", chipRow, "LEFT", x, 0)
        sep:Show()
        x = x + 12
        chip("THIS CHARACTER", pane.thisChar, function() pane.thisChar = not pane.thisChar; obj.Refresh() end)
    end

    ------------------------------------------------------------------
    -- Refresh routine.
    ------------------------------------------------------------------
    function obj.Refresh()
        local nowE = Dashboard.Now()
        local data = Store and Store.GetData and Store.GetData()
        local instData = (data and data.instances) or {}
        local view = Instances.AllAccounts(nowE)

        -- Meters: one row per account with data, then the ALL totals row.
        local aids = InstancesUI.SortedAccountIDs(view.accounts)
        local mi = 0
        local firstMeter, prevMeter
        for _, aid in ipairs(aids) do
            mi = mi + 1
            local r = getMeterRow(mi)
            r:ClearAllPoints()
            if prevMeter then
                r:SetPoint("TOPLEFT", prevMeter, "BOTTOMLEFT", 0, -METER_GAP)
                r:SetPoint("TOPRIGHT", prevMeter, "BOTTOMRIGHT", 0, -METER_GAP)
            else
                r:SetPoint("TOPLEFT", capHdr, "BOTTOMLEFT", 0, -4)
                r:SetPoint("TOPRIGHT", capHdr, "BOTTOMRIGHT", 0, -4)
                firstMeter = r
            end
            setMeterRow(r, "Acct " .. aid, view.accounts[aid], nowE, "account")
            r:Show()
            prevMeter = r
        end
        -- ALL row (always present — the cross-account baseline).
        mi = mi + 1
        local allRow = getMeterRow(mi)
        allRow:ClearAllPoints()
        if prevMeter then
            allRow:SetPoint("TOPLEFT", prevMeter, "BOTTOMLEFT", 0, -METER_GAP)
            allRow:SetPoint("TOPRIGHT", prevMeter, "BOTTOMRIGHT", 0, -METER_GAP)
        else
            allRow:SetPoint("TOPLEFT", capHdr, "BOTTOMLEFT", 0, -4)
            allRow:SetPoint("TOPRIGHT", capHdr, "BOTTOMRIGHT", 0, -4)
        end
        setMeterRow(allRow, "All", view.total, nowE, "all")
        allRow:Show()
        for j = mi + 1, #pane.meterRows do pane.meterRows[j]:Hide() end
        capMeta:SetText("caps " .. Instances.HOURLY_CAP .. "/hr · " .. Instances.DAILY_CAP .. "/day per account")

        -- Reposition the register header below the meters (meters vary in count).
        local metersH = mi * METER_ROW_H + (mi - 1) * METER_GAP
        regHdr:ClearAllPoints()
        local top = -(PAD + HEADER_H + 4 + metersH + 8)
        regHdr:SetPoint("TOPLEFT", box, "TOPLEFT", PAD, top)
        regHdr:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PAD, top)

        -- Chips.
        layoutChips(aids)

        -- Register list (newest first, scope + this-character filtered).
        local all = InstancesUI.GatherEntries(instData)
        local list = InstancesUI.FilterEntries(all, { aid = pane.scopeAid, thisChar = pane.thisChar }, selfNameRealm())
        local classMap = InstancesUI.ClassLookup(data or {})

        local W = scroll:GetWidth(); if W < 1 then W = box:GetWidth() - 2 * PAD end
        child:SetWidth(W)
        for _, r in ipairs(pane.regRows) do r:Hide() end
        local y = 0
        for i = 1, #list do
            local item = list[i]
            local r = getRegRow(i)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            r:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
            setRegRow(r, InstancesUI.RowModel(item.entry, item.nameRealm, classMap[item.nameRealm], nowE))
            r:Show()
            y = y + REG_ROW_H + REG_GAP
        end
        child:SetHeight(math.max(y, 1))
        regMeta:SetText(#list .. (#list == 1 and " entry" or " entries"))

        -- Empty state — plain copy (BRAND_SPEC §6).
        if #list == 0 then
            emptyLabel:SetText("No instance entries recorded.")
            emptyLabel:Show()
        else
            emptyLabel:Hide()
        end
    end

    ------------------------------------------------------------------
    -- 1s ticker (visible-only — a hidden pane gets no OnUpdate) so capped countdowns
    -- tick, plus a brighten pulse on any capped countdown numeral (§8: brighten,
    -- never alpha-dim).
    ------------------------------------------------------------------
    local accum = 0
    host:SetScript("OnUpdate", function(self, elapsed)
        accum = accum + elapsed
        local dr, dg, db = UI.Color("danger")
        local t = 0.4 * math.abs(math.sin(GetTime() * 3))
        for _, r in ipairs(pane.meterRows) do
            if r.cd._pulse then r.cd:SetAlpha(1); r.cd:SetTextColor(brighten(dr, dg, db, t)) end
        end
        if accum >= 1 then accum = 0; ns:SafeCall(obj.Refresh) end
    end)

    -- Repaint in place when the engine records / merges an instance entry.
    ns:On("INSTANCES_CHANGED", function()
        if host:IsShown() then ns:SafeCall(obj.Refresh) end
    end)

    scroll:SetScript("OnSizeChanged", function() ns:SafeCall(obj.Refresh) end)
    return obj
end)

----------------------------------------------------------------------
-- Self-test: the pure view model (meter-state matrix incl. warn/cap boundaries +
-- next-slot countdown math; register row assembly incl. merged tag + negative gold;
-- gather/filter/lookup helpers). Runs headless (no frames). Suite "instancesui".
----------------------------------------------------------------------

local function testInstancesUI(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local IU = ns.InstancesUI

    -- Meter-state boundaries (hourly cap 5 / warn 4).
    ck(IU.MeterState(0, 5, 4) == "ok",   "0/5 -> ok")
    ck(IU.MeterState(3, 5, 4) == "ok",   "3/5 -> ok (below warn)")
    ck(IU.MeterState(4, 5, 4) == "warn", "4/5 -> warn (== warn threshold)")
    ck(IU.MeterState(5, 5, 4) == "cap",  "5/5 -> cap (== cap)")
    ck(IU.MeterState(6, 5, 4) == "cap",  "6/5 -> cap (over)")
    -- Daily cap 30 / warn 27.
    ck(IU.MeterState(26, 30, 27) == "ok",   "26/30 -> ok")
    ck(IU.MeterState(27, 30, 27) == "warn", "27/30 -> warn")
    ck(IU.MeterState(30, 30, 27) == "cap",  "30/30 -> cap")

    -- Attention-inverted token map.
    ck(IU.StateToken("ok")   == "muted",  "ok  -> calm (muted)")
    ck(IU.StateToken("warn") == "warn",   "warn -> amber")
    ck(IU.StateToken("cap")  == "danger", "cap -> danger")

    -- MeterModel (caps injected so the test is engine-independent).
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

    -- Next-slot math + M:SS.
    ck(IU.NextSlotSeconds(T + 125, T) == 125, "next-slot seconds")
    ck(IU.NextSlotSeconds(T - 10, T) == 0, "past slot clamps to 0")
    ck(IU.NextSlotSeconds(nil, T) == nil, "no slot time -> nil")
    ck(IU.FormatMSS(293) == "4:53", "293s -> 4:53")
    ck(IU.FormatMSS(5) == "0:05", "5s -> 0:05")
    ck(IU.FormatMSS(0) == "0:00", "0s -> 0:00")

    -- Money formatting incl. the negative-gold danger read.
    ck(IU.FormatMoney(12345) == "1g 23s", "positive gold -> g/s")
    ck(IU.FormatMoney(-5000) == "-50s 0c", "negative gold shows sign")
    ck(IU.FormatMoney(0) == "0c", "zero copper")

    -- Register row assembly fixture: non-merged, positive gold.
    local rN = IU.RowModel({ t = T - 120, name = "Molten Core", dur = 3600, gold = 25000, xp = 1500, merged = false }, "Alt-Realm", "MAGE", T)
    ck(rN.instance == "Molten Core", "row: instance name")
    ck(rN.merged == false, "row: non-merged flag false")
    ck(rN.goldToken == "muted", "row: positive gold reads calm")
    ck(rN.classTag == "MAGE", "row: carries class for colouring")
    ck(rN.xpText == "+1500 xp", "row: positive xp cell")
    ck(rN.agoText:find("ago") ~= nil, "row: ago text formatted")
    -- Merged re-entry, negative gold, zero xp.
    local rM = IU.RowModel({ t = T - 30, name = "Zul'Gurub", dur = 60, gold = -1200, xp = 0, merged = true }, "Alt-Realm", "WARLOCK", T)
    ck(rM.merged == true, "row: merged flag true")
    ck(rM.goldToken == "danger", "row: negative gold reads danger")
    ck(rM.xpText == nil, "row: zero xp -> no xp cell")
    ck(rM.agoText == "just now", "row: sub-60s -> just now")

    -- Gather (newest first) + filter + lookup.
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
