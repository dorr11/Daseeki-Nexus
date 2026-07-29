-- Daseeki Nexus — ui_roster.lua
-- The "Characters" tab (BRAND_SPEC §7 "Field Ledger"): the only roster screen.
-- Replaces the old 60s + Summoners tabs with ONE adaptive-density register/grid
-- roster over the shared cross-account character model (ui_shell Dashboard.*).
--
-- Wave R1-A (ROSTER ENGINE). Sibling R1-B owns the open ledger PAGE and codes
-- against the Roster.* hosting contract published at the bottom of this file.
--
-- Design law honored here (see the compliance notes inline):
--   §5 diamond budget : ONE wax seal per row (online=brand-lit / offline=idle).
--                       every other state = plain SQUARE pip; tally = ruled text;
--                       NO diamonds beyond the seal.
--   §7 structure      : register grammar `seal · name · acct · [7-raid tally] ·
--                       centered buff-tile strip · freshness`; Grid = Coverage
--                       Board (name + 10 square pips + buff-tile column headers).
--   §8 interaction    : WoW-native GameTooltip hover-peek (~200ms), ≤120ms reveal
--                       owned by R1-B, wheel scroll, no web idioms.
--   §9 open-entry     : ONE adaptive RosterRow path; open page hosted in the row's
--                       slot via a single (pageH−rowH) reflow with scroll clamp.
--   Attention inversion: owned/held/fine = calm `idle`; only MISSING/URGENT tints.
--
-- Clean-room: reimplements the roster on our own DaseekiUI/Ledger stack. No
-- third-party code or identifiers.

local ADDON, ns = ...
local UI = DaseekiUI                 -- nil under the headless harness; only ever
local Dashboard = ns.Dashboard       -- dereferenced inside function bodies below.
local Store = ns.Store

local Roster = {}
ns.Roster = Roster

----------------------------------------------------------------------
-- Metrics / density descriptors
----------------------------------------------------------------------

local REGISTER_ROW_H = 26
local GRID_ROW_H     = 22
local REG_GAP        = 3
local GRID_GAP       = 2
local PAD            = 8
local SEAL_SIZE      = 9      -- wax seal diamond edge (one per row — §5; +1 so online crimson reads clearly, §O)
local TILE           = 18     -- register buff-icon tile
local PIP            = 14     -- grid square coverage pip
local HDR_TILE       = 16     -- grid column-header buff tile
local NAME_W         = 140    -- grid name column (fixed; pips pack tight right after it — item F)
local PIP_PITCH      = 26     -- grid pip column pitch (tight fixed, NOT window-spread — item F)
local STALE_AGE      = 30 * 60

-- The adaptive-path facet map (Expert-C law: ONE row primitive, a density param).
-- `Roster.RowFields(density)` is the single source of which facets a row shows at
-- each altitude — the register/grid render path selects from THIS, never forks.
Roster.DENSITY = {
    register = {
        rowH = REGISTER_ROW_H, gap = REG_GAP,
        fields = { seal = true, name = true, acct = true, tally = true,
                   buffStrip = true, freshness = true, pips = false },
    },
    grid = {
        rowH = GRID_ROW_H, gap = GRID_GAP,
        fields = { seal = true, name = true, acct = false, tally = false,
                   buffStrip = false, freshness = false, pips = true },
    },
}
function Roster.RowFields(density)
    local d = Roster.DENSITY[density]
    return d and d.fields or nil
end

-- Ruled raid tally order (BRAND_SPEC §7 L3 grammar: raids as ruled text initials,
-- locked = bold cream / open = faint, NO raid diamonds). Keys match Store.RAID_KEYS.
local RAID_TALLY = {
    { k = "MC",   lbl = "MC"   },
    { k = "BWL",  lbl = "BWL"  },
    { k = "ZG",   lbl = "ZG"   },
    { k = "AQ40", lbl = "AQ40" },
    { k = "Naxx", lbl = "Naxx" },   -- item G: "Naxx" everywhere (register + open page)
    { k = "Ony",  lbl = "Ony"  },
    { k = "AQ20", lbl = "AQ20" },
}

-- Chip definitions. Scope is single-select; modifiers are independent toggles.
-- Summoners scope = warlock class filter (spec: the Summoners tab retires into the
-- chip system). Stale/Locked tooltips are the owner-locked exact strings.
local SCOPE_DEFS = {
    { key = "all",       label = "All",       tip = "Every tracked character." },
    { key = "60s",       label = "60s",       tip = "Level 60 characters." },
    { key = "summoners", label = "Summoners", tip = "Warlocks." },
}
local MOD_DEFS = {
    { key = "online", label = "Online", tip = "Currently online." },
    { key = "needs",  label = "Needs buffs", tip = "Missing at least one buff." },
    { key = "stale",  label = "Stale",  tip = "Data older than 30 min — hasn't synced recently." },
    { key = "locked", label = "Locked", tip = "Holding at least one raid lockout." },
}

----------------------------------------------------------------------
-- PURE roster logic (no UI — exercised headless by the "roster" self-test).
----------------------------------------------------------------------

local function raidKeys()
    return (Store and Store.RAID_KEYS) or { "Naxx", "AQ40", "BWL", "MC", "ZG", "AQ20", "Ony" }
end

-- Stale = data older than 30 min (no data at all also reads stale).
function Roster.IsStale(rec, nowE)
    local upd = (rec and rec.lastDataUpdate) or 0
    if upd <= 0 then return true end
    return (nowE - upd) > STALE_AGE
end

-- Locked = holding at least one un-expired raid lockout.
function Roster.IsLocked(rec, nowE)
    local lk = rec and rec.raidLockouts
    if type(lk) ~= "table" then return false end
    for _, key in ipairs(raidKeys()) do
        local e = lk[key]
        if e and e > nowE then return true end
    end
    return false
end

-- Count of APPLICABLE tracked buffs that are missing (attention model shared with
-- the tile/pip render + the hover-peek). Uses the shell's AuraRequirement so the
-- roster agrees with the detail panel on applicability.
function Roster.MissingCount(entry)
    local rec = entry and entry.rec
    if not rec then return 0 end
    local faction = entry.faction or rec.faction
    local order = (Dashboard and Dashboard.AURA_DISPLAY_ORDER) or {}
    local n = 0
    for _, slot in ipairs(order) do
        local st = rec.auraStates and rec.auraStates[slot]
        local present = st and (st.duration or 0) > 0
        local applicable = Dashboard.AuraRequirement(slot, rec, faction)
        if applicable and not present then n = n + 1 end
    end
    return n
end

function Roster.NeedsBuffs(entry)
    return Roster.MissingCount(entry) > 0
end

function Roster.InScope(entry, scope)
    local rec = entry and entry.rec
    if scope == "60s" then return ((rec and rec.level) or 0) >= 60 end
    if scope == "summoners" then return rec and rec.classTag == "WARLOCK" or false end
    return true   -- "all"
