-- Daseeki Nexus — ui_professions.lua  (THE PROFESSIONS TAB, wave P2)
--
-- P1 gathered the facts and said nothing. This file is the saying: a dedicated
-- tab in the dashboard shell, peer to Characters, holding the four views the
-- design settled on —
--
--   THE GRID        one row per character in the SAME order the cards use,
--                   profession cells carrying icon + skill/cap + specialisation
--                   marker + the live cooldown state, secondaries in their own
--                   aligned sub-columns.
--
--   THE ROLLUP      every profession cooldown across every character, ready
--                   first then soonest. "What can I make today", answered
--                   without clicking anything.
--
--   THE DRILL-IN    click a profession cell and the tab becomes the two-pane
--                   list+editor shape the style guide mandates: that character's
--                   professions on the left (~300), the recipe list on the
--                   right with its filter band, and the selected recipe's
--                   SOURCE and MATERIALS underneath it.
--
--   THE SEARCH      "who can craft X" across every character's known set, with
--                   the learnable-by answer beside it.
--
----------------------------------------------------------------------
-- THE THIRD STATE IS THE WHOLE POINT, AND THIS FILE IS WHERE IT SHOWS
--
-- P1's contract is blunt: a profession with no `k` bitmap and no `a` stamp has
-- NEVER BEEN SCANNED, which is a different fact from "knows nothing", and
-- `Professions.KnownState()` returns "unknown"/"known"/"missing" — there is no
-- boolean form on purpose. Every surface in this file honours that:
--
--   * a never-scanned profession's recipe column renders an EM DASH and the
--     words "not checked", never 0 and never an empty list;
--   * a never-scanned profession contributes to NOTHING it cannot answer for:
--     it is not counted as missing in the drill-in, it is not "cannot craft" in
--     the search, and it never suppresses a row;
--   * a payload whose dataset version disagrees with ours decodes to nil, which
--     is ALSO unknown — a peer on a different build reads as unchecked rather
--     than as a confident list of the wrong recipes.
--
-- ProfUI.KnownSet() is the single reader. It returns (set|nil, state) and nil
-- ALWAYS means "we were not told", never "the answer is empty". The self-test
-- pins it against Professions.KnownState row for row, so the list path and the
-- single-recipe path can never drift into disagreeing.
--
----------------------------------------------------------------------
-- COLD NAMES (CLIENT_ASYNC_LESSONS class 6, the Daseeki-Bags precedent)
--
-- The dataset ships NO recipe names and no item names — the client resolves
-- both from ids, in the player's own language. On a fresh login the client may
-- not have answered yet, and Bags' ui_find.lua already paid for the lesson: a
-- pending id is an UNANSWERED QUESTION, not a miss. Scoring it as a miss is what
-- made a search say "nobody has this" about an item three alts were holding.
--
-- So: ids the resolver cannot answer are HELD. With a search active they are
-- excluded from the rows AND counted, and the surface says "still loading N
-- names…". With no search active the row still renders (we know the recipe
-- exists) wearing an ellipsis where its name goes. A bounded ladder re-asks and
-- re-renders as answers land, and then STOPS claiming to be loading — a ladder
-- with no last rung is the same lie in a slower voice.
--
----------------------------------------------------------------------
-- LAYOUT IS PROVISIONAL AND DELIBERATELY CHEAP TO CHANGE
--
-- The owner's word on this view was "start with this. i will need to play with
-- it a bit before I decide", which means an iteration round is already booked.
-- Every metric therefore lives in ONE table (ProfUI.LAYOUT) and every placement
-- goes through a small PURE function over it (ProfUI.GridRowY, ProfUI.CellX,
-- ProfUI.SecondaryX, ProfUI.SplitX). Moving a column is editing one number, not
-- hunting anchor arithmetic through a thousand lines.
--
-- DREW_UI_STYLE compliance notes, so the next reader can check them:
--   1 fixed-width bands, content hugging its natural width (the grid is a fixed
--     616-wide band inside its panel; the rollup is a fixed 300 column).
--   3 the two-pane drill-in is the Armory-Sets shape: ~300 list left, editor
--     right.
--   4 no dead bands: every panel's first content row sits one PANEL_PAD under
--     its header rule.
--   5 one grid: the filter band's four controls share one baseline and one
--     height.
--   6 every control is labeled — the search boxes carry inline labels, the
--     source chip prints "SOURCE: …", the grid columns carry a header band.
--   7 stable layout: the window is fixed-size, so there are no layout modes.
--
----------------------------------------------------------------------
-- INERTNESS
--
-- The behavioral spec's rule, applied to a view: module off => the TAB IS NOT
-- THERE. The shell asks Professions.IsEnabled() when it paints the tab strip;
-- this file refuses to build a pane, refuses to touch the dataset (which a
-- disabled module has un-parsed — asking it to LoadCore would rebuild exactly
-- what the toggle just dropped), registers no Blizzard event until a cold name
-- actually needs watching, and drops that watcher the moment nothing is pending
-- or the module is switched off.
--
-- Clean-room build on our own DaseekiUI stack. No third-party code or
-- identifiers.

local ADDON, ns = ...
local UI = DaseekiUI                  -- nil under the headless harness; only ever
local Dashboard = ns.Dashboard        -- dereferenced inside function bodies below.

local ProfUI = {}
ns.ProfessionsUI = ProfUI

----------------------------------------------------------------------
-- LAYOUT — the one table. See the header: this is the iteration surface.
----------------------------------------------------------------------

local L = {
    GUTTER      = 10,   -- base-colored gap between panels
    PANEL_PAD   = 10,   -- panel edge -> its content
    TOOLBAR_H   = 30,   -- the who-can-craft band at the top of the tab
    SIDE_W      = 300,  -- style guide rule 10: list column is ~300
    HEAD_H      = 18,   -- column-header band inside the grid panel

    ROW_H       = 32,   -- one character row in the grid
    NAME_W      = 132,  -- the class-colored name column
    CELL_W      = 116,  -- one PRIMARY profession cell
    CELL_GAP    = 6,
    PRIMARIES   = 2,    -- a character may hold two primaries; the slots are fixed
    SEC_W       = 58,   -- one SECONDARY chip
    SEC_GAP     = 4,
    GROUP_GAP   = 12,   -- primaries block -> secondaries block

    ICON        = 18,
    SEC_ICON    = 14,

    LIST_ROW_H  = 20,   -- recipe / rollup / search rows
    FILTER_H    = 28,   -- the drill-in filter band
    DETAIL_H    = 132,  -- the selected-recipe detail band (source + materials)
    SCROLL_STEP = 40,
}
ProfUI.LAYOUT = L

-- PURE placement maths. Every one of these is a function of LAYOUT alone, which
-- is what makes the geometry a number to edit rather than a hunt.
function ProfUI.GridRowY(i)          return (i - 1) * L.ROW_H end
function ProfUI.CellX(slot)          return L.NAME_W + (slot - 1) * (L.CELL_W + L.CELL_GAP) end
function ProfUI.SecondaryBlockX()    return ProfUI.CellX(L.PRIMARIES + 1) - L.CELL_GAP + L.GROUP_GAP end
function ProfUI.SecondaryX(i)        return ProfUI.SecondaryBlockX() + (i - 1) * (L.SEC_W + L.SEC_GAP) end
function ProfUI.GridWidth()
    return ProfUI.SecondaryX(#ProfUI.SECONDARY_ORDER) + L.SEC_W
end
-- The x of the right pane in a two-pane split of `total` width.
function ProfUI.SplitX()             return L.SIDE_W + L.GUTTER end

----------------------------------------------------------------------
-- PROFESSION ORDER
--
-- The dataset carries no primary/secondary flag — it is a recipe catalogue, not
-- a rules engine — so the split lives here, as a named constant rather than as
-- an inference. Everything not named a secondary occupies one of the two
-- primary slots. Poisons is rogue-only and is not a "secondary" in the game's
-- own words, but it behaves exactly like one for layout purposes: it costs no
-- primary slot, so it sits with them rather than stealing a column a real
-- primary needs.
----------------------------------------------------------------------

ProfUI.SECONDARY_ORDER = { "cooking", "firstaid", "fishing", "poisons" }
ProfUI.SECONDARY_SHORT = { cooking = "COOK", firstaid = "AID", fishing = "FISH", poisons = "POIS" }
ProfUI.SECONDARY = {}
for _, k in ipairs(ProfUI.SECONDARY_ORDER) do ProfUI.SECONDARY[k] = true end

function ProfUI.IsSecondary(profKey) return ProfUI.SECONDARY[profKey] and true or false end

----------------------------------------------------------------------
-- DATASET ACCESS
--
-- Both accessors REFUSE while the module is disabled. That refusal is not
-- defensive politeness: Dataset.Unload() is what SetEnabled(false) calls, and a
-- view calling LoadCore() would rebuild the exact tables the toggle just
-- dropped — an "off" switch that a hidden panel quietly undoes.
--
-- SOURCES is the "where do I get it" graph and is ~1,900 rows the grid never
-- reads. It is loaded only when a drill-in or a search actually asks, which is
-- the whole point of P1 staging the parse.
----------------------------------------------------------------------

local function enabled()
    local P = ns.Professions
    return (P and P.IsEnabled and P.IsEnabled()) and true or false
end
ProfUI.Enabled = enabled

local function core()
    if not enabled() then return nil end
    local D = ns.Professions and ns.Professions.Dataset
    if not (D and D.LoadCore and D.LoadCore()) then return nil end
    return D
end

local function sourcesDS()
    if not enabled() then return nil end
    local D = ns.Professions and ns.Professions.Dataset
    if not (D and D.LoadSources and D.LoadSources()) then return nil end
    return D
end
ProfUI.Core, ProfUI.Sources = core, sourcesDS

----------------------------------------------------------------------
-- Session caches. All of them are dropped by OnModuleToggled, because a
-- disabled module must not leave a profession-name map behind either.
----------------------------------------------------------------------

local _profName, _profIcon, _cdProf = {}, {}, nil
local _spellName, _itemName = {}, {}
local _askCount = {}     -- id -> how many times we have asked the client for it

function ProfUI.ClearCaches()
    _profName, _profIcon, _cdProf = {}, {}, nil
    _spellName, _itemName = {}, {}
    _askCount = {}
    if ProfUI._clearSourceMemo then ProfUI._clearSourceMemo() end
    if ProfUI._resetWatchState then ProfUI._resetWatchState() end
end

local function now()
    return (Dashboard and Dashboard.Now and Dashboard.Now())
        or (GetServerTime and GetServerTime()) or (time and time()) or 0
end
ProfUI.Now = now

local function spellTexture(id)
    if not id then return nil end
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    if GetSpellTexture then return GetSpellTexture(id) end
    return nil
end

-- The profession's name IN THE CLIENT'S OWN LANGUAGE. Each rank tier IS a
-- spell, so GetSpellInfo on the apprentice rank answers "Alchemy"/"Alchimie"/…
-- without shipping one translation. The dataset's English name is the fallback
-- for a client that cannot answer, never the first choice.
function ProfUI.ProfName(profKey)
    if _profName[profKey] then return _profName[profKey] end
    local D = core()
    if not D then return profKey end
    local idx = D.profIdx and D.profIdx[profKey]
    if not idx then return profKey end
    local tiers = D.ranks and D.ranks[idx]
    local t1 = tiers and tiers[1]
    if t1 and GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, t1.spell)
        if ok and type(n) == "string" and n ~= "" then _profName[profKey] = n; return n end
    end
    local n = (D.profs[idx] and D.profs[idx].name) or profKey
    _profName[profKey] = n
    return n
end

function ProfUI.ProfIcon(profKey)
    if _profIcon[profKey] ~= nil then return _profIcon[profKey] or nil end
    local D = core()
    local idx = D and D.profIdx and D.profIdx[profKey]
    local tiers = idx and D.ranks and D.ranks[idx]
    local t1 = tiers and tiers[1]
    local tex = t1 and spellTexture(t1.spell) or nil
    _profIcon[profKey] = tex or false
    return tex
end

function ProfUI.RecipeCount(profKey)
    local D = core()
    if not D then return 0 end
    local idx = D.profIdx and D.profIdx[profKey]
    if not idx then return 0 end
    return #((D.profRecipes and D.profRecipes[idx]) or {})
end

----------------------------------------------------------------------
-- THE COLD-NAME RESOLVER
--
-- `resolver.spell(id)` / `resolver.item(id)` return a name, or nil meaning "not
-- answered yet". nil is never a name and never an empty string: an empty string
-- would flow into a row and read as a nameless recipe.
----------------------------------------------------------------------

function ProfUI.LiveResolver()
    return {
        spell = function(id)
            if not id then return nil end
            local c = _spellName[id]
            if c then return c end
            local n
            if C_Spell and C_Spell.GetSpellInfo then
                local ok, info = pcall(C_Spell.GetSpellInfo, id)
                if ok and type(info) == "table" then n = info.name end
            end
            if (not n) and GetSpellInfo then
                local ok, nm = pcall(GetSpellInfo, id)
                if ok then n = nm end
            end
            if type(n) == "string" and n ~= "" then _spellName[id] = n; return n end
            return nil
        end,
        item = function(id)
            if not id then return nil end
            local c = _itemName[id]
            if c then return c end
            local n
            if C_Item and C_Item.GetItemInfo then
                local ok, nm = pcall(C_Item.GetItemInfo, id)
                if ok then n = nm end
            end
            if (not n) and GetItemInfo then
                local ok, nm = pcall(GetItemInfo, id)
                if ok then n = nm end
            end
            if type(n) == "string" and n ~= "" then _itemName[id] = n; return n end
            return nil
        end,
    }
end

-- Ask the client for the ids we could not read, bounded per id. An id the
-- server has no data for answers with success=false forever, so an unbounded
-- ask/repaint pair trades a stuck panel for an event storm.
ProfUI.MAX_ASKS = 3
function ProfUI.AskFor(kind, ids)
    if type(ids) ~= "table" then return 0 end
    local asked = 0
    for i = 1, #ids do
        local id = ids[i]
        local key = kind .. ":" .. tostring(id)
        local n = _askCount[key] or 0
        if n < ProfUI.MAX_ASKS then
            _askCount[key] = n + 1
            asked = asked + 1
            if kind == "item" and C_Item and C_Item.RequestLoadItemDataByID then
                pcall(C_Item.RequestLoadItemDataByID, id)
            elseif kind == "spell" and C_Spell and C_Spell.RequestLoadSpellData then
                pcall(C_Spell.RequestLoadSpellData, id)
            end
        end
    end
    return asked
end

-- PURE. The bounded re-ask ladder — the belt to GET_ITEM_INFO_RECEIVED's
-- braces, for answers that arrive with no event of their own, and the terminal
-- condition that stops a surface claiming "loading" forever.
ProfUI.WATCH_LADDER = { 0.25, 0.5, 1, 2, 4 }
function ProfUI.LadderDelay(round)
    local n = tonumber(round)
    if not n then return nil end
    return ProfUI.WATCH_LADDER[n]
end
function ProfUI.LadderCeiling()
    local t = 0
    for i = 1, #ProfUI.WATCH_LADDER do t = t + ProfUI.WATCH_LADDER[i] end
    return t
end

