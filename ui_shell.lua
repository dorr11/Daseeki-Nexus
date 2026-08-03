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
-- ROUND-19: height 620 -> 643 (+23). The detail pane had to grow to seat RAID LOCKOUTS
-- bottom-left AND repay round-17's 1px buff-row gap, but measurement showed the bottom row
-- has ZERO px to give: the timers dock's fixed stack floors at 265 and BOTTOM_H is already
-- 268 (3px of air above its footer), and BOTTOM_H governs the instances panel too. Growing
-- the window is the only funding source that squeezes nothing — the dock, the instances
-- panel and every other metric are untouched. The window is fixed-size (not resizable), so
-- this is purely more pixels of content. ROUND-20 grows it again, 643 -> 661 (+18), to
-- STACK the raid-lockout block (eyebrow on its own line above the keys) — same funding
-- rule, same reason: the dock is still at its floor, so BOTTOM_H cannot pay. Arithmetic:
--     body = 648 - HEADER_H 34 = 614 = DETAIL_H 320 + GUTTER 10 + BOTTOM_H 268 + 2*MARGIN 16
local DEFAULT_W, DEFAULT_H = 1120, 648
local MIN_W, MIN_H = 1120, 648
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
-- A1.1: the recency window is 15s, not 150s (spec §2.1 rule 3). At 150s a
-- sibling you logged out of stayed green for two and a half minutes, which is
-- the owner's original complaint — the exclusivity fix only REDUCED it, because
-- the elected winner is still "online" for the whole window after it goes
-- quiet. 15s is safe precisely because live mesh presence (below) is now the
-- primary source and recency is only the fallback.
local ONLINE_WINDOW = 15

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
-- key (the seasonal Fire Festival Fury tail slot) are always optional.
--
-- ⚠ DRIFT IS A DISPLAY BUG. The tracker moved slots 9/10 off the retired
-- Traces of Silithyst / Boon of Blackfathom and onto Battle Shout (25101) and
-- Fire Festival Fury (29338/29846) — this table did not follow, so a warrior's
-- Battle Shout painted as "Traces of Silithyst" on every card, tile and
-- tooltip. The slot map is now cross-checked against the tracker's own
-- matchers by the "aura slot map agreement" self-test below, which fails loudly
-- the next time either side moves alone.
--
-- ICON SOURCE OF TRUTH (owner feedback #1 — "buff icons arent correct"): icons
-- are NOT hardcoded Interface\Icons guesses any more. Each slot carries the
-- REAL game `spellID`, and the icon is derived at runtime via
-- Dashboard.AuraIcon(slot) → C_Spell.GetSpellTexture(spellID) (question-mark
-- fallback). This is the single source shared by ui_shell (detail), the cards
-- and the timers dock.
--
-- CROSS-FILE CONTRACT: `thresholdKey` is the aura VOCABULARY of this addon —
-- the exact, case-sensitive keys shared by Store.AURA_THRESHOLD_SEEDS,
-- Store.CLASS_RULE_SEEDS / Store.AURA_RULE_KEYS, options.lua's
-- CLASS_RULE_GRIDS[].optKey, Dashboard.BUFF_TIME_RULE and the importer's
-- AURA_SLOT_KEY: dmf, ony, dmtAP, dmtSP, dmtStam, songflower, zg, rend,
-- battleShout. Every one of those is a raw table index, so a single flipped
-- letter is silent.
--
-- (Historical note: these used to be the keys the hub's editable duration
-- thresholds were stored under. The settings rework retired that table —
-- buff-time colour is the fixed Dashboard.BUFF_TIME_RULE now — but the KEY
-- NAMES stayed, because they are the vocabulary, not the feature.)
--
-- The two tail slots carry the IDs the TRACKER matches on (25101 / 29338), not
-- the player-cast Battle Shout art id — the icon must belong to the buff that
-- actually landed in the slot.
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
    [9]  = { key = "battleshout",name = "Battle Shout",                    short = "BS",   thresholdKey = "battleShout",spellID = 25101,  iconSpellID = 6673  },
    [10] = { key = "fff",       name = "Fire Festival Fury",               short = "FFF",  thresholdKey = nil,          spellID = 29338,  iconSpellID = 29846 },
}

