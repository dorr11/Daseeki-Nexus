-- Daseeki Nexus — ui_shell.lua
-- The dashboard window shell (spec §0): a free-floating, movable, resizable
-- DaseekiUI-chrome window with a header bar, tab bar, active-panel host, and a
-- live status bar. Also the home of the cross-tab shared model + helpers that
-- the individual tab files consume (roster query, class colors, aura metadata,
-- freshness/duration formatting, faction crests, the shared roster two-pane,
-- and the shared character detail panel used by both 60s and Online).
--
-- Clean-room build: reimplements the functional spec on our own DaseekiUI stack.
-- No third-party code or identifiers.

local ADDON, ns = ...
local UI = DaseekiUI

local Dashboard = {}
ns.Dashboard = Dashboard

----------------------------------------------------------------------
-- Window metrics (fixed bands — style guide: compact, stable layouts)
----------------------------------------------------------------------

local DEFAULT_W, DEFAULT_H = 1020, 640
-- Min width must always fit the two-pane roster (card list + detail) so the
-- layout never has to fall back to a stacked mode (style rule 7). Card list is
-- 352 + SPLIT_GAP 12 + detail min 380 = 744 of content; window overhead is
-- 2*PAD(12)=24 => 768. Round up for margin.
local MIN_W, MIN_H = 820, 480
local HEADER_H = 44
local TAB_H    = 34
local STATUS_H = 28
local PAD      = 12

-- Roster two-pane geometry (shared by 60s + Online).
Dashboard.CARD_LIST_W = 352
Dashboard.SPLIT_GAP   = 12

-- Online heuristic: a record whose lastSeen is within this window counts as
-- online (the current player character is always treated online).
local ONLINE_WINDOW = 150

----------------------------------------------------------------------
-- Faction crest textures (Blizzard built-ins; no atlas dependency so this
-- renders identically on Classic Era). The PvP crest art has the emblem in a
-- sub-rect, cropped with TexCoord.
----------------------------------------------------------------------

local FACTION_CREST = {
    Alliance = "Interface\\TargetingFrame\\UI-PVP-Alliance",
    Horde    = "Interface\\TargetingFrame\\UI-PVP-Horde",
}
local CREST_COORD = { 0.02, 0.62, 0.03, 0.63 }

function Dashboard.FactionCrest(faction)
    return FACTION_CREST[faction] or FACTION_CREST.Alliance
end

