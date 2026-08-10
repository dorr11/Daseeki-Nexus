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

-- Session state. All nil/false until Activate().
Filters._activated = false
Filters._frame     = nil
Filters._state     = nil     -- surface -> live filter state (nil = window closed)
Filters._panels    = nil     -- surface -> panel frame
Filters._hooked    = nil     -- surface -> true once the game frame's scripts are hooked
Filters._prof      = nil     -- surface -> the profession name the window last showed
Filters._textTimer = nil     -- surface -> debounce generation

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
-- LIVE: pushing the state at the client
----------------------------------------------------------------------

-- Every call is guarded and pcall'd. A client that has moved on and dropped one
-- of these functions loses that dimension, not the window.
function Filters.ApplyNative(surface, state, G)
    local api = Filters.Api(surface, G)
    state = state or Filters.NewState()
    if api.setText then pcall(api.setText, Filters.Trim(state.text)) end
    if api.setMakeable then pcall(api.setMakeable, state.makeable and true or false) end
    if api.setSub then
        local i = tonumber(state.subclass) or 0
        -- The client's own convention for these two: index 0 with the "list all"
        -- flag means every subclass; a real index selects one and hides the rest.
        if i > 0 then pcall(api.setSub, i, 0, 1) else pcall(api.setSub, 0, 1, 1) end
    end
    if api.setSlot then
        local i = tonumber(state.slot) or 0
        if surface == CRAFT then
            -- The craft surface's slot filter takes the index alone.
            pcall(api.setSlot, i)
        elseif i > 0 then pcall(api.setSlot, i, 0, 1)
        else pcall(api.setSlot, 0, 1, 1) end
    end
    return true
end

-- Everything back to "show me all of it". This is what runs on window show and
-- on window hide, and it is the reason the next capture sees a full list.
function Filters.ClearNative(surface, G)
    return Filters.ApplyNative(surface, Filters.NewState(), G)
end

-- The witness professions.lua's capture consults. A window that is closed
-- narrows nothing, so a nil state is an honest false.
function Filters.ViewGuard(surface)
    local st = Filters._state and Filters._state[surface]
    if not st then return false end
    return Filters.Narrowed(st)
end

-- The one place a filter change lands: push it at the client, refresh the
-- controls, and — when nothing narrows any more — re-capture the full list.
function Filters.SetState(surface, mutate)
    local st = Filters._state and Filters._state[surface]
    if not st then return false end
    if type(mutate) == "function" then mutate(st) end
    Filters.ApplyNative(surface, st)
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
    x = x + 56 + PAD

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
    local now = Filters.ProfessionName(surface)
    local was = Filters._prof and Filters._prof[surface]
    if now and was and now ~= was then
        Filters._prof[surface] = now
        Filters.ResetSurface(surface)
        return true
    end
    if now and not was and Filters._prof then Filters._prof[surface] = now end
    return false
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
    local savedState = Filters._state
    local savedTimer = _G.C_Timer

    local ok, err = pcall(function()
        sim:install()
        _G.GetTime = function() return 20000 end
        _G.C_Timer = nil                  -- run the deferred capture inline
        P._leavingWorld, P._loggingOut = false, false
        P._enteredWorldAt = 0
        P._live, P._scanAt = nil, nil
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
    end)

    sim:restore()
    _G.GetTime = savedTime
    _G.C_Timer = savedTimer
    P._leavingWorld, P._loggingOut = savedLatch[1], savedLatch[2]
    P._enteredWorldAt, P._live, P._scanAt = savedLatch[3], savedLatch[4], savedLatch[5]
    Filters._state = savedState
    P.ClearViewGuards()
    if not ok then fails[#fails + 1] = "error in interlock fixtures: " .. tostring(err) end
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