-- PURE. Sorted, de-duplicated union of two id lists (class 8: this drives a
-- retry loop, so it may not inherit iteration luck).
function ProfUI.MergeIDs(a, b)
    local seen, out = {}, {}
    local lists = { a, b }
    for li = 1, 2 do
        local list = lists[li]
        if type(list) == "table" then
            for i = 1, #list do
                local id = tonumber(list[i])
                if id and not seen[id] then seen[id] = true; out[#out + 1] = id end
            end
        end
    end
    table.sort(out)
    return out
end

-- PURE. The only two things a cold surface may say about its own certainty.
--   state = { hasQuery, rows, pending, exhausted, noun }
-- Returns emptyText (nil when rows exist) and statusText (nil when there is
-- nothing to say). rows == 0 with pending > 0 is NOT "no matches" — it is "we
-- have not been told yet", and it must read as that.
function ProfUI.StatusText(state)
    state = state or {}
    local rows      = tonumber(state.rows) or 0
    local pending   = tonumber(state.pending) or 0
    local exhausted = state.exhausted and true or false
    local noun      = state.noun or "name"

    if not state.hasQuery then
        return nil, nil
    end
    local phrase = (pending == 1) and ("1 " .. noun) or (tostring(pending) .. " " .. noun .. "s")

    if rows == 0 then
        if pending > 0 and not exhausted then
            return "Still loading " .. phrase .. "\226\128\166", nil
        elseif pending > 0 then
            return "No match among the names that answered \226\128\148 " .. phrase
                .. " never loaded.", nil
        end
        return "No match.", nil
    end
    if pending > 0 and not exhausted then
        return nil, "still loading " .. phrase .. "\226\128\166"
    elseif pending > 0 then
        return nil, phrase .. " never loaded"
    end
    return nil, nil
end

----------------------------------------------------------------------
-- THE KNOWN SET — the single reader of the three-state contract
--
-- Returns (set|nil, state). `set` is { [teachingSpellID] = true }. nil ALWAYS
-- means unknown:
--   * the character has no record at all,
--   * the character HAS the profession but has never opened its window
--     (`k` or `a` absent — P1's third state, spelled out),
--   * the payload was written against a different dataset version, so its bit
--     positions mean different recipes and decoding would be a confident lie.
--
-- The self-test pins this against Professions.KnownState() for every recipe of
-- a profession, so the list path and the tooltip path cannot drift.
----------------------------------------------------------------------

function ProfUI.KnownSet(payload, profKey)
    local P = ns.Professions
    if not (P and type(payload) == "table") then return nil, "unscanned" end
    local p = payload.p and payload.p[profKey]
    if not p then return nil, "unscanned" end
    if p.k == nil or p.a == nil then return nil, "unscanned" end
    local ids = P.DecodeKnown and P.DecodeKnown(profKey, p.k, payload.ds)
    if type(ids) ~= "table" then return nil, "unscanned" end
    local set = {}
    for i = 1, #ids do set[ids[i]] = true end
    return set, "scanned"
end

----------------------------------------------------------------------
-- COOLDOWNS
--
-- A stored stamp is the epoch the cooldown is READY, on server time — the same
-- clock Store.Now() reads on every account — so the countdown decays purely by
-- arithmetic against `now` and needs no capture-time correction. (The cards'
-- Dashboard.DecayRemaining exists because an aura stores a REMAINING measured
-- at capture; this stores an ABSOLUTE moment, which is the honest shape for a
-- fact that must survive a peer being offline for a day. The floor-at-zero and
-- never-negative rules are identical.)
--
-- A stamp in the past is not stale data — it is the answer READY, held by an
-- alt that has not re-opened the window since. P1 deletes a stamp only from a
-- proven scan, so an expired stamp is exactly as trustworthy as a running one.
----------------------------------------------------------------------

function ProfUI.CooldownRemaining(readyAt, nowE)
    local at = tonumber(readyAt)
    if not at then return nil end
    local rem = at - (tonumber(nowE) or now())
    if rem < 0 then rem = 0 end
    return math.floor(rem)
end

local function cdProfMap()
    if _cdProf then return _cdProf end
    local D = core()
    if not D then return nil end
    local m = {}
    for _, rec in pairs(D.recipe or {}) do
        if rec.cd and rec.cd > 0 then
            local key = "g" .. rec.cd
            if not m[key] then
                local p = D.profs and D.profs[rec.p]
                m[key] = p and p.key or nil
            end
        end
    end
    _cdProf = m
    return m
end

-- cdKey -> profKey|nil, spellID|nil, groupOrdinal|nil.
-- The group form is the alchemy transmute family: THIRTEEN recipes, ONE timer.
-- Naming such a row after any single member would be twelve wrong answers, so
-- the label is the profession plus the words "shared cooldown".
function ProfUI.CdKeyMeta(cdKey)
    local key = tostring(cdKey or "")
    local g = key:match("^g(%d+)$")
    if g then
        local m = cdProfMap()
        return (m and m["g" .. g]) or nil, nil, tonumber(g)
    end
    local spell = tonumber(key)
    local D = core()
    local rec = D and spell and D.recipe and D.recipe[spell]
    if rec then
        local p = D.profs and D.profs[rec.p]
        return p and p.key or nil, spell, nil
    end
    return nil, spell, nil
end

-- Returns label, pending. pending=true means a teaching-spell name has not been
-- answered yet — held, never replaced with a guess.
function ProfUI.CooldownLabel(cdKey, res)
    local profKey, spell, group = ProfUI.CdKeyMeta(cdKey)
    if group then
        local pn = profKey and ProfUI.ProfName(profKey) or nil
        if pn then return pn .. " \194\183 shared cooldown", false end
        return "shared profession cooldown", false
    end
    if spell then
        local n = res and res.spell and res.spell(spell)
        if n then return n, false end
        return nil, true
    end
    return "profession cooldown", false
end

-- The cooldown state of ONE profession, folded for a grid cell:
--   nil                                    this character has no cooldown facts here
--   { state = "ready", ready = n }         at least one is up
--   { state = "running", remaining = s }   none up; the soonest is `remaining` away
function ProfUI.CellCooldown(payload, profKey, nowE)
    if type(payload) ~= "table" or type(payload.c) ~= "table" then return nil end
    local ready, soonest = 0, nil
    local any = false
    for cdKey, at in pairs(payload.c) do
        local owner = ProfUI.CdKeyMeta(cdKey)
        if owner == profKey then
            any = true
            local rem = ProfUI.CooldownRemaining(at, nowE)
            if rem == 0 then ready = ready + 1
            elseif not soonest or rem < soonest then soonest = rem end
        end
    end
    if not any then return nil end
    if ready > 0 then return { state = "ready", ready = ready } end
    return { state = "running", remaining = soonest or 0 }
end

----------------------------------------------------------------------
-- THE GRID MODEL  (PURE — takes a lookup, never touches the store itself)
--
-- `lookup(ownerKey)` returns that character's professions payload (or nil). The
-- indirection is not ceremony: it is what lets the harness drive the whole grid
-- off a fixture with no SavedVariables, including the never-scanned case, which
-- is the one that has to be right.
----------------------------------------------------------------------

-- One profession cell. nil when the character does not have that profession at
-- all (which is a proven fact — P1's probe drops a profession the character no
-- longer holds).
function ProfUI.CellModel(payload, profKey, nowE)
    if type(payload) ~= "table" then return nil end
    local p = payload.p and payload.p[profKey]
    if not p then return nil end
    local _, state = ProfUI.KnownSet(payload, profKey)
    return {
        key       = profKey,
        level     = p.l,                       -- nil = unknown, never 0-as-unknown
        cap       = p.m,
        tier      = p.t,
        specs     = p.s,
        hasSpec   = (type(p.s) == "table" and #p.s > 0) or false,
        scanned   = (state == "scanned"),
        known     = (state == "scanned") and p.n or nil,
        total     = ProfUI.RecipeCount(profKey),
        drift     = p.u,
        scannedAt = p.a,
        cd        = ProfUI.CellCooldown(payload, profKey, nowE),
    }
end

-- One character row. `entry` is a roster entry ({ nameRealm, rec, online, … }).
function ProfUI.GridRow(entry, payload, nowE)
    local rec = entry and entry.rec or nil
    local row = {
        key        = entry and entry.nameRealm or "?",
        classTag   = rec and rec.classTag or nil,
        level      = rec and rec.level or nil,
        online     = entry and entry.online or false,
        primaries  = {},
        secondaries = {},
        hasAny     = false,
        tracked    = (type(payload) == "table") and true or false,
    }
    if type(payload) == "table" and type(payload.p) == "table" then
        local prim = {}
        for profKey in pairs(payload.p) do
            if ProfUI.IsSecondary(profKey) then
                row.secondaries[profKey] = ProfUI.CellModel(payload, profKey, nowE)
            else
                prim[#prim + 1] = profKey
            end
        end
        -- Deterministic slot order (class 8) — pairs() order is not an opinion
        -- we are allowed to render.
        table.sort(prim)
        for i = 1, #prim do row.primaries[i] = ProfUI.CellModel(payload, prim[i], nowE) end
        -- The game allows two primaries and the probe only reports professions
        -- the character actually holds, so this is zero in every real record.
        -- It is carried anyway because the alternative to counting it is
        -- DROPPING it: a third primary would simply not be painted, and a
        -- silently unpainted profession is the same class of lie as a zero
        -- where an em dash belongs.
        row.overflow = math.max(0, #prim - L.PRIMARIES)
        row.hasAny = (#prim > 0)
        if not row.hasAny then
            for _ in pairs(row.secondaries) do row.hasAny = true break end
        end
    end
    return row
end

-- The whole grid. `entries` arrives already in card order (the caller sorts it
-- with ns.Cards.SortEntries, which is exactly why the two lists agree).
function ProfUI.GridRows(entries, lookup, nowE)
    local out = {}
    if type(entries) ~= "table" then return out end
    nowE = nowE or now()
    for i = 1, #entries do
        local e = entries[i]
        local payload = lookup and lookup(e.nameRealm) or nil
        out[#out + 1] = ProfUI.GridRow(e, payload, nowE)
    end
    return out
end

----------------------------------------------------------------------
-- THE COOLDOWN ROLLUP  (PURE)
--
-- Every profession cooldown on every character, READY FIRST then soonest. The
-- order is a strict total order so two renders of the same store are byte
-- identical.
----------------------------------------------------------------------

function ProfUI.RollupRows(entries, lookup, nowE, res)
    local out = {}
    if type(entries) ~= "table" then return out end
    nowE = nowE or now()
    for i = 1, #entries do
        local e = entries[i]
        local payload = lookup and lookup(e.nameRealm) or nil
        if type(payload) == "table" and type(payload.c) == "table" then
            for cdKey, at in pairs(payload.c) do
                local rem = ProfUI.CooldownRemaining(at, nowE)
                if rem then
                    local profKey = ProfUI.CdKeyMeta(cdKey)
                    local label, pending = ProfUI.CooldownLabel(cdKey, res)
                    out[#out + 1] = {
                        owner     = e.nameRealm,
                        classTag  = e.rec and e.rec.classTag or nil,
                        cdKey     = tostring(cdKey),
                        profKey   = profKey,
                        label     = label,
                        pending   = pending and true or false,
                        ready     = (rem == 0),
                        remaining = rem,
                        readyAt   = tonumber(at) or 0,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.ready ~= b.ready then return a.ready end          -- ready first
        if a.remaining ~= b.remaining then return a.remaining < b.remaining end
        if a.owner ~= b.owner then return a.owner < b.owner end
        return a.cdKey < b.cdKey
    end)
    return out
end

-- PURE. How many cooldowns are ready right now — the tab badge.
function ProfUI.ReadyCount(rows)
    local n = 0
    for i = 1, #(rows or {}) do if rows[i].ready then n = n + 1 end end
    return n
end

----------------------------------------------------------------------
-- SOURCE DISPLAY
--
-- Two different questions, answered from two different dataset facts:
--
--   THE FILTER asks "what CLASS of source is this", and the dataset already
--   carries the derived answer as a bit mask on the recipe row (trainer 1,
--   vendor 2, drop 4, quest 8, object 16, holiday 32, granted 64). Re-deriving
--   it from the relation text would be a second opinion where one is enough.
--
--   THE DISPLAY asks "where, precisely", and that is the relation grammar:
--     T<copper>@<set>  trainer            I<item>    taught by a recipe-item
--     Q<ids>  quest    O<id>  object      R<fac>/<st> reputation gate
--     L<n>    char lvl C<class> class     G  granted with the profession
--     S<idx>  prose note                  K<item> granted via a contract item
--   and, on the recipe-ITEM it points at:
--     V<copper>@<npcs> vendor   D<npcs> drop   W<lo>-<hi> world drop
--     E<id> world event         X no source in the dataset
--
-- BOTH acquisition paths of a recipe are walked. The addendum's §4.5 records a
-- shipped implementation that only ever inspected the FIRST teaching item and
-- silently dropped the second route; a recipe with a vendor AND a drop would
-- have shown one of them.
----------------------------------------------------------------------

ProfUI.SOURCE_BITS = {
    trainer = 1, vendor = 2, drop = 4, quest = 8, object = 16, holiday = 32, granted = 64,
}
ProfUI.SOURCE_ORDER = { "trainer", "vendor", "drop", "quest", "object", "holiday", "granted" }
ProfUI.SOURCE_LABEL = {
    trainer = "Trainer", vendor = "Vendor", drop = "Drop", quest = "Quest",
    object = "World object", holiday = "World event", granted = "Free with profession",
}

-- PURE. Lua 5.1 in the WoW client has no guaranteed `bit` library, so the mask
-- test is plain arithmetic.
function ProfUI.HasSourceBit(mask, key)
    local bit = ProfUI.SOURCE_BITS[key]
    if not bit then return false end
    mask = tonumber(mask) or 0
    return math.floor(mask / bit) % 2 == 1
end

local function money(copper)
    copper = tonumber(copper) or 0
    if copper <= 0 then return nil end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 and g == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

local function firstNumber(list)
    return tonumber(tostring(list or ""):match("(%d+)"))
end
local function countNumbers(list)
    local n = 0
    for _ in tostring(list or ""):gmatch("%d+") do n = n + 1 end
    return n
end

-- "Therum Deepforge (Ironforge)" for an NPC id, as far as the indices reach.
local function npcWhere(D, id)
    local npc = D.npc and D.npc[id]
    if not npc then return nil end
    local zone = npc.zone and D.zone and D.zone[npc.zone]
    if zone and zone.name then return npc.name .. " (" .. zone.name .. ")" end
    return npc.name
end

local function plusMore(n)
    if n > 1 then return " +" .. (n - 1) .. " more" end
    return ""
end

-- Walk ONE recipe-item's acquisition relations into display parts. Returns
-- parts (array of strings) and a blocking reason when this route is not a route
-- you can walk today.
local function itemRoute(D, itemID)
    local acq = D.itemAcq and D.itemAcq[itemID]
    local item = D.item and D.item[itemID]
    local flags = (item and item.flags) or "-"
    local parts, blocked = {}, nil

    if type(acq) ~= "string" or acq == "" then
        return parts, { key = "nosource", text = "no source recorded" }
    end
    for tok in (acq .. ";"):gmatch("(.-);") do
        if tok ~= "" then
            local head = tok:sub(1, 1)
            if head == "V" then
                local cost, npcs = tok:match("^V(%d+)@([%d%+]+)$")
                local where = npcWhere(D, firstNumber(npcs))
                local m = money(tonumber(cost))
                parts[#parts + 1] = "Vendor: " .. (where or "?")
                    .. plusMore(countNumbers(npcs)) .. (m and (" \194\183 " .. m) or "")
            elseif head == "D" then
                local npcs = tok:sub(2)
                parts[#parts + 1] = "Drops from " .. (npcWhere(D, firstNumber(npcs)) or "?")
                    .. plusMore(countNumbers(npcs))
            elseif head == "W" then
                local lo, hi = tok:match("^W(%d+)%-(%d+)$")
                parts[#parts + 1] = "World drop (mobs " .. tostring(lo) .. "\226\128\147" .. tostring(hi) .. ")"
            elseif head == "Q" then
                local q = D.quest and D.quest[firstNumber(tok:sub(2))]
                parts[#parts + 1] = "Quest: " .. ((q and q.name) or "?")
            elseif head == "O" then
                local o = D.object and D.object[firstNumber(tok:sub(2))]
                parts[#parts + 1] = "World object: " .. ((o and o.name) or "?")
            elseif head == "R" then
                local f, st = tok:match("^R(%d+)/(%d+)$")
                parts[#parts + 1] = "Reputation: " .. ((D.faction and D.faction[tonumber(f)]) or "?")
                    .. " \226\128\148 " .. ((D.standing and D.standing[tonumber(st)]) or "?")
            elseif head == "E" then
                local ev = D.event and D.event[firstNumber(tok:sub(2))]
                parts[#parts + 1] = "World event: " .. (ev or "?")
                blocked = { key = "event", text = "only during " .. (ev or "a world event") }
            elseif head == "S" then
                local note = D.note and D.note[firstNumber(tok:sub(2))]
                if note then parts[#parts + 1] = note end
            elseif head == "X" then
                blocked = { key = "nosource", text = "no source recorded in the dataset" }
            end
        end
    end
    -- The generator's own candidate flags, as a cross-check on the token walk.
    if flags:find("x", 1, true) and not blocked then
        blocked = { key = "nosource", text = "no source recorded in the dataset" }
    end
    if flags:find("e", 1, true) and not blocked then
        blocked = { key = "event", text = "only during a world event" }
    end
    return parts, blocked
end

-- The full source model for one teaching spell.
--   { classes = { trainer = true, … },   -- the mask, for the filter
--     text    = "Trainer \194\183 1g 20s",  -- one compact line for a list row
--     lines   = { … },                   -- every route, for the detail band
--     unavailable = nil | { key = "event"|"nosource", text = "…" } }
--
-- `unavailable` is a CANDIDATE, in the generator's own word, and it is only set
-- when EVERY route is blocked. A recipe with a holiday vendor and a world drop
-- is obtainable; a recipe whose only teacher is a Winter Veil vendor is not
-- obtainable TODAY, and the row says which.
-- MEMOISED, because a recipe's source is a GAME FACT and the drill-in asks for
-- all ~239 of a profession's recipes on every repaint. The one moving part is a
-- teaching ITEM's name, which the client may not have answered for yet — so a
-- model built while an item name was still cold is NOT cached, and the next
-- render (or the next GET_ITEM_INFO_RECEIVED) rebuilds it with the real name.
-- Caching a "item 12345" line would freeze the cold read forever.
local _srcModel = {}
function ProfUI.SourceModel(spellID)
    local memo = _srcModel[spellID]
    if memo then return memo end
    local D = sourcesDS()
    if not D then return nil end
    local rec = D.recipe and D.recipe[spellID]
    if not rec then return nil end
    local acq = D.acq and D.acq[spellID]
    local res = ProfUI.LiveResolver()
    local coldItem = false

    local classes = {}
    for _, k in ipairs(ProfUI.SOURCE_ORDER) do
        if ProfUI.HasSourceBit(rec.m, k) then classes[k] = true end
    end

    local lines, routes, blockedRoutes = {}, 0, 0
    local firstBlock = nil
    local suffix = {}

    for tok in (tostring(acq or "") .. ";"):gmatch("(.-);") do
        if tok ~= "" then
            local head = tok:sub(1, 1)
            if head == "G" then
                routes = routes + 1
                lines[#lines + 1] = "Granted when you learn the profession"
            elseif head == "T" then
                routes = routes + 1
                local cost = tok:match("^T(%d+)@")
                local m = money(tonumber(cost))
                lines[#lines + 1] = "Trainer" .. (m and (" \194\183 " .. m) or " \194\183 free")
            elseif head == "I" or head == "K" then
                routes = routes + 1
                local itemID = tonumber(tok:sub(2))
                local parts, blocked = itemRoute(D, itemID)
                local nm = res.item(itemID)
                if nm == nil then coldItem = true end
                local head2 = (head == "K") and "Granted by " or "Taught by "
                local label = head2 .. (nm or ("item " .. tostring(itemID)))
                if #parts > 0 then label = label .. " \226\128\148 " .. table.concat(parts, "; ") end
                lines[#lines + 1] = label
                if blocked then
                    blockedRoutes = blockedRoutes + 1
                    firstBlock = firstBlock or blocked
                end
            elseif head == "Q" then
                routes = routes + 1
                local q = D.quest and D.quest[firstNumber(tok:sub(2))]
                lines[#lines + 1] = "Quest: " .. ((q and q.name) or "?")
            elseif head == "O" then
                routes = routes + 1
                local o = D.object and D.object[firstNumber(tok:sub(2))]
                lines[#lines + 1] = "World object: " .. ((o and o.name) or "?")
            elseif head == "S" then
                routes = routes + 1
                local note = D.note and D.note[firstNumber(tok:sub(2))]
                lines[#lines + 1] = note or "special acquisition"
            elseif head == "R" then
                local f, st = tok:match("^R(%d+)/(%d+)$")
                suffix[#suffix + 1] = "needs " .. ((D.faction and D.faction[tonumber(f)]) or "?")
                    .. " \226\128\148 " .. ((D.standing and D.standing[tonumber(st)]) or "?")
            elseif head == "L" then
                suffix[#suffix + 1] = "level " .. tostring(tok:sub(2)) .. "+"
            elseif head == "C" then
                suffix[#suffix + 1] = tostring(tok:sub(2)) .. " only"
            elseif head == "X" then
                routes = routes + 1
                blockedRoutes = blockedRoutes + 1
                firstBlock = firstBlock or { key = "nosource", text = "no source recorded in the dataset" }
            end
        end
    end

    -- A compact one-liner for the list column: the highest-signal class we have.
    local text
    for _, k in ipairs(ProfUI.SOURCE_ORDER) do
        if classes[k] then text = ProfUI.SOURCE_LABEL[k]; break end
    end
    if not text then text = "?" end
    if #suffix > 0 then text = text .. " \194\183 " .. table.concat(suffix, ", ") end

    local unavailable = nil
    if routes > 0 and blockedRoutes >= routes then unavailable = firstBlock end

    local model = { classes = classes, text = text, lines = lines,
                    suffix = suffix, unavailable = unavailable,
                    skill = rec.s, spec = (rec.spec and rec.spec > 0) and rec.spec or nil,
                    cold = coldItem }
    if not coldItem then _srcModel[spellID] = model end
    return model
end

function ProfUI._clearSourceMemo() _srcModel = {} end

function ProfUI.SpecName(specIdx)
    local D = core()
    local s = D and D.specs and D.specs[specIdx]
    return s and s.name or nil
end

----------------------------------------------------------------------
-- THE DRILL-IN RECIPE ROWS  (PURE apart from the injected resolver)
--
-- opts = { search = "", source = nil|<class key>, missingOnly = bool,
--          showUnavailable = bool }
--
-- Row states are the contract's three, never two:
--   "known"    proven in the bitmap
--   "missing"  proven absent from a scanned bitmap
--   "unknown"  never scanned / undecodable — the WHOLE list takes this state,
--              and "missing only" then shows NOTHING rather than claiming the
--              character is missing 239 recipes it may well know.
----------------------------------------------------------------------

function ProfUI.RecipeRows(payload, profKey, opts, res)
    opts = opts or {}
    res = res or ProfUI.LiveResolver()
    local D = core()
    local rows, pending = {}, {}
    if not D then return rows, pending, "nodata" end
    local idx = D.profIdx and D.profIdx[profKey]
    if not idx then return rows, pending, "nodata" end
    local list = (D.profRecipes and D.profRecipes[idx]) or {}

    local known, state = ProfUI.KnownSet(payload, profKey)
    local unscanned = (state ~= "scanned")
    local needle = tostring(opts.search or ""):lower()
    local hasSearch = (needle ~= "")
    -- Q7's default, spelled out: OBTAINABLE-NOW unless the caller says
    -- otherwise. An absent option is the default, not "no opinion" — leaving it
    -- nil used to mean unavailables leaked through the front door.
    local showUnav = opts.showUnavailable and true or false

    for i = 1, #list do
        local spell = list[i]
        local rec = D.recipe[spell]
        local rowState = unscanned and "unknown" or (known[spell] and "known" or "missing")

        local keep = true
        if opts.missingOnly and rowState ~= "missing" then keep = false end

        -- Memoised (see SourceModel): a game fact looked up once per session.
        local src = keep and ProfUI.SourceModel(spell) or nil
        if keep and opts.source then
            if not (src and src.classes and src.classes[opts.source]) then keep = false end
        end
        local unavailable = src and src.unavailable or nil
        if keep and unavailable and not showUnav then keep = false end

        if keep then
            local name = res.spell and res.spell(spell) or nil
            if name == nil then
                pending[#pending + 1] = spell
                -- A pending name cannot be judged against a search term. Held,
                -- never scored as a miss (the Bags lesson).
                if hasSearch then keep = false end
            elseif hasSearch and not name:lower():find(needle, 1, true) then
                keep = false
            end
            if keep then
                rows[#rows + 1] = {
                    spell   = spell,
                    name    = name,                       -- nil = not answered yet
                    state   = rowState,
                    skill   = rec and rec.s or nil,
                    spec    = (rec and rec.spec and rec.spec > 0) and rec.spec or nil,
                    source  = src and src.text or nil,
                    classes = src and src.classes or nil,
                    unavailable = src and src.unavailable or nil,
                }
            end
        end
    end
    table.sort(pending)
    return rows, pending, unscanned and "unscanned" or "scanned"
end

-- PURE. The professions of ONE character, for the drill-in's left column, in
-- the same primaries-then-secondaries order the grid uses.
function ProfUI.ProfessionList(payload, nowE)
    local out = {}
    if type(payload) ~= "table" or type(payload.p) ~= "table" then return out end
    local prim, sec = {}, {}
    for profKey in pairs(payload.p) do
        if ProfUI.IsSecondary(profKey) then sec[#sec + 1] = profKey else prim[#prim + 1] = profKey end
    end
    table.sort(prim); table.sort(sec)
    for i = 1, #prim do out[#out + 1] = ProfUI.CellModel(payload, prim[i], nowE) end
    for i = 1, #sec  do out[#out + 1] = ProfUI.CellModel(payload, sec[i],  nowE) end
    return out
end

----------------------------------------------------------------------
-- MATERIALS LINKAGE — the join that is the whole point
--
-- P1 harvests reagents from the live profession window because the recipe
-- catalogue has none to ship, and stores them ACCOUNT-WIDE keyed by teaching
-- spell id. The inventory module holds `itemCounts` per character. Joining the
-- two answers the question the owner actually asks at a bank: "can Puumats make
-- this, and if not, who is holding the cloth."
--
-- ABSENCE IS NOT ZERO, twice over:
--   * no reagent entry for this recipe => "not yet harvested", with the exact
--     instruction that fixes it. Rendering 0/0 would be a claim we cannot make.
--   * a character with no inventory record contributes NOTHING, rather than a
--     confident 0 that would make a full bank look empty.
----------------------------------------------------------------------

function ProfUI.MaterialRows(spellID, reagents, ownerKey, invLookup, res)
    res = res or ProfUI.LiveResolver()
    local entry = type(reagents) == "table" and reagents[spellID] or nil
    if type(entry) ~= "table" or type(entry.r) ~= "table" then
        return nil, "unharvested"
    end

    local ids = {}
    for itemID in pairs(entry.r) do ids[#ids + 1] = itemID end
    table.sort(ids)      -- class 8: a reagent list may not inherit iteration luck

    local rows, pending = {}, {}
    for i = 1, #ids do
        local itemID = ids[i]
        local need = entry.r[itemID]
        local mine, others = nil, {}
        if type(invLookup) == "function" then
            local ownerCounts = invLookup(ownerKey)
            if type(ownerCounts) == "table" then mine = ownerCounts[itemID] end
            local everyone = invLookup()          -- no key = "every owner"
            if type(everyone) == "table" then
                for key, counts in pairs(everyone) do
                    if key ~= ownerKey and type(counts) == "table" then
                        local n = counts[itemID]
                        if n and n > 0 then
                            others[#others + 1] = { key = key, count = n }
                        end
                    end
                end
            end
        end
        table.sort(others, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.key < b.key
        end)
        local name = res.item and res.item(itemID) or nil
        if name == nil then pending[#pending + 1] = itemID end
        rows[#rows + 1] = {
            itemID = itemID, need = need, name = name,
            mine   = mine,                        -- nil = no inventory record at all
            enough = (mine ~= nil) and (mine >= need) or false,
            others = others,
        }
    end
    table.sort(pending)
    return rows, "harvested", pending, { produces = entry.o, yield = entry.n }
end

-- PURE. The one-line form of a material row:
--   "8 / 10 Runecloth"  plus "\194\183 Puumats 200"
-- A character with no inventory record reads "? / 10", never "0 / 10".
function ProfUI.MaterialText(row)
    if type(row) ~= "table" then return "" end
    local have = (row.mine ~= nil) and tostring(row.mine) or "?"
    local name = row.name or "\226\128\166"
    local left = have .. " / " .. tostring(row.need) .. "  " .. name
    local right = nil
    if row.others and #row.others > 0 then
        local o = row.others[1]
        local shortName = tostring(o.key):match("^([^%-]+)") or o.key
        right = shortName .. " " .. tostring(o.count)
        if #row.others > 1 then right = right .. " +" .. (#row.others - 1) end
    end
    return left, right
end

----------------------------------------------------------------------
-- WHO CAN CRAFT X  (PURE apart from the injected resolver)
--
-- Learnability is a TWO-state answer (addendum §4.3): a character can learn a
-- recipe if they HAVE the profession and MEET the skill requirement — and, on
-- our own reading, hold the specialisation when one is required. Character
-- level is stored but is never a gate (§4.2), so it is not consulted here.
--
-- The third state survives the search: a character whose profession has never
-- been scanned appears under "not checked", never under "cannot".
----------------------------------------------------------------------

ProfUI.SEARCH_LIMIT = 40

function ProfUI.SearchRows(query, entries, lookup, res, limit)
    res = res or ProfUI.LiveResolver()
    limit = limit or ProfUI.SEARCH_LIMIT
    local rows, pending = {}, {}
    local needle = tostring(query or ""):lower()
    if needle == "" then return rows, pending, false end
    local D = core()
    if not D then return rows, pending, false end

    -- Which characters hold which professions, resolved once.
    local holders = {}
    for i = 1, #(entries or {}) do
        local e = entries[i]
        local payload = lookup and lookup(e.nameRealm) or nil
        if type(payload) == "table" and type(payload.p) == "table" then
            holders[#holders + 1] = { entry = e, payload = payload }
        end
    end

    local matched, truncated = 0, false
    for pIdx = 1, #(D.profs or {}) do
        local prof = D.profs[pIdx]
        local list = prof and D.profRecipes and D.profRecipes[pIdx] or nil
        if list then
            for i = 1, #list do
                local spell = list[i]
                local name = res.spell and res.spell(spell) or nil
                if name == nil then
                    pending[#pending + 1] = spell
                elseif name:lower():find(needle, 1, true) then
                    matched = matched + 1
                    if matched > limit then
                        truncated = true
                    else
                        local rec = D.recipe[spell]
                        local row = { spell = spell, name = name, profKey = prof.key,
                                      known = {}, learnable = {}, unchecked = {} }
                        for h = 1, #holders do
                            local hp = holders[h].payload
                            local pr = hp.p[prof.key]
                            if pr then
                                local who = holders[h].entry
                                local set, st = ProfUI.KnownSet(hp, prof.key)
                                if st ~= "scanned" then
                                    row.unchecked[#row.unchecked + 1] = who
                                elseif set[spell] then
                                    row.known[#row.known + 1] = who
                                else
                                    local lvl = tonumber(pr.l)
                                    local needSkill = rec and rec.s or 0
                                    local specOK = true
                                    if rec and rec.spec and rec.spec > 0 then
                                        specOK = false
                                        local sp = D.specs and D.specs[rec.spec]
                                        if sp and type(pr.s) == "table" then
                                            for j = 1, #pr.s do
                                                if pr.s[j] == sp.id then specOK = true break end
                                            end
                                        end
                                    end
                                    if lvl == nil then
                                        row.unchecked[#row.unchecked + 1] = who
                                    elseif specOK and lvl >= needSkill then
                                        row.learnable[#row.learnable + 1] = who
                                    end
                                end
                            end
                        end
                        rows[#rows + 1] = row
                    end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if #a.known ~= #b.known then return #a.known > #b.known end
        if a.name ~= b.name then return a.name < b.name end
        return a.spell < b.spell
    end)
    table.sort(pending)
    return rows, pending, truncated
end

----------------------------------------------------------------------
-- THE LOGIN LINE
--
-- Q6, and the quiet philosophy that came with it: ONE line, no popup, no sound,
-- configurable off. It names characters and PROFESSIONS rather than recipes on
-- purpose — a profession name resolves from its own rank spell and is never
-- cold, so the line can never print an ellipsis where a name should be at the
-- exact moment the client is busiest.
----------------------------------------------------------------------

ProfUI.LOGIN_NAMES = 4

function ProfUI.LoginLineEnabled()
    local db = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    if not db then return true end
    if db.professionsLoginLine == nil then return true end     -- absent = ON
    return db.professionsLoginLine and true or false
end

-- PURE. nil when there is nothing ready — silence is the correct output, not an
-- empty announcement.
function ProfUI.LoginLine(rows, maxNames)
    maxNames = maxNames or ProfUI.LOGIN_NAMES
    local ready = {}
    for i = 1, #(rows or {}) do
        if rows[i].ready then ready[#ready + 1] = rows[i] end
    end
    if #ready == 0 then return nil end
    local parts = {}
    for i = 1, math.min(#ready, maxNames) do
        local r = ready[i]
        local shortName = tostring(r.owner):match("^([^%-]+)") or r.owner
        local what = r.profKey and ProfUI.ProfName(r.profKey) or "a profession"
        parts[#parts + 1] = shortName .. " (" .. what .. ")"
    end
    local tail = ""
    if #ready > maxNames then tail = " and " .. (#ready - maxNames) .. " more" end
    local head = (#ready == 1) and "1 profession cooldown is ready"
                                or (#ready .. " profession cooldowns are ready")
    return head .. ": " .. table.concat(parts, ", ") .. tail .. "."
end

----------------------------------------------------------------------
-- STORE READERS (the only place this file touches SavedVariables)
----------------------------------------------------------------------

local function payloadLookup()
    local S = ns.Store
    local owners = (S and S.ProfessionsOwners and S.ProfessionsOwners()) or {}
    return function(ownerKey)
        local e = owners[ownerKey]
        return e and e.data or nil
    end
end
ProfUI.PayloadLookup = payloadLookup

-- invLookup(key) -> that character's itemCounts; invLookup() -> every
-- character's, keyed by ownerKey.
local function inventoryLookup()
    local S = ns.Store
    local owners = (S and S.InventoryOwners and S.InventoryOwners()) or {}
    local flat = nil
    return function(ownerKey)
        if ownerKey == nil then
            if not flat then
                flat = {}
                for key, e in pairs(owners) do
                    local d = e and e.data
                    if type(d) == "table" and type(d.itemCounts) == "table" then
                        flat[key] = d.itemCounts
                    end
                end
            end
            return flat
        end
        local e = owners[ownerKey]
        local d = e and e.data
        return (type(d) == "table" and type(d.itemCounts) == "table") and d.itemCounts or nil
    end
end
ProfUI.InventoryLookup = inventoryLookup

local function reagentStore()
    local S = ns.Store
    return (S and S.ProfessionsReagents and S.ProfessionsReagents(false)) or nil
end

-- The roster, in the SAME order the character cards use — the brief's "roster
-- order matching the cards" is not a coincidence to be re-derived, it is
-- ns.Cards.SortEntries called on the same gather.
function ProfUI.Roster()
    if not (Dashboard and Dashboard.GatherRoster) then return {} end
    local faction = Dashboard.GetFaction and Dashboard.GetFaction() or nil
    local entries = Dashboard.GatherRoster(faction, { includeHomeless = true }) or {}
    local Cards = ns.Cards
    for _, e in ipairs(entries) do
        e.faction = faction
        if Cards and Cards.IsSelf then e.isSelf = Cards.IsSelf(e.nameRealm) end
    end
    if Cards and Cards.SortEntries then return Cards.SortEntries(entries) end
    return entries
end

-- The tab badge: how many profession cooldowns are ready across the roster.
-- Returns 0 while the module is off, so the shell never paints a badge for a
-- tab that is not there.
--
-- ONE-SECOND TTL. The shell repaints the strip on every engine callback and on
-- every tick of the professions pane's own repainter, and this walks the whole
-- roster (which re-derives online winners over the entire store). A count that
-- changes at most once a second does not need computing twice in one frame; the
-- TTL is the clock the number itself moves on, so nothing is ever stale by more
-- than the tick that would have redrawn it anyway.
local _badge, _badgeAt = 0, nil
function ProfUI.BadgeCount()
    if not enabled() then return 0 end
    local t = now()
    if _badgeAt == t then return _badge end
    local ok, n = pcall(function()
        return ProfUI.ReadyCount(ProfUI.RollupRows(ProfUI.Roster(), payloadLookup(), t))
    end)
    _badge, _badgeAt = (ok and n) or 0, t
    return _badge
end

----------------------------------------------------------------------
-- THE COLD-NAME WATCHER
--
-- Created lazily, the FIRST time a surface actually holds a pending id, and
-- dropped the moment nothing is pending or the module is switched off. A view
-- that never meets a cold name never registers a Blizzard event, which is what
-- the inertness rule asks of a display layer.
----------------------------------------------------------------------

local watcher = nil
local watchRound = 0
local watching = {}      -- "kind:id" -> true, the ids this ladder is waiting on
local exhausted = {}     -- "kind:id" -> true, ids a completed ladder never got

-- THE TERMINAL CONDITION, and it has to be per ID rather than per ladder.
--
-- A ladder that merely ends is not enough: the next render finds the same
-- unanswered id, calls notePending, and starts a fresh ladder — a loop with a
-- 7.75-second period that would run for the whole session. So when a ladder
-- ends, every id it was waiting on is marked EXHAUSTED and can never start
-- another one. A NEW cold id still gets its own full ladder, which is the
-- behaviour we actually want; the ids the server will never answer for simply
-- stop costing anything, and the surface says "N never loaded" instead of
-- "still loading" forever.
local function stopWatch()
    watchRound = 0
    for key in pairs(watching) do exhausted[key] = true end
    watching = {}
    if watcher then
        pcall(function() watcher:UnregisterAllEvents() end)
        pcall(function() watcher:SetScript("OnEvent", nil) end)
        pcall(function() watcher:Hide() end)
        watcher = nil
    end
end
ProfUI.StopWatch = stopWatch

local repaintPane   -- forward declaration; defined with the pane below

local function startWatch()
    if not enabled() then return end
    if watcher then return end
    if not CreateFrame then return end
    local f = CreateFrame("Frame")
    f:SetScript("OnEvent", function()
        if repaintPane then ns:SafeCall(repaintPane) end
    end)
    pcall(function() f:RegisterEvent("GET_ITEM_INFO_RECEIVED") end)
    pcall(function() f:RegisterEvent("SPELLS_CHANGED") end)
    watcher = f
    -- The bounded ladder: five rungs, then we stop claiming to be loading.
    if C_Timer and C_Timer.After then
        watchRound = 0
        local function rung()
            watchRound = watchRound + 1
            local d = ProfUI.LadderDelay(watchRound)
            if not d then stopWatch(); if repaintPane then ns:SafeCall(repaintPane) end return end
            C_Timer.After(d, function()
                if not enabled() then stopWatch() return end
                if repaintPane then ns:SafeCall(repaintPane) end
                rung()
            end)
        end
        rung()
    end
end

-- Called by every render that produced pending ids. Ids a completed ladder has
-- already given up on are dropped here, so they can neither re-ask nor re-arm.
local function notePending(kind, ids)
    if type(ids) ~= "table" or #ids == 0 then return false end
    local fresh = {}
    for i = 1, #ids do
        local key = kind .. ":" .. tostring(ids[i])
        if not exhausted[key] then
            fresh[#fresh + 1] = ids[i]
            watching[key] = true
        end
    end
    if #fresh == 0 then return false end
    ProfUI.AskFor(kind, fresh)
    startWatch()
    return true
end

-- Re-enabling the module is a fresh start for the cold-name loop too: the ids
-- an earlier session gave up on deserve another chance, not a permanent
-- verdict. Wired through ClearCaches so there is one reset, not two.
function ProfUI._resetWatchState()
    stopWatch()
    watching, exhausted = {}, {}
end

----------------------------------------------------------------------
-- MODULE TOGGLE HOOK
--
-- options.lua calls this right after Professions.SetEnabled, so turning the
-- module off drops this file's caches and its watcher too, and the shell
-- repaints its tab strip in the same breath (module off => the tab is gone).
----------------------------------------------------------------------

function ProfUI.OnModuleToggled(on)
    ProfUI.ClearCaches()
    if not on then stopWatch() end
    if not Dashboard then return end
    -- Re-SELECT rather than merely repaint. Switching the module off while its
    -- own tab is the one on screen would otherwise leave the strip correct (no
    -- Professions button) and the BODY wrong (the professions pane, now blank,
    -- still showing). SelectTab runs the request through ResolveTab, so an
    -- active-but-now-invisible tab lands on Characters.
    if Dashboard.SelectTab and Dashboard.window then
        Dashboard.SelectTab(Dashboard.activeTabId or "characters")
    end
    if Dashboard.RefreshTabStrip then Dashboard.RefreshTabStrip() end
    if Dashboard.RefreshActive then Dashboard.RefreshActive() end
end

-- ════════════════════════════════════════════════════════════════════════════
--  THE VIEW
--
--  Everything above this line is pure and headless-testable. Everything below
--  is frames, and is never reached by the harness (the pane is only built when
--  the shell selects the tab).
-- ════════════════════════════════════════════════════════════════════════════

local function fstr(parent, key, justify)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(Dashboard.Font(key))
    if justify then f:SetJustifyH(justify) end
    f:SetWordWrap(false)
    return f
end

local function panel(parent, id)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    UI.Skin(p, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("raised"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)
    if Dashboard.RoundCorners then Dashboard.RoundCorners(p, 7, "ground") end
    Dashboard.Tag(p, id)
    return p
end

-- An uppercase micro caption — the column headers and panel eyebrows.
local function eyebrow(parent, text, justify)
    local f = fstr(parent, "small", justify or "LEFT")
    f:SetText(text)
    UI.Skin(f, function(self) self:SetTextColor(UI.Color("muted")) end)
    return f
end

-- A labeled inline search box. The label sits to the LEFT and shares the box's
-- vertical centre (style rule 3: vertical centering for mixed-height row
-- items), so the whole control is one compact 24px band rather than a 44px
-- stacked one.
-- NAMING NOTE (applies to every factory below): the static anchor-graph gate is
-- purely textual and conflates same-named locals across scopes, so a `lbl` that
-- anchors to a `box` here and a `box` that anchors to a `lbl` there reads as a
-- cycle that cannot exist. Each factory therefore uses its OWN names.
local function searchBox(parent, labelText, width, onChange)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(width, 24)
    local caption = fstr(holder, "small", "LEFT")
    caption:SetText(labelText)
    caption:SetPoint("LEFT", holder, "LEFT", 0, 0)
    UI.Skin(caption, function(self) self:SetTextColor(UI.Color("muted")) end)
    local lw = math.max(1, (caption:GetStringWidth() or 40) + 6)

    local entry = CreateFrame("EditBox", nil, holder, "BackdropTemplate")
    entry:SetPoint("LEFT", caption, "RIGHT", 6, 0)
    entry:SetSize(math.max(60, width - lw), 22)
    entry:SetAutoFocus(false)
    entry:SetFontObject(Dashboard.Font("body"))
    entry:SetTextInsets(6, 6, 0, 0)
    UI.Skin(entry, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    entry:SetScript("OnTextChanged", function(self) if onChange then onChange(self:GetText() or "") end end)
    entry:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    entry:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    holder:SetWidth(width)
    holder._box = entry
    return holder
end

-- A compact CYCLING chip. ⚠ JUDGEMENT CALL (flagged for the owner's iteration
-- round): the source filter has nine values, which is too many for a segmented
-- strip in a 28px band and heavier than this pane wants a popup for. The chip
-- prints its axis AND its value ("SOURCE: Trainer"), so rule 6 is satisfied,
-- and right-click steps backwards so a nine-ring is never a nine-click.
local function cycleChip(parent, axis, values, labels, width, onPick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, 22)
    b._i = 1
    local lbl = fstr(b, "small", "LEFT")
    lbl:SetPoint("LEFT", b, "LEFT", 7, 0)
    lbl:SetPoint("RIGHT", b, "RIGHT", -7, 0)
    b._lbl = lbl
    UI.Skin(b, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("control"))
        self:SetBackdropBorderColor(UI.Color(self._i > 1 and "accentDim" or "controlBorder"))
        self._lbl:SetTextColor(UI.Color(self._i > 1 and "text" or "muted"))
    end)
    local function paint()
        local v = values[b._i]
        lbl:SetText(axis .. ": " .. (labels[v] or "All"))
        b:SetBackdropBorderColor(UI.Color(b._i > 1 and "accentDim" or "controlBorder"))
        lbl:SetTextColor(UI.Color(b._i > 1 and "text" or "muted"))
    end
    b._paint = paint
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, button)
        local step = (button == "RightButton") and -1 or 1
        self._i = ((self._i - 1 + step) % #values) + 1
        paint()
        if onPick then onPick(values[self._i]) end
    end)
    function b:SetValue(v)
        for i = 1, #values do if values[i] == v then self._i = i break end end
        paint()
    end
    paint()
    return b
end

-- A compact labeled checkbox (16px box + label).
local function checkBox(parent, labelText, get, set)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(1, 22)
    local tickBox = CreateFrame("Frame", nil, b, "BackdropTemplate")
    tickBox:SetSize(14, 14)
    tickBox:SetPoint("LEFT", b, "LEFT", 0, 0)
    local tick = tickBox:CreateTexture(nil, "OVERLAY")
    tick:SetPoint("TOPLEFT", tickBox, "TOPLEFT", 3, -3)
    tick:SetPoint("BOTTOMRIGHT", tickBox, "BOTTOMRIGHT", -3, 3)
    local chkLbl = fstr(b, "small", "LEFT")
    chkLbl:SetText(labelText)
    chkLbl:SetPoint("LEFT", tickBox, "RIGHT", 6, 0)
    b._box, b._tick, b._lbl = tickBox, tick, chkLbl
    UI.Skin(b, function(self)
        self._box:SetBackdrop(UI.FLAT_BACKDROP)
        self._box:SetBackdropColor(UI.Color("inset"))
        self._box:SetBackdropBorderColor(UI.Color("controlBorder"))
        self._tick:SetColorTexture(UI.Color("accent"))
        self._lbl:SetTextColor(UI.Color("muted"))
    end)
    function b:Repaint()
        local on = get and get() or false
        self._tick:SetShown(on and true or false)
        self._lbl:SetTextColor(UI.Color(on and "text" or "muted"))
    end
    b:SetScript("OnClick", function(self)
        if set then set(not (get and get())) end
        self:Repaint()
    end)
    b:SetWidth(14 + 6 + math.max(20, (chkLbl:GetStringWidth() or 40) + 2))
    b:Repaint()
    return b
end

-- A scroll region with a child frame and wheel support. Returns scroll, child.
local function scroller(parent, id)
    local sc = CreateFrame("ScrollFrame", nil, parent)
    sc:SetClipsChildren(true)
    sc:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, sc)
    child:SetSize(1, 1)
    sc:SetScrollChild(child)
    sc:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * L.SCROLL_STEP)))
    end)
    Dashboard.Tag(sc, id)
    return sc, child
end

----------------------------------------------------------------------
-- Row factories. Each pools its own rows on its own list; names are kept
-- distinct per factory so the static anchor-graph gate never conflates two
-- unrelated `row` locals into a false cycle.
----------------------------------------------------------------------

-- One character row of the grid: name column + two primary cells + the
-- secondary chips.
local function makeGridRow(parentChild, pane)
    local gr = CreateFrame("Button", nil, parentChild)
    -- STANDING TECHNICAL RULE: both dimensions at creation. The render sets the
    -- real width from its scroll frame, but no frame here is ever born
    -- zero-sized (the class of defect that cost three iteration rounds).
    gr:SetSize(ProfUI.GridWidth(), L.ROW_H)

    local hl = gr:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    UI.Skin(hl, function(self) self:SetColorTexture(UI.Color("accent", 0.10)) end)
    gr:SetHighlightTexture(hl)

    local nameFS = fstr(gr, "body", "LEFT")
    nameFS:SetPoint("LEFT", gr, "LEFT", 2, 0)
    nameFS:SetWidth(L.NAME_W - 6)
    gr._name = nameFS

    -- PRIMARY cells.
    gr._cells = {}
    for slot = 1, L.PRIMARIES do
        local cell = CreateFrame("Button", nil, gr)
        cell:SetSize(L.CELL_W, L.ROW_H - 4)
        cell:SetPoint("TOPLEFT", gr, "TOPLEFT", ProfUI.CellX(slot), -2)
        local ch = cell:CreateTexture(nil, "HIGHLIGHT")
        ch:SetAllPoints()
        UI.Skin(ch, function(self) self:SetColorTexture(UI.Color("accent", 0.16)) end)
        cell:SetHighlightTexture(ch)
        local icon = cell:CreateTexture(nil, "ARTWORK")
        icon:SetSize(L.ICON, L.ICON)
        icon:SetPoint("LEFT", cell, "LEFT", 2, 0)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local top = fstr(cell, "numeral", "LEFT")
        top:SetPoint("TOPLEFT", cell, "TOPLEFT", L.ICON + 6, -1)
        local bot = fstr(cell, "small", "LEFT")
        bot:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT", L.ICON + 6, 1)
        cell._icon, cell._top, cell._bot = icon, top, bot
        cell:SetScript("OnClick", function(self)
            if self._profKey and self._owner then pane.OpenDrill(self._owner, self._profKey) end
        end)
        cell:SetScript("OnEnter", function(self) pane.CellTooltip(self) end)
        cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
        gr._cells[slot] = cell
    end

    -- SECONDARY chips, in fixed columns so they line up down the grid.
    gr._secs = {}
    for i, profKey in ipairs(ProfUI.SECONDARY_ORDER) do
        local chip = CreateFrame("Button", nil, gr)
        chip:SetSize(L.SEC_W, L.ROW_H - 8)
        chip:SetPoint("TOPLEFT", gr, "TOPLEFT", ProfUI.SecondaryX(i), -4)
        local sh = chip:CreateTexture(nil, "HIGHLIGHT")
        sh:SetAllPoints()
        UI.Skin(sh, function(self) self:SetColorTexture(UI.Color("accent", 0.16)) end)
        chip:SetHighlightTexture(sh)
        local sicon = chip:CreateTexture(nil, "ARTWORK")
        sicon:SetSize(L.SEC_ICON, L.SEC_ICON)
        sicon:SetPoint("LEFT", chip, "LEFT", 1, 0)
        sicon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local stext = fstr(chip, "numeral", "LEFT")
        stext:SetPoint("LEFT", sicon, "RIGHT", 4, 0)
        chip._icon, chip._text, chip._profKey = sicon, stext, profKey
        chip:SetScript("OnClick", function(self)
            if self._owner then pane.OpenDrill(self._owner, self._profKey) end
        end)
        chip:SetScript("OnEnter", function(self) pane.CellTooltip(self) end)
        chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
        gr._secs[i] = chip
    end
    return gr
end

-- Paint one profession cell from a CellModel. `compact` is the secondary chip
-- form (icon + skill only; the tooltip carries the rest).
local function paintCell(cell, model, ownerKey, compact)
    cell._owner   = ownerKey
    cell._profKey = model and model.key or cell._profKey
    cell._model   = model
    if not model then
        cell._icon:SetTexture(nil)
        if cell._top then cell._top:SetText("") end
        if cell._bot then cell._bot:SetText("") end
        if cell._text then cell._text:SetText("") end
        cell:EnableMouse(false)
        cell:SetAlpha(0.35)
        return
    end
    cell:EnableMouse(true)
    cell:SetAlpha(1)
    cell._icon:SetTexture(ProfUI.ProfIcon(model.key) or "Interface\\Icons\\INV_Misc_QuestionMark")
    -- A DESATURATED ICON is the third state at a glance: we know this character
    -- has the profession, we have never looked inside it. The secondary chips
    -- have no room for the words, so this is the only signal they carry — and
    -- the primaries wear it too so the two blocks mean the same thing.
    cell._icon:SetDesaturated(not model.scanned)

    local skill = model.level and (tostring(model.level) .. "/" .. tostring(model.cap or "?")) or "\226\128\148"
    if compact then
        cell._text:SetText(skill)
        cell._text:SetTextColor(UI.Color(model.level and "text" or "faint"))
        return
    end

    cell._top:SetText(skill .. (model.hasSpec and "  \226\151\134" or ""))
    cell._top:SetTextColor(UI.Color(model.level and "text" or "faint"))

    -- The bottom line answers the most URGENT thing we know, in this order:
    -- a ready cooldown, a running one, then the recipe census — and the census
    -- is an EM DASH when the window has never been opened, never a zero.
    local cd = model.cd
    if cd and cd.state == "ready" then
        cell._bot:SetText("\226\156\147 ready" .. (cd.ready > 1 and (" \195\151" .. cd.ready) or ""))
        cell._bot:SetTextColor(UI.Color("ok"))
    elseif cd and cd.state == "running" then
        cell._bot:SetText(Dashboard.FormatDuration(cd.remaining, "compact"))
        cell._bot:SetTextColor(UI.Color("warn"))
    elseif model.scanned then
        cell._bot:SetText(tostring(model.known or 0) .. "/" .. tostring(model.total))
        cell._bot:SetTextColor(UI.Color("muted"))
    else
        cell._bot:SetText("\226\128\148 not checked")
        cell._bot:SetTextColor(UI.Color("faint"))
    end
end

-- ── the recipe list row (drill-in) ───────────────────────────────────────────
local function makeRecipeRow(listChild, pane)
    local rr = CreateFrame("Button", nil, listChild)
    rr:SetSize(1, L.LIST_ROW_H)          -- width comes from the render; never born zero
    local rh = rr:CreateTexture(nil, "HIGHLIGHT")
    rh:SetAllPoints()
    UI.Skin(rh, function(self) self:SetColorTexture(UI.Color("accent", 0.12)) end)
    rr:SetHighlightTexture(rh)

    local mark = fstr(rr, "small", "CENTER")
    mark:SetPoint("LEFT", rr, "LEFT", 2, 0)
    mark:SetWidth(14)
    local title = fstr(rr, "body", "LEFT")
    title:SetPoint("LEFT", mark, "RIGHT", 4, 0)
    title:SetWidth(250)
    local skill = fstr(rr, "numeral", "RIGHT")
    skill:SetPoint("LEFT", title, "RIGHT", 4, 0)
    skill:SetWidth(38)
    local src = fstr(rr, "small", "LEFT")
    src:SetPoint("LEFT", skill, "RIGHT", 10, 0)
    src:SetPoint("RIGHT", rr, "RIGHT", -4, 0)

    rr._mark, rr._title, rr._skill, rr._src = mark, title, skill, src
    rr:SetScript("OnClick", function(self)
        if self._spell then pane.SelectRecipe(self._spell) end
    end)
    return rr
end

local function paintRecipeRow(rr, row, selected)
    rr._spell = row.spell
    local grey = row.unavailable and true or false
    if row.state == "known" then
        rr._mark:SetText("\226\156\147"); rr._mark:SetTextColor(UI.Color("ok"))
    elseif row.state == "missing" then
        rr._mark:SetText("+"); rr._mark:SetTextColor(UI.Color("accentDim"))
    else
        rr._mark:SetText("?"); rr._mark:SetTextColor(UI.Color("faint"))
    end
    rr._title:SetText(row.name or "\226\128\166")
    if grey then
        rr._title:SetTextColor(UI.Color("faint"))
    elseif row.state == "known" then
        rr._title:SetTextColor(UI.Color("text"))
    elseif row.state == "unknown" then
        rr._title:SetTextColor(UI.Color("faint"))
    else
        rr._title:SetTextColor(UI.Color("muted"))
    end
    rr._skill:SetText(row.skill and tostring(row.skill) or "")
    rr._skill:SetTextColor(UI.Color("faint"))

    local right = row.source or ""
    if row.unavailable then right = "unavailable \226\128\148 " .. row.unavailable.text
    elseif row.spec then right = right .. " \194\183 " .. (ProfUI.SpecName(row.spec) or "specialisation") end
    rr._src:SetText(right)
    rr._src:SetTextColor(UI.Color(row.unavailable and "danger" or "faint"))
    rr:SetAlpha(grey and 0.6 or 1)
    if selected then rr._title:SetTextColor(UI.Color("accent")) end
end

-- ── the rollup row ───────────────────────────────────────────────────────────
local function makeRollupRow(rollChild)
    local ru = CreateFrame("Frame", nil, rollChild)
    ru:SetSize(1, L.LIST_ROW_H)
    local who = fstr(ru, "body", "LEFT")
    who:SetPoint("LEFT", ru, "LEFT", 2, 0)
    who:SetWidth(84)
    local what = fstr(ru, "small", "LEFT")
    what:SetPoint("LEFT", who, "RIGHT", 4, 0)
    local when = fstr(ru, "numeral", "RIGHT")
    when:SetPoint("RIGHT", ru, "RIGHT", -2, 0)
    when:SetWidth(58)
    what:SetPoint("RIGHT", when, "LEFT", -6, 0)
    ru._who, ru._what, ru._when = who, what, when
    return ru
end

-- ── the search result block ──────────────────────────────────────────────────
local function makeSearchRow(searchChild)
    local sr = CreateFrame("Frame", nil, searchChild)
    sr:SetSize(1, L.LIST_ROW_H * 3)
    local head = fstr(sr, "body", "LEFT")
    head:SetPoint("TOPLEFT", sr, "TOPLEFT", 2, -1)
    head:SetPoint("RIGHT", sr, "RIGHT", -2, 0)
    local k = fstr(sr, "small", "LEFT")
    k:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 10, -2)
    k:SetPoint("RIGHT", sr, "RIGHT", -2, 0)
    local l = fstr(sr, "small", "LEFT")
    l:SetPoint("TOPLEFT", k, "BOTTOMLEFT", 0, -1)
    l:SetPoint("RIGHT", sr, "RIGHT", -2, 0)
    sr._head, sr._known, sr._learn = head, k, l
    return sr
end

-- ── the material row (recipe detail band) ────────────────────────────────────
local function makeMatRow(matHost)
    local mt = CreateFrame("Frame", nil, matHost)
    mt:SetSize(1, L.LIST_ROW_H - 2)
    local micon = mt:CreateTexture(nil, "ARTWORK")
    micon:SetSize(14, 14)
    micon:SetPoint("LEFT", mt, "LEFT", 2, 0)
    micon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local mtext = fstr(mt, "body", "LEFT")
    mtext:SetPoint("LEFT", micon, "RIGHT", 5, 0)
    local melse = fstr(mt, "small", "RIGHT")
    melse:SetPoint("RIGHT", mt, "RIGHT", -4, 0)
    melse:SetWidth(190)
    mtext:SetPoint("RIGHT", melse, "LEFT", -6, 0)
    mt._icon, mt._text, mt._else = micon, mtext, melse
    return mt
end

-- Class-colored short name. `extra` appends an honest overflow marker.
local function nameInk(fs, nameRealm, classTag, extra)
    fs:SetText(Dashboard.ShortName(nameRealm)
        .. ((extra and extra > 0) and (" " .. Dashboard.Colored("+" .. extra, "warn")) or ""))
    fs:SetTextColor(Dashboard.ClassColor(classTag))
end

----------------------------------------------------------------------
-- THE PANE
----------------------------------------------------------------------

local thePane = nil

Dashboard.RegisterTab("professions", function(host)
    local pane = {
        mode    = "grid",              -- "grid" | "drill" | "search"
        drill   = nil,                 -- { owner =, profKey =, spell = }
        query   = "",
        filters = { search = "", source = nil, missingOnly = false, showUnavailable = false },
        obj     = {},
        _gridRows = {}, _rollRows = {}, _recRows = {}, _searchRows = {}, _matRows = {},
        _profRows = {},
    }
    thePane = pane

    -- Persisted filter choices (additive, optional).
    local st = Dashboard.UIState and Dashboard.UIState() or {}
    st.prof = st.prof or {}
    pane.filters.source          = st.prof.source
    pane.filters.missingOnly     = st.prof.missingOnly and true or false
    pane.filters.showUnavailable = st.prof.showUnavailable and true or false
    local function persist()
        st.prof.source          = pane.filters.source
        st.prof.missingOnly     = pane.filters.missingOnly
        st.prof.showUnavailable = pane.filters.showUnavailable
    end

    -- ── TOOLBAR: the who-can-craft box + the breadcrumb ──────────────────────
    local toolbar = CreateFrame("Frame", nil, host)
    toolbar:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    toolbar:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
    toolbar:SetHeight(L.TOOLBAR_H)
    Dashboard.Tag(toolbar, "prof.toolbar")

    local who = searchBox(toolbar, "WHO CAN CRAFT", 320, function(text)
        pane.query = text or ""
        pane.mode = (pane.query ~= "") and "search" or (pane.drill and "drill" or "grid")
        pane.obj.Refresh()
    end)
    who:SetPoint("LEFT", toolbar, "LEFT", 2, 0)

    local crumb = fstr(toolbar, "small", "RIGHT")
    crumb:SetPoint("RIGHT", toolbar, "RIGHT", -2, 0)
    UI.Skin(crumb, function(self) self:SetTextColor(UI.Color("muted")) end)

    local back = UI.MakeButton(toolbar, {
        text = "\226\128\185 All characters", variant = "quiet", width = 130, height = 22,
        onClick = function() pane.CloseDrill() end,
    })
    back:SetPoint("RIGHT", crumb, "LEFT", -8, 0)
    back:Hide()

    -- ── BODY: the mode host.
    -- Deliberately a frame of its own rather than anchoring the mode panels
    -- straight to `host`: the grid and the drill-in are mutually exclusive and
    -- therefore DO sit at the same origin, which the static anchor gate reads
    -- (correctly, for its narrow rule) as two frames overlapping on a shared
    -- parent. One container makes the exclusivity structural instead of
    -- textual.
    local body = CreateFrame("Frame", nil, host)
    body:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -L.TOOLBAR_H)
    body:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
    Dashboard.Tag(body, "prof.body")

    -- ══ MODE A: the grid + the rollup ═══════════════════════════════════════
    -- Style rule 1, content hugs its natural width: the grid panel is exactly as
    -- wide as the columns it holds (name + two primaries + four secondary chips
    -- + its own padding), NOT "everything left over". The leftover goes to the
    -- rollup, which is the pane that actually wants it — recipe names are long
    -- and a cramped cooldown column is the one thing this view cannot afford to
    -- truncate.
    local gridP = panel(body, "prof.grid")
    gridP:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    gridP:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    gridP:SetWidth(ProfUI.GridWidth() + 2 * L.PANEL_PAD)

    local gridHead = CreateFrame("Frame", nil, gridP)
    gridHead:SetPoint("TOPLEFT", gridP, "TOPLEFT", L.PANEL_PAD, -L.PANEL_PAD)
    gridHead:SetPoint("TOPRIGHT", gridP, "TOPRIGHT", -L.PANEL_PAD, -L.PANEL_PAD)
    gridHead:SetHeight(L.HEAD_H)
    do
        local h = eyebrow(gridHead, "CHARACTER", "LEFT")
        h:SetPoint("LEFT", gridHead, "LEFT", 2, 0)
        for slot = 1, L.PRIMARIES do
            local ph = eyebrow(gridHead, "PRIMARY", "LEFT")
            ph:SetPoint("TOPLEFT", gridHead, "TOPLEFT", ProfUI.CellX(slot) + 2, 0)
        end
        for i, key in ipairs(ProfUI.SECONDARY_ORDER) do
            local sh = eyebrow(gridHead, ProfUI.SECONDARY_SHORT[key] or key, "LEFT")
            sh:SetPoint("TOPLEFT", gridHead, "TOPLEFT", ProfUI.SecondaryX(i), 0)
        end
    end

    local gridScroll, gridChild = scroller(gridP, "prof.grid.list")
    gridScroll:SetPoint("TOPLEFT", gridP, "TOPLEFT", L.PANEL_PAD, -(L.PANEL_PAD + L.HEAD_H + 2))
    gridScroll:SetPoint("BOTTOMRIGHT", gridP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    pane._gridChild = gridChild

    local gridEmpty = fstr(gridChild, "muted", "LEFT")
    gridEmpty:SetPoint("TOPLEFT", gridChild, "TOPLEFT", 2, -4)
    gridEmpty:SetText("No professions recorded yet \226\128\148 open a profession window on any character.")
    gridEmpty:Hide()
    pane._gridEmpty = gridEmpty

    local rollP = panel(body, "prof.rollup")
    rollP:SetPoint("TOPLEFT", gridP, "TOPRIGHT", L.GUTTER, 0)
    rollP:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)

    local rollHead = eyebrow(rollP, "COOLDOWNS", "LEFT")
    rollHead:SetPoint("TOPLEFT", rollP, "TOPLEFT", L.PANEL_PAD, -L.PANEL_PAD)
    local rollCount = fstr(rollP, "numeral", "RIGHT")
    rollCount:SetPoint("TOPRIGHT", rollP, "TOPRIGHT", -L.PANEL_PAD, -L.PANEL_PAD)
    pane._rollCount = rollCount

    local rollScroll, rollChild = scroller(rollP, "prof.rollup.list")
    rollScroll:SetPoint("TOPLEFT", rollP, "TOPLEFT", L.PANEL_PAD, -(L.PANEL_PAD + L.HEAD_H + 2))
    rollScroll:SetPoint("BOTTOMRIGHT", rollP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    pane._rollChild = rollChild

    local rollEmpty = fstr(rollChild, "muted", "LEFT")
    rollEmpty:SetPoint("TOPLEFT", rollChild, "TOPLEFT", 2, -4)
    rollEmpty:SetText("No profession cooldowns recorded.")
    rollEmpty:Hide()
    pane._rollEmpty = rollEmpty

    -- ══ MODE B: the drill-in two-pane ═══════════════════════════════════════
    local listP = panel(body, "prof.drill.list")
    listP:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    listP:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    listP:SetWidth(L.SIDE_W)
    listP:Hide()

    local drillWho = fstr(listP, "body", "LEFT")
    drillWho:SetPoint("TOPLEFT", listP, "TOPLEFT", L.PANEL_PAD, -L.PANEL_PAD)
    pane._drillWho = drillWho
    local drillHead = eyebrow(listP, "PROFESSIONS", "LEFT")
    drillHead:SetPoint("TOPLEFT", drillWho, "BOTTOMLEFT", 0, -6)

    local profScroll, profChild = scroller(listP, "prof.drill.profs")
    profScroll:SetPoint("TOPLEFT", listP, "TOPLEFT", L.PANEL_PAD, -(L.PANEL_PAD + 40))
    profScroll:SetPoint("BOTTOMRIGHT", listP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    pane._profChild = profChild

    local recP = panel(body, "prof.drill.recipes")
    recP:SetPoint("TOPLEFT", body, "TOPLEFT", ProfUI.SplitX(), 0)
    recP:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    recP:Hide()

    local filterBand = CreateFrame("Frame", nil, recP)
    filterBand:SetPoint("TOPLEFT", recP, "TOPLEFT", L.PANEL_PAD, -L.PANEL_PAD)
    filterBand:SetPoint("TOPRIGHT", recP, "TOPRIGHT", -L.PANEL_PAD, -L.PANEL_PAD)
    filterBand:SetHeight(L.FILTER_H)
    Dashboard.Tag(filterBand, "prof.filters")

    local rSearch = searchBox(filterBand, "FIND", 230, function(text)
        pane.filters.search = text or ""
        pane.obj.Refresh()
    end)
    rSearch:SetPoint("LEFT", filterBand, "LEFT", 0, 0)

    local SRC_VALUES = { false }
    local SRC_LABELS = { [false] = "All" }
    for _, k in ipairs(ProfUI.SOURCE_ORDER) do
        SRC_VALUES[#SRC_VALUES + 1] = k
        SRC_LABELS[k] = ProfUI.SOURCE_LABEL[k]
    end
    local srcChip = cycleChip(filterBand, "SOURCE", SRC_VALUES, SRC_LABELS, 150, function(v)
        pane.filters.source = v or nil
        persist(); pane.obj.Refresh()
    end)
    srcChip:SetPoint("LEFT", rSearch, "RIGHT", L.GUTTER, 0)
    srcChip:SetValue(pane.filters.source or false)

    local missChk = checkBox(filterBand, "Missing only",
        function() return pane.filters.missingOnly end,
        function(v) pane.filters.missingOnly = v; persist(); pane.obj.Refresh() end)
    missChk:SetPoint("LEFT", srcChip, "RIGHT", L.GUTTER, 0)

    local unavChk = checkBox(filterBand, "Show unavailable",
        function() return pane.filters.showUnavailable end,
        function(v) pane.filters.showUnavailable = v; persist(); pane.obj.Refresh() end)
    unavChk:SetPoint("LEFT", missChk, "RIGHT", L.GUTTER, 0)

    local recStatus = fstr(recP, "small", "RIGHT")
    recStatus:SetPoint("RIGHT", filterBand, "RIGHT", 0, 0)
    UI.Skin(recStatus, function(self) self:SetTextColor(UI.Color("muted")) end)
    pane._recStatus = recStatus

    local recScroll, recChild = scroller(recP, "prof.recipes.list")
    recScroll:SetPoint("TOPLEFT", recP, "TOPLEFT", L.PANEL_PAD, -(L.PANEL_PAD + L.FILTER_H + 4))
    recScroll:SetPoint("BOTTOMRIGHT", recP, "BOTTOMRIGHT", -L.PANEL_PAD, L.DETAIL_H + 4)
    pane._recChild = recChild

    local recEmpty = fstr(recChild, "muted", "LEFT")
    recEmpty:SetPoint("TOPLEFT", recChild, "TOPLEFT", 2, -4)
    recEmpty:Hide()
    pane._recEmpty = recEmpty

    -- The selected recipe's SOURCE + MATERIALS, pinned to the bottom of the
    -- recipe pane so the list above it never has to reflow.
    local detail = CreateFrame("Frame", nil, recP)
    detail:SetPoint("BOTTOMLEFT", recP, "BOTTOMLEFT", L.PANEL_PAD, L.PANEL_PAD)
    detail:SetPoint("BOTTOMRIGHT", recP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    detail:SetHeight(L.DETAIL_H)
    Dashboard.Tag(detail, "prof.recipe.detail")
    pane._detail = detail

    local dTitle = fstr(detail, "body", "LEFT")
    dTitle:SetPoint("TOPLEFT", detail, "TOPLEFT", 2, -2)
    dTitle:SetPoint("RIGHT", detail, "RIGHT", -2, 0)
    local dSource = fstr(detail, "small", "LEFT")
    dSource:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -3)
    dSource:SetPoint("RIGHT", detail, "RIGHT", -2, 0)
    local dMats = eyebrow(detail, "MATERIALS", "LEFT")
    dMats:SetPoint("TOPLEFT", dSource, "BOTTOMLEFT", 0, -6)
    -- The note and the reagent rows are MUTUALLY EXCLUSIVE — either we have the
    -- materials or we are saying why we do not — so they share one origin under
    -- the MATERIALS eyebrow rather than stacking with a permanently blank line
    -- between them (style rule 4: no unexplained vertical gaps). Their shared
    -- anchor is `dMats`, not the pane, so the static overlap gate's shared-parent
    -- rule is not tripped by a pair that genuinely cannot both be visible.
    local dNote = fstr(detail, "small", "LEFT")
    dNote:SetPoint("TOPLEFT", dMats, "BOTTOMLEFT", 0, -3)
    dNote:SetPoint("RIGHT", detail, "RIGHT", -2, 0)
    pane._dTitle, pane._dSource, pane._dMats, pane._dNote = dTitle, dSource, dMats, dNote

    local matHost = CreateFrame("Frame", nil, detail)
    matHost:SetPoint("TOPLEFT", dMats, "BOTTOMLEFT", 0, -3)
    matHost:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", 0, 0)
    pane._matHost = matHost

    -- ══ MODE C: the who-can-craft results ═══════════════════════════════════
    local searchP = panel(body, "prof.search")
    searchP:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    searchP:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    searchP:Hide()

    local searchHead = eyebrow(searchP, "WHO CAN CRAFT IT", "LEFT")
    searchHead:SetPoint("TOPLEFT", searchP, "TOPLEFT", L.PANEL_PAD, -L.PANEL_PAD)
    local searchStatus = fstr(searchP, "small", "RIGHT")
    searchStatus:SetPoint("TOPRIGHT", searchP, "TOPRIGHT", -L.PANEL_PAD, -L.PANEL_PAD)
    UI.Skin(searchStatus, function(self) self:SetTextColor(UI.Color("muted")) end)
    pane._searchStatus = searchStatus

    local sScroll, searchChild = scroller(searchP, "prof.search.list")
    sScroll:SetPoint("TOPLEFT", searchP, "TOPLEFT", L.PANEL_PAD, -(L.PANEL_PAD + L.HEAD_H + 2))
    sScroll:SetPoint("BOTTOMRIGHT", searchP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    pane._searchChild = searchChild

    local searchEmpty = fstr(searchChild, "muted", "LEFT")
    searchEmpty:SetPoint("TOPLEFT", searchChild, "TOPLEFT", 2, -4)
    pane._searchEmpty = searchEmpty

    ----------------------------------------------------------------------
    -- Mode switching + tooltips
    ----------------------------------------------------------------------

    function pane.OpenDrill(ownerKey, profKey)
        pane.drill = { owner = ownerKey, profKey = profKey, spell = nil }
        pane.mode = "drill"
        pane.obj.Refresh()
    end
    function pane.CloseDrill()
        pane.drill = nil
        pane.mode = (pane.query ~= "") and "search" or "grid"
        pane.obj.Refresh()
    end
    function pane.SelectRecipe(spell)
        if pane.drill then pane.drill.spell = spell end
        pane.obj.Refresh()
    end

    function pane.CellTooltip(cell)
        local m = cell._model
        if not m then return end
        GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ProfUI.ProfName(m.key), UI.Color("text"))
        if m.level then
            GameTooltip:AddLine("Skill " .. m.level .. " / " .. tostring(m.cap or "?"), UI.Color("muted"))
        else
            GameTooltip:AddLine("Skill not recorded yet", UI.Color("faint"))
        end
        if m.hasSpec and m.specs then
            local names = {}
            for i = 1, #m.specs do
                local D = core()
                local idx = D and D.specById and D.specById[m.specs[i]]
                local sp = idx and D.specs[idx]
                names[#names + 1] = (sp and sp.name) or tostring(m.specs[i])
            end
            GameTooltip:AddLine("Specialisation: " .. table.concat(names, ", "), UI.Color("accent"))
        end
        if m.scanned then
            GameTooltip:AddLine(tostring(m.known or 0) .. " of " .. tostring(m.total)
                .. " recipes known", UI.Color("muted"))
            if m.drift and m.drift > 0 then
                GameTooltip:AddLine(m.drift .. " known recipe(s) our catalogue does not carry",
                    UI.Color("warn"))
            end
        else
            GameTooltip:AddLine("Recipes NOT CHECKED \226\128\148 open this profession's window",
                UI.Color("faint"))
            GameTooltip:AddLine("on that character once to fill it in.", UI.Color("faint"))
        end
        if m.cd then
            if m.cd.state == "ready" then
                GameTooltip:AddLine("Cooldown ready", UI.Color("ok"))
            else
                GameTooltip:AddLine("Cooldown in "
                    .. Dashboard.FormatDuration(m.cd.remaining), UI.Color("warn"))
            end
        end
        GameTooltip:Show()
    end

    ----------------------------------------------------------------------
    -- Renderers
    ----------------------------------------------------------------------

    local function getGridRow(i)
        local r = pane._gridRows[i]
        if not r then r = makeGridRow(gridChild, pane); pane._gridRows[i] = r end
        return r
    end
    local function getRollRow(i)
        local r = pane._rollRows[i]
        if not r then r = makeRollupRow(rollChild); pane._rollRows[i] = r end
        return r
    end
    local function getRecRow(i)
        local r = pane._recRows[i]
        if not r then r = makeRecipeRow(recChild, pane); pane._recRows[i] = r end
        return r
    end
    local function getSearchRow(i)
        local r = pane._searchRows[i]
        if not r then r = makeSearchRow(searchChild); pane._searchRows[i] = r end
        return r
    end
    local function getMatRow(i)
        local r = pane._matRows[i]
        if not r then r = makeMatRow(matHost); pane._matRows[i] = r end
        return r
    end
    local function getProfRow(i)
        local r = pane._profRows[i]
        if not r then
            local pr = CreateFrame("Button", nil, profChild)
            pr:SetSize(1, L.ROW_H - 4)
            local ph = pr:CreateTexture(nil, "HIGHLIGHT")
            ph:SetAllPoints()
            UI.Skin(ph, function(self) self:SetColorTexture(UI.Color("accent", 0.12)) end)
            pr:SetHighlightTexture(ph)
            local pi = pr:CreateTexture(nil, "ARTWORK")
            pi:SetSize(L.ICON, L.ICON)
            pi:SetPoint("LEFT", pr, "LEFT", 2, 0)
            pi:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            local pn = fstr(pr, "body", "LEFT")
            pn:SetPoint("LEFT", pi, "RIGHT", 6, 0)
            local pl = fstr(pr, "numeral", "RIGHT")
            pl:SetPoint("RIGHT", pr, "RIGHT", -4, 0)
            pl:SetWidth(64)
            pn:SetPoint("RIGHT", pl, "LEFT", -4, 0)
            pr._icon, pr._name, pr._lvl = pi, pn, pl
            pr:SetScript("OnClick", function(self)
                if self._profKey and pane.drill then pane.OpenDrill(pane.drill.owner, self._profKey) end
            end)
            r = pr
            pane._profRows[i] = r
        end
        return r
    end

    local function renderGrid(entries, lookup, nowE)
        local rows = ProfUI.GridRows(entries, lookup, nowE)
        local W = math.max(ProfUI.GridWidth(), gridScroll:GetWidth() or 1)
        gridChild:SetWidth(W)
        for _, r in ipairs(pane._gridRows) do r:Hide() end
        local shown, y = 0, 0
        for i = 1, #rows do
            local model = rows[i]
            if model.hasAny then
                shown = shown + 1
                local gr = getGridRow(shown)
                gr:ClearAllPoints()
                gr:SetPoint("TOPLEFT", gridChild, "TOPLEFT", 0, -y)
                gr:SetWidth(W)
                nameInk(gr._name, model.key, model.classTag, model.overflow)
                for slot = 1, L.PRIMARIES do
                    paintCell(gr._cells[slot], model.primaries[slot], model.key, false)
                end
                for si, profKey in ipairs(ProfUI.SECONDARY_ORDER) do
                    paintCell(gr._secs[si], model.secondaries[profKey], model.key, true)
                end
                gr:Show()
                y = y + L.ROW_H
            end
        end
        gridChild:SetHeight(math.max(y, 1))
        pane._gridEmpty:SetShown(shown == 0)
    end

    local function renderRollup(entries, lookup, nowE, res)
        local rows = ProfUI.RollupRows(entries, lookup, nowE, res)
        local ready = ProfUI.ReadyCount(rows)
        rollCount:SetText(ready > 0 and (ready .. " ready") or "")
        rollCount:SetTextColor(UI.Color(ready > 0 and "ok" or "muted"))
        rollChild:SetWidth(math.max(1, rollScroll:GetWidth() or 1))
        for _, r in ipairs(pane._rollRows) do r:Hide() end
        local pending, y = {}, 0
        for i = 1, #rows do
            local row = rows[i]
            if row.pending then pending[#pending + 1] = tonumber(row.cdKey) end
            local ru = getRollRow(i)
            ru:ClearAllPoints()
            ru:SetPoint("TOPLEFT", rollChild, "TOPLEFT", 0, -y)
            ru:SetPoint("RIGHT", rollChild, "RIGHT", 0, 0)
            nameInk(ru._who, row.owner, row.classTag)
            ru._what:SetText(row.label or "\226\128\166")
            ru._what:SetTextColor(UI.Color("muted"))
            if row.ready then
                ru._when:SetText("\226\156\147 ready")
                ru._when:SetTextColor(UI.Color("ok"))
            else
                ru._when:SetText(Dashboard.FormatDuration(row.remaining, "compact"))
                ru._when:SetTextColor(UI.Color("warn"))
            end
            ru:Show()
            y = y + L.LIST_ROW_H
        end
        rollChild:SetHeight(math.max(y, 1))
        pane._rollEmpty:SetShown(#rows == 0)
        notePending("spell", pending)
    end

    local function renderMaterials(spell, ownerKey, res)
        for _, r in ipairs(pane._matRows) do r:Hide() end
        if not spell then
            pane._dNote:SetText("Select a recipe to see what it costs.")
            pane._dNote:SetTextColor(UI.Color("faint"))
            pane._dNote:Show()
            return
        end
        local rows, state, pending = ProfUI.MaterialRows(spell, reagentStore(), ownerKey,
                                                         inventoryLookup(), res)
        -- ABSENCE IS NOT ZERO. No harvest for this recipe means nobody on this
        -- account has had its window open since the module arrived — so the
        -- panel says exactly that, and exactly what fixes it, instead of drawing
        -- a materials list of nothing.
        if state == "unharvested" then
            pane._dNote:SetText("Materials not yet harvested \226\128\148 open "
                .. ProfUI.ProfName(pane.drill and pane.drill.profKey or "")
                .. " on " .. Dashboard.ShortName(ownerKey) .. " once.")
            pane._dNote:SetTextColor(UI.Color("warn"))
            pane._dNote:Show()
            return
        end
        pane._dNote:Hide()
        local y = 0
        for i = 1, #rows do
            local row = rows[i]
            local mt = getMatRow(i)
            mt:ClearAllPoints()
            mt:SetPoint("TOPLEFT", matHost, "TOPLEFT", 0, -y)
            mt:SetPoint("RIGHT", matHost, "RIGHT", 0, 0)
            mt._icon:SetTexture(Dashboard.ItemIcon(row.itemID))
            local left, right = ProfUI.MaterialText(row)
            mt._text:SetText(left)
            mt._text:SetTextColor(UI.Color(row.enough and "ok" or (row.mine == nil and "faint" or "warn")))
            mt._else:SetText(right or "")
            mt._else:SetTextColor(UI.Color("muted"))
            mt:Show()
            y = y + (L.LIST_ROW_H - 2)
        end
        notePending("item", pending)
    end

    local function renderDrill(lookup, nowE, res)
        local d = pane.drill
        if not d then return end
        local payload = lookup(d.owner)
        nameInk(drillWho, d.owner, (function()
            local rec = Dashboard.ResolveRosterOwner and select(1, Dashboard.ResolveRosterOwner(d.owner))
            return rec and rec.classTag or nil
        end)())

        -- LEFT: this character's professions.
        local list = ProfUI.ProfessionList(payload, nowE)
        profChild:SetWidth(math.max(1, profScroll:GetWidth() or 1))
        for _, r in ipairs(pane._profRows) do r:Hide() end
        local y = 0
        for i = 1, #list do
            local m = list[i]
            local pr = getProfRow(i)
            pr._profKey = m.key
            pr:ClearAllPoints()
            pr:SetPoint("TOPLEFT", profChild, "TOPLEFT", 0, -y)
            pr:SetPoint("RIGHT", profChild, "RIGHT", 0, 0)
            pr._icon:SetTexture(ProfUI.ProfIcon(m.key) or "Interface\\Icons\\INV_Misc_QuestionMark")
            pr._name:SetText(ProfUI.ProfName(m.key))
            pr._name:SetTextColor(UI.Color(m.key == d.profKey and "accent" or "text"))
            pr._lvl:SetText(m.level and (m.level .. "/" .. tostring(m.cap or "?")) or "\226\128\148")
            pr._lvl:SetTextColor(UI.Color(m.level and "muted" or "faint"))
            pr:Show()
            y = y + (L.ROW_H - 4)
        end
        profChild:SetHeight(math.max(y, 1))

        -- RIGHT: the recipe list.
        local rows, pending, state = ProfUI.RecipeRows(payload, d.profKey, pane.filters, res)
        recChild:SetWidth(math.max(1, recScroll:GetWidth() or 1))
        for _, r in ipairs(pane._recRows) do r:Hide() end
        local ry = 0
        for i = 1, #rows do
            local rr = getRecRow(i)
            rr:ClearAllPoints()
            rr:SetPoint("TOPLEFT", recChild, "TOPLEFT", 0, -ry)
            rr:SetPoint("RIGHT", recChild, "RIGHT", 0, 0)
            paintRecipeRow(rr, rows[i], rows[i].spell == d.spell)
            rr:Show()
            ry = ry + L.LIST_ROW_H
        end
        recChild:SetHeight(math.max(ry, 1))

        local emptyText, statusText = ProfUI.StatusText({
            hasQuery = true, rows = #rows, pending = #pending,
            exhausted = (watcher == nil), noun = "name",
        })
        if state == "unscanned" then
            emptyText = "Not checked yet \226\128\148 open "
                .. ProfUI.ProfName(d.profKey) .. " on " .. Dashboard.ShortName(d.owner)
                .. " once and this list fills in."
        end
        pane._recEmpty:SetText((#rows == 0) and (emptyText or "No recipes match.") or "")
        pane._recEmpty:SetShown(#rows == 0)
        recStatus:SetText(statusText or "")

        -- The selected recipe's source + materials.
        if d.spell then
            local nm = res.spell and res.spell(d.spell) or nil
            pane._dTitle:SetText(nm or "\226\128\166")
            pane._dTitle:SetTextColor(UI.Color("text"))
            local src = ProfUI.SourceModel(d.spell)
            local line = src and (#src.lines > 0 and table.concat(src.lines, "  \194\183  ") or src.text) or ""
            if src and src.unavailable then
                line = line .. "   [unavailable \226\128\148 " .. src.unavailable.text .. "]"
            end
            pane._dSource:SetText(line)
            pane._dSource:SetTextColor(UI.Color(src and src.unavailable and "danger" or "muted"))
        else
            pane._dTitle:SetText("")
            pane._dSource:SetText("")
        end
        renderMaterials(d.spell, d.owner, res)
        notePending("spell", pending)
    end

    local function renderSearch(entries, lookup, res)
        local rows, pending, truncated = ProfUI.SearchRows(pane.query, entries, lookup, res)
        searchChild:SetWidth(math.max(1, sScroll:GetWidth() or 1))
        for _, r in ipairs(pane._searchRows) do r:Hide() end
        local y = 0
        local function joinNames(list)
            local parts = {}
            for i = 1, #list do
                parts[#parts + 1] = Dashboard.ColoredName(list[i].nameRealm,
                    list[i].rec and list[i].rec.classTag or nil)
            end
            return table.concat(parts, ", ")
        end
        for i = 1, #rows do
            local row = rows[i]
            local sr = getSearchRow(i)
            sr:ClearAllPoints()
            sr:SetPoint("TOPLEFT", searchChild, "TOPLEFT", 0, -y)
            sr:SetPoint("RIGHT", searchChild, "RIGHT", 0, 0)
            sr._head:SetText(row.name .. "   "
                .. Dashboard.Colored(ProfUI.ProfName(row.profKey), "muted"))
            sr._head:SetTextColor(UI.Color("text"))
            sr._known:SetText((#row.known > 0)
                and ("Known: " .. joinNames(row.known))
                or "Known: nobody")
            sr._known:SetTextColor(UI.Color(#row.known > 0 and "ok" or "faint"))
            local learnText = (#row.learnable > 0) and ("Can learn: " .. joinNames(row.learnable)) or ""
            -- The third state survives all the way out to the search results:
            -- an alt whose profession was never scanned is COUNTED, never
            -- folded into "cannot".
            if #row.unchecked > 0 then
                learnText = learnText .. ((learnText ~= "") and "   " or "")
                    .. Dashboard.Colored("not checked: " .. #row.unchecked, "faint")
            end
            sr._learn:SetText(learnText)
            sr._learn:SetTextColor(UI.Color("muted"))
            sr:Show()
            y = y + L.LIST_ROW_H * 3
        end
        searchChild:SetHeight(math.max(y, 1))

        local emptyText, statusText = ProfUI.StatusText({
            hasQuery = (pane.query ~= ""), rows = #rows, pending = #pending,
            exhausted = (watcher == nil), noun = "recipe name",
        })
        pane._searchEmpty:SetText(emptyText or "")
        pane._searchEmpty:SetShown((emptyText ~= nil))
        searchStatus:SetText(truncated and "showing the first "
            .. ProfUI.SEARCH_LIMIT .. " \226\128\148 refine the search" or (statusText or ""))
        notePending("spell", pending)
    end

    ----------------------------------------------------------------------
    -- Refresh / Repaint
    ----------------------------------------------------------------------

    function pane.obj.Refresh()
        if not enabled() then
            gridP:Hide(); rollP:Hide(); listP:Hide(); recP:Hide(); searchP:Hide()
            return
        end
        local nowE = now()
        local res = ProfUI.LiveResolver()
        local entries = ProfUI.Roster()
        local lookup = payloadLookup()
        pane._entries, pane._lookup = entries, lookup

        local isDrill  = (pane.mode == "drill" and pane.drill ~= nil)
        local isSearch = (pane.mode == "search")
        gridP:SetShown(not isDrill and not isSearch)
        rollP:SetShown(not isDrill and not isSearch)
        listP:SetShown(isDrill)
        recP:SetShown(isDrill)
        searchP:SetShown(isSearch)
        back:SetShown(isDrill)
        crumb:SetText(isDrill and (Dashboard.ShortName(pane.drill.owner) .. " \226\128\186 "
            .. ProfUI.ProfName(pane.drill.profKey)) or "")

        if isSearch then
            renderSearch(entries, lookup, res)
        elseif isDrill then
            renderDrill(lookup, nowE, res)
        else
            renderGrid(entries, lookup, nowE)
            renderRollup(entries, lookup, nowE, res)
        end
        if Dashboard.RefreshTabStrip then Dashboard.RefreshTabStrip() end
    end

    -- THE CHEAP HALF. Everything one second changes here is a COUNTDOWN, and a
    -- countdown needs neither a fresh roster gather (which re-derives online
    -- winners across the whole store) nor a re-sort nor a scroll reset. So the
    -- ticker re-renders from the entries the last full Refresh already gathered.
    -- Membership, selection and store changes still arrive as engine events and
    -- still run the full Refresh. Search results carry no clock at all, so that
    -- mode simply does not tick.
    function pane.obj.Repaint()
        if not enabled() then return end
        if pane.mode == "search" then return end
        local entries, lookup = pane._entries, pane._lookup
        if not (entries and lookup) then return pane.obj.Refresh() end
        local nowE = now()
        local res = ProfUI.LiveResolver()
        if pane.mode == "drill" and pane.drill then
            renderDrill(lookup, nowE, res)
        else
            renderGrid(entries, lookup, nowE)
            renderRollup(entries, lookup, nowE, res)
        end
        if Dashboard.RefreshTabStrip then Dashboard.RefreshTabStrip() end
    end
    repaintPane = function() if thePane then thePane.obj.Refresh() end end

    local tickAccum = 0
    host:SetScript("OnUpdate", function(self, elapsed)
        local fire
        if ns.Cards and ns.Cards.RepaintTick then
            tickAccum, fire = ns.Cards.RepaintTick(tickAccum, elapsed, self:IsVisible(), 1)
        end
        if fire then ns:SafeCall(pane.obj.Repaint) end
    end)

    gridScroll:SetScript("OnSizeChanged", function() pane.obj.Refresh() end)
    pane.obj.Refresh()
    return pane.obj
end)

----------------------------------------------------------------------
-- THE LOGIN LINE — one line, once, and only if there is something to say.
----------------------------------------------------------------------

ProfUI._loginLineFired = false

function ProfUI.FireLoginLine()
    if ProfUI._loginLineFired then return false, "already-fired" end
    if not enabled() then return false, "disabled" end
    if not ProfUI.LoginLineEnabled() then
        ProfUI._loginLineFired = true      -- latch anyway: the answer is settled
        return false, "off"
    end
    ProfUI._loginLineFired = true
    local rows = ProfUI.RollupRows(ProfUI.Roster(), payloadLookup(), now())
    local line = ProfUI.LoginLine(rows)
    if not line then return false, "nothing-ready" end
    ns:Print(line)
    return true, line
end

-- Late enough that peer payloads delivered at login have landed and the store
-- is warm; early enough to be part of logging in. No sound, no popup, no
-- repeat — the quiet philosophy the owner signed off on.
ns:On("LOGIN", function()
    if not enabled() then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(12, function() ns:SafeCall(ProfUI.FireLoginLine) end)
    end
end)

----------------------------------------------------------------------
-- DIAGNOSTICS  (the style guide's standing rule: every visual system ships a
-- debug affordance).
----------------------------------------------------------------------

ns:RegisterDebugCommand("professionsui", function()
    ns:Print("professions view: module " .. (enabled() and "enabled" or "DISABLED")
        .. " | pane " .. (thePane and ("built, mode " .. tostring(thePane.mode)) or "not built")
        .. " | cold-name watcher " .. (watcher and "up" or "idle"))
    local entries = ProfUI.Roster()
    local lookup = payloadLookup()
    local rows = ProfUI.RollupRows(entries, lookup, now())
    ns:Print(string.format("  roster %d character(s), %d cooldown row(s), %d ready",
        #entries, #rows, ProfUI.ReadyCount(rows)))
    for i = 1, math.min(#rows, 8) do
        local r = rows[i]
        ns:Print(string.format("    %-20s %-28s %s", r.owner, tostring(r.label or "?"),
            r.ready and "READY" or (r.remaining .. "s")))
    end
    ns:Print("  login line: " .. (ProfUI.LoginLineEnabled() and "on" or "off")
        .. ", " .. (ProfUI._loginLineFired and "already fired this session" or "not fired yet"))
    local grid = ProfUI.GridRows(entries, lookup, now())
    local unscanned = 0
    for i = 1, #grid do
        for _, c in ipairs(grid[i].primaries) do if c and not c.scanned then unscanned = unscanned + 1 end end
        for _, c in pairs(grid[i].secondaries) do if c and not c.scanned then unscanned = unscanned + 1 end end
    end
    ns:Print("  grid: " .. #grid .. " row(s), " .. unscanned .. " never-scanned profession cell(s)")
end)

-- ════════════════════════════════════════════════════════════════════════════
--  SELF-TEST  (suite "professionsui")
--
--  Everything here drives the PURE layer off fixtures. The fixture's recipe ids
--  are pulled out of the SHIPPED dataset rather than hardcoded, so regenerating
--  professions_data.lua cannot silently turn these tests into assertions about
--  ids that no longer exist.
-- ════════════════════════════════════════════════════════════════════════════

local function fixtureEntries()
    return {
        { nameRealm = "Aaa-Realm", rec = { classTag = "MAGE",   level = 60 }, online = true },
        { nameRealm = "Bbb-Realm", rec = { classTag = "ROGUE",  level = 60 }, online = false },
        { nameRealm = "Ccc-Realm", rec = { classTag = "PRIEST", level = 42 }, online = false },
    }
end

-- A resolver that answers for a named set of ids and holds everything else.
local function fakeResolver(spellNames, itemNames)
    return {
        spell = function(id) return spellNames and spellNames[id] or nil end,
        item  = function(id) return itemNames and itemNames[id] or nil end,
    }
end

local function pickProf(D, key, n)
    local idx = D.profIdx[key]
    local list = D.profRecipes[idx]
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

local function testGridModel(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local P = ns.Professions
    local D = core()
    ck(D ~= nil, "the dataset would not load for the grid tests")
    if not D then return end

    local ids = pickProf(D, "tailoring", 3)
    local bits = P.EncodeKnown("tailoring", { ids[1], ids[2] })
    local NOW = 1700000000

    local payloads = {
        ["Aaa-Realm"] = {
            v = 1, ds = D.Version and D.Version() or ns.ProfessionsDataMeta.version,
            p = {
                tailoring = { l = 300, m = 300, t = 4, k = bits, n = 2, a = NOW - 100 },
                -- NEVER SCANNED: the profession is proven present, the window
                -- has never been opened. This is the row the whole module exists
                -- to render honestly.
                enchanting = { l = 285, m = 300, t = 4 },
                -- SCANNED and genuinely empty: a proven zero, which is a
                -- different fact from the unchecked profession above it and
                -- must render as 0, not as an em dash.
                cooking   = { l = 300, m = 300, t = 4,
                              k = P.EncodeKnown("cooking", {}), n = 0, a = NOW - 100 },
            },
            c = { ["g1"] = NOW + 3600 },
        },
        ["Bbb-Realm"] = {
            v = 1, ds = "some-other-dataset",
            p = { tailoring = { l = 300, m = 300, k = bits, n = 2, a = NOW } },
            c = {},
        },
        ["Ccc-Realm"] = nil,
    }
    local lookup = function(k) return payloads[k] end

    local rows = ProfUI.GridRows(fixtureEntries(), lookup, NOW)
    ck(#rows == 3, "the grid dropped a roster row (got " .. #rows .. ")")
    ck(rows[1].key == "Aaa-Realm", "the grid did not keep the roster order it was handed")
    ck(rows[3].hasAny == false, "a character with no professions record claimed professions")

    -- The three states, one per assertion.
    local aaa = rows[1]
    local prim = {}
    for _, c in ipairs(aaa.primaries) do prim[c.key] = c end
    ck(prim.tailoring ~= nil and prim.tailoring.scanned == true,
       "a scanned profession did not report itself scanned")
    ck(prim.tailoring and prim.tailoring.known == 2, "the known count did not come through")
    ck(prim.enchanting ~= nil, "a never-scanned profession vanished from the grid")
    ck(prim.enchanting and prim.enchanting.scanned == false,
       "a never-scanned profession claimed to be scanned")
    ck(prim.enchanting and prim.enchanting.known == nil,
       "a never-scanned profession reported a KNOWN COUNT \226\128\148 that is the zero-lie")
    ck(prim.enchanting and prim.enchanting.level == 285,
       "the skill level was dropped along with the unknown recipe set")
    ck(aaa.secondaries.cooking ~= nil and aaa.secondaries.cooking.scanned == true,
       "a scanned SECONDARY with an empty known set was treated as unscanned")
    ck(aaa.secondaries.cooking and aaa.secondaries.cooking.known == 0,
       "a proven-empty known set should be 0, not nil")

    -- Dataset drift: a payload written under another dataset version decodes to
    -- nil, and nil is UNKNOWN — never "knows nothing".
    local bbb = rows[2]
    ck(bbb.primaries[1] and bbb.primaries[1].scanned == false,
       "a foreign-dataset payload was decoded instead of refused")

    -- KnownSet must agree with Professions.KnownState for EVERY recipe of the
    -- profession. Two readers, one truth.
    local set = ProfUI.KnownSet(payloads["Aaa-Realm"], "tailoring")
    local list = D.profRecipes[D.profIdx.tailoring]
    local disagreements = 0
    for i = 1, #list do
        local state = P.KnownState(payloads["Aaa-Realm"], "tailoring", list[i])
        local mine = set[list[i]] and "known" or "missing"
        if state ~= mine then disagreements = disagreements + 1 end
    end
    ck(disagreements == 0, "KnownSet and KnownState disagreed on " .. disagreements .. " recipe(s)")
    local nilSet, nilState = ProfUI.KnownSet(payloads["Aaa-Realm"], "enchanting")
    ck(nilSet == nil and nilState == "unscanned", "a never-scanned profession returned a SET")
    ck(P.KnownState(payloads["Aaa-Realm"], "enchanting", list[1]) == "unknown",
       "P1's own reader disagrees about the third state")

    -- Cooldown decay + the ready flip, on the cell.
    local cd = prim.alchemy
    ck(aaa.primaries[1] ~= nil, "the primaries slots came out empty")
    local cell = ProfUI.CellModel(payloads["Aaa-Realm"], "tailoring", NOW)
    ck(cell.cd == nil, "a profession with no cooldown key invented one")
    local alch = { p = { alchemy = { l = 300, m = 300 } }, c = { ["g1"] = NOW + 600 } }
    local ac = ProfUI.CellModel(alch, "alchemy", NOW)
    ck(ac.cd and ac.cd.state == "running" and ac.cd.remaining == 600,
       "the cooldown did not decay to 600s")
    local ac2 = ProfUI.CellModel(alch, "alchemy", NOW + 600)
    ck(ac2.cd and ac2.cd.state == "ready", "an elapsed cooldown did not flip to ready")
    local ac3 = ProfUI.CellModel(alch, "alchemy", NOW + 99999)
    ck(ac3.cd and ac3.cd.state == "ready" and ProfUI.CooldownRemaining(NOW + 600, NOW + 99999) == 0,
       "a long-elapsed cooldown went negative instead of flooring at ready")

    -- Layout maths stay a pure function of LAYOUT.
    ck(ProfUI.CellX(1) == L.NAME_W, "the first primary column moved off the name column")
    ck(ProfUI.CellX(2) == L.NAME_W + L.CELL_W + L.CELL_GAP, "the second primary column is mis-pitched")
    ck(ProfUI.SecondaryX(2) - ProfUI.SecondaryX(1) == L.SEC_W + L.SEC_GAP,
       "the secondary chips are mis-pitched")
    ck(ProfUI.GridRowY(3) == 2 * L.ROW_H, "the grid row pitch is not ROW_H")
end

local function testRollup(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local D = core()
    if not D then fails[#fails + 1] = "dataset unavailable for the rollup tests" return end
    local NOW = 1700000000
    local trans = nil
    for spell, rec in pairs(D.recipe) do
        if rec.cd and rec.cd > 0 then trans = spell break end
    end
    ck(trans ~= nil, "the dataset carries no shared-cooldown recipe to test with")

    local payloads = {
        ["Aaa-Realm"] = { p = {}, c = { ["g1"] = NOW + 7200, ["12345"] = NOW - 5 } },
        ["Bbb-Realm"] = { p = {}, c = { ["999"] = NOW + 60 } },
        ["Ccc-Realm"] = { p = {}, c = {} },
    }
    local rows = ProfUI.RollupRows(fixtureEntries(), function(k) return payloads[k] end, NOW,
                                   fakeResolver({ [999] = "Mooncloth" }))
    ck(#rows == 3, "the rollup lost a cooldown row (got " .. #rows .. ")")
    ck(rows[1].ready == true, "the rollup did not put a READY cooldown first")
    ck(rows[2].remaining == 60 and rows[3].remaining == 7200,
       "the rollup did not order the running cooldowns soonest-first")
    ck(ProfUI.ReadyCount(rows) == 1, "the ready count is wrong")

    -- A group key never wears a member's name.
    local label = ProfUI.CooldownLabel("g1")
    ck(type(label) == "string" and label:find("shared", 1, true) ~= nil,
       "a shared-cooldown group did not label itself as shared")
    -- A spell the resolver has not answered for is PENDING, not "unknown recipe".
    local _, pending = ProfUI.CooldownLabel("12345", fakeResolver({}))
    ck(pending == true, "a cold recipe name was not reported pending")

    -- Determinism: same input, same order, twice.
    local again = ProfUI.RollupRows(fixtureEntries(), function(k) return payloads[k] end, NOW,
                                     fakeResolver({ [999] = "Mooncloth" }))
    local same = true
    for i = 1, #rows do if rows[i].cdKey ~= again[i].cdKey then same = false end end
    ck(same, "two rollups of the same store came out in different orders")
end

local function testFilters(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local P = ns.Professions
    local D = core()
    if not D then fails[#fails + 1] = "dataset unavailable for the filter tests" return end
    local ids = pickProf(D, "alchemy", 6)
    local bits = P.EncodeKnown("alchemy", { ids[1], ids[2] })
    local NOW = 1700000000
    local payload = {
        v = 1, ds = ns.ProfessionsDataMeta.version,
        p = { alchemy = { l = 300, m = 300, k = bits, n = 2, a = NOW } }, c = {},
    }
    local names = {}
    for i = 1, #ids do names[ids[i]] = "Fixture Recipe " .. i end
    local res = fakeResolver(names)

    local all = ProfUI.RecipeRows(payload, "alchemy", { showUnavailable = true }, res)
    ck(#all >= 6, "the unfiltered recipe list came back short (" .. #all .. ")")
    local knownN, missingN = 0, 0
    for _, r in ipairs(all) do
        if r.state == "known" then knownN = knownN + 1 elseif r.state == "missing" then missingN = missingN + 1 end
    end
    ck(knownN == 2, "the known rows did not match the bitmap (" .. knownN .. ")")
    ck(missingN == #all - 2, "the missing rows do not account for the rest")

    local missing = ProfUI.RecipeRows(payload, "alchemy",
        { missingOnly = true, showUnavailable = true }, res)
    ck(#missing == missingN, "missing-only did not equal the missing count")
    for _, r in ipairs(missing) do
        if r.state ~= "missing" then fails[#fails + 1] = "missing-only let a " .. r.state .. " row through" break end
    end

    -- THE THIRD STATE: a never-scanned profession shows every recipe as
    -- UNKNOWN, and missing-only shows NOTHING — claiming 111 missing recipes
    -- for a character we never looked at is the exact lie this module exists to
    -- avoid.
    local cold = { v = 1, ds = ns.ProfessionsDataMeta.version,
                   p = { alchemy = { l = 300, m = 300 } }, c = {} }
    local coldRows, _, coldState = ProfUI.RecipeRows(cold, "alchemy", { showUnavailable = true }, res)
    ck(coldState == "unscanned", "a never-scanned profession did not report unscanned")
    local badState = false
    for _, r in ipairs(coldRows) do if r.state ~= "unknown" then badState = true end end
    ck(not badState, "a never-scanned profession produced known/missing rows")
    local coldMissing = ProfUI.RecipeRows(cold, "alchemy",
        { missingOnly = true, showUnavailable = true }, res)
    ck(#coldMissing == 0, "missing-only invented missing recipes for an unchecked character")

    -- Source filter, off the dataset's own derived mask.
    local trainers = ProfUI.RecipeRows(payload, "alchemy",
        { source = "trainer", showUnavailable = true }, res)
    ck(#trainers > 0, "the trainer source filter matched nothing at all")
    ck(#trainers < #all, "the trainer source filter matched everything (it is not filtering)")
    for _, r in ipairs(trainers) do
        if not (r.classes and r.classes.trainer) then
            fails[#fails + 1] = "the source filter let a non-trainer row through" break
        end
    end

    -- The unavailable toggle. Every unavailable row must carry a REASON — a
    -- greyed row with no explanation is a worse answer than no row.
    local shown = ProfUI.RecipeRows(payload, "alchemy", { showUnavailable = true }, res)
    local hidden = ProfUI.RecipeRows(payload, "alchemy", { showUnavailable = false }, res)
    ck(#hidden <= #shown, "hiding unavailables produced MORE rows")
    for _, r in ipairs(shown) do
        if r.unavailable and (type(r.unavailable.text) ~= "string" or r.unavailable.text == "") then
            fails[#fails + 1] = "an unavailable row carries no reason" break
        end
    end
    for _, r in ipairs(hidden) do
        if r.unavailable then fails[#fails + 1] = "an unavailable row survived the toggle being off" break end
    end
    -- Q7's DEFAULT is obtainable-now: an absent option must behave like "off",
    -- not like "no opinion".
    local defaulted = ProfUI.RecipeRows(payload, "alchemy", {}, res)
    ck(#defaulted == #hidden, "the default (no options at all) is not obtainable-now")

    -- Search: a name that has not answered is HELD, never scored as a miss.
    local hit = ProfUI.RecipeRows(payload, "alchemy",
        { search = "Fixture Recipe 1", showUnavailable = true }, res)
    ck(#hit >= 1, "the recipe search found nothing for a name it was given")
    local coldRes = fakeResolver({})
    local coldHit, coldPending = ProfUI.RecipeRows(payload, "alchemy",
        { search = "anything", showUnavailable = true }, coldRes)
    ck(#coldHit == 0, "a search matched a recipe whose name never loaded")
    ck(#coldPending > 0, "cold recipe names were not reported as pending")
    local empty, status = ProfUI.StatusText({ hasQuery = true, rows = 0,
        pending = #coldPending, exhausted = false, noun = "name" })
    ck(type(empty) == "string" and empty:find("Still loading", 1, true) == 1,
       "a cold empty result did not say it was still loading")
    local empty2 = ProfUI.StatusText({ hasQuery = true, rows = 0, pending = 0, exhausted = false })
    ck(empty2 == "No match.", "a genuinely empty result did not say so plainly")
    ck(ProfUI.LadderDelay(#ProfUI.WATCH_LADDER + 1) == nil,
       "the re-ask ladder has no last rung")
end

local function testMaterials(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local SPELL, CLOTH, THREAD = 8776, 14047, 14341
    local reagents = { [SPELL] = { o = 14152, n = 1, r = { [CLOTH] = 10, [THREAD] = 2 } } }
    local inv = {
        ["Aaa-Realm"] = { [CLOTH] = 8 },
        ["Bbb-Realm"] = { [CLOTH] = 200, [THREAD] = 40 },
        ["Ccc-Realm"] = { [THREAD] = 5 },
    }
    local function invLookup(key)
        if key == nil then return inv end
        return inv[key]
    end
    local res = fakeResolver(nil, { [CLOTH] = "Runecloth", [THREAD] = "Rune Thread" })

    local rows, state, pending, made = ProfUI.MaterialRows(SPELL, reagents, "Aaa-Realm", invLookup, res)
    ck(state == "harvested", "a harvested recipe did not report harvested")
    ck(#rows == 2, "the reagent rows came out wrong (" .. #rows .. ")")
    ck(made and made.produces == 14152 and made.yield == 1, "the produced item/yield did not survive")

    local byID = {}
    for _, r in ipairs(rows) do byID[r.itemID] = r end
    ck(byID[CLOTH].mine == 8 and byID[CLOTH].need == 10, "the owner's own count did not join")
    ck(byID[CLOTH].enough == false, "8 of 10 was reported as enough")
    ck(#byID[CLOTH].others == 1 and byID[CLOTH].others[1].key == "Bbb-Realm"
        and byID[CLOTH].others[1].count == 200, "the mesh holder did not join")
    local left, right = ProfUI.MaterialText(byID[CLOTH])
    ck(left:find("8 / 10", 1, true) ~= nil and left:find("Runecloth", 1, true) ~= nil,
       "the material line did not read '8 / 10 Runecloth' (" .. left .. ")")
    ck(right ~= nil and right:find("Bbb", 1, true) ~= nil,
       "the material line did not name who else is holding it")

    -- A character with NO inventory record contributes nothing and reads "?",
    -- never a confident zero.
    local rows2 = ProfUI.MaterialRows(SPELL, reagents, "Ddd-Realm", invLookup, res)
    local by2 = {}
    for _, r in ipairs(rows2) do by2[r.itemID] = r end
    ck(by2[CLOTH].mine == nil, "an unknown inventory answered with a count")
    local l2 = ProfUI.MaterialText(by2[CLOTH])
    ck(l2:find("? / 10", 1, true) ~= nil, "an unknown inventory rendered as a number (" .. l2 .. ")")

    -- Not harvested is a STATE, not an empty list of zeros.
    local none, st2 = ProfUI.MaterialRows(4321, reagents, "Aaa-Realm", invLookup, res)
    ck(none == nil and st2 == "unharvested", "an unharvested recipe did not say so")

    -- Cold item names are pending, and the row still renders (we know the
    -- reagent exists; we just cannot spell it yet).
    local rows3, _, pending3 = ProfUI.MaterialRows(SPELL, reagents, "Aaa-Realm", invLookup,
                                                    fakeResolver(nil, {}))
    ck(#rows3 == 2 and #pending3 == 2, "cold reagent names dropped their rows instead of pending")
    ck(rows3[1].name == nil, "a cold reagent invented a name")
    ck(pending ~= nil, "the harvested path did not return a pending list")
end

local function testSearch(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local P = ns.Professions
    local D = core()
    if not D then fails[#fails + 1] = "dataset unavailable for the search tests" return end

    -- A tailoring recipe with a real skill requirement, so the learnable gate
    -- has something to gate on.
    local target, needSkill
    local list = D.profRecipes[D.profIdx.tailoring]
    for i = 1, #list do
        local rec = D.recipe[list[i]]
        if rec.s and rec.s >= 100 and (not rec.spec or rec.spec == 0) then
            target, needSkill = list[i], rec.s
            break
        end
    end
    ck(target ~= nil, "no suitable tailoring recipe found for the search fixture")
    if not target then return end

    local bits = P.EncodeKnown("tailoring", { target })
    local NOW = 1700000000
    local DS = ns.ProfessionsDataMeta.version
    local payloads = {
        -- knows it
        ["Aaa-Realm"] = { v = 1, ds = DS,
            p = { tailoring = { l = 300, m = 300, k = bits, n = 1, a = NOW } }, c = {} },
        -- has the profession, scanned, does NOT know it, and is skilled enough
        ["Bbb-Realm"] = { v = 1, ds = DS,
            p = { tailoring = { l = needSkill, m = 300, k = P.EncodeKnown("tailoring", {}),
                                n = 0, a = NOW } }, c = {} },
        -- has the profession and has NEVER been scanned: not "cannot", NOT CHECKED
        ["Ccc-Realm"] = { v = 1, ds = DS, p = { tailoring = { l = 300, m = 300 } }, c = {} },
    }
    local res = fakeResolver({ [target] = "Fixture Robe of Testing" })
    local rows, pending, truncated = ProfUI.SearchRows("Robe of Testing", fixtureEntries(),
        function(k) return payloads[k] end, res)
    ck(#rows == 1, "the who-can-craft search did not find exactly one recipe (" .. #rows .. ")")
    if #rows == 1 then
        local r = rows[1]
        ck(#r.known == 1 and r.known[1].nameRealm == "Aaa-Realm", "the KNOWN alt did not come through")
        ck(#r.learnable == 1 and r.learnable[1].nameRealm == "Bbb-Realm",
           "the LEARNABLE alt did not come through")
        ck(#r.unchecked == 1 and r.unchecked[1].nameRealm == "Ccc-Realm",
           "an unscanned alt was judged instead of counted as NOT CHECKED")
    end
    ck(truncated == false, "a one-hit search claimed to be truncated")

    -- Under-skilled is neither learnable nor unchecked.
    if needSkill > 1 then
        payloads["Bbb-Realm"].p.tailoring.l = needSkill - 1
        local rows2 = ProfUI.SearchRows("Robe of Testing", fixtureEntries(),
            function(k) return payloads[k] end, res)
        ck(#rows2 == 1 and #rows2[1].learnable == 0,
           "a character below the skill requirement was called learnable")
    end

    -- Cold names are held, not missed.
    local coldRows, coldPending = ProfUI.SearchRows("Robe of Testing", fixtureEntries(),
        function(k) return payloads[k] end, fakeResolver({}))
    ck(#coldRows == 0 and #coldPending > 0,
       "a search with no resolved names claimed a clean miss instead of pending")
    -- An empty query answers nothing and asks nothing.
    local none = ProfUI.SearchRows("", fixtureEntries(), function(k) return payloads[k] end, res)
    ck(#none == 0, "an empty query returned rows")
end

local function testBadgeAndLoginLine(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local NOW = 1700000000
    local payloads = {
        ["Aaa-Realm"] = { p = {}, c = { ["g1"] = NOW - 10, ["777"] = NOW + 60 } },
        ["Bbb-Realm"] = { p = {}, c = { ["888"] = NOW - 1 } },
        ["Ccc-Realm"] = { p = {}, c = {} },
    }
    local rows = ProfUI.RollupRows(fixtureEntries(), function(k) return payloads[k] end, NOW,
                                    fakeResolver({ [777] = "A", [888] = "B" }))
    ck(ProfUI.ReadyCount(rows) == 2, "the badge count is wrong (" .. ProfUI.ReadyCount(rows) .. ")")

    local line = ProfUI.LoginLine(rows)
    ck(type(line) == "string", "the login line produced nothing for two ready cooldowns")
    ck(line and line:find("2 profession cooldowns are ready", 1, true) == 1,
       "the login line does not open with the count (" .. tostring(line) .. ")")
    ck(line and line:find("Aaa", 1, true) ~= nil and line:find("Bbb", 1, true) ~= nil,
       "the login line does not name the characters")
    ck(select(2, tostring(line):gsub("\n", "")) == 0, "the login line is more than one line")

    -- Nothing ready = SILENCE, not "0 cooldowns are ready".
    local quiet = ProfUI.RollupRows(fixtureEntries(),
        function(k) return { p = {}, c = { ["1"] = NOW + 500 } } end, NOW, fakeResolver({}))
    ck(ProfUI.LoginLine(quiet) == nil, "the login line spoke up with nothing ready")

    -- The name cap holds the line short.
    local many = {}
    for i = 1, 9 do
        many[#many + 1] = { owner = "Char" .. i .. "-Realm", ready = true, remaining = 0,
                            cdKey = tostring(i), profKey = "alchemy" }
    end
    local capped = ProfUI.LoginLine(many, 4)
    ck(capped and capped:find("and 5 more", 1, true) ~= nil,
       "the login line did not cap the names it prints")

    -- The once-per-login latch, and the setting.
    local db = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    local savedSetting = db and db.professionsLoginLine
    local savedLatch = ProfUI._loginLineFired
    if db then
        db.professionsLoginLine = false
        ProfUI._loginLineFired = false
        local fired, why = ProfUI.FireLoginLine()
        ck(fired == false and why == "off", "the login line ignored its off switch")
        ck(ProfUI._loginLineFired == true, "the off switch did not settle the question for the session")
        db.professionsLoginLine = true
        ProfUI._loginLineFired = true
        local again, why2 = ProfUI.FireLoginLine()
        ck(again == false and why2 == "already-fired", "the login line fired twice in one session")
        db.professionsLoginLine = savedSetting
    end
    ProfUI._loginLineFired = savedLatch
    ck(ProfUI.LoginLineEnabled() ~= nil, "the login-line setting reader returned nothing")
end

local function testSourceModel(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local D = sourcesDS()
    if not D then fails[#fails + 1] = "the source graph would not load" return end

    -- The mask reader is plain arithmetic (no `bit` library in the client).
    ck(ProfUI.HasSourceBit(1, "trainer") == true, "bit 1 is not trainer")
    ck(ProfUI.HasSourceBit(1, "vendor") == false, "bit 1 leaked into vendor")
    ck(ProfUI.HasSourceBit(64 + 2, "granted") == true, "the granted bit did not read")
    ck(ProfUI.HasSourceBit(64 + 2, "vendor") == true, "a combined mask lost a bit")
    ck(ProfUI.HasSourceBit(0, "trainer") == false, "an empty mask claimed a source")

    -- Every recipe in the catalogue must produce a source model with at least
    -- one class and a non-empty display line; a blank source column is the
    -- failure mode this whole graph exists to prevent.
    local blank, noClass, unavailable, checked = 0, 0, 0, 0
    for pIdx = 1, #D.profs do
        local list = D.profRecipes[pIdx]
        for i = 1, math.min(#list, 25) do          -- a sample per profession keeps this cheap
            local m = ProfUI.SourceModel(list[i])
            checked = checked + 1
            if not m then blank = blank + 1
            else
                local anyClass = false
                for _ in pairs(m.classes) do anyClass = true break end
                if not anyClass then noClass = noClass + 1 end
                if (m.text or "") == "" then blank = blank + 1 end
                if m.unavailable then
                    unavailable = unavailable + 1
                    if type(m.unavailable.text) ~= "string" or m.unavailable.text == "" then
                        fails[#fails + 1] = "an unavailable candidate carries no reason"
                    end
                end
            end
        end
    end
    ck(blank == 0, blank .. " of " .. checked .. " sampled recipes produced no source display")
    ck(noClass == 0, noClass .. " sampled recipes produced no source CLASS for the filter")
    ProfUI._measuredSourceSample = checked
    ProfUI._measuredUnavailable = unavailable
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("professionsui", function(verbose)
        local suites = {
            { name = "grid model (roster order, the third state, cooldown decay, layout maths)",
              fn = testGridModel },
            { name = "cooldown rollup (ready-first ordering, shared groups, determinism)",
              fn = testRollup },
            { name = "drill-in filters (missing-only, source, unavailable toggle, cold search)",
              fn = testFilters },
            { name = "materials join (mesh counts, unknown vs zero, unharvested state)",
              fn = testMaterials },
            { name = "who-can-craft search (known / learnable / not checked, cold names)",
              fn = testSearch },
            { name = "tab badge + login line (count, cap, latch, off switch)",
              fn = testBadgeAndLoginLine },
            { name = "source display (mask reader + every sampled recipe answers)",
              fn = testSourceModel },
        }
        local allPass = true
        for _, suite in ipairs(suites) do
            local f = {}
            local ok = pcall(suite.fn, f)
            local passed = ok and #f == 0
            if not passed then allPass = false end
            if verbose and ns and ns.Print then
                if passed then ns:Print("  PASS professionsui/" .. suite.name)
                elseif not ok then ns:Print("  FAIL professionsui/" .. suite.name .. " :: error in test")
                else for _, m in ipairs(f) do ns:Print("  FAIL professionsui/" .. suite.name .. " :: " .. m) end end
            end
        end
        return allPass
    end)
end