end

-- AND-combine the active modifier toggles.
function Roster.MatchesMods(entry, mods, nowE)
    mods = mods or {}
    if mods.online and not entry.online then return false end
    if mods.needs and not Roster.NeedsBuffs(entry) then return false end
    if mods.stale and not Roster.IsStale(entry.rec, nowE) then return false end
    if mods.locked and not Roster.IsLocked(entry.rec, nowE) then return false end
    return true
end

-- Deterministic sort: self first, then online-first, then account (numeric asc),
-- then name asc (spec §7 "AUTO-OPEN the highest-sorted ONLINE character (self
-- first)" + "sort online-first then account/name, stable"). The comparator is a
-- strict total order, so the result is stable/deterministic without relying on
-- table.sort stability. `e.isSelf` is stamped during gather.
local function acctNum(e)
    return tonumber(e.aid) or math.huge
end
function Roster.SortEntries(entries)
    local out = {}
    for i = 1, #entries do out[i] = entries[i] end
    table.sort(out, function(a, b)
        local as, bs = a.isSelf and true or false, b.isSelf and true or false
        if as ~= bs then return as end
        local ao, bo = a.online and true or false, b.online and true or false
        if ao ~= bo then return ao end
        local aa, ba = acctNum(a), acctNum(b)
        if aa ~= ba then return aa < ba end
        return (a.nameRealm or "") < (b.nameRealm or "")
    end)
    return out
end