----------------------------------------------------------------------
-- Aura metadata (the tracked-buff model).
--
-- Storage authority is tracker.lua: it fills record.auraStates[1..10] by a
-- FIXED slot layout. AURA_META mirrors that slot layout exactly (index == slot)
-- and adds presentation (name/short/icon) plus the per-faction threshold key
-- used to color the buff (spec §2's 9 configurable auras). Slots without a
-- threshold key (Silithyst, Boon of Blackfathom) are always optional.
--
-- CROSS-FILE CONTRACT: `thresholdKey` values here are the keys the hub's
-- aura-config page (options.lua AURA_DEFS) writes into
-- GetFactionSettings().auraOpts.thresholds, and that the importer
-- (import.lua AURA_SLOT_KEY) resolves SN's positional thresholds onto. Keys
-- (exact, case-sensitive): dmf, ony, dmtAP, dmtSP, dmtStam, songflower, zg,
-- rend (+ battleShout, which has no storage slot).
----------------------------------------------------------------------

Dashboard.AURA_META = {
    [1]  = { key = "ony",       name = "Rallying Cry of the Dragonslayer", short = "Ony",  thresholdKey = "ony",       icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
    [2]  = { key = "rend",      name = "Warchief's Blessing",              short = "Rend", thresholdKey = "rend",      icon = "Interface\\Icons\\Spell_Holy_LayOnHands" },
    [3]  = { key = "zg",        name = "Spirit of Zandalar",               short = "ZG",   thresholdKey = "zg",        icon = "Interface\\Icons\\Ability_Creature_Poison_05" },
    [4]  = { key = "songflower",name = "Songflower Serenade",              short = "SF",   thresholdKey = "songflower",icon = "Interface\\Icons\\Spell_Holy_MindVision" },
    [5]  = { key = "dmf",       name = "Sayge's Dark Fortune",             short = "DMF",  thresholdKey = "dmf",       icon = "Interface\\Icons\\INV_Misc_Orb_02" },
    [6]  = { key = "dmtap",     name = "Fengus' Ferocity",                 short = "AP",   thresholdKey = "dmtAP",     icon = "Interface\\Icons\\INV_Misc_MonsterClaw_04" },
    [7]  = { key = "dmtstam",   name = "Mol'dar's Moxie",                  short = "Stam", thresholdKey = "dmtStam",   icon = "Interface\\Icons\\Ability_Racial_Cannibalize" },
    [8]  = { key = "dmtsp",     name = "Slip'kik's Savvy",                 short = "SP",   thresholdKey = "dmtSP",     icon = "Interface\\Icons\\Spell_Nature_WispSplode" },
    [9]  = { key = "silithyst", name = "Traces of Silithyst",             short = "Sili", thresholdKey = nil,         icon = "Interface\\Icons\\INV_Misc_Dust_02" },
    [10] = { key = "boon",      name = "Boon of Blackfathom",              short = "BFD",  thresholdKey = nil,         icon = "Interface\\Icons\\Spell_Frost_FrostArmor02" },
}

-- Presentation order for the card's collapsing icon strip (spec §1): DMF, Ony,
-- ZG, DMT-AP, DMT-SP, DMT-STAM, Songflower, Rend, then the two optional tail
-- slots. Values are slot indices into AURA_META / auraStates.
Dashboard.AURA_DISPLAY_ORDER = { 5, 1, 3, 6, 8, 7, 4, 2, 9, 10 }

-- Default thresholds (seconds) when the hub has not been configured yet, so the
-- card colors are meaningful out of the box. normal = below this is "warn";
-- minimum = below this is "low/critical".
local DEFAULT_THRESHOLD = { normal = 20 * 60, minimum = 5 * 60 }

----------------------------------------------------------------------
-- Raid lockout display list (spec §1 dot row).
----------------------------------------------------------------------

Dashboard.RAID_DISPLAY = { "Naxx", "AQ40", "BWL", "MC", "ZG", "AQ20", "Ony" }

----------------------------------------------------------------------
-- Shared helpers
----------------------------------------------------------------------

local function now() return (GetServerTime and GetServerTime()) or time() end
Dashboard.Now = now

-- Inline color escape sourced FROM a theme token (so mixed-content strings stay
-- tokens-only — no hardcoded hex — per the style guide). Rebuilt each refresh,
-- so it tracks the active theme.
function Dashboard.HexColor(token)
    local r, g, b = UI.Color(token)
    return ("|cff%02x%02x%02x"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end
function Dashboard.Colored(text, token)
    return Dashboard.HexColor(token) .. tostring(text) .. "|r"
end

-- Class color (r,g,b) from the user override table, falling back to Blizzard's.
function Dashboard.ClassColor(classTag)
    if classTag and ns.Store and ns.Store.GetSettings then
        local db = ns.Store.GetSettings()
        local hex = db and db.classColors and db.classColors[classTag]
        if hex and #hex >= 6 then
            local r = tonumber(hex:sub(1, 2), 16)
            local g = tonumber(hex:sub(3, 4), 16)
            local b = tonumber(hex:sub(5, 6), 16)
            if r and g and b then return r / 255, g / 255, b / 255 end
        end
    end
    local c = classTag and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classTag]
    if c then return c.r, c.g, c.b end
    return UI.Color("text")
end

-- Class-colored "Name-Realm" (realm suffix dropped for compactness).
function Dashboard.ColoredName(nameRealm, classTag)
    local shown = (nameRealm or "?"):match("^([^%-]+)") or nameRealm or "?"
    local r, g, b = Dashboard.ClassColor(classTag)
    return ("|cff%02x%02x%02x%s|r"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), shown)
end

-- "Name" only (no realm), uncolored.
function Dashboard.ShortName(nameRealm)
    return (nameRealm or "?"):match("^([^%-]+)") or nameRealm or "?"
end

-- Compact duration: 2h, 1h05m, 45m, 30s. Clamped at 0.
function Dashboard.FormatDuration(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec >= 3600 then
        local h = math.floor(sec / 3600)
        local m = math.floor((sec % 3600) / 60)
        if m > 0 then return ("%dh%02dm"):format(h, m) end
        return ("%dh"):format(h)
    elseif sec >= 60 then
        return ("%dm"):format(math.floor(sec / 60))
    end
    return ("%ds"):format(sec)
end

-- "Updated 3m ago" style freshness string from an epoch.
function Dashboard.FreshnessText(epoch)
    if not epoch or epoch <= 0 then return "no data" end
    local d = now() - epoch
    if d < 0 then d = 0 end
    if d < 60 then return "Updated just now" end
    return "Updated " .. Dashboard.FormatDuration(d) .. " ago"
end

-- Online heuristic (records carry no live-online flag; mesh presence is a later
-- wave). The current player character is always online; others count online if
-- seen within ONLINE_WINDOW.
function Dashboard.IsOnline(rec, nameRealm)
    if not rec then return false end
    if ns.Tracker and nameRealm then
        local self = UnitName and UnitName("player")
        if self and nameRealm:match("^([^%-]+)") == self then return true end
    end
    return (now() - (rec.lastSeen or 0)) <= ONLINE_WINDOW
end

-- Threshold {normal, minimum} for an aura key on a faction.
function Dashboard.GetThreshold(faction, thresholdKey)
    if thresholdKey and ns.Store and ns.Store.GetFactionSettings then
        local fs = ns.Store.GetFactionSettings(faction)
        local t = fs and fs.auraOpts and fs.auraOpts.thresholds
                  and fs.auraOpts.thresholds[thresholdKey]
        if t and (t.normal or t.minimum) then return t end
    end
    return DEFAULT_THRESHOLD
end

-- Below-normal auras want an amber "warn". Core now ships a `warn` token; use
-- it when present, else fall back to "accent" (the prior stand-in) so an older
-- Core still colors correctly instead of flashing white.
local function warnToken()
    local UI = DaseekiUI
    if UI and UI.Token and type(UI.Token("warn")) == "table" then return "warn" end
    return "accent"
end

-- Color token for a present aura's remaining time vs its threshold.
--   healthy (>= normal)  -> "ok" (green)
--   below-normal         -> "warn" (amber; "accent" fallback on older Core)
--   below-minimum        -> "danger" (red)
function Dashboard.AuraColorToken(remaining, threshold)
    threshold = threshold or DEFAULT_THRESHOLD
    if remaining >= (threshold.normal or 0) then return "ok" end
    if remaining >= (threshold.minimum or 0) then return warnToken() end
    return "danger"
end

----------------------------------------------------------------------
-- Roster query — gather character records for a faction across all accounts.
-- Returns an array of { nameRealm, aid, rec, online } entries.
----------------------------------------------------------------------

function Dashboard.GatherRoster(faction, opts)
    opts = opts or {}
    local out = {}
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if not data or not data.accounts then return out end
    for aid, bucket in pairs(data.accounts) do
        local function consider(nameRealm, rec)
            if not rec then return end
            if opts.faction ~= false and faction and rec.faction and rec.faction ~= faction then
                return
            end
            if opts.minLevel and (rec.level or 0) < opts.minLevel then return end
            if opts.warlockOnly and rec.classTag ~= "WARLOCK" then return end
            out[#out + 1] = {
                nameRealm = nameRealm,
                aid       = aid,
                rec       = rec,
                online    = Dashboard.IsOnline(rec, nameRealm),
            }
        end
        for nameRealm, rec in pairs(bucket.characters or {}) do consider(nameRealm, rec) end
        if opts.includeHomeless then
            for nameRealm, rec in pairs(bucket.homeless or {}) do consider(nameRealm, rec) end
        end
    end
    return out
end

----------------------------------------------------------------------
-- Persisted UI state (card order per faction, last tab, summoner sort).
----------------------------------------------------------------------

local function uiState()
    local db = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    if not db then return {} end
    db.ui = db.ui or {}
    return db.ui
end
Dashboard.UIState = uiState

-- Card order for a faction: an array of nameRealm strings. Missing entries are
-- appended in name order; stale entries pruned. Returns the ordered roster.
function Dashboard.OrderRoster(faction, roster)
    local st = uiState()
    st.cardOrder = st.cardOrder or {}
    local saved = st.cardOrder[faction] or {}
    local byName = {}
    for _, e in ipairs(roster) do byName[e.nameRealm] = e end
    local ordered, seen = {}, {}
    for _, nr in ipairs(saved) do
        if byName[nr] and not seen[nr] then
            ordered[#ordered + 1] = byName[nr]
            seen[nr] = true
        end
    end
    -- Append any not-yet-ordered, alphabetically for stability.
    local rest = {}
    for _, e in ipairs(roster) do if not seen[e.nameRealm] then rest[#rest + 1] = e end end
    table.sort(rest, function(a, b) return a.nameRealm < b.nameRealm end)
    for _, e in ipairs(rest) do ordered[#ordered + 1] = e end
    return ordered
end

function Dashboard.SaveCardOrder(faction, orderedNameRealms)
    local st = uiState()
    st.cardOrder = st.cardOrder or {}
    st.cardOrder[faction] = orderedNameRealms
end

----------------------------------------------------------------------
-- Tab registry. Tab files register a builder keyed by id; the shell owns the
-- canonical order + scope so tab-bar layout is independent of load order.
----------------------------------------------------------------------

Dashboard.tabBuilders = {}   -- id -> build(host) -> tabObj (must expose :Refresh())

-- scope "faction" = faction-scoped (underline in faction color);
-- scope "account" = account-wide (split underline).
local TAB_SLOTS = {
    { id = "sixties",   label = "60s",       scope = "faction" },
    { id = "online",    label = "Online",    scope = "faction" },
    { id = "summoners", label = "Summoners", scope = "faction" },
    { id = "timers",    label = "Timers",    scope = "account" },
    { id = "help",      label = "Help",      scope = "account" },
}

function Dashboard.RegisterTab(id, buildFn)
    Dashboard.tabBuilders[id] = buildFn
end

----------------------------------------------------------------------
-- DMF schedule (approximate). Classic Era Darkmoon Faire runs ~1 week/month,
-- alternating Elwynn (Alliance) and Mulgore (Horde). The exact server schedule
-- is not exposed to addons without the calendar loaded, so this is a computed
-- estimate anchored to a known faire start; the engine may override it later
-- via Dashboard.SetDMFSchedule. Clearly labelled "(est.)" in the status bar.
----------------------------------------------------------------------

-- Anchor: a Monday when a faire began (2024-02-05 was a Mulgore-week Monday).
local DMF_ANCHOR   = 1707091200   -- 2024-02-05 00:00 UTC (approx)
local DMF_PERIOD   = 28 * 86400   -- 4-week cadence
local DMF_DURATION = 7 * 86400
local Dmf_override  -- { active, zone, startEpoch, endEpoch }

function Dashboard.SetDMFSchedule(sched) Dmf_override = sched end

function Dashboard.GetDMFSchedule()
    if Dmf_override then return Dmf_override end
    local t = now()
    local phase = (t - DMF_ANCHOR) % DMF_PERIOD
    local cycleStart = t - phase
    local active = phase < DMF_DURATION
    -- Zone alternates each cycle.
    local cycleIdx = math.floor((cycleStart - DMF_ANCHOR) / DMF_PERIOD)
    local zone = (cycleIdx % 2 == 0) and "Mulgore" or "Elwynn Forest"
    if active then
        return { active = true, zone = zone, startEpoch = cycleStart,
                 endEpoch = cycleStart + DMF_DURATION, estimated = true }
    end
    -- Next faire.
    local nextStart = cycleStart + DMF_PERIOD
    local nextZone = ((cycleIdx + 1) % 2 == 0) and "Mulgore" or "Elwynn Forest"
    return { active = false, zone = nextZone, startEpoch = nextStart,
             endEpoch = nextStart + DMF_DURATION, estimated = true }
end

----------------------------------------------------------------------
-- Small chrome helpers
----------------------------------------------------------------------

-- A compact text header button (fixed height, centered label). Used for the
-- header action strip. Returns the button; sets :SetEnabledState(bool, tip).
local function makeHeaderButton(parent, text, onClick, width)
    local btn = UI.MakeButton(parent, {
        text = text, variant = "normal", width = width, height = 24,
        onClick = function(self)
            if self._disabled then return end
            if onClick then onClick(self) end
        end,
    })
    btn._disabled = false
    function btn:SetEnabledState(on, tip)
        self._disabled = not on
        self._label:SetFontObject(on and UI.fonts.body or UI.fonts.muted)
        self._tip = tip
    end
    btn:SetScript("OnEnter", function(self)
        if self._tip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(self._tip, UI.Color("muted"))
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end
Dashboard.MakeHeaderButton = makeHeaderButton

----------------------------------------------------------------------
-- Window construction (lazy, first Toggle after login)
----------------------------------------------------------------------

local win  -- the dashboard window frame

local function saveGeom()
    if not win then return end
    local st = uiState()
    local point, _, relPoint, x, y = win:GetPoint()
    st.dashGeom = {
        point = point, relPoint = relPoint, x = x, y = y,
        w = math.floor(win:GetWidth() + 0.5), h = math.floor(win:GetHeight() + 0.5),
    }
end

local function restoreGeom()
    local st = uiState()
    local g = st.dashGeom or {}
    win:SetSize(math.max(MIN_W, g.w or DEFAULT_W), math.max(MIN_H, g.h or DEFAULT_H))
    win:ClearAllPoints()
    win:SetPoint(g.point or "CENTER", UIParent, g.relPoint or "CENTER", g.x or 0, g.y or 0)
end

-- Active-tab bookkeeping.
Dashboard.activeTabId = nil
Dashboard._tabObjs = {}    -- id -> built tab object
Dashboard._tabPanes = {}   -- id -> host frame

-- Refresh the currently visible tab (called on engine callbacks + tab show).
function Dashboard.RefreshActive()
    local id = Dashboard.activeTabId
    local obj = id and Dashboard._tabObjs[id]
    if obj and obj.Refresh then ns:SafeCall(obj.Refresh) end
    Dashboard.RefreshStatusBar()
end

-- Current selected faction ("Alliance"/"Horde"). Defaults to the player's.
local function defaultFaction()
    local f = UnitFactionGroup and UnitFactionGroup("player")
    return (f == "Alliance" or f == "Horde") and f or "Alliance"
end
Dashboard.faction = nil
function Dashboard.GetFaction()
    if not Dashboard.faction then Dashboard.faction = defaultFaction() end
    return Dashboard.faction
end

function Dashboard.SetFaction(f)
    if f ~= "Alliance" and f ~= "Horde" then return end
    Dashboard.faction = f
    if win and win._updateFactionToggle then win._updateFactionToggle() end
    if win and win._updateTabUnderlines then win._updateTabUnderlines() end
    Dashboard.RefreshActive()
end

-- Faction underline color token: faction-scoped tabs use the faction color;
-- account-wide tabs split, but we approximate with the neutral accent since the
-- flat underline is one texture (documented — a split gradient would need art).
local FACTION_TOKEN = { Alliance = "accent", Horde = "danger" }

----------------------------------------------------------------------
-- Tab selection
----------------------------------------------------------------------

function Dashboard.SelectTab(id)
    if not win then return end
    -- Build the tab pane lazily on first selection.
    if not Dashboard._tabPanes[id] then
        local host = CreateFrame("Frame", nil, win.tabHost)
        host:SetAllPoints(win.tabHost)
        host:Hide()
        Dashboard._tabPanes[id] = host
        local builder = Dashboard.tabBuilders[id]
        if builder then
            local ok, obj = pcall(builder, host)
            if ok then Dashboard._tabObjs[id] = obj
            else geterrorhandler()(obj) end
        end
    end
    for tid, pane in pairs(Dashboard._tabPanes) do pane:SetShown(tid == id) end
    Dashboard.activeTabId = id
    local st = uiState(); st.lastTab = id
    if win._updateTabButtons then win._updateTabButtons() end
    Dashboard.RefreshActive()
end

----------------------------------------------------------------------
-- Header + tab bar + status bar construction
----------------------------------------------------------------------

local function buildHeader(w)
    local header = CreateFrame("Frame", nil, w)
    header:SetPoint("TOPLEFT", w, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", w, "TOPRIGHT", 0, 0)
    header:SetHeight(HEADER_H)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() w:StartMoving() end)
    header:SetScript("OnDragStop",  function() w:StopMovingOrSizing(); saveGeom() end)

    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", header, "TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -1, 0)
    UI.Skin(bg, function(self) self:SetColorTexture(UI.Color("panel")) end)

    -- Faction toggle (two crest buttons at the left).
    local CREST = 28
    local function crestButton(faction, x)
        local b = CreateFrame("Button", nil, header)
        b:SetSize(CREST, CREST)
        b:SetPoint("LEFT", header, "LEFT", x, 0)
        local tex = b:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(Dashboard.FactionCrest(faction))
        tex:SetTexCoord(unpack(CREST_COORD))
        b._tex = tex
        b:SetScript("OnClick", function() Dashboard.SetFaction(faction) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(faction, UI.Color("text"))
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end
    local allyBtn  = crestButton("Alliance", 10)
    local hordeBtn = crestButton("Horde", 10 + CREST + 4)

    w._updateFactionToggle = function()
        local f = Dashboard.GetFaction()
        allyBtn._tex:SetDesaturated(f ~= "Alliance")
        hordeBtn._tex:SetDesaturated(f ~= "Horde")
        allyBtn._tex:SetAlpha(f == "Alliance" and 1 or 0.5)
        hordeBtn._tex:SetAlpha(f == "Horde" and 1 or 0.5)
    end

    -- Centered title (serif header font).
    local title = header:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.header)
    title:SetPoint("CENTER", header, "CENTER", 0, 0)
    title:SetText("Daseeki Nexus")

    -- Right-side action strip: [Cancel Buffs] [Invite Online] [gear] [close].
    local closeBtn = CreateFrame("Button", nil, header)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -6, 0)
    local cx = closeBtn:CreateFontString(nil, "OVERLAY")
    cx:SetFontObject(UI.fonts.body)
    cx:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
    cx:SetText("X")
    closeBtn:SetScript("OnEnter", function() cx:SetFontObject(UI.fonts.danger) end)
    closeBtn:SetScript("OnLeave", function() cx:SetFontObject(UI.fonts.body) end)
    closeBtn:SetScript("OnClick", function() w:Hide() end)

    local gearBtn = makeHeaderButton(header, "Settings", function()
        if DaseekiSuite and DaseekiSuite.Open then
            DaseekiSuite:Open("nexus")
        else
            ns:Print("Daseeki hub not available.")
        end
    end, 72)
    gearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)

    local inviteBtn = makeHeaderButton(header, "Invite Online", function()
        if ns.Auto and ns.Auto.InviteOnline then
            ns.Auto.InviteOnline(Dashboard.GetFaction())
        end
    end, 100)
    inviteBtn:SetPoint("RIGHT", gearBtn, "LEFT", -6, 0)
    -- N4 owns Auto.InviteOnline; disabled with a tooltip until then.
    if not (ns.Auto and ns.Auto.InviteOnline) then
        inviteBtn:SetEnabledState(false, "Arrives in a later update.")
    end

    local cancelBtn = makeHeaderButton(header, "Cancel Buffs", function()
        if ns.HUD and ns.HUD.ShowCancelBuffs then ns.HUD.ShowCancelBuffs() end
    end, 100)
    cancelBtn:SetPoint("RIGHT", inviteBtn, "LEFT", -6, 0)
    if not (ns.HUD and ns.HUD.ShowCancelBuffs) then
        cancelBtn:SetEnabledState(false, "Cancel-Buffs popup arrives in a later update.")
    end

    w.header = header
    w._updateFactionToggle()
    return header
end

local function buildTabBar(w)
    local bar = CreateFrame("Frame", nil, w)
    bar:SetPoint("TOPLEFT", w, "TOPLEFT", 0, -HEADER_H)
    bar:SetPoint("TOPRIGHT", w, "TOPRIGHT", 0, -HEADER_H)
    bar:SetHeight(TAB_H)

    local rule = w:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", w, "TOPLEFT", 1, -(HEADER_H + TAB_H))
    rule:SetPoint("TOPRIGHT", w, "TOPRIGHT", -1, -(HEADER_H + TAB_H))
    UI.Skin(rule, function(self) self:SetColorTexture(UI.Color("borderLite")) end)

    local tabs = {}
    local x = PAD
    for _, slot in ipairs(TAB_SLOTS) do
        local b = CreateFrame("Button", nil, bar)
        b:SetHeight(TAB_H)
        b._id = slot.id
        b._scope = slot.scope
        local lbl = b:CreateFontString(nil, "OVERLAY")
        lbl:SetFontObject(UI.fonts.body)
        lbl:SetPoint("CENTER", b, "CENTER", 0, 0)
        lbl:SetText(slot.label)
        b._label = lbl
        local tw = math.max(48, (lbl:GetStringWidth() or 40) + 22)
        b:SetWidth(tw)
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
        x = x + tw + 4

        local under = b:CreateTexture(nil, "OVERLAY")
        under:SetHeight(2)
        under:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 6, 2)
        under:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -6, 2)
        under:Hide()
        b._under = under

        b:SetScript("OnClick", function(self) Dashboard.SelectTab(self._id) end)
        b:SetScript("OnEnter", function(self)
            if Dashboard.activeTabId ~= self._id then self._label:SetFontObject(UI.fonts.accent) end
        end)
        b:SetScript("OnLeave", function(self)
            if Dashboard.activeTabId ~= self._id then self._label:SetFontObject(UI.fonts.body) end
        end)
        tabs[#tabs + 1] = b
    end

    w._updateTabUnderlines = function()
        local ftok = FACTION_TOKEN[Dashboard.GetFaction()] or "accent"
        for _, b in ipairs(tabs) do
            local tok = (b._scope == "faction") and ftok or "accent"
            b._under:SetColorTexture(UI.Color(tok))
        end
    end
    w._updateTabButtons = function()
        for _, b in ipairs(tabs) do
            local active = (Dashboard.activeTabId == b._id)
            b._under:SetShown(active)
            b._label:SetFontObject(active and UI.fonts.accent or UI.fonts.body)
        end
    end

    -- Content host below the tab bar, above the status bar.
    local host = CreateFrame("Frame", nil, w)
    host:SetPoint("TOPLEFT", w, "TOPLEFT", PAD, -(HEADER_H + TAB_H + PAD))
    host:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -PAD, STATUS_H + PAD)
    w.tabHost = host

    w.tabBar = bar
    w._updateTabUnderlines()
    return bar
end

-- Status bar: Rend / Ony-A / Ony-H live states, guild-online count, DMF.
local function buildStatusBar(w)
    local bar = UI.FlatFrame(w, "panel", "border")
    bar:SetHeight(STATUS_H)
    bar:SetPoint("BOTTOMLEFT", w, "BOTTOMLEFT", 1, 1)
    bar:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -1, 1)

    local function seg(anchorTo, x)
        local fs = bar:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject(UI.fonts.small)
        if anchorTo then
            fs:SetPoint("LEFT", anchorTo, "RIGHT", x, 0)
        else
            fs:SetPoint("LEFT", bar, "LEFT", x, 0)
        end
        return fs
    end

    local rendFS = seg(nil, 10)
    local sep1   = seg(rendFS, 8);  sep1:SetText(Dashboard.Colored("·","faint"))
    local onyAFS = seg(sep1, 8)
    local sep2   = seg(onyAFS, 8);  sep2:SetText(Dashboard.Colored("·","faint"))
    local onyHFS = seg(sep2, 8)

    -- Two spaced request-button slots (their request plumbing is N4); reserve
    -- the space per the task so the later wave drops in without reflow.
    local slotA = CreateFrame("Frame", nil, bar); slotA:SetSize(18, 18)
    slotA:SetPoint("LEFT", onyHFS, "RIGHT", 16, 0)
    local slotB = CreateFrame("Frame", nil, bar); slotB:SetSize(18, 18)
    slotB:SetPoint("LEFT", slotA, "RIGHT", 6, 0)

    -- Guild-online count (green), hover list.
    local guildFS = bar:CreateFontString(nil, "OVERLAY")
    guildFS:SetFontObject(UI.fonts.small)
    guildFS:SetPoint("LEFT", slotB, "RIGHT", 16, 0)
    local guildHover = CreateFrame("Frame", nil, bar)
    guildHover:SetPoint("TOPLEFT", guildFS, "TOPLEFT", -2, 4)
    guildHover:SetPoint("BOTTOMRIGHT", guildFS, "BOTTOMRIGHT", 2, -4)
    guildHover:EnableMouse(true)
    guildHover:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Guild online", UI.Color("ok"))
        local list = Dashboard._guildOnline or {}
        if #list == 0 then
            GameTooltip:AddLine("Nobody online.", UI.Color("muted"))
        else
            for i = 1, math.min(#list, 30) do
                GameTooltip:AddDoubleLine(list[i].name, list[i].zone or "?",
                    1, 1, 1, UI.Color("muted"))
            end
        end
        GameTooltip:Show()
    end)
    guildHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- DMF schedule (right-aligned), hover for start/end.
    local dmfFS = bar:CreateFontString(nil, "OVERLAY")
    dmfFS:SetFontObject(UI.fonts.small)
    dmfFS:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    local dmfHover = CreateFrame("Frame", nil, bar)
    dmfHover:SetPoint("TOPLEFT", dmfFS, "TOPLEFT", -2, 4)
    dmfHover:SetPoint("BOTTOMRIGHT", dmfFS, "BOTTOMRIGHT", 2, -4)
    dmfHover:EnableMouse(true)
    dmfHover:SetScript("OnEnter", function(self)
        local s = Dashboard.GetDMFSchedule()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Darkmoon Faire" .. (s.estimated and " (estimated)" or ""), UI.Color("text"))
        GameTooltip:AddLine("Zone: " .. (s.zone or "?"), UI.Color("muted"))
        GameTooltip:AddDoubleLine("Start", date("%b %d %H:%M", s.startEpoch), UI.Color("muted"), 1, 1, 1)
        GameTooltip:AddDoubleLine("End", date("%b %d %H:%M", s.endEpoch), UI.Color("muted"), 1, 1, 1)
        GameTooltip:Show()
    end)
    dmfHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    w.status = { bar = bar, rend = rendFS, onyA = onyAFS, onyH = onyHFS,
                 guild = guildFS, dmf = dmfFS }
    return bar
