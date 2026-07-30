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

-- Control-panel rebuild: the window is FIXED at the mockup size (1000 x 620, no
-- responsive reflow — pivot §10). The body is a single 576 region under a 44px
-- titlebar (tabs live IN the titlebar; the former tab-band + status-band are gone).
-- Round-6: grew to 1120 wide for the panel-layer layout (cards panel + detail panel +
-- the two-panel instances/timers bottom row need the extra room to stay legible).
local DEFAULT_W, DEFAULT_H = 1120, 620
local MIN_W, MIN_H = 1120, 620
local HEADER_H = 34    -- round-13: tab strip removed, so the titlebar tightens (was 44);
                       -- the reclaimed 10px goes to the body (DETAIL_H grows to match)
local TAB_H    = 34    -- retained constant (unused by the fixed layout)
local PAD      = 12

-- Guarded audit-tag helper (the geometry harness ships ns.Audit.Tag in
-- layoutaudit.lua). Tags stay no-ops when the harness/audit layer is absent.
local function tag(frame, id)
    if ns.Audit and ns.Audit.Tag and frame then ns.Audit.Tag(frame, id) end
    return frame
end
Dashboard.Tag = tag

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

-- Diamond STATUS PIP (owner round-8 item 2): the online indicator is a smooth diamond
-- with POP — a WHITE8X8 fill clipped to a diamond via the §9 mask primitive
-- (UI.MaskTexture + UI.TEX_DIAMOND), >= 8px so the shape reads, plus a larger low-alpha
-- HALO behind it that glows against the panel. Falls back to a rotated-square diamond
-- if the mask primitive is unavailable (headless / no Core). Returns (pip, halo); the
-- pip is the anchor target. Paint with Dashboard.PaintStatusPip(pip, halo, online).
local function maskOrRotate(t)
    if UI and UI.MaskTexture then UI.MaskTexture(t)   -- clip to the faceted diamond stencil
    else t:SetRotation(0.7853981633974483) end        -- fallback: rotated square (math.rad 45)
end
function Dashboard.MakeStatusPip(parent, size)
    size = size or 9
    local pip = parent:CreateTexture(nil, "OVERLAY")
    pip:SetTexture("Interface\\Buttons\\WHITE8X8"); pip:SetSize(size, size); maskOrRotate(pip)
    -- Halo lives in its OWN small child frame so it can be ANIMATED (owner round-10
    -- item 5: an outward-expanding glow). It sits over/around the pip; low alpha.
    local halo = CreateFrame("Frame", nil, parent)
    halo:SetSize(size + 5, size + 5); halo:SetPoint("CENTER", pip, "CENTER", 0, 0)
    local htex = halo:CreateTexture(nil, "ARTWORK")
    htex:SetTexture("Interface\\Buttons\\WHITE8X8"); htex:SetAllPoints(halo); maskOrRotate(htex)
    halo.tex = htex
    halo:Hide()
    -- Glow: one looping scale+alpha AnimationGroup (~2s) — the halo expands outward from
    -- the pip centre and fades, then repeats. Guarded for animation-API variance across
    -- clients (SetScaleTo/SetScale, SetToAlpha/SetChange). Engine-driven, so it is cheap
    -- and pauses automatically when the frame is hidden (offline / other tab).
    pcall(function()
        local ag = halo:CreateAnimationGroup(); ag:SetLooping("REPEAT")
        local sc = ag:CreateAnimation("Scale"); sc:SetOrigin("CENTER", 0, 0); sc:SetDuration(2)
        if sc.SetScaleTo then sc:SetScaleFrom(0.45, 0.45); sc:SetScaleTo(2.0, 2.0)
        elseif sc.SetScale then sc:SetScale(2.0, 2.0) end
        local al = ag:CreateAnimation("Alpha"); al:SetDuration(2)
        if al.SetFromAlpha then al:SetFromAlpha(1); al:SetToAlpha(0)
        elseif al.SetChange then al:SetChange(-1) end
        halo.glow = ag
    end)
    return pip, halo
end