-- The filter + count model. Returns (sortedFilteredList, counts) where
--   counts.scope[k] = size of scope k within the whole faction roster (no mods),
--   counts.mod[k]   = within the ACTIVE scope, how many match modifier k alone.
-- (Mockup rule: "every badge recounts within active scope".)
function Roster.ComputeView(entries, scope, mods, nowE)
    entries = entries or {}
    local scoped, list = {}, {}
    for _, e in ipairs(entries) do
        if Roster.InScope(e, scope) then scoped[#scoped + 1] = e end
    end
    for _, e in ipairs(scoped) do
        if Roster.MatchesMods(e, mods, nowE) then list[#list + 1] = e end
    end
    list = Roster.SortEntries(list)

    local counts = { scope = {}, mod = {} }
    for _, def in ipairs(SCOPE_DEFS) do
        local n = 0
        for _, e in ipairs(entries) do if Roster.InScope(e, def.key) then n = n + 1 end end
        counts.scope[def.key] = n
    end
    for _, def in ipairs(MOD_DEFS) do
        local n = 0
        for _, e in ipairs(scoped) do
            if Roster.MatchesMods(e, { [def.key] = true }, nowE) then n = n + 1 end
        end
        counts.mod[def.key] = n
    end
    return list, counts
end

-- Pure mirror of the open-entry reflow (Expert-C condition 3: rows below re-anchor
-- by a single (pageH − rowH) delta; recompute child height; clamp/nudge scroll so
-- the opened entry is never clipped). The live layout walks cumulative Y (same
-- result); this is the testable form with mock heights.
function Roster.ReflowMath(openIndex, rowH, gap, pageH, count, scrollTop, viewH)
    local pitch = rowH + gap
    local openTop = (openIndex - 1) * pitch
    local openBottom = openTop + pageH
    local delta = pageH - rowH
    local childH = count * pitch + delta
    local maxScroll = math.max(0, childH - viewH)
    local st = scrollTop or 0
    if openBottom > st + viewH then st = openBottom - viewH end   -- nudge up if below fold
    if openTop < st then st = openTop end                         -- nudge down if above
    if st < 0 then st = 0 end
    if st > maxScroll then st = maxScroll end
    return {
        delta = delta, pitch = pitch, openTop = openTop, openBottom = openBottom,
        childH = childH, scrollTop = st, maxScroll = maxScroll,
    }
end

-- Is a Name-Realm this player's current character? (self-priority for auto-open).
function Roster.IsSelf(nameRealm)
    if not nameRealm then return false end
    local me = UnitName and UnitName("player")
    if not me then return false end
    return (nameRealm:match("^([^%-]+)") or nameRealm) == me
end

----------------------------------------------------------------------
-- UI helpers (only reached in-game; UI is non-nil there).
----------------------------------------------------------------------

local function fstr(parent, fontKey)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[fontKey] or UI.fonts.body)
    return f
end

-- Freshness ink "cools" with staleness (visual wear-as-meaning, §4).
local function freshToken(rec, nowE)
    local upd = (rec and rec.lastDataUpdate) or 0
    if upd <= 0 then return "faint" end
    local age = nowE - upd
    if age < 10 * 60 then return "muted" end
    if age < STALE_AGE then return "faint" end
    return "idle"
end

-- State + abstract-pip token for a buff slot on a character. The ABSTRACT square
-- pip (Coverage Board / grid) keeps BRAND_SPEC §5 attention-inversion: owned/held
-- = calm idle, MISSING = danger tint (required) / warn (optional), non-applicable
-- = faint. (§5a's WoW-native lit=have grammar applies to real spell-ICON tiles —
-- the register strip — NOT to these abstract pips.) Promoted onto Roster so the
-- headless harness can pin the mapping and catch any future inversion (item C).
--   present  -> "owned",   "idle"
--   missing (required) -> "missing", "danger"
--   missing (optional) -> "warn",    "warn"
--   non-applicable     -> "na",      "faint"
function Roster.SlotState(entry, slot)
    local rec = entry.rec
    local st = rec.auraStates and rec.auraStates[slot]
    local present = st and (st.duration or 0) > 0
    local applicable, requirement = Dashboard.AuraRequirement(slot, rec, entry.faction or rec.faction)
    if present then return "owned", "idle" end
    if not applicable then return "na", "faint" end
    if requirement == "optional" then return "warn", "warn" end
    return "missing", "danger"
end
local slotState = Roster.SlotState

----------------------------------------------------------------------
-- The ONE adaptive RosterRow (register + grid densities, one pooled frame set).
----------------------------------------------------------------------

local function makeRosterRow(parent, pane)
    local row = CreateFrame("Button", nil, parent)
    row:RegisterForClicks("LeftButtonUp")

    -- Flat row fill so text/numerals never sit on the ledger grain (§4 layering).
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)

    -- Hover highlight (WoW-native).
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    row.hl = hl

    -- ONE wax seal per row (§5 diamond budget). Token-drawn diamond, brand-lit when
    -- online / idle when offline.
    row.seal = Dashboard.MakeDiamond(row, SEAL_SIZE, "ARTWORK")
    row.seal:SetPoint("LEFT", row, "LEFT", PAD, 0)

    row.name  = fstr(row, "body");  row.name:SetWordWrap(false); row.name:SetJustifyH("LEFT")
    row.acct  = fstr(row, "microLabel"); row.acct:SetJustifyH("LEFT")
    row.tally = fstr(row, "small"); row.tally:SetWordWrap(false); row.tally:SetJustifyH("RIGHT")
    row.fresh = fstr(row, "small"); row.fresh:SetWordWrap(false); row.fresh:SetJustifyH("RIGHT")

    -- Register buff-icon strip (real spell icons, attention-inverted, CENTERED).
    row.strip = CreateFrame("Frame", nil, row)
    row.strip:SetPoint("CENTER", row, "CENTER", 0, 0)
    row.tiles = {}
    for i = 1, 10 do
        local t = CreateFrame("Frame", nil, row.strip, "BackdropTemplate")
        t:SetSize(TILE, TILE)
        local ic = t:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", t, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t.icon = ic
        t:EnableMouse(false)
        t:Hide()
        row.tiles[i] = t
    end

    -- Grid coverage pips (plain SQUARE color pips — §5). One per tracked buff slot.
    row.pips = {}
    for i = 1, 10 do
        local p = row:CreateTexture(nil, "ARTWORK")
        p:SetTexture("Interface\\Buttons\\WHITE8X8")
        p:SetSize(PIP, PIP)
        p:Hide()
        row.pips[i] = p
    end

    -- ONE hairline per register row region (§6 + Expert-C §1.5): a bottom rule.
    row.rule = UI.Hairline(row, { token = "border" })
    row.rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", PAD, 0)
    row.rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -PAD, 0)

    -- Hover-peek (§8): GameTooltip after ~200ms.
    local HOVER_DELAY = 0.2
    row:SetScript("OnEnter", function(self)
        self._hoverAt = GetTime()
        self._peekPending = true
        if C_Timer and C_Timer.After then
            C_Timer.After(HOVER_DELAY, function()
                if self._peekPending and self:IsMouseOver() and self._entry then
                    Roster.ShowPeek(self, self._entry)
                end
            end)
        end
    end)
    row:SetScript("OnLeave", function(self)
        self._peekPending = false
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- Click fires the hosting contract event (register + grid rows both fire).
    row:SetScript("OnClick", function(self)
        if not self._entry then return end
        ns:Fire("ROSTER_ROW_CLICKED", self._entry.nameRealm, self)
    end)

    -- Position + value the row for a density. `geom` carries the list width and,
    -- for grid, the pip column layout.
    function row:Populate(entry, density, geom)
        self._entry = entry
        local desc = Roster.DENSITY[density] or Roster.DENSITY.register
        local F = desc.fields
        local W = geom.width
        local nowE = Dashboard.Now()
        local rec = entry.rec

        self:SetHeight(desc.rowH)
        self.bg:SetColorTexture(UI.Color("panel"))
        self.hl:SetColorTexture(UI.Color("brand", 0.10))

        -- Seal — online brand-lit, offline idle-calm.
        Dashboard.SetDiamondColor(self.seal, entry.online and "brand" or "idle")

        -- Name (class-colored, always shown).
        self.name:ClearAllPoints()
        self.name:SetPoint("LEFT", self.seal, "RIGHT", 8, 0)
        self.name:SetText(Dashboard.ColoredName(entry.nameRealm, rec.classTag))

        -- Account tag (register only) — micro-label, uppercased by hand (no
        -- letter-spacing API). Subordinate to the name.
        if F.acct and entry.aid and entry.aid ~= "" then
            self.acct:ClearAllPoints()
            self.acct:SetPoint("LEFT", self.name, "RIGHT", 8, 0)
            self.acct:SetText(("#%s"):format(tostring(entry.aid):upper()))
            self.acct:SetTextColor(UI.Color("muted"))
            self.acct:Show()
        else
            self.acct:Hide()
        end

        -- Freshness (register only) — ink cools with staleness, right-aligned.
        if F.freshness then
            self.fresh:ClearAllPoints()
            self.fresh:SetPoint("RIGHT", self, "RIGHT", -PAD, 0)
            self.fresh:SetText(Dashboard.FreshnessText(rec.lastDataUpdate))
            self.fresh:SetTextColor(UI.Color(freshToken(rec, nowE)))
            self.fresh:Show()
        else
            self.fresh:Hide()
        end

        -- Ruled raid tally (register only): initials, locked = cream / open = faint.
        if F.tally then
            local parts = {}
            for _, r in ipairs(RAID_TALLY) do
                local expiry = rec.raidLockouts and rec.raidLockouts[r.k]
                local locked = expiry and expiry > nowE
                parts[#parts + 1] = Dashboard.Colored(r.lbl, locked and "text" or "faint")
            end
            self.tally:ClearAllPoints()
            self.tally:SetPoint("RIGHT", self.fresh, "LEFT", -12, 0)
            self.tally:SetText(table.concat(parts, " "))
            self.tally:Show()
        else
            self.tally:Hide()
        end

        -- Register buff strip (real icons, attention-inverted, centered). Non-
        -- applicable slots collapse so the strip stays tight.
        for _, t in ipairs(self.tiles) do t:Hide() end
        for _, p in ipairs(self.pips) do p:Hide() end
        if F.buffStrip then
            local placed = 0
            for _, slot in ipairs(Dashboard.AURA_DISPLAY_ORDER) do
                local state, token = slotState(entry, slot)
                if state ~= "na" then
                    placed = placed + 1
                    local t = self.tiles[placed]
                    t:ClearAllPoints()
                    t:SetPoint("LEFT", self.strip, "LEFT", (placed - 1) * (TILE + 3), 0)
                    t.icon:SetTexture(Dashboard.AuraIcon(slot))
                    t:SetBackdrop(UI.FLAT_BACKDROP)
                    if state == "owned" then
                        -- §5a: real spell icon = OWNED reads WoW-native full-color LIT.
                        -- Card-parity framed tile: flat RAISED backing + quiet cborder rim
                        -- (matches the open-page tiles), icon inset + cropped.
                        t.icon:SetDesaturated(false); t.icon:SetVertexColor(1, 1, 1); t.icon:SetAlpha(1)
                        t:SetBackdropColor(UI.Color("raised"))
                        t:SetBackdropBorderColor(UI.Color("controlBorder"))
                    else
                        -- §5a: MISSING = desaturated (unlit) icon + danger/warn EDGE.
                        t.icon:SetDesaturated(true); t.icon:SetVertexColor(1, 1, 1); t.icon:SetAlpha(0.85)
                        t:SetBackdropColor(UI.Color(token, 0.25))
                        t:SetBackdropBorderColor(UI.Color(token))
                    end
                    t:Show()
                end
            end
            self.strip:SetSize(math.max(1, placed * (TILE + 3) - 3), TILE)
            self.strip:Show()
        else
            self.strip:Hide()
        end

        -- Grid coverage pips (fixed 10 columns aligned to the header tiles). Owned
        -- = idle; missing = danger; optional = warn; non-applicable = faint.
        if F.pips then
            for i, slot in ipairs(Dashboard.AURA_DISPLAY_ORDER) do
                local p = self.pips[i]
                local col = geom.cols and geom.cols[i]
                if col then
                    local _, token = slotState(entry, slot)
                    p:SetColorTexture(UI.Color(token))
                    p:ClearAllPoints()
                    p:SetPoint("LEFT", self, "LEFT", col.x + (col.w - PIP) / 2, 0)
                    p:Show()
                end
            end
            -- Name column is fixed-width in grid so pips line up with headers.
            self.name:SetWidth(NAME_W)
        else
            self.name:SetWidth(0)   -- auto-size in register
        end
    end

    return row
end

----------------------------------------------------------------------
-- Hover-peek tooltip (§8 GameTooltip house style).
----------------------------------------------------------------------

-- Adaptive peek side (item D): default the tip to the RIGHT of the cursor; if the
-- cursor sits in the right band of the window the tip would clip the right edge,
-- so flip LEFT. Pure so the harness can pin the flip threshold.
function Roster.PeekAnchor(cursorX, screenW, frac)
    frac = frac or 0.6
    if screenW and screenW > 0 and cursorX and cursorX > screenW * frac then
        return "left"
    end
    return "right"
end

function Roster.ShowPeek(anchor, entry)
    if not (GameTooltip and entry and entry.rec) then return end
    local rec = entry.rec
    -- Anchor to the cursor and flip side near the right bound so the black tip box
    -- never gets cut off at the window edge (item D). Full-width rows made a plain
    -- ANCHOR_RIGHT clip every time.
    local screenW = (UIParent and UIParent.GetRight and UIParent:GetRight())
        or (GetScreenWidth and GetScreenWidth()) or 0
    local cx, cy = 0, 0
    if GetCursorPosition then
        local scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
        if not scale or scale == 0 then scale = 1 end
        cx, cy = GetCursorPosition()
        cx, cy = cx / scale, cy / scale
    end
    GameTooltip:SetOwner(anchor, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    if Roster.PeekAnchor(cx, screenW) == "left" then
        GameTooltip:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", cx - 12, cy)
    else
        GameTooltip:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx + 12, cy)
    end
    GameTooltip:AddLine(Dashboard.ColoredName(entry.nameRealm, rec.classTag) ..
        (entry.online and "  " .. Dashboard.Colored("online", "ok") or ""))
    local loc = (rec.location and rec.location ~= "" and rec.location)
        or Dashboard.Colored("Missing location", "danger")
    GameTooltip:AddDoubleLine("Location", loc, UI.Color("muted"), 1, 1, 1)
    local miss = Roster.MissingCount(entry)
    GameTooltip:AddDoubleLine("Buffs missing", tostring(miss),
        UI.Color("muted"), UI.Color(miss > 0 and "danger" or "ok"))
    GameTooltip:AddDoubleLine("Updated", Dashboard.FreshnessText(rec.lastDataUpdate):gsub("^Updated ", ""),
        UI.Color("muted"), UI.Color(freshToken(rec, Dashboard.Now())))
    GameTooltip:Show()
end

----------------------------------------------------------------------
-- Chip row (scope singles + modifier toggles, live counts + tooltips).
----------------------------------------------------------------------

local function makeChip(parent, def, kind, pane)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetHeight(20)
    b._def, b._kind = def, kind
    local lbl = b:CreateFontString(nil, "OVERLAY")
    lbl:SetFontObject(UI.fonts.microLabel)
    lbl:SetPoint("LEFT", b, "LEFT", 8, 0)
    b._lbl = lbl

    b:SetScript("OnClick", function(self)
        if self._kind == "scope" then
            pane.scope = self._def.key
        else
            pane.mods[self._def.key] = not pane.mods[self._def.key] or nil
        end
        pane.obj.Refresh()
    end)
    b:SetScript("OnEnter", function(self)
        if not self._def.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(self._def.label, UI.Color("text"))
        GameTooltip:AddLine(self._def.tip, UI.Color("muted"), true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Paint by active state; label carries the live count. Uppercase by hand.
    -- Quiet, low-chrome pills (annot round-2 pin 3 / mockup .chip intent): inactive =
    -- muted text on a barely-raised fill with NO visible border (edge blended into the
    -- fill); active = a brand-TINTED wash (not a solid crimson block) + cream text +
    -- brandBright count. The count is a dimmer suffix, always. Reads like the approved
    -- mockup, not the old boxy bordered buttons.
    function b:Apply(active, count)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        if active then
            self:SetBackdropColor(UI.Color("brand", 0.28))        -- tinted wash over the panel
            self:SetBackdropBorderColor(UI.Color("brand", 0.55))  -- soft brand edge, no hard chrome
        else
            self:SetBackdropColor(UI.Color("raised"))             -- barely-raised fill
            self:SetBackdropBorderColor(UI.Color("raised"))       -- edge == fill => no visible border
        end
        self._lbl:SetText(("%s %s"):format(self._def.label:upper(),
            Dashboard.Colored(tostring(count or 0), active and "brandBright" or "faint")))
        self._lbl:SetTextColor(UI.Color(active and "text" or "muted"))
        local w = (self._lbl:GetStringWidth() or 40) + 16
        self:SetWidth(math.max(40, w))
    end
    return b
end

----------------------------------------------------------------------
-- Card ⇄ Grid density toggle (state persists; additive settings key).
----------------------------------------------------------------------

local function rosterUIState()
    local st = Dashboard.UIState()
    if st.rosterDensity ~= "grid" and st.rosterDensity ~= "card" then
        st.rosterDensity = "card"
    end
    return st
end

----------------------------------------------------------------------
-- Tab registration — the "Characters" screen.
----------------------------------------------------------------------

Dashboard.RegisterTab("characters", function(host)
    local obj = {}
    local pane = { obj = obj, scope = "all", mods = {}, rows = {}, list = {} }
    Roster._pane = pane

    -- Ledger ground for the whole content region (grain + vignette + the window's
    -- ONE bronze keyline flourish). Text lives on child frames with flat fills so
    -- glyphs never sit on grain (§4).
    local content = UI.FlatFrame(host, "ground", "border")
    content:SetAllPoints(host)
    UI.PaintLedgerGround(content, { keyline = true })
    pane.content = content

    -- Chip row (flat panel band; protects its own text from the grain).
    local chipRow = UI.FlatFrame(content, "panel", "border")
    chipRow:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD)
    chipRow:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -PAD)
    chipRow:SetHeight(28)

    pane.scopeChips, pane.modChips = {}, {}
    local x = 8
    for _, def in ipairs(SCOPE_DEFS) do
        local c = makeChip(chipRow, def, "scope", pane)
        c:SetPoint("LEFT", chipRow, "LEFT", x, 0)
        c:Apply(false, 0)
        x = x + c:GetWidth() + 5
        pane.scopeChips[#pane.scopeChips + 1] = c
    end
    -- Single-pixel separation between scope singles and modifier toggles (mockup
    -- .chipdiv — a 1px rule, not a glyph).
    local sep = chipRow:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(UI.Color("border"))
    sep:SetSize(1, 14)
    sep:SetPoint("LEFT", chipRow, "LEFT", x + 4, 0)
    x = x + 12
    for _, def in ipairs(MOD_DEFS) do
        local c = makeChip(chipRow, def, "mod", pane)
        c:SetPoint("LEFT", chipRow, "LEFT", x, 0)
        c:Apply(false, 0)
        x = x + c:GetWidth() + 5
        pane.modChips[#pane.modChips + 1] = c
    end

    -- Card ⇄ Grid toggle (header row, right-aligned).
    local hdr = CreateFrame("Frame", nil, content)
    hdr:SetPoint("TOPLEFT", chipRow, "BOTTOMLEFT", 0, -6)
    hdr:SetPoint("TOPRIGHT", chipRow, "BOTTOMRIGHT", 0, -6)
    hdr:SetHeight(GRID_ROW_H)
    pane.hdr = hdr

    -- Card ⇄ Grid segmented toggle (annot round-2 pin 3 / mockup .vseg): ONE quiet
    -- container with a soft bronze keyline (no heavy per-button chrome); two touching
    -- segments; the active segment carries a brand tint + brandBright label, the idle
    -- segment is transparent (shows the container fill) with muted text.
    local SEG_W, SEG_H = 46, 18
    local segWrap = UI.FlatFrame(hdr, "control", "controlBorder")
    segWrap:SetSize(SEG_W * 2 + 2, SEG_H + 2)
    segWrap:SetPoint("RIGHT", hdr, "RIGHT", -4, 0)
    UI.Skin(segWrap, function(self)
        self:SetBackdropColor(UI.Color("control"))
        self:SetBackdropBorderColor(UI.Color("bronzeDim", 0.55))
    end)
    pane.segWrap = segWrap

    local function densityBtn(label, key, side)   -- side: "left" | "right"
        local b = CreateFrame("Button", nil, segWrap, "BackdropTemplate")
        b:SetSize(SEG_W, SEG_H)
        if side == "right" then b:SetPoint("RIGHT", segWrap, "RIGHT", -1, 0)
        else                    b:SetPoint("LEFT", segWrap, "LEFT", 1, 0) end
        local t = b:CreateFontString(nil, "OVERLAY")
        t:SetFontObject(UI.fonts.microLabel)
        t:SetPoint("CENTER", b, "CENTER", 0, 0)
        t:SetText(label:upper())
        b._t, b._key = t, key
        b:SetScript("OnClick", function()
            rosterUIState().rosterDensity = key
            obj.Refresh()
        end)
        return b
    end
    -- Grid on the left, Card on the right (matches the mockup's Grid|Card order).
    local gridBtn = densityBtn("Grid", "grid", "left")
    local cardBtn = densityBtn("Card", "card", "right")
    pane.densityBtns = { card = cardBtn, grid = gridBtn }

    -- Grid column-header buff tiles (real icons), shown only in grid density; one
    -- header underline hairline (the grid's single ruled element).
    pane.hdrTiles = {}
    for i = 1, 10 do
        local t = CreateFrame("Frame", nil, hdr, "BackdropTemplate")
        t:SetSize(HDR_TILE, HDR_TILE)
        local ic = t:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", t, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t.icon = ic
        t:EnableMouse(true)
        t._slot = Dashboard.AURA_DISPLAY_ORDER[i]
        t:SetScript("OnEnter", function(self)
            local meta = Dashboard.AURA_META[self._slot]
            if not meta then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(meta.name, UI.Color("text"))
            GameTooltip:Show()
        end)
        t:SetScript("OnLeave", function() GameTooltip:Hide() end)
        t:Hide()
        pane.hdrTiles[i] = t
    end
    local nameHdr = hdr:CreateFontString(nil, "OVERLAY")
    nameHdr:SetFontObject(UI.fonts.microLabel)
    nameHdr:SetPoint("LEFT", hdr, "LEFT", PAD + SEAL_SIZE + 8, 0)
    nameHdr:SetText("CHARACTER"); nameHdr:SetTextColor(UI.Color("muted"))
    nameHdr:Hide()
    pane.nameHdr = nameHdr

    local hdrRule = UI.Hairline(hdr, { token = "border" })
    hdrRule:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", PAD, 0)
    hdrRule:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", -PAD, 0)
    pane.hdrRule = hdrRule

    -- Scroll list.
    local scroll = CreateFrame("ScrollFrame", nil, content)
    scroll:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
    scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD, PAD)
    scroll:SetClipsChildren(true)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 30)))
    end)
    pane.scroll, pane.child = scroll, child

    local emptyLabel = fstr(child, "muted")
    emptyLabel:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -4)
    emptyLabel:Hide()
    pane.emptyLabel = emptyLabel

    -- Column geometry for grid (pip columns aligned to header tiles).
    -- Coverage Board columns: name column is fixed, then the 10 pip columns at a
    -- TIGHT fixed pitch immediately after it — NOT spread across the whole window
    -- (item F: full-width spread destroyed scanability). Right side carries nothing.
    local function pipGeom(width)
        local x0 = PAD + SEAL_SIZE + 8 + NAME_W + 8
        local cols = {}
        for i = 1, 10 do cols[i] = { x = x0 + (i - 1) * PIP_PITCH, w = PIP_PITCH } end
        return cols
    end

    local function getRow(i)
        local r = pane.rows[i]
        if not r then
            r = makeRosterRow(child, pane)
            pane.rows[i] = r
        end
        return r
    end

    -- The single layout pass (data-refresh and open-entry reflow both call this).
    -- Walks cumulative Y; if a row is the open entry, its slot hosts the R1-B page
    -- frame instead (the row hides) and everything below shifts by the single
    -- (pageH − rowH) delta.
    --   reveal=true  → this is a fresh OPEN: nudge/clamp scroll so the page shows.
    --   reveal=false → steady repaint (ticker/data event): PRESERVE the user's
    --     scroll (only clamp to the valid range). The old code clamped-to-open on
    --     EVERY repaint, so with the top char auto-opened the register snapped back
    --     to the top a beat after any manual scroll (item L).
    local function layout(reveal)
        local density = rosterUIState().rosterDensity
        local dkey = (density == "grid") and "grid" or "register"
        local desc = Roster.DENSITY[dkey]
        local W = scroll:GetWidth(); if W < 1 then W = host:GetWidth() - 2 * PAD end
        child:SetWidth(W)
        local geom = { width = W, cols = (dkey == "grid") and pipGeom(W) or nil }

        for _, r in ipairs(pane.rows) do r:Hide() end
        local y, used = 0, 0
        local openTop, openBottom
        for _, entry in ipairs(pane.list) do
            if pane._openName and entry.nameRealm == pane._openName and pane._openPage then
                -- Host the open ledger page in this entry's slot (row stays hidden).
                openTop = y
                pane._openPage:ClearAllPoints()
                pane._openPage:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                pane._openPage:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                pane._openPage:Show()
                y = y + (pane._openPageH or desc.rowH) + desc.gap
                openBottom = openTop + (pane._openPageH or desc.rowH)
            else
                used = used + 1
                local r = getRow(used)   -- pooled rows reused deterministically by position
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                r:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                r:Populate(entry, dkey, geom)
                r:Show()
                y = y + desc.rowH + desc.gap
            end
        end
        child:SetHeight(math.max(y, 1))

        -- Scroll handling. Always clamp to the valid range (so a shrunk list can't
        -- strand the view past the bottom); only NUDGE toward the open entry on a
        -- fresh reveal (Expert-C cond 3) — never on steady repaints (item L).
        do
            local viewH = scroll:GetHeight()
            local maxScroll = math.max(0, child:GetHeight() - viewH)
            local stp = scroll:GetVerticalScroll()
            if reveal and openTop then
                if openBottom > stp + viewH then stp = openBottom - viewH end
                if openTop < stp then stp = openTop end
            end
            scroll:SetVerticalScroll(math.max(0, math.min(maxScroll, stp)))
        end

        -- Grid header tiles + name header on/off + positions.
        for i, t in ipairs(pane.hdrTiles) do
            local col = geom.cols and geom.cols[i]
            if dkey == "grid" and col then
                t.icon:SetTexture(Dashboard.AuraIcon(Dashboard.AURA_DISPLAY_ORDER[i]))
                t:SetBackdrop(UI.FLAT_BACKDROP)
                t:SetBackdropColor(UI.Color("raised"))            -- framed-tile parity with the rows
                t:SetBackdropBorderColor(UI.Color("controlBorder"))
                t:ClearAllPoints()
                t:SetPoint("LEFT", hdr, "LEFT", col.x + (col.w - HDR_TILE) / 2, 0)
                t:Show()
            else
                t:Hide()
            end
        end
        pane.nameHdr:SetShown(dkey == "grid")
    end
    pane.layout = layout
    pane.Reflow       = function() layout(false) end   -- release / steady reflow (preserve scroll)
    pane.RevealReflow = function() layout(true)  end   -- fresh open (nudge into view)

    -- A cheap signature of WHICH view we're showing. A change here (scope, active
    -- modifiers, or faction) is a real view change — it re-permits an auto-open and
    -- forces a full recompute; a plain data tick does not.
    local function viewKey(scope, mods, faction)
        local m = {}
        for _, def in ipairs(MOD_DEFS) do if mods[def.key] then m[#m + 1] = def.key end end
        return (faction or "?") .. "|" .. (scope or "?") .. "|" .. table.concat(m, ",")
    end

    function obj.Refresh()
        -- Density toggle paint (cheap; always). Active segment = brand tint (border ==
        -- fill, no chrome); idle segment = transparent so the container fill shows
        -- through. Quiet segmented look — mockup .vseg, not two boxy buttons.
        local density = rosterUIState().rosterDensity
        for key, b in pairs(pane.densityBtns) do
            local active = (key == density)
            b:SetBackdrop(UI.FLAT_BACKDROP)
            if active then
                b:SetBackdropColor(UI.Color("brand", 0.22))
                b:SetBackdropBorderColor(UI.Color("brand", 0.22))
            else
                b:SetBackdropColor(UI.Color("control", 0))
                b:SetBackdropBorderColor(UI.Color("control", 0))
            end
            b._t:SetTextColor(UI.Color(active and "brandBright" or "muted"))
        end

        local faction = Dashboard.GetFaction()
        local vk = viewKey(pane.scope, pane.mods, faction)
        local viewChanged = (vk ~= pane._lastViewKey)

        -- Per-tick cost audit (coordinator): the register is repainted ~1×/sec by
        -- the shared ticker. Re-gathering every account + re-sorting the whole
        -- roster on every one of those repaints was wasteful. Only do the full
        -- model recompute when something structural changed — a data event set the
        -- dirty flag, the view (scope/mods/faction) changed, or it's the first run.
        -- Otherwise take the LIGHT path: relayout in place (live buff/freshness
        -- fields read straight off the shared records, and scroll is preserved).
        local full = pane._dirty or viewChanged or not pane._listBuilt
        if not full then
            layout(false)
            return
        end
        pane._dirty = false
        pane._listBuilt = true
        if viewChanged then
            pane._lastViewKey = vk
            pane._autoOpened = false   -- a genuine scope/faction change may re-auto-open
        end

        -- Gather the faction roster (all accounts), stamp self + faction.
        local entries = Dashboard.GatherRoster(faction, { includeHomeless = true })
        for _, e in ipairs(entries) do
            e.faction = faction
            e.isSelf = Roster.IsSelf(e.nameRealm)
        end

        local nowE = Dashboard.Now()
        local list, counts = Roster.ComputeView(entries, pane.scope, pane.mods, nowE)
        pane.list = list

        -- Chip labels + active states.
        for _, c in ipairs(pane.scopeChips) do
            c:Apply(pane.scope == c._def.key, counts.scope[c._def.key])
        end
        for _, c in ipairs(pane.modChips) do
            c:Apply(pane.mods[c._def.key] and true or false, counts.mod[c._def.key])
        end

        -- Close the open page if its character is no longer in the visible set
        -- (item B: faction switch, an excluding filter, or any rebuild that drops
        -- the row). We EMIT — LedgerPage owns Close(), which releases our slot.
        local openKey = ns.LedgerPage and ns.LedgerPage.GetOpen and ns.LedgerPage.GetOpen()
        if openKey and not Roster.OpenEntryInView(openKey, list) then
            ns:Fire("ROSTER_CLOSE_OPEN_ENTRY", openKey)
        end

        layout(false)

        -- Empty state.
        if #list == 0 then
            pane.emptyLabel:SetText("No characters match.")
            pane.emptyLabel:Show()
        else
            pane.emptyLabel:Hide()
        end

        -- Auto-open the highest-sorted ONLINE character (self first). Fires once per
        -- view: the latch clears on show and on a real scope/faction change, NOT on
        -- every repaint. R1-B owns opening (it listens for ROSTER_ROW_CLICKED).
        if not pane._autoOpened and not pane._openName and #list > 0 and list[1].online then
            pane._autoOpened = true
            ns:Fire("ROSTER_ROW_CLICKED", list[1].nameRealm, pane.rows[1])
        end
    end

    -- Data-event dirty flags: a full recompute happens at most on the next tick
    -- after real store movement, never on the bare time ticker (item L cost audit).
    if ns.On then
        local function markDirty() pane._dirty = true end
        ns:On("STORE_REFRESHED", markDirty)
        ns:On("STATE_CHANGED",   markDirty)
        ns:On("NODE_UPDATED",    markDirty)
    end

    -- Reset auto-open + force a full rebuild each time the tab becomes visible.
    host:HookScript("OnShow", function() pane._autoOpened = false; pane._dirty = true end)
    scroll:SetScript("OnSizeChanged", function() obj.Refresh() end)

    return obj
end)