end

----------------------------------------------------------------------
-- Status-bar refresh (world-buff states + guild + DMF). The pulse/color
-- semantics come from spec §0: steady green = can pop, steady orange = CD>20m,
-- fast-pulse red = CD<=20m or killed, grey = no data.
----------------------------------------------------------------------

local function anchorOf(state)
    if not state then return 0 end
    return math.max(state.lastPop or 0, state.lastKilled or 0)
end

-- Returns text, token, pulse(bool) for a buff key.
local function worldBuffCell(label, buffKey)
    local T = ns.Timers
    if not T then return label .. ": —", "faint", false end
    local state = T.state and T.state[buffKey]
    local anchor = anchorOf(state)
    local info = T.ComputeCD and T.ComputeCD(buffKey, anchor, now())
    if not info or anchor <= 0 then
        return label .. ": no data", "faint", false
    end
    if info.ready then
        return label .. ": Ready", "ok", false
    end
    local rem = info.remaining or 0
    if rem <= 20 * 60 then
        return label .. ": " .. Dashboard.FormatDuration(rem), "danger", true
    end
    return label .. ": " .. Dashboard.FormatDuration(rem), "accent", false
end

function Dashboard.RefreshStatusBar()
    if not win or not win.status then return end
    local s = win.status
    local faction = Dashboard.GetFaction()

    local function apply(fs, label, key)
        local text, token, pulse = worldBuffCell(label, key)
        fs._token, fs._pulse = token, pulse
        fs:SetText(text)
        fs:SetTextColor(UI.Color(token))
    end
    apply(s.rend, "Rend", "rend")
    apply(s.onyA, "Ony-A", "onyA")
    apply(s.onyH, "Ony-H", "onyH")

    -- Guild online.
    local list = Dashboard.QueryGuildOnline()
    Dashboard._guildOnline = list
    s.guild:SetText(Dashboard.Colored(("Guild: %d online"):format(#list),"ok"))

    -- DMF.
    local d = Dashboard.GetDMFSchedule()
    local dtext
    if d.active then
        dtext = ("DMF (est.): %s, ends %s"):format(d.zone, Dashboard.FormatDuration(d.endEpoch - now()))
    else
        dtext = ("DMF (est.): %s in %s"):format(d.zone, Dashboard.FormatDuration(d.startEpoch - now()))
    end
    s.dmf:SetText(dtext)
    s.dmf:SetTextColor(UI.Color("muted"))
end

-- Guild roster online snapshot: { {name, zone}, ... }.
function Dashboard.QueryGuildOnline()
    local out = {}
    if not (IsInGuild and IsInGuild()) then return out end
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
    local n = (GetNumGuildMembers and GetNumGuildMembers()) or 0
    for i = 1, n do
        local name, _, _, _, _, zone, _, _, online = GetGuildRosterInfo(i)
        if online and name then
            out[#out + 1] = { name = Dashboard.ShortName(name), zone = zone }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

----------------------------------------------------------------------
-- Status-bar pulse ticker (runs only while the window is shown).
----------------------------------------------------------------------

local function installStatusTicker(w)
    local accum = 0
    w:SetScript("OnUpdate", function(self, elapsed)
        accum = accum + elapsed
        -- Pulse (every frame) for red-flagged world-buff cells.
        if self.status then
            local t = GetTime()
            local a = 0.5 + 0.5 * math.abs(math.sin(t * 3))
            for _, key in ipairs({ "rend", "onyA", "onyH" }) do
                local fs = self.status[key]
                if fs and fs._pulse then fs:SetAlpha(a) else if fs then fs:SetAlpha(1) end end
            end
        end
        -- Text refresh ~4x/sec.
        if accum >= 0.25 then
            accum = 0
            Dashboard.RefreshStatusBar()
        end
    end)
end

----------------------------------------------------------------------
-- The window itself
----------------------------------------------------------------------

local function ensureWindow()
    if win then return win end

    win = CreateFrame("Frame", "DaseekiNexusDashboard", UIParent, "BackdropTemplate")
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:SetResizable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    if win.SetResizeBounds then win:SetResizeBounds(MIN_W, MIN_H) end
    win:Hide()
    UI.Skin(win, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("ground"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)

    tinsert(UISpecialFrames, "DaseekiNexusDashboard")   -- Escape closes

    buildHeader(win)
    buildTabBar(win)
    buildStatusBar(win)

    -- Corner resize grip (bottom-right, visible).
    local grip = CreateFrame("Button", nil, win)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -2, 2)
    for i = 1, 3 do
        local ln = grip:CreateTexture(nil, "OVERLAY")
        ln:SetSize(2, 2 + (i - 1) * 4)
        ln:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -(i - 1) * 4, 2)
        UI.Skin(ln, function(self) self:SetColorTexture(UI.Color("borderLite")) end)
    end
    grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        win:StopMovingOrSizing(); saveGeom(); Dashboard.RefreshActive()
    end)

    win:SetScript("OnSizeChanged", function() Dashboard.RefreshActive() end)
    win:SetScript("OnShow", function()
        win._updateFactionToggle()
        win._updateTabUnderlines()
        Dashboard.RefreshActive()
    end)
    installStatusTicker(win)

    restoreGeom()

    -- Default tab: last used within session, else 60s.
    local st = uiState()
    local start = st.lastTab or "sixties"
    if not Dashboard.tabBuilders[start] and start ~= "help" then start = "sixties" end
    Dashboard.SelectTab(start)

    Dashboard.window = win
    return win
end
Dashboard.EnsureWindow = ensureWindow

----------------------------------------------------------------------
-- Public open / toggle / reset
----------------------------------------------------------------------

function Dashboard.Show(tabId)
    ensureWindow()
    if tabId then Dashboard.SelectTab(tabId) end
    win:Show()
end

function Dashboard.Toggle(tabId)
    ensureWindow()
    if win:IsShown() and not tabId then
        win:Hide()
    else
        if tabId then Dashboard.SelectTab(tabId) end
        win:Show()
    end
end

function Dashboard.ResetUI()
    ensureWindow()
    local st = uiState()
    st.dashGeom = nil
    win:SetSize(DEFAULT_W, DEFAULT_H)
    win:ClearAllPoints()
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    saveGeom()
    Dashboard.RefreshActive()
    ns:Print("dashboard layout reset.")
end

----------------------------------------------------------------------
-- Engine callback subscriptions (refresh the active tab + status bar).
----------------------------------------------------------------------

local function onEngineChange() if win and win:IsShown() then Dashboard.RefreshActive() end end
ns:On("STATE_CHANGED", onEngineChange)
ns:On("TIMER_UPDATED", onEngineChange)
ns:On("NODE_UPDATED", onEngineChange)
ns:On("CD_WARNING", onEngineChange)

----------------------------------------------------------------------
-- SHARED: character detail panel (spec §1; shared by 60s + Online).
--
-- A scrolling column rebuilt on Show(entry). Uses pooled row frames so a
-- re-selection never leaks frames. Every visual reads tokens + re-skins.
----------------------------------------------------------------------

local function fs(parent, fontKey)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[fontKey] or UI.fonts.body)
    return f
end

function Dashboard.BuildDetailPanel(parent)
    local D = {}
    local box = UI.FlatFrame(parent, "panel", "border")
    box:SetAllPoints(parent)
    D.frame = box

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", box, "TOPLEFT", 12, -12)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -12, 12)
    scroll:SetClipsChildren(true)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 28)))
    end)
    D.scroll, D.child = scroll, child

    -- Empty-state label.
    local empty = fs(child, "muted")
    empty:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -4)
    empty:SetText("Select a character.")
    D.empty = empty

    -- Pools.
    D._headers, D._lines, D._buffRows, D._raidRows = {}, {}, {}, {}

    local function getHeader(i)
        local h = D._headers[i]
        if not h then
            h = UI.MakeSectionHeader(child, "")
            D._headers[i] = h
        end
        return h
    end
    local function getLine(i)
        local l = D._lines[i]
        if not l then
            l = fs(child, "body"); l:SetJustifyH("LEFT"); l:SetWordWrap(true)
            D._lines[i] = l
        end
        return l
    end
    local function getBuffRow(i)
        local r = D._buffRows[i]
        if not r then
            r = CreateFrame("Frame", nil, child)
            r:SetHeight(20)
            r.icon = r:CreateTexture(nil, "ARTWORK")
            r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
            r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            r.name = fs(r, "body"); r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
            r.val = fs(r, "muted"); r.val:SetPoint("RIGHT", r, "RIGHT", 0, 0); r.val:SetJustifyH("RIGHT")
            D._buffRows[i] = r
        end
        return r
    end
    local function getRaidRow(i)
        local r = D._raidRows[i]
        if not r then
            r = CreateFrame("Frame", nil, child)
            r:SetHeight(18)
            r.dot = r:CreateTexture(nil, "ARTWORK")
            r.dot:SetSize(8, 8); r.dot:SetPoint("LEFT", r, "LEFT", 2, 0)
            r.name = fs(r, "body"); r.name:SetPoint("LEFT", r.dot, "RIGHT", 8, 0)
            r.val = fs(r, "muted"); r.val:SetPoint("RIGHT", r, "RIGHT", 0, 0); r.val:SetJustifyH("RIGHT")
            D._raidRows[i] = r
        end
        return r
    end

    -- Manual-location override editbox (created once; retargeted per Show).
    local locBox = CreateFrame("EditBox", nil, child, "BackdropTemplate")
    locBox:SetHeight(22); locBox:SetAutoFocus(false)
    locBox:SetFontObject(UI.fonts.body); locBox:SetTextInsets(8, 8, 0, 0)
    UI.Skin(locBox, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    locBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    locBox:SetScript("OnEscapePressed", function(self)
        self:SetText(ns.Store.GetManualLocation(D._current or "") or ""); self:ClearFocus()
    end)
    locBox:SetScript("OnEditFocusLost", function(self)
        if D._current then
            local t = self:GetText()
            ns.Store.SetManualLocation(D._current, (t ~= "" and t) or nil)
        end
    end)
    D.locBox = locBox

    local function hideAll()
        for _, h in ipairs(D._headers) do h:Hide() end
        for _, l in ipairs(D._lines) do l:Hide() end
        for _, r in ipairs(D._buffRows) do r:Hide() end
        for _, r in ipairs(D._raidRows) do r:Hide() end
        locBox:Hide()
    end

    function D:Show(entry)
        hideAll()
        if not entry or not entry.rec then
            empty:Show()
            child:SetHeight(1)
            return
        end
        empty:Hide()
        D._current = entry.nameRealm
        D._entry = entry
        local rec = entry.rec
        local W = scroll:GetWidth() - 2; if W < 1 then W = parent:GetWidth() - 30 end
        child:SetWidth(math.max(W, 1))
        local y = 0
        local li, bi, ri, hi = 0, 0, 0, 0

        local function line(text, fontKey, tokenOverride)
            li = li + 1
            local l = getLine(li)
            l:SetFontObject(UI.fonts[fontKey or "body"])
            if tokenOverride then l:SetTextColor(UI.Color(tokenOverride)) end
            l:ClearAllPoints()
            l:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            l:SetWidth(W)
            l:SetText(text)
            l:Show()
            y = y + (l:GetStringHeight() or 14) + 4
        end
        local function header(text)
            hi = hi + 1
            local h = getHeader(hi)
            h._label:SetText(text)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            h:SetWidth(W)
            h:Show()
            y = y + h.uiHeight + 2
        end

        -- Name (class-colored header).
        li = li + 1
        local nameFS = getLine(li)
        nameFS:SetFontObject(UI.fonts.header)
        nameFS:ClearAllPoints()
        nameFS:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        nameFS:SetWidth(W)
        nameFS:SetText(Dashboard.ColoredName(entry.nameRealm, rec.classTag))
        nameFS:Show()
        y = y + 22

        -- Status + last update.
        local onlineTxt = entry.online and Dashboard.Colored("Online","ok") or Dashboard.Colored("Offline","faint")
        line(("Status: %s  |  %s"):format(onlineTxt, Dashboard.FreshnessText(rec.lastDataUpdate)), "muted")
        -- Meta.
        local acct = (entry.aid ~= "" and entry.aid) or "?"
        line(("Account %s  |  %s  |  %s"):format(acct, rec.className or "?", rec.faction or "?"), "muted")
        if rec.pvpFlagged then line("PvP flagged", "danger") end

        -- Location + source + manual override.
        header("Location")
        line("Current: " .. (rec.location or Dashboard.Colored("Missing location","danger")), "body")
        li = li + 1
        local lblManual = getLine(li)
        lblManual:SetFontObject(UI.fonts.small)
        lblManual:ClearAllPoints()
        lblManual:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        lblManual:SetWidth(W); lblManual:SetText("Manual override:")
        lblManual:Show()
        y = y + 16
        locBox:ClearAllPoints()
        locBox:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        locBox:SetWidth(math.min(280, W))
        locBox:SetText(ns.Store.GetManualLocation(entry.nameRealm) or "")
        locBox:Show()
        y = y + 26

        -- Buffs.
        header("Buffs")
        for _, slot in ipairs(Dashboard.AURA_DISPLAY_ORDER) do
            local meta = Dashboard.AURA_META[slot]
            local st = rec.auraStates and rec.auraStates[slot]
            bi = bi + 1
            local r = getBuffRow(bi)
            r.icon:SetTexture(meta.icon)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            r:SetWidth(W)
            if st and (st.duration or 0) > 0 then
                local th = Dashboard.GetThreshold(entry.faction or rec.faction, meta.thresholdKey)
                local tok = Dashboard.AuraColorToken(st.duration, th)
                r.icon:SetDesaturated(false)
                r.name:SetText(meta.name); r.name:SetTextColor(UI.Color(tok))
                local annot = rec.chronoboonActive and "  (Boon)" or ""
                r.val:SetText(Dashboard.FormatDuration(st.duration) .. annot)
                r.val:SetTextColor(UI.Color(tok))
            else
                r.icon:SetDesaturated(true)
                r.name:SetText(meta.name); r.name:SetTextColor(UI.Color("faint"))
                local missTxt = rec.chronoboonActive and "UNBOONED" or "Missing"
                r.val:SetText(missTxt); r.val:SetTextColor(UI.Color("faint"))
            end
            r:Show()
            y = y + 22
        end

        -- Cooldowns.
        header("Cooldowns")
        line(("Chronoboon: %s (%d in bags)"):format(
            rec.chronoboonActive and "active" or "none", rec.boonCount or 0), "body")
        local dmfTxt = rec.dmfInBoon and "in Boon" or (rec.dmfCooldownActive and "on cooldown" or "available")
        line("Darkmoon fortune: " .. dmfTxt, "body")
        if (rec.hearthstoneCD or 0) > 0 then
            line("Hearthstone: " .. Dashboard.FormatDuration(rec.hearthstoneCD), "body")
        else
            line("Hearthstone: ready", "body")
        end
        if rec.classTag == "WARLOCK" then
            line("Soul shards: " .. (rec.shardCount or 0), "body")
        end

        -- Raids.
        header("Raids")
        local nowE = now()
        for _, key in ipairs(Dashboard.RAID_DISPLAY) do
            ri = ri + 1
            local r = getRaidRow(ri)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            r:SetWidth(W)
            local expiry = rec.raidLockouts and rec.raidLockouts[key]
            local locked = expiry and expiry > nowE
            r.dot:SetColorTexture(UI.Color(locked and "danger" or "ok"))
            r.name:SetText(key); r.name:SetTextColor(UI.Color("text"))
            if locked then
                r.val:SetText("Locked · " .. Dashboard.FormatDuration(expiry - nowE))
                r.val:SetTextColor(UI.Color("danger"))
            else
                r.val:SetText("Available"); r.val:SetTextColor(UI.Color("ok"))
            end
            r:Show()
            y = y + 18
        end

        child:SetHeight(math.max(y + 8, 1))
        scroll:SetVerticalScroll(0)
    end

    box:SetScript("OnSizeChanged", function()
        -- Re-lay the current selection so text widths recompute on resize.
        if D._entry then D:Show(D._entry) end
    end)

    return D
end

----------------------------------------------------------------------
-- SHARED: roster two-pane (card list + shared detail). Used by 60s + Online.
--
-- opts = {
--   gather = function() -> ordered roster entries,
--   makeCard = function(parent) -> card frame with :Populate(entry) (+ height),
--   cardHeight = number,
--   enableDrag = bool,          -- 60s drag-reorder + persist per faction
--   listHint = string,          -- caption under the list title
--   listTitle = string,
-- }
-- Returns { frame, Refresh, Select }.
----------------------------------------------------------------------

function Dashboard.BuildRosterPane(host, opts)
    local R = { _cards = {}, _selected = nil }
    local GAP = Dashboard.SPLIT_GAP
    local LIST_W = Dashboard.CARD_LIST_W
    local cardH = opts.cardHeight or 92

    -- Left column: title + hint + scroll card list.
    local left = UI.FlatFrame(host, "inset", "border")
    left:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
    left:SetWidth(LIST_W)

    local title = fs(left, "accent")
    title:SetPoint("TOPLEFT", left, "TOPLEFT", 10, -8)
    title:SetText(opts.listTitle or "Roster")
    local hint = fs(left, "small")
    hint:SetPoint("TOPRIGHT", left, "TOPRIGHT", -10, -10)
    hint:SetText(opts.listHint or "")

    local listScroll = CreateFrame("ScrollFrame", nil, left)
    listScroll:SetPoint("TOPLEFT", left, "TOPLEFT", 8, -28)
    listScroll:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -8, 8)
    listScroll:SetClipsChildren(true)
    listScroll:EnableMouseWheel(true)
    local listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(1, 1)
    listScroll:SetScrollChild(listChild)
    listScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, listChild:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 30)))
    end)
    R._listScroll, R._listChild = listScroll, listChild

    -- Blue insertion line for drag-reorder.
    local insLine = listChild:CreateTexture(nil, "OVERLAY")
    insLine:SetHeight(2)
    insLine:Hide()
    UI.Skin(insLine, function(self) self:SetColorTexture(UI.Color("accent")) end)
    R._insLine = insLine

    -- Right: shared detail panel.
    local right = CreateFrame("Frame", nil, host)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", GAP, 0)
    right:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
    local detail = Dashboard.BuildDetailPanel(right)
    R._detail = detail

    local function getCard(i)
        local c = R._cards[i]
        if not c then
            c = opts.makeCard(listChild)
            c:SetHeight(cardH)
            c:EnableMouse(true)
            c:RegisterForClicks("LeftButtonUp")
            c:SetScript("OnClick", function(self) R._onCardClick(self) end)
            R._enableDragOn(c)
            R._cards[i] = c
        end
        return c
    end

    local function selectEntry(entry)
        R._selected = entry and entry.nameRealm or nil
        detail:Show(entry)
        R.Refresh()
    end
    R.Select = selectEntry

    function R.Refresh()
        local roster = opts.gather()
        R._ordered = roster
        local W = listScroll:GetWidth(); if W < 1 then W = LIST_W - 16 end
        listChild:SetWidth(W)
        for _, c in ipairs(R._cards) do c:Hide() end
        local y = 0
        for i, entry in ipairs(roster) do
            local c = getCard(i)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -y)
            c:SetWidth(W)
            c._entry = entry
            c:Populate(entry, entry.nameRealm == R._selected)
            c:Show()
            y = y + cardH + 6
        end
        listChild:SetHeight(math.max(y, 1))
        -- Keep detail current for the selected entry (data may have changed).
        if R._selected then
            for _, e in ipairs(roster) do
                if e.nameRealm == R._selected then detail:Show(e); break end
            end
        end
    end

    -- Click-to-select + optional drag-reorder wiring is attached per card by
    -- the card factory calling R._bindCard(card). Expose the hooks it needs.
    R._onCardClick = function(card)
        if card._entry then selectEntry(card._entry) end
    end

    -- Drag reorder (60s). Card factory calls R._enableDragOn(card) if wanted.
    R._enableDragOn = function(card)
        if not opts.enableDrag then return end
        card:RegisterForDrag("LeftButton")
        card:SetScript("OnDragStart", function(self)
            R._dragging = self
            self:SetAlpha(0.5)
        end)
        card:SetScript("OnDragStop", function(self)
            self:SetAlpha(1)
            R._insLine:Hide()
            local target = R._dropIndex
            R._dragging = nil
            if target and self._entry then
                -- Rebuild order with this entry moved to target index.
                local order = {}
                for _, e in ipairs(R._ordered) do
                    if e.nameRealm ~= self._entry.nameRealm then order[#order + 1] = e.nameRealm end
                end
                table.insert(order, math.max(1, math.min(#order + 1, target)), self._entry.nameRealm)
                Dashboard.SaveCardOrder(Dashboard.GetFaction(), order)
                R.Refresh()
            end
        end)
        card:SetScript("OnUpdate", function(self)
            if R._dragging ~= self then return end
            local _, cursorY = GetCursorPosition()
            local scale = listChild:GetEffectiveScale()
            local topY = listChild:GetTop() or 0
            local rel = (topY - (cursorY / scale))
            local idx = math.floor(rel / (cardH + 6)) + 1
            R._dropIndex = math.max(1, math.min(#R._ordered + 1, idx))
            R._insLine:ClearAllPoints()
            R._insLine:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -((R._dropIndex - 1) * (cardH + 6)) + 3)
            R._insLine:SetPoint("TOPRIGHT", listChild, "TOPRIGHT", 0, 0)
            R._insLine:Show()
        end)
    end

    listScroll:SetScript("OnSizeChanged", function() R.Refresh() end)

    R.frame = host
    return R
end

----------------------------------------------------------------------
-- Slash wiring — replace the core.lua stubs (RegisterSubcommand overwrites).
----------------------------------------------------------------------

ns:RegisterSubcommand("toggle", function() Dashboard.Toggle() end, "show/hide the dashboard")
ns:RegisterSubcommand("x", function()
    if ns.HUD and ns.HUD.ShowCancelBuffs then ns.HUD.ShowCancelBuffs()
    else ns:Print("Cancel-Buffs popup arrives in a later update.") end
end, "cancel-buffs popup")
ns:RegisterSubcommand("resetui", function() Dashboard.ResetUI() end, "reset dashboard layout")
ns:RegisterSubcommand("reset",   function() Dashboard.ResetUI() end, "reset dashboard layout")

----------------------------------------------------------------------
-- Help tab (static, our brand + our commands). Shell-owned.
----------------------------------------------------------------------

Dashboard.RegisterTab("help", function(host)
    local pane = UI.CreatePane(host)
    local flow = pane.flow

    local s = flow:AddSection("Daseeki Nexus")
    s:Hint("Cross-account world-buff dashboard and timers for the Daseeki suite.")

    local c = flow:AddSection("Slash commands")
    c:Hint("Primary /nexus (short /dnx); /dsn and /daseekinetwork still work.")
    c:Label("/nexus toggle    — show or hide this dashboard")
    c:Label("/nexus x         — open the Cancel Buffs popup")
    c:Label("/nexus resetui   — recenter and reset the window size")
    c:Label("/nexus account <id>  — show or set this account's mesh ID")
    c:Label("/nexus help      — full command list in chat")

    local t = flow:AddSection("Tabs")
    t:Label("60s        — every level-60 alt on the selected faction, with buffs")
    t:Label("Online     — the full roster, online characters first")
    t:Label("Summoners  — warlocks available to summon, sortable")
    t:Label("Timers     — world-buff cooldowns and Felwood songflowers")

    local g = flow:AddSection("Getting started")
    g:Hint("Set a unique Account ID and the shared Mesh channel/token in the Daseeki hub "
        .. "(the Settings button, top-right), then relog once. Characters appear across "
        .. "your accounts within seconds.")

    pane:Layout()
    return { Refresh = function() pane:Layout() end }
end)