-- Online = FULL ok-green (no muting) + a soft ANIMATED ok halo glow. Offline = a dim
-- faint diamond, no halo. `pip` is a texture; `halo` is the glow frame from MakeStatusPip.
function Dashboard.PaintStatusPip(pip, halo, online)
    if online then
        local r, g, b = UI.Color("ok")
        pip:SetVertexColor(r, g, b, 1)
        if halo then
            halo.tex:SetVertexColor(r, g, b, 0.5)
            halo:Show()
            if halo.glow and not halo.glow:IsPlaying() then halo.glow:Play() end
        end
    else
        local r, g, b = UI.Color("faint")
        pip:SetVertexColor(r, g, b, 0.8)
        if halo then
            if halo.glow then halo.glow:Stop() end
            halo:Hide()
        end
    end
end

-- ROUNDED CORNERS (round-8 item 3; REBUILT round-11 item 1 — the REAL fix). The old
-- approach covered each corner with a single behind-tinted mask, which also erased the
-- 1px border STROKE at the corner ("pixels in the very corner disappear" — owner). Now
-- each corner draws TWO own textures (authored TOP-LEFT, reused via SetTexCoord flips):
--   * COVER (round-corner.tga) tinted to the color BEHIND the frame — carves the smooth
--     rounded FILL silhouette by painting the outside-arc region with the base color.
--   * STROKE (round-stroke.tga) tinted to the BORDER token — a ~1px arc laid ALONG the
--     curve so the border stroke CONTINUES around the corner, meeting the straight
--     backdrop edges at the arc tangents. This is the piece the old mask erased.
-- Border color stays token-tinted (SetVertexColor); selected cards re-tint the stroke to
-- accent via Dashboard.SetCornerStroke. Hairlines/dividers INSIDE panels stay square.
local ROUND_CORNER_TEX = "Interface\\AddOns\\Daseeki-Nexus\\textures\\round-corner"
local ROUND_STROKE_TEX = "Interface\\AddOns\\Daseeki-Nexus\\textures\\round-stroke"
local ROUND_CORNER_SPEC = {
    -- anchor + texcoord (L,R,T,B) flips of the TOP-LEFT base texture.
    { "TOPLEFT",     0, 1, 0, 1 },
    { "TOPRIGHT",    1, 0, 0, 1 },
    { "BOTTOMLEFT",  0, 1, 1, 0 },
    { "BOTTOMRIGHT", 1, 0, 1, 0 },
}
-- `only` (optional): a set keyed by corner name ("TOPLEFT"/"TOPRIGHT"/"BOTTOMLEFT"/
-- "BOTTOMRIGHT") — render just those corners. Used to round only the OUTER corners of a
-- touching segment pair (the faction A|H chips) so their shared inner edge stays square.
function Dashboard.RoundCorners(frame, radius, behindToken, borderToken, only)
    radius = radius or 5
    behindToken = behindToken or "ground"
    borderToken = borderToken or "borderLite"
    frame._rrStroke = {}          -- stroke textures, for later re-tint (selection)
    frame._rrStrokeToken = borderToken
    for _, c in ipairs(ROUND_CORNER_SPEC) do
      if not only or only[c[1]] then
        -- COVER: behind color, carves the rounded fill silhouette.
        local cov = frame:CreateTexture(nil, "OVERLAY", nil, 6)
        cov:SetTexture(ROUND_CORNER_TEX)
        cov:SetSize(radius, radius)
        cov:SetTexCoord(c[2], c[3], c[4], c[5])
        cov:SetPoint(c[1], frame, c[1], 0, 0)
        UI.Skin(cov, function(self) self:SetVertexColor(UI.Color(behindToken)) end)
        -- STROKE: border color, continues the 1px edge around the arc (above cover).
        local st = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        st:SetTexture(ROUND_STROKE_TEX)
        st:SetSize(radius, radius)
        st:SetTexCoord(c[2], c[3], c[4], c[5])
        st:SetPoint(c[1], frame, c[1], 0, 0)
        UI.Skin(st, function(self) self:SetVertexColor(UI.Color(frame._rrStrokeToken or borderToken)) end)
        frame._rrStroke[#frame._rrStroke + 1] = st
      end
    end
    return frame
end

-- Re-tint the corner stroke (e.g. a selected card whose straight border went accent).
function Dashboard.SetCornerStroke(frame, token)
    if not (frame and frame._rrStroke) then return end
    frame._rrStrokeToken = token or "borderLite"
    for _, st in ipairs(frame._rrStroke) do st:SetVertexColor(UI.Color(frame._rrStrokeToken)) end
end

-- ── Dashboard body/card TYPE (round-11; REWIRED round-14 to Core's font picker) ──
-- Core now OWNS font selection. Its shared UI.fonts.* (body/muted/small/accent/danger/
-- header + microLabel/numeral) already resolve to the PICKED face (UI.FontFile(), default
-- the vendored "Fira Sans Condensed Medium") at the scale-adjusted size, and Core re-skins
-- them live on font AND theme change (applyFonts + fireFontChanged / fireThemeChanged). So
-- the dashboard simply CONSUMES Core's objects — the round-11 ARIALN-forced Nexus-LOCAL
-- font objects are RETIRED (they fought the picker and caused drift). numeral keeps its
-- OUTLINE telemetry intent (Core sets it); ceremonial stays MORPHEUS (brand-locked).
-- No Nexus-local font objects remain. (UI is nil under the headless harness — guarded.)
function Dashboard.Font(key)
    return (UI and UI.fonts and (UI.fonts[key] or UI.fonts.body)) or nil
end

-- A few dashboard FontStrings need the picked face at a size OFFSET from a base role
-- (bolded, +1/+2) — the card name and the filter-segment labels. Rather than mint a
-- Nexus-local FontObject, SizedFont reads the CURRENT picked face+size straight off the
-- base role's Core object (so scale is already baked in) and applies base+delta with the
-- given flags to the FontString, then re-applies on OnFontChanged / OnThemeChanged so the
-- offset tracks the picker/theme live. The FACE stays Core-owned; only size+flags are ours.
local sizedFonts = {}   -- { fs, baseKey, delta, flags }
local function applySizedFont(rec)
    local base = UI and UI.fonts and UI.fonts[rec.baseKey]
    if not (base and base.GetFont) then return end
    local face, sz = base:GetFont()
    if face and rec.fs and rec.fs.SetFont then rec.fs:SetFont(face, (sz or 12) + rec.delta, rec.flags) end
end
function Dashboard.SizedFont(fs, baseKey, delta, flags)
    if not fs then return fs end
    local rec = { fs = fs, baseKey = baseKey or "body", delta = delta or 0, flags = flags }
    sizedFonts[#sizedFonts + 1] = rec
    applySizedFont(rec)
    return fs
end
if UI then
    local function reapply() for _, r in ipairs(sizedFonts) do applySizedFont(r) end end
    if UI.OnFontChanged  then UI.OnFontChanged(reapply)  end
    if UI.OnThemeChanged then UI.OnThemeChanged(reapply) end   -- a theme may change base sizes
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

----------------------------------------------------------------------
-- Tab registry. Tab files register a builder keyed by id; the shell owns the
-- canonical order + scope so tab-bar layout is independent of load order.
----------------------------------------------------------------------

Dashboard.tabBuilders = {}   -- id -> build(host) -> tabObj (must expose :Refresh())

-- Round-13: the tab strip is gone (single-page dashboard); "characters" is the only
-- registered pane and is auto-selected. RegisterTab remains the pane-builder hook.
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

-- Compact DMF caption for the dock readout (round-12 restore #1). PURE — takes the
-- schedule table + current epoch. Upcoming: "Darkmoon: <zone> in 3d 4h (est.)"; active:
-- "Darkmoon: <zone> · up now, 2d left (est.)". FormatDuration shows the two largest units.
function Dashboard.FormatDMFCaption(sc, nowE)
    if not sc then return "Darkmoon: \226\128\148" end
    local zone = sc.zone or "?"
    local est = sc.estimated and " (est.)" or ""
    if sc.active then
        local left = math.max(0, (sc.endEpoch or nowE) - nowE)
        return ("Darkmoon: %s \194\183 up now, %s left%s"):format(zone, Dashboard.FormatDuration(left), est)
    end
    local inN = math.max(0, (sc.startEpoch or nowE) - nowE)
    return ("Darkmoon: %s in %s%s"):format(zone, Dashboard.FormatDuration(inN), est)
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
        self._label:SetFontObject(on and Dashboard.Font("body") or Dashboard.Font("muted"))
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
    -- Fixed size (ignore any saved width/height from the old resizable layout);
    -- only the saved POSITION is restored.
    win:SetSize(DEFAULT_W, DEFAULT_H)
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

----------------------------------------------------------------------
-- Pane selection (round-13: single pane — only "characters" is ever selected).
----------------------------------------------------------------------

function Dashboard.SelectTab(id)
    if not win then return end
    -- Build the pane lazily on first selection.
    if not Dashboard._tabPanes[id] then
        local host = CreateFrame("Frame", nil, win.tabHost)
        -- Characters is the edge-to-edge control panel (its panes own their insets); any
        -- future non-characters pane would keep a PAD inset so it doesn't regress.
        if id == "characters" then
            host:SetAllPoints(win.tabHost)
        else
            host:SetPoint("TOPLEFT", win.tabHost, "TOPLEFT", PAD, -PAD)
            host:SetPoint("BOTTOMRIGHT", win.tabHost, "BOTTOMRIGHT", -PAD, PAD)
        end
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

-- The 44px TITLEBAR (control-panel rebuild): logo diamond · ceremonial wordmark ·
-- tabs (Characters · Instances · Help) · faction toggle · close — one flat bar. The
-- former separate tab-band and status-band are GONE (the mockup collapses chrome to
-- a single 44px titlebar over a 576 body; the status bar's world-buff readouts moved
-- into the timers dock). The wordmark keeps a ceremonial face (pivot allowance); no
-- other serif/grain on the dashboard. This builder also creates w.tabHost (the full
-- 576 body) and the w._updateFactionToggle / _updateTabButtons / _updateTabUnderlines
-- closures that Dashboard.SelectTab + OnShow rely on.
local function buildHeader(w)
    local header = CreateFrame("Frame", nil, w)
    header:SetPoint("TOPLEFT", w, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", w, "TOPRIGHT", 0, 0)
    header:SetHeight(HEADER_H)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() w:StartMoving() end)
    header:SetScript("OnDragStop",  function() w:StopMovingOrSizing(); saveGeom() end)
    tag(header, "shell.titlebar")

    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", header, "TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -1, 0)
    UI.Skin(bg, function(self) self:SetColorTexture(UI.Color("panel")) end)

    -- Suite EMBLEM (owner round-8 item 1: the token-drawn diamond "wasn't rendering
    -- correctly"). Use the REAL suite sigil — Core's UI.MakerMark, the same faceted
    -- diamond brandmark the Daseeki hub titlebar draws (outer diamond ring + crimson
    -- MORPHEUS "D"), so Nexus shows the identical, correct emblem. Falls back to the
    -- token-drawn accent diamond only if the Core primitive is somehow absent.
    local logo
    if UI.MakerMark then
        logo = UI.MakerMark(header, { size = 18 })
    else
        logo = Dashboard.MakeDiamond(header, 14, "OVERLAY")
        Dashboard.SetDiamondColor(logo, "accent")
    end
    logo:SetPoint("LEFT", header, "LEFT", PAD, 0)

    -- Wordmark: just NEXUS (accent), in the ceremonial face — the emblem carries the
    -- suite brand now.
    local wordmark = header:CreateFontString(nil, "OVERLAY")
    wordmark:SetFontObject(UI.fonts.ceremonial or UI.fonts.header)
    wordmark:SetPoint("LEFT", logo, "RIGHT", 10, 0)
    wordmark:SetText(Dashboard.HexColor("accent") .. "NEXUS|r")

    -- Close (far right).
    local closeBtn = CreateFrame("Button", nil, header)
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -8, 0)
    local cx = closeBtn:CreateFontString(nil, "OVERLAY")
    cx:SetFontObject(Dashboard.Font("body"))
    cx:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
    cx:SetText("X")
    closeBtn:SetScript("OnEnter", function() cx:SetFontObject(Dashboard.Font("danger")) end)
    closeBtn:SetScript("OnLeave", function() cx:SetFontObject(Dashboard.Font("body")) end)
    closeBtn:SetScript("OnClick", function() w:Hide() end)

    -- Round-6 (item B): the faction toggle MOVED OFF the titlebar into the chip bar
    -- (it filters characters, so it lives with the filters — see ui_cards). The
    -- titlebar right cluster is now just Settings · ✕. A no-op _updateFactionToggle is
    -- kept so OnShow (which calls it) stays safe; the chip-bar segment repaints on
    -- Dashboard.RefreshActive instead.
    w._updateFactionToggle = function() end

    -- Settings launcher (right-cluster text button, left of ✕). Opens the Core hub to
    -- the Nexus section. (Settings is an action, not a pane — a text button, not a tab.)
    local settingsBtn = CreateFrame("Button", nil, header)
    settingsBtn:SetHeight(HEADER_H)
    local sLbl = settingsBtn:CreateFontString(nil, "OVERLAY")
    sLbl:SetFontObject(Dashboard.Font("body"))
    sLbl:SetPoint("CENTER", settingsBtn, "CENTER", 0, 0)
    sLbl:SetText("Settings")
    settingsBtn:SetWidth((sLbl:GetStringWidth() or 52) + 16)
    settingsBtn:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
    settingsBtn:SetScript("OnEnter", function() sLbl:SetFontObject(Dashboard.Font("accent")) end)
    settingsBtn:SetScript("OnLeave", function() sLbl:SetFontObject(Dashboard.Font("body")) end)
    settingsBtn:SetScript("OnClick", function()
        if DaseekiSuite and DaseekiSuite.Open then DaseekiSuite:Open("nexus")
        else ns:Print("the Daseeki hub (Daseeki Core) is not available.") end
    end)
    w.settingsBtn = settingsBtn

    -- Round-13 (owner: single-page control panel): the Characters/Help TAB STRIP is
    -- REMOVED. The dashboard IS the Characters page and Help moved into the Settings hub
    -- (Settings -> Nexus -> Help), so the titlebar is just [emblem] NEXUS ... Settings ✕.
    -- The two tab-update hooks stay as no-ops (OnShow / SelectTab / SetFaction call them).
    w._updateTabUnderlines = function() end
    w._updateTabButtons    = function() end

    -- Titlebar bottom rule (1px) — the seam between the titlebar and the body.
    -- Pop pass (round-4): borderLite so the seam reads like the reference's edges.
    local rule = w:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", w, "TOPLEFT", 1, -HEADER_H)
    rule:SetPoint("TOPRIGHT", w, "TOPRIGHT", -1, -HEADER_H)
    UI.Skin(rule, function(self) self:SetColorTexture(UI.Color("borderLite")) end)

    -- Content host = the full 576 body (edge-to-edge; panes own their own insets).
    local host = CreateFrame("Frame", nil, w)
    host:SetPoint("TOPLEFT", w, "TOPLEFT", 0, -HEADER_H)
    host:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", 0, 0)
    w.tabHost = host

    w.header = header
    w._updateFactionToggle()
    w._updateTabUnderlines()
    return header
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
    win:SetResizable(false)   -- fixed-proportion mockup (pivot §10: no reflow)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    if win.SetResizeBounds then win:SetResizeBounds(MIN_W, MIN_H, DEFAULT_W, DEFAULT_H) end
    win:Hide()
    UI.Skin(win, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("ground"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)

    tinsert(UISpecialFrames, "DaseekiNexusDashboard")   -- Escape closes

    -- Titlebar (logo · wordmark · tabs · faction · close) + the full-body tab host.
    -- The former separate tab-band + status-band are retired: tabs live in the 44px
    -- titlebar and the world-buff readouts + DMF estimate live in the timers dock
    -- (ui_timersdock.lua). The old status-bar subsystem (buildStatusBar, guild-online
    -- count, the Nexus/NWB request pair, RefreshStatusBar/ticker) was removed in round-12.
    buildHeader(win)

    -- Fixed window: no resize grip (pivot §10 — the mockup is fixed-proportion).
    win:SetScript("OnShow", function()
        win._updateFactionToggle()
        win._updateTabUnderlines()
        Dashboard.RefreshActive()
    end)

    restoreGeom()

    -- Round-13: single-page dashboard — Characters is the only pane (Help moved to the
    -- Settings hub). Always select it.
    Dashboard.SelectTab("characters")

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

    -- Round-12 restore #1: the dock caption formatter (pure).
    local upcoming = { zone = "Mulgore", active = false, startEpoch = 100000, endEpoch = 100000 + DMF_DURATION, estimated = true }
    ck(Dashboard.FormatDMFCaption(upcoming, 100000 - 2 * 86400) == "Darkmoon: Mulgore in 2d (est.)",
        "DMF caption: upcoming shows 'in Nd' + (est.)")
    local live = { zone = "Elwynn Forest", active = true, startEpoch = 100000, endEpoch = 100000 + DMF_DURATION, estimated = true }
    local liveTxt = Dashboard.FormatDMFCaption(live, 100000 + 2 * 86400)
    ck(liveTxt:find("up now", 1, true) ~= nil and liveTxt:find("Elwynn Forest", 1, true) ~= nil,
        "DMF caption: active shows 'up now' + zone")
    ck(Dashboard.FormatDMFCaption(nil, 0) == "Darkmoon: \226\128\148", "DMF caption: nil schedule -> em-dash")
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