----------------------------------------------------------------------
-- OPEN-ENTRY HOSTING CONTRACT (R1-B codes against these verbatim).
--
--   Roster.HostOpenEntry(nameRealm, pageFrame, pageHeight)
--       Hide that character's register row and host `pageFrame` in its slot in
--       the scroll flow; reflow subsequent rows by the single (pageHeight − rowH)
--       delta; clamp/nudge scroll so the page is never clipped. One-open-max:
--       opening B closes A in the same frame.
--   Roster.ReleaseOpenEntry()
--       Restore the hidden row and reflow back.
--   Roster.RowPitch() -> current register row height.
--   Event "ROSTER_ROW_CLICKED"(nameRealm, rowFrame) fires on register + grid row
--       click, and once on show for the highest-sorted online character.
----------------------------------------------------------------------

function Roster.RowPitch()
    return REGISTER_ROW_H
end

function Roster.HostOpenEntry(nameRealm, pageFrame, pageHeight)
    local P = Roster._pane
    if not P or not nameRealm or not pageFrame then return end
    -- One-open-max: close any currently-open entry first (never two pages).
    if P._openName and P._openName ~= nameRealm then
        Roster.ReleaseOpenEntry()
    end
    P._openName  = nameRealm
    P._openPage  = pageFrame
    P._openPageH = pageHeight or (Roster.RowPitch() * 6)
    if pageFrame.SetParent then
        pageFrame:SetParent(P.child)
        -- The page inherits the scroll child's strata (it must NOT pin its own —
        -- see ui_ledgerpage Build) so the ScrollFrame scrolls AND clips it with the
        -- rows; raise its frame level so it still draws above the row fills (A).
        if pageFrame.SetFrameLevel and P.child and P.child.GetFrameLevel then
            pageFrame:SetFrameLevel((P.child:GetFrameLevel() or 0) + 5)
        end
    end
    -- Fresh open → nudge the page into view (reveal); steady reflows preserve scroll.
    if P.RevealReflow then P.RevealReflow() elseif P.Reflow then P.Reflow() end
