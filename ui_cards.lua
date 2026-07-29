-- Daseeki Nexus — ui_cards.lua
-- The LEFT column of the control-panel dashboard + the master/detail body grid.
--
-- NEXUS DIRECTION PIVOT (BRAND_SPEC 2026-07-29): control-panel style master/detail.
-- This file registers the "characters" screen and builds the whole Characters body:
--   LEFT 380  = 44px chip bar (scope + modifier chips, live counts) + a scrollable
--               compact CARD list (status dot · class name · acct tag · location ·
--               buff-icon strip · updated-ago). Click selects (instant), selection
--               shows a wax-accent edge, auto-selects the highest-sorted online
--               character (self first) on show, and FOLLOWS filters (if the selected
--               card is filtered out, the next visible card is selected).
--   1px divider (shared seam @ x=380).
--   RIGHT     = detail pane (316, top → ns.Detail) + timers dock (260, bottom →
--               ns.TimersDock).
-- It re-houses the proven roster logic from the retired ui_roster.lua (ns.Roster):
--   scope/modifier filtering, live counts and the deterministic sort — as pure,
--   headless-tested functions on ns.Cards. The open-entry register, the Card/Grid
--   toggle and the grid Coverage Board altitude RETIRE with the SN-silhouette
--   rehabilitation (coverage may return later as its own surface).
--
-- AESTHETIC (control-panel, §9/§10 + pivot): flat token fills, sharp 1px UI.Hairline
-- rules, hard column edges, uppercase microLabels. NO PaintLedgerGround/grain/serif.
-- All colors via theme tokens (the mockup renders Winterspring-Frost token VALUES).
--
-- Clean-room build on our own DaseekiUI stack. No third-party code or identifiers.

local ADDON, ns = ...
local UI = DaseekiUI                 -- nil under the headless harness; only ever
local Dashboard = ns.Dashboard       -- dereferenced inside function bodies below.
local Cards = {}
ns.Cards = Cards

----------------------------------------------------------------------
-- Geometry (mockup nexus-controlpanel-notes.md — every value is law).
----------------------------------------------------------------------
local COL_W      = 380      -- left column width
local CHIP_H     = 44       -- chip bar height
local LIST_PAD   = 12       -- card list padding
local CARD_H     = 84       -- card height (round-4: +10 for the "Updated X ago" body line)
local CARD_GAP   = 6        -- gap between cards
local CARD_PAD_H = 11       -- card horizontal padding
local CARD_PAD_V = 9        -- card vertical padding
local TILE       = 18       -- buff strip tile edge
local TILE_GAP   = 3
local CD_ICON    = 15       -- chrono/hearth cooldown icon edge (right-edge stack)
local DETAIL_H   = 284      -- right-top detail pane height (round-4: was 316 — the
                            -- detail reserved a hollow band; shrink it and let the
                            -- dock take the reclaimed space so WORLD BUFF TIMERS rises).
-- dock fills the remaining 292 (576 - 284).

local STALE_AGE = 30 * 60

-- Chip definitions. Scope is single-select; modifiers are independent toggles. The
-- mockup renders the Online + Needs-buffs modifiers; Stale/Locked stay in the pure
-- model (counts + filtering) for future chips but are not drawn (owner cut-watch).
local SCOPE_DEFS = {
    { key = "all",       label = "All",       tip = "Every tracked character." },
    { key = "60s",       label = "60s",       tip = "Level 60 characters." },
    { key = "summoners", label = "Summoners", tip = "Warlocks." },
}
local MOD_DEFS = {
    { key = "online", label = "Online",      tip = "Currently online." },
    { key = "needs",  label = "Needs buffs", tip = "Missing at least one buff." },
    { key = "stale",  label = "Stale",       tip = "Data older than 30 min." },
    { key = "locked", label = "Locked",      tip = "Holding at least one raid lockout." },
}
local MOD_CHIPS = { "online", "needs" }   -- the modifiers rendered as chips (mockup)

----------------------------------------------------------------------
-- PURE roster logic (no UI — exercised headless by the "cards" self-test).
-- Re-housed verbatim from ui_roster.lua (ns.Roster), plus the NEW selection
-- state machine ResolveSelection (auto-select + filter-follows).
----------------------------------------------------------------------

local function raidKeys()
    return (ns.Store and ns.Store.RAID_KEYS) or { "Naxx", "AQ40", "BWL", "MC", "ZG", "AQ20", "Ony" }
end

function Cards.IsStale(rec, nowE)
    local upd = (rec and rec.lastDataUpdate) or 0
    if upd <= 0 then return true end
    return (nowE - upd) > STALE_AGE
end

function Cards.IsLocked(rec, nowE)
    local lk = rec and rec.raidLockouts
    if type(lk) ~= "table" then return false end
    for _, key in ipairs(raidKeys()) do
        local e = lk[key]
        if e and e > nowE then return true end
    end
    return false
end

function Cards.MissingCount(entry)
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

function Cards.NeedsBuffs(entry)
    return Cards.MissingCount(entry) > 0
end

function Cards.InScope(entry, scope)
    local rec = entry and entry.rec
    if scope == "60s" then return ((rec and rec.level) or 0) >= 60 end
    if scope == "summoners" then return rec and rec.classTag == "WARLOCK" or false end
    return true
end

function Cards.MatchesMods(entry, mods, nowE)
    mods = mods or {}
    if mods.online and not entry.online then return false end
    if mods.needs and not Cards.NeedsBuffs(entry) then return false end
    if mods.stale and not Cards.IsStale(entry.rec, nowE) then return false end
    if mods.locked and not Cards.IsLocked(entry.rec, nowE) then return false end
    return true
end

