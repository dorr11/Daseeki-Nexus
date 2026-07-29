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

-- Canonical faction identity colors (Alliance royal blue / Horde crimson).
-- These are GAME identity, not theme decoration, so they are deliberately NOT
-- theme tokens (the active theme's accent can be ember/fel/ice and must never
-- stand in for "Alliance"). The task sanctions literal faction colors routed
-- through UI.Skin; the segmented faction toggle re-skins from these. r,g,b 0..1.
local FACTION_COLOR = {
    Alliance = { 0.15, 0.35, 0.85 },
    Horde    = { 0.75, 0.14, 0.14 },
}
function Dashboard.FactionColor(faction)
    local c = FACTION_COLOR[faction] or FACTION_COLOR.Alliance
    return c[1], c[2], c[3]
end

function Dashboard.FactionCrest(faction)
    return FACTION_CREST[faction] or FACTION_CREST.Alliance
end

----------------------------------------------------------------------
-- Aura metadata (the tracked-buff model).
--
-- Storage authority is tracker.lua: it fills record.auraStates[1..10] by a
-- FIXED slot layout. AURA_META mirrors that slot layout exactly (index == slot)
-- and adds presentation (name/short) plus the per-faction threshold key used to
-- color the buff (spec §2's 9 configurable auras). Slots without a threshold
-- key (Silithyst, Boon of Blackfathom) are always optional.
--
-- ICON SOURCE OF TRUTH (owner feedback #1 — "buff icons arent correct"): icons
-- are NOT hardcoded Interface\Icons guesses any more. Each slot carries the
-- REAL game `spellID` (the same catalogue options.lua AURA_DEFS uses) and the
-- icon is derived at runtime via Dashboard.AuraIcon(slot) →
-- C_Spell.GetSpellTexture(spellID) (question-mark fallback). This is the single
-- source shared by ui_shell (detail), ui_tab_sixties (cards) and ui_tab_timers.
--
-- CROSS-FILE CONTRACT: `thresholdKey` values here are the keys the hub's
-- aura-config page (options.lua AURA_DEFS) writes into
-- GetFactionSettings().auraOpts.thresholds, and that the importer
-- (import.lua AURA_SLOT_KEY) resolves SN's positional thresholds onto. Keys
-- (exact, case-sensitive): dmf, ony, dmtAP, dmtSP, dmtStam, songflower, zg,
-- rend (+ battleShout, which has no storage slot). `spellID` values mirror
-- options.lua AURA_DEFS one-for-one; the two tail slots add their own real IDs.
----------------------------------------------------------------------

Dashboard.AURA_META = {
    [1]  = { key = "ony",       name = "Rallying Cry of the Dragonslayer", short = "Ony",  thresholdKey = "ony",        spellID = 22888 },
    [2]  = { key = "rend",      name = "Warchief's Blessing",              short = "Rend", thresholdKey = "rend",       spellID = 16609 },
    [3]  = { key = "zg",        name = "Spirit of Zandalar",               short = "ZG",   thresholdKey = "zg",         spellID = 24425 },
    [4]  = { key = "songflower",name = "Songflower Serenade",              short = "SF",   thresholdKey = "songflower", spellID = 15366 },
    [5]  = { key = "dmf",       name = "Sayge's Dark Fortune",             short = "DMF",  thresholdKey = "dmf",        spellID = 23768 },
    [6]  = { key = "dmtap",     name = "Fengus' Ferocity",                 short = "AP",   thresholdKey = "dmtAP",      spellID = 22817 },
    [7]  = { key = "dmtstam",   name = "Mol'dar's Moxie",                  short = "Stam", thresholdKey = "dmtStam",    spellID = 22818 },
    [8]  = { key = "dmtsp",     name = "Slip'kik's Savvy",                 short = "SP",   thresholdKey = "dmtSP",      spellID = 22820 },
    [9]  = { key = "silithyst", name = "Traces of Silithyst",             short = "Sili", thresholdKey = nil,          spellID = 29534 },
    [10] = { key = "boon",      name = "Boon of Blackfathom",              short = "BFD",  thresholdKey = nil,          spellID = 430947 },
}

-- Explicit unknown marker (Blizzard built-in) — NOT a guess at any buff's art,
-- just the graceful fallback when a spell/item icon cannot be resolved.
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Resolve a tracked-aura slot's icon from its real spellID. Catalog-verified
-- (build 1.15.9): C_Spell.GetSpellTexture(spellID) -> iconID, with the legacy
-- global GetSpellTexture as a fallback. Successful lookups are cached; a nil
-- (spell not loaded / not in this client, e.g. the SoD-only Boon) is NOT cached
-- so a later refresh retries, and renders the question mark until then.
local _auraIconCache = {}
function Dashboard.AuraIcon(slot)
    local meta = Dashboard.AURA_META[slot]
    if not meta then return QUESTION_ICON end
    local cached = _auraIconCache[slot]
    if cached then return cached end
    local tex
    local id = meta.spellID
    if id then
        if C_Spell and C_Spell.GetSpellTexture then
            tex = C_Spell.GetSpellTexture(id)
        elseif GetSpellTexture then
            tex = GetSpellTexture(id)
        end
    end
    if tex then _auraIconCache[slot] = tex; return tex end
    return QUESTION_ICON
end

-- Resolve a real item's inventory icon by itemID (owner feedback #7 — the
-- Chronoboon Displacer 184937 and Hearthstone 6948 were guessed). Catalog:
-- C_Item.GetItemIconByID(itemID) -> icon:fileID, legacy GetItemIcon fallback.
local _itemIconCache = {}
function Dashboard.ItemIcon(itemID, fallback)
    if not itemID then return fallback or QUESTION_ICON end
    local cached = _itemIconCache[itemID]
    if cached then return cached end
    local icon
    if C_Item and C_Item.GetItemIconByID then icon = C_Item.GetItemIconByID(itemID) end
    if not icon and GetItemIcon then icon = GetItemIcon(itemID) end
    if icon then _itemIconCache[itemID] = icon; return icon end
    return fallback or QUESTION_ICON
end

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

-- Full raid names for diamond-pip tooltips (60s cards, parity item 1) and the
-- detail Raids rows (parity item 2). Keys match Store.RAID_KEYS.
Dashboard.RAID_FULLNAME = {
    Naxx = "Naxxramas",
    AQ40 = "Temple of Ahn'Qiraj",
    BWL  = "Blackwing Lair",
    MC   = "Molten Core",
    ZG   = "Zul'Gurub",
    AQ20 = "Ruins of Ahn'Qiraj",
    Ony  = "Onyxia's Lair",
}

-- Reset-cadence groups (parity item 2): the detail Raids section renders these
-- in order with a small vertical gap BETWEEN groups, mirroring the reference's
-- weekly / 3-day / 5-day visual grouping. The flat RAID_DISPLAY order above is
-- exactly the concatenation of these groups, so the card pip row is unaffected.
Dashboard.RAID_GROUPS = {
    { cadence = "Weekly", keys = { "Naxx", "AQ40", "BWL", "MC" } },
    { cadence = "3-day",  keys = { "ZG", "AQ20" } },
    { cadence = "5-day",  keys = { "Ony" } },
}

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

-- Token-drawn diamond pip (parity items 1 & 2 — raid-lockout pips as diamonds).
-- A small solid WHITE8X8 square rotated 45° renders as a filled diamond, tinted
-- from a theme token so the whole thing stays tokens-only (no custom .tga; the
-- network design doc mandates token-drawn shapes for pips/arrows/stripes). Size
-- is the square edge; the rotated diamond's bounding box is ~size*1.41, so give
-- each pip ~size*1.6 of horizontal room. `layer` optional (default ARTWORK).
function Dashboard.MakeDiamond(parent, size, layer)
    size = size or 9
    local d = parent:CreateTexture(nil, layer or "ARTWORK")
    d:SetTexture("Interface\\Buttons\\WHITE8X8")
    d:SetSize(size, size)
    d:SetRotation(0.7853981633974483)   -- math.rad(45)
    return d
end
function Dashboard.SetDiamondColor(tex, token, alpha)
    local r, g, b = UI.Color(token)
    tex:SetVertexColor(r, g, b, alpha or 1)
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

-- Shared duration formatter (owner feedback #2 — "time values are in hours, not
-- days"). One function for cards, detail, status bar and DMF. Breaks seconds
-- into a d/h/m ladder and shows the TWO LARGEST non-zero units, so long spans
-- read in days: 300h38m -> "12d 12h", 463h31m -> "19d 7h". Sub-hour spans show
-- a single unit ("45m", "30s"). `style`:
--   nil/"short"  -> spaced, human ("12d 12h", "1h 05m", "45m")
--   "compact"    -> no spaces, for tight cells ("12d12h", "1h05m")
-- Clamped at 0.
function Dashboard.FormatDuration(sec, style)
    sec = math.max(0, math.floor(sec or 0))
    local sep = (style == "compact") and "" or " "
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if d > 0 then
        if h > 0 then return ("%dd%s%dh"):format(d, sep, h) end
        return ("%dd"):format(d)
    elseif h > 0 then
        if m > 0 then return ("%dh%s%02dm"):format(h, sep, m) end
        return ("%dh"):format(h)
    elseif m > 0 then
        return ("%dm"):format(m)
    end
    return ("%ds"):format(s)
end

-- Client-side decay of a stored remaining-cooldown value. A record carries the
-- seconds remaining AT THE MOMENT it was captured (rec.lastDataUpdate); for a
-- REMOTE character no fresh update may arrive for minutes, so the displayed
-- countdown must age locally: remaining = stored - (now - lastUpdate), floored at
-- 0 (an elapsed cooldown reads "ready"). For the self record lastUpdate ~= now so
-- the subtraction is ~0. Clock skew (future lastUpdate) clamps elapsed to 0 so a
-- remote clock ahead of ours can't inflate the countdown. Pure + self-tested.
function Dashboard.DecayRemaining(stored, lastUpdate, nowE)
    stored = tonumber(stored) or 0
    if stored <= 0 then return 0 end
    if nowE == nil then nowE = Dashboard.Now() end
    local elapsed = nowE - (tonumber(lastUpdate) or 0)
    if elapsed < 0 then elapsed = 0 end
    local rem = stored - elapsed
    if rem < 0 then rem = 0 end
    return math.floor(rem)
end

-- DMF cooldown remaining (owner task 4 — the "DMFable" tracker, folded onto the
-- DMF buff row). The engine models the Darkmoon-fortune cooldown as a boolean
-- (rec.dmfCooldownActive) plus rec.dmfCooldown.offlineSince; the only duration in
-- the model is the sibling ~8h resting-offline auto-clear (store.lua's private
-- DMF_OFFLINE_CLEAR + Store.SweepOfflineDMF). We must not touch store.lua here
-- (a concurrent branch owns it), so: prefer a Store accessor if that branch adds
-- one, otherwise mirror the 8h rule locally. Returns seconds until the CD would
-- auto-clear, or 0 when not on cooldown / online (offlineSince == 0 → no clock).
-- ⚠ The mirrored constant duplicates store.lua's private one; the clean end state
-- is Store exposing Store.DMFCooldownRemaining and this fallback being deleted.
local DMF_OFFLINE_CLEAR = 8 * 3600
local function dmfCooldownRemaining(rec, nowE)
    if ns.Store and ns.Store.DMFCooldownRemaining then
        return ns.Store.DMFCooldownRemaining(rec, nowE) or 0
    end
    if not (rec and rec.dmfCooldownActive and rec.dmfCooldown) then return 0 end
    local since = rec.dmfCooldown.offlineSince or 0
    if since <= 0 then return 0 end
    local rem = (since + DMF_OFFLINE_CLEAR) - (nowE or now())
    return rem > 0 and math.floor(rem) or 0
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
-- Aura applicability / requirement (owner feedback #3 — "missing buffs arent
-- displayed"). Shared by the 60s card strip and the detail panel so both agree
-- on what a MISSING slot should look like.
--
-- Rules (spec §1):
--   * Rend (slot 2) and Slip'kik's Savvy / DMT SP (slot 8) are governed by
--     per-class rule maps GetFactionSettings().auraOpts.{rend,dmtSP}
--     {required|optional|ignored}[class] (see CLASS_RULED_KEYS). Ignored
--     classes are non-applicable (hidden); optional = greyed-no-border when
--     missing; required = danger border / red "Missing". Slip'kik defaults
--     physical classes (War/Rogue/Hunter) to ignored, casters to optional.
--   * Every other threshold-bearing world buff (Ony/ZG/Songflower/DMF/DMT AP/
--     DMT Stam) is required-by-default: applicable + "required" for everyone.
--   * The two tail slots without a threshold key (Silithyst, Boon of Blackfathom)
--     are OPTIONAL and treated as non-applicable when ABSENT, so they collapse
--     out of the strip/detail instead of littering every card with two grey
--     seasonal/PvP icons (spec §1 "seasonal-absent hidden"; style-guide prime
--     directive "clean and compact"). When PRESENT they still render normally.
--     ⚠ Deviation from a literal "all others required-by-default": the tail
--     slots stay optional/collapsing — flagged for cheap owner override.
--   * Battle Shout has no storage slot here, so its class map drives no display
--     row (the engine still consumes it elsewhere).
----------------------------------------------------------------------

-- Threshold keys whose applicability is governed by a per-class
-- required/optional/ignored map in auraOpts (keyed identically to the
-- thresholdKey). Rend was the first; Slip'kik's Savvy (dmtSP) joins it so
-- physical classes hide it by default while casters see it as optional.
local CLASS_RULED_KEYS = { rend = true, dmtSP = true }

-- Class rule state for an aura opt map ("rend"/"battleShout"/"dmtSP") on a faction.
function Dashboard.ClassRuleState(optKey, classTag, faction)
    if not classTag then return "ignored" end
    local fs = ns.Store and ns.Store.GetFactionSettings and ns.Store.GetFactionSettings(faction)
    local o = fs and fs.auraOpts and fs.auraOpts[optKey]
    if not o then return "ignored" end
    if o.required and o.required[classTag] then return "required" end
    if o.optional and o.optional[classTag] then return "optional" end
    return "ignored"
end

-- Returns applicable(bool), requirement("required"|"optional") for a slot on a
-- character. applicable=false means "hide this slot when the buff is absent".
function Dashboard.AuraRequirement(slot, rec, faction)
    local meta = Dashboard.AURA_META[slot]
    if not meta then return false end
    if meta.thresholdKey and CLASS_RULED_KEYS[meta.thresholdKey] then
        local st = Dashboard.ClassRuleState(meta.thresholdKey, rec and rec.classTag, faction)
        if st == "ignored" then return false, "optional" end
        return true, st
    end
    if not meta.thresholdKey then
        -- Optional tail slots collapse when absent (see rationale above).
        return false, "optional"
    end
    return true, "required"
end

-- Stable online-first partition (owner feedback #4). Preserves the incoming
-- (drag) order WITHIN each group, so drag-reorder still persists while online
-- characters automatically float to the top. table.sort is unstable, so this is
-- done by hand rather than a comparator.
function Dashboard.PartitionOnlineFirst(list)
    local onlineGrp, offlineGrp = {}, {}
    for _, e in ipairs(list) do
        if e.online then onlineGrp[#onlineGrp + 1] = e else offlineGrp[#offlineGrp + 1] = e end
    end
    for _, e in ipairs(offlineGrp) do onlineGrp[#onlineGrp + 1] = e end
    return onlineGrp
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
-- align "right" pins a tab to the RIGHT end of the bar (owner feedback 2b:
-- Help sits in a right-aligned group, mirroring the reference's Help/Settings
-- cluster). Everything else is the left group in declared order.
local TAB_SLOTS = {
    -- Field Ledger rebuild (BRAND_SPEC §7): Characters is the ONLY roster screen.
    -- The former 60s + Summoners + Online tabs collapse into it — scope singles
    -- (All / 60s / Summoners) and modifier toggles now live in the chip row
    -- (ui_roster.lua), and the open-entry register replaces the two-pane detail.
    { id = "characters", label = "Characters", scope = "faction" },
    { id = "timers",     label = "Timers",     scope = "account" },
    -- Instance-entry ledger + cap meters (NovaInstanceTracker absorption). Account-
    -- wide (the caps are enforced per account; the tab's ALL row is cross-account).
    { id = "instances",  label = "Instances",  scope = "account" },
    { id = "help",       label = "Help",       scope = "account", align = "right" },
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

local DMF_DURATION = 7 * 86400
local Dmf_override  -- { active, zone, startEpoch, endEpoch }

function Dashboard.SetDMFSchedule(sched) Dmf_override = sched end

-- Day-of-week (0=Sunday .. 6=Saturday) for a Gregorian Y-M-D via Sakamoto's
-- method — pure arithmetic, no os.* — so the calendar rule is self-testable.
local DOW_T = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
local function dayOfWeek(y, m, d)
    if m < 3 then y = y - 1 end
    return (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + DOW_T[m] + d) % 7
end

-- PURE Darkmoon Faire plan for a calendar month (owner task 12). The faire opens
-- the Monday AFTER the month's first Friday (00:00) and runs 7 days. Zone
-- alternates by calendar month, anchored so an EVEN month is Mulgore (Aug 2026)
-- and an ODD month is Elwynn Forest (Jul/Sep 2026). Returns
-- { firstFriday, opensDay, zone } as day-of-month numbers — no os.* calls.
function Dashboard.DMFMonthPlan(year, month)
    local fri = 1
    for d = 1, 7 do
        if dayOfWeek(year, month, d) == 5 then fri = d; break end
    end
    return { firstFriday = fri, opensDay = fri + 3,   -- Monday after the first Friday
             zone = (month % 2 == 0) and "Mulgore" or "Elwynn Forest" }
end

-- Live schedule off the real calendar. `nowOverride` (epoch) is a test seam. Uses
-- os.time/os.date when present (real in the harness; the harness's global `time`
-- stub ignores its table argument, so os.time is preferred), else the WoW `time`/
-- `date` globals in-game. Keeps now()'s clock base for the active/next decision.
function Dashboard.GetDMFSchedule(nowOverride)
    if Dmf_override then return Dmf_override end
    -- WoW has NO global `os` table; `os.time` would error ("attempt to index
    -- global 'os' (a nil value)") BEFORE the `or time` fallback ever ran, so this
    -- function was dead in-game and error-stormed the status-bar tick. Presence-
    -- check via rawget so the harness (real Lua, os present) still prefers os.*.
    local osT   = rawget(_G, "os")
    local _time = (osT and osT.time) or time
    local _date = (osT and osT.date) or date
    local t = nowOverride or now()
    local c = _date("*t", t)
    local y, m = c.year, c.month
    local function monthWindow(yy, mm)
        local plan = Dashboard.DMFMonthPlan(yy, mm)
        local startE = _time({ year = yy, month = mm, day = plan.opensDay, hour = 0, min = 0, sec = 0 })
        return plan, startE, startE + DMF_DURATION
    end
    local plan, startEpoch, endEpoch = monthWindow(y, m)
    if t >= endEpoch then
        -- This month's faire has ended — advance to next month's estimate.
        m = m + 1; if m > 12 then m = 1; y = y + 1 end
        plan, startEpoch, endEpoch = monthWindow(y, m)
    end
    return { active = (t >= startEpoch and t < endEpoch), zone = plan.zone,
             startEpoch = startEpoch, endEpoch = endEpoch, estimated = true }
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

    -- Faction toggle (owner feedback #5 — "make it look more like the SN one"):
    -- a proper labelled segmented control, two touching halves "Alliance" /
    -- "Horde" each with crest + text, the ACTIVE half filled with its faction
    -- color (Alliance blue / Horde red) and the inactive half dimmed. Compact,
    -- sized for the 44px header (style guide: clean + compact, one grid).
    local SEG_H, SEG_W = 26, 92
    local segTop = math.floor((HEADER_H - SEG_H) / 2)   -- vertically centered
    local factionSegs = {}
    local function factionSeg(faction, label, x)
        local b = CreateFrame("Button", nil, header, "BackdropTemplate")
        b:SetSize(SEG_W, SEG_H)
        b:SetPoint("TOPLEFT", header, "TOPLEFT", x, -segTop)
        b._faction = faction

        local crest = b:CreateTexture(nil, "ARTWORK")
        crest:SetSize(16, 16)
        crest:SetPoint("LEFT", b, "LEFT", 8, 0)
        crest:SetTexture(Dashboard.FactionCrest(faction))
        crest:SetTexCoord(unpack(CREST_COORD))
        b._crest = crest

        local lbl = b:CreateFontString(nil, "OVERLAY")
        lbl:SetFontObject(UI.fonts.body)
        lbl:SetPoint("LEFT", crest, "RIGHT", 5, 0)
        lbl:SetText(label)
        b._lbl = lbl

        b._setActive = function(self, on)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            if on then
                local r, g, bl = Dashboard.FactionColor(faction)
                self:SetBackdropColor(r, g, bl, 0.85)
                self:SetBackdropBorderColor(r, g, bl, 1)
                self._crest:SetDesaturated(false); self._crest:SetAlpha(1)
                self._lbl:SetTextColor(UI.Color("text"))
            else
                self:SetBackdropColor(UI.Color("control"))
                self:SetBackdropBorderColor(UI.Color("controlBorder"))
                self._crest:SetDesaturated(true); self._crest:SetAlpha(0.5)
                self._lbl:SetTextColor(UI.Color("faint"))
            end
        end
        b:SetScript("OnClick", function() Dashboard.SetFaction(faction) end)
        -- Re-skin on theme change (inactive side reads theme tokens; active side
        -- reads the faction color) — both routed through the active state.
        UI.Skin(b, function(self) self:_setActive(Dashboard.GetFaction() == faction) end)
        factionSegs[#factionSegs + 1] = b
        return b
    end
    factionSeg("Alliance", "Alliance", PAD)
    factionSeg("Horde", "Horde", PAD + SEG_W)   -- touching halves, shared seam

    w._updateFactionToggle = function()
        local f = Dashboard.GetFaction()
        for _, b in ipairs(factionSegs) do b:_setActive(b._faction == f) end
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

    -- The "Cancel Buffs" header button was removed (owner feedback 2b). The
    -- Cancel-Buffs popup stays reachable via the /nexus x slash command and the
    -- minimap button's Ctrl+Right-click. Invite Online is now the leftmost
    -- header action, so no gap remains where the button used to sit.

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
    local leftX  = PAD   -- growing offset from the bar's LEFT edge
    local rightX = PAD   -- growing offset from the bar's RIGHT edge (right group)
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
        if slot.align == "right" then
            -- Anchor to the bar's RIGHT edge so it tracks window resizes.
            b:SetPoint("RIGHT", bar, "RIGHT", -rightX, 0)
            rightX = rightX + tw + 4
        else
            b:SetPoint("LEFT", bar, "LEFT", leftX, 0)
            leftX = leftX + tw + 4
        end

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

----------------------------------------------------------------------
-- Status-bar request buttons (owner feedback #6 + spec §0). Two compact
-- circular buttons: request Nexus data / request NWB (guild) data. Wired to the
-- parallel agent's ns.Timers.Request* APIs via soft guards, with state colors
-- (grey none-available / green ready / red cooldown) and freshness tooltips
-- from ns.Timers.GetSourceFreshness().
----------------------------------------------------------------------

local REQUEST_COOLDOWN = 30            -- local throttle between our requests (s)
local _requestSent = { nexus = 0, nwb = 0 }
local REQ_API  = { nexus = "RequestNexusData", nwb = "RequestNWBData" }
local REQ_NAME = { nexus = "Nexus", nwb = "NWB (guild)" }
-- Blizzard built-in circular status indicators (green/red/grey dots).
local INDICATOR = {
    grey  = "Interface\\COMMON\\Indicator-Gray",
    green = "Interface\\COMMON\\Indicator-Green",
    red   = "Interface\\COMMON\\Indicator-Red",
}

local function requestApiPresent(sourceKey)
    return (ns.Timers and ns.Timers[REQ_API[sourceKey]]) and true or false
end

-- Soft-guard around ns.Timers.GetSourceFreshness() -> { nexus, nwb, snPassive }.
function Dashboard.SourceFreshness(sourceKey)
    local T = ns.Timers
    if not (T and T.GetSourceFreshness) then return nil end
    local ok, tbl = pcall(T.GetSourceFreshness)
    if ok and type(tbl) == "table" then
        local ts = tbl[sourceKey]
        if ts and ts > 0 then return ts end
    end
    return nil
end

-- Returns state("disabled"|"grey"|"green"|"red"), remaining(seconds).
function Dashboard.RequestState(sourceKey)
    if not requestApiPresent(sourceKey) then return "disabled", 0 end
    local rem = ((_requestSent[sourceKey] or 0) + REQUEST_COOLDOWN) - now()
    if rem > 0 then return "red", rem end
    -- NWB data comes from the guild; grey when nobody is online to answer.
    if sourceKey == "nwb" and #(Dashboard._guildOnline or {}) == 0 then
        return "grey", 0
    end
    return "green", 0
end

function Dashboard.OnRequestClick(sourceKey)
    if Dashboard.RequestState(sourceKey) ~= "green" then return end
    local fn = ns.Timers and ns.Timers[REQ_API[sourceKey]]
    if fn then ns:SafeCall(fn) end
    _requestSent[sourceKey] = now()
    Dashboard.RefreshStatusBar()
end

function Dashboard.FillRequestTooltip(sourceKey)
    local name = REQ_NAME[sourceKey] or sourceKey
    GameTooltip:AddLine("Request " .. name .. " data", UI.Color("text"))
    local state, rem = Dashboard.RequestState(sourceKey)
    if state == "disabled" then
        GameTooltip:AddLine("Not available in this build yet.", UI.Color("muted"))
    elseif state == "red" then
        GameTooltip:AddLine("On cooldown — " .. Dashboard.FormatDuration(rem) .. " left.", UI.Color("danger"))
    elseif state == "grey" then
        GameTooltip:AddLine("No guild members online to answer.", UI.Color("muted"))
    else
        GameTooltip:AddLine("Click to request now.", UI.Color("ok"))
    end
    local fresh = Dashboard.SourceFreshness(sourceKey)
    if fresh then
        GameTooltip:AddLine("Last update: " .. Dashboard.FormatDuration(now() - fresh) .. " ago", UI.Color("muted"))
    end
end

-- Paint a request button's dot + interactivity from its live state.
function Dashboard.ApplyRequestButton(b)
    local state = Dashboard.RequestState(b._sourceKey)
    local tex = INDICATOR.grey
    if state == "green" then tex = INDICATOR.green
    elseif state == "red" then tex = INDICATOR.red end
    b._dot:SetTexture(tex)
    if state == "disabled" then
        b._dot:SetDesaturated(true); b:SetAlpha(0.5)
        b._lbl:SetTextColor(UI.Color("faint"))
    else
        b._dot:SetDesaturated(false); b:SetAlpha(1)
        b._lbl:SetTextColor(UI.Color("text"))
    end
end

-- Status bar: Rend / Ony-A / Ony-H live states, request buttons, guild-online
-- count, DMF.
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

    -- Icon-tile label (annot round-2 pin 1/2): the status-bar readouts' TEXT LABELS
    -- ("Rend:", "Onyxia (A):", "Onyxia (H):") become real icon tiles — the Rend buff
    -- spell icon and the Alliance/Horde faction crests — while the live VALUE stays
    -- text (BRAND_SPEC §5a/§7). `coord` crops the source art (spell icons trim the
    -- 1px border; crests use CREST_COORD, the same rect the Timers rows use).
    local ICON = 14
    local function iconTile(anchorTo, gap, tex, coord)
        local t = bar:CreateTexture(nil, "ARTWORK")
        t:SetSize(ICON, ICON)
        if anchorTo then t:SetPoint("LEFT", anchorTo, "RIGHT", gap, 0)
        else             t:SetPoint("LEFT", bar, "LEFT", gap, 0) end
        t:SetTexture(tex)
        t:SetTexCoord(unpack(coord or { 0.08, 0.92, 0.08, 0.92 }))
        return t
    end

    -- Rend: spell-icon tile (slot 2 = Warchief's Blessing) then the live value.
    local rendIcon = iconTile(nil, 10, Dashboard.AuraIcon(2))
    local rendFS   = seg(rendIcon, 5)
    local sep1     = seg(rendFS, 8);  sep1:SetText(Dashboard.Colored("·","faint"))
    -- Onyxia: ONE shared Ony spell-icon (slot 1 = Rallying Cry of the Dragonslayer)
    -- identifies the buff, then each faction crest + its value. (Owner left the shared
    -- icon optional — kept, because A/H crests alone don't say "Onyxia"; the spell art
    -- does the identifying and the crests disambiguate faction.)
    local onyIcon  = iconTile(sep1, 8, Dashboard.AuraIcon(1))
    local crestA   = iconTile(onyIcon, 5, Dashboard.FactionCrest("Alliance"), CREST_COORD)
    local onyAFS   = seg(crestA, 5)
    local sep2     = seg(onyAFS, 8);  sep2:SetText(Dashboard.Colored("·","faint"))
    local crestH   = iconTile(sep2, 8, Dashboard.FactionCrest("Horde"), CREST_COORD)
    local onyHFS   = seg(crestH, 5)

    -- Pulse companions: when a cell red-flags (CD<=20m), the value text fades — carry
    -- its label icon(s) with it so the pair reads as one flagged unit. The shared Ony
    -- spell icon stays steady (it labels both cells).
    rendFS._pulseMates = { rendIcon }
    onyAFS._pulseMates = { crestA }
    onyHFS._pulseMates = { crestH }

    -- Two compact circular request buttons (Nexus / NWB-guild). Wired to the
    -- parallel agent's soft-guarded ns.Timers.Request* APIs; state + tooltip via
    -- the Dashboard request module above.
    local function requestButton(sourceKey, letter, anchorTo)
        local b = CreateFrame("Button", nil, bar)
        b:SetSize(16, 16)
        if anchorTo then b:SetPoint("LEFT", anchorTo, "RIGHT", 8, 0)
        else b:SetPoint("LEFT", onyHFS, "RIGHT", 18, 0) end
        b._sourceKey = sourceKey
        local dot = b:CreateTexture(nil, "ARTWORK")
        dot:SetAllPoints()
        b._dot = dot
        local lbl = b:CreateFontString(nil, "OVERLAY")
        lbl:SetFontObject(UI.fonts.small)
        lbl:SetPoint("CENTER", b, "CENTER", 0, 0)
        lbl:SetText(letter)
        b._lbl = lbl
        b:SetScript("OnClick", function(self) Dashboard.OnRequestClick(self._sourceKey) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            Dashboard.FillRequestTooltip(self._sourceKey)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        UI.Skin(b, function(self) Dashboard.ApplyRequestButton(self) end)
        return b
    end
    local reqNexus = requestButton("nexus", "N", nil)
    local reqNWB   = requestButton("nwb", "G", reqNexus)

    -- Guild-online count (green), hover list.
    local guildFS = bar:CreateFontString(nil, "OVERLAY")
    guildFS:SetFontObject(UI.fonts.small)
    guildFS:SetPoint("LEFT", reqNWB, "RIGHT", 16, 0)
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
                 rendIcon = rendIcon, onyIcon = onyIcon, crestA = crestA, crestH = crestH,
                 guild = guildFS, dmf = dmfFS, reqNexus = reqNexus, reqNWB = reqNWB }
    return bar
end

----------------------------------------------------------------------
-- Status-bar refresh (world-buff states + guild + DMF). The pulse/color
-- semantics come from spec §0: steady green = Open (off-cooldown), steady orange
-- = CD>20m, fast-pulse red = CD<=20m or killed, grey = no data.
----------------------------------------------------------------------

local function anchorOf(state)
    if not state then return 0 end
    return math.max(state.lastPop or 0, state.lastKilled or 0)
end

-- Returns VALUE text, token, pulse(bool) for a buff key. The label is now an icon
-- tile (annot round-2), so this returns only the live readout value — BRAND_SPEC
-- §5a/§7: status-bar readouts keep their TEXT values; only the labels became icons.
local function worldBuffCell(buffKey)
    local T = ns.Timers
    if not T then return "—", "faint", false end
    local state = T.state and T.state[buffKey]
    local anchor = anchorOf(state)
    local info = T.ComputeCD and T.ComputeCD(buffKey, anchor, now())
    if not info or anchor <= 0 then
        return "no data", "faint", false
    end
    if info.ready then
        -- Off-cooldown world buff = green "Open" (BRAND_SPEC §6 binding).
        return "Open", "ok", false
    end
    local rem = info.remaining or 0
    if rem <= 20 * 60 then
        return Dashboard.FormatDuration(rem), "danger", true
    end
    return Dashboard.FormatDuration(rem), "accent", false
end

function Dashboard.RefreshStatusBar()
    if not win or not win.status then return end
    local s = win.status
    local faction = Dashboard.GetFaction()

    local function apply(fs, key)
        local text, token, pulse = worldBuffCell(key)
        fs._token, fs._pulse = token, pulse
        fs:SetText(text)
        fs:SetTextColor(UI.Color(token))
    end
    apply(s.rend, "rend")
    apply(s.onyA, "onyA")
    apply(s.onyH, "onyH")

    -- Re-resolve the spell-icon tiles: at build time the spell art may not have been
    -- loaded (AuraIcon returns the ? fallback uncached), so refresh once it's in.
    if s.rendIcon then s.rendIcon:SetTexture(Dashboard.AuraIcon(2)) end
    if s.onyIcon  then s.onyIcon:SetTexture(Dashboard.AuraIcon(1))  end

    -- Guild online.
    local list = Dashboard.QueryGuildOnline()
    Dashboard._guildOnline = list
    s.guild:SetText(Dashboard.Colored(("Guild: %d online"):format(#list),"ok"))

    -- Request buttons (state depends on the guild-online snapshot just taken).
    if s.reqNexus then Dashboard.ApplyRequestButton(s.reqNexus) end
    if s.reqNWB then Dashboard.ApplyRequestButton(s.reqNWB) end

    -- DMF.
    local d = Dashboard.GetDMFSchedule()
    local dtext
    if d.active then
        dtext = ("Darkmoon: %s, ends %s (est.)"):format(d.zone, Dashboard.FormatDuration(d.endEpoch - now()))
    else
        dtext = ("Darkmoon: %s in %s (est.)"):format(d.zone, Dashboard.FormatDuration(d.startEpoch - now()))
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
    local accum, accumTab = 0, 0
    w:SetScript("OnUpdate", function(self, elapsed)
        accum = accum + elapsed
        accumTab = accumTab + elapsed
        -- Pulse (every frame) for red-flagged world-buff cells.
        if self.status then
            local t = GetTime()
            local a = 0.5 + 0.5 * math.abs(math.sin(t * 3))
            for _, key in ipairs({ "rend", "onyA", "onyH" }) do
                local fs = self.status[key]
                if fs then
                    local av = fs._pulse and a or 1
                    fs:SetAlpha(av)
                    if fs._pulseMates then
                        for _, m in ipairs(fs._pulseMates) do m:SetAlpha(av) end
                    end
                end
            end
        end
        -- Text refresh ~4x/sec.
        if accum >= 0.25 then
            accum = 0
            Dashboard.RefreshStatusBar()
        end
        -- Active-tab repaint ~1/sec so time-based cell text (chrono/hearth
        -- cooldown countdowns, "Updated Xm ago" freshness) ticks down on its own
        -- via this SHARED ticker — no per-card OnUpdate. Suppressed mid drag-
        -- reorder so a relayout can't yank the card out from under the cursor.
        if accumTab >= 1 then
            accumTab = 0
            if not Dashboard._rosterDragging then
                Dashboard.RefreshActive()
            end
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
    local start = st.lastTab or "characters"
    if not Dashboard.tabBuilders[start] and start ~= "help" then start = "characters" end
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
-- Bulk store refresh (the importer's dedicated crash-safe signal, replacing an
-- args-less STATE_CHANGED). Same refresh path so an import — or any future bulk
-- store change — repaints the active tab + status bar.
ns:On("STORE_REFRESHED", onEngineChange)

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
            -- Diamond pip (parity item 2), tinted green/red per lockout state.
            r.dot = Dashboard.MakeDiamond(r, 9)
            r.dot:SetPoint("LEFT", r, "LEFT", 4, 0)
            r.name = fs(r, "body"); r.name:SetPoint("LEFT", r.dot, "RIGHT", 10, 0)
            r.val = fs(r, "muted"); r.val:SetPoint("RIGHT", r, "RIGHT", 0, 0); r.val:SetJustifyH("RIGHT")
            D._raidRows[i] = r
        end
        return r
    end

    -- Per-character Notes editbox (owner task 9 — replaces the old manual-location
    -- override; Location now shows the game-captured zone only). Reads/writes the
    -- Store.GetNote/SetNote API being added CONCURRENTLY in store.lua; calls are
    -- GUARDED so this branch parses + self-tests green standalone before the merge.
    local function noteGet(nameRealm)
        if ns.Store and ns.Store.GetNote then return ns.Store.GetNote(nameRealm) end
        return nil
    end
    local function noteSet(nameRealm, text)
        if ns.Store and ns.Store.SetNote then ns.Store.SetNote(nameRealm, text) end
    end
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
        self:SetText(noteGet(D._current or "") or ""); self:ClearFocus()
    end)
    locBox:SetScript("OnEditFocusLost", function(self)
        if D._current then
            local t = self:GetText()
            noteSet(D._current, (t ~= "" and t) or nil)   -- empty string clears (nil)
        end
    end)
    D.locBox = locBox
    D._noteGet = noteGet

    -- Chrono + hearth cooldown ICONS (owner task 5): the old Cooldowns text lines
    -- become an icons-only stack in the panel's top-right, mirroring the roster
    -- card's corner stack (chrono on top, hearth below; chrono holds a fixed slot
    -- so hearth never shifts). No text labels — a tooltip carries the old detail.
    local function detailIcon(size)
        local f = CreateFrame("Frame", nil, child, "BackdropTemplate")
        f:SetSize(size, size)
        local ic = f:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        f.icon = ic
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self)
            if not self._tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            for _, ln in ipairs(self._tip) do GameTooltip:AddLine(ln[1], ln[2], ln[3], ln[4]) end
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return f
    end
    local chronoIcon = detailIcon(18)
    chronoIcon:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -2)
    local hearthIcon = detailIcon(18)
    hearthIcon:SetPoint("TOPRIGHT", chronoIcon, "BOTTOMRIGHT", 0, -4)
    D.chronoIcon, D.hearthIcon = chronoIcon, hearthIcon
    -- Right-side reserve for the top header lines so they never run under the
    -- icon stack at narrow panel widths (owner task 5 collision guard).
    D.ICON_RESERVE = 26

    local function hideAll()
        for _, h in ipairs(D._headers) do h:Hide() end
        for _, l in ipairs(D._lines) do l:Hide() end
        for _, r in ipairs(D._buffRows) do r:Hide() end
        for _, r in ipairs(D._raidRows) do r:Hide() end
        locBox:Hide()
        chronoIcon:Hide(); hearthIcon:Hide()
    end

    function D:Show(entry)
        hideAll()
        if not entry or not entry.rec then
            empty:Show()
            child:SetHeight(1)
            D._shownId = nil
            return
        end
        empty:Hide()
        -- Scroll preservation (owner task 6): the shared ~1s ticker re-Shows the
        -- selected character every tick, which used to snap the scroll to the top.
        -- The content structure is identical between ticks for the same character
        -- (only VALUES change), so a full rebuild is geometry-stable — capture the
        -- offset before the rebuild and restore it (clamped) when the character is
        -- unchanged; jump to the top only when a DIFFERENT character is selected.
        local sameChar = (D._shownId ~= nil and D._shownId == entry.nameRealm)
        local prevScroll = scroll:GetVerticalScroll()
        D._current = entry.nameRealm
        D._entry = entry
        local rec = entry.rec
        local W = scroll:GetWidth() - 2; if W < 1 then W = parent:GetWidth() - 30 end
        child:SetWidth(math.max(W, 1))
        local y = 0
        local li, bi, ri, hi = 0, 0, 0, 0

        local function line(text, fontKey, tokenOverride, rightReserve)
            li = li + 1
            local l = getLine(li)
            l:SetFontObject(UI.fonts[fontKey or "body"])
            if tokenOverride then l:SetTextColor(UI.Color(tokenOverride)) end
            l:ClearAllPoints()
            l:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            l:SetWidth(W - (rightReserve or 0))
            l:SetText(text)
            l:Show()
            y = y + (l:GetStringHeight() or 14) + 4
            return l
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

        -- Name (class-colored header). Width is reserved on the right so the name
        -- can't run under the top-right cooldown-icon stack (owner task 5).
        local RSV = D.ICON_RESERVE or 26
        li = li + 1
        local nameFS = getLine(li)
        nameFS:SetFontObject(UI.fonts.header)
        nameFS:ClearAllPoints()
        nameFS:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        nameFS:SetWidth(W - RSV)
        nameFS:SetWordWrap(false)
        nameFS:SetText(Dashboard.ColoredName(entry.nameRealm, rec.classTag))
        nameFS:Show()
        y = y + 22

        -- Status + last update (right-reserved to clear the icon stack).
        local onlineTxt = entry.online and Dashboard.Colored("Online","ok") or Dashboard.Colored("Offline","faint")
        line(("Status: %s  |  %s"):format(onlineTxt, Dashboard.FreshnessText(rec.lastDataUpdate)), "muted", nil, RSV)
        -- Meta.
        local acct = (entry.aid ~= "" and entry.aid) or "?"
        line(("Account %s  |  %s  |  %s"):format(acct, rec.className or "?", rec.faction or "?"), "muted", nil, RSV)
        -- PvP-flagged warning (parity item 4): red "PVP Flagged" with the
        -- character's faction crest inline (sub-rect of the PvP crest art).
        if rec.pvpFlagged then
            local crest = rec.faction
                and ("|T%s:14:14:0:0:64:64:1:40:2:40|t "):format(Dashboard.FactionCrest(rec.faction))
                or ""
            line(crest .. "PVP Flagged", "body", "danger")
        end

        -- Top-right cooldown ICONS (owner task 5): icons only, state mirrored from
        -- the roster card (chrono shows while booned OR on use-CD; hearth always
        -- shows, desaturated while on CD). Anchored to the child, so they sit
        -- beside the header block. Tooltips carry what the old text lines said.
        do
            local nowE0 = now()
            hearthIcon.icon:SetTexture(Dashboard.ItemIcon(6948))    -- Hearthstone
            chronoIcon.icon:SetTexture(Dashboard.ItemIcon(184937))  -- Chronoboon Displacer
            local chronoRem = Dashboard.DecayRemaining(rec.itemCooldown, rec.lastDataUpdate, nowE0)
            if rec.chronoboonActive then
                chronoIcon:Show(); chronoIcon:SetBackdrop(UI.FLAT_BACKDROP)
                chronoIcon:SetBackdropColor(UI.Color("inset"))
                chronoIcon:SetBackdropBorderColor(UI.Color((rec.boonCount or 0) == 0 and "danger" or "accent"))
                chronoIcon.icon:SetDesaturated(false)
            elseif chronoRem > 0 then
                chronoIcon:Show(); chronoIcon:SetBackdrop(UI.FLAT_BACKDROP)
                chronoIcon:SetBackdropColor(UI.Color("inset"))
                chronoIcon:SetBackdropBorderColor(UI.Color("border"))
                chronoIcon.icon:SetDesaturated(true)
            else
                chronoIcon:Hide()
            end
            local hearthRem = Dashboard.DecayRemaining(rec.hearthstoneCD, rec.lastDataUpdate, nowE0)
            hearthIcon:Show()
            hearthIcon.icon:SetDesaturated(hearthRem > 0)
            -- Tooltips (nice-to-have): the old Cooldowns lines' content.
            local boonState = rec.chronoboonActive and "Active"
                or (((rec.boonCount or 0) > 0) and "Ready" or "None")
            local chTip = {{ "Chronoboon Displacer", UI.Color("accent") },
                { ("%d in bags  ·  %s"):format(rec.boonCount or 0, boonState), UI.Color("text") }}
            if chronoRem > 0 then chTip[#chTip+1] = { "Cooldown " .. Dashboard.FormatDuration(chronoRem), UI.Color("danger") } end
            chronoIcon._tip = chTip
            local hTok = hearthRem > 0 and "danger" or "ok"
            hearthIcon._tip = {{ "Hearthstone", UI.Color("accent") },
                { hearthRem > 0 and Dashboard.FormatDuration(hearthRem) or "Ready", UI.Color(hTok) }}
        end

        -- Location (owner task 9: game-captured zone only — no manual override) +
        -- a free-text per-character Notes field.
        header("Location")
        line("Current: " .. (rec.location or Dashboard.Colored("Missing location","danger")), "body")
        li = li + 1
        local lblNotes = getLine(li)
        lblNotes:SetFontObject(UI.fonts.small)
        lblNotes:ClearAllPoints()
        lblNotes:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        lblNotes:SetWidth(W); lblNotes:SetText("Notes:")
        lblNotes:Show()
        y = y + 16
        locBox:ClearAllPoints()
        locBox:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        locBox:SetWidth(math.min(280, W))
        locBox:SetText(noteGet(entry.nameRealm) or "")
        locBox:Show()
        y = y + 26

        -- Buffs (owner feedback #3 — list EVERY applicable tracked aura, with a
        -- red "Missing" when absent; non-applicable rows collapse). Icons come
        -- from the real spell (owner feedback #1) via Dashboard.AuraIcon.
        header("Buffs")
        for _, slot in ipairs(Dashboard.AURA_DISPLAY_ORDER) do
            local meta = Dashboard.AURA_META[slot]
            local st = rec.auraStates and rec.auraStates[slot]
            local present = st and (st.duration or 0) > 0
            local applicable, requirement = Dashboard.AuraRequirement(slot, rec, entry.faction or rec.faction)
            if present or applicable then
                bi = bi + 1
                local r = getBuffRow(bi)
                r.icon:SetTexture(Dashboard.AuraIcon(slot))
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                r:SetWidth(W)
                -- Row label is "ABBR - Full Name" (parity item 3), e.g.
                -- "DMF - Sayge's Dark Fortune", "SF - Songflower Serenade".
                local label = ("%s - %s"):format(meta.short, meta.name)
                local baseVal, baseTok
                if present then
                    local th = Dashboard.GetThreshold(entry.faction or rec.faction, meta.thresholdKey)
                    local tok = Dashboard.AuraColorToken(st.duration, th)
                    -- Booned contents (parity item 37): a slot whose source is
                    -- "boon" is a chronoboon-stored buff — render it green with a
                    -- green "(Boon)" suffix ("1h 59m (Boon)") per the reference,
                    -- regardless of threshold. The engine (tracker tooltip parse)
                    -- writes source="boon" + the parsed remaining into the slot.
                    -- Hand-merge reconciliation: engine ships numeric sources
                    -- (Store.AURA_SOURCE.BOON == 2), not the string "boon".
                    local BOON = (ns.Store and ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
                    local booned = (st.source == BOON or st.source == "boon")
                    if booned then tok = "ok" end
                    r.icon:SetDesaturated(false); r.icon:SetVertexColor(1, 1, 1); r.icon:SetAlpha(1)
                    r.name:SetText(label); r.name:SetTextColor(UI.Color(tok))
                    local annot = booned and " (Boon)" or ""
                    baseVal, baseTok = Dashboard.FormatDuration(st.duration) .. annot, tok
                else
                    -- Missing + applicable: greyed icon; "ABBR - Full Name" + a red
                    -- "MISSING" (owner task 3 — was "Missing"/"UNBOONED"). Required
                    -- stays danger; optional keeps its warn/amber treatment.
                    local tok = (requirement == "optional") and warnToken() or "danger"
                    r.icon:SetDesaturated(true); r.icon:SetVertexColor(0.7, 0.7, 0.7); r.icon:SetAlpha(0.5)
                    r.name:SetText(label); r.name:SetTextColor(UI.Color(tok))
                    baseVal, baseTok = "MISSING", tok
                end
                -- DMF-ability parenthetical (owner task 4): on the DMF row only,
                -- append the Darkmoon-fortune cooldown state IN ADDITION to the
                -- buff-state label — green "(READY)" when a new fortune can be
                -- taken, else the remaining cooldown in red. Inline-tokened so it
                -- keeps its own colour beside the row's state colour.
                if meta.key == "dmf" then
                    local par, ptok
                    if not rec.dmfCooldownActive then
                        par, ptok = "(READY)", "ok"
                    else
                        local rem = dmfCooldownRemaining(rec, now())
                        if rem > 0 then par, ptok = "(" .. Dashboard.FormatDuration(rem) .. ")", "danger"
                        else par, ptok = "(on CD)", "danger" end
                    end
                    baseVal = baseVal .. "  " .. Dashboard.Colored(par, ptok)
                end
                r.val:SetText(baseVal); r.val:SetTextColor(UI.Color(baseTok))
                r:Show()
                y = y + 22
            end
        end

        -- Cooldowns (owner task 5): the chronoboon + hearthstone cooldowns now
        -- render as the icons-only stack in the panel's top-right, and the Darkmoon
        -- fortune state moved onto its buff row (owner task 4). The section header
        -- is therefore dropped entirely for the common case; only warlocks keep a
        -- section (soul-shard count) so no EMPTY section header is ever shown.
        if rec.classTag == "WARLOCK" then
            header("Cooldowns")
            line("Soul shards: " .. (rec.shardCount or 0), "body")
        end

        -- Raids (parity item 2): a diamond pip + FULL raid name per raid, grouped
        -- with a small gap by reset cadence (weekly · 3-day · 5-day) like the
        -- reference. Each row reads green "Available" / red "Locked · Xd" and the
        -- name takes the state color too.
        header("Raids")
        local nowE = now()
        for gi, grp in ipairs(Dashboard.RAID_GROUPS) do
            if gi > 1 then y = y + 6 end   -- spacing between cadence groups
            for _, key in ipairs(grp.keys) do
                ri = ri + 1
                local r = getRaidRow(ri)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                r:SetWidth(W)
                local expiry = rec.raidLockouts and rec.raidLockouts[key]
                local locked = expiry and expiry > nowE
                local tok = locked and "danger" or "ok"
                Dashboard.SetDiamondColor(r.dot, tok)
                r.name:SetText(Dashboard.RAID_FULLNAME[key] or key)
                r.name:SetTextColor(UI.Color(tok))
                if locked then
                    r.val:SetText("Locked · " .. Dashboard.FormatDuration(expiry - nowE))
                else
                    r.val:SetText("Available")
                end
                r.val:SetTextColor(UI.Color(tok))
                r:Show()
                y = y + 18
            end
        end

        child:SetHeight(math.max(y + 8, 1))
        -- Scroll preservation (owner task 6): jump to the top only when a DIFFERENT
        -- character was just selected; when the same character is re-Shown (the ~1s
        -- ticker, or a resize relayout), keep the reader's scroll offset, clamped to
        -- the new content height.
        if sameChar then
            local maxs = math.max(0, child:GetHeight() - scroll:GetHeight())
            scroll:SetVerticalScroll(math.min(prevScroll, maxs))
        else
            scroll:SetVerticalScroll(0)
        end
        D._shownId = entry.nameRealm
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
    if opts.enableOnlineFilter then
        -- "All | Online" list filter (owner task 11 — replaces the Online tab), in
        -- the header's right slot where the hint used to sit. Default All (current
        -- online-first behavior); Online filters to currently-online characters.
        -- State persists in UI settings (additive key), and re-tints each Refresh
        -- so it tracks theme changes.
        R._onlineOnly = uiState().sixtiesOnlineOnly and true or false
        local bar = CreateFrame("Frame", nil, left)
        bar:SetPoint("TOPRIGHT", left, "TOPRIGHT", -10, -8)
        bar:SetSize(96, 16)
        local onBtn = CreateFrame("Button", nil, bar)
        local onT = onBtn:CreateFontString(nil, "OVERLAY"); onT:SetFontObject(UI.fonts.small)
        onT:SetText("Online"); onT:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
        onBtn:SetAllPoints(onT)
        local sep = fs(bar, "small"); sep:SetText("|"); sep:SetPoint("RIGHT", onT, "LEFT", -4, 0)
        local allBtn = CreateFrame("Button", nil, bar)
        local allT = allBtn:CreateFontString(nil, "OVERLAY"); allT:SetFontObject(UI.fonts.small)
        allT:SetText("All"); allT:SetPoint("RIGHT", sep, "LEFT", -4, 0)
        allBtn:SetAllPoints(allT)
        local function paint()
            sep:SetTextColor(UI.Color("faint"))
            allT:SetTextColor(UI.Color(R._onlineOnly and "muted" or "accent"))
            onT:SetTextColor(UI.Color(R._onlineOnly and "accent" or "muted"))
        end
        local function setMode(onlineOnly)
            R._onlineOnly = onlineOnly and true or false
            uiState().sixtiesOnlineOnly = R._onlineOnly
            paint(); R.Refresh()
        end
        allBtn:SetScript("OnClick", function() setMode(false) end)
        onBtn:SetScript("OnClick", function() setMode(true) end)
        R._filterPaint = paint
        paint()
    else
        local hint = fs(left, "small")
        hint:SetPoint("TOPRIGHT", left, "TOPRIGHT", -10, -10)
        hint:SetText(opts.listHint or "")
    end

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

    -- Muted list empty-state (opts.emptyText). Used by the Online tab to show
    -- "No characters online" when the filtered list is empty (owner feedback).
    local emptyLabel = fs(listChild, "muted")
    emptyLabel:SetPoint("TOPLEFT", listChild, "TOPLEFT", 4, -4)
    emptyLabel:SetText(opts.emptyText or "")
    emptyLabel:Hide()
    R._emptyLabel = emptyLabel

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
        if R._filterPaint then R._filterPaint() end   -- keep toggle tint theme-current
        local roster = opts.gather()
        if opts.enableOnlineFilter and R._onlineOnly then
            local filtered = {}
            for _, e in ipairs(roster) do if e.online then filtered[#filtered + 1] = e end end
            roster = filtered
        end
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
        -- List empty-state. With the All | Online filter (owner task 11) the
        -- message reflects the active mode.
        if R._emptyLabel then
            local emptyText = opts.emptyText or ""
            if opts.enableOnlineFilter then
                emptyText = R._onlineOnly and "No characters online" or "No characters tracked"
                R._emptyLabel:SetText(emptyText)
            end
            R._emptyLabel:SetShown(#roster == 0 and emptyText ~= "")
        end
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
            Dashboard._rosterDragging = true   -- pause the shared 1s tab repaint
            self:SetAlpha(0.5)
        end)
        card:SetScript("OnDragStop", function(self)
            self:SetAlpha(1)
            Dashboard._rosterDragging = nil
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

-- Content uses the :Hint block path (not :Label rows). :Hint's AddBlock arrange
-- explicitly sets BOTH the block width and the label width and computes wrapped
-- height, so every line renders deterministically. The prior "Tabs" section used
-- :Label rows, whose container frame width is left unset (0) — the same
-- zero-size class the framework guards for height but not for a lone label's
-- width — which is the most likely cause of that section rendering blank. It is
-- removed here per owner feedback 2b; the remaining content stays on the robust
-- :Hint path so the blank-section class can't recur.
Dashboard.RegisterTab("help", function(host)
    local pane = UI.CreatePane(host)
    local flow = pane.flow

    local s = flow:AddSection("Daseeki Nexus")
    s:Hint("Cross-account world-buff dashboard and timers for the Daseeki suite. "
        .. "Every account that shares your mesh Channel and Token sees the same roster.")

    -- ── Setup Guide (numbered, like the reference's Quick Start) ──────────────
    -- Mesh joins on a Channel + Token PAIR (both user-set, case sensitive, no
    -- auto-derivation) — the pair is the mesh password.
    local g = flow:AddSection("Setup Guide")
    g:Hint("1.  Install Daseeki Nexus on every account you want connected.")
    g:Hint("2.  On each account, open Settings \226\134\146 Mesh & Accounts and set a unique Account ID (1\226\128\1512 digits, different on each account).")
    g:Hint("3.  On the same Mesh & Accounts page, set the SAME Channel name (16+ letters/numbers, case sensitive) AND the SAME Token (6 letters/numbers) on every account \226\128\148 generate the credentials there, or paste a setup bundle to copy the same Channel and Token to another account.")
    g:Hint("4.  Enable the mesh, then log out and back in once on each account \226\128\148 characters appear across your accounts within seconds.")
    g:Hint("5.  Migrating from another world-buff addon? Run /nexus import to carry over its settings, Channel, Token and data (see Troubleshooting).")
    g:Hint("Open Settings from the button at this window's top-right, or with /nexus settings.")

    -- ── Slash commands (one per line, every user-facing subcommand) ───────────
    local c = flow:AddSection("Slash commands")
    c:Hint("Primary /nexus  \194\183  short /dnx  \194\183  aliases /dsn, /daseekinetwork")
    c:Hint("/nexus toggle \226\128\148 show or hide the dashboard")
    c:Hint("/nexus x \226\128\148 open the Cancel Buffs popup")
    c:Hint("/nexus invite \226\128\148 invite all online characters")
    c:Hint("/nexus resetui \226\128\148 reset the dashboard window position")
    c:Hint("/nexus account <id> \226\128\148 show or set this account's mesh ID")
    c:Hint("/nexus settings \226\128\148 open the Daseeki hub to Nexus settings")
    c:Hint("/nexus import \226\128\148 import ShadowNetwork settings & data ('dry' to preview)")
    c:Hint("/nexus help \226\128\148 full command list in chat")

    -- ── Minimap button (parity item 10): OUR real click matrix, one per line ──
    -- (Documents what minimap.lua actually binds — Alt+Left /camp logout is
    -- intentionally omitted this build for secure-frame safety, so it is not
    -- listed; Shift+Left is not a separate action.)
    local mm = flow:AddSection("Minimap button")
    mm:Hint("Left-click \226\128\148 invite all online characters.")
    mm:Hint("Right-click \226\128\148 open or close the dashboard.")
    mm:Hint("Ctrl + Right-click \226\128\148 open the Cancel Buffs popup.")
    mm:Hint("Shift + Right-click \226\128\148 open the dashboard on the Timers tab.")
    mm:Hint("Alt + Right-click \226\128\148 open the world map at Felwood.")
    mm:Hint("Hover \226\128\148 live Rend / Onyxia (A/H) cooldowns plus this click list.")
    mm:Hint("Drag it around the minimap ring to reposition (unless locked in Settings \226\134\146 General).")

    -- ── Troubleshooting (parity item 11): Q&A adapted to our token+channel flow
    local tr = flow:AddSection("Troubleshooting")
    tr:Hint("Other accounts not showing? The Channel AND Token must match byte-for-byte on every account \226\128\148 both are case sensitive and together act as your mesh password. Correct any mismatch in Settings \226\134\146 Mesh & Accounts, then /reload.")
    tr:Hint("Characters under the wrong account? Two accounts are sharing an Account ID. Give each account its own unique ID in Settings \226\134\146 Mesh & Accounts.")
    tr:Hint("Copying settings to a new account? Set it up with the same Channel + Token, then use Send Settings to Mesh (you confirm the target account IDs first).")
    tr:Hint("Coming from ShadowNetwork? Run /nexus import \226\128\148 it carries over your settings, Channel, Token and stored data.")

    -- ── Accounts & Tombstones (parity item 19) ────────────────────────────────
    local ac = flow:AddSection("Accounts & Tombstones")
    ac:Hint("Deleting an account is local only \226\128\148 it hides that account on THIS client and leaves a 14-day tombstone that blocks it from re-appearing.")
    ac:Hint("Remove a tombstone early and the account re-adds itself on its next heartbeat (while it is still meshing).")
    ac:Hint("Changing your Account ID migrates your data locally; other accounts keep showing your OLD ID until they delete it.")
    ac:Hint("If two accounts use the same ID you'll see an \"Account ID conflict\" warning \226\128\148 change one of them to a unique ID.")
    ac:Hint("You can't delete your OWN account \226\128\148 change your Account ID instead.")

    -- ── First-time setup (detailed) — parity item 21, at the bottom ───────────
    local ds = flow:AddSection("First-time setup (detailed)")
    ds:Hint("1.  Account ID \226\128\148 In Settings \226\134\146 Mesh & Accounts, give this account a short unique ID (1\226\128\1512 digits). Every connected account needs a DIFFERENT ID; this is how the mesh tells your accounts apart.")
    ds:Hint("2.  Channel \226\128\148 On the same Mesh & Accounts page, set a Channel name of 16+ letters and numbers. It is case sensitive and must be identical on every account \226\128\148 think of it as the room your accounts meet in.")
    ds:Hint("3.  Token \226\128\148 Set a 6-character Token (letters/numbers), also identical everywhere. Generate the credentials on the Mesh & Accounts page, or paste a setup bundle to copy the same Channel and Token to another account. The Channel + Token together are your mesh password; anyone with both can see your roster, so keep them private.")
    ds:Hint("4.  Same faction \226\128\148 The mesh rides a hidden faction chat channel, so each account must log in a character on the SAME faction to connect. Cross-faction characters simply will not mesh.")
    ds:Hint("5.  Enable + relog \226\128\148 Enable the mesh, then log out and back in once on each account. Your characters appear across accounts within seconds.")
    ds:Hint("6.  Verify \226\128\148 Open the Characters tab; you should see characters from your other accounts. Use the scope chips (All / 60s / Summoners) and the Card/Grid toggle to filter and compare, and open a character for its Notes and detail. If not, check Troubleshooting above.")

    pane:Layout()
    return { Refresh = function() pane:Layout() end }
end)

----------------------------------------------------------------------
-- Self-test: class-rule aura applicability matrix (spec §5). Verifies the
-- Slip'kik's Savvy (dmtSP) class rule drives Dashboard.AuraRequirement the same
-- way Rend does: ignored class => hidden (collapses when missing); optional =>
-- greyed/no-border yellow when missing; required => danger/red "Missing".
-- Registered as suite "dashboard" so the headless harness exercises it.
----------------------------------------------------------------------

local function testAuraClassRules(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local SP_SLOT, REND_SLOT, FAC = 8, 2, "Alliance"
    -- Ignored default (Rogue): non-applicable -> hidden / collapses when missing.
    local appl = Dashboard.AuraRequirement(SP_SLOT, { classTag = "ROGUE" }, FAC)
    ck(appl == false, "dmtSP Rogue (ignored) is non-applicable (hidden)")
    -- Optional default (Mage): applicable + optional -> amber "Missing".
    local a2, r2 = Dashboard.AuraRequirement(SP_SLOT, { classTag = "MAGE" }, FAC)
    ck(a2 == true and r2 == "optional", "dmtSP Mage (optional) is applicable+optional")
    -- Required (flip Warrior required, then restore): applicable + required (red).
    local o = ns.Store.GetFactionSettings(FAC).auraOpts.dmtSP
    local pReq, pIgn = o.required.WARRIOR, o.ignored.WARRIOR
    o.ignored.WARRIOR = nil; o.required.WARRIOR = true
    local a3, r3 = Dashboard.AuraRequirement(SP_SLOT, { classTag = "WARRIOR" }, FAC)
    ck(a3 == true and r3 == "required", "dmtSP Warrior (required) is applicable+required")
    o.required.WARRIOR = pReq; o.ignored.WARRIOR = pIgn   -- restore defaults
    -- Regression guard: Rend stays class-ruled (empty default map => hidden).
    local a4 = Dashboard.AuraRequirement(REND_SLOT, { classTag = "MAGE" }, FAC)
    ck(a4 == false, "rend default (no class in map) stays hidden")
    -- Regression guard: a non-class-ruled buff (ZG, slot 3) stays required.
    local a5, r5 = Dashboard.AuraRequirement(3, { classTag = "ROGUE" }, FAC)
    ck(a5 == true and r5 == "required", "ZG stays required-by-default (not class-ruled)")
end

-- Self-test: client-side cooldown decay (Task 2). A stored remaining value ages
-- by wall-clock elapsed since capture, floored at 0, so a remote card's chrono/
-- hearth countdown decays without a fresh update.
local function testDecayRemaining(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Dashboard.DecayRemaining(3600, 1000, 1100) == 3500, "3600 stored, 100s elapsed -> 3500")
    ck(Dashboard.DecayRemaining(3600, 1000, 4600) == 0, "exactly elapsed -> 0")
    ck(Dashboard.DecayRemaining(3600, 1000, 999999) == 0, "over-elapsed floors at 0")
    ck(Dashboard.DecayRemaining(0, 1000, 1100) == 0, "0 stored -> 0")
    ck(Dashboard.DecayRemaining(3600, 2000, 1000) == 3600, "future lastUpdate clamps elapsed to 0")
    ck(Dashboard.DecayRemaining(nil, nil, 1000) == 0, "nil stored -> 0")
end

-- Self-test: DMF calendar rule (owner task 12). The pure DMFMonthPlan drives the
-- first-Friday / opens-Monday / alternating-zone math; GetDMFSchedule (with a
-- test-seam `now`) covers mid-faire active-with-end and the month rollover.
local function testDMFSchedule(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local aug = Dashboard.DMFMonthPlan(2026, 8)
    ck(aug.firstFriday == 7, "Aug 2026 first Friday == 7 (got " .. tostring(aug.firstFriday) .. ")")
    ck(aug.opensDay == 10, "Aug 2026 opens Mon == 10 (got " .. tostring(aug.opensDay) .. ")")
    ck(aug.zone == "Mulgore", "Aug 2026 zone == Mulgore")
    local sep = Dashboard.DMFMonthPlan(2026, 9)
    ck(sep.firstFriday == 4, "Sep 2026 first Friday == 4 (got " .. tostring(sep.firstFriday) .. ")")
    ck(sep.opensDay == 7, "Sep 2026 opens Mon == 7")
    ck(sep.zone == "Elwynn Forest", "Sep 2026 zone == Elwynn Forest")
    ck(Dashboard.DMFMonthPlan(2026, 7).zone == "Elwynn Forest", "Jul 2026 (odd) zone == Elwynn Forest")

    -- Live-window cases via the test seam. Build reference epochs the same way
    -- GetDMFSchedule does so timezone handling matches.
    local _time = os.time or time
    local augOpen = _time({ year = 2026, month = 8, day = 10, hour = 0, min = 0, sec = 0 })
    local mid = Dashboard.GetDMFSchedule(augOpen + 3 * 86400)   -- Aug 13, mid-faire
    ck(mid.active == true, "mid-faire -> active")
    ck(mid.zone == "Mulgore", "mid-faire -> Mulgore")
    ck(mid.endEpoch == augOpen + DMF_DURATION, "mid-faire end == open + 7d")
    local roll = Dashboard.GetDMFSchedule(augOpen + 9 * 86400)  -- Aug 19, past Aug end
    ck(roll.active == false, "post-Aug pre-Sep -> not active")
    ck(roll.zone == "Elwynn Forest", "post-Aug rollover -> Sep Elwynn Forest")
    local before = Dashboard.GetDMFSchedule(augOpen - 2 * 86400) -- Aug 8, before this month's faire
    ck(before.active == false, "before Aug open -> not active")
    ck(before.zone == "Mulgore", "before Aug open -> shows Aug Mulgore")
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("dashboard", function(verbose)
        local cases = {
            { name = "aura class rules", fn = testAuraClassRules },
            { name = "cooldown decay", fn = testDecayRemaining },
            { name = "dmf schedule", fn = testDMFSchedule },
        }
        local allPass = true
        for _, c in ipairs(cases) do
            local fails = {}
            local ok = pcall(c.fn, fails)
            local passed = ok and #fails == 0
            if not passed then allPass = false end
            if verbose and ns and ns.Print then
                if passed then ns:Print("  PASS dashboard/" .. c.name)
                elseif not ok then ns:Print("  FAIL dashboard/" .. c.name .. " :: error in test")
                else for _, f in ipairs(fails) do ns:Print("  FAIL dashboard/" .. c.name .. " :: " .. f) end end
            end
        end
        return allPass
    end)
end