-- `iconSpellID` is ART ONLY, never identity: the two tail slots key on the ID the
-- TRACKER matches (25101 NPC Battle Shout / 29338 FFF), and those are the IDs the
-- drift self-test pins. But an ID the client cannot resolve renders a question
-- mark, and 25101 is an NPC-cast spell — so each tail slot names a second, always-
-- loadable spell with the SAME artwork (6673 = the player Battle Shout the options
-- page already draws; 29846 = FFF's alternate id) for AuraIcon to fall back to
-- before it gives up. Identity stays with `spellID`; only the texture may come
-- from `iconSpellID`.

-- Explicit unknown marker (Blizzard built-in) — NOT a guess at any buff's art,
-- just the graceful fallback when a spell/item icon cannot be resolved.
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Resolve a tracked-aura slot's icon from its real spellID. Catalog-verified
-- (build 1.15.9): C_Spell.GetSpellTexture(spellID) -> iconID, with the legacy
-- global GetSpellTexture as a fallback. Successful lookups are cached; a nil
-- (spell not loaded / not in this client) is NOT cached so a later refresh
-- retries, and renders the question mark until then.
--
-- Two IDs are tried in order: the slot's identity `spellID` first, then the
-- art-only `iconSpellID` for the tail slots whose identity id is an NPC cast the
-- client may not hand us a texture for (see the note on AURA_META).
-- Exposed ONLY so the self-test can evict what it faked: running /nexus selftest
-- in-game must not leave a stub texture cached on a live slot.
local _auraIconCache = {}
Dashboard._auraIconCache = _auraIconCache
local function spellTexture(id)
    if not id then return nil end
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    if GetSpellTexture then return GetSpellTexture(id) end
    return nil
end
function Dashboard.AuraIcon(slot)
    local meta = Dashboard.AURA_META[slot]
    if not meta then return QUESTION_ICON end
    local cached = _auraIconCache[slot]
    if cached then return cached end
    local tex = spellTexture(meta.spellID) or spellTexture(meta.iconSpellID)
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
-- ZG, DMT-AP, DMT-SP, DMT-STAM, Songflower, Rend, then the two tail slots.
-- Values are slot indices into AURA_META / auraStates.
--
-- The tail is still the right home for the new 9/10: Battle Shout is a 13-minute
-- buff (vs the hours-long world buffs ahead of it) and only two classes are even
-- ruled to want it, and FFF is seasonal — both belong AFTER the long-lived set
-- the owner reads first, exactly where the retired tail slots sat. Rend keeps
-- the last "real" world-buff position immediately before them.
Dashboard.AURA_DISPLAY_ORDER = { 5, 1, 3, 6, 8, 7, 4, 2, 9, 10 }

-- Default thresholds (seconds) when the hub has not been configured yet, so the
-- card colors are meaningful out of the box. normal = below this is "warn";
-- minimum = below this is "low/critical".
local DEFAULT_THRESHOLD = { normal = 20 * 60, minimum = 5 * 60 }

----------------------------------------------------------------------
-- Raid lockout display list (spec §1 dot row).
----------------------------------------------------------------------

-- ROUND-22 addendum: realigned to the OWNER-CANON order that ui_detail's TALLY_ORDER now
-- uses ("MC BWL AQ40 NAXX | ONY ZG AQ20" — weekly-reset raids, then short-cycle), so the
-- two constants finally agree instead of quietly diverging.
-- NOTE: as of this round BOTH RAID_DISPLAY and RAID_GROUPS below have ZERO consumers —
-- nothing in the addon reads either one (the detail tally uses its own TALLY_ORDER, and
-- the card pip row was retired). They are kept as exported vocabulary rather than deleted
-- because they are public Dashboard fields a sibling could be mid-way through adopting;
-- flagged for the coordinator to decide between adopting or deleting them.
Dashboard.RAID_DISPLAY = { "MC", "BWL", "AQ40", "Naxx", "Ony", "ZG", "AQ20" }

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
-- THEME-LESS FALLBACK: the pure display layer (Detail.TallyText et al.) is documented
-- as headless-testable, and _test_detail.lua exercises it with DaseekiUI ABSENT on
-- purpose — that's the frameless/deferred-render contract. So HexColor must not hard-
-- require the live theme: with no UI (or no UI.Color) it emits white. In-game DaseekiUI
-- is a hard dependency, so the branch never triggers there; it exists so the pure
-- helpers stay callable without a theme.
function Dashboard.HexColor(token)
    local r, g, b
    if UI and type(UI.Color) == "function" then
        r, g, b = UI.Color(token)
    else
        r, g, b = 1, 1, 1
    end
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

-- Class color (r,g,b).
--
-- SETTINGS-REWORK ITEM 1: the per-class hex override is GONE. The "Colors"
-- settings section is removed, the stored `db.classColors` table is parked and
-- cleared by Store.RetireClassColors, and this path now reads the shipped
-- palette UNCONDITIONALLY. It deliberately no longer consults SavedVariables at
-- all — a leftover override in a hand-edited or rolled-back file must not be
-- able to re-colour the roster behind the owner's back, and reading the palette
-- makes this function pure and headless-testable.
--
-- Order: our own palette (Store.DEFAULT_CLASS_COLORS), then Blizzard's
-- RAID_CLASS_COLORS for anything the palette does not name, then the theme's
-- text colour.
function Dashboard.ClassColor(classTag)
    local palette = ns.Store and ns.Store.DEFAULT_CLASS_COLORS
    local hex = classTag and type(palette) == "table" and palette[classTag]
    if type(hex) == "string" and #hex >= 6 then
        local r = tonumber(hex:sub(1, 2), 16)
        local g = tonumber(hex:sub(3, 4), 16)
        local b = tonumber(hex:sub(5, 6), 16)
        if r and g and b then return r / 255, g / 255, b / 255 end
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

----------------------------------------------------------------------
-- A9.1 — DISPLAYED item-cooldown remaining. THE single choke point.
--
-- Every reader of the hearthstone / chronoboon cooldowns (card icons, detail
-- rows) comes through here so they can never disagree. The record now carries a
-- START EPOCH per cooldown and the remaining is always DERIVED, which is what
-- makes a mid-cooldown relog show a countdown that simply continues instead of
-- freezing at whatever the last capture happened to read.
--
-- `which` is "hearthstone" or "chronoboon". Delegates to Store.ItemCdRemaining
-- (pure, harness-tested there), including its legacy fallback for records that
-- predate the epoch fields. Returns 0 when the store layer is absent.
--
-- NOTE this deliberately does NOT go through Dashboard.DecayRemaining: that
-- helper decays a stored remaining against rec.lastDataUpdate, which is exactly
-- the model A9.1 replaces. It stays for the aura path (§4.5), which really does
-- store a captured remaining.
function Dashboard.ItemCdRemaining(rec, which, nowE)
    if ns.Store and ns.Store.ItemCdRemaining then
        return ns.Store.ItemCdRemaining(rec, which, nowE or Dashboard.Now()) or 0
    end
    return 0
end

-- DMF cooldown remaining (owner task 4 — the "DMFable" tracker, folded onto the
-- DMF buff row). A8 landed the real model in store.lua: a 14,400 s ONLINE-TIME
-- cooldown carried on rec.dmfCooldown.remainingOnlineSecs, ticked down by the
-- tracker and frozen while the fortune is stashed in a chronoboon. This is now a
-- thin delegation; the old local 8h mirror is gone, and with it the bug where an
-- ONLINE character always read 0 remaining (offlineSince is 0 while online) and
-- so rendered READY the instant after taking a fortune (A8.2).
--
-- Contract kept exactly as the UI expects:
--   not on cooldown       -> 0   (callers render "READY")
--   on cooldown, rem > 0  -> the remaining seconds
--   on cooldown, rem == 0 -> 0   (callers render "on CD"; this is the remote /
--                                 legacy case, where the real remaining is not
--                                 something we can know — see the tri-state note
--                                 on Store.DMFCooldownRemaining)
local function dmfCooldownRemaining(rec, nowE)
    if ns.Store and ns.Store.DMFCooldownRemaining then
        return ns.Store.DMFCooldownRemaining(rec, nowE) or 0
    end
    return 0
end

----------------------------------------------------------------------
-- A6.8 — DISPLAYED aura remaining. THE single choke point.
--
-- Every aura duration in the record is the seconds left AT THE MOMENT IT WAS
-- CAPTURED (rec.lastDataUpdate). We used to render that number raw, everywhere,
-- for every character — so a buff on a live alt sat frozen on your other
-- account's screen at whatever it read when the last update arrived, and an
-- "Ony 1h 20m" could still be showing 1h 20m twenty minutes later.
--
-- The rule, in one place so cards, detail tiles and the missing-buff counts can
-- never disagree:
--   * BOONED slot        -> FROZEN, always. A suspended buff does not tick, on
--                           anyone's screen, online or not. This is A7.6: it used
--                           to be right by accident (nothing decayed at all), and
--                           is now an explicit, tested exception.
--   * ONLINE character   -> stored - (now - lastDataUpdate), floored at 0. The
--                           record is being refreshed, so the elapsed time since
--                           the last refresh is real time off the buff.
--   * OFFLINE character  -> FROZEN at its last known value (unchanged: nothing is
--                           updating the record, and decaying it would invent an
--                           expiry the character may never have reached).
--
-- `online` may be passed by a caller that already computed it (the card gather
-- stamps entry.online); otherwise it is resolved through Dashboard.IsOnline.
-- Returns (remaining, cell) so callers can still read source/option.
function Dashboard.AuraRemaining(rec, slot, nowE, online)
    local st = rec and rec.auraStates and rec.auraStates[slot]
    if type(st) ~= "table" then return 0, nil end
    local stored = tonumber(st.duration) or 0
    if stored <= 0 then return 0, st end

    local BOON = (ns.Store and ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
    if st.source == BOON or st.source == "boon" then
        return math.floor(stored), st          -- A7.6: never decays
    end

    if online == nil then online = Dashboard.IsOnline(rec, rec.nameRealm) end
    if not online then return math.floor(stored), st end   -- offline: frozen

    return Dashboard.DecayRemaining(stored, rec.lastDataUpdate, nowE), st
end

-- "Updated 3m ago" style freshness string from an epoch.
function Dashboard.FreshnessText(epoch)
    if not epoch or epoch <= 0 then return "no data" end
    local d = now() - epoch
    if d < 0 then d = 0 end
    if d < 60 then return "Updated just now" end
    return "Updated " .. Dashboard.FormatDuration(d) .. " ago"
end

----------------------------------------------------------------------
-- Same-account online exclusivity
--
-- A WoW ACCOUNT can only ever have ONE character logged in at a time, but the
-- records carry no live-online flag — `lastSeen` recency is all we have, and a
-- character you just logged OUT of stays "fresh" for the whole ONLINE_WINDOW.
-- So the roster used to paint a green pip on BOTH the character you left and
-- the one you just entered (owner bug: Daseeki -> Shalk, both on account #1).
--
-- A1.2 (this pass): the records still carry no live-online flag, but the MESH
-- does — Mesh.peers[aid].online plus the peer's current character name. That is
-- first-hand evidence refreshed by every inbound message on any mesh prefix,
-- and (since A1.3) expired after 30s of silence. It is now the PRIMARY online
-- source for a remote account; lastSeen recency is the fallback for accounts the
-- mesh has nothing to say about. Exclusivity itself is unchanged.
--
-- Rule: at most ONE character per account id may read online.
--   * LOCAL account  -> the character we are logged in as wins outright; every
--     local sibling is offline no matter how fresh its lastSeen looks.
--   * REMOTE account -> the character the MESH says is live for that account
--     wins, if we hold a record for it. Otherwise the sibling with the newest
--     lastSeen wins, and only if that lastSeen is itself inside ONLINE_WINDOW
--     (else nobody on it is on).
--   * ORPHAN bucket (aid == "", and not ours) is EXEMPT: it is a grab-bag of
--     synced-but-unattributed characters from potentially MANY accounts, so
--     "one per account" is not a claim we can make there. Recency still rules.
--
-- Exclusivity is strictly PER-AID — two characters on two DIFFERENT accounts
-- are both legitimately online (the owner runs four accounts).
--
-- Computed ONCE per roster refresh over ALL stored records, never over the
-- faction/level-filtered subset: the sibling that wins an account is very often
-- filtered out of the view you are looking at (a Horde main vs the Alliance alt
-- you just logged into), and computing over the subset would let each faction
-- roster elect its own "winner" and reproduce the bug.
----------------------------------------------------------------------

-- Short (realm-stripped) name of the character we are logged in as, or nil.
local function selfShortName()
    local n = UnitName and UnitName("player")
    if n and n ~= "" then return n end
    return nil
end
Dashboard.SelfShortName = selfShortName

local function shortOf(nameRealm)
    return nameRealm:match("^([^%-]+)") or nameRealm
end

-- PURE: snapshot live mesh presence as { [accountID] = nameRealm } for every
-- peer the mesh currently believes is online AND for which it knows the current
-- character name. Kept separate from ComputeOnlineWinners so the winners pass
-- stays a pure function of its arguments.
function Dashboard.MeshPresence()
    local out = {}
    local Mesh = ns.Mesh
    local peers = Mesh and Mesh.peers
    if not peers then return out end
    for aid, p in pairs(peers) do
        if type(p) == "table" and p.online and p.name and p.name ~= "" then
            out[aid] = p.name
        end
    end
    return out
end

-- PURE exclusivity pass. `records` is an array of
--   { nameRealm = , aid = , rec = , selfAcct = bool }
-- `selfName` is the short name of the logged-in character (nil when unknown).
-- `meshOnline` is the optional { [aid] = nameRealm } live-presence snapshot;
-- when it names a character we actually hold a record for, that character wins
-- its account outright (A1.2) — no recency test, because live mesh presence is
-- stronger evidence than any stored epoch.
-- Returns
--   { winner  = { [aid] = nameRealm | false },   -- false = nobody online here
--     charAID = { [nameRealm] = aid | false } }  -- false = name spans >1 aid
-- An aid absent from `winner` is exempt (no exclusivity claim).
function Dashboard.ComputeOnlineWinners(records, nowE, selfName, meshOnline)
    local groups, charAID = {}, {}
    for _, r in ipairs(records or {}) do
        local aid = r.aid or ""
        -- The orphan bucket only earns a claim when it is OUR bucket (which it
        -- is when no account id has been chosen yet — see Store.GetSelfAccount).
        if aid ~= "" or r.selfAcct then
            local g = groups[aid]
            if not g then g = { selfAcct = false }; groups[aid] = g end
            if r.selfAcct then g.selfAcct = true end
            g[#g + 1] = r
            local seen = charAID[r.nameRealm]
            if seen == nil then charAID[r.nameRealm] = aid
            elseif seen ~= aid then charAID[r.nameRealm] = false end
        end
    end

    local winner = {}
    for aid, g in pairs(groups) do
        local pick
        if g.selfAcct and selfName then
            for _, r in ipairs(g) do
                if shortOf(r.nameRealm) == selfName then pick = r.nameRealm; break end
            end
        end
        -- A1.2: live mesh presence beats stored recency for a REMOTE account.
        -- Never for our own account — the character we are standing in always
        -- wins there, and the mesh never carries our own AID as a peer anyway.
        if not pick and not g.selfAcct then
            local live = meshOnline and meshOnline[aid]
            if live then
                for _, r in ipairs(g) do
                    if r.nameRealm == live then pick = live; break end
                end
            end
        end
        if not pick then
            -- Remote account (or a bucket flagged self that we are not actually
            -- standing in — a stale isSelf after an account-id change): newest
            -- lastSeen wins, and only while it is inside the window.
            local best, bestSeen
            for _, r in ipairs(g) do
                local ls = (r.rec and r.rec.lastSeen) or 0
                if not bestSeen or ls > bestSeen
                   or (ls == bestSeen and r.nameRealm < best) then
                    best, bestSeen = r.nameRealm, ls
                end
            end
            if best and (nowE - bestSeen) <= ONLINE_WINDOW then pick = best end
        end
        winner[aid] = pick or false
    end
    return { winner = winner, charAID = charAID }
end

-- Rebuild the exclusivity table from the WHOLE store. Cheap (a few dozen
-- records) and idempotent; run at the top of every roster gather.
function Dashboard.RefreshOnlineWinners()
    local records = {}
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    local accounts = data and data.accounts
    if accounts then
        local selfAID = (ns.GetAccountID and ns:GetAccountID()) or ""
        for aid, bucket in pairs(accounts) do
            local selfAcct = (bucket.isSelf == true)
                             or (selfAID ~= "" and aid == selfAID)
            local function add(nameRealm, rec)
                records[#records + 1] = {
                    nameRealm = nameRealm, aid = aid, rec = rec, selfAcct = selfAcct,
                }
            end
            for nameRealm, rec in pairs(bucket.characters or {}) do add(nameRealm, rec) end
            for nameRealm, rec in pairs(bucket.homeless or {}) do add(nameRealm, rec) end
        end
    end
    Dashboard._onlineWinners = Dashboard.ComputeOnlineWinners(
        records, now(), selfShortName(), Dashboard.MeshPresence())
    return Dashboard._onlineWinners
end

-- Online test. Recency gates who is a CANDIDATE; the per-account exclusivity
-- table decides which single candidate actually wins. `aid` is optional — pass
-- it when the caller already knows the account (it disambiguates a Name-Realm
-- that exists under more than one account); otherwise it is looked up.
function Dashboard.IsOnline(rec, nameRealm, aid)
    if not rec then return false end
    local w = Dashboard._onlineWinners
    if not w then w = Dashboard.RefreshOnlineWinners() end
    if w and nameRealm then
        local own = aid
        if own == nil then own = w.charAID[nameRealm] end
        -- `own == false` means the same Name-Realm sits under several accounts
        -- and cannot be attributed; fall through to plain recency for it.
        if own then
            local win = w.winner[own]
            if win ~= nil then return win == nameRealm end
        end
    end
    -- Exempt / unattributable character (orphan bucket, or a Name-Realm that
    -- sits under more than one account). Self always wins; then live mesh
    -- presence (A1.2); then the 15s recency heuristic (A1.1).
    local selfName = selfShortName()
    if selfName and nameRealm and shortOf(nameRealm) == selfName then return true end
    if nameRealm then
        local live = Dashboard.MeshPresence()
        for _, name in pairs(live) do
            if name == nameRealm then return true end
        end
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
--
-- SETTINGS-REWORK ITEM 4: this is now the FALLBACK path only — it serves the
-- buffs that carry no full-duration class (see BUFF_TIME_RULE below), which is
-- exactly the seasonal tail slot. Every tracked world buff goes through
-- Dashboard.BuffTimeToken instead.
function Dashboard.AuraColorToken(remaining, threshold)
    threshold = threshold or DEFAULT_THRESHOLD
    if remaining >= (threshold.normal or 0) then return "ok" end
    if remaining >= (threshold.minimum or 0) then return warnToken() end
    return "danger"
end

----------------------------------------------------------------------
-- SETTINGS-REWORK ITEM 4 — FIXED buff-time colouring.
--
-- The nine editable normal/minimum threshold pairs are retired. Buff-time
-- colour is now a backend rule derived from each buff's FULL DURATION, stated
-- once here and not configurable:
--
--     full 2h  ->  remaining < 90 min  = yellow, else green
--     full 1h  ->  remaining < 55 min  = yellow, else green
--     Battle Shout (15 min NPC cast, spell 25101)
--              ->  remaining < 12 min  = yellow, else green
--
-- Note what is NOT here: red. A buff that is PRESENT is green or yellow; red is
-- reserved for MISSING (Dashboard.AuraRequirement), so the card's red now means
-- exactly one thing. The old three-band scheme spent red on "present but old",
-- which is the state the owner reads as "still fine, top it up soon".
--
-- FULL DURATIONS are the game facts already encoded in this addon, restated in
-- one table rather than inferred from the retired seeds:
--   * 2h — Rallying Cry of the Dragonslayer (Ony), Spirit of Zandalar (ZG),
--     Sayge's Dark Fortune (DMF) and the three Dire Maul tribute buffs
--     (Fengus AP / Slip'kik SP / Mol'dar Stam). tracker.lua's
--     SYNTH_DURATION_OTHER = 7200 is the same fact from the capture side.
--   * 1h — Warchief's Blessing (Rend; tracker's SYNTH_DURATION_REND = 3600)
--     and Songflower Serenade (its retired 58/57 seed pair is a 1h buff's).
--   * Battle Shout is the 15-minute NPC ("Fallen Hero") cast, spell 25101 —
--     AURA_META[9].spellID, tracker BUFF_SPELL_IDS[25101] = 9. NOT the 2-minute
--     player self-cast, which tracker's BS_SELFCAST_MAX filter rejects, and NOT
--     boonable (tracker BOONABLE_SLOT stops at slot 8).
--
-- Keys are thresholdKeys (AURA_META[slot].thresholdKey), so this table is
-- indexed by the same byte strings as everything else in the aura vocabulary.
-- A key that is absent here has no full-duration class and keeps the old
-- green/amber/red behaviour through AuraColorToken — today that is only the
-- seasonal tail slot, which carries thresholdKey = nil.
----------------------------------------------------------------------

local HOUR = 3600
Dashboard.BUFF_FULL_2H = 2 * HOUR
Dashboard.BUFF_FULL_1H = HOUR
Dashboard.BUFF_FULL_BS = 15 * 60

-- full = the buff's full duration (seconds); warnBelow = strictly-below cutoff.
Dashboard.BUFF_TIME_RULE = {
    ony         = { full = 7200, warnBelow = 90 * 60 },
    zg          = { full = 7200, warnBelow = 90 * 60 },
    dmf         = { full = 7200, warnBelow = 90 * 60 },
    dmtAP       = { full = 7200, warnBelow = 90 * 60 },
    dmtSP       = { full = 7200, warnBelow = 90 * 60 },
    dmtStam     = { full = 7200, warnBelow = 90 * 60 },
    rend        = { full = 3600, warnBelow = 55 * 60 },
    songflower  = { full = 3600, warnBelow = 55 * 60 },
    battleShout = { full =  900, warnBelow = 12 * 60 },
}

-- Colour token for a PRESENT buff under the fixed rule. Returns nil when the
-- key has no full-duration class, so the caller can fall back to the legacy
-- threshold path instead of silently painting everything green.
function Dashboard.BuffTimeToken(thresholdKey, remaining)
    local rule = thresholdKey and Dashboard.BUFF_TIME_RULE[thresholdKey]
    if not rule then return nil end
    if (tonumber(remaining) or 0) < rule.warnBelow then return warnToken() end
    return "ok"
end

----------------------------------------------------------------------
-- Aura applicability / requirement (owner feedback #3 — "missing buffs arent
-- displayed"). Shared by the 60s card strip and the detail panel so both agree
-- on what a MISSING slot should look like.
--
-- Rules (spec §1):
--   * Rend (slot 2), Fengus' Ferocity / DMT AP (slot 6), Slip'kik's Savvy /
--     DMT SP (slot 8) and Battle Shout (slot 9) are governed by per-class rule
--     maps GetFactionSettings().auraOpts.{rend,dmtAP,dmtSP,battleShout}
--     {required|optional|ignored}[class] (see CLASS_RULED_KEYS). Ignored
--     classes are non-applicable (hidden); optional = greyed-no-border when
--     missing; required = danger border / red "Missing". Slip'kik defaults
--     physical classes (War/Rogue/Hunter) to ignored, casters to optional;
--     Fengus is its mirror (six weapon classes required, Mage/Priest/Warlock
--     ignored); Battle Shout ships Warrior/Rogue required and every other
--     class ignored.
--   * Every other threshold-bearing world buff (Ony/ZG/Songflower/DMF/
--     DMT Stam) is required-by-default: applicable + "required" for everyone.
--   * The tail slot without a threshold key (the seasonal Fire Festival Fury)
--     is OPTIONAL and treated as non-applicable when ABSENT, so it collapses
--     out of the strip/detail instead of littering every card with a grey
--     seasonal icon (spec §1 "seasonal-absent hidden"; style-guide prime
--     directive "clean and compact"). When PRESENT it still renders normally.
--     ⚠ Deviation from a literal "all others required-by-default": the tail
--     slot stays optional/collapsing — flagged for cheap owner override.
----------------------------------------------------------------------

-- Threshold keys whose applicability is governed by a per-class
-- required/optional/ignored map in auraOpts (keyed identically to the
-- thresholdKey). Rend was the first; Slip'kik's Savvy (dmtSP) joins it so
-- physical classes hide it by default while casters see it as optional.
--
-- battleShout is the THIRD, and it is not optional bookkeeping: the moment
-- slot 9 became Battle Shout it gained a thresholdKey, and a threshold-bearing
-- slot is required-by-default for EVERY class. Without this entry a mage,
-- priest, druid — every non-shout-carrier — would sprout a permanent red
-- "Missing Battle Shout" tile. Listing it here hands the slot to the B12 seeds
-- (Store.CLASS_RULE_SEEDS: Warrior/Rogue required, everyone else ignored), so
-- warriors and rogues see a real requirement and nobody else sees anything.
--
-- CASE IS LOAD-BEARING. These are the same byte strings as
-- AURA_META[slot].thresholdKey and as the `optKey` the options page writes
-- (options.lua CLASS_RULE_GRIDS) — "dmtSP", not the slot's lowercase
-- AURA_META.key "dmtsp". The lookup below is a raw table index, so a single
-- flipped letter on either side is silent: the owner's click writes a map, the
-- display reads a different one, and the rule can never fire. Exported so the
-- "options" suite can assert the write-key set and this read-key set are
-- identical strings in BOTH directions.
--
-- dmtAP (Fengus' Ferocity, slot 6) is the FOURTH, added round-24 on owner
-- report: "magic damage dealers wouldn't want it, so it showing as missing on
-- mage is incorrect." Fengus is the tribute MELEE attack-power buff, so it is
-- Slip'kik's mirror — Store.CLASS_RULE_SEEDS.dmtAP requires it for the six
-- weapon classes and IGNORES it for Mage/Priest/Warlock. Without this entry the
-- slot is threshold-bearing and therefore required-for-everyone, which is the
-- red "Missing" tile on a mage card and the inflated "N/N HELD" denominator.
local CLASS_RULED_KEYS = { rend = true, dmtSP = true, battleShout = true, dmtAP = true }
Dashboard.CLASS_RULED_KEYS = CLASS_RULED_KEYS

-- Class rule state for an aura rule map ("rend"/"battleShout"/"dmtSP"/"dmtAP").
--
-- SETTINGS-REWORK ITEM 6: FACTION-BLIND. There is one global rule table
-- (Store.GetAuraRules) instead of factionSettings[F].auraOpts[optKey]. The
-- third parameter is accepted and IGNORED so every existing call site — cards,
-- detail, the requirement helper, the suites — keeps compiling and keeps
-- meaning the same thing; passing a faction simply cannot change the answer any
-- more, which is the entire point of the merge.
function Dashboard.ClassRuleState(optKey, classTag, _faction)
    if not classTag then return "ignored" end
    local rules = ns.Store and ns.Store.GetAuraRules and ns.Store.GetAuraRules()
    local o = rules and rules[optKey]
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
--
-- CROSS-BUCKET DEDUP (owner bug: "Puucons" drew TWICE, both green, the day his
-- third account joined the mesh).
--
-- Account buckets are the only partition of the character graph, so when an
-- account is re-set up under a new / differently-formatted AID its characters
-- start arriving under a brand new bucket while the old bucket keeps a complete,
-- untouched copy of every one of them. This walk used to emit ONE ENTRY PER
-- BUCKET, so the same Name-Realm produced two cards — and because online
-- exclusivity is deliberately per-account (ComputeOnlineWinners, above), each
-- bucket elected its own winner and BOTH cards lit green. The machinery already
-- DETECTED the case (charAID[name] == false means "this name spans >1 aid"); it
-- just had nowhere to act on it.
--
-- A Name-Realm is ONE character, so the roster shows ONE card for it. Which copy
-- that card carries is decided by Dashboard.RosterWinner's tiebreak chain
-- (newest ownerEpoch -> newest lastDataUpdate -> real bucket over homeless ->
-- lowest numeric aid). The entry carries the WINNING copy's own aid, so online
-- exclusivity and the detail pane both stay attributed to the right account.
--
-- The losing copies are NOT deleted here. Deletion is a STORE decision with its
-- own guards (Store.ReconcileStaleTwins / SweepStaleTwins, B5); the UI layer only
-- decides what to draw, so a display rule can never destroy data.
----------------------------------------------------------------------

-- PURE. Account-id ordering for the final tiebreak: real numeric ids ascending,
-- then anything non-numeric (including the "" orphan bucket) lexicographically.
-- Numbers first so "lowest numeric AID" means what it says even when a
-- differently-FORMATTED id (the very thing that caused this bug) is in the mix.
function Dashboard.AIDLess(a, b)
    a, b = a or "", b or ""
    if a == b then return false end
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    if na then return true end          -- numeric beats non-numeric
    if nb then return false end
    return a < b
end

-- PURE. Is candidate `a` a better copy of a character than candidate `b`?
-- A candidate is { aid = , rec = , homeless = bool }.
--   1. newest ownerEpoch          (the owner's own stamp — the real evidence)
--   2. newest lastDataUpdate      (when the epochs are unstamped/equal)
--   3. a real account bucket beats homeless / the "" orphan bucket
--   4. lowest numeric aid         (pure determinism — no data left to judge on)
function Dashboard.RosterCandidateBetter(a, b)
    if not b then return true end
    if not a then return false end
    local ra, rb = a.rec or {}, b.rec or {}

    local ea, eb = tonumber(ra.ownerEpoch) or 0, tonumber(rb.ownerEpoch) or 0
    if ea ~= eb then return ea > eb end

    local ua, ub = tonumber(ra.lastDataUpdate) or 0, tonumber(rb.lastDataUpdate) or 0
    if ua ~= ub then return ua > ub end

    -- "Homeless" for ranking means "has no real home": the per-bucket homeless
    -- table OR the "" orphan bucket, which is exactly the same claim (a record
    -- we hold without a confirmed place to put it).
    local ha = (a.homeless or (a.aid or "") == "") and 1 or 0
    local hb = (b.homeless or (b.aid or "") == "") and 1 or 0
    if ha ~= hb then return ha < hb end

    return Dashboard.AIDLess(a.aid, b.aid)
end

-- PURE. Fold an array of candidates for ONE Name-Realm down to the winner.
function Dashboard.RosterWinner(candidates)
    local best
    for _, c in ipairs(candidates or {}) do
        if Dashboard.RosterCandidateBetter(c, best) then best = c end
    end
    return best
end

-- Every copy of `nameRealm` the store holds, as candidates. Unfiltered — this is
-- the identity question ("which bucket owns this character"), not a view.
function Dashboard.RosterCandidates(nameRealm)
    local out = {}
    if type(nameRealm) ~= "string" or nameRealm == "" then return out end
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if not data or not data.accounts then return out end
    for aid, bucket in pairs(data.accounts) do
        local rec = bucket.characters and bucket.characters[nameRealm]
        if rec then
            out[#out + 1] = { nameRealm = nameRealm, aid = aid, rec = rec, homeless = false }
        else
            rec = bucket.homeless and bucket.homeless[nameRealm]
            if rec then
                out[#out + 1] = { nameRealm = nameRealm, aid = aid, rec = rec, homeless = true }
            end
        end
    end
    return out
end

-- THE shared answer to "which stored copy IS this character". Returns rec, aid
-- (nil when we hold no copy). Detail.Resolve delegates here so the detail pane
-- can never disagree with the card the owner just clicked.
function Dashboard.ResolveRosterOwner(nameRealm)
    local best = Dashboard.RosterWinner(Dashboard.RosterCandidates(nameRealm))
    if not best then return nil end
    return best.rec, best.aid
end

function Dashboard.GatherRoster(faction, opts)
    opts = opts or {}
    local out = {}
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if not data or not data.accounts then return out end
    -- Per-account online exclusivity is recomputed over the WHOLE store BEFORE
    -- the faction/level filters run (see the block above IsOnline for why).
    Dashboard.RefreshOnlineWinners()

    -- Pass 1: collect the surviving copies per Name-Realm. The filters run per
    -- COPY on purpose — a stale twin that fails the level/faction gate must not
    -- suppress the live copy that passes it.
    local bestOf, names = {}, {}
    for aid, bucket in pairs(data.accounts) do
        local function consider(nameRealm, rec, homeless)
            if not rec then return end
            if opts.faction ~= false and faction and rec.faction and rec.faction ~= faction then
                return
            end
            if opts.minLevel and (rec.level or 0) < opts.minLevel then return end
            if opts.warlockOnly and rec.classTag ~= "WARLOCK" then return end
            local cand = { nameRealm = nameRealm, aid = aid, rec = rec, homeless = homeless }
            local held = bestOf[nameRealm]
            if not held then names[#names + 1] = nameRealm end
            if Dashboard.RosterCandidateBetter(cand, held) then bestOf[nameRealm] = cand end
        end
        for nameRealm, rec in pairs(bucket.characters or {}) do consider(nameRealm, rec, false) end
        if opts.includeHomeless then
            for nameRealm, rec in pairs(bucket.homeless or {}) do consider(nameRealm, rec, true) end
        end
    end

    -- Pass 2: emit one entry per name, carrying the WINNER's aid so IsOnline
    -- resolves exclusivity against the account that actually owns the character.
    -- Sorted by name so the array handed downstream is deterministic (the card
    -- list re-sorts it, but a stable input keeps equal-rank ties from shuffling).
    table.sort(names)
    for i = 1, #names do
        local c = bestOf[names[i]]
        out[#out + 1] = {
            nameRealm = c.nameRealm,
            aid       = c.aid,
            rec       = c.rec,
            online    = Dashboard.IsOnline(c.rec, c.nameRealm, c.aid),
        }
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

    -- Close (far right). ROUND-19b (owner: "update the 'x' button to be the same style as
    -- the others"): the TEXT "X" becomes a 22x22 white-mask icon button skinned exactly
    -- like the gear beside it and the dock's Refresh/Broadcast pair — our own glyph
    -- (textures/icon-close.tga), `muted` at rest, re-tinted on ThemeChanged.
    -- ONE DELIBERATE DIVERGENCE: hover tints `danger`, not `accent`. Closing is the only
    -- destructive affordance in the titlebar and the old text X already hovered red, so
    -- that language is preserved rather than flattened into the shared accent hover.
    -- No tooltip: ✕ is universal, and the gear beside it needs one only because a cog is
    -- ambiguous. Escape-close (UISpecialFrames) is untouched.
    local closeBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -8, 0)
    local cIcon = closeBtn:CreateTexture(nil, "ARTWORK")
    cIcon:SetPoint("TOPLEFT", closeBtn, "TOPLEFT", 2, -2)
    cIcon:SetPoint("BOTTOMRIGHT", closeBtn, "BOTTOMRIGHT", -2, 2)
    cIcon:SetTexture("Interface\\AddOns\\Daseeki-Nexus\\textures\\icon-close")
    closeBtn.icon = cIcon
    UI.Skin(closeBtn, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
        self.icon:SetVertexColor(UI.Color(self._hot and "danger" or "muted"))
    end)
    closeBtn:SetScript("OnEnter", function(self)
        self._hot = true
        self.icon:SetVertexColor(UI.Color("danger"))
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self._hot = nil
        self.icon:SetVertexColor(UI.Color("muted"))
    end)
    closeBtn:SetScript("OnClick", function() w:Hide() end)
    tag(closeBtn, "shell.close")

    -- Round-6 (item B): the faction toggle MOVED OFF the titlebar into the chip bar
    -- (it filters characters, so it lives with the filters — see ui_cards). The
    -- titlebar right cluster is now just Settings · ✕. A no-op _updateFactionToggle is
    -- kept so OnShow (which calls it) stays safe; the chip-bar segment repaints on
    -- Dashboard.RefreshActive instead.
    w._updateFactionToggle = function() end

    -- Settings launcher, left of ✕. Opens the Core hub to the Nexus section.
    -- ROUND-18 item 4 (owner): the "Settings" TEXT button becomes a 22x22 GEAR ICON button
    -- skinned exactly like the timers dock's Refresh/Broadcast pair — our own white glyph
    -- mask (textures/icon-gear.tga), tinted `muted` at rest and `accent` on hover, both
    -- re-applied on ThemeChanged. The label is not lost: it moves to a GameTooltip.
    local settingsBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
    settingsBtn:SetSize(22, 22)
    local sIcon = settingsBtn:CreateTexture(nil, "ARTWORK")
    sIcon:SetPoint("TOPLEFT", settingsBtn, "TOPLEFT", 2, -2)
    sIcon:SetPoint("BOTTOMRIGHT", settingsBtn, "BOTTOMRIGHT", -2, 2)
    sIcon:SetTexture("Interface\\AddOns\\Daseeki-Nexus\\textures\\icon-gear")
    settingsBtn.icon = sIcon
    UI.Skin(settingsBtn, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
        self.icon:SetVertexColor(UI.Color(self._hot and "accent" or "muted"))
    end)
    settingsBtn:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
    settingsBtn:SetScript("OnEnter", function(self)
        self._hot = true
        self.icon:SetVertexColor(UI.Color("accent"))
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Settings", UI.Color("text")); GameTooltip:Show()
    end)
    settingsBtn:SetScript("OnLeave", function(self)
        self._hot = nil
        self.icon:SetVertexColor(UI.Color("muted"))
        GameTooltip:Hide()
    end)
    settingsBtn:SetScript("OnClick", function()
        if DaseekiSuite and DaseekiSuite.Open then DaseekiSuite:Open("nexus")
        else ns:Print("the Daseeki hub (Daseeki Core) is not available.") end
    end)
    tag(settingsBtn, "shell.settings")
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
    -- SETTINGS-REWORK ITEM 6: the write target is the ONE global rule table.
    local o = ns.Store.GetAuraRules().dmtSP
    local pReq, pIgn = o.required.WARRIOR, o.ignored.WARRIOR
    o.ignored.WARRIOR = nil; o.required.WARRIOR = true
    local a3, r3 = Dashboard.AuraRequirement(SP_SLOT, { classTag = "WARRIOR" }, FAC)
    ck(a3 == true and r3 == "required", "dmtSP Warrior (required) is applicable+required")
    o.required.WARRIOR = pReq; o.ignored.WARRIOR = pIgn   -- restore defaults
    -- Rend stays class-ruled, and since B12 its class map SHIPS SEEDED
    -- (store.lua Store.CLASS_RULE_SEEDS, spec §4.7): Warrior/Rogue required,
    -- every other class optional. Mage is therefore applicable+optional.
    -- (This assertion previously read `a4 == false` — that was the B12 defect
    -- frozen into a guard: with an empty map every non-Warrior collapsed out.)
    local a4, r4 = Dashboard.AuraRequirement(REND_SLOT, { classTag = "MAGE" }, FAC)
    ck(a4 == true and r4 == "optional", "rend seeded default: Mage is applicable+optional")
    local a4b, r4b = Dashboard.AuraRequirement(REND_SLOT, { classTag = "WARRIOR" }, FAC)
    ck(a4b == true and r4b == "required", "rend seeded default: Warrior is applicable+required")
    -- Regression guard: a non-class-ruled buff (ZG, slot 3) stays required.
    local a5, r5 = Dashboard.AuraRequirement(3, { classTag = "ROGUE" }, FAC)
    ck(a5 == true and r5 == "required", "ZG stays required-by-default (not class-ruled)")

    -- ---- Battle Shout (slot 9) class-ruling matrix -------------------------
    -- Slot 9 gained a thresholdKey the day it became Battle Shout, and a
    -- threshold-bearing slot is required-by-default for EVERYONE. If
    -- CLASS_RULED_KEYS ever loses `battleShout` again, every caster in the
    -- roster grows a permanent red "Missing Battle Shout" tile — these four
    -- assertions are the tripwire.
    local BS_SLOT = 9
    local aW, rW = Dashboard.AuraRequirement(BS_SLOT, { classTag = "WARRIOR" }, FAC)
    ck(aW == true and rW == "required", "battleShout seeded default: Warrior is applicable+required")
    local aR, rR = Dashboard.AuraRequirement(BS_SLOT, { classTag = "ROGUE" }, FAC)
    ck(aR == true and rR == "required", "battleShout seeded default: Rogue is applicable+required")
    local aM = Dashboard.AuraRequirement(BS_SLOT, { classTag = "MAGE" }, FAC)
    ck(aM == false, "battleShout seeded default: Mage is IGNORED (no red missing tile)")
    local aP = Dashboard.AuraRequirement(BS_SLOT, { classTag = "PRIEST" }, FAC)
    ck(aP == false, "battleShout seeded default: Priest is IGNORED (no red missing tile)")
    -- A classless record must not be treated as required either.
    ck(Dashboard.AuraRequirement(BS_SLOT, {}, FAC) == false,
       "battleShout with no classTag -> non-applicable, never required")

    -- ---- Fengus' Ferocity / DMT AP (slot 6) class-ruling matrix -------------
    -- OWNER BUG, round-24: a level-60 MAGE card read "WORLD BUFFS · 7/8 HELD"
    -- with Fengus' Ferocity = Missing. Slot 6 carries a thresholdKey, and a
    -- threshold-bearing slot with no class rule is required-for-everyone — so
    -- the melee attack-power buff was red-flagged on every caster in the
    -- roster. These assertions are the tripwire for both halves of the fix
    -- (CLASS_RULED_KEYS.dmtAP above + Store.CLASS_RULE_SEEDS.dmtAP).
    local AP_SLOT = 6
    for _, c in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "SHAMAN", "DRUID" }) do
        local aA, rA = Dashboard.AuraRequirement(AP_SLOT, { classTag = c }, FAC)
        ck(aA == true and rA == "required",
           ("dmtAP seeded default: %s is applicable+required"):format(c))
    end
    for _, c in ipairs({ "MAGE", "PRIEST", "WARLOCK" }) do
        ck(Dashboard.AuraRequirement(AP_SLOT, { classTag = c }, FAC) == false,
           ("dmtAP seeded default: %s is IGNORED (no red Missing tile)"):format(c))
    end
    -- SETTINGS-REWORK ITEM 6: the faction argument cannot change the answer any
    -- more — there is one global rule table and ClassRuleState ignores the third
    -- parameter. Asserted for EVERY class on both sides rather than spot-checked,
    -- because "the faction argument is inert" is the whole contract of the merge:
    -- if a faction-sensitive read path ever creeps back in, this fails loudly.
    for _, c in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
                         "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
        for _, slot in ipairs({ 2, 6, 8, 9 }) do
            local aA, rA = Dashboard.AuraRequirement(slot, { classTag = c }, "Alliance")
            local aH, rH = Dashboard.AuraRequirement(slot, { classTag = c }, "Horde")
            ck(aA == aH and rA == rH,
               ("global rules: slot %d / %s reads identically on both factions"):format(slot, c))
        end
    end
    ck(Dashboard.AuraRequirement(AP_SLOT, { classTag = "MAGE" }, "Horde") == false,
       "dmtAP Horde mage is IGNORED too")
    ck(select(2, Dashboard.AuraRequirement(AP_SLOT, { classTag = "SHAMAN" }, "Horde")) == "required",
       "dmtAP Horde shaman is required")
    ck(Dashboard.AuraRequirement(AP_SLOT, {}, FAC) == false,
       "dmtAP with no classTag -> non-applicable, never required")
    -- The owner can re-tick it like any other rule (Buffs page write path).
    local ap = ns.Store.GetAuraRules().dmtAP
    if ap then
        local pReq, pIgn = ap.required.MAGE, ap.ignored.MAGE
        ap.ignored.MAGE = nil; ap.required.MAGE = true
        local aM2, rM2 = Dashboard.AuraRequirement(AP_SLOT, { classTag = "MAGE" }, FAC)
        ck(aM2 == true and rM2 == "required",
           "dmtAP is user-overridable: Mage re-ticked required reads back red")
        ap.required.MAGE = pReq; ap.ignored.MAGE = pIgn   -- restore defaults
    end

    -- ---- "N/N HELD" denominator (the number the owner actually saw) --------
    -- The detail pane counts a row only when BuffTileState says shown, and for
    -- an absent buff that is exactly AuraRequirement's applicable flag. Count
    -- it the same way here for a bare (no buffs at all) character of each class
    -- so the denominator is pinned headlessly, without touching ui_detail.lua.
    local function shownWhenBare(classTag, faction)
        local n = 0
        for _, slot in ipairs(Dashboard.AURA_DISPLAY_ORDER or {}) do
            -- The DMF row renders even when absent (display-order contract), so
            -- it is counted regardless of applicability, mirroring BuffTileState.
            local meta = Dashboard.AURA_META[slot]
            local appl = Dashboard.AuraRequirement(slot, { classTag = classTag }, faction)
            if appl or (meta and meta.key == "dmf") then n = n + 1 end
        end
        return n
    end
    local mageShown, warShown = shownWhenBare("MAGE", FAC), shownWhenBare("WARRIOR", FAC)
    ck(mageShown == 7, ("bare mage shows 7 buff rows (0/7 HELD), got " .. mageShown))
    ck(warShown  == 8, ("bare warrior shows 8 buff rows (0/8 HELD), got " .. warShown))
end

-- Self-test: AURA_META agrees with the TRACKER's slot map (drift guard).
--
-- THE REGRESSION THIS EXISTS FOR: the tracker moved slots 9/10 onto Battle
-- Shout (25101) and Fire Festival Fury (29338/29846); AURA_META went on
-- declaring Traces of Silithyst / Boon of Blackfathom. Storage and presentation
-- live in two files, so a captured Battle Shout rendered — name, icon, tooltip,
-- everywhere — as Silithyst. Nothing but a test can keep the two honest.
--
-- The tracker is owned elsewhere, so this consumes it READ-ONLY through the two
-- matchers it already exposes for the live aura scan (Tracker.MatchBuffSlotByID
-- / Tracker.MatchBuffSlot) — the same code the wire path runs, not a private
-- copy of its tables. When the tracker is absent (a headless host that only
-- loads the UI), the hardcoded pairs below still pin AURA_META on their own.
local AURA_SLOT_EXPECTED = {
    [1]  = { key = "ony",        spellID = 22888 },
    [2]  = { key = "rend",       spellID = 16609 },
    [3]  = { key = "zg",         spellID = 24425 },
    [4]  = { key = "songflower", spellID = 15366 },
    [5]  = { key = "dmf",        spellID = 23768 },
    [6]  = { key = "dmtap",      spellID = 22817 },
    [7]  = { key = "dmtstam",    spellID = 22818 },
    [8]  = { key = "dmtsp",      spellID = 22820 },
    [9]  = { key = "battleshout",spellID = 25101 },   -- NPC "Fallen Hero" cast
    [10] = { key = "fff",        spellID = 29338 },   -- seasonal (alt id 29846)
}

local function testAuraSlotMap(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local META = Dashboard.AURA_META
    ck(type(META) == "table", "AURA_META exists")
    if type(META) ~= "table" then return end

    local seenKey = {}
    for slot = 1, 10 do
        local meta, want = META[slot], AURA_SLOT_EXPECTED[slot]
        if not meta then
            ck(false, ("AURA_META[%d] is missing"):format(slot))
        else
            ck(meta.key == want.key,
               ("slot %d key %q, expected %q"):format(slot, tostring(meta.key), want.key))
            ck(meta.spellID == want.spellID,
               ("slot %d spellID %s, expected %d"):format(slot, tostring(meta.spellID), want.spellID))
            ck(type(meta.name) == "string" and meta.name ~= "", ("slot %d has a display name"):format(slot))
            ck(type(meta.short) == "string" and meta.short ~= "", ("slot %d has a short label"):format(slot))
            ck(not seenKey[meta.key], ("slot %d key %q is not unique"):format(slot, tostring(meta.key)))
            seenKey[meta.key] = true
        end
    end
    ck(META[11] == nil, "AURA_META stops at 10 (the tracker's slot budget)")

    -- Cross-check against the tracker itself, both ways: the ID we paint the
    -- icon from must land in the slot we paint it into, and the name we print
    -- must match the prefix the tracker files that slot under.
    local T = ns.Tracker
    if T and T.MatchBuffSlotByID and T.MatchBuffSlot then
        for slot = 1, 10 do
            local meta = META[slot]
            if meta then
                local byID = T.MatchBuffSlotByID(meta.spellID)
                ck(byID == slot,
                   ("DRIFT: tracker files spellID %s in slot %s, AURA_META shows it as slot %d (%s)")
                       :format(tostring(meta.spellID), tostring(byID), slot, tostring(meta.name)))
                local byName = T.MatchBuffSlot(meta.name)
                ck(byName == slot,
                   ("DRIFT: tracker files %q in slot %s, AURA_META shows slot %d")
                       :format(tostring(meta.name), tostring(byName), slot))
            end
        end
        -- The retired tail buffs must NOT resolve any more, on either side.
        ck(T.MatchBuffSlot("Traces of Silithyst") == nil, "retired: Silithyst has no slot")
        ck(T.MatchBuffSlot("Boon of Blackfathom") == nil, "retired: Boon of Blackfathom has no slot")
    else
        ck(false, "tracker matchers unreachable — slot-map agreement unverified")
    end

    -- The display order must still be a permutation of every stored slot, or a
    -- slot silently stops rendering (the quiet half of this class of bug).
    local order, cover = Dashboard.AURA_DISPLAY_ORDER, {}
    ck(type(order) == "table" and #order == 10, "AURA_DISPLAY_ORDER covers 10 slots")
    for _, slot in ipairs(order or {}) do
        ck(META[slot] ~= nil, ("display order references unknown slot %s"):format(tostring(slot)))
        ck(not cover[slot], ("display order lists slot %s twice"):format(tostring(slot)))
        cover[slot] = true
    end
    for slot = 1, 10 do ck(cover[slot], ("slot %d is never displayed"):format(slot)) end
    -- BS/FFF ride at the tail (see the order's rationale).
    ck(order and order[9] == 9 and order[10] == 10, "Battle Shout + FFF sit at the tail of the strip")

    -- Icon fallback: the tail slots' identity ids are NPC / seasonal casts the
    -- client may not resolve a texture for, so each names art-only backup id.
    -- Proven by resolving slot 9 through a client that ONLY knows 6673.
    ck(META[9] and META[9].iconSpellID == 6673, "Battle Shout carries the 6673 art fallback")
    ck(META[10] and META[10].iconSpellID == 29846, "FFF carries the 29846 art fallback")
    local savedCS    = C_Spell
    local savedCache = Dashboard._auraIconCache and Dashboard._auraIconCache[9]
    if Dashboard._auraIconCache then Dashboard._auraIconCache[9] = nil end
    C_Spell = { GetSpellTexture = function(id) return (id == 6673) and "TEX:6673" or nil end }
    local icon = Dashboard.AuraIcon(9)
    C_Spell = savedCS
    -- Evict the stub so a live /nexus selftest cannot poison slot 9's real icon.
    if Dashboard._auraIconCache then Dashboard._auraIconCache[9] = savedCache end
    ck(icon == "TEX:6673",
       "AuraIcon(9) falls back to the art id when 25101 has no texture (got " .. tostring(icon) .. ")")
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

-- Same-account online exclusivity (owner bug: logging Daseeki -> Shalk on ONE
-- account left both showing a green pip). Exercises the pure winners pass and
-- the IsOnline lookup that consults it.
local function testOnlineExclusivity(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = 1000000
    local function r(nameRealm, aid, lastSeen, selfAcct)
        return { nameRealm = nameRealm, aid = aid, selfAcct = selfAcct or false,
                 rec = { lastSeen = lastSeen } }
    end

    -- 1) REMOTE account, two fresh siblings -> only the newest lastSeen is on.
    local w = Dashboard.ComputeOnlineWinners(
        { r("Daseeki-R", "2", T - 40), r("Shalk-R", "2", T - 5) }, T, "Tester")
    ck(w.winner["2"] == "Shalk-R", "same aid, two fresh -> newest (Shalk) wins")

    -- 2) LOCAL account -> the character we are logged in as wins outright, even
    --    though the sibling we just left has the FRESHER lastSeen. This is the
    --    reported bug: recency alone kept Daseeki green.
    w = Dashboard.ComputeOnlineWinners(
        { r("Daseeki-R", "1", T, true), r("Shalk-R", "1", T - 90, true) }, T, "Shalk")
    ck(w.winner["1"] == "Shalk-R", "local account -> current player wins over fresher sibling")

    -- 3) DIFFERENT accounts, both fresh -> both online (owner runs 4 accounts;
    --    exclusivity is strictly per-aid and must never span accounts).
    w = Dashboard.ComputeOnlineWinners(
        { r("Aaa-R", "1", T - 5, true), r("Bbb-R", "3", T - 5) }, T, "Aaa")
    ck(w.winner["1"] == "Aaa-R" and w.winner["3"] == "Bbb-R", "different aids -> both online")

    -- 4) Remote account whose freshest record is outside ONLINE_WINDOW -> nobody.
    w = Dashboard.ComputeOnlineWinners(
        { r("Old-R", "4", T - (ONLINE_WINDOW + 1)), r("Older-R", "4", T - 9999) }, T, "Tester")
    ck(w.winner["4"] == false, "remote aid, all stale -> no winner")

    -- 5) Orphan bucket that is not ours is EXEMPT (unattributed characters may
    --    come from many accounts, so one-per-account is not a valid claim).
    w = Dashboard.ComputeOnlineWinners(
        { r("Un-R", "", T), r("Deux-R", "", T - 1) }, T, "Tester")
    ck(w.winner[""] == nil, "non-self orphan bucket -> exempt from exclusivity")
    --    ...but our OWN orphan bucket (no account id chosen yet) still claims.
    w = Dashboard.ComputeOnlineWinners(
        { r("Un-R", "", T, true), r("Tester-R", "", T - 99, true) }, T, "Tester")
    ck(w.winner[""] == "Tester-R", "self orphan bucket -> current player wins")

    -- 6) A Name-Realm held under TWO accounts is unattributable -> charAID false.
    w = Dashboard.ComputeOnlineWinners(
        { r("Dup-R", "1", T, true), r("Dup-R", "5", T) }, T, "Tester")
    ck(w.charAID["Dup-R"] == false, "duplicate Name-Realm across aids -> unattributable")

    -- 7) IsOnline consults the table: the LOSER reads offline even though its
    --    lastSeen is bang-fresh, and an explicit aid overrides the lookup.
    local saved = Dashboard._onlineWinners
    Dashboard._onlineWinners = {
        winner  = { ["1"] = "Shalk-R", ["3"] = "Bbb-R" },
        charAID = { ["Shalk-R"] = "1", ["Daseeki-R"] = "1", ["Bbb-R"] = "3" },
    }
    local fresh = { lastSeen = now() }
    ck(Dashboard.IsOnline(fresh, "Shalk-R", "1") == true, "IsOnline: winner -> online")
    ck(Dashboard.IsOnline(fresh, "Daseeki-R", "1") == false,
        "IsOnline: fresh same-account loser -> OFFLINE (the bug)")
    ck(Dashboard.IsOnline(fresh, "Daseeki-R") == false,
        "IsOnline: aid resolved via charAID -> loser still offline")
    ck(Dashboard.IsOnline(fresh, "Bbb-R", "3") == true, "IsOnline: other account unaffected")
    ck(Dashboard.IsOnline(fresh, "Nobody-R") == true,
        "IsOnline: untracked character falls back to recency")
    ck(Dashboard.IsOnline({ lastSeen = now() - (ONLINE_WINDOW + 5) }, "Nobody-R") == false,
        "IsOnline: untracked + stale -> offline")
    ck(Dashboard.IsOnline(nil, "Shalk-R", "1") == false, "IsOnline: nil record -> offline")
    Dashboard._onlineWinners = saved
end

-- A1.1 + A1.2 — the 15s recency window and live mesh presence as the PRIMARY
-- online source for a remote account. Exclusivity is unchanged; only the
-- freshness evidence improves.
local function testMeshPresence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = 1000000
    local function r(nameRealm, aid, lastSeen, selfAcct)
        return { nameRealm = nameRealm, aid = aid, selfAcct = selfAcct or false,
                 rec = { lastSeen = lastSeen } }
    end

    -- A1.1: the window is 15s. A sibling silent for 16s is grey; the old 150s
    -- window kept it green for two and a half minutes (the owner's complaint).
    ck(ONLINE_WINDOW == 15, "ONLINE_WINDOW must be 15s (got " .. ONLINE_WINDOW .. ")")
    local w = Dashboard.ComputeOnlineWinners({ r("Quiet-R", "2", T - 16) }, T, "Tester")
    ck(w.winner["2"] == false, "16s-silent remote sibling -> offline at the 15s window")
    w = Dashboard.ComputeOnlineWinners({ r("Quiet-R", "2", T - 14) }, T, "Tester")
    ck(w.winner["2"] == "Quiet-R", "14s-silent remote sibling still online")

    -- A1.2 (a): mesh presence WINS over recency. The mesh says account 2 is on
    -- Shalk; Daseeki's stored lastSeen is fresher, but the mesh is first-hand.
    w = Dashboard.ComputeOnlineWinners(
        { r("Daseeki-R", "2", T - 1), r("Shalk-R", "2", T - 300) }, T, "Tester",
        { ["2"] = "Shalk-R" })
    ck(w.winner["2"] == "Shalk-R", "mesh presence beats a fresher stored lastSeen")

    -- A1.2 (b): mesh presence RESCUES a peer whose state pushes are throttled —
    -- every record is outside the 15s window, but the peer is heartbeating.
    w = Dashboard.ComputeOnlineWinners(
        { r("Live-R", "2", T - 600) }, T, "Tester", { ["2"] = "Live-R" })
    ck(w.winner["2"] == "Live-R", "mesh-live peer stays online past the recency window")

    -- A1.2 (c): the mesh naming a character we hold NO record for must not
    -- invent a winner — we fall back to recency.
    w = Dashboard.ComputeOnlineWinners(
        { r("Known-R", "2", T - 3) }, T, "Tester", { ["2"] = "Stranger-R" })
    ck(w.winner["2"] == "Known-R", "unknown mesh name -> recency fallback")
    w = Dashboard.ComputeOnlineWinners(
        { r("Known-R", "2", T - 99) }, T, "Tester", { ["2"] = "Stranger-R" })
    ck(w.winner["2"] == false, "unknown mesh name + stale record -> offline")

    -- A1.3 interlock: once the peer sweep flips Mesh.peers[aid].online false the
    -- snapshot no longer names it, so a crashed peer goes grey. (MeshPresence
    -- only reports peers still flagged online.)
    w = Dashboard.ComputeOnlineWinners({ r("Live-R", "2", T - 600) }, T, "Tester", {})
    ck(w.winner["2"] == false, "swept (offline) peer -> grey")

    -- LOCAL account rule is UNTOUCHED: the character we are standing in wins
    -- outright, and mesh presence can never override or double-green it.
    w = Dashboard.ComputeOnlineWinners(
        { r("Daseeki-R", "1", T, true), r("Shalk-R", "1", T - 90, true) }, T, "Shalk",
        { ["1"] = "Daseeki-R" })
    ck(w.winner["1"] == "Shalk-R", "local account: current player still wins over mesh hint")

    -- Dashboard.MeshPresence reads the live peer table: online peers only.
    local savedPeers = ns.Mesh and ns.Mesh.peers
    if ns.Mesh then
        ns.Mesh.peers = {
            ["2"] = { aid = "2", name = "On-R",   online = true },
            ["3"] = { aid = "3", name = "Off-R",  online = false },
            ["4"] = { aid = "4", online = true },              -- no name yet
        }
        local snap = Dashboard.MeshPresence()
        ck(snap["2"] == "On-R", "MeshPresence includes an online named peer")
        ck(snap["3"] == nil, "MeshPresence excludes an offline peer")
        ck(snap["4"] == nil, "MeshPresence excludes a nameless peer")
        ns.Mesh.peers = savedPeers
    end
end

-- A6.8 — the display-decay choke point. Three behaviours, one helper:
-- online decays, offline freezes, booned NEVER decays (A7.6).
local function testAuraDisplayDecay(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local BOON = (ns.Store and ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
    local T = 1700000000

    local function rec(cell, upd)
        return { nameRealm = "Zzz-Nowhere", lastDataUpdate = upd or T,
                 lastSeen = upd or T, auraStates = { [1] = cell } }
    end

    -- ONLINE: the stored number ages by the time since the record was refreshed.
    local r = rec({ duration = 3600, source = 0 })
    ck(Dashboard.AuraRemaining(r, 1, T, true) == 3600, "online, no elapsed -> unchanged")
    ck(Dashboard.AuraRemaining(r, 1, T + 600, true) == 3000,
       "online: 600s since the last update -> 600s off the buff (THE A6.8 FIX)")
    ck(Dashboard.AuraRemaining(r, 1, T + 99999, true) == 0, "online: floors at 0, never negative")

    -- OFFLINE: frozen at its last known value.
    ck(Dashboard.AuraRemaining(r, 1, T + 600, false) == 3600,
       "offline: FROZEN — nothing is refreshing the record, so nothing is inferred")
    ck(Dashboard.AuraRemaining(r, 1, T + 99999, false) == 3600, "offline: still frozen much later")

    -- BOONED: frozen for EVERYONE, online or not (A7.6, now explicit).
    local b = rec({ duration = 3600, source = BOON })
    ck(Dashboard.AuraRemaining(b, 1, T + 600, true) == 3600,
       "booned + ONLINE: frozen — a suspended buff does not tick (A7.6)")
    ck(Dashboard.AuraRemaining(b, 1, T + 99999, true) == 3600,
       "booned + ONLINE: still frozen after a whole day")
    ck(Dashboard.AuraRemaining(b, 1, T + 600, false) == 3600, "booned + offline: frozen")
    -- The string form of the same flag is honoured (legacy records).
    local bs = rec({ duration = 1800, source = "boon" })
    ck(Dashboard.AuraRemaining(bs, 1, T + 600, true) == 1800, "booned via the legacy string source: frozen")

    -- Clock skew: a lastDataUpdate in the future must not inflate the countdown.
    local skew = rec({ duration = 3600, source = 0 }, T + 500)
    ck(Dashboard.AuraRemaining(skew, 1, T, true) == 3600, "clock skew: elapsed clamps at 0")

    -- Empty / absent slots are inert.
    ck(Dashboard.AuraRemaining(rec({ duration = 0, source = 0 }), 1, T, true) == 0, "zero duration -> 0")
    ck(Dashboard.AuraRemaining({ auraStates = {} }, 1, T, true) == 0, "absent slot -> 0")
    ck(Dashboard.AuraRemaining(nil, 1, T, true) == 0, "nil record -> 0")

    -- The second return is the raw cell, so callers can still read source/option.
    local _, cell = Dashboard.AuraRemaining(b, 1, T, true)
    ck(cell and cell.source == BOON, "returns the raw cell alongside the remaining")
end

-- CROSS-BUCKET ROSTER DEDUP (owner bug: one character, two cards, both green,
-- after a third account joined the mesh under a new AID). Exercises the pure
-- tiebreak chain, the GatherRoster fold, and the Detail.Resolve agreement that
-- keeps the clicked card and the detail pane on the same record.
local function testRosterDedup(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = 1700000000

    -- ---- the pure aid ordering ---------------------------------------------
    ck(Dashboard.AIDLess("2", "10") == true,  "aid order is NUMERIC: 2 < 10 (not '10' < '2')")
    ck(Dashboard.AIDLess("10", "2") == false, "...and not the other way round")
    ck(Dashboard.AIDLess("3", "3") == false,  "an aid does not beat itself")
    ck(Dashboard.AIDLess("3", "abc") == true, "a numeric aid beats a non-numeric one")
    ck(Dashboard.AIDLess("abc", "3") == false, "...and never loses that way round")
    ck(Dashboard.AIDLess("3", "") == true,    "a real aid beats the orphan bucket")
    ck(Dashboard.AIDLess("abc", "abd") == true, "two non-numeric aids compare as strings")

    -- ---- the pure tiebreak chain, one rung at a time ------------------------
    local function cand(aid, ownerEpoch, upd, homeless)
        return { nameRealm = "Puucons-R", aid = aid, homeless = homeless or false,
                 rec = { ownerEpoch = ownerEpoch, lastDataUpdate = upd or 0 } }
    end
    local old, live = cand("3", T - 14 * 86400, T - 14 * 86400), cand("7", T, T)
    ck(Dashboard.RosterWinner({ old, live }).aid == "7", "rung 1: newest ownerEpoch wins")
    ck(Dashboard.RosterWinner({ live, old }).aid == "7", "...regardless of scan order")
    ck(Dashboard.RosterWinner({ cand("3", T, T - 500), cand("7", T, T) }).aid == "7",
        "rung 2: equal ownerEpoch -> newest lastDataUpdate wins")
    ck(Dashboard.RosterWinner({ cand("3", T, T, true), cand("7", T, T, false) }).aid == "7",
        "rung 3: equal epochs -> a real account bucket beats homeless")
    ck(Dashboard.RosterWinner({ cand("3", T, T), cand("7", T, T, true) }).aid == "3",
        "...and the homeless copy loses whichever aid it sits under")
    ck(Dashboard.RosterWinner({ cand("", T, T), cand("7", T, T) }).aid == "7",
        "rung 3: the '' orphan bucket ranks as homeless too")
    ck(Dashboard.RosterWinner({ cand("7", T, T), cand("3", T, T) }).aid == "3",
        "rung 4: everything equal -> lowest numeric aid (determinism)")
    ck(Dashboard.RosterWinner({}) == nil, "no candidates -> no winner")
    -- Unstamped records (ownerEpoch absent) must not error or win by accident.
    ck(Dashboard.RosterWinner({ { aid = "9", rec = {} }, cand("3", T, T) }).aid == "3",
        "an unstamped copy loses to a stamped one")

    -- ---- GatherRoster over a real two-bucket store --------------------------
    local savedAccounts = ns.Store and ns.Store.data and ns.Store.data.accounts
    local savedPeers    = ns.Mesh and ns.Mesh.peers
    local savedWinners  = Dashboard._onlineWinners
    if ns.Mesh then ns.Mesh.peers = {} end

    local function rec(opts)
        return { nameRealm = opts.name, faction = "Alliance", level = opts.level or 60,
                 classTag = opts.class or "WARRIOR",
                 ownerEpoch = opts.epoch or 0, lastDataUpdate = opts.upd or 0,
                 lastSeen = opts.seen or 0 }
    end
    local function bucket(chars, homeless, isSelf)
        return { isSelf = isSelf or false, characters = chars or {}, homeless = homeless or {},
                 segments = { sixties = {}, summoners = {}, norole = {} }, segmentHashes = {} }
    end

    -- THE OWNER'S CASE: "Puucons" under the two-week-old bucket 3 AND under the
    -- account that just re-joined under a new aid, both with a fresh lastSeen.
    ns.Store.data.accounts = {
        ["3"]  = bucket({ ["Puucons-R"] = rec{ name = "Puucons-R", epoch = T - 14 * 86400,
                                               upd = T - 14 * 86400, seen = now(), level = 58 } }),
        ["11"] = bucket({ ["Puucons-R"] = rec{ name = "Puucons-R", epoch = T, upd = T,
                                               seen = now(), level = 60 },
                          ["Sibling-R"] = rec{ name = "Sibling-R", epoch = T, upd = T, seen = 0 } }),
    }
    local roster = Dashboard.GatherRoster("Alliance", { includeHomeless = true })
    local seen = {}
    for _, e in ipairs(roster) do seen[e.nameRealm] = (seen[e.nameRealm] or 0) + 1 end
    ck(seen["Puucons-R"] == 1, "THE BUG: one character across two buckets -> ONE roster entry")
    ck(seen["Sibling-R"] == 1, "a character held by only one bucket is untouched")
    ck(#roster == 2, "the roster is exactly the two distinct characters")
    local pu
    for _, e in ipairs(roster) do if e.nameRealm == "Puucons-R" then pu = e end end
    ck(pu and pu.aid == "11", "the surviving entry carries the WINNING bucket's aid")
    ck(pu and pu.rec.level == 60, "...and the winning bucket's RECORD (the fresh one)")
    ck(pu and pu.online == true, "...and is online exactly once (both used to be green)")

    -- Detail.Resolve must land on that same record — the clicked card and the
    -- detail pane cannot disagree.
    if ns.Detail and ns.Detail.Resolve then
        local dRec, dAid = ns.Detail.Resolve("Puucons-R")
        ck(dRec == (pu and pu.rec), "Detail.Resolve returns the SAME record the roster picked")
        ck(dAid == "11", "Detail.Resolve returns the same aid too")
        ck(ns.Detail.Resolve("Nobody-R") == nil, "Detail.Resolve on an unheld name -> nil")
    end
    local rRec, rAid = Dashboard.ResolveRosterOwner("Puucons-R")
    ck(rRec == (pu and pu.rec) and rAid == "11", "ResolveRosterOwner agrees with the roster")
    ck(Dashboard.ResolveRosterOwner("Nobody-R") == nil, "ResolveRosterOwner on an unheld name -> nil")

    -- A view FILTER must not let a stale twin suppress the live copy: the old
    -- bucket's level-58 record fails the 60s gate, the live level-60 one passes.
    local sixties = Dashboard.GatherRoster("Alliance", { minLevel = 60, includeHomeless = true })
    local n60 = 0
    for _, e in ipairs(sixties) do if e.nameRealm == "Puucons-R" then n60 = n60 + 1 end end
    ck(n60 == 1, "the live copy still passes a filter its stale twin fails")

    -- Homeless-vs-account preference through the real gather path.
    ns.Store.data.accounts = {
        ["4"] = bucket(nil, { ["Drifter-R"] = rec{ name = "Drifter-R", epoch = T, upd = T } }),
        ["5"] = bucket({ ["Drifter-R"] = rec{ name = "Drifter-R", epoch = T, upd = T } }),
    }
    local hr = Dashboard.GatherRoster("Alliance", { includeHomeless = true })
    ck(#hr == 1 and hr[1].aid == "5", "homeless vs real bucket at equal epochs -> the real bucket")

    -- ...but with includeHomeless off, a name that ONLY exists homeless is absent
    -- (unchanged behaviour — the dedup must not smuggle homeless records in).
    ns.Store.data.accounts = {
        ["4"] = bucket(nil, { ["Drifter-R"] = rec{ name = "Drifter-R", epoch = T, upd = T } }),
    }
    ck(#Dashboard.GatherRoster("Alliance", {}) == 0, "includeHomeless=false still hides homeless records")

    ns.Store.data.accounts = savedAccounts
    if ns.Mesh then ns.Mesh.peers = savedPeers end
    Dashboard._onlineWinners = savedWinners
end

if ns.RegisterSelfTest then
----------------------------------------------------------------------
-- SETTINGS-REWORK ITEM 4 — the FIXED buff-time colour rule.
--
-- Three duration classes, three cutoffs, and a hard "never red while present".
-- Boundaries are tested at exactly the cutoff and one second either side,
-- because "< 90 min" vs "<= 90 min" is a one-character mistake that no amount
-- of eyeballing a card catches — a buff sitting on the boundary would simply
-- look like it flipped a minute early or late.
--
-- MUTATION COVERAGE (each assertion below is here to kill a specific wrong
-- implementation, not to restate the code):
--   * the cutoffs swapped between classes  -> the cross-class checks fail
--   * >= instead of >                      -> the exact-cutoff checks fail
--   * the old three-band threshold path left wired in -> the "never danger"
--     sweep fails at low remaining, where AuraColorToken returns "danger"
--   * a key silently absent from the table -> the coverage check fails
----------------------------------------------------------------------
local function testBuffTimeRule(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local D = Dashboard
    ck(type(D.BUFF_TIME_RULE) == "table", "Dashboard.BUFF_TIME_RULE exists")
    ck(type(D.BuffTimeToken) == "function", "Dashboard.BuffTimeToken exists")
    if not (D.BUFF_TIME_RULE and D.BuffTimeToken) then return end

    -- The amber token depends on the running Core (warn, or accent on an older
    -- one). Resolve it the same way the implementation does rather than pinning
    -- a literal, so this suite tests the RULE and not the theme.
    local AMBER = D.BuffTimeToken("ony", 0)
    ck(AMBER ~= "ok" and AMBER ~= "danger", "the below-cutoff token is amber, not ok/danger")

    -- ---- coverage: every tracked buff has a class, and only the seasonal
    -- tail slot (thresholdKey = nil) is outside the rule ---------------------
    local outside = {}
    for slot, meta in pairs(D.AURA_META or {}) do
        local key = meta.thresholdKey
        if key and not D.BUFF_TIME_RULE[key] then
            outside[#outside + 1] = ("slot %d (%s)"):format(slot, key)
        end
    end
    ck(#outside == 0,
       "every threshold-bearing slot has a full-duration class; missing: "
       .. (table.concat(outside, ", ")))
    ck(D.BuffTimeToken(nil, 0) == nil,
       "a slot with no thresholdKey returns nil (caller keeps green/amber/red)")
    ck(D.BuffTimeToken("notARealBuff", 0) == nil, "an unknown key returns nil, never a colour")

    -- ---- 2h class: yellow under 90 min ------------------------------------
    local TWO_H = { "ony", "zg", "dmf", "dmtAP", "dmtSP", "dmtStam" }
    for _, k in ipairs(TWO_H) do
        ck(D.BUFF_TIME_RULE[k].full == 7200, k .. " is a 2h buff")
        ck(D.BuffTimeToken(k, 7200)     == "ok",    k .. " at full 2h -> green")
        ck(D.BuffTimeToken(k, 90 * 60)  == "ok",    k .. " at EXACTLY 90m -> green (not <)")
        ck(D.BuffTimeToken(k, 90 * 60 - 1) == AMBER, k .. " one second under 90m -> yellow")
        ck(D.BuffTimeToken(k, 60)       == AMBER,   k .. " at 1m -> yellow, NOT red")
        ck(D.BuffTimeToken(k, 0)        == AMBER,   k .. " at 0 -> yellow, NOT red")
    end

    -- ---- 1h class: yellow under 55 min ------------------------------------
    for _, k in ipairs({ "rend", "songflower" }) do
        ck(D.BUFF_TIME_RULE[k].full == 3600, k .. " is a 1h buff")
        ck(D.BuffTimeToken(k, 3600)     == "ok",    k .. " at full 1h -> green")
        ck(D.BuffTimeToken(k, 55 * 60)  == "ok",    k .. " at EXACTLY 55m -> green")
        ck(D.BuffTimeToken(k, 55 * 60 - 1) == AMBER, k .. " one second under 55m -> yellow")
        -- Cross-class: a 1h buff at 60m must NOT be judged by the 2h cutoff.
        ck(D.BuffTimeToken(k, 60 * 60)  == "ok",
           k .. " at 60m is GREEN (the 90m cutoff belongs to 2h buffs)")
    end

    -- ---- Battle Shout: the 15-minute NPC cast (spell 25101) ---------------
    ck(D.BUFF_TIME_RULE.battleShout.full == 900,
       "battleShout is the 15-minute NPC buff, not the 2-minute self-cast")
    ck(D.BuffTimeToken("battleShout", 900)      == "ok",    "BS at full 15m -> green")
    ck(D.BuffTimeToken("battleShout", 12 * 60)  == "ok",    "BS at EXACTLY 12m -> green")
    ck(D.BuffTimeToken("battleShout", 12 * 60 - 1) == AMBER, "BS one second under 12m -> yellow")
    ck(D.BuffTimeToken("battleShout", 60)       == AMBER,   "BS at 1m -> yellow, NOT red")
    -- Cross-class: BS at 30m (impossible in game, but a boon-parse artefact can
    -- produce it) must not borrow the 1h/2h cutoffs.
    ck(D.BuffTimeToken("battleShout", 30 * 60)  == "ok", "BS above its own cutoff is green")

    -- The slot that carries the rule really is spell 25101 on both sides.
    local bs = D.AURA_META and D.AURA_META[9]
    ck(bs and bs.thresholdKey == "battleShout" and bs.spellID == 25101,
       "AURA_META slot 9 is Battle Shout / thresholdKey battleShout / spell 25101")

    -- ---- NEVER RED while present, at any remaining, for every class -------
    -- Red belongs to MISSING now. This sweep is what fails loudly if the old
    -- three-band threshold path is ever re-wired into the present-buff branch.
    for key in pairs(D.BUFF_TIME_RULE) do
        for _, secs in ipairs({ 0, 1, 59, 300, 3599, 3600, 5399, 5400, 7199, 7200, 99999 }) do
            local tok = D.BuffTimeToken(key, secs)
            ck(tok == "ok" or tok == AMBER,
               ("%s at %ds must be green or yellow, never %s"):format(key, secs, tostring(tok)))
        end
    end

    -- Junk remaining must not throw or return red.
    ck(D.BuffTimeToken("ony", nil) == AMBER, "nil remaining reads as 0 -> yellow")
    ck(D.BuffTimeToken("ony", "banana") == AMBER, "non-numeric remaining reads as 0 -> yellow")
end

    ns:RegisterSelfTest("dashboard", function(verbose)
        local cases = {
            { name = "aura slot map agreement (tracker <-> AURA_META)", fn = testAuraSlotMap },
            { name = "aura class rules", fn = testAuraClassRules },
            { name = "fixed buff-time rule (settings rework item 4)", fn = testBuffTimeRule },
            { name = "cooldown decay", fn = testDecayRemaining },
            { name = "aura display decay (A6.8/A7.6)", fn = testAuraDisplayDecay },
            { name = "dmf schedule", fn = testDMFSchedule },
            { name = "online exclusivity", fn = testOnlineExclusivity },
            { name = "mesh presence + 15s window (A1.1/A1.2)", fn = testMeshPresence },
            { name = "cross-bucket roster dedup", fn = testRosterDedup },
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