-- Deterministic sort: self first, then online-first, then account (numeric asc),
-- then name asc. Strict total order → stable/deterministic. `isSelf` stamped in gather.
local function acctNum(e) return tonumber(e.aid) or math.huge end
function Cards.SortEntries(entries)
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
--   counts.scope[k] = size of scope k within the whole roster (no mods),
--   counts.mod[k]   = within the ACTIVE scope, how many match modifier k alone.
function Cards.ComputeView(entries, scope, mods, nowE)
    entries = entries or {}
    local scoped, list = {}, {}
    for _, e in ipairs(entries) do
        if Cards.InScope(e, scope) then scoped[#scoped + 1] = e end
    end
    for _, e in ipairs(scoped) do
        if Cards.MatchesMods(e, mods, nowE) then list[#list + 1] = e end
    end
    list = Cards.SortEntries(list)

    local counts = { scope = {}, mod = {} }
    for _, def in ipairs(SCOPE_DEFS) do
        local n = 0
        for _, e in ipairs(entries) do if Cards.InScope(e, def.key) then n = n + 1 end end
        counts.scope[def.key] = n
    end
    for _, def in ipairs(MOD_DEFS) do
        local n = 0
        for _, e in ipairs(scoped) do
            if Cards.MatchesMods(e, { [def.key] = true }, nowE) then n = n + 1 end
        end
        counts.mod[def.key] = n
    end
    return list, counts
end

-- The SELECTION state machine (pure): given the currently-visible sorted list and
-- the current selection, return the nameRealm that SHOULD be selected.
--   * current selection still visible -> keep it.
--   * otherwise -> the highest-sorted visible entry (self/online-first, because the
--     list is already SortEntries-ordered) — this covers BOTH "auto-select highest
--     online on show" AND "selection follows filters (selected filtered out ->
--     select next visible)". Empty list -> nil.
function Cards.ResolveSelection(list, currentSel)
    if currentSel then
        for _, e in ipairs(list) do
            if e.nameRealm == currentSel then return currentSel end
        end
    end
    if list[1] then return list[1].nameRealm end
    return nil
end

function Cards.IsSelf(nameRealm)
    if not nameRealm then return false end
    local me = UnitName and UnitName("player")
    if not me then return false end
    return (nameRealm:match("^([^%-]+)") or nameRealm) == me
end

-- State + abstract-pip/tile token for a buff slot (attention model). §5a lit=have on
-- the real ICON tiles: present -> owned; missing required -> danger; missing optional
-- -> warn; non-applicable -> faint (hidden).
--   present -> "owned","idle" ; missing(req) -> "missing","danger"
--   missing(opt) -> "warn","warn" ; non-applicable -> "na","faint"
function Cards.SlotState(entry, slot)
    local rec = entry.rec
    local st = rec.auraStates and rec.auraStates[slot]
    local present = st and (st.duration or 0) > 0
    local applicable, requirement = Dashboard.AuraRequirement(slot, rec, entry.faction or rec.faction)
    if present then return "owned", "idle" end
    if not applicable then return "na", "faint" end
    if requirement == "optional" then return "warn", "warn" end
    return "missing", "danger"
end

-- COMPACT CARD-STRIP tile style (owner round-2 §5b, corrected): tiles DOUBLE-ENCODE
-- state — the icon keeps §5a lit/desat (held = full-color, missing = desaturated)
-- AND every tile gets a state BORDER (held = ok-green, missing = danger-red / warn
-- for optional), matching the reference. Returns:
--   { shown, desat (bool), border (token), state }  -- shown=false for a hidden slot.
-- (The DETAIL pane's larger tiles use their own BuffTileState paint; this is the
-- compact strip's dedicated, headless-tested style matrix.)
function Cards.StripTileStyle(entry, slot)
    local state, token = Cards.SlotState(entry, slot)
    if state == "na" then return { shown = false, state = state } end
    local owned = (state == "owned")
    return {
        shown  = true,
        state  = state,
        desat  = not owned,                 -- §5a: held lit, missing desaturated
        border = owned and "ok" or token,   -- held green, missing danger/warn
    }
end

-- Compact "updated ago" text + stale flag ("2m"/"41m"/"2h"/"1d"; ""/false if none).
function Cards.AgoText(rec, nowE)
    local upd = (rec and rec.lastDataUpdate) or 0
    if upd <= 0 then return "\226\128\148", true end
    local age = math.max(0, nowE - upd)
    local txt
    if age < 60 then txt = age .. "s"
    elseif age < 3600 then txt = math.floor(age / 60) .. "m"
    elseif age < 86400 then txt = math.floor(age / 3600) .. "h"
    else txt = math.floor(age / 86400) .. "d" end
    return txt, (age > STALE_AGE)
end

-- Freshness ink cools with staleness (visual wear-as-meaning).
local function freshToken(rec, nowE)
    local upd = (rec and rec.lastDataUpdate) or 0
    if upd <= 0 then return "faint" end
    local age = nowE - upd
    if age < 10 * 60 then return "muted" end
    if age < STALE_AGE then return "faint" end
    return "idle"
end

-- Struck = blacklisted / tombstoned name (rendered with a strike overlay).
function Cards.IsStruck(nameRealm)
    local st = Dashboard and Dashboard.UIState and Dashboard.UIState()
    local bl = st and st.blacklist
    return (bl and bl[nameRealm]) and true or false
end

-- ════════════════════════════════════════════════════════════════════════════
--  UI (in-game only; UI is non-nil there)
-- ════════════════════════════════════════════════════════════════════════════

local function tag(frame, id)
    if ns.Audit and ns.Audit.Tag and frame then ns.Audit.Tag(frame, id) end
    return frame
end
local function fstr(parent, key, justify)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    if justify then f:SetJustifyH(justify) end
    return f
end
local function now() return (Dashboard and Dashboard.Now and Dashboard.Now()) or (GetServerTime and GetServerTime()) or time() end

-- Pop pass (round-4): a class-colored NAME rendered a tier brighter — the class hue
-- lifted ~12% toward white so muddy classes (warlock/rogue) read on the dark ground,
-- returned as r,g,b for SetTextColor (class color is a sanctioned identity color).
local function brightName(classTag)
    local r, g, b = Dashboard.ClassColor(classTag)
    if not r then return UI.Color("text") end
    local t = 0.12
    return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

----------------------------------------------------------------------
-- A compact card (mockup .card anatomy). Pooled; :Populate(entry, selected).
----------------------------------------------------------------------
local function makeCard(parent, pane)
    local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
    card:SetHeight(CARD_H)
    card:RegisterForClicks("LeftButtonUp")
    -- Pop pass (round-4): resting card OUTLINE = borderLite (visible edge, like the
    -- reference's cards); selected = accent border + a raised fill + an accent WASH.
    UI.Skin(card, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color(self._sel and "raised" or "panel"))
        self:SetBackdropBorderColor(UI.Color(self._sel and "accent" or "borderLite"))
    end)
    -- Accent wash over the selected card (clearly distinct from a resting card).
    card.wash = card:CreateTexture(nil, "BACKGROUND")
    card.wash:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    card.wash:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -1, 1)
    card.wash:Hide()
    -- Selection accent edge (mockup .card.sel:before — a 3px accent bar).
    card.edge = card:CreateTexture(nil, "OVERLAY")
    card.edge:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
    card.edge:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
    card.edge:SetWidth(3); card.edge:Hide()

    -- Right edge: chrono + hearth cooldown icons, stacked (owner round-2 item 5 —
    -- the pre-rebuild cards + the reference cards carry these). Same data the detail
    -- pane shows. Small (CD_ICON) so the card stays compact.
    local function cdIcon(topAnchor, dy)
        local f = CreateFrame("Frame", nil, card, "BackdropTemplate")
        f:SetSize(CD_ICON, CD_ICON)
        f:SetPoint("TOPRIGHT", topAnchor, dy and "BOTTOMRIGHT" or "TOPRIGHT",
            dy and 0 or -CARD_PAD_H, dy or -CARD_PAD_V)
        local ic = f:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        f.icon = ic
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self)
            if not self._tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(self._tip[1], UI.Color("text"))
            GameTooltip:AddLine(self._tip[2], UI.Color(self._tip[3] or "muted"))
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return f
    end
    card.chrono = cdIcon(card)                 -- top of the stack
    card.hearth = cdIcon(card.chrono, -2)      -- below chrono
    local CD_COL = CARD_PAD_H + CD_ICON + 6    -- horizontal room the stack reserves

    -- Row 1: dot + class-colored name + account tag + optional PvP crest (inline
    -- cluster; owner round-2 item 6 — acct stays inline by the name).
    card.dot = card:CreateTexture(nil, "OVERLAY")
    card.dot:SetSize(8, 8); card.dot:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PAD_H, -CARD_PAD_V - 3)
    -- Name: brightened class color + one font step up (pop pass). No right bound; the
    -- acct tag hugs the name (compact cards, short names).
    card.name = fstr(card, "body"); card.name:SetPoint("LEFT", card.dot, "RIGHT", 8, 0)
    card.name:SetJustifyH("LEFT"); card.name:SetWordWrap(false)
    do local f, sz, fl = card.name:GetFont(); if f then card.name:SetFont(f, (sz or 13) + 1, fl) end end
    card.acct = fstr(card, "microLabel"); card.acct:SetPoint("LEFT", card.name, "RIGHT", 6, 0)
    card.acct:SetTextColor(UI.Color("muted"))
    card.pvp = card:CreateTexture(nil, "ARTWORK")
    card.pvp:SetSize(13, 13); card.pvp:SetPoint("LEFT", card.acct, "RIGHT", 4, 0); card.pvp:Hide()
    -- Strike overlay for tombstoned/blacklisted names.
    card.strike = card:CreateTexture(nil, "OVERLAY")
    card.strike:SetHeight(1); card.strike:Hide()
    card.strike:SetPoint("LEFT", card.name, "LEFT", 0, 0)

    -- Row 2: location (left). Row 3: "Updated X ago" in the BODY, under the location
    -- (owner round-4 item 4 — off the right edge, which belongs to the CD stack).
    card.loc = fstr(card, "small"); card.loc:SetPoint("TOPLEFT", card.dot, "BOTTOMLEFT", 0, -6)
    card.loc:SetWordWrap(false)
    card.upd = fstr(card, "microLabel"); card.upd:SetPoint("TOPLEFT", card.loc, "BOTTOMLEFT", 0, -3)

    -- Row 3: buff-icon strip (real-icon tiles; §5a lit/desat + state border).
    card.tiles = {}
    for i = 1, 10 do
        local t = CreateFrame("Frame", nil, card, "BackdropTemplate")
        t:SetSize(TILE, TILE)
        if i == 1 then t:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", CARD_PAD_H, CARD_PAD_V)
        else t:SetPoint("LEFT", card.tiles[i - 1], "RIGHT", TILE_GAP, 0) end
        local ic = t:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", t, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t.icon = ic
        card.tiles[i] = t
    end

    card:SetScript("OnClick", function(self) if self._entry then pane._select(self._entry) end end)

    function card:Populate(entry, selected)
        self._entry = entry
        self._sel = selected and true or false
        local rec = entry.rec
        local nowE = now()
        self:SetBackdropColor(UI.Color(selected and "raised" or "panel"))
        self:SetBackdropBorderColor(UI.Color(selected and "accent" or "borderLite"))
        self.edge:SetShown(selected)
        if selected then self.edge:SetColorTexture(UI.Color("accent")) end
        -- Selected accent wash (clearly distinct from a resting card).
        self.wash:SetShown(selected)
        if selected then local ar, ag, ab = UI.Color("accent"); self.wash:SetColorTexture(ar, ag, ab, 0.10) end

        self.dot:SetColorTexture(UI.Color(entry.online and "ok" or "faint"))
        -- Name: short (realm stripped) in the brightened class hue (pop pass).
        self.name:SetText(Dashboard.ShortName(entry.nameRealm))
        self.name:SetTextColor(brightName(rec.classTag))
        self.acct:SetText((entry.aid and entry.aid ~= "" and ("#" .. entry.aid)) or "")

        local struck = Cards.IsStruck(entry.nameRealm)
        if struck then
            self.strike:Show()
            self.strike:SetColorTexture(UI.Color("danger"))
            self.strike:SetWidth(self.name:GetStringWidth() or 40)
        else
            self.strike:Hide()
        end

        -- Location reads at full `text` (pop pass — it's meaningful, not tertiary).
        local loc = rec.location
        if loc and loc ~= "" then
            self.loc:SetText(loc); self.loc:SetTextColor(UI.Color("text"))
        else
            self.loc:SetText("Unknown"); self.loc:SetTextColor(UI.Color("danger"))
        end
        -- "Updated X ago" in the body under the location (tertiary -> muted; warn stale).
        local ago, stale = Cards.AgoText(rec, nowE)
        self.upd:SetText("Updated " .. ago .. " ago")
        self.upd:SetTextColor(UI.Color(stale and "warn" or "muted"))

        -- PvP-flagged crest inline in the name/acct cluster.
        if rec.pvpFlagged and rec.faction then
            self.pvp:Show()
            self.pvp:SetTexture(Dashboard.FactionCrest(rec.faction))
            self.pvp:SetTexCoord(0.02, 0.62, 0.03, 0.63)
        else
            self.pvp:Hide()
        end

        -- Chrono / hearth cooldown icons (right-edge stack). Chrono: booned = lit +
        -- accent/danger rim; on use-CD = desat; else lit. Hearth: desat while on CD.
        self.chrono.icon:SetTexture(Dashboard.ItemIcon(184937))   -- Chronoboon Displacer
        self.hearth.icon:SetTexture(Dashboard.ItemIcon(6948))     -- Hearthstone
        local chronoRem = Dashboard.DecayRemaining(rec.itemCooldown, rec.lastDataUpdate, nowE)
        self.chrono:SetBackdrop(UI.FLAT_BACKDROP); self.chrono:SetBackdropColor(UI.Color("inset"))
        if rec.chronoboonActive then
            self.chrono:SetShown(true); self.chrono.icon:SetDesaturated(false)
            self.chrono:SetBackdropBorderColor(UI.Color((rec.boonCount or 0) == 0 and "danger" or "accent"))
            self.chrono._tip = { "Chronoboon Displacer", "Booned", "accent" }
        elseif chronoRem > 0 then
            self.chrono:SetShown(true); self.chrono.icon:SetDesaturated(true)
            self.chrono:SetBackdropBorderColor(UI.Color("border"))
            self.chrono._tip = { "Chronoboon Displacer", "CD " .. Dashboard.FormatDuration(chronoRem), "danger" }
        else
            self.chrono:SetShown(true); self.chrono.icon:SetDesaturated(false)
            self.chrono:SetBackdropBorderColor(UI.Color("controlBorder"))
            self.chrono._tip = { "Chronoboon Displacer", ("%d in bags"):format(rec.boonCount or 0), "muted" }
        end
        local hearthRem = Dashboard.DecayRemaining(rec.hearthstoneCD, rec.lastDataUpdate, nowE)
        self.hearth:SetBackdrop(UI.FLAT_BACKDROP); self.hearth:SetBackdropColor(UI.Color("inset"))
        self.hearth.icon:SetDesaturated(hearthRem > 0)
        self.hearth:SetBackdropBorderColor(UI.Color(hearthRem > 0 and "border" or "controlBorder"))
        self.hearth._tip = { "Hearthstone", hearthRem > 0 and ("CD " .. Dashboard.FormatDuration(hearthRem)) or "Ready",
                             hearthRem > 0 and "danger" or "ok" }

        -- Buff strip: real-icon tiles double-encoding state (§5b) — §5a lit/desat
        -- icon + a state border (held ok-green / missing danger-red / warn optional).
        local order = Dashboard.AURA_DISPLAY_ORDER or {}
        local ti = 0
        for _, slot in ipairs(order) do
            local sty = Cards.StripTileStyle(entry, slot)
            if sty.shown then
                ti = ti + 1
                local t = self.tiles[ti]
                if t then
                    t:Show()
                    t.icon:SetTexture(Dashboard.AuraIcon(slot))
                    t.icon:SetDesaturated(sty.desat)
                    t.icon:SetAlpha(sty.desat and 0.6 or 1)
                    t:SetBackdrop(UI.FLAT_BACKDROP)
                    t:SetBackdropColor(UI.Color("inset"))
                    t:SetBackdropBorderColor(UI.Color(sty.border))
                end
            end
        end
        for i = ti + 1, #self.tiles do self.tiles[i]:Hide() end
    end

    return card
end

----------------------------------------------------------------------
-- A chip (mockup .chip). scope = single-select filled accent; modifier = accent
-- outline. Shows a live count. :Apply(active, count).
----------------------------------------------------------------------
local function makeChip(parent, def, kind, pane)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetHeight(22)
    b._key, b._kind = def.key, kind
    local lbl = fstr(b, "microLabel"); lbl:SetPoint("LEFT", b, "LEFT", 9, 0)
    b._lbl = lbl
    local cnt = fstr(b, "microLabel"); cnt:SetPoint("LEFT", lbl, "RIGHT", 5, 0)
    b._cnt = cnt
    b:SetScript("OnEnter", function(self)
        if not def.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(def.tip, UI.Color("muted")); GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function()
        if kind == "scope" then pane.scope = def.key
        else pane.mods[def.key] = not pane.mods[def.key] end
        pane.obj.Refresh()
    end)
    function b:Apply(active, count)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self._lbl:SetText(def.label:upper())
        self._cnt:SetText(count and tostring(count) or "")
        -- Pop pass (round-4): inactive chip LABELS read at `text` (not muted); the
        -- outline is borderLite; the count stays a tertiary `muted`.
        if kind == "scope" then
            if active then
                self:SetBackdropColor(UI.Color("accent")); self:SetBackdropBorderColor(UI.Color("accent"))
                self._lbl:SetTextColor(UI.Color("ground")); self._cnt:SetTextColor(UI.Color("ground"))
            else
                self:SetBackdropColor(0, 0, 0, 0); self:SetBackdropBorderColor(UI.Color("borderLite"))
                self._lbl:SetTextColor(UI.Color("text")); self._cnt:SetTextColor(UI.Color("muted"))
            end
        else
            if active then
                local ar, ag, ab = UI.Color("accent")
                self:SetBackdropColor(ar, ag, ab, 0.18); self:SetBackdropBorderColor(UI.Color("accent"))
                self._lbl:SetTextColor(UI.Color("accent")); self._cnt:SetTextColor(UI.Color("accent"))
            else
                self:SetBackdropColor(0, 0, 0, 0); self:SetBackdropBorderColor(UI.Color("borderLite"))
                self._lbl:SetTextColor(UI.Color("text")); self._cnt:SetTextColor(UI.Color("muted"))
            end
        end
        -- Size to content (label + count + padding).
        local w = (self._lbl:GetStringWidth() or 20) + (count and ((self._cnt:GetStringWidth() or 0) + 5) or 0) + 18
        self:SetWidth(math.max(34, w))
    end
    return b
end

----------------------------------------------------------------------
-- The "characters" screen — the whole control-panel body.
----------------------------------------------------------------------
Dashboard.RegisterTab("characters", function(host)
    local pane = { scope = "all", mods = {}, _cards = {}, selected = nil, obj = {} }
    Cards._pane = pane

    -- Restore persisted selection (additive, optional).
    local persisted = Dashboard.UIState and Dashboard.UIState().selectedCharacter
    if persisted and persisted ~= "" then pane.selected = persisted end

    -- ── LEFT column (380) ────────────────────────────────────────────────────
    local col = CreateFrame("Frame", nil, host)
    col:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    col:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
    col:SetWidth(COL_W)
    tag(col, "cards.col")
    pane.col = col

    -- Vertical divider at the column's right edge (shared 1px seam @ x=380).
    local vdiv = host:CreateTexture(nil, "OVERLAY")
    vdiv:SetWidth(1)
    vdiv:SetPoint("TOPLEFT", col, "TOPRIGHT", 0, 0)
    vdiv:SetPoint("BOTTOMLEFT", col, "BOTTOMRIGHT", 0, 0)
    UI.Skin(vdiv, function(self) self:SetColorTexture(UI.Color("borderLite")) end)

    -- Chip bar (44) at the top of the left column.
    local chipbar = CreateFrame("Frame", nil, col)
    chipbar:SetPoint("TOPLEFT", col, "TOPLEFT", 0, 0)
    chipbar:SetPoint("TOPRIGHT", col, "TOPRIGHT", 0, 0)
    chipbar:SetHeight(CHIP_H)
    tag(chipbar, "cards.chipbar")
    pane.chipbar = chipbar
    local chipRule = UI.Hairline(col, { token = "borderLite" })
    chipRule:SetPoint("BOTTOMLEFT", chipbar, "BOTTOMLEFT", 0, 0)
    chipRule:SetPoint("BOTTOMRIGHT", chipbar, "BOTTOMRIGHT", 0, 0)

    -- Build chips: scope singles, a divider, then modifier toggles.
    pane._scopeChips, pane._modChips = {}, {}
    local x = LIST_PAD
    for _, def in ipairs(SCOPE_DEFS) do
        local c = makeChip(chipbar, def, "scope", pane)
        c._x = x; pane._scopeChips[def.key] = c; pane._scopeChips[#pane._scopeChips + 1] = c
    end
    for _, key in ipairs(MOD_CHIPS) do
        local def
        for _, d in ipairs(MOD_DEFS) do if d.key == key then def = d end end
        local c = makeChip(chipbar, def, "mod", pane)
        pane._modChips[key] = c; pane._modChips[#pane._modChips + 1] = c
    end
    -- A small vertical divider texture between scope and modifier groups.
    local chipSep = chipbar:CreateTexture(nil, "OVERLAY")
    chipSep:SetSize(1, 18)
    UI.Skin(chipSep, function(self) self:SetColorTexture(UI.Color("borderLite")) end)
    pane._chipSep = chipSep

    -- ── Card list (scroll) ───────────────────────────────────────────────────
    local listScroll = CreateFrame("ScrollFrame", nil, col)
    listScroll:SetPoint("TOPLEFT", col, "TOPLEFT", LIST_PAD, -(CHIP_H + LIST_PAD))
    listScroll:SetPoint("BOTTOMRIGHT", col, "BOTTOMRIGHT", -LIST_PAD, LIST_PAD)
    listScroll:SetClipsChildren(true)
    listScroll:EnableMouseWheel(true)
    tag(listScroll, "cards.list")
    local listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(1, 1); listScroll:SetScrollChild(listChild)
    listScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, listChild:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 34)))
    end)
    pane._listScroll, pane._listChild = listScroll, listChild
    local emptyFS = fstr(listChild, "muted"); emptyFS:SetPoint("TOPLEFT", listChild, "TOPLEFT", 2, -2)
    emptyFS:SetText("No characters tracked."); emptyFS:Hide()
    pane._emptyFS = emptyFS

    -- ── RIGHT column: detail (316, top) + dock (260, bottom) ─────────────────
    local detailHost = CreateFrame("Frame", nil, host)
    detailHost:SetPoint("TOPLEFT", col, "TOPRIGHT", 1, 0)
    detailHost:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
    detailHost:SetHeight(DETAIL_H)
    tag(detailHost, "detail.pane")
    pane.detailHost = detailHost

    local dockHost = CreateFrame("Frame", nil, host)
    dockHost:SetPoint("TOPLEFT", detailHost, "BOTTOMLEFT", 0, 0)
    dockHost:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
    tag(dockHost, "dock.pane")
    pane.dockHost = dockHost

    -- Seam hairline between detail and dock (the 1px divider).
    local seam = UI.Hairline(host, { token = "borderLite" })
    seam:SetPoint("TOPLEFT", detailHost, "BOTTOMLEFT", 0, 0)
    seam:SetPoint("TOPRIGHT", detailHost, "BOTTOMRIGHT", 0, 0)

    pane.detail = ns.Detail and ns.Detail.Attach and ns.Detail.Attach(detailHost) or nil
    pane.dock   = ns.TimersDock and ns.TimersDock.Attach and ns.TimersDock.Attach(dockHost) or nil

    -- ── Selection ────────────────────────────────────────────────────────────
    -- Apply a selection: persist, fire the selection event, swap the detail.
    function pane._applySelection(entry)
        pane.selected = entry and entry.nameRealm or nil
        local st = Dashboard.UIState and Dashboard.UIState()
        if st then st.selectedCharacter = pane.selected or "" end
        ns:Fire("NEXUS_SELECT", pane.selected)
        if pane.detail then pane.detail:Show(entry) end
    end
    -- Click handler: select + re-highlight the cards (no full regather needed).
    function pane._select(entry)
        pane._applySelection(entry)
        for _, c in ipairs(pane._cards) do
            if c._entry then c:Populate(c._entry, c._entry.nameRealm == pane.selected) end
        end
    end

    local function getCard(i)
        local c = pane._cards[i]
        if not c then c = makeCard(listChild, pane); pane._cards[i] = c end
        return c
    end

    -- ── Refresh: gather → view → resolve selection → render ──────────────────
    function pane.obj.Refresh()
        local faction = Dashboard.GetFaction()
        local entries = Dashboard.GatherRoster(faction, { includeHomeless = true }) or {}
        for _, e in ipairs(entries) do
            e.faction = faction
            e.isSelf = Cards.IsSelf(e.nameRealm)
        end
        local nowE = now()
        local list, counts = Cards.ComputeView(entries, pane.scope, pane.mods, nowE)

        -- Chip states + counts.
        for _, def in ipairs(SCOPE_DEFS) do
            pane._scopeChips[def.key]:Apply(pane.scope == def.key, counts.scope[def.key])
        end
        for _, key in ipairs(MOD_CHIPS) do
            pane._modChips[key]:Apply(pane.mods[key] and true or false, counts.mod[key])
        end
        -- Lay chips left-to-right (widths are content-sized in :Apply).
        local cx = LIST_PAD
        for _, c in ipairs(pane._scopeChips) do
            c:ClearAllPoints(); c:SetPoint("LEFT", chipbar, "LEFT", cx, 0); cx = cx + c:GetWidth() + 5
        end
        pane._chipSep:ClearAllPoints(); pane._chipSep:SetPoint("LEFT", chipbar, "LEFT", cx + 1, 0); cx = cx + 8
        for _, c in ipairs(pane._modChips) do
            c:ClearAllPoints(); c:SetPoint("LEFT", chipbar, "LEFT", cx, 0); cx = cx + c:GetWidth() + 5
        end

        -- Selection follows the filter (auto-select highest / next visible).
        local resolved = Cards.ResolveSelection(list, pane.selected)
        if resolved ~= pane.selected then
            local entry
            for _, e in ipairs(list) do if e.nameRealm == resolved then entry = e end end
            pane._applySelection(entry)
        else
            -- Keep the detail current for the (unchanged) selection's data.
            if pane.detail and resolved then
                for _, e in ipairs(list) do if e.nameRealm == resolved then pane.detail:Show(e); break end end
            elseif pane.detail and not resolved then
                pane.detail:Show(nil)
            end
        end

        -- Render the card list.
        local W = listScroll:GetWidth(); if W < 1 then W = COL_W - 2 * LIST_PAD end
        listChild:SetWidth(W)
        for _, c in ipairs(pane._cards) do c:Hide() end
        local y = 0
        for i, entry in ipairs(list) do
            local c = getCard(i)
            c:ClearAllPoints(); c:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -y); c:SetWidth(W)
            c:Populate(entry, entry.nameRealm == pane.selected)
            c:Show()
            y = y + CARD_H + CARD_GAP
        end
        listChild:SetHeight(math.max(y, 1))
        pane._emptyFS:SetShown(#list == 0)

        -- Keep the dock's live world-buff readouts current on engine events too
        -- (its own 1s ticker also drives it; this makes timer events immediate).
        if pane.dock and pane.dock.Refresh then pane.dock.Refresh() end
    end

    listScroll:SetScript("OnSizeChanged", function() pane.obj.Refresh() end)
    pane.obj.Refresh()
    return pane.obj
end)

