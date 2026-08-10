-- Daseeki Nexus — professions_filters.lua   (IN-FRAME TRADESKILL FILTERS, wave P3)
--
-- Search and filter controls living ON Blizzard's own profession windows — the
-- trade-skill window and the enchanting craft window — for whichever profession
-- is open. This is the absorption of the standalone filter addon: the owner's
-- ruling was option (a), "replicate the filter UI inside the Blizzard window",
-- so the controls attach to the game's frame rather than hiding in a Nexus pane.
--
-- It is a SUB-SURFACE of the professions module, not a module of its own: no
-- setting of its own, no login hook of its own, nothing registered while the
-- parent is off. professions.lua's Activate/SetEnabled drive it.
--
-- ══ THE ONE DECISION THAT SHAPES EVERYTHING: WE FILTER THROUGH THE CLIENT ════
--
-- PROFESSIONS_BEHAVIOR_SPEC §A.4 describes the examined implementation as a
-- full RE-IMPLEMENTATION of Blizzard's list-row layout: post-hook the refresh,
-- build a filtered array, re-drive every visible row's text, font object, width,
-- numeric id, header textures and highlight state, then recompute the
-- expand/collapse-all button. §7 defect 5 is the bill for that — every Blizzard
-- change to a row widget name, a texture, an anchor or the ORDER of the values
-- the list-info call returns breaks it, usually as an error inside the game's
-- own refresh, so the whole window dies rather than just the filter. §A.4's
-- deviation is explicit: "if the modern client exposes a data-provider or
-- predicate hook for these lists, use it."
--
-- It does. Interface 11509 ships SERVER-SIDE list filters:
--
--   SetTradeSkillItemNameFilter / GetTradeSkillItemNameFilter  (globals.txt:7625/5732)
--   SetTradeSkillSubClassFilter / GetTradeSkillSubClassFilter  (7626 / 5744)
--   GetTradeSkillSubClasses                                    (5743)
--   SetTradeSkillInvSlotFilter  / GetTradeSkillInvSlotFilter   (7623 / 5728)
--   GetTradeSkillInvSlots                                      (5729)
--   TradeSkillOnlyShowMakeable                                 (8197)
--   SetCraftFilter / GetCraftFilter / GetCraftSlots            (7486 / 4950 / 4962)
--   CraftOnlyShowMakeable                                      (4056)
--
-- So this module renders CONTROLS and nothing else. The game does the filtering
-- and the game draws its own rows. Consequences, all of them free:
--
--   * §7 defect 5 (row re-rendering) — no rows are touched.
--   * §7 defect 4 (full rebuild per keystroke, ~1,500 string scans) — there is
--     no rebuild; the text box is debounced anyway (§A.4's deviation).
--   * §7 defect 6 (selection mutated by typing) — we never call the selection
--     setter. Blizzard decides what a filtered list does with the selection.
--   * §7 defect 7 (collapse state destroyed) — we never expand or collapse
--     anything, so there is no state to lose and none to restore.
--   * §7 defect 30 (20-shot retry loop waiting for the window to appear) — the
--     panel is a CHILD of the game frame and shown from the frame's own OnShow
--     script, so it appears when the frame does, once, with no polling.
--   * §7 defect 31 (two diverged copies of the same matcher) — one
--     implementation parameterised by a per-surface adapter.
--
-- The price is honest and small: the craft (enchanting) window has NO name
-- filter in the client's API — only a slot filter and have-materials — so the
-- search box is not offered there. Offering it would mean owning the craft
-- window's row rendering, which is the exact trade §A.4 tells us not to make.
--
-- ══ FILTERING THE VIEW MUST NEVER FILTER THE CAPTURE ═════════════════════════
--
-- The client's filters are the real thing: with one engaged, GetNumTradeSkills
-- answers with the NARROWED count and the enumeration walks only the survivors.
-- Every row still resolves, so the capture layer's completeness gate cannot see
-- it — it would simply write a smaller known set, which is the one lie this
-- whole module exists to prevent.
--
-- So there are three interlocks, and the harness asserts all three:
--
--   1. professions.lua's VIEW GUARD. This file registers a witness; while any
--      narrowing is engaged, CaptureWindow refuses and writes NOTHING. The last
--      proven known set stands, with its `a` stamp still honest about when it
--      was taken.
--   2. THE WINDOW OPENS UNFILTERED. Every filter is cleared on show, and a
--      forced capture is issued one frame later, over the full list. That also
--      covers the event-ordering coin flip (CLIENT_ASYNC_LESSONS class 2): if
--      the capture's own TRADE_SKILL_SHOW handler ran first, against filter
--      state left over from the client, our clear-and-recapture overwrites it.
--   3. CLEARING RE-CAPTURES. The moment the last filter comes off, the full
--      list is captured again, so a session spent filtering is not a session
--      spent stale.
--
-- ══ STAND-DOWN ══════════════════════════════════════════════════════════════
-- The standalone filter addon is going away, but it is installed today and it
-- attaches its own panel to the same two frames. Two panels on one window is
-- worse than either, so while it is loaded we build nothing and say so once —
-- the same rule and the same probe shape as the tooltip stand-downs.
--
-- ══ SECURE AUDIT ════════════════════════════════════════════════════════════
-- Zero protected calls. The filter setters are unprotected client functions;
-- the panel is an ordinary frame parented to an unprotected Blizzard frame; no
-- selection setter, no action, nothing called from a text-changed handler that
-- touches game state beyond the documented filter API.
--
-- Clean-room: no third-party source was read. The behavior comes from our own
-- Room-1 spec; the control set, the layout and the capture interlocks are ours.

local ADDON, ns = ...

local Filters = {}
ns.ProfessionFilters = Filters

local EMPTY = {}

local TRADESKILL = "tradeskill"
local CRAFT      = "craft"
Filters.SURFACES = { TRADESKILL, CRAFT }

-- Debounce for the search box. §A.4's deviation ("~150–250 ms"); the client
-- does the work, but a keystroke still costs a server-side list rebuild and a
-- window refresh, and there is no reason to buy one per character typed.
local TEXT_DEBOUNCE = 0.2
Filters.TEXT_DEBOUNCE = TEXT_DEBOUNCE

-- How many times per window session the filter conventions may be measured
-- against an enumeration that answered zero. See Filters.Settle.
Filters.MAX_DARK_PROBES = 4

-- Session state. All nil/false until Activate().
Filters._activated = false
Filters._frame     = nil
Filters._state     = nil     -- surface -> live filter state (nil = window closed)
Filters._panels    = nil     -- surface -> panel frame
Filters._hooked    = nil     -- surface -> true once the game frame's scripts are hooked
Filters._prof      = nil     -- surface -> the profession name the window last showed
Filters._textTimer = nil     -- surface -> debounce generation
Filters._conv      = nil     -- surface -> the MEASURED argument forms for the pickers
Filters._probing   = nil     -- surface -> true while we are moving the client's filters
Filters._unhonored = nil     -- surface -> { dimension -> true } this client ignores
Filters._redrawFn  = nil     -- surface -> the client's own list-update function name

----------------------------------------------------------------------
-- Stand-down
----------------------------------------------------------------------

Filters.CPF_ADDON = "ClassicProfessionFilter"

-- PURE. probe = { cpfLoaded = bool }.
function Filters.CPFOwnsFilterUI(probe)
    if type(probe) ~= "table" then return false end
    return probe.cpfLoaded and true or false
end

function Filters.ProbeCPF(G)
    G = G or _G
    local name = Filters.CPF_ADDON
    local loaded = false
    local CA = G.C_AddOns
    if CA and CA.IsAddOnLoaded then
        local ok, res = pcall(CA.IsAddOnLoaded, name)
        loaded = (ok and res) and true or false
    elseif G.IsAddOnLoaded then
        local ok, res = pcall(G.IsAddOnLoaded, name)
        loaded = (ok and res) and true or false
    end
    return { cpfLoaded = loaded }
end

function Filters.IsEnabled()
    local P = ns.Professions
    if not (P and P.IsEnabled) then return false end
    return P.IsEnabled() and true or false
end

-- The single gate. Returns active(bool), reason(string).
function Filters.Status()
    if not Filters.IsEnabled() then
        return false, "the Professions module is switched off"
    end
    if Filters.CPFOwnsFilterUI(Filters.ProbeCPF()) then
        return false, "ClassicProfessionFilter is installed and attaches its own panel"
    end
    if not _G.DaseekiUI then
        return false, "DaseekiUI is not loaded (no widget kit to build with)"
    end
    return true, "active"
end

function Filters.Active()
    local active = Filters.Status()
    return active
end

function Filters.NoteStandDown(why)
    if Filters._noted then return false end
    Filters._noted = true
    if ns.Print then
        ns:Print("in-frame profession filters are standing down — " .. tostring(why) .. ".")
    end
    return true
end

----------------------------------------------------------------------
-- ═══════════ PURE MODEL ═════════════════════════════════════════════
--
-- The filter state, what "narrowed" means, and a REFERENCE predicate over a
-- list model. The reference predicate is not used to draw anything — the client
-- does the filtering — it is the written-down meaning of each dimension, and
-- the self-tests drive both it and the client (simulated) through the same
-- model and assert they agree. A dimension whose meaning drifts from what the
-- client actually does turns the suite red.
----------------------------------------------------------------------

function Filters.NewState()
    -- 0 in a picker is "all" — the client's own convention for these filters,
    -- and an explicit value rather than nil so `narrowed` never has to guess.
    return { text = "", makeable = false, subclass = 0, slot = 0 }
end

-- PURE. Trimmed, never nil.
function Filters.Trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- PURE. Is anything about this state narrowing the client's enumeration?
-- This is the predicate the capture's view guard runs on.
function Filters.Narrowed(state)
    if type(state) ~= "table" then return false end
    if Filters.Trim(state.text) ~= "" then return true end
    if state.makeable then return true end
    if (tonumber(state.subclass) or 0) > 0 then return true end
    if (tonumber(state.slot) or 0) > 0 then return true end
    return false
end

-- PURE. Case-insensitive PLAIN substring (§7 defect: the examined implementation
-- hand-rolled a character-window scan; plain find is the same answer for less).
function Filters.TextMatches(name, text)
    text = Filters.Trim(text)
    if text == "" then return true end
    if type(name) ~= "string" then return false end
    return name:lower():find(text:lower(), 1, true) ~= nil
end

-- PURE. Does one RECIPE row survive this state? Headers are not asked — see
-- Select. row = { kind, name, sub, slot, avail }.
function Filters.RowMatches(row, state)
    if type(row) ~= "table" then return false end
    state = state or EMPTY
    if not Filters.TextMatches(row.name, state.text) then return false end
    if state.makeable and (tonumber(row.avail) or 0) <= 0 then return false end
    local sub = tonumber(state.subclass) or 0
    if sub > 0 and (tonumber(row.sub) or 0) ~= sub then return false end
    local slot = tonumber(state.slot) or 0
    if slot > 0 and (tonumber(row.slot) or 0) ~= slot then return false end
    return true
end

-- PURE. The whole list model -> the rows that survive, in order.
--
-- The header rule is the spec's (§A.2): a category header appears when at least
-- one recipe under it survives, and a surviving recipe never appears without its
-- header. Headers themselves are not text-matched — the CATEGORY PICKER is the
-- dimension that selects by category, which is §A.2's own recommendation
-- ("filter by category/subclass as a picker rather than as free text").
function Filters.Select(list, state)
    local out = {}
    if type(list) ~= "table" then return out end
    local pendingHeader = nil
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" then
            if row.kind == "header" then
                pendingHeader = row
            elseif Filters.RowMatches(row, state) then
                if pendingHeader then
                    out[#out + 1] = pendingHeader
                    pendingHeader = nil
                end
                out[#out + 1] = row
            end
        end
    end
    return out
end

----------------------------------------------------------------------
-- The per-surface adapter — ONE implementation, two surfaces
--
-- §7 defect 31: the examined implementation is two near-identical files that
-- have diverged (one checks a name for nil before lowercasing it, the other
-- does not). Everything below is written once and told which client functions
-- to use. A function the client does not have is simply absent from the table,
-- and the dimension it powers is not offered — never a dead control.
----------------------------------------------------------------------

function Filters.Api(surface, G)
    G = G or _G
    if surface == CRAFT then
        return {
            surface     = CRAFT,
            frameName   = "CraftFrame",
            frame       = G.CraftFrame,
            numRows     = G.GetNumCrafts,
            isProfession= G.CraftIsEnchanting,
            line        = G.GetCraftDisplaySkillLine,
            setMakeable = G.CraftOnlyShowMakeable,
            setSlot     = G.SetCraftFilter,
            getSlot     = G.GetCraftFilter,
            slots       = G.GetCraftSlots,
            slotLabel   = "All Slots",
        }
    end
    return {
        surface     = TRADESKILL,
        frameName   = "TradeSkillFrame",
        frame       = G.TradeSkillFrame,
        numRows     = G.GetNumTradeSkills,
        line        = G.GetTradeSkillLine,
        setText     = G.SetTradeSkillItemNameFilter,
        getText     = G.GetTradeSkillItemNameFilter,
        setMakeable = G.TradeSkillOnlyShowMakeable,
        -- Not a control we offer; a leftover we clear. See ClearNative.
        setSkillUps = G.TradeSkillOnlyShowSkillUps,
        setSub      = G.SetTradeSkillSubClassFilter,
        getSub      = G.GetTradeSkillSubClassFilter,
        subs        = G.GetTradeSkillSubClasses,
        setSlot     = G.SetTradeSkillInvSlotFilter,
        getSlot     = G.GetTradeSkillInvSlotFilter,
        slots       = G.GetTradeSkillInvSlots,
        slotLabel   = "All Slots",
    }
end

-- PURE(ish). Which dimensions can this client actually offer on this surface?
-- Drives both the panel and the self-tests, so an absent API is a missing
-- control everywhere at once rather than a control that silently does nothing.
function Filters.Dimensions(api)
    local out = {}
    if type(api) ~= "table" then return out end
    if api.setText then
        out[#out + 1] = { key = "text", kind = "search", label = "Search recipes" }
    end
    if api.setMakeable then
        out[#out + 1] = { key = "makeable", kind = "toggle",
                          label = _G.CRAFT_IS_MAKEABLE or "Have Materials" }
    end
    if api.subs and api.setSub then
        out[#out + 1] = { key = "subclass", kind = "pick", label = "All Categories",
                          list = api.subs }
    end
    if api.slots and api.setSlot then
        out[#out + 1] = { key = "slot", kind = "pick", label = api.slotLabel or "All Slots",
                          list = api.slots }
    end
    return out
end

function Filters.DimensionKeys(api)
    local keys = {}
    for i, d in ipairs(Filters.Dimensions(api)) do keys[i] = d.key end
    return keys
end

----------------------------------------------------------------------
-- ═══════ PUSHING THE STATE AT THE CLIENT: MEASURE, NEVER ASSUME ═════════════
--
-- Wave P3 shipped this file with a written-down judgement call: the argument
-- convention of the two PICKER setters is "index 0 with the list-all flag means
-- every subclass". The 11509 catalog carries the NAMES of those functions and
-- nothing else — no arity, no parameter list, no documented sentinel — so that
-- convention was a guess, it was flagged as a guess, and live it was wrong in
-- both directions: the category picker did not narrow, and the search box
-- appeared to do nothing at all.
--
-- The lesson is not "find the right constant". It is that a constant we cannot
-- verify must not be passed BLIND, because the same call that fails to narrow
-- when we want it to can narrow to NOTHING when we do not — and this file's
-- clear-on-open runs before every capture, so a clear that quietly narrowed
-- would take the capture layer down with it. That is precisely what "the window
-- always opens unfiltered" turned into.
--
-- So nothing here interprets a value. Every filter call is a HYPOTHESIS and the
-- client's own row count is the experiment:
--
--   * to show everything, try each candidate argument form and keep the one that
--     leaves the MOST rows enumerated. A form that shrinks the list is rejected
--     by measurement, so an unverified sentinel can no longer wedge the window
--     shut. Worst case we change nothing.
--   * to narrow, keep the first form that produces a strictly smaller, non-empty
--     list. If no form does, the dimension is NOT HONORED on this client and the
--     control says so instead of pretending.
--   * the forms that win are remembered per surface, and forgotten the moment
--     one stops producing the effect it was learned for (class 5: a calibration
--     learned once and never revisited turns one bad read into a permanent
--     state).
--
-- And because moving the client's filters is exactly the thing the capture must
-- never read across, the probe registers itself in the view guard while it runs.
----------------------------------------------------------------------

-- Candidate argument forms. `n` is how many arguments to pass; entries 1 and 2
-- are the second and third arguments when there are three. The orderings are
-- deliberate: the shortest call first, because a client that only ever wanted an
-- index will accept it and the extra flags are then noise we never send.
local ALL_FORMS = {
    { n = 1 },
    { n = 3, 1, 1 },
    { n = 3, 1, 0 },
    { n = 3, 0, 1 },
}
local PICK_FORMS = {
    { n = 1 },
    { n = 3, 0, 1 },
    { n = 3, 1, 0 },
    { n = 3, 0, 0 },
}
Filters.ALL_FORMS  = ALL_FORMS
Filters.PICK_FORMS = PICK_FORMS

function Filters.FormName(form)
    if type(form) ~= "table" then return "none" end
    if form.n == 1 then return "(i)" end
    return "(i," .. tostring(form[1]) .. "," .. tostring(form[2]) .. ")"
end

local function callForm(fn, index, form)
    if not fn then return false end
    if form.n == 1 then return pcall(fn, index) end
    return pcall(fn, index, form[1], form[2])
end

-- The client's own enumeration size — the single witness every decision in this
-- section rests on. nil when it cannot be read, which is a refusal to decide,
-- never a zero.
function Filters.RowCount(surface, G)
    local api = Filters.Api(surface, G)
    if not api.numRows then return nil end
    local ok, n = pcall(api.numRows)
    if not ok or type(n) ~= "number" then return nil end
    return n
end

-- THE REDRAW. Setting a server-side filter changes what the client ENUMERATES;
-- it does not repaint the window. Blizzard's own filter menu calls the frame's
-- update function itself afterwards, and a panel that sets a filter without one
-- produces exactly the symptom this fix was reported as: typing changes nothing
-- on screen. Probed rather than assumed — the update function lives in a
-- load-on-demand addon, so it is absent until the window has been opened once.
function Filters.Redraw(surface, G)
    G = G or _G
    local names = (surface == CRAFT)
        and { "CraftFrame_Update" }
        or  { "TradeSkillFrame_Update" }
    for i = 1, #names do
        local fn = G[names[i]]
        if type(fn) == "function" then
            Filters._redrawFn = Filters._redrawFn or {}
            Filters._redrawFn[surface] = names[i]
            pcall(fn)
            return names[i]
        end
    end
    Filters._redrawFn = Filters._redrawFn or {}
    Filters._redrawFn[surface] = false
    return nil
end

-- Note one measured fact into the professions module's forensics ring, so the
-- owner's next window open answers "what does this client actually honor?"
-- without another round trip.
local function noteProbe(surface, what, detail)
    local P = ns.Professions
    if not (P and P.RecordAttempt) then return false end
    return P.RecordAttempt({
        e = "filter-probe", s = surface, r = what, g = detail,
    })
end

----------------------------------------------------------------------
-- CONVENTION PERSISTENCE  (perf/professions-scan)
--
-- The measured argument forms are a property of the CLIENT BINARY, not of a
-- session: within one build a setter does not change its calling convention.
-- So the four learned forms are mirrored into the store keyed by GetBuildInfo,
-- and a fresh session seeds its session table from there instead of paying the
-- full sweep (and its update-echo burst) on every first window open.
--
-- The class-5 rule stands in FULL: the persisted form is still a HYPOTHESIS.
-- ShowAll re-measures it against the live row count on every use and drops it
-- (session AND store) the moment it stops producing the effect it was learned
-- for; Narrow does the same. A build change wipes the whole record. Everything
-- that is window state — settled, darkProbes, interfere, degraded — remains
-- session-only and is never persisted.
----------------------------------------------------------------------

function Filters.ClientBuild()
    local P = ns.Professions
    if P and P.ClientBuild then return P.ClientBuild() end
    return "?"
end

-- The per-build store record, or nil. With `create`, a record left by another
-- build is wiped and re-stamped rather than read.
function Filters.ConvStoreArea(create)
    local S = ns.Store
    local area = S and S.ProfessionsFilterConv and S.ProfessionsFilterConv(create)
    if not area then return nil end
    local build = Filters.ClientBuild()
    if area.build ~= build then
        if not create then return nil end
        for k in pairs(area) do area[k] = nil end
        area.build = build
    end
    return area
end

Filters.PERSISTED_FORMS = { "subAll", "slotAll", "subPick", "slotPick" }

-- Mirror one learned (or forgotten: form=nil) argument form into the store.
-- Learning may CREATE the store area only while the module is enabled — the
-- teardown path clears filters on the way out, and a disabled module writing
-- its first saved-variable key during its own teardown would break the
-- inertness rule sideways. Deletions never create anything.
function Filters.RememberForm(surface, key, form)
    local area = Filters.ConvStoreArea(form ~= nil and Filters.IsEnabled())
    if not area then return false end
    local mine = area[surface]
    if type(mine) ~= "table" then
        if form == nil then return true end
        mine = {}
        area[surface] = mine
    end
    if form == nil then
        mine[key] = nil
    else
        mine[key] = { n = form.n, form[1], form[2] }
    end
    return true
end

-- Drop every remembered convention for `surface` (nil: for both), session and
-- store. The manual-rescan path calls this so a rescan re-measures from
-- scratch; the self-tests call it between simulated clients.
function Filters.ForgetConventions(surface)
    if surface then
        if Filters._conv then Filters._conv[surface] = nil end
        local area = Filters.ConvStoreArea(false)
        if area then area[surface] = nil end
    else
        Filters._conv = nil
        local S = ns.Store
        local area = S and S.ProfessionsFilterConv and S.ProfessionsFilterConv(false)
        if area then for k in pairs(area) do area[k] = nil end end
    end
    return true
end

function Filters.Conv(surface)
    Filters._conv = Filters._conv or {}
    local conv = Filters._conv[surface]
    if not conv then
        conv = {}
        Filters._conv[surface] = conv
        -- Seed the measured forms persisted for this client build. Copied, not
        -- referenced: the session table grows window state the store must not.
        local area = Filters.ConvStoreArea(false)
        local mine = area and area[surface]
        if type(mine) == "table" then
            for _, key in ipairs(Filters.PERSISTED_FORMS) do
                local form = mine[key]
                if type(form) == "table" and type(form.n) == "number" then
                    conv[key] = { n = form.n, form[1], form[2] }
                end
            end
        end
    end
    return conv
end

-- SHOW EVERYTHING, by measurement. Returns the row count we ended on.
--
-- Each candidate is applied and measured; the winner is the one that leaves the
-- most rows, and it is re-applied last so the client ends in the state we chose
-- rather than the state of the final probe. Because "more rows" is the only
-- thing this function will accept, it is incapable of narrowing the window —
-- which is the property the capture layer depends on.
function Filters.ShowAll(surface, api, G)
    local best, bestCount = nil, Filters.RowCount(surface, G) or 0
    local conv = Filters.Conv(surface)
    local applied = false

    -- An empty enumeration is measured too, because it is exactly where a
    -- LEFTOVER filter hides — the client's picker state survives window
    -- sessions, so a window can open showing nothing at all and every candidate
    -- that lifts it is an improvement. What such a probe may NOT do is believe
    -- itself: no form is cached from an all-zero measurement, `settled` stays
    -- false, and Settle() re-asks the question once there is something to count.
    local function search(setter, key)
        if not setter then return end
        local start = Filters.RowCount(surface, G) or 0
        -- THE REMEMBERED FORM FIRST (persisted per client build). If it still
        -- leaves at least as many rows enumerated as we started with — and any
        -- rows at all — the sweep is skipped: within one build the sweep could
        -- only re-elect the same winner. A remembered form that LOSES rows has
        -- stopped meaning what it was measured to mean, so it is dropped from
        -- session and store and the full sweep re-measures (class 5). A dark
        -- window (start == 0) never takes the fast path: zero proves nothing.
        local cached = conv[key]
        if cached then
            local ok = callForm(setter, 0, cached)
            local n = ok and Filters.RowCount(surface, G) or nil
            if n and n > 0 and n >= start then
                applied = true
                if n > bestCount then bestCount = n end
                return
            end
            conv[key] = nil
            Filters.RememberForm(surface, key, nil)
            noteProbe(surface, "recalibrate", key)
        end
        local winner, winnerCount = nil, -1
        for i = 1, #ALL_FORMS do
            local form = ALL_FORMS[i]
            if callForm(setter, 0, form) then
                local n = Filters.RowCount(surface, G)
                if n and n > winnerCount then winner, winnerCount = form, n end
                -- Starting from nothing, the first form that produces ANY rows
                -- has already lifted whatever was hiding them. Sweeping the rest
                -- would only spend more setter calls, and every setter call
                -- comes back at the capture layer as an update to refuse.
                if start <= 0 and n and n > 0 then break end
            end
        end
        if winner then
            callForm(setter, 0, winner)
            applied = true
            if winnerCount > 0 then                 -- never cache off an empty window
                conv[key] = winner
                Filters.RememberForm(surface, key, winner)
            end
            if winnerCount > bestCount then bestCount = winnerCount end
            if winnerCount < start then
                -- No form we know reaches the state we found the client in. We
                -- are left with the least-bad one and the fact is recorded
                -- rather than swallowed.
                conv.degraded = true
                noteProbe(surface, "clear-degraded",
                    key .. " " .. tostring(winnerCount) .. "<" .. tostring(start))
            end
        end
    end

    -- Subclass first, then slot, then subclass AGAIN. The third call is the
    -- whole point: these two setters share one filter record on the client, so
    -- the slot call can carry flags that undo what the subclass call just
    -- established. Re-asserting and re-measuring is how that is caught rather
    -- than reasoned about.
    search(api.setSub, "subAll")
    search(api.setSlot, "slotAll")
    if api.setSub and conv.subAll then
        callForm(api.setSub, 0, conv.subAll)
        local n = Filters.RowCount(surface, G)
        if n and n < bestCount and conv.slotAll then
            -- Re-asserting the subclass lost rows: the two orderings disagree,
            -- so keep whichever leaves more and record that they interfere.
            callForm(api.setSlot, 0, conv.slotAll)
            local m = Filters.RowCount(surface, G)
            if not m or m < n then callForm(api.setSub, 0, conv.subAll) end
            conv.interfere = true
        end
    end
    best = applied
    local final = Filters.RowCount(surface, G) or bestCount
    -- SETTLED means "this measurement was taken against a window that had rows".
    -- A window opens before the server's row list arrives, so the first probe of
    -- a session can easily run against an empty enumeration, where every
    -- candidate scores zero and the winner is arbitrary. That answer is not
    -- wrong so much as unearned, and OnWindowUpdate re-asks once the rows are
    -- actually there rather than living with it (class 5: a calibration taken
    -- once, in the dark, is worse than no calibration).
    conv.settled = final > 0
    if not conv.settled then conv.darkProbes = (conv.darkProbes or 0) + 1 end
    return final, best
end

-- NARROW one picker to `index`, by measurement. Returns true when the client
-- honored it. `baseline` is the unfiltered count to beat.
function Filters.Narrow(surface, api, setter, key, index, baseline, G)
    if not setter or (tonumber(index) or 0) <= 0 then return false end
    local conv = Filters.Conv(surface)

    local function try(form)
        if not callForm(setter, index, form) then return nil end
        return Filters.RowCount(surface, G)
    end

    -- The remembered form first — and it is only kept while it keeps working.
    local cached = conv[key]
    if cached then
        local n = try(cached)
        if n and n > 0 and n < baseline then return true end
        conv[key] = nil                              -- it stopped working: forget it
        Filters.RememberForm(surface, key, nil)      -- ...in the store too (class 5)
        noteProbe(surface, "recalibrate", key)
    end
    for i = 1, #PICK_FORMS do
        local form = PICK_FORMS[i]
        local n = try(form)
        if n and n > 0 and n < baseline then
            conv[key] = form
            Filters.RememberForm(surface, key, form) -- persisted per client build
            noteProbe(surface, "form-learned", key .. "=" .. Filters.FormName(form)
                .. " rows " .. tostring(n) .. "/" .. tostring(baseline))
            return true
        end
    end
    return false
end

-- The dimensions we are told to engage, engaged in an order that cannot lose
-- them: everything that should show ALL goes first, and the narrowing calls go
-- last, so a shared flag written by a later call can only ever be the one we
-- wanted. Then the result is VERIFIED against the unfiltered count.
function Filters.ApplyPickers(surface, api, state, G)
    local sub  = tonumber(state.subclass) or 0
    local slot = tonumber(state.slot) or 0
    local baseline = Filters.ShowAll(surface, api, G)
    if sub <= 0 and slot <= 0 then return true, baseline end
    -- Narrowing an empty enumeration proves nothing and cannot be verified, so
    -- the pick waits for the window to have something in it.
    if baseline <= 0 then return false, 0 end

    Filters._unhonored = Filters._unhonored or {}
    Filters._unhonored[surface] = Filters._unhonored[surface] or {}
    local bad = Filters._unhonored[surface]

    local okSub, okSlot = true, true
    if sub > 0 then
        okSub = Filters.Narrow(surface, api, api.setSub, "subPick", sub, baseline, G)
        bad.subclass = (not okSub) or nil
    end
    if slot > 0 then
        okSlot = Filters.Narrow(surface, api, api.setSlot, "slotPick", slot, baseline, G)
        bad.slot = (not okSlot) or nil
        -- Engaging the slot may have carried flags that released the subclass.
        -- Re-assert it and keep the narrower of the two orderings.
        if okSlot and sub > 0 and okSub then
            local after = Filters.RowCount(surface, G) or baseline
            if after >= baseline then
                Filters.Narrow(surface, api, api.setSub, "subPick", sub, baseline, G)
                Filters.Conv(surface).interfere = true
            end
        end
    end

    local final = Filters.RowCount(surface, G) or baseline
    if final >= baseline then
        -- Nothing we could say narrowed this client. Leave the window showing
        -- everything rather than in some half-set state, and let the control
        -- report the absence honestly.
        Filters.ShowAll(surface, api, G)
        if sub > 0 then bad.subclass = true end
        if slot > 0 then bad.slot = true end
        noteProbe(surface, "not-honored",
            (sub > 0 and "subclass " or "") .. (slot > 0 and "slot" or ""))
        return false, baseline
    end
    return true, final
end

-- Every call is guarded and pcall'd. A client that has moved on and dropped one
-- of these functions loses that dimension, not the window.
--
-- The whole push runs behind the probing latch, because the measurement moves
-- the client's filters on purpose and a capture that read the list mid-probe
-- would read a deliberately narrowed one.
function Filters.ApplyNative(surface, state, G)
    local api = Filters.Api(surface, G)
    state = state or Filters.NewState()
    Filters._probing = Filters._probing or {}
    local was = Filters._probing[surface]
    Filters._probing[surface] = true
    local ok, err = pcall(function()
        -- The two dimensions whose meaning is NOT in doubt: one string, one
        -- boolean, both with getters that read back what was set.
        if api.setText then pcall(api.setText, Filters.Trim(state.text)) end
        if api.setMakeable then pcall(api.setMakeable, state.makeable and true or false) end
        -- ...and the two whose argument convention the catalog does not carry.
        Filters.ApplyPickers(surface, api, state, G)
    end)
    Filters._probing[surface] = was
    -- The client filtered; now make it repaint. Without this the list on screen
    -- is the list from before the filter, which is indistinguishable to a player
    -- from a filter that does not work.
    Filters.Redraw(surface, G)
    if not ok then noteProbe(surface, "apply-error", tostring(err)) end
    return ok
end

-- Everything back to "show me all of it". This is what runs on window show and
-- on window hide, and it is the reason the next capture sees a full list.
--
-- It cannot narrow: ShowAll only ever accepts a candidate that leaves MORE rows
-- enumerated, and the unambiguous dimensions are set to their empty values.
function Filters.ClearNative(surface, G)
    -- The client's own "only show skill-ups" box is not a dimension this panel
    -- offers, but it IS one the capture layer refuses on, and it survives across
    -- window sessions. Left engaged it would mean every open lands in a
    -- permanent refusal that nothing this file does can lift. One boolean, no
    -- ambiguity, cleared where every other leftover is cleared — on the way in
    -- and on the way out, never on a keystroke.
    local api = Filters.Api(surface, G)
    if api.setSkillUps then pcall(api.setSkillUps, false) end
    return Filters.ApplyNative(surface, Filters.NewState(), G)
end

-- The witness professions.lua's capture consults. A window that is closed
-- narrows nothing, so a nil state is an honest false.
--
-- The probing latch comes FIRST and outranks everything: while this file is
-- moving the client's filters to find out what they do, the list is narrowed by
-- construction and no capture may read it.
function Filters.ViewGuard(surface)
    if Filters._probing and Filters._probing[surface] then return true, "probing" end
    local st = Filters._state and Filters._state[surface]
    if not st then return false end
    if Filters.Narrowed(st) then return true, "panel" end
    return false
end

-- The one place a filter change lands: push it at the client, refresh the
-- controls, and — when nothing narrows any more — re-capture the full list.
-- A dimension this client would not honor is reported ONCE and then rolled back
-- out of our own state, so the control cannot sit there looking engaged while
-- the list behind it is unfiltered. Honest absence beats a lying control.
function Filters.NoteUnhonored(surface, st)
    local bad = Filters._unhonored and Filters._unhonored[surface]
    if not bad then return false end
    local rolled = false
    Filters._toldUnhonored = Filters._toldUnhonored or {}
    for _, key in ipairs({ "subclass", "slot" }) do
        if bad[key] then
            if st and (tonumber(st[key]) or 0) > 0 then st[key] = 0 rolled = true end
            local tag = surface .. ":" .. key
            if not Filters._toldUnhonored[tag] and ns.Print then
                Filters._toldUnhonored[tag] = true
                ns:Print("this client does not honor the " ..
                    (key == "slot" and "slot" or "category") ..
                    " filter on the " .. surface .. " window — the control is standing down.")
            end
        end
    end
    return rolled
end

function Filters.SetState(surface, mutate)
    local st = Filters._state and Filters._state[surface]
    if not st then return false end
    if type(mutate) == "function" then mutate(st) end
    Filters.ApplyNative(surface, st)
    if Filters.NoteUnhonored(surface, st) then
        -- The roll-back is a state change of its own, so it goes back at the
        -- client rather than only at the panel.
        Filters.ApplyNative(surface, st)
    end
    Filters.RefreshPanel(surface)
    if not Filters.Narrowed(st) then
        -- Deferred one frame: the client rebuilds its list in response to the
        -- filter call, and a capture in the same execution would read the
        -- PRE-change enumeration (CLIENT_ASYNC_LESSONS class 1).
        Filters.CaptureSoon(surface)
    end
    return true
end

function Filters.CaptureSoon(surface)
    local P = ns.Professions
    if not (P and P.CaptureWindow) then return false end
    local run = function()
        if not Filters.IsEnabled() then return end
        P.CaptureWindow(surface, true)
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0, run) else run() end
    return true
end

----------------------------------------------------------------------
-- LIVE: the panel
--
-- DREW_UI_STYLE: one compact row, content hugging its natural width, centered
-- over the game window rather than stretched to its edges; every control
-- self-labelling (the pickers read "All Categories" / "All Slots" when idle, so
-- the dimension is named by the control itself); no dead vertical space.
--
-- The panel is a CHILD of the Blizzard frame. That is deliberate and it is what
-- "match the frame's scale" means here: parenting inherits the frame's
-- effective scale and strata, moves with it when the player drags it, and hides
-- with it — so there is no cursor arithmetic anywhere in this file and
-- CLIENT_ASYNC_LESSONS class 3 (mixed coordinate spaces) cannot arise.
----------------------------------------------------------------------

local PANEL_H   = 30
local PAD       = 8
local GAP       = 6
local SEARCH_W  = 150
local PICK_W    = 128

local function uiKit() return _G.DaseekiUI end

-- Choice list for a picker dimension: { {value=0,text=<idle label>}, ... }.
function Filters.PickChoices(dim)
    local out = { { value = 0, text = dim.label } }
    if type(dim.list) ~= "function" then return out end
    local ok, res = pcall(dim.list)
    if not ok then return out end
    if type(res) == "table" then
        for i = 1, #res do out[#out + 1] = { value = i, text = tostring(res[i]) } end
    else
        -- The client hands these back as a vararg on some builds.
        local vals = { pcall(dim.list) }
        for i = 2, #vals do
            if type(vals[i]) == "string" then out[#out + 1] = { value = i - 1, text = vals[i] } end
        end
    end
    return out
end

function Filters.EnsurePanel(surface)
    Filters._panels = Filters._panels or {}
    if Filters._panels[surface] then return Filters._panels[surface] end
    local UI = uiKit()
    if not UI or not UI.FlatFrame then return nil end
    local api = Filters.Api(surface)
    local host = api.frame
    if not host then return nil end

    local dims0 = Filters.Dimensions(api)
    -- A bar carrying nothing but a Clear button is a dead control, and a dead
    -- control is worse than an absent one. A client with none of the filter API
    -- gets no panel at all.
    if #dims0 == 0 then return nil end

    local panel = UI.FlatFrame(host, "panel", "borderLite")
    panel:SetHeight(PANEL_H)
    panel:SetPoint("BOTTOM", host, "TOP", 0, 2)
    if panel.SetFrameLevel and host.GetFrameLevel then
        pcall(function() panel:SetFrameLevel(host:GetFrameLevel() + 5) end)
    end
    panel._controls = {}

    local dims = dims0
    local x, controls = PAD, {}

    for _, dim in ipairs(dims) do
        local w
        if dim.kind == "search" then
            local box = UI.MakeEditBox(panel, {
                width = SEARCH_W,
                get = function()
                    local st = Filters._state and Filters._state[surface]
                    return st and st.text or ""
                end,
                set = function(v) Filters.QueueText(surface, v) end,
            })
            -- Live typing, debounced: the commit-on-enter contract MakeEditBox
            -- ships is right for a settings field and wrong for a search box.
            if box.editBox then
                local hint = box.editBox:CreateFontString(nil, "OVERLAY")
                hint:SetFontObject(UI.fonts and UI.fonts.muted or "GameFontDisableSmall")
                hint:SetPoint("LEFT", box.editBox, "LEFT", 8, 0)
                hint:SetText(dim.label)
                box._hint = hint
                box.editBox:SetScript("OnTextChanged", function(self, userInput)
                    -- The placeholder answers to the BOX, not to the debounced
                    -- filter state: it must clear on the first keystroke, not a
                    -- fifth of a second later.
                    if (self:GetText() or "") == "" then hint:Show() else hint:Hide() end
                    if userInput then Filters.QueueText(surface, self:GetText()) end
                end)
            end
            box:SetPoint("LEFT", panel, "LEFT", x, 0)
            controls.text, w = box, SEARCH_W

        elseif dim.kind == "toggle" then
            local cb = UI.MakeCheckbox(panel, {
                label = dim.label,
                tooltip = "Show only recipes you can make right now",
                get = function()
                    local st = Filters._state and Filters._state[surface]
                    return st and st.makeable or false
                end,
                set = function(v)
                    Filters.SetState(surface, function(st) st.makeable = v and true or false end)
                end,
            })
            cb:SetPoint("LEFT", panel, "LEFT", x, 0)
            controls.makeable, w = cb, cb.uiWidth or 120

        elseif dim.kind == "pick" then
            local key = dim.key
            local dd = UI.MakeDropdown(panel, {
                width = PICK_W,
                choices = Filters.PickChoices(dim),
                set = function(v)
                    Filters.SetState(surface, function(st) st[key] = tonumber(v) or 0 end)
                end,
            })
            dd:SetPoint("LEFT", panel, "LEFT", x, 0)
            if dd.SetValue then dd:SetValue(0) end
            controls[key], w = dd, PICK_W
        end

        if w then x = x + w + GAP end
    end

    local clear = UI.MakeButton(panel, {
        text = _G.RESET or "Clear", variant = "quiet", width = 56, height = 22,
        onClick = function() Filters.ResetSurface(surface) end,
    })
    clear:SetPoint("LEFT", panel, "LEFT", x, 0)
    controls.clear = clear
    x = x + 56 + GAP

    -- The manual full-rescan affordance (perf/professions-scan): window opens
    -- now verify a cheap settled signature instead of re-running the full
    -- capture, and this button is the owner's override — signature ignored,
    -- full capture, reagent re-harvest, filter probe re-measured. Same quiet
    -- variant and row as Clear: it belongs to the same "reset something" family.
    local rescan = UI.MakeButton(panel, {
        text = "Rescan", variant = "quiet", width = 64, height = 22,
        tooltip = "Force a full re-capture of this profession (recipes, reagents, cooldowns)",
        onClick = function()
            local P = ns.Professions
            if P and P.ForceRescan then P.ForceRescan(surface) end
        end,
    })
    rescan:SetPoint("LEFT", panel, "LEFT", x, 0)
    controls.rescan = rescan
    x = x + 64 + PAD

    panel:SetWidth(x)                    -- hug the content; never the host's width
    panel._controls = controls
    panel:Hide()
    Filters._panels[surface] = panel
    return panel
end

function Filters.RefreshPanel(surface)
    local panel = Filters._panels and Filters._panels[surface]
    if not panel then return false end
    local c = panel._controls or EMPTY
    local st = (Filters._state and Filters._state[surface]) or Filters.NewState()
    if c.text then
        if c.text.Refresh then pcall(c.text.Refresh) end
        if c.text._hint then
            if Filters.Trim(st.text) == "" then c.text._hint:Show() else c.text._hint:Hide() end
        end
    end
    if c.makeable and c.makeable.Refresh then pcall(c.makeable.Refresh, c.makeable) end
    if c.subclass and c.subclass.SetValue then c.subclass:SetValue(tonumber(st.subclass) or 0) end
    if c.slot and c.slot.SetValue then c.slot:SetValue(tonumber(st.slot) or 0) end
    return true
end

-- Debounced search text (§A.4). One generation counter per surface, so a burst
-- of keystrokes results in exactly one filter call.
function Filters.QueueText(surface, text)
    Filters._textTimer = Filters._textTimer or {}
    local gen = (Filters._textTimer[surface] or 0) + 1
    Filters._textTimer[surface] = gen
    local apply = function()
        if Filters._textTimer and Filters._textTimer[surface] ~= gen then return end
        Filters.SetState(surface, function(st) st.text = Filters.Trim(text) end)
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(TEXT_DEBOUNCE, apply)
    else apply() end
end

function Filters.ResetSurface(surface)
    if not (Filters._state and Filters._state[surface]) then return false end
    Filters._state[surface] = Filters.NewState()
    Filters.ApplyNative(surface, Filters._state[surface])
    local panel = Filters._panels and Filters._panels[surface]
    if panel and panel._controls and panel._controls.text and panel._controls.text.editBox then
        panel._controls.text.editBox:SetText("")
        panel._controls.text.editBox:ClearFocus()
    end
    Filters.RefreshPanel(surface)
    Filters.CaptureSoon(surface)
    return true
end

----------------------------------------------------------------------
-- LIVE: window sessions
----------------------------------------------------------------------

-- Is this surface actually showing a PROFESSION? The craft surface is shared
-- with hunter beast training, which is not one — the same refusal the capture
-- layer makes, for the same reason.
function Filters.SurfaceIsProfession(surface, G)
    local api = Filters.Api(surface, G)
    if not api.isProfession then return true end
    local ok, yes = pcall(api.isProfession)
    return (ok and yes) and true or false
end

function Filters.ProfessionName(surface, G)
    local api = Filters.Api(surface, G)
    if not api.line then return nil end
    local ok, name = pcall(api.line)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

function Filters.OnWindowShow(surface, retried)
    local active, why = Filters.Status()
    if not active then
        if why and why:find(Filters.CPF_ADDON, 1, true) then Filters.NoteStandDown(why) end
        return false
    end
    -- The game's profession UI is load-on-demand: the SHOW event can beat the
    -- frame into existence, and a third-party UI can delay it further. ONE
    -- deferred retry, not §7 defect 30's twenty-shot poll — and the frame's own
    -- OnShow hook (HookFrame) is the real path, so this only has to cover the
    -- very first open, before there is a frame to hook.
    if not Filters.Api(surface).frame then
        if retried then return false end
        if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0, function()
                if not Filters.IsEnabled() then return end
                Filters.HookFrame(surface)
                Filters.OnWindowShow(surface, true)
            end)
        end
        return false
    end
    if not Filters.SurfaceIsProfession(surface) then return false end

    -- The window always opens UNFILTERED. Interlock 2: whatever the client was
    -- carrying is cleared before anything is captured, and the forced capture a
    -- frame later overwrites anything a racing filtered capture wrote.
    Filters._state = Filters._state or {}
    Filters._state[surface] = Filters.NewState()
    -- The dark-probe budget is per WINDOW SESSION, not per client: a second open
    -- is a fresh chance for the rows to be there this time. The measured forms
    -- themselves are a client property and survive.
    Filters.Conv(surface).darkProbes = nil
    Filters.ClearNative(surface)
    Filters._prof = Filters._prof or {}
    Filters._prof[surface] = Filters.ProfessionName(surface)

    local panel = Filters.EnsurePanel(surface)
    if panel then
        Filters.RefreshPanel(surface)
        panel:Show()
    end
    Filters.CaptureSoon(surface)
    return true
end

function Filters.OnWindowHide(surface)
    -- Clear on the way out (§A.5): nothing of ours survives the window, so the
    -- next open cannot start narrowed and the next capture cannot start short.
    if Filters._state and Filters._state[surface] then
        Filters.ClearNative(surface)
        Filters._state[surface] = nil
    end
    if Filters._prof then Filters._prof[surface] = nil end
    if Filters._textTimer then Filters._textTimer[surface] = nil end
    local panel = Filters._panels and Filters._panels[surface]
    if panel then panel:Hide() end
    return true
end

-- §A.5's second reset trigger: the window stayed open and the profession
-- changed under it (a linked profession, or the player switching skill line).
-- A filter that means something for tailoring means nothing for cooking.
function Filters.OnWindowUpdate(surface)
    if not (Filters._state and Filters._state[surface]) then return false end
    -- Our own probe echoes back as updates. Re-entering here mid-measurement
    -- would measure the measurement.
    if Filters._probing and Filters._probing[surface] then return false end
    local now = Filters.ProfessionName(surface)
    local was = Filters._prof and Filters._prof[surface]
    if now and was and now ~= was then
        Filters._prof[surface] = now
        Filters.ResetSurface(surface)
        return true
    end
    if now and not was and Filters._prof then Filters._prof[surface] = now end

    return Filters.Settle(surface)
end

-- THE SETTLE. The clear that ran on SHOW may have measured a window whose rows
-- had not arrived, where every candidate scores zero and the winner is
-- arbitrary. That answer is unearned, so it is marked unsettled and asked again
-- — on the next window update, and on each rung of the capture layer's retry
-- ladder, because a window whose rows arrive without an event has no update to
-- ride on.
--
-- It latches: once a measurement has been taken against a window that had rows,
-- `settled` is true and this cannot become a loop.
function Filters.Settle(surface)
    if not (Filters._state and Filters._state[surface]) then return false end
    if Filters._probing and Filters._probing[surface] then return false end
    local conv = Filters.Conv(surface)
    if conv.settled then return false end
    if Filters.Narrowed(Filters._state[surface]) then return false end
    -- A probe taken against an empty enumeration is a probe in the dark, and
    -- there are only so many of those per window session. Four is enough to
    -- cover the first four rungs of the capture layer's ladder — about two
    -- seconds, which is longer than a trade-skill list packet takes to arrive on
    -- any connection worth waiting for — and it is a hard stop, so a window that
    -- genuinely has nothing in it stops being asked.
    if (conv.darkProbes or 0) >= Filters.MAX_DARK_PROBES
       and (Filters.RowCount(surface) or 0) <= 0 then
        return false
    end
    Filters.ClearNative(surface)
    if not conv.settled then return false end       -- still nothing to count
    Filters.CaptureSoon(surface)
    return true
end

-- Watch the OBJECT, not only the event (CLIENT_ASYNC_LESSONS class 2): a UI that
-- delays or replaces the game window makes the SHOW event a lie about whether
-- the frame is up. Hooking the frame's own scripts is the fix §7 defect 30's
-- deviation asks for, and it replaces the 20-shot retry loop entirely.
function Filters.HookFrame(surface)
    Filters._hooked = Filters._hooked or {}
    if Filters._hooked[surface] then return true end
    local api = Filters.Api(surface)
    local host = api.frame
    if not (host and host.HookScript) then return false end
    Filters._hooked[surface] = true
    host:HookScript("OnShow", function()
        if ns.SafeCall then ns:SafeCall(Filters.OnWindowShow, surface)
        else Filters.OnWindowShow(surface) end
    end)
    host:HookScript("OnHide", function()
        if ns.SafeCall then ns:SafeCall(Filters.OnWindowHide, surface)
        else Filters.OnWindowHide(surface) end
    end)
    return true
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

Filters.EVENTS = {
    "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE",
    "CRAFT_SHOW", "CRAFT_UPDATE", "CRAFT_CLOSE",
}

local function onEvent(_, event)
    if not Filters.IsEnabled() then return end
    if event == "TRADE_SKILL_SHOW" then
        Filters.HookFrame(TRADESKILL)
        Filters.OnWindowShow(TRADESKILL)
    elseif event == "TRADE_SKILL_UPDATE" then
        Filters.OnWindowUpdate(TRADESKILL)
    elseif event == "TRADE_SKILL_CLOSE" then
        Filters.OnWindowHide(TRADESKILL)
    elseif event == "CRAFT_SHOW" then
        Filters.HookFrame(CRAFT)
        Filters.OnWindowShow(CRAFT)
    elseif event == "CRAFT_UPDATE" then
        Filters.OnWindowUpdate(CRAFT)
    elseif event == "CRAFT_CLOSE" then
        Filters.OnWindowHide(CRAFT)
    end
end
Filters._onEvent = onEvent

function Filters.Activate()
    if Filters._activated then return true end
    if not Filters.IsEnabled() then return false end
    Filters._activated = true

    -- The capture interlock is registered even when the panel itself stands
    -- down for the third-party addon: THAT addon narrows the same lists, and a
    -- narrowed list must never become a written known set no matter who
    -- narrowed it. The guard reads our own state, which stays empty while we
    -- are standing down — but registering it is free and the seam is then live
    -- the moment the collision clears.
    local P = ns.Professions
    if P and P.RegisterViewGuard then P.RegisterViewGuard(Filters.ViewGuard) end

    if not Filters._frame and _G.CreateFrame then
        local f = _G.CreateFrame("Frame")
        f:SetScript("OnEvent", onEvent)
        for i = 1, #Filters.EVENTS do
            pcall(function() f:RegisterEvent(Filters.EVENTS[i]) end)
        end
        Filters._frame = f
    end
    return true
end

function Filters.Teardown()
    -- Leave the client the way we found it: any filter of ours comes off before
    -- the controls that could remove it disappear.
    for _, surface in ipairs(Filters.SURFACES) do
        if Filters._state and Filters._state[surface] then Filters.ClearNative(surface) end
    end
    if Filters._frame then
        pcall(function() Filters._frame:UnregisterAllEvents() end)
        pcall(function() Filters._frame:SetScript("OnEvent", nil) end)
        pcall(function() Filters._frame:Hide() end)
        Filters._frame = nil
    end
    if Filters._panels then
        for _, panel in pairs(Filters._panels) do
            pcall(function() panel:Hide() end)
        end
    end
    Filters._activated = false
    Filters._state     = nil
    Filters._prof      = nil
    Filters._textTimer = nil
    Filters._probing   = nil
    -- The measured conventions go too. They describe a client we are no longer
    -- talking to, and a form remembered across a teardown is the sticky
    -- calibration class 5 warns about wearing a different hat.
    Filters._conv      = nil
    Filters._unhonored = nil
    Filters._redrawFn  = nil
    return true
end

----------------------------------------------------------------------
-- Diagnostics
----------------------------------------------------------------------

ns:RegisterDebugCommand("proffilters", function()
    local active, why = Filters.Status()
    ns:Print("profession filters: " .. (active and "ACTIVE" or "standing down")
        .. " — " .. tostring(why))
    for _, surface in ipairs(Filters.SURFACES) do
        local api = Filters.Api(surface)
        local keys = Filters.DimensionKeys(api)
        local st = Filters._state and Filters._state[surface]
        ns:Print(string.format("  %s: frame=%s | dimensions=%s | open=%s | narrowed=%s",
            surface, tostring(api.frame ~= nil),
            (#keys > 0) and table.concat(keys, ",") or "none",
            tostring(st ~= nil), tostring(Filters.ViewGuard(surface))))
    end
    ns:Print(string.format("  activated=%s | cpf=%s | panels=%s",
        tostring(Filters._activated), tostring(Filters.ProbeCPF().cpfLoaded),
        tostring(Filters._panels ~= nil)))
    -- WHAT THIS CLIENT ACTUALLY HONORS, as measured rather than as assumed.
    -- This is the readout that answers the question P3 could only flag.
    for _, surface in ipairs(Filters.SURFACES) do
        local conv = Filters._conv and Filters._conv[surface]
        local bad  = Filters._unhonored and Filters._unhonored[surface]
        local badList = {}
        for key in pairs(bad or EMPTY) do badList[#badList + 1] = key end
        table.sort(badList)
        ns:Print(string.format("  %s conventions: subAll=%s subPick=%s slotAll=%s slotPick=%s"
            .. " | interfere=%s | redraw=%s | rows=%s%s", surface,
            Filters.FormName(conv and conv.subAll), Filters.FormName(conv and conv.subPick),
            Filters.FormName(conv and conv.slotAll), Filters.FormName(conv and conv.slotPick),
            tostring((conv and conv.interfere) and true or false),
            tostring((Filters._redrawFn and Filters._redrawFn[surface]) or "NOT FOUND"),
            tostring(Filters.RowCount(surface) or "?"),
            (#badList > 0) and (" | NOT HONORED: " .. table.concat(badList, ",")) or ""))
    end
end)

----------------------------------------------------------------------
-- Self-tests (suite "proffilters")
--
-- The interesting ones drive a SIMULATED CLIENT: a fake trade-skill list whose
-- filter setters really narrow what the enumeration returns, exactly as the
-- real one does. That lets the suite prove three things no static check can:
--   * each dimension selects the rows the written-down predicate says it does,
--     THROUGH the client rather than beside it;
--   * a filtered window's capture writes nothing;
--   * the same window, unfiltered, captures the full known set.
----------------------------------------------------------------------

-- Build a fake client over a list model. Returns the sim; call sim:install()
-- and sim:restore().
local function newClientSim(model, spellOf)
    local sim = { state = Filters.NewState(), model = model, saved = {} }

    function sim.surviving()
        return Filters.Select(model, sim.state)
    end

    local G = _G
    function sim:install()
        self.saved = {
            num = G.GetNumTradeSkills, info = G.GetTradeSkillInfo,
            link = G.GetTradeSkillRecipeLink, line = G.GetTradeSkillLine,
            cd = G.GetTradeSkillCooldown,
            setText = G.SetTradeSkillItemNameFilter, getText = G.GetTradeSkillItemNameFilter,
            makeable = G.TradeSkillOnlyShowMakeable, getMakeable = G.GetOnlyShowMakeable,
            setSub = G.SetTradeSkillSubClassFilter, subs = G.GetTradeSkillSubClasses,
            setSlot = G.SetTradeSkillInvSlotFilter, slots = G.GetTradeSkillInvSlots,
            onlyMakeable = G.GetOnlyShowMakeable,
        }
        G.GetNumTradeSkills = function() return #sim.surviving() end
        G.GetTradeSkillInfo = function(i)
            local row = sim.surviving()[i]
            if not row then return nil end
            return row.name, (row.kind == "header") and "header" or "optimal",
                   tonumber(row.avail) or 0, false
        end
        G.GetTradeSkillRecipeLink = function(i)
            local row = sim.surviving()[i]
            if not row or row.kind == "header" then return nil end
            return "|cffffd000|Henchant:" .. tostring(spellOf(row)) .. "|h[x]|h|r"
        end
        G.GetTradeSkillLine = function() return "Blacksmithing", 275, 300 end
        G.GetTradeSkillCooldown = function() return nil end
        G.SetTradeSkillItemNameFilter = function(t) sim.state.text = t or "" end
        G.GetTradeSkillItemNameFilter = function() return sim.state.text end
        G.TradeSkillOnlyShowMakeable = function(v) sim.state.makeable = v and true or false end
        G.GetOnlyShowMakeable = function() return sim.state.makeable end
        G.SetTradeSkillSubClassFilter = function(i, listAll)
            sim.state.subclass = (listAll == 1 or listAll == true) and 0 or (tonumber(i) or 0)
        end
        G.GetTradeSkillSubClasses = function() return { "Weapon", "Armor" } end
        G.SetTradeSkillInvSlotFilter = function(i, listAll)
            sim.state.slot = (listAll == 1 or listAll == true) and 0 or (tonumber(i) or 0)
        end
        G.GetTradeSkillInvSlots = function() return { "Head", "Chest" } end
    end
    function sim:restore()
        local s = self.saved
        G.GetNumTradeSkills, G.GetTradeSkillInfo = s.num, s.info
        G.GetTradeSkillRecipeLink, G.GetTradeSkillLine = s.link, s.line
        G.GetTradeSkillCooldown = s.cd
        G.SetTradeSkillItemNameFilter, G.GetTradeSkillItemNameFilter = s.setText, s.getText
        G.TradeSkillOnlyShowMakeable, G.GetOnlyShowMakeable = s.makeable, s.getMakeable
        G.SetTradeSkillSubClassFilter, G.GetTradeSkillSubClasses = s.setSub, s.subs
        G.SetTradeSkillInvSlotFilter, G.GetTradeSkillInvSlots = s.setSlot, s.slots
    end
    return sim
end

local function testPureModel(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    ck(Filters.Trim("  x  ") == "x", "Trim did not trim")
    ck(Filters.Trim(nil) == "", "Trim(nil) was not the empty string")

    local st = Filters.NewState()
    ck(Filters.Narrowed(st) == false, "a fresh state reported itself as narrowing")
    ck(Filters.Narrowed(nil) == false, "a nil state reported itself as narrowing")
    st.text = "   "
    ck(Filters.Narrowed(st) == false, "whitespace-only search text counted as a filter")
    st.text = "arc"
    ck(Filters.Narrowed(st) == true, "search text did not count as narrowing")
    st = Filters.NewState(); st.makeable = true
    ck(Filters.Narrowed(st) == true, "have-materials did not count as narrowing")
    st = Filters.NewState(); st.subclass = 2
    ck(Filters.Narrowed(st) == true, "a category pick did not count as narrowing")
    st = Filters.NewState(); st.slot = 1
    ck(Filters.Narrowed(st) == true, "a slot pick did not count as narrowing")

    ck(Filters.TextMatches("Arcanite Reaper", "arcan") == true, "substring match failed")
    ck(Filters.TextMatches("Arcanite Reaper", "ARCAN") == true, "match was case sensitive")
    ck(Filters.TextMatches("Arcanite Reaper", "") == true, "empty text did not match everything")
    ck(Filters.TextMatches(nil, "x") == false, "a nil row name matched (defect 31's asymmetry)")
    ck(Filters.TextMatches("a.c", "a.c") == true, "the match was a pattern, not a plain find")
    ck(Filters.TextMatches("abc", "a.c") == false, "a magic character behaved as a pattern")

    ck(Filters.CPFOwnsFilterUI({ cpfLoaded = true }) == true, "the CPF stand-down did not trip")
    ck(Filters.CPFOwnsFilterUI({ cpfLoaded = false }) == false, "the CPF stand-down over-tripped")
    ck(Filters.CPFOwnsFilterUI(nil) == false, "a nil probe stood down")
    ck(Filters.ProbeCPF({ C_AddOns = { IsAddOnLoaded = function() return true end } }).cpfLoaded
       == true, "the CPF probe missed a loaded addon")
    ck(Filters.ProbeCPF({ IsAddOnLoaded = function() return false end }).cpfLoaded == false,
       "the CPF probe saw an absent addon")
end

-- One list model shared by the dimension rows: two categories, five recipes,
-- with availability, subclass and slot spread across them.
local function fixtureList()
    return {
        { kind = "header", name = "Weapons" },
        { kind = "recipe", name = "Arcanite Reaper", avail = 1, sub = 1, slot = 1 },
        { kind = "recipe", name = "Iron Sword",      avail = 0, sub = 1, slot = 1 },
        { kind = "header", name = "Armor" },
        { kind = "recipe", name = "Iron Shield",     avail = 2, sub = 2, slot = 2 },
        { kind = "recipe", name = "Arcanite Plate",  avail = 0, sub = 2, slot = 2 },
        { kind = "recipe", name = "Copper Chain",    avail = 3, sub = 2, slot = 2 },
    }
end

local function names(list)
    local out = {}
    for i = 1, #list do out[i] = list[i].name end
    return table.concat(out, ",")
end

local function testDimensions(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local list = fixtureList()

    -- Every dimension, through the reference predicate, on the real list shape.
    local function sel(mut)
        local st = Filters.NewState()
        mut(st)
        return names(Filters.Select(list, st))
    end

    ck(sel(function() end) ==
       "Weapons,Arcanite Reaper,Iron Sword,Armor,Iron Shield,Arcanite Plate,Copper Chain",
       "the unfiltered selection dropped or reordered rows")

    -- 1. free text
    ck(sel(function(st) st.text = "arcanite" end) ==
       "Weapons,Arcanite Reaper,Armor,Arcanite Plate",
       "the text filter did not select both arcanite recipes with both headers")
    ck(sel(function(st) st.text = "  IRON  " end) ==
       "Weapons,Iron Sword,Armor,Iron Shield",
       "the text filter did not trim and case-fold")
    ck(sel(function(st) st.text = "nothingatall" end) == "",
       "a search matching nothing still emitted a header")

    -- 2. have materials
    ck(sel(function(st) st.makeable = true end) ==
       "Weapons,Arcanite Reaper,Armor,Iron Shield,Copper Chain",
       "have-materials did not drop the zero-availability rows")

    -- 3. category (subclass) picker
    ck(sel(function(st) st.subclass = 1 end) == "Weapons,Arcanite Reaper,Iron Sword",
       "the category picker did not isolate one category")
    ck(sel(function(st) st.subclass = 0 end):find("Armor", 1, true) ~= nil,
       "category 0 was not 'all categories'")

    -- 4. inventory slot picker
    ck(sel(function(st) st.slot = 2 end) == "Armor,Iron Shield,Arcanite Plate,Copper Chain",
       "the slot picker did not isolate one slot")

    -- conjunction: the predicates compose, they do not replace each other
    ck(sel(function(st) st.text = "arcanite"; st.makeable = true end) ==
       "Weapons,Arcanite Reaper",
       "text AND have-materials did not compose as a conjunction")
    ck(sel(function(st) st.text = "iron"; st.subclass = 2 end) == "Armor,Iron Shield",
       "text AND category did not compose as a conjunction")

    -- a surviving recipe NEVER appears without its header, and a header never
    -- appears alone (§A.2).
    do
        local st = Filters.NewState(); st.text = "copper"
        local out = Filters.Select(list, st)
        ck(#out == 2 and out[1].kind == "header" and out[1].name == "Armor",
           "a surviving recipe was emitted without its category header")
        for i = 1, #out - 1 do
            ck(not (out[i].kind == "header" and out[i + 1].kind == "header"),
               "an empty category header survived")
        end
        ck(out[#out].kind ~= "header", "a trailing empty header survived")
    end

    -- The dimensions offered follow the client's ACTUAL API surface: a client
    -- missing a setter offers no control for it (never a dead control).
    do
        local full = Filters.Dimensions(Filters.Api(TRADESKILL, {
            TradeSkillFrame = {}, GetNumTradeSkills = function() end,
            SetTradeSkillItemNameFilter = function() end,
            TradeSkillOnlyShowMakeable = function() end,
            SetTradeSkillSubClassFilter = function() end,
            GetTradeSkillSubClasses = function() end,
            SetTradeSkillInvSlotFilter = function() end,
            GetTradeSkillInvSlots = function() end,
        }))
        local keys = {}
        for i, d in ipairs(full) do keys[i] = d.key end
        ck(table.concat(keys, ",") == "text,makeable,subclass,slot",
           "the trade-skill surface did not offer its four dimensions (" ..
           table.concat(keys, ",") .. ")")

        local bare = Filters.Dimensions(Filters.Api(TRADESKILL, {}))
        ck(#bare == 0, "a client with none of the filter API still offered controls")

        -- The craft surface: slot + have-materials, and NO search box, because
        -- the client has no craft name filter to drive.
        local craft = Filters.DimensionKeys(Filters.Api(CRAFT, {
            CraftFrame = {}, CraftOnlyShowMakeable = function() end,
            SetCraftFilter = function() end, GetCraftSlots = function() end,
        }))
        ck(table.concat(craft, ",") == "makeable,slot",
           "the craft surface's dimension set was " .. table.concat(craft, ",")
           .. ", expected makeable,slot")
    end
end

-- The interlock the whole wave turns on.
local function testCaptureInterlock(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local P = ns.Professions
    if not (P and P.Dataset) then
        fails[#fails + 1] = "the professions module is not loaded; the interlock cannot be tested"
        return
    end
    local D = P.Dataset
    if not D.LoadCore() then
        fails[#fails + 1] = "the dataset would not load"
        return
    end

    -- Real recipes, so the capture resolves a real profession by id.
    local bs = D.profRecipes[D.profIdx.blacksmithing]
    local list = {
        { kind = "header", name = "Weapons" },
        { kind = "recipe", name = "Arcanite Reaper", avail = 1, sub = 1, slot = 1, s = bs[1] },
        { kind = "recipe", name = "Iron Sword",      avail = 0, sub = 1, slot = 1, s = bs[2] },
        { kind = "header", name = "Armor" },
        { kind = "recipe", name = "Iron Shield",     avail = 2, sub = 2, slot = 2, s = bs[3] },
        { kind = "recipe", name = "Copper Chain",    avail = 3, sub = 2, slot = 2, s = bs[4] },
    }
    local sim = newClientSim(list, function(row) return row.s end)

    local savedTime = _G.GetTime
    local savedLatch = { P._leavingWorld, P._loggingOut, P._enteredWorldAt, P._live, P._scanAt }
    local savedPerf = { P._settled, P._stale, P._harvested, P._harvestJob }
    local savedState = Filters._state
    local savedTimer = _G.C_Timer
    local savedArea = ns.Store and ns.Store.data and ns.Store.data.professions

    local ok, err = pcall(function()
        sim:install()
        _G.GetTime = function() return 20000 end
        _G.C_Timer = nil                  -- run the deferred capture inline
        P._leavingWorld, P._loggingOut = false, false
        P._enteredWorldAt = 0
        P._live, P._scanAt = nil, nil
        P._settled, P._stale = nil, nil
        P._harvested, P._harvestJob = nil, nil
        Filters._state = { [TRADESKILL] = Filters.NewState() }
        P.RegisterViewGuard(Filters.ViewGuard)

        local function knownCount()
            local live = P._live
            local rec = live and live.p and live.p.blacksmithing
            if not rec or not rec.k then return nil end
            local ids = P.DecodeKnown("blacksmithing", rec.k, nil)
            return ids and #ids or nil
        end

        -- (1) UNFILTERED: the whole list captures.
        local okCap = P.CaptureWindow(TRADESKILL, true)
        ck(okCap == true, "the unfiltered window did not capture")
        ck(knownCount() == 4, "the unfiltered capture wrote " .. tostring(knownCount())
           .. " known recipes, expected 4")

        -- (2) FILTERED VIEW, FULL CAPTURE. Engage a filter that really narrows
        --     the client's enumeration, then try to capture.
        Filters.SetState(TRADESKILL, function(st) st.text = "arcanite" end)
        ck(#sim.surviving() == 2, "the simulated client did not actually narrow ("
           .. #sim.surviving() .. " rows)")
        ck(_G.GetNumTradeSkills() == 2, "the client's own enumeration ignored the filter")
        ck(Filters.ViewGuard(TRADESKILL) == true, "the view guard did not see the filter")
        ck(P.ViewNarrowed(TRADESKILL) == true, "the capture layer did not see the filter")

        P._scanAt = nil
        local okFiltered, why = P.CaptureWindow(TRADESKILL, true)
        ck(okFiltered == false and why == "view-filtered",
           "a FILTERED window captured (" .. tostring(why) .. ") — the known set would "
           .. "have been silently truncated to the visible rows")
        ck(knownCount() == 4, "the filtered window replaced the known set with "
           .. tostring(knownCount()) .. " recipes; the full set must survive untouched")

        -- Every dimension, not just the text one.
        for _, mut in ipairs({
            function(st) st.makeable = true end,
            function(st) st.subclass = 1 end,
            function(st) st.slot = 2 end,
        }) do
            Filters.ResetSurface(TRADESKILL)
            Filters.SetState(TRADESKILL, mut)
            P._scanAt = nil
            local o, w = P.CaptureWindow(TRADESKILL, true)
            ck(o == false and w == "view-filtered",
               "a window narrowed by one of the picker dimensions still captured")
            ck(knownCount() == 4, "a narrowed window truncated the stored known set")
        end

        -- (3) CLEARING RE-CAPTURES, over the full list.
        P._live, P._scanAt = nil, nil
        Filters.ResetSurface(TRADESKILL)     -- C_Timer absent => capture runs inline
        ck(P.ViewNarrowed(TRADESKILL) == false, "clearing did not clear the guard")
        ck(knownCount() == 4, "clearing the filter did not re-capture the full list ("
           .. tostring(knownCount()) .. ")")

        -- (4) A CLOSED window narrows nothing, whatever the client is carrying.
        Filters.OnWindowHide(TRADESKILL)
        ck(Filters.ViewGuard(TRADESKILL) == false,
           "a closed window still reported itself as narrowing")

        -- (5) The client's OWN leftover name filter is caught even with no state
        --     of ours — the hazard that predates this panel.
        _G.SetTradeSkillItemNameFilter("iron")
        ck(P.ViewNarrowed(TRADESKILL) == true,
           "a name filter left in the client by anything else was invisible to the capture")
        _G.SetTradeSkillItemNameFilter("")
        ck(P.ViewNarrowed(TRADESKILL) == false, "the guard latched on after the filter cleared")
        -- ...and the same for the client's own have-materials box, which has a
        -- getter and therefore needs no state of ours to be seen.
        _G.TradeSkillOnlyShowMakeable(true)
        ck(P.ViewNarrowed(TRADESKILL) == true,
           "Blizzard's own Have Materials tick was invisible to the capture")
        _G.TradeSkillOnlyShowMakeable(false)
        ck(P.ViewNarrowed(TRADESKILL) == false,
           "the guard latched on after have-materials was cleared")

        -- (6) ...and the client's own SKILL-UPS box, which hides most of a maxed
        --     character's list, has a getter and was invisible until the live
        --     miss made the cost of a missing witness plain.
        local savedUps, savedGetUps = _G.TradeSkillOnlyShowSkillUps, _G.GetOnlyShowSkillUps
        local ups = false
        _G.TradeSkillOnlyShowSkillUps = function(v) ups = v and true or false end
        _G.GetOnlyShowSkillUps = function() return ups end
        _G.TradeSkillOnlyShowSkillUps(true)
        ck(P.ViewNarrowed(TRADESKILL) == true,
           "Blizzard's own skill-ups-only tick was invisible to the capture; the "
           .. "known set would have been truncated to the recipes that still level")
        Filters.ClearNative(TRADESKILL)
        ck(ups == false, "the window clear left the skill-ups box engaged, which is a "
           .. "refusal nothing in this file could ever lift")
        ck(P.ViewNarrowed(TRADESKILL) == false, "the skill-ups guard latched on")
        _G.TradeSkillOnlyShowSkillUps, _G.GetOnlyShowSkillUps = savedUps, savedGetUps
    end)

    sim:restore()
    _G.GetTime = savedTime
    _G.C_Timer = savedTimer
    P._leavingWorld, P._loggingOut = savedLatch[1], savedLatch[2]
    P._enteredWorldAt, P._live, P._scanAt = savedLatch[3], savedLatch[4], savedLatch[5]
    P._settled, P._stale = savedPerf[1], savedPerf[2]
    P._harvested, P._harvestJob = savedPerf[3], savedPerf[4]
    Filters._state = savedState
    if ns.Store and ns.Store.data then ns.Store.data.professions = savedArea end
    P.ClearViewGuards()
    if not ok then fails[#fails + 1] = "error in interlock fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- THE CONVENTION SUITE — what the client HONORS, not what we hoped
--
-- Wave P3's filter controls were reported broken in both directions on a live
-- 11509 client: the search box appeared to do nothing and the category picker
-- did not narrow. Both symptoms trace to things this file could not know and
-- assumed anyway — the argument convention of the two picker setters, and
-- whether setting a server-side filter repaints the window.
--
-- So the fixture below is a client whose picker setters share ONE filter record,
-- which is the shape that produces the reported defect, and it is instantiated
-- under three different argument conventions. The point is not that one of them
-- is the real 11509 (we cannot know that from here). The point is that the
-- shipped code must come out right under ALL of them, because that is what
-- "measured rather than assumed" has to mean to be worth anything.
--
-- Each leg carries a RED CONTROL: the pre-fix call sequence, replayed against
-- the same client, reproducing the owner's symptom.
----------------------------------------------------------------------

-- The list every convention leg filters. Two categories, two slots, one row with
-- no materials, so every dimension has something to bite on.
local function convFixture()
    return {
        { kind = "header", name = "Weapons" },
        { kind = "recipe", name = "Arcanite Reaper", avail = 1, sub = 1, slot = 1 },
        { kind = "recipe", name = "Iron Sword",      avail = 0, sub = 1, slot = 1 },
        { kind = "header", name = "Armor" },
        { kind = "recipe", name = "Iron Shield",     avail = 2, sub = 2, slot = 2 },
        { kind = "recipe", name = "Arcanite Plate",  avail = 1, sub = 2, slot = 2 },
        { kind = "recipe", name = "Copper Chain",    avail = 3, sub = 2, slot = 2 },
    }
end

-- A client whose two picker setters write the SAME three-field filter record.
--
--   "triple"    set(index, listAllSub, listAllSlot); a missing flag reads as 0,
--               i.e. "do not list all" — the unforgiving reading, and the one
--               under which a bare set(0) narrows the window to nothing.
--   "inverted"  the same three fields with the flag polarity the other way, so
--               the exact call P3 shipped as its blind CLEAR empties the list.
--   "indexonly" one argument, 0 means all, extra arguments ignored, and neither
--               setter touches the other's field.
local function newConventionSim(convention, rows)
    local G = _G
    local sim = { rows = rows or convFixture(), saved = {}, redraws = 0, convention = convention }
    sim.f = { text = "", makeable = false, sub = 0, slot = 0,
              allSub = true, allSlot = true }

    function sim.visible()
        local out, pending = {}, nil
        local f = sim.f
        for i = 1, #sim.rows do
            local row = sim.rows[i]
            if row.kind == "header" then
                pending = row
            else
                local keep = true
                if Filters.Trim(f.text) ~= "" and not Filters.TextMatches(row.name, f.text) then
                    keep = false
                end
                if f.makeable and (tonumber(row.avail) or 0) <= 0 then keep = false end
                if not f.allSub and (tonumber(row.sub) or 0) ~= f.sub then keep = false end
                if not f.allSlot and (tonumber(row.slot) or 0) ~= f.slot then keep = false end
                if keep then
                    if pending then out[#out + 1] = pending pending = nil end
                    out[#out + 1] = row
                end
            end
        end
        return out
    end

    local function setPicker(field, index, a, b)
        local f = sim.f
        f[field] = tonumber(index) or 0
        if convention == "indexonly" then
            if field == "sub" then f.allSub = (f.sub == 0) else f.allSlot = (f.slot == 0) end
        elseif convention == "inverted" then
            f.allSub  = (a ~= 1)
            f.allSlot = (b ~= 1)
        else                                       -- "triple"
            f.allSub  = (a == 1)
            f.allSlot = (b == 1)
        end
    end

    function sim:install()
        local s = sim.saved
        s.num, s.info, s.link = G.GetNumTradeSkills, G.GetTradeSkillInfo, G.GetTradeSkillRecipeLink
        s.line, s.setText, s.getText = G.GetTradeSkillLine,
            G.SetTradeSkillItemNameFilter, G.GetTradeSkillItemNameFilter
        s.makeable, s.getMakeable = G.TradeSkillOnlyShowMakeable, G.GetOnlyShowMakeable
        s.setSub, s.subs = G.SetTradeSkillSubClassFilter, G.GetTradeSkillSubClasses
        s.setSlot, s.slots = G.SetTradeSkillInvSlotFilter, G.GetTradeSkillInvSlots
        s.frame, s.update = G.TradeSkillFrame, G.TradeSkillFrame_Update

        G.GetNumTradeSkills = function() return #sim.visible() end
        G.GetTradeSkillInfo = function(i)
            local row = sim.visible()[i]
            if not row then return nil end
            return row.name, (row.kind == "header") and "header" or "optimal", row.avail or 0, false
        end
        G.GetTradeSkillRecipeLink = function() return nil end
        G.GetTradeSkillLine = function() return "Blacksmithing", 275, 300 end
        G.SetTradeSkillItemNameFilter = function(t) sim.f.text = t or "" end
        G.GetTradeSkillItemNameFilter = function() return sim.f.text end
        G.TradeSkillOnlyShowMakeable = function(v) sim.f.makeable = v and true or false end
        G.GetOnlyShowMakeable = function() return sim.f.makeable end
        G.SetTradeSkillSubClassFilter  = function(i, a, b) setPicker("sub", i, a, b) end
        G.SetTradeSkillInvSlotFilter   = function(i, a, b) setPicker("slot", i, a, b) end
        G.GetTradeSkillSubClasses = function() return { "Weapon", "Armor" } end
        G.GetTradeSkillInvSlots   = function() return { "Head", "Chest" } end
        G.TradeSkillFrame = {}
        -- THE DISPLAY. The client only repaints when its own update runs, which
        -- is why a filter that works can still look like a filter that does not.
        sim.displayed = sim.visible()
        G.TradeSkillFrame_Update = function()
            sim.redraws = sim.redraws + 1
            sim.displayed = sim.visible()
        end
    end

    function sim:restore()
        local s = sim.saved
        G.GetNumTradeSkills, G.GetTradeSkillInfo = s.num, s.info
        G.GetTradeSkillRecipeLink, G.GetTradeSkillLine = s.link, s.line
        G.SetTradeSkillItemNameFilter, G.GetTradeSkillItemNameFilter = s.setText, s.getText
        G.TradeSkillOnlyShowMakeable, G.GetOnlyShowMakeable = s.makeable, s.getMakeable
        G.SetTradeSkillSubClassFilter, G.GetTradeSkillSubClasses = s.setSub, s.subs
        G.SetTradeSkillInvSlotFilter, G.GetTradeSkillInvSlots = s.setSlot, s.slots
        G.TradeSkillFrame, G.TradeSkillFrame_Update = s.frame, s.update
    end

    return sim
end

-- THE RED CONTROL: wave P3's ApplyNative, exactly as it shipped. The judgement
-- call is in the last four lines — an unverified "show all" convention passed
-- blind, and a slot call that lands AFTER the subclass call and overwrites the
-- flag the subclass call had just set.
local function prefixApplyNative(state)
    local G = _G
    if G.SetTradeSkillItemNameFilter then
        pcall(G.SetTradeSkillItemNameFilter, Filters.Trim(state.text))
    end
    if G.TradeSkillOnlyShowMakeable then
        pcall(G.TradeSkillOnlyShowMakeable, state.makeable and true or false)
    end
    local i = tonumber(state.subclass) or 0
    if i > 0 then pcall(G.SetTradeSkillSubClassFilter, i, 0, 1)
    else pcall(G.SetTradeSkillSubClassFilter, 0, 1, 1) end
    local j = tonumber(state.slot) or 0
    if j > 0 then pcall(G.SetTradeSkillInvSlotFilter, j, 0, 1)
    else pcall(G.SetTradeSkillInvSlotFilter, 0, 1, 1) end
    -- ...and no repaint at all, which is the other half of the report.
end

local function testNativeConventions(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function freshState(mut)
        local st = Filters.NewState()
        if mut then mut(st) end
        return st
    end

    local function reset()
        -- Session AND store: the persisted forms would otherwise leak between
        -- the three simulated clients, which are three different "builds" of
        -- the world sharing one store.
        Filters.ForgetConventions(nil)
        Filters._conv, Filters._unhonored, Filters._probing = nil, nil, nil
        Filters._redrawFn, Filters._toldUnhonored = nil, nil
    end

    local savedConv = { Filters._conv, Filters._unhonored, Filters._probing,
                        Filters._redrawFn, Filters._toldUnhonored }

    local ok, err = pcall(function()
        -- ══ (1) THE SHARED-RECORD CLIENT: the category picker report ═════════
        do
            local sim = newConventionSim("triple")
            sim:install()
            reset()
            local full = _G.GetNumTradeSkills()
            ck(full == 7, "the fixture did not start unfiltered (" .. full .. " rows)")

            -- RED: P3's sequence. The subclass call narrows and the slot call,
            -- one line later, hands the flag back — the list is full again. This
            -- is "selecting a category doesnt filter the recipes correctly",
            -- reproduced.
            prefixApplyNative(freshState(function(st) st.subclass = 1 end))
            ck(_G.GetNumTradeSkills() == full,
               "RED CONTROL DID NOT REPRODUCE: the pre-fix sequence narrowed the "
               .. "category after all — the fixture no longer models the defect")

            -- GREEN: measured. The winning form is found by trying and counting.
            reset()
            Filters.ApplyNative(TRADESKILL, freshState(function(st) st.subclass = 1 end))
            ck(_G.GetNumTradeSkills() == 3,
               "the measured category filter left " .. _G.GetNumTradeSkills()
               .. " rows, expected 3 (one header + two weapons)")
            ck(Filters._conv[TRADESKILL].subPick ~= nil,
               "the category form was applied without being recorded")

            -- The SLOT picker's winning form is a DIFFERENT one — the two flags
            -- are not interchangeable, which is exactly the assumption that
            -- shipped. A single hard-coded convention cannot satisfy both.
            reset()
            Filters.ApplyNative(TRADESKILL, freshState(function(st) st.slot = 2 end))
            ck(_G.GetNumTradeSkills() == 4,
               "the measured slot filter left " .. _G.GetNumTradeSkills()
               .. " rows, expected 4 (one header + three armor)")

            -- Both at once still composes.
            reset()
            Filters.ApplyNative(TRADESKILL, freshState(function(st)
                st.subclass = 2 st.slot = 2 end))
            ck(_G.GetNumTradeSkills() == 4,
               "category AND slot together left " .. _G.GetNumTradeSkills() .. " rows, expected 4")

            -- Clearing goes all the way back.
            Filters.ClearNative(TRADESKILL)
            ck(_G.GetNumTradeSkills() == full,
               "the measured clear did not restore the full list (" ..
               _G.GetNumTradeSkills() .. "/" .. full .. ")")
            sim:restore()
        end

        -- ══ (2) THE INVERTED CLIENT: the blind clear that empties the window ══
        -- This is the hazard that made the whole judgement call dangerous rather
        -- than merely wrong: the SAME call P3 used to guarantee an unfiltered
        -- window narrows this client to nothing, and every capture behind it
        -- then reads an empty list.
        do
            local sim = newConventionSim("inverted")
            sim:install()
            reset()
            local full = _G.GetNumTradeSkills()

            prefixApplyNative(freshState())          -- the pre-fix CLEAR
            ck(_G.GetNumTradeSkills() == 0,
               "RED CONTROL DID NOT REPRODUCE: the blind clear left "
               .. _G.GetNumTradeSkills() .. " rows on the inverted client")

            reset()
            Filters.ClearNative(TRADESKILL)
            ck(_G.GetNumTradeSkills() == full,
               "the measured clear narrowed the window it was supposed to open ("
               .. _G.GetNumTradeSkills() .. "/" .. full .. ") — a clear that can "
               .. "narrow is the defect that took the capture layer down with it")
            sim:restore()
        end

        -- ══ (3) THE INDEX-ONLY CLIENT: the same code, no flags sent ══════════
        do
            local sim = newConventionSim("indexonly")
            sim:install()
            reset()
            local full = _G.GetNumTradeSkills()
            Filters.ApplyNative(TRADESKILL, freshState(function(st) st.subclass = 1 end))
            ck(_G.GetNumTradeSkills() == 3,
               "the index-only client was not narrowed (" .. _G.GetNumTradeSkills() .. ")")
            ck(Filters.FormName(Filters._conv[TRADESKILL].subPick) == "(i)",
               "the index-only client was handed flags it never asked for ("
               .. Filters.FormName(Filters._conv[TRADESKILL].subPick) .. ")")
            Filters.ClearNative(TRADESKILL)
            ck(_G.GetNumTradeSkills() == full, "the index-only clear did not restore the list")
            sim:restore()
        end

        -- ══ (4) THE REPAINT: a filter nobody drew is a filter nobody has ═════
        do
            local sim = newConventionSim("triple")
            sim:install()
            reset()
            local function displayedNames()
                local out = {}
                for i = 1, #sim.displayed do out[i] = sim.displayed[i].name end
                return table.concat(out, ",")
            end
            local before = displayedNames()

            -- RED: the pre-fix path filters the client and never repaints, so
            -- the rows on screen are the rows from before. To the player that is
            -- "typing into the search recipes doesnt return anything".
            prefixApplyNative(freshState(function(st) st.text = "arcanite" end))
            ck(displayedNames() == before,
               "RED CONTROL DID NOT REPRODUCE: the display changed without a repaint")
            ck(_G.GetNumTradeSkills() < 7,
               "the client's own enumeration did not narrow, so the red control is "
               .. "proving the wrong thing")

            -- GREEN: the shipped path drives the client's own update.
            reset()
            Filters.ApplyNative(TRADESKILL, freshState(function(st) st.text = "arcanite" end))
            ck(sim.redraws > 0, "the client's list-update was never called")
            ck(displayedNames() == "Weapons,Arcanite Reaper,Armor,Arcanite Plate",
               "the repainted list was '" .. displayedNames() .. "'")
            ck(Filters._redrawFn[TRADESKILL] == "TradeSkillFrame_Update",
               "the repaint function was not recorded for the diagnostics")

            -- And a client with NO update function is recorded as such rather
            -- than silently doing nothing.
            _G.TradeSkillFrame_Update = nil
            reset()
            Filters.ApplyNative(TRADESKILL, freshState())
            ck(Filters._redrawFn[TRADESKILL] == false,
               "a client with no list-update was not recorded as such")
            sim:restore()
        end

        -- ══ (5) A DIMENSION THE CLIENT WILL NOT HONOR IS NOT PRETENDED ═══════
        do
            local sim = newConventionSim("triple")
            sim:install()
            reset()
            -- A client whose subclass setter is a no-op: nothing we can say
            -- narrows it, so the control must stand down rather than sit there
            -- looking engaged over an unfiltered list.
            _G.SetTradeSkillSubClassFilter = function() end
            local full = _G.GetNumTradeSkills()
            Filters._state = { [TRADESKILL] = Filters.NewState() }
            Filters.SetState(TRADESKILL, function(st) st.subclass = 1 end)
            ck(_G.GetNumTradeSkills() == full,
               "a no-op setter still produced a narrowed list")
            ck(Filters._unhonored[TRADESKILL].subclass == true,
               "an ignored dimension was not recorded as unhonored")
            ck((Filters._state[TRADESKILL].subclass or 0) == 0,
               "the picker kept a value the client never applied")
            ck(Filters.ViewGuard(TRADESKILL) == false,
               "a filter the client ignored still blocked the capture forever")
            Filters._state = nil
            sim:restore()
        end

        -- ══ (6) THE PROBE ITSELF IS INTERLOCKED ══════════════════════════════
        -- Measuring means deliberately narrowing the client, so a capture that
        -- read the list mid-probe would read a list we narrowed on purpose.
        do
            local sim = newConventionSim("triple")
            sim:install()
            reset()
            local P = ns.Professions
            local seen = {}
            local savedSetSub = _G.SetTradeSkillSubClassFilter
            _G.SetTradeSkillSubClassFilter = function(i, a, b)
                seen[#seen + 1] = Filters.ViewGuard(TRADESKILL) and true or false
                return savedSetSub(i, a, b)
            end
            Filters.ApplyNative(TRADESKILL, freshState(function(st) st.subclass = 1 end))
            local allGuarded = #seen > 0
            for i = 1, #seen do if not seen[i] then allGuarded = false end end
            ck(allGuarded, "the client's filters were moved with the capture unguarded ("
               .. #seen .. " calls) — a scan landing mid-probe would have written a "
               .. "deliberately narrowed known set")
            ck(Filters.ViewGuard(TRADESKILL) ~= true or Filters.Narrowed(
                   Filters._state and Filters._state[TRADESKILL] or nil),
               "the probing latch did not come back down")
            if P and P.ViewNarrowedWhy then
                local savedGuards = P._viewGuards
                P.ClearViewGuards()
                P.RegisterViewGuard(Filters.ViewGuard)
                Filters._probing = { [TRADESKILL] = true }
                local narrowed, why = P.ViewNarrowedWhy(TRADESKILL)
                ck(narrowed == true and tostring(why):find("probing", 1, true) ~= nil,
                   "the capture layer could not see the probe (" .. tostring(why) .. ")")
                Filters._probing = nil
                P._viewGuards = savedGuards
            end
            sim:restore()
        end

        -- ══ (7) THE WINDOW THAT OPENS EMPTY ══════════════════════════════════
        -- The measurement is only worth what the window had to measure. A clear
        -- that ran before the server's rows arrived scored every candidate at
        -- zero and picked one arbitrarily; on a client where the arbitrary pick
        -- narrows, living with that answer would hide the whole list the moment
        -- it arrived. So the answer is marked unsettled and re-asked.
        do
            local sim = newConventionSim("triple")
            local landed = false
            sim:install()
            reset()
            local realNum = _G.GetNumTradeSkills
            _G.GetNumTradeSkills = function() return landed and realNum() or 0 end

            Filters._state = { [TRADESKILL] = Filters.NewState() }
            Filters.ClearNative(TRADESKILL)                       -- measured in the dark
            ck(Filters.Conv(TRADESKILL).settled ~= true,
               "a measurement taken against an empty window claimed to be settled")

            landed = true
            Filters.OnWindowUpdate(TRADESKILL)                    -- the rows arrive
            ck(Filters.Conv(TRADESKILL).settled == true,
               "the settle never ran once the rows were there")
            ck(_G.GetNumTradeSkills() == 7,
               "the window that opened empty stayed narrowed after its rows landed ("
               .. _G.GetNumTradeSkills() .. "/7) — the clear taken in the dark was kept")

            -- ...and it does not keep re-asking.
            local before = sim.redraws
            Filters.OnWindowUpdate(TRADESKILL)
            ck(sim.redraws == before, "the settle re-ran after it had already settled")

            _G.GetNumTradeSkills = realNum
            Filters._state = nil
            sim:restore()
        end

        -- ══ (8) PERSISTENCE ACROSS SESSIONS, per client build ════════════════
        -- The forms learned by measurement seed the next session from the store
        -- instead of re-running the sweep — and the class-5 rule survives the
        -- persistence: a stored form that stops working is dropped, store and
        -- session both, and re-measured.
        do
            local sim = newConventionSim("triple")
            sim:install()
            reset()
            -- Learn the expensive way once.
            Filters.ApplyNative(TRADESKILL, freshState(function(st) st.subclass = 1 end))
            local learned = Filters.FormName(Filters._conv[TRADESKILL].subPick)
            ck(learned ~= "none", "no category form was learned to persist")

            -- "Relog": session mirror gone, store intact.
            Filters._conv = nil
            local conv = Filters.Conv(TRADESKILL)
            ck(Filters.FormName(conv.subPick) == learned,
               "the persisted category form did not seed the new session ("
               .. Filters.FormName(conv.subPick) .. " vs " .. learned .. ")")

            -- The seeded clear takes the FAST PATH: the remembered show-all
            -- form is verified against the live count instead of re-sweeping
            -- every candidate. Two calls (fast path + the interference
            -- re-assert), where the sweep costs four candidates or more.
            local calls = 0
            local realSetSub = _G.SetTradeSkillSubClassFilter
            _G.SetTradeSkillSubClassFilter = function(...)
                calls = calls + 1
                return realSetSub(...)
            end
            Filters.ClearNative(TRADESKILL)
            ck(_G.GetNumTradeSkills() == 7,
               "the seeded clear did not leave the full list ("
               .. _G.GetNumTradeSkills() .. "/7)")
            ck(calls <= 2, "the seeded clear still swept the candidates ("
               .. calls .. " subclass setter calls)")
            _G.SetTradeSkillSubClassFilter = realSetSub
            sim:restore()

            -- CLASS 5: the same store, but the client's convention has moved
            -- out from under it (the inverted client). The persisted show-all
            -- form now EMPTIES the window; it must be dropped and re-measured,
            -- never trusted, and the clear must still end on the full list.
            local sim2 = newConventionSim("inverted")
            sim2:install()
            Filters._conv = nil                    -- fresh session, seeded from store
            Filters.ClearNative(TRADESKILL)
            ck(_G.GetNumTradeSkills() == 7,
               "a persisted form that stopped working was kept: the clear left "
               .. _G.GetNumTradeSkills() .. " rows on the changed client")
            local area = Filters.ConvStoreArea(false)
            local storedSubAll = area and area[TRADESKILL] and area[TRADESKILL].subAll
            ck(storedSubAll == nil or Filters.FormName(storedSubAll) ~= "(i,1,1)",
               "the store still carries the dead (i,1,1) show-all form")
            sim2:restore()
        end
    end)

    reset()
    Filters._conv, Filters._unhonored, Filters._probing = savedConv[1], savedConv[2], savedConv[3]
    Filters._redrawFn, Filters._toldUnhonored = savedConv[4], savedConv[5]
    if not ok then fails[#fails + 1] = "error in convention fixtures: " .. tostring(err) end
end

local function testInertness(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local P = ns.Professions
    if not P then return end

    local S = ns.Store
    local db = S and S.GetSettings and S.GetSettings()
    local savedSetting = db and db.professionsEnabled
    local savedFrame, savedActive = Filters._frame, Filters._activated
    local savedState = Filters._state

    local ok, err = pcall(function()
        Filters._state = { [TRADESKILL] = Filters.NewState() }
        P.SetEnabled(false)
        ck(Filters.IsEnabled() == false, "the filters module outlived its parent")
        ck(Filters.Active() == false, "a disabled module still reports its panel active")
        ck(Filters._frame == nil, "the event frame survived the module being disabled")
        ck(Filters._activated == false, "the module still reports itself activated")
        ck(Filters._state == nil, "filter state survived the module being disabled")
        ck(Filters.ViewGuard(TRADESKILL) == false, "a torn-down guard still narrowed")
        ck(Filters.Activate() == false, "a disabled module activated")
        ck(Filters.OnWindowShow(TRADESKILL) == false, "a disabled module built a panel")
        ck(Filters._panels == nil or Filters._panels[TRADESKILL] == nil
           or not Filters._panels[TRADESKILL]:IsShown(),
           "a disabled module left a panel on screen")

        P.SetEnabled(true)
        ck(Filters.IsEnabled() == true, "re-enabling the parent did not re-enable the filters")
    end)

    P.SetEnabled(false)
    if db then db.professionsEnabled = savedSetting end
    Filters._frame, Filters._activated = savedFrame, savedActive
    Filters._state = savedState
    if not ok then fails[#fails + 1] = "error in inertness fixtures: " .. tostring(err) end
end

function Filters.RunSelfTests(verbose)
    local suites = {
        { name = "pure model (state, narrowing, plain matching, stand-down)", fn = testPureModel },
        { name = "filter dimensions through the list model", fn = testDimensions },
        { name = "native filter conventions, measured on three different clients",
          fn = testNativeConventions },
        { name = "capture interlock (a filtered VIEW never becomes a filtered CAPTURE)",
          fn = testCaptureInterlock },
        { name = "inertness (off = no frame, no panel, no guard)", fn = testInertness },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local f = {}
        local ok = pcall(suite.fn, f)
        local passed = ok and #f == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS proffilters/" .. suite.name)
            elseif not ok then ns:Print("  FAIL proffilters/" .. suite.name .. " :: error in test")
            else for _, m in ipairs(f) do ns:Print("  FAIL proffilters/" .. suite.name .. " :: " .. m) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("proffilters", Filters.RunSelfTests)
end