end

-- Is the open character still present in the freshly computed view? (item B).
function Roster.OpenEntryInView(openKey, list)
    if not openKey then return true end
    for _, e in ipairs(list or {}) do
        if e.nameRealm == openKey then return true end
    end
    return false
end

function Roster.ReleaseOpenEntry()
    local P = Roster._pane
    if not P or not P._openName then return end
    if P._openPage and P._openPage.Hide then P._openPage:Hide() end
    P._openName, P._openPage, P._openPageH = nil, nil, nil
    if P.Reflow then P.Reflow() end
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; registered as suite "roster"). Covers the chip filter
-- matrix incl. counts, sort stability/determinism, HostOpenEntry reflow math with
-- mock heights, and adaptive-path row-field selection per density.
----------------------------------------------------------------------

local function mkEntry(name, aid, opts)
    opts = opts or {}
    return {
        nameRealm = name, aid = aid, online = opts.online and true or false,
        isSelf = opts.isSelf and true or false, faction = "Alliance",
        rec = {
            classTag = opts.class, level = opts.level or 60,
            lastDataUpdate = opts.upd, location = opts.loc,
            raidLockouts = opts.locks or {}, auraStates = opts.auras or {},
        },
    }
end

-- Abstract-pip inversion lock (item C) + open-entry view membership (item B) +
-- hover-peek anchor flip (item D). Kept in its own suite entry so the pip mapping
-- can never silently invert again.
local function testSlotStateAndAnchors(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local D = Dashboard
    if not (D and D.AURA_META) then ck(false, "Dashboard.AURA_META unavailable"); return end
    local function slotOf(key) for s, m in pairs(D.AURA_META) do if m.key == key then return s end end end

    -- ABSTRACT square pip = attention inversion: owned=idle(calm), MISSING=danger.
    local onySlot = slotOf("ony")     -- required-by-default (threshold-bearing)
    if onySlot then
        local ownedE = { faction = "Horde", rec = { classTag = "WARRIOR", auraStates = { [onySlot] = { duration = 3600 } } } }
        local missE  = { faction = "Horde", rec = { classTag = "WARRIOR", auraStates = {} } }
        local s1, tok1 = Roster.SlotState(ownedE, onySlot)
        local s2, tok2 = Roster.SlotState(missE,  onySlot)
        ck(s1 == "owned"   and tok1 == "idle",   "owned buff -> calm idle pip (NOT red)")
        ck(s2 == "missing" and tok2 == "danger", "missing required buff -> danger pip (NOT calm)")
    end
    local boonSlot = slotOf("boon")   -- tail, no threshold -> non-applicable when absent
    if boonSlot then
        local absentE = { faction = "Horde", rec = { classTag = "MAGE", auraStates = {} } }
        local s3, tok3 = Roster.SlotState(absentE, boonSlot)
        ck(s3 == "na" and tok3 == "faint", "non-applicable absent slot -> faint pip")
    end
    local rendSlot = slotOf("rend")   -- class-ruled; optional-for-MAGE via the stub
    if rendSlot then
        local savedGFS = ns.Store and ns.Store.GetFactionSettings
        ns.Store = ns.Store or {}
        ns.Store.GetFactionSettings = function()
            return { auraOpts = { rend = { required = {}, optional = { MAGE = true } }, thresholds = {} } }
        end
        local mageE = { faction = "Horde", rec = { classTag = "MAGE", auraStates = {} } }
        local s4, tok4 = Roster.SlotState(mageE, rendSlot)
        ck(s4 == "warn" and tok4 == "warn", "optional missing buff -> warn pip")
        ns.Store.GetFactionSettings = savedGFS
    end

    -- item B: OpenEntryInView drives the close-when-gone decision on rebuild.
    local list = { { nameRealm = "A-R" }, { nameRealm = "B-R" } }
    ck(Roster.OpenEntryInView("A-R", list) == true,  "open entry present -> stays open")
    ck(Roster.OpenEntryInView("Z-R", list) == false, "open entry gone from view -> close")
    ck(Roster.OpenEntryInView(nil, list) == true,    "nothing open -> trivially in view")

    -- item D: peek anchor flips left near the right bound, else right of cursor.
    ck(Roster.PeekAnchor(100, 1000) == "right", "cursor left of bound -> right anchor")
    ck(Roster.PeekAnchor(950, 1000) == "left",  "cursor near right bound -> left anchor (no clip)")
end

local function testRosterLogic(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local NOW = 1000000

    -- Stale / Locked primitives.
    ck(Roster.IsStale({ lastDataUpdate = NOW - 40 * 60 }, NOW) == true, "40m -> stale")
    ck(Roster.IsStale({ lastDataUpdate = NOW - 5 * 60 }, NOW) == false, "5m -> fresh")
    ck(Roster.IsStale({ lastDataUpdate = 0 }, NOW) == true, "no data -> stale")
    ck(Roster.IsLocked({ raidLockouts = { MC = NOW + 100 } }, NOW) == true, "future lockout -> locked")
    ck(Roster.IsLocked({ raidLockouts = { MC = NOW - 100 } }, NOW) == false, "expired lockout -> unlocked")
    ck(Roster.IsLocked({ raidLockouts = {} }, NOW) == false, "no lockouts -> unlocked")

    -- Scope filter incl. the Summoners = warlock rule.
    local wlock = mkEntry("Lock-R", "1", { class = "WARLOCK", level = 60 })
    local war50 = mkEntry("War-R", "1", { class = "WARRIOR", level = 50 })
    ck(Roster.InScope(wlock, "summoners") == true, "warlock in summoners scope")
    ck(Roster.InScope(war50, "summoners") == false, "warrior not in summoners scope")
    ck(Roster.InScope(war50, "60s") == false, "level 50 not in 60s scope")
    ck(Roster.InScope(wlock, "60s") == true, "level 60 in 60s scope")
    ck(Roster.InScope(war50, "all") == true, "everyone in all scope")

    -- ComputeView counts + filtering matrix.
    local entries = {
        mkEntry("Aaa-R", "2", { class = "WARLOCK", online = true, upd = NOW, locks = { MC = NOW + 500 } }),
        mkEntry("Bbb-R", "1", { class = "MAGE", online = true, upd = NOW - 60 * 60 }),   -- stale
        mkEntry("Ccc-R", "1", { class = "WARLOCK", online = false, upd = NOW, level = 50 }),
        mkEntry("Ddd-R", "3", { class = "PRIEST", online = false, upd = NOW - 45 * 60, locks = { ZG = NOW + 10 } }),
    }
    local list, counts = Roster.ComputeView(entries, "all", {}, NOW)
    ck(#list == 4, "all scope, no mods -> 4 rows (got " .. #list .. ")")
    ck(counts.scope.all == 4, "all count 4")
    ck(counts.scope.summoners == 2, "summoners (warlock) count 2")
    ck(counts.scope["60s"] == 3, "60s count 3 (one level-50)")
    ck(counts.mod.online == 2, "online count 2")
    ck(counts.mod.stale == 2, "stale count 2 (Bbb + Ddd)")
    ck(counts.mod.locked == 2, "locked count 2 (Aaa + Ddd)")

    -- Modifier AND-combine within scope.
    local l2 = Roster.ComputeView(entries, "all", { online = true, locked = true }, NOW)
    ck(#l2 == 1 and l2[1].nameRealm == "Aaa-R", "online+locked -> only Aaa")

    -- Summoners scope recomputes modifier counts within scope.
    local _, c3 = Roster.ComputeView(entries, "summoners", {}, NOW)
    ck(c3.mod.online == 1, "within summoners scope, online count 1 (Aaa)")

    -- Sort determinism: self first, then online, then account asc, then name.
    local se = {
        mkEntry("Zed-R", "1", { online = true }),
        mkEntry("Ann-R", "2", { online = true, isSelf = true }),   -- self
        mkEntry("Bob-R", "1", { online = true }),
        mkEntry("Cal-R", "1", { online = false }),
    }
    local sorted = Roster.SortEntries(se)
    ck(sorted[1].nameRealm == "Ann-R", "self sorts first")
    ck(sorted[2].nameRealm == "Bob-R", "then online acct1 name asc (Bob before Zed)")
    ck(sorted[3].nameRealm == "Zed-R", "online acct1 Zed second")
    ck(sorted[4].nameRealm == "Cal-R", "offline last")
    -- Idempotent (already-sorted input yields same order).
    local sorted2 = Roster.SortEntries(sorted)
    for i = 1, #sorted do ck(sorted2[i].nameRealm == sorted[i].nameRealm, "sort idempotent @" .. i) end

    -- Adaptive-path field selection per density.
    local rf = Roster.RowFields("register")
    local gf = Roster.RowFields("grid")
    ck(rf.acct == true and rf.tally == true and rf.buffStrip == true and rf.freshness == true and rf.pips == false,
        "register facets: acct/tally/strip/fresh on, pips off")
    ck(gf.pips == true and gf.acct == false and gf.tally == false and gf.buffStrip == false,
        "grid facets: pips on, register-only facets off")
    ck(rf.seal == true and gf.seal == true, "seal shown at both densities")

    -- HostOpenEntry reflow math with mock heights.
    -- 10 rows, rowH 26, gap 3 (pitch 29); open the 3rd with a 180px page; view 200.
    local rm = Roster.ReflowMath(3, 26, 3, 180, 10, 0, 200)
    ck(rm.pitch == 29, "pitch 29")
    ck(rm.delta == 180 - 26, "delta = pageH - rowH = 154")
    ck(rm.openTop == 2 * 29, "openTop = (idx-1)*pitch = 58")
    ck(rm.openBottom == 58 + 180, "openBottom = openTop + pageH = 238")
    ck(rm.childH == 10 * 29 + 154, "childH = count*pitch + delta = 444")
    -- Page bottom (238) exceeds view (0..200): scroll nudged up to keep it visible.
    ck(rm.scrollTop == 238 - 200, "scroll nudged so open page bottom is visible (38)")
    ck(rm.scrollTop <= rm.maxScroll, "scroll within max")
    -- Opening the first row (fits at top) leaves scroll at 0.
    local rm2 = Roster.ReflowMath(1, 26, 3, 120, 10, 0, 300)
    ck(rm2.scrollTop == 0, "first-row open, fits -> scroll 0")
    -- A page taller than the view nudges to its top (never leaves it clipped above).
    local rm3 = Roster.ReflowMath(5, 26, 3, 500, 10, 400, 200)
    ck(rm3.scrollTop == 4 * 29, "tall page open -> scroll to its top (116)")

    -- MissingCount / NeedsBuffs go through AuraRequirement (shell). A warrior with
    -- no auras: every required world buff is missing, so NeedsBuffs is true.
    local bare = mkEntry("Miss-R", "1", { class = "WARRIOR" })
    ck(Roster.NeedsBuffs(bare) == true, "bare warrior needs buffs")
    ck(Roster.MissingCount(bare) >= 1, "bare warrior missing >= 1")
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("roster", function(verbose)
        local fails = {}
        local ok1 = pcall(testRosterLogic, fails)
        local ok2 = pcall(testSlotStateAndAnchors, fails)
        local ok = ok1 and ok2
        local passed = ok and #fails == 0
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS roster/logic")
            elseif not ok then ns:Print("  FAIL roster/logic :: error in test")
            else for _, f in ipairs(fails) do ns:Print("  FAIL roster/logic :: " .. f) end end
        end
        return passed
    end)
end