-- ════════════════════════════════════════════════════════════════════════════
--  SELF-TEST  (suite "cards"): the surviving roster display suites — chip
--  filtering, live counts, deterministic sort, buff SlotState — plus the NEW
--  selection state machine (ResolveSelection: auto-select + filter-follows) and
--  the compact AgoText. The open-entry / reflow / peek-anchor suites RETIRE.
-- ════════════════════════════════════════════════════════════════════════════

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

local function testCardsLogic(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local NOW = 1000000

    -- Stale / Locked primitives.
    ck(Cards.IsStale({ lastDataUpdate = NOW - 40 * 60 }, NOW) == true, "40m -> stale")
    ck(Cards.IsStale({ lastDataUpdate = NOW - 5 * 60 }, NOW) == false, "5m -> fresh")
    ck(Cards.IsStale({ lastDataUpdate = 0 }, NOW) == true, "no data -> stale")
    ck(Cards.IsLocked({ raidLockouts = { MC = NOW + 100 } }, NOW) == true, "future lockout -> locked")
    ck(Cards.IsLocked({ raidLockouts = { MC = NOW - 100 } }, NOW) == false, "expired lockout -> unlocked")

    -- Scope filter incl. the Summoners = warlock rule.
    local wlock = mkEntry("Lock-R", "1", { class = "WARLOCK", level = 60 })
    local war50 = mkEntry("War-R", "1", { class = "WARRIOR", level = 50 })
    ck(Cards.InScope(wlock, "summoners") == true, "warlock in summoners scope")
    ck(Cards.InScope(war50, "summoners") == false, "warrior not in summoners scope")
    ck(Cards.InScope(war50, "60s") == false, "level 50 not in 60s scope")
    ck(Cards.InScope(wlock, "60s") == true, "level 60 in 60s scope")

    -- ComputeView counts + filtering matrix.
    local entries = {
        mkEntry("Aaa-R", "2", { class = "WARLOCK", online = true, upd = NOW, locks = { MC = NOW + 500 } }),
        mkEntry("Bbb-R", "1", { class = "MAGE", online = true, upd = NOW - 60 * 60 }),   -- stale
        mkEntry("Ccc-R", "1", { class = "WARLOCK", online = false, upd = NOW, level = 50 }),
        mkEntry("Ddd-R", "3", { class = "PRIEST", online = false, upd = NOW - 45 * 60, locks = { ZG = NOW + 10 } }),
    }
    local list, counts = Cards.ComputeView(entries, "all", {}, NOW)
    ck(#list == 4, "all scope, no mods -> 4 rows (got " .. #list .. ")")
    ck(counts.scope.all == 4, "all count 4")
    ck(counts.scope.summoners == 2, "summoners (warlock) count 2")
    ck(counts.scope["60s"] == 3, "60s count 3 (one level-50)")
    ck(counts.mod.online == 2, "online count 2")
    ck(counts.mod.stale == 2, "stale count 2 (Bbb + Ddd)")
    ck(counts.mod.locked == 2, "locked count 2 (Aaa + Ddd)")

    local l2 = Cards.ComputeView(entries, "all", { online = true, locked = true }, NOW)
    ck(#l2 == 1 and l2[1].nameRealm == "Aaa-R", "online+locked -> only Aaa")
    local _, c3 = Cards.ComputeView(entries, "summoners", {}, NOW)
    ck(c3.mod.online == 1, "within summoners scope, online count 1 (Aaa)")

    -- Sort determinism: self first, then online, then account asc, then name.
    local se = {
        mkEntry("Zed-R", "1", { online = true }),
        mkEntry("Ann-R", "2", { online = true, isSelf = true }),
        mkEntry("Bob-R", "1", { online = true }),
        mkEntry("Cal-R", "1", { online = false }),
    }
    local sorted = Cards.SortEntries(se)
    ck(sorted[1].nameRealm == "Ann-R", "self sorts first")
    ck(sorted[2].nameRealm == "Bob-R", "then online acct1 name asc (Bob before Zed)")
    ck(sorted[3].nameRealm == "Zed-R", "online acct1 Zed second")
    ck(sorted[4].nameRealm == "Cal-R", "offline last")
    local sorted2 = Cards.SortEntries(sorted)
    for i = 1, #sorted do ck(sorted2[i].nameRealm == sorted[i].nameRealm, "sort idempotent @" .. i) end

    -- MissingCount / NeedsBuffs go through AuraRequirement (shell).
    local bare = mkEntry("Miss-R", "1", { class = "WARRIOR" })
    ck(Cards.NeedsBuffs(bare) == true, "bare warrior needs buffs")
    ck(Cards.MissingCount(bare) >= 1, "bare warrior missing >= 1")

    -- AgoText compact + stale flag.
    local a1, s1 = Cards.AgoText({ lastDataUpdate = NOW - 120 }, NOW)
    ck(a1 == "2m" and s1 == false, "2m ago, not stale")
    local a2, s2 = Cards.AgoText({ lastDataUpdate = NOW - 90 * 60 }, NOW)
    ck(a2 == "1h" and s2 == true, "90m ago -> '1h' + stale")
    local a3 = Cards.AgoText({ lastDataUpdate = 0 }, NOW)
    ck(a3 == "\226\128\148", "no data -> em-dash")
end

local function testSelectionMachine(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local list = {
        mkEntry("Ann-R", "1", { online = true, isSelf = true }),
        mkEntry("Bob-R", "1", { online = true }),
        mkEntry("Cal-R", "2", { online = false }),
    }
    list = Cards.SortEntries(list)
    -- Nothing selected -> auto-select the highest-sorted (self first).
    ck(Cards.ResolveSelection(list, nil) == "Ann-R", "no selection -> auto-select highest (self)")
    -- Selection present in view -> keep it.
    ck(Cards.ResolveSelection(list, "Bob-R") == "Bob-R", "visible selection kept")
    -- Selection filtered out -> follow to the next visible (highest-sorted).
    ck(Cards.ResolveSelection(list, "Zzz-R") == "Ann-R", "filtered-out selection -> next visible")
    -- Empty view -> nil.
    ck(Cards.ResolveSelection({}, "Bob-R") == nil, "empty view -> no selection")
    -- Filter-follows end-to-end: select Cal, then apply Online mod (Cal drops) ->
    -- ResolveSelection over the online-only view moves selection to a visible online.
    local NOW = 1000000
    local onlineOnly = Cards.ComputeView(list, "all", { online = true }, NOW)
    ck(Cards.ResolveSelection(onlineOnly, "Cal-R") == "Ann-R", "Online filter drops Cal -> selection follows to Ann")
end

local function testSlotState(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local D = Dashboard
    if not (D and D.AURA_META) then ck(false, "Dashboard.AURA_META unavailable"); return end
    local function slotOf(key) for s, m in pairs(D.AURA_META) do if m.key == key then return s end end end
    local onySlot = slotOf("ony")
    if onySlot then
        local ownedE = { faction = "Horde", rec = { classTag = "WARRIOR", auraStates = { [onySlot] = { duration = 3600 } } } }
        local missE  = { faction = "Horde", rec = { classTag = "WARRIOR", auraStates = {} } }
        local s1, t1 = Cards.SlotState(ownedE, onySlot)
        local s2, t2 = Cards.SlotState(missE, onySlot)
        ck(s1 == "owned" and t1 == "idle", "owned buff -> owned/idle")
        ck(s2 == "missing" and t2 == "danger", "missing required -> missing/danger")
    end
    local boonSlot = slotOf("boon")
    if boonSlot then
        local absentE = { faction = "Horde", rec = { classTag = "MAGE", auraStates = {} } }
        local s3, t3 = Cards.SlotState(absentE, boonSlot)
        ck(s3 == "na" and t3 == "faint", "non-applicable absent -> na/faint")
    end
    local rendSlot = slotOf("rend")
    if rendSlot then
        local savedGFS = ns.Store and ns.Store.GetFactionSettings
        ns.Store = ns.Store or {}
        ns.Store.GetFactionSettings = function()
            return { auraOpts = { rend = { required = {}, optional = { MAGE = true } }, thresholds = {} } }
        end
        local mageE = { faction = "Horde", rec = { classTag = "MAGE", auraStates = {} } }
        local s4, t4 = Cards.SlotState(mageE, rendSlot)
        ck(s4 == "warn" and t4 == "warn", "optional missing -> warn/warn")
        ns.Store.GetFactionSettings = savedGFS
    end
end

-- Compact card-strip DOUBLE-ENCODE matrix (owner round-2 §5b): every visible tile
-- carries BOTH a color state (lit/desat) AND a border state (ok/danger/warn).
local function testStripStyle(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local D = Dashboard
    if not (D and D.AURA_META) then ck(false, "Dashboard.AURA_META unavailable"); return end
    local function slotOf(key) for s, m in pairs(D.AURA_META) do if m.key == key then return s end end end
    local onySlot, boonSlot, rendSlot = slotOf("ony"), slotOf("boon"), slotOf("rend")

    -- Held required -> lit (desat=false) + ok-green border.
    if onySlot then
        local ownedE = { faction = "Horde", rec = { classTag = "WARRIOR", auraStates = { [onySlot] = { duration = 3600 } } } }
        local held = Cards.StripTileStyle(ownedE, onySlot)
        ck(held.shown and held.desat == false and held.border == "ok",
            "held tile -> shown + lit (desat=false) + ok border")
        -- Missing required -> desaturated + danger border.
        local missE = { faction = "Horde", rec = { classTag = "WARRIOR", auraStates = {} } }
        local miss = Cards.StripTileStyle(missE, onySlot)
        ck(miss.shown and miss.desat == true and miss.border == "danger",
            "missing required tile -> shown + desat + danger border")
    end
    -- Non-applicable absent tail slot -> hidden.
    if boonSlot then
        local na = Cards.StripTileStyle({ faction = "Horde", rec = { classTag = "MAGE", auraStates = {} } }, boonSlot)
        ck(na.shown == false, "non-applicable slot -> not shown in strip")
    end
    -- Optional missing -> desaturated + warn border.
    if rendSlot then
        local savedGFS = ns.Store and ns.Store.GetFactionSettings
        ns.Store = ns.Store or {}
        ns.Store.GetFactionSettings = function()
            return { auraOpts = { rend = { required = {}, optional = { MAGE = true } }, thresholds = {} } }
        end
        local opt = Cards.StripTileStyle({ faction = "Horde", rec = { classTag = "MAGE", auraStates = {} } }, rendSlot)
        ck(opt.shown and opt.desat == true and opt.border == "warn",
            "optional missing tile -> shown + desat + warn border")
        ns.Store.GetFactionSettings = savedGFS
    end
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("cards", function(verbose)
        local cases = {
            { name = "roster logic",      fn = testCardsLogic },
            { name = "selection machine", fn = testSelectionMachine },
            { name = "slot state",        fn = testSlotState },
            { name = "strip tile style",  fn = testStripStyle },
        }
        local allPass = true
        for _, c in ipairs(cases) do
            local f2 = {}
            local ok = pcall(c.fn, f2)
            local passed = ok and #f2 == 0
            if not passed then allPass = false end
            if verbose and ns and ns.Print then
                if passed then ns:Print("  PASS cards/" .. c.name)
                elseif not ok then ns:Print("  FAIL cards/" .. c.name .. " :: error in test")
                else for _, m in ipairs(f2) do ns:Print("  FAIL cards/" .. c.name .. " :: " .. m) end end
            end
        end
        return allPass
    end)
end
