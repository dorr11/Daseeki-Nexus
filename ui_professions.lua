-- Daseeki Nexus — ui_professions.lua  (THE PROFESSIONS TAB, wave P2)
--
-- P1 gathered the facts and said nothing. This file is the saying: a dedicated
-- tab in the dashboard shell, peer to Characters, holding the four surfaces the
-- owner's rework settled on (annotated-screenshot pass, 2026-08-10) —
--
--   THE GRID        left pane (GRID_FRACTION of the body): one row per
--                   character in the SAME order the cards use, two PRIMARY
--                   cells + the COOKING / FIRST AID / FISHING chips. Poisons
--                   has NO grid column — the data stays captured and speaks
--                   through the detail pane's tab instead. Clicking a row
--                   SELECTS the character (the cards' cursor idiom: selecting
--                   again keeps it; selection never clears itself).
--
--   THE DETAIL      top-right pane, always there: the selected character's
--                   professions as TABS across the top (a rogue's Poisons tab
--                   included; zero-recipe professions earn none — see
--                   DetailTabs), the picked tab showing the recipe census —
--                   the filter band, the known/missing list, and the selected
--                   recipe's SOURCE info band. This pane REPLACES the old
--                   mode-swap drill-in outright. (The MATERIALS block was
--                   retired 2026-08-10; the list wears its height.)
--
--   THE COOLDOWNS   bottom-right pane: ONE ROW PER COOLDOWN KIND the store has
--                   seen (Mooncloth, the transmute group, …), each naming the
--                   characters READY to craft it right now, class-colored. A
--                   character mid-cooldown is simply not listed (the owner's
--                   rule), and a kind no character owns is not a row.
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
-- goes through a small PURE function over it (ProfUI.GridColumns,
-- ProfUI.GridRowY, ProfUI.SplitWidths, ProfUI.RightSplitHeights,
-- ProfUI.DetailTabLayout). Moving a column is editing one number, not hunting
-- anchor arithmetic through a thousand lines.
--
-- THE OVERFLOW LESSON (the FISHING/POISONS bleed, 2026-08-10). The previous
-- pass placed the grid columns at CONSTANT x-offsets and "proved" the fit by
-- comparing two constants at ONE assumed shell width (1096, eleven pixels of
-- slack) — the columns never read the pane they lived in, the pane's real
-- width depended on a resize-timing dance (applySplit is a no-op until the
-- body's rect resolves), and nothing capped a cell's text at its own column
-- pitch. Column geometry is now a function of the REAL pane width at render
-- time: ProfUI.GridColumns(availW) shrinks every column proportionally when
-- the pane is narrower than the natural sum, so the band's right edge can
-- never pass the pane at ANY width; the header labels are width-capped to
-- their own columns and the header band clips; and the self-test exercises
-- the fit at MULTIPLE shell widths instead of pinning one.
--
-- DREW_UI_STYLE compliance notes, so the next reader can check them:
--   1 fixed-width bands, content hugging its natural width — up to the pane:
--     at or above the natural sum the columns sit at their LAYOUT pitch; below
--     it, fitting the pane wins (GridColumns' proportional shrink).
--   3 the detail pane is the list+editor shape re-homed: tabs pick the list,
--     the recipe detail band sits under it.
--   4 no dead bands: every panel's first content row sits one PANEL_PAD under
--     its header rule.
--   5 one grid: each filter row's controls share one baseline and one height.
--   6 every control is labeled — the search boxes carry inline labels, the
--     source chip prints "SOURCE: …", the grid columns carry a header band.
--   7 stable layout: no layout modes — but every pane and column re-derives
--     from the real rect on OnSizeChanged AND at the top of every Refresh.
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
    HEAD_H      = 18,   -- column-header band inside the grid panel
    CHIP_H      = 44,   -- the filter chip bar at the top of the grid panel —
                        -- the SAME 44 the characters view's chip bar wears
                        -- (owner, 2026-08-10: "add these same filters"), so the
                        -- two tabs share one rhythm. Costs the grid one 32px
                        -- row and change; the self-test pins both facts.

    -- The owner's rework splits: the grid pane takes GRID_FRACTION of the
    -- body's width (his first boxes said "~55-60%" and 60 shipped; the
    -- iteration round he booked then moved it — owner, 2026-08-10: an even
    -- 50/50, the detail column earning the width), and the right column gives
    -- DETAIL_FRACTION of its height to the detail pane, the rest to the
    -- cooldown kinds. ProfUI.SplitWidths() and ProfUI.RightSplitHeights()
    -- are the only readers. The grid absorbs the narrower pane the way it
    -- absorbs ANY pane: GridColumns shrinks every column pitch off the real
    -- width and every cell text stays capped at its own column — at the 700px
    -- shell the band now rides ~0.45 of natural (was ~0.54), tight but honest.
    GRID_FRACTION   = 0.50,
    DETAIL_FRACTION = 0.70,

    ROW_H       = 32,   -- one character row in the grid
    NAME_W      = 150,  -- the class-colored name column (natural width)
    CELL_W      = 140,  -- one PRIMARY profession cell (natural width)
    CELL_GAP    = 8,
    PRIMARIES   = 2,    -- a character may hold two primaries; the slots are fixed
    SEC_W       = 78,   -- one SECONDARY chip (natural width)
    SEC_GAP     = 6,
    GROUP_GAP   = 16,   -- primaries block -> secondaries block

    ICON        = 18,
    SEC_ICON    = 14,

    DTAB_H      = 22,   -- one profession tab in the detail pane's strip
    DTAB_GAP    = 4,
    DTAB_MAX    = 120,  -- a tab never grows past this (two tabs hug left)

    CD_LABEL_W  = 170,  -- the cooldown kind's name column

    LIST_ROW_H  = 20,   -- recipe / cooldown / search rows
    FILTER_H    = 24,   -- one filter row in the detail pane (there are two)

    -- The recipe list's column geometry (detail pane). These used to live as
    -- baked per-FontString anchors inside makeRecipeRow plus an ad-hoc titleW
    -- in the render — the exact shape the grid's overflow lesson bans. They
    -- are now LAYOUT constants read ONLY through ProfUI.RecipeColumns, so the
    -- rows and the column-header band (owner, 2026-08-10: "add column headers
    -- in the Detail list") share one x/width source and cannot drift apart.
    REC_MARK_X     = 2,    -- the state marker's left inset
    REC_MARK_W     = 14,   -- the state marker column
    REC_TITLE_GAP  = 4,    -- marker -> recipe name
    REC_TITLE_FRAC = 0.55, -- the name column's share of the real list width
    REC_TITLE_MIN  = 140,  -- ... clamped to stay readable in a narrow pane
    REC_TITLE_MAX  = 260,  -- ... and to leave the source column a remainder
    REC_SKILL_GAP  = 4,    -- name -> skill requirement
    REC_SKILL_W    = 38,   -- the skill column (right-justified numerals)
    REC_SRC_GAP    = 10,   -- skill -> source kind
    REC_SRC_PAD    = 4,    -- source column -> the row's right edge

    -- The acquisition text's line budget. One line stopped fitting the moment
    -- the acquisition phrases grew their zone suffixes ("Sold by Fradd
    -- Swiftgear \226\128\148 Gnomeregan area" style, 2026-08-10) — the owner's
    -- screenshot showed the line truncating — so the band wears TWO lines and
    -- text that still exceeds them ellipsizes (native FontString behavior,
    -- no scrolling). ProfUI.AcqTextHeight() is the only reader of the pair.
    ACQ_LINES   = 2,    -- how many lines the acquisition FontString may wear
    ACQ_LINE_H  = 14,   -- one acquisition line (the small role) incl. its gap

    INFO_H      = 58,   -- the selected-recipe info band: name + acquisition,
                        -- the acquisition wearing its ACQ_LINES lines: the old
                        -- one-line band (44) grown by exactly one ACQ_LINE_H,
                        -- which is precisely the height the recipe LIST above
                        -- yields back. (Was DETAIL_H = 132 when a MATERIALS
                        -- block lived here; the owner retired that block,
                        -- 2026-08-10, and the freed height belongs to the
                        -- recipe LIST above.)
    SCROLL_STEP = 40,
}
ProfUI.LAYOUT = L

-- PURE placement maths. GridRowY is a function of LAYOUT alone; everything
-- horizontal goes through GridColumns, which is a function of LAYOUT *and the
-- real pane width* — the overflow lesson, spelled out in the header.
function ProfUI.GridRowY(i)          return (i - 1) * L.ROW_H end

-- PURE. The grid's column geometry, derived from the width ACTUALLY available
-- to the row band at render time. At (or above) the natural sum every column
-- sits at its LAYOUT width; below it, every column shrinks proportionally
-- (the gaps hold still) and each width floors, so the band's right edge can
-- never pass availW — at any window size, with no assumed constant anywhere.
-- Returns { name = {x,w}, prim = {{x,w},…}, sec = { cooking = {x,w}, … },
--           width = <right edge>, scale = <1 or the shrink factor> }.
function ProfUI.GridColumns(availW)
    availW = tonumber(availW) or 0
    local secs = ProfUI.GRID_SECONDARIES
    local gaps = (L.PRIMARIES - 1) * L.CELL_GAP + L.GROUP_GAP + (#secs - 1) * L.SEC_GAP
    local natural = L.NAME_W + L.PRIMARIES * L.CELL_W + #secs * L.SEC_W
    local full = natural + gaps
    local scale = 1
    if availW < full then scale = (availW > 0) and (availW / full) or 0 end
    -- Columns AND gaps shrink together; each floors, so the accumulated right
    -- edge can only ever fall short of availW, never pass it.
    local function dim(nat) return math.floor(nat * scale) end
    local cols = { name = { x = 0, w = dim(L.NAME_W) }, prim = {}, sec = {} }
    local x = cols.name.w
    for slot = 1, L.PRIMARIES do
        if slot > 1 then x = x + dim(L.CELL_GAP) end
        cols.prim[slot] = { x = x, w = dim(L.CELL_W) }
        x = x + cols.prim[slot].w
    end
    x = x + dim(L.GROUP_GAP)
    for i, key in ipairs(secs) do
        if i > 1 then x = x + dim(L.SEC_GAP) end
        cols.sec[key] = { x = x, w = dim(L.SEC_W) }
        x = x + cols.sec[key].w
    end
    cols.width = x
    cols.scale = scale
    return cols
end

-- The NATURAL width of the column band (every column at its LAYOUT width) —
-- the born-size for pooled rows and the "stop growing" point of the fit.
function ProfUI.GridWidth()
    return ProfUI.GridColumns(1e9).width
end

-- PURE. The horizontal pane split: grid pane width, right-column width, as a
-- function of the body's total width. The two panes plus the gutter always
-- conserve the total, so a rounding slop can never open a stray column of
-- background between the right column and the body's right edge.
function ProfUI.SplitWidths(total)
    total = tonumber(total) or 0
    local avail = total - L.GUTTER
    if avail < 0 then avail = 0 end
    local gridW = math.floor(avail * L.GRID_FRACTION + 0.5)
    return gridW, avail - gridW
end

-- PURE. The right column's vertical split: detail pane height, cooldown pane
-- height. Same conservation rule as SplitWidths, on the other axis.
function ProfUI.RightSplitHeights(total)
    total = tonumber(total) or 0
    local avail = total - L.GUTTER
    if avail < 0 then avail = 0 end
    local detailH = math.floor(avail * L.DETAIL_FRACTION + 0.5)
    return detailH, avail - detailH
end

-- PURE. The recipe list's bottom inset inside the detail pane: the info band
-- plus its breathing room. The list owns everything between the filter rows and
-- this inset — retiring the materials block (info band 132 -> INFO_H) is what
-- bought the list its extra rows, and the self-test pins that the inset never
-- quietly grows back. The two-line acquisition text (2026-08-10) took exactly
-- one ACQ_LINE_H of that gain back, and the self-test pins that too.
function ProfUI.RecipeListBottomInset()
    return L.INFO_H + L.PANEL_PAD + 4
end

-- PURE. The recipe list's column geometry, from the width ACTUALLY available
-- at render time (the grid's overflow lesson, applied to the detail pane): the
-- state marker, the recipe name (its share of the real width, clamped), the
-- skill requirement, and the source kind wearing the remainder. ONE reader for
-- the rows AND the header band — they cannot disagree.
-- Returns { mark = {x,w}, title = {x,w}, skill = {x,w}, src = {x,w} }.
function ProfUI.RecipeColumns(availW)
    availW = tonumber(availW) or 0
    local titleW = math.floor(availW * L.REC_TITLE_FRAC)
    if titleW < L.REC_TITLE_MIN then titleW = L.REC_TITLE_MIN
    elseif titleW > L.REC_TITLE_MAX then titleW = L.REC_TITLE_MAX end
    local titleX = L.REC_MARK_X + L.REC_MARK_W + L.REC_TITLE_GAP
    local skillX = titleX + titleW + L.REC_SKILL_GAP
    local srcX   = skillX + L.REC_SKILL_W + L.REC_SRC_GAP
    local srcW   = availW - L.REC_SRC_PAD - srcX
    if srcW < 1 then srcW = 1 end
    return {
        mark  = { x = L.REC_MARK_X, w = L.REC_MARK_W },
        title = { x = titleX, w = titleW },
        skill = { x = skillX, w = L.REC_SKILL_W },
        src   = { x = srcX,   w = srcW },
    }
end

-- PURE. The recipe list's header row: label + the EXACT x/width of the column
-- it captions, derived FROM RecipeColumns (never positioned independently —
-- the lesson the grid's header already carries). SKILL right-justifies because
-- the skill numerals under it do.
function ProfUI.RecipeHeaderCells(availW)
    local c = ProfUI.RecipeColumns(availW)
    return {
        { label = "RECIPE", x = c.title.x, w = c.title.w, justify = "LEFT"  },
        { label = "SKILL",  x = c.skill.x, w = c.skill.w, justify = "RIGHT" },
        { label = "SOURCE", x = c.src.x,   w = c.src.w,   justify = "LEFT"  },
    }
end

-- PURE. What the header band costs the recipe LIST, top to bottom: the band
-- (HEAD_H) plus its 2px gap — exactly one LIST_ROW_H, and the self-test pins
-- it never quietly grows past one row. The view and the pin read this same
-- number (the grid's GridListTopInset idiom).
function ProfUI.RecipeListHeaderHeight()
    return L.HEAD_H + 2
end

-- PURE. The acquisition FontString's fixed height: its whole ACQ_LINES budget.
-- The view sets this as the FontString's real height (TOP-justified, wrapping),
-- so a wrapped second line can never spill past the info band, and the
-- self-test reads the SAME number — the view and the pin cannot drift.
function ProfUI.AcqTextHeight()
    return L.ACQ_LINES * L.ACQ_LINE_H
end

-- PURE. The grid pane's vertical furniture, top to bottom: the chip bar
-- (CHIP_H, the filter row), the column-header band under it, the character
-- rows under that. Two readers so the view and the self-test share one
-- arithmetic — the chip bar's cost to the list is these numbers, nowhere else.
function ProfUI.GridHeaderTopInset()
    return L.CHIP_H + L.PANEL_PAD
end
function ProfUI.GridListTopInset()
    return L.CHIP_H + L.PANEL_PAD + L.HEAD_H + 2
end

-- PURE. The detail pane's profession-tab strip: n tabs in availW. Tabs share
-- the width evenly, cap at DTAB_MAX (so two tabs hug the left rather than
-- stretching), and the last tab's right edge stays inside availW.
function ProfUI.DetailTabLayout(availW, n)
    availW = tonumber(availW) or 0
    n = tonumber(n) or 0
    if n <= 0 or availW <= 0 then return { w = 0, xs = {} } end
    local gaps = (n - 1) * L.DTAB_GAP
    local w = math.floor((availW - gaps) / n)
    if w > L.DTAB_MAX then w = L.DTAB_MAX end
    if w < 1 then w = 1 end
    local xs = {}
    for i = 1, n do xs[i] = (i - 1) * (w + L.DTAB_GAP) end
    return { w = w, xs = xs }
end

----------------------------------------------------------------------
-- THE GLYPH REGISTRY  (the tofu lesson, 2026-08-10)
--
-- The suite font is whatever face the owner picked in Daseeki-Core — the
-- fresh-install default is the vendored FiraSansCondensed-Medium.ttf, and
-- EVERY font role follows the picked face (theme.lua retired the hardcoded
-- ARIALN roles). A glyph the face does not carry renders as a TOFU BOX wearing
-- whatever ink the surrounding text was given, which is how the spec marker
-- became a "mystery green square" in the owner's screenshots.
--
-- So: every non-ASCII marker this file prints lives HERE, and each entry is a
-- glyph PROVEN to render — proven means its codepoint is present in the
-- vendored face's cmap table (checked directly against the TTF) AND/OR it is
-- already rendering in shipped suite text:
--
--   spec   U+25CA LOZENGE          in the vendored cmap; the diamond shape the
--                                  tooltip's "Specialisation:" line explains.
--                                  (U+25C6 BLACK DIAMOND is NOT in the face —
--                                  that was the green square.)
--   known  U+25CF BLACK CIRCLE     in the vendored cmap; already shipped by
--                                  options.lua's mesh list ("\226\151\143 Online").
--                                  (U+2713 CHECK MARK is NOT in the face —
--                                  the recipe list's green box.)
--   dash   U+2014 EM DASH          rendering across the whole suite (the very
--                                  "— not checked" the owner could read).
--   dots   U+2026 ELLIPSIS         shipped in Bags/Nexus status lines.
--   middot U+00B7 MIDDLE DOT       the suite separator, everywhere.
--   range  U+2013 EN DASH          world-drop level ranges.
--   times  U+00D7 MULTIPLICATION   shipped as the suite's close-button "x".
--
-- (A texture is the other honest option — Dashboard.MakeDiamond draws a
-- token-tinted diamond pip — but a text marker rides the FontString it
-- annotates for free, so the in-cmap lozenge wins.)
--
-- BANNED_GLYPHS is the other half: sequences that have ALREADY shipped as tofu
-- once. The self-test fails if any of them reappears — in the registry, in any
-- pure-layer output it can reach, and (under the harness, where io exists) as
-- raw bytes or decimal escapes anywhere in this file's source.
----------------------------------------------------------------------

ProfUI.GLYPHS = {
    spec   = "\226\151\138",   -- U+25CA lozenge (the spec marker)
    known  = "\226\151\143",   -- U+25CF black circle (recipe known / cd ready)
    dash   = "\226\128\148",   -- U+2014 em dash
    dots   = "\226\128\166",   -- U+2026 ellipsis
    middot = "\194\183",       -- U+00B7 middle dot
    range  = "\226\128\147",   -- U+2013 en dash
    times  = "\195\151",       -- U+00D7 multiplication sign
    absent = "--",             -- ASCII: the never-learned secondary cell
}

-- Codepoints that shipped as tofu boxes once. Stored as BYTE TRIPLES so the
-- banned sequences themselves never appear in this file in either matchable
-- form (raw UTF-8 or decimal escapes) — the self-test builds both forms at
-- runtime and scans for them.
ProfUI.BANNED_GLYPH_BYTES = {
    { name = "U+25C6 black diamond (the mystery green square)", 226, 151, 134 },
    { name = "U+2713 check mark (the known-row green box)",     226, 156, 147 },
}

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

-- The GRID's secondary columns are a strict SUBSET: the owner removed the
-- Poisons column outright (rework pass, 2026-08-10). Poisons remains a
-- CLASSIFIED secondary — it still costs no primary slot, still travels on the
-- payload, and still gets a tab in the detail pane for the character that
-- holds it (the rogue) — it just buys no grid width for the seven characters
-- that never will.
ProfUI.GRID_SECONDARIES = { "cooking", "firstaid", "fishing" }

-- Full names, per the owner's header pass — the columns are wide enough that
-- abbreviating them ("COOK", "AID") was pure information loss. Uppercase
-- because the grid's header band is an eyebrow row (CHARACTER, PRIMARY, …).
ProfUI.SECONDARY_LABEL = {
    cooking = "COOKING", firstaid = "FIRST AID", fishing = "FISHING",
}
ProfUI.SECONDARY = {}
for _, k in ipairs(ProfUI.SECONDARY_ORDER) do ProfUI.SECONDARY[k] = true end

function ProfUI.IsSecondary(profKey) return ProfUI.SECONDARY[profKey] and true or false end

-- PURE. The grid's header row, in column order. The self-test pins this list —
-- including the ABSENCE of POISONS.
function ProfUI.GridHeaderLabels()
    local out = { "CHARACTER" }
    for _ = 1, L.PRIMARIES do out[#out + 1] = "PRIMARY" end
    for _, key in ipairs(ProfUI.GRID_SECONDARIES) do
        out[#out + 1] = ProfUI.SECONDARY_LABEL[key] or tostring(key):upper()
    end
    return out
end

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
    -- The recipe-tooltip session record: which render mode won, and whether
    -- the enchant hyperlink was proven to work/fail on this client. A module
    -- toggle is a clean re-learn point (same rule as every cache here).
    ProfUI._tipStats = { enchant = 0, item = 0, facts = 0 }
    ProfUI._tipEnchantWorks = nil
    if ProfUI._clearSourceMemo then ProfUI._clearSourceMemo() end
    if ProfUI._resetWatchState then ProfUI._resetWatchState() end
end
ProfUI._tipStats = { enchant = 0, item = 0, facts = 0 }
ProfUI._tipEnchantWorks = nil    -- nil = untested this session; true/false = proven

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

-- A profession you can OPEN. The owner's rule ("Fishing doesnt need a tab",
-- "skinnign is not something that can be opened") made DATA-DRIVEN: a
-- profession with ZERO recipes in the dataset has no craft window, no recipe
-- census, nothing to browse and nothing to scan — the catalogue's own count is
-- the gate, never a hardcoded name list. In the shipped dataset that is
-- fishing, herbalism and skinning (mining keeps its 12 Smelting recipes, so
-- mining keeps its tab). The two refusals fail OPEN on purpose: an unloadable
-- dataset or an unknown key cannot prove "nothing to browse", and hiding a tab
-- on a guess would be the silent-drop lie.
function ProfUI.HasBrowsableRecipes(profKey)
    local D = core()
    if not D then return true end
    local idx = D.profIdx and D.profIdx[profKey]
    if not idx then return true end
    return #((D.profRecipes and D.profRecipes[idx]) or {}) > 0
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

-- PURE. The level display, owner's rule: ONLY the current level ("300", never
-- "300/300" — the cap is a constant of the Era, printing it per cell was noise),
-- inked "ok" (green) at the absolute Era skill cap, "warn" (yellow) anywhere
-- below it, "faint" behind an em dash when the level was never recorded. The
-- character's own per-rank cap (p.m) still travels on the model and still
-- speaks in the tooltip; it just no longer costs grid width.
ProfUI.ERA_CAP = 300
function ProfUI.LevelInk(level)
    local n = tonumber(level)
    if not n then return ProfUI.GLYPHS.dash, "faint" end
    if n >= ProfUI.ERA_CAP then return tostring(n), "ok" end
    return tostring(n), "warn"
end

-- PURE. The census half of a grid cell's bottom line — text, ink, or NIL for
-- "render nothing". Nil is the whole point for a ZERO-RECIPE profession
-- (fishing, herbalism, skinning): there is no window to open and no census to
-- take, so neither "— not checked" nor a known/total count may ever appear —
-- the level alone is the whole truth (owner's rule, 2026-08-10).
function ProfUI.CensusText(model)
    if type(model) ~= "table" then return nil end
    if (tonumber(model.total) or 0) == 0 then return nil end
    if model.scanned then
        return tostring(model.known or 0) .. "/" .. tostring(model.total), "muted"
    end
    return ProfUI.GLYPHS.dash .. " not checked", "faint"
end

-- PURE. One SECONDARY chip's text + ink. A character who never learned the
-- profession renders the ASCII "--" placeholder in the faint ink (the
-- never-recorded family) — a quiet "nothing here", never an empty cell that
-- reads as "not painted yet". A learned profession is the level, as ever.
function ProfUI.SecondaryCellText(model)
    if type(model) ~= "table" then return ProfUI.GLYPHS.absent, "faint" end
    return ProfUI.LevelInk(model.level)
end

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
        -- The census denominator honours the spec rule (owner, 2026-08-10):
        -- an Armorsmith's total is "recipes obtainable as an Armorsmith" —
        -- spec-conflicted recipes are censused out. Equals RecipeCount for a
        -- character with no spec chosen.
        total     = ProfUI.ObtainableTotal(payload, profKey),
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
-- THE GRID FILTER CHIPS  (PURE — the owner's "same filters, minus summoners",
-- 2026-08-10)
--
-- The characters view's chip trio (60s | Online | Summoners) plus the faction
-- A|H pair, brought to the professions grid with the SUMMONERS chip deliberately
-- absent: Summoners exists to find the low-level warlocks you summon WITH,
-- which is a world-buff-roster question, not a professions one. The faction
-- pair needs no model here at all — it is the SAME global Dashboard faction
-- switch the cards use (ProfUI.Roster() already gathers by it), re-surfaced as
-- chips on this tab.
--
-- SEMANTICS (each one deliberate):
--   * The chips filter THE GRID ROWS ONLY. The cooldown pane keeps reading the
--     whole roster — a hidden-but-ready alt still matters, which is the pane's
--     reason to exist — matching the cards' precedent, where the filter scopes
--     the card list and no sibling panel. The who-can-craft search is likewise
--     untouched (it answers about the account, not about the visible rows).
--   * FILTERED IS NOT DESELECTED. A selected character the chip hides stays
--     selected — the detail pane says so and waits — and re-admitting them
--     (clearing the chip, or their coming online) restores the detail pane
--     without a click. Auto-selecting someone else would silently answer a
--     question about the wrong character.
--   * The transition is the cards' exclusive toggle: zero-or-one chip active,
--     clicking the active chip clears it, none active means everyone shows.
--
-- Where ns.Cards is loaded (always, in the real client and the harness) the
-- predicates DELEGATE to Cards.FilterMatch/NextFilter, so the two tabs cannot
-- drift; the local fallback exists for a headless load order without cards and
-- restates the same two rules. The self-test pins delegate == fallback.
----------------------------------------------------------------------

ProfUI.GRID_FILTER_DEFS = {
    { key = "60s",    label = "60s",    tip = "Level 60 characters." },
    { key = "online", label = "Online", tip = "Currently online." },
    -- NO summoners entry, per the owner's "minus summoners".
}

-- PURE. filter key -> its chip label (nil for an unknown key).
function ProfUI.GridFilterLabel(filter)
    for _, def in ipairs(ProfUI.GRID_FILTER_DEFS) do
        if def.key == filter then return def.label end
    end
    return nil
end

-- PURE. Heal a persisted value: only a key with a real chip may come back from
-- SavedVariables ("" is the none-sentinel, and a key whose chip is gone — or
-- was never offered here, like "summoners" — must not filter invisibly).
function ProfUI.ValidGridFilter(v)
    for _, def in ipairs(ProfUI.GRID_FILTER_DEFS) do
        if def.key == v then return v end
    end
    return nil
end

-- PURE. Does `entry` pass the (single, exclusive) active filter?
function ProfUI.GridFilterMatch(entry, filter)
    if not filter then return true end
    local Cards = ns.Cards
    if Cards and Cards.FilterMatch then
        return Cards.FilterMatch(entry, filter) and true or false
    end
    if filter == "online" then return (entry and entry.online) and true or false end
    if filter == "60s" then
        return ((entry and entry.rec and entry.rec.level) or 0) >= 60
    end
    return true
end

-- PURE. The visible grid roster: `entries` arrive already in card order
-- (ProfUI.Roster sorts), and filtering preserves that order.
function ProfUI.FilterEntries(entries, filter)
    local out = {}
    for i = 1, #(entries or {}) do
        if ProfUI.GridFilterMatch(entries[i], filter) then out[#out + 1] = entries[i] end
    end
    return out
end

-- PURE. The cards' exclusive-toggle transition, restated (and pinned equal to
-- Cards.NextFilter): clicking the ACTIVE chip clears (nil = everyone), clicking
-- another selects it exclusively.
function ProfUI.NextGridFilter(current, clicked)
    if current == clicked then return nil end
    return clicked
end

-- PURE. TRUE only when the selected owner IS in the roster and the active chip
-- hides them — the one case where the detail pane must say "hidden, kept"
-- instead of rendering. An owner absent from the roster altogether (faction
-- switch, deleted record) is NOT this case; those keep their existing empty
-- states.
function ProfUI.SelectionHiddenByFilter(entries, filter, owner)
    if not (owner and filter) then return false end
    for i = 1, #(entries or {}) do
        local e = entries[i]
        if e and e.nameRealm == owner then
            return not ProfUI.GridFilterMatch(e, filter)
        end
    end
    return false
end

-- PURE. The detail pane's line for a hidden-but-kept selection. nil when no
-- chip is active (there is nothing to explain).
function ProfUI.HiddenSelectionHint(shortName, filter)
    if not filter then return nil end
    local label = ProfUI.GridFilterLabel(filter) or tostring(filter)
    return tostring(shortName or "?") .. " is hidden by the " .. label
        .. " filter \226\128\148 selection kept; clear the filter to see them again."
end

-- PURE. The grid's empty-state line: with a chip active the ABSENCE has a
-- cause, and the hint names it (and the way out) instead of claiming nothing
-- was ever recorded.
function ProfUI.GridEmptyText(filter)
    if not filter then
        return "No professions recorded yet \226\128\148 open a profession window on any character."
    end
    local label = ProfUI.GridFilterLabel(filter) or tostring(filter)
    return "No characters match the " .. label
        .. " filter \226\128\148 click it again to show everyone."
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
-- THE COOLDOWN KINDS  (PURE — the rework's bottom-right pane)
--
-- One row per cooldown KIND the store has seen — a kind is a cdKey, which P1
-- already made account-stable (a teaching spell id, or "gN" for a shared
-- group), so the kinds are ENUMERATED from the payloads rather than hardcoded:
-- whatever the module tracks is what renders. Each kind carries the roster
-- characters currently OFF cooldown (ready to craft), in roster order and
-- wearing their class tags. The owner's rule is explicit: a character
-- mid-cooldown is not listed at all, and a kind no character owns is not a
-- row. (RollupRows stays alive underneath — the badge and the login line
-- still count per-INSTANCE, which is the number they always meant.)
----------------------------------------------------------------------

function ProfUI.CooldownKindRows(entries, lookup, nowE, res)
    local kinds, order = {}, {}
    nowE = nowE or now()
    for i = 1, #(entries or {}) do
        local e = entries[i]
        local payload = lookup and lookup(e.nameRealm) or nil
        if type(payload) == "table" and type(payload.c) == "table" then
            for cdKey, at in pairs(payload.c) do
                local key = tostring(cdKey)
                local k = kinds[key]
                if not k then
                    local profKey = ProfUI.CdKeyMeta(key)
                    local label, pending = ProfUI.CooldownLabel(key, res)
                    k = { cdKey = key, profKey = profKey, label = label,
                          pending = pending and true or false,
                          owners = 0, ready = {} }
                    kinds[key] = k
                    order[#order + 1] = k
                end
                k.owners = k.owners + 1
                local rem = ProfUI.CooldownRemaining(at, nowE)
                if rem == 0 then
                    k.ready[#k.ready + 1] = { key = e.nameRealm,
                                              classTag = e.rec and e.rec.classTag or nil }
                end
            end
        end
    end
    -- Strict total order (class 8): label first so the pane reads
    -- alphabetically, cdKey as the tiebreak so a pending label cannot make two
    -- renders disagree.
    table.sort(order, function(a, b)
        local la, lb = a.label or "", b.label or ""
        if la ~= lb then return la < lb end
        return a.cdKey < b.cdKey
    end)
    return order
end

-- PURE apart from the dataset read. The detail pane's tab list for one
-- character: every profession the payload proves they hold AND that has
-- recipes to browse, primaries first then secondaries, each block sorted —
-- the same order ProfessionList renders, reduced to keys. A rogue's poisons
-- rides in payload.p and therefore gets its tab; a character without it
-- cannot, because the probe never invents a profession. A ZERO-RECIPE
-- profession (fishing, herbalism, skinning — by dataset count, see
-- HasBrowsableRecipes) gets NO tab: there is no window behind it and nothing a
-- tab could show. It stays in the grid, the payload and the mesh — level
-- tracking is the part the owner wants — it just cannot be "opened" here any
-- more than it can in the game.
function ProfUI.DetailTabs(payload)
    local out = {}
    local list = ProfUI.ProfessionList(payload)
    for i = 1, #list do
        local key = list[i].key
        if ProfUI.HasBrowsableRecipes(key) then out[#out + 1] = key end
    end
    return out
end

-- PURE. Which tab actually shows: the remembered one if it is still eligible,
-- else the character's FIRST eligible profession. This is the same fallback
-- that already caught "remembered tab the character no longer holds"; the
-- zero-recipe exclusion routes through it too, so a session that left
-- Skinning selected lands on the first real tab instead of a blank pane.
function ProfUI.ResolveDetailTab(tabs, want)
    for i = 1, #(tabs or {}) do
        if tabs[i] == want then return want end
    end
    return tabs and tabs[1] or nil
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

-- The zone an NPC stands in, alone — nil when the indices cannot say.
local function npcZone(D, id)
    local npc = D.npc and D.npc[id]
    local zone = npc and npc.zone and D.zone and D.zone[npc.zone]
    return zone and zone.name or nil
end

local function plusMore(n)
    if n > 1 then return " +" .. (n - 1) .. " more" end
    return ""
end

-- PURE over the dataset. The vendor half of an acquisition line, WITH ZONES
-- (owner's directive, 2026-08-10): "Sold by Dan Golthas \226\128\148 Badlands",
-- up to VENDOR_NAMES of them comma-joined, then the current idiom's "+N more"
-- for the rest. An NPC the indices cannot place keeps its name alone rather
-- than inventing a zone; an NPC the indices do not carry at all reads "?".
ProfUI.VENDOR_NAMES = 2
function ProfUI.VendorPhrase(D, npcList)
    local ids = {}
    for id in tostring(npcList or ""):gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
    if #ids == 0 then return "Sold by ?" end
    local named = {}
    for i = 1, math.min(#ids, ProfUI.VENDOR_NAMES) do
        local npc = D.npc and D.npc[ids[i]]
        local part = npc and npc.name or "?"
        local zone = npcZone(D, ids[i])
        if zone then part = part .. " " .. ProfUI.GLYPHS.dash .. " " .. zone end
        named[#named + 1] = part
    end
    local tail = ""
    if #ids > ProfUI.VENDOR_NAMES then
        tail = " +" .. (#ids - ProfUI.VENDOR_NAMES) .. " more"
    end
    return "Sold by " .. table.concat(named, ", ") .. tail
end

-- PURE over the dataset. A quest acquisition WITH ITS ZONE:
-- "Quest: Goretusk Liver Pie \226\128\148 Westfall". The [quest] rows carry no
-- zone of their own — the zone is where the quest GIVER stands, via the same
-- npc -> zone link the vendors use — so a giver-less quest (the dataset holds
-- seven) keeps its bare name rather than guessing.
function ProfUI.QuestPhrase(D, questID)
    local q = D.quest and D.quest[questID]
    if not q then return "Quest: ?" end
    local text = "Quest: " .. (q.name or "?")
    local zone = npcZone(D, firstNumber(q.givers))
    if zone then text = text .. " " .. ProfUI.GLYPHS.dash .. " " .. zone end
    return text
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
                local m = money(tonumber(cost))
                parts[#parts + 1] = ProfUI.VendorPhrase(D, npcs)
                    .. (m and (" \194\183 " .. m) or "")
            elseif head == "D" then
                local npcs = tok:sub(2)
                parts[#parts + 1] = "Drops from " .. (npcWhere(D, firstNumber(npcs)) or "?")
                    .. plusMore(countNumbers(npcs))
            elseif head == "W" then
                local lo, hi = tok:match("^W(%d+)%-(%d+)$")
                parts[#parts + 1] = "World drop (mobs " .. tostring(lo) .. "\226\128\147" .. tostring(hi) .. ")"
            elseif head == "Q" then
                parts[#parts + 1] = ProfUI.QuestPhrase(D, firstNumber(tok:sub(2)))
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
    local teachItem = nil    -- the FIRST teaching item (I/K route) — the recipe
                             -- tooltip's item-hyperlink fallback reads it

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
                if itemID and not teachItem then teachItem = itemID end
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
                lines[#lines + 1] = ProfUI.QuestPhrase(D, firstNumber(tok:sub(2)))
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
                    teachItem = teachItem,
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
-- THE SPEC RULE — one predicate, all consumers (owner, 2026-08-10: "we
-- shouldnt display recipes as missing if they are for a different
-- specialization than selected", his screenshot the Gnomish Engineer whose
-- missing list red-flagged a Goblin-only Dimensional Ripper).
--
-- The dataset speaks in spec ORDINALS (rec.spec -> D.specs[idx] = { id =
-- <spec spell id>, p = <profession idx>, name }), the payload in held spec
-- SPELL IDS (p.s). The standing of one recipe against one character:
--
--   "ok"        no spec requirement, or the character HOLDS the required spec
--   "openable"  a spec is required and the character holds NO spec in that
--               profession's family — nothing is conflicted yet, they could
--               still choose it (the owner's rule 3: unchanged behavior)
--   "conflict"  the character holds a DIFFERENT spec of the same family —
--               "a different specialization than selected", the owner's exact
--               case. (With no spec-hierarchy data in the dataset, holding
--               ANY other family spec reads as "selected something else",
--               which is also the literal directive.)
--
-- An unknown spec ordinal fails OPEN ("ok"): hiding a recipe on a guess would
-- be the silent-drop lie. The learnable computation (SearchRows) and the
-- recipe-list classification (RecipeRows) both read THIS function — the
-- self-test pins that they cannot drift into two spec rules.
----------------------------------------------------------------------

function ProfUI.SpecStanding(D, rec, heldSpecs)
    local specIdx = rec and tonumber(rec.spec)
    if not specIdx or specIdx == 0 then return "ok" end
    local sp = D and D.specs and D.specs[specIdx]
    if not sp then return "ok" end
    if type(heldSpecs) == "table" then
        for j = 1, #heldSpecs do
            if heldSpecs[j] == sp.id then return "ok" end
        end
        for j = 1, #heldSpecs do
            local hIdx = D.specById and D.specById[heldSpecs[j]]
            local hs = hIdx and D.specs[hIdx]
            if hs and hs.p == sp.p then return "conflict" end
        end
    end
    return "openable"
end

-- The census DENOMINATOR for one character's profession: the dataset recipes
-- MINUS the spec-conflicted ones (an Armorsmith's total is "recipes obtainable
-- as an Armorsmith"), except that a recipe the character provably KNOWS always
-- counts — a known recipe can never be censused out from under its own
-- numerator. With no payload (or no spec chosen) this equals RecipeCount.
-- View-layer classification only: the capture, the payload and the wire are
-- untouched. (Unmemoised on purpose — the same render path already decodes
-- the known bitmap per cell, and this walk is the same order of cheap.)
function ProfUI.ObtainableTotal(payload, profKey)
    local D = core()
    if not D then return 0 end
    local idx = D.profIdx and D.profIdx[profKey]
    if not idx then return 0 end
    local list = (D.profRecipes and D.profRecipes[idx]) or {}
    local p = type(payload) == "table" and payload.p and payload.p[profKey] or nil
    local held = p and p.s or nil
    local known = ProfUI.KnownSet(payload, profKey)
    local n = 0
    for i = 1, #list do
        local spell = list[i]
        if (known and known[spell])
            or ProfUI.SpecStanding(D, D.recipe[spell], held) ~= "conflict" then
            n = n + 1
        end
    end
    return n
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

    -- The character's held specs for this profession travel on the payload
    -- whether or not the window was ever scanned; the spec rule reads them.
    local held = type(payload) == "table" and payload.p and payload.p[profKey]
        and payload.p[profKey].s or nil

    for i = 1, #list do
        local spell = list[i]
        local rec = D.recipe[spell]
        local rowState = unscanned and "unknown" or (known[spell] and "known" or "missing")

        -- THE SPEC RULE (the shared predicate — see SpecStanding): a recipe
        -- locked behind a spec this character did NOT choose is not "missing",
        -- it is unavailable-with-a-reason. A KNOWN recipe is never reclassified
        -- (knowing it outranks any inference about specs).
        local specConflict = (rowState ~= "known")
            and ProfUI.SpecStanding(D, rec, held) == "conflict" or false

        local keep = true
        -- "Missing only" must agree with the owner's rule: a spec-conflicted
        -- recipe is not missing, so it never rides that filter — not even with
        -- Show unavailable ticked.
        if opts.missingOnly and (rowState ~= "missing" or specConflict) then keep = false end

        -- Memoised (see SourceModel): a game fact looked up once per session.
        local src = keep and ProfUI.SourceModel(spell) or nil
        if keep and opts.source then
            if not (src and src.classes and src.classes[opts.source]) then keep = false end
        end
        -- A spec conflict wears the SPEC as its visible reason (the owner's
        -- screenshot: "Goblin Engineer" is the fact that explains the row);
        -- otherwise the source graph's own unavailability candidate stands.
        local unavailable = nil
        if specConflict then
            unavailable = { key = "spec",
                text = "requires " .. (ProfUI.SpecName(rec and rec.spec)
                                       or "another specialisation") }
        else
            unavailable = src and src.unavailable or nil
        end
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
                    unavailable = unavailable,
                    specConflict = specConflict or nil,
                    item    = src and src.teachItem or nil,   -- teaching item, for the tooltip fallback
                }
            end
        end
    end
    table.sort(pending)
    return rows, pending, unscanned and "unscanned" or "scanned"
end

----------------------------------------------------------------------
-- THE SHOPPING LIST  (owner, 2026-08-10: "similar to how we built a way to
-- generate a shopping list for all missing consumes with Raid Prep, can we do
-- the same thing with missing recipes via professions? should only be recipes
-- that are actually tradable via the AH.")
--
-- Raid Prep's shopping list is a ONE-CLICK VERB, not a window: the checklist's
-- gavel collects what you are short on and hands the names to Auctionator's
-- Shopping tab (MultiSearchExact), with branded chat prints carrying the edge
-- cases. This is the same verb scoped to ONE character's ONE profession: the
-- chat list is the render (item links in chat are shift-clickable into the AH
-- search box), and with Auctionator loaded at an open auction house the names
-- land in the Shopping tab exactly as the gavel's do.
--
-- WHAT QUALIFIES ("actually tradable via the AH" made mechanical):
--   1. The recipe is MISSING for that character — through RecipeRows'
--      missingOnly seam, so the spec rule (SpecStanding, the shared predicate)
--      and the unavailable classification apply unchanged: a spec-conflicted
--      or genuinely-unobtainable recipe can never ride this list, and an
--      unscanned profession produces NO list (the third state, not zero).
--   2. Its teaching source is an ITEM — the dataset's I/K acquisition
--      relation. Trainer-taught-only and quest-taught-only recipes have no
--      teaching item and are excluded by that fact.
--   3. The teaching ITEM can reach the open world: its own acquisition facts
--      carry a vendor / mob-drop / world-drop / world-object route. An item
--      whose only route is a quest reward cannot be posted by anyone; an
--      event-gated or source-less item mirrors itemRoute's own blocked
--      classification. All exclusions are sourced from the dataset's
--      acquisition facts, never guessed.
--   4. The item is BoE or unbound, read LIVE from the client. Item data is
--      ASYNC (CLIENT_ASYNC_LESSONS class 4): a cold item's bind is UNKNOWN,
--      so the row renders in a distinct UNRESOLVED state — never silently
--      included as tradable, never silently dropped — one warm load is
--      requested, and re-running the list is the retry.
--
-- Vendor-sold teaching items ARE included (someone can flip them onto the AH)
-- but wear their vendor + zone tag, so the owner can see when the AH is the
-- expensive path for that recipe.
----------------------------------------------------------------------

-- PURE. Is this bindType an AH-postable bind? true = BoE or no bind; false =
-- provably bound (pickup/use/quest); nil = NOT A NUMBER, which is either a
-- cold read or a client whose GetItemInfo signature drifted — both are "we do
-- not know", and unknown may never masquerade as either verdict. The 0/2
-- literals are Enum.ItemBind's None/OnEquip; the live Enum wins where the
-- client carries one (the catalog is names-only, so positions and values are
-- never trusted blind — see LiveItemInfo).
function ProfUI.BindTradable(bind)
    if type(bind) ~= "number" then return nil end
    local E = _G.Enum and _G.Enum.ItemBind or nil
    local none    = (E and type(E.None) == "number") and E.None or 0
    local onEquip = (E and type(E.OnEquip) == "number") and E.OnEquip or 2
    return (bind == none or bind == onEquip)
end

-- The live item-info reader, resolver-shaped so the harness can inject a fake
-- (the cold/bind sim idiom): reader(itemID) -> { name, link, bind } or nil
-- meaning "the client has not answered" (class 4: cold, not empty). Every
-- return position is TYPE-CHECKED, never trusted: bindType is the 14th return
-- of GetItemInfo on this client family (verified against the API catalog's
-- C_Item.GetItemInfo signature), but if that slot is not a number the reader
-- reports bind = nil and the row lands in the unresolved state rather than a
-- confident wrong verdict.
function ProfUI.LiveItemInfo()
    return function(id)
        if not id then return nil end
        local r = nil
        if C_Item and C_Item.GetItemInfo then
            local t = { pcall(C_Item.GetItemInfo, id) }
            if t[1] and type(t[2]) == "string" and t[2] ~= "" then r = t end
        end
        if not r and GetItemInfo then
            local t = { pcall(GetItemInfo, id) }
            if t[1] and type(t[2]) == "string" and t[2] ~= "" then r = t end
        end
        if not r then return nil end                       -- cold: no answer yet
        local link = (type(r[3]) == "string" and r[3]:find("|H", 1, true)) and r[3] or nil
        local bind = (type(r[15]) == "number") and r[15] or nil   -- 14th return, +1 for pcall's ok
        return { name = r[2], link = link, bind = bind }
    end
end

-- PURE over the dataset. Can this teaching ITEM reach the open world, and how
-- would a row describe that? Walks the item's own acquisition tokens (the same
-- grammar itemRoute reads) into:
--   { reachable = bool,           -- a vendor / drop / world-drop / object route exists
--     vendor    = phrase|nil,     -- "Sold by X — Zone · cost" when vendor-sold
--     tag       = string|nil }    -- the row's source tag (vendor first, then
--                                 -- World drop, mob drop, world object)
-- Quest tokens are NOT routes (a quest reward cannot be posted); E/X tokens
-- (and the generator's e/x candidate flags) mirror itemRoute's blocked
-- classification, so an event-gated or source-less item is not reachable.
function ProfUI.ItemTradeRoutes(D, itemID)
    local out = { reachable = false, vendor = nil, tag = nil }
    local acq = D and D.itemAcq and D.itemAcq[itemID]
    local item = D and D.item and D.item[itemID]
    local flags = (item and item.flags) or "-"
    if type(acq) ~= "string" or acq == "" then return out end
    local vendorTag, dropTag, worldTag, objectTag, blocked = nil, nil, nil, nil, false
    for tok in (acq .. ";"):gmatch("(.-);") do
        if tok ~= "" then
            local head = tok:sub(1, 1)
            if head == "V" then
                local cost, npcs = tok:match("^V(%d+)@([%d%+]+)$")
                local m = money(tonumber(cost))
                vendorTag = ProfUI.VendorPhrase(D, npcs) .. (m and (" \194\183 " .. m) or "")
            elseif head == "D" then
                local npcs = tok:sub(2)
                dropTag = "Drops from " .. (npcWhere(D, firstNumber(npcs)) or "?")
                    .. plusMore(countNumbers(npcs))
            elseif head == "W" then
                worldTag = "World drop"
            elseif head == "O" then
                local o = D.object and D.object[firstNumber(tok:sub(2))]
                objectTag = "World object: " .. ((o and o.name) or "?")
            elseif head == "E" or head == "X" then
                blocked = true
            end
            -- Q is not a route to the AH; R/S are riders, not routes.
        end
    end
    if blocked or flags:find("e", 1, true) or flags:find("x", 1, true) then return out end
    out.vendor = vendorTag
    out.tag = vendorTag or worldTag or dropTag or objectTag
    out.reachable = (out.tag ~= nil)
    return out
end

-- PURE apart from the injected reader. One recipe's AH-tradability verdict:
--   { state = "tradable",   item, name, link, tag, vendor }  -- buy this
--   { state = "unresolved", item, tag, vendor }              -- bind unknown (cold)
--   { state = "excluded",   reason = "no-item"|"unreachable"|"bound" }
-- The FIRST teaching item that proves tradable wins; a cold/type-drifted read
-- on a reachable item is held as an unresolved CANDIDATE (never a verdict)
-- unless a later item settles it.
function ProfUI.ShopTradability(D, spellID, iteminfo)
    local sawItem, sawBound, unresolved = false, false, nil
    local acq = D and D.acq and D.acq[spellID]
    for tok in (tostring(acq or "") .. ";"):gmatch("(.-);") do
        local head = tok:sub(1, 1)
        if head == "I" or head == "K" then
            local itemID = tonumber(tok:sub(2))
            if itemID then
                sawItem = true
                local route = ProfUI.ItemTradeRoutes(D, itemID)
                if route.reachable then
                    local info = iteminfo and iteminfo(itemID) or nil
                    -- Class 5 (truthy-zero/false): `a and b or c` would collapse
                    -- a FALSE verdict into nil, scoring "provably bound" as
                    -- "unknown". Explicit branch, no fallback chain.
                    local ok = nil
                    if info then ok = ProfUI.BindTradable(info.bind) end
                    if info and ok == true then
                        return { state = "tradable", item = itemID, name = info.name,
                                 link = info.link, tag = route.tag,
                                 vendor = route.vendor and true or false }
                    elseif info and ok == false then
                        sawBound = true
                    else
                        -- Cold item, or a bind slot that failed the type check:
                        -- UNKNOWN, held (class 4) — never included, never dropped.
                        unresolved = unresolved or { item = itemID, tag = route.tag,
                                                     vendor = route.vendor and true or false }
                    end
                end
            end
        end
    end
    if unresolved then
        return { state = "unresolved", item = unresolved.item, tag = unresolved.tag,
                 vendor = unresolved.vendor }
    end
    local reason = "no-item"
    if sawBound then reason = "bound" elseif sawItem then reason = "unreachable" end
    return { state = "excluded", reason = reason }
end

-- The list itself. Base set = RecipeRows' missingOnly seam (spec rule +
-- unavailable classification ride along unchanged; unscanned professions
-- return NOTHING with state "unscanned"). Returns rows, pendingItems (cold
-- teaching-item ids, sorted — class 8: this feeds a bounded re-ask), state,
-- and the MISSING count before the tradability filter (the empty-state
-- message needs to tell "all known" from "nothing tradable").
-- Rows are sorted by skill requirement ASCENDING (the owner reads it as a
-- levelling path; Raid Prep's checklist order is user-authored so there was
-- no deliberate ordering to inherit), spell id as the deterministic tiebreak.
function ProfUI.ShoplistRows(payload, profKey, res, iteminfo)
    res = res or ProfUI.LiveResolver()
    iteminfo = iteminfo or ProfUI.LiveItemInfo()
    local base, _, state = ProfUI.RecipeRows(payload, profKey, { missingOnly = true }, res)
    local rows, pendingItems = {}, {}
    local D = sourcesDS()
    if not D then return rows, pendingItems, "nodata", #base end
    for i = 1, #base do
        local br = base[i]
        local v = ProfUI.ShopTradability(D, br.spell, iteminfo)
        if v.state == "tradable" then
            rows[#rows + 1] = { spell = br.spell, name = br.name, skill = br.skill,
                item = v.item, itemName = v.name, link = v.link,
                tag = v.tag, vendor = v.vendor, unresolved = false }
        elseif v.state == "unresolved" then
            rows[#rows + 1] = { spell = br.spell, name = br.name, skill = br.skill,
                item = v.item, tag = v.tag, vendor = v.vendor, unresolved = true }
            pendingItems[#pendingItems + 1] = v.item
        end
    end
    table.sort(rows, function(a, b)
        local sa, sb = tonumber(a.skill) or 0, tonumber(b.skill) or 0
        if sa ~= sb then return sa < sb end
        return a.spell < b.spell
    end)
    table.sort(pendingItems)
    return rows, pendingItems, state, #base
end

-- PURE. The chat render, as plain lines (ns:Print wears the brand tag). The
-- unresolved rows wear their state IN the line — a cold bind is a fact worth
-- printing, not a row to hide — and re-running the list is the retry.
function ProfUI.ShoplistLines(ownerKey, profKey, rows, state, missingN)
    local who = tostring(ownerKey or "?"):match("^([^%-]+)") or tostring(ownerKey or "?")
    local prof = ProfUI.ProfName(profKey)
    local out = {}
    if state == "nodata" then
        out[1] = "shopping list: the professions dataset is unavailable."
        return out
    end
    if state ~= "scanned" then
        out[1] = "Not checked yet \226\128\148 open " .. prof .. " on " .. who
            .. " once and run this again."
        return out
    end
    if #rows == 0 then
        if (missingN or 0) == 0 then
            out[1] = "Nothing to buy \226\128\148 " .. who .. " already knows every "
                .. prof .. " recipe they can obtain."
        else
            out[1] = "Nothing to buy \226\128\148 none of " .. who .. "'s "
                .. tostring(missingN) .. " missing " .. prof
                .. " recipe(s) is tradable on the AH."
        end
        return out
    end
    out[1] = "Shopping list \226\128\148 " .. who .. "'s " .. prof .. " ("
        .. #rows .. (#rows == 1 and " recipe" or " recipes") .. " buyable on the AH):"
    for i = 1, #rows do
        local r = rows[i]
        local label
        if r.unresolved then
            label = "item " .. tostring(r.item)
                .. "  [unresolved \226\128\148 item data still loading; run this again]"
        else
            label = r.link or r.itemName or ("item " .. tostring(r.item))
        end
        out[#out + 1] = "  " .. label
            .. " \226\128\148 skill " .. tostring(r.skill or "?")
            .. (r.tag and (" \226\128\148 " .. r.tag) or "")
    end
    return out
end

-- PURE. The Auctionator hand-off: resolved teaching-item NAMES only, deduped,
-- in list order. Unresolved rows never ride — an unproven bind may not be
-- shopped for as if it were proven.
function ProfUI.ShoplistSearchTerms(rows)
    local seen, out = {}, {}
    for i = 1, #(rows or {}) do
        local r = rows[i]
        if not r.unresolved and type(r.itemName) == "string" and r.itemName ~= ""
            and not seen[r.itemName] then
            seen[r.itemName] = true
            out[#out + 1] = r.itemName
        end
    end
    return out
end

-- PURE apart from core()/DetailTabs. Resolve `/nexus profs shoplist
-- [character] [profession]` against the roster. Both arguments optional:
-- the pane's selection is the default, then the player's own character; a
-- character with exactly one browsable profession needs no second argument.
-- Returns ownerKey, profKey or nil, nil, err.
function ProfUI.ShoplistTarget(rest, entries, lookup, defaults)
    defaults = defaults or {}
    entries = entries or {}
    rest = tostring(rest or ""):match("^%s*(.-)%s*$") or ""
    local t1, t2 = rest:match("^(%S*)%s*(%S*)")
    t1, t2 = t1 or "", t2 or ""

    local function findOwner(token)
        token = token:lower()
        for i = 1, #entries do
            local nr = entries[i].nameRealm or ""
            if nr:lower() == token
                or ((nr:match("^([^%-]+)") or nr):lower() == token) then
                return nr
            end
        end
        return nil
    end
    local function findProf(token)
        local D = core()
        if not D or token == "" then return nil end
        token = token:lower()
        local prefix = nil
        for i = 1, #(D.profs or {}) do
            local p = D.profs[i]
            local key = tostring(p.key or ""):lower()
            local nm  = tostring(p.name or ""):lower()
            if key == token or nm == token then return p.key end
            if key:find(token, 1, true) == 1 or nm:find(token, 1, true) == 1 then
                if prefix and prefix ~= p.key then prefix = false else prefix = p.key end
            end
        end
        return prefix or nil     -- false (ambiguous) collapses to nil
    end
    local function selfOwner()
        for i = 1, #entries do
            if entries[i].isSelf then return entries[i].nameRealm end
        end
        return nil
    end

    local owner, profKey = nil, nil
    if t1 == "" then
        owner = defaults.owner or selfOwner()
    else
        owner = findOwner(t1)
        if not owner then
            -- One argument that is not a character may be a profession.
            profKey = findProf(t1)
            if not profKey then
                return nil, nil, "no character (or profession) named '" .. t1 .. "'."
            end
            owner = defaults.owner or selfOwner()
        end
    end
    if not owner then
        return nil, nil, "select a character in the Professions tab, or name one: "
            .. "/nexus profs shoplist <character> [profession]"
    end
    if t2 ~= "" then
        profKey = findProf(t2)
        if not profKey then return nil, nil, "no profession named '" .. t2 .. "'." end
    end
    if not profKey then
        if defaults.owner == owner and defaults.prof then
            profKey = defaults.prof
        else
            local tabs = ProfUI.DetailTabs(lookup and lookup(owner) or nil)
            if #tabs == 1 then
                profKey = tabs[1]
            elseif #tabs == 0 then
                return nil, nil, "no browsable professions recorded for "
                    .. (tostring(owner):match("^([^%-]+)") or owner) .. " yet."
            else
                return nil, nil, "which profession? " .. table.concat(tabs, ", ")
            end
        end
    end
    return owner, profKey
end

----------------------------------------------------------------------
-- THE RECIPE ROW TOOLTIP  (owner, 2026-08-10: "recipes in the professions tab
-- show their tooltip when hovered over")
--
-- The tooltip a recipe row wants is the CRAFT tooltip — product + reagents,
-- what the profession window itself shows — which this client family renders
-- via GameTooltip:SetHyperlink("enchant:<teachingSpellID>"). That mechanism is
-- UNVERIFIED on 11509 (the same client returned nil recipe LINKS in the
-- profession window; link RETRIEVAL and hyperlink RENDERING are different
-- mechanisms, so neither outcome is assumed), so every attempt is defensive
-- and the chain falls through honestly:
--
--   1. enchant:<spellID>      the craft tooltip. A pcall error OR an empty
--                             render latches _tipEnchantWorks=false for the
--                             session — whichever mode wins first stays the
--                             mode, so hovers are consistent, and the latch is
--                             readable in /dnx professionsui.
--   2. item:<teachingItemID>  where the dataset carries a teaching item (the
--                             recipe scroll). This also picks up the suite's
--                             own Known/Learnable lines from tooltips.lua for
--                             free. CLASS 4 (cold reads): an item tooltip can
--                             render its TITLE synchronously with the body
--                             absent, so a render under two lines is treated
--                             as cold, a warm load is requested, and the chain
--                             falls through — cold is transient, so it NEVER
--                             latches; the re-hover is the retry (no ladder).
--   3. dataset facts          name / state / skill / source — the same strings
--                             the pane already renders. Cannot fail, so a
--                             hover can never leave a blank tooltip standing.
--
-- Everything here takes the TOOLTIP AS A PARAMETER (GameTooltip live, a
-- recording fake under the harness — the parity gate's idiom), so the whole
-- chain is exercised headless.
----------------------------------------------------------------------

-- PURE. The attempt chain for one row, honouring the session latch.
function ProfUI.RecipeTooltipPlan(row)
    local plan = {}
    if type(row) == "table" and row.spell and ProfUI._tipEnchantWorks ~= false then
        plan[#plan + 1] = { kind = "enchant", link = "enchant:" .. row.spell, minLines = 1 }
    end
    if type(row) == "table" and row.item then
        -- minLines = 2: a title-only item tooltip is the class-4 cold read,
        -- not an answer.
        plan[#plan + 1] = { kind = "item", link = "item:" .. row.item, minLines = 2 }
    end
    plan[#plan + 1] = { kind = "facts" }
    return plan
end

-- PURE. The dataset-facts tooltip, as { text, ink } lines — the same strings
-- the list row and info band already render, never an empty table.
function ProfUI.RecipeFactLines(row, res)
    row = type(row) == "table" and row or {}
    local out = {}
    local name = row.name
    if name == nil and res and res.spell and row.spell then name = res.spell(row.spell) end
    out[#out + 1] = { text = name or ("Recipe " .. tostring(row.spell or "?")), ink = "text" }
    if row.state == "known" then
        out[#out + 1] = { text = ProfUI.GLYPHS.known .. " Known", ink = "ok" }
    elseif row.state == "missing" then
        out[#out + 1] = { text = "Not known", ink = "muted" }
    elseif row.state == "unknown" then
        out[#out + 1] = { text = "Not checked", ink = "faint" }
    end
    if row.skill then
        out[#out + 1] = { text = "Requires skill " .. tostring(row.skill), ink = "muted" }
    end
    if row.source then
        out[#out + 1] = { text = row.source, ink = "muted" }
    end
    if row.unavailable and row.unavailable.text then
        out[#out + 1] = { text = "Unavailable \226\128\148 " .. row.unavailable.text, ink = "danger" }
    end
    return out
end

-- Drive the chain against `tip`. Returns the mode that rendered ("enchant" |
-- "item" | "facts") and records it in _tipStats. `ask` is injectable for the
-- harness; it defaults to the real warm-load request.
function ProfUI.RenderRecipeTooltip(tip, row, res, ask)
    ask = ask or function(kind, ids) return ProfUI.AskFor(kind, ids) end
    local plan = ProfUI.RecipeTooltipPlan(row)
    for i = 1, #plan do
        local step = plan[i]
        if step.kind == "facts" then
            local lines = ProfUI.RecipeFactLines(row, res)
            for j = 1, #lines do
                local ln = lines[j]
                if tip and tip.AddLine then
                    if UI and UI.Color then tip:AddLine(ln.text, UI.Color(ln.ink))
                    else tip:AddLine(ln.text) end
                end
            end
            ProfUI._tipStats.facts = ProfUI._tipStats.facts + 1
            return "facts"
        end
        local ok = false
        if tip and tip.SetHyperlink then
            ok = pcall(tip.SetHyperlink, tip, step.link)
        end
        local lines = 0
        if ok and tip.NumLines then
            local okN, n = pcall(tip.NumLines, tip)
            lines = (okN and tonumber(n)) or 0
        end
        if ok and lines >= step.minLines then
            if step.kind == "enchant" and ProfUI._tipEnchantWorks == nil then
                ProfUI._tipEnchantWorks = true
            end
            ProfUI._tipStats[step.kind] = ProfUI._tipStats[step.kind] + 1
            return step.kind
        end
        -- This step failed. An enchant failure is a fact about the CLIENT
        -- (latch, stay consistent all session); an item failure is a fact
        -- about a COLD CACHE (transient — request the warm load and let the
        -- re-hover be the retry).
        if step.kind == "enchant" then
            ProfUI._tipEnchantWorks = false
        elseif step.kind == "item" and row and row.item then
            ask("item", { row.item })
        end
        if tip and tip.ClearLines then pcall(tip.ClearLines, tip) end
    end
end

-- PURE. The pooled-cell lesson (Daseeki-Bags' bank tooltips): may a repaint
-- leave the standing tooltip up? Only if this row still shows the SAME recipe.
function ProfUI.TooltipStaleOnPaint(prevSpell, newSpell, ownedByRow)
    return (ownedByRow and prevSpell ~= newSpell) and true or false
end

-- The three row handlers, tooltip-injected. `rr` needs only ._row / ._spell,
-- so the harness drives these with plain tables.
function ProfUI.RowTooltipEnter(tip, rr, res)
    local row = rr and rr._row
    if not row then return nil end
    if tip and tip.SetOwner then tip:SetOwner(rr, "ANCHOR_RIGHT") end
    local mode = ProfUI.RenderRecipeTooltip(tip, row, res)
    if tip and tip.Show then tip:Show() end
    return mode
end

function ProfUI.RowTooltipLeave(tip)
    if tip and tip.Hide then tip:Hide() end
end

-- Called by paintRecipeRow BEFORE the row adopts its new spell: a recycled row
-- must not keep the previous recipe's tooltip standing. Returns true when it
-- hid one (the re-hover re-renders the new content naturally).
function ProfUI.RowTooltipOnPaint(tip, rr, newSpell)
    local owned = (tip and tip.GetOwner and tip:GetOwner() == rr) and true or false
    if ProfUI.TooltipStaleOnPaint(rr and rr._spell, newSpell, owned) then
        if tip.Hide then tip:Hide() end
        return true
    end
    return false
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
                                    -- THE SPEC RULE, through the one shared
                                    -- predicate (SpecStanding — the recipe
                                    -- list's classification reads the same
                                    -- function, and the self-test pins it):
                                    -- learnable requires HOLDING the spec.
                                    local specOK =
                                        ProfUI.SpecStanding(D, rec, pr.s) == "ok"
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

-- One character row of the grid: name column + two primary cells + the grid
-- secondary chips. NOTHING here bakes an x-position: the render calls
-- fitGridRow (below) with the SAME ProfUI.GridColumns the header uses, so the
-- cells and their headers cannot disagree — and neither can outrun the pane
-- that produced the columns. Clicking anywhere SELECTS the character; clicking
-- a specific profession cell selects that profession's detail tab with it.
local function makeGridRow(parentChild, pane)
    local gr = CreateFrame("Button", nil, parentChild)
    -- STANDING TECHNICAL RULE: both dimensions at creation. The render sets the
    -- real width from its scroll frame, but no frame here is ever born
    -- zero-sized (the class of defect that cost three iteration rounds).
    gr:SetSize(ProfUI.GridWidth(), L.ROW_H)

    -- Selection affordance, the cards' vocabulary scaled to a row: an accent
    -- wash over the fill plus a 2px accent edge on the leading side.
    local selWash = gr:CreateTexture(nil, "BACKGROUND")
    selWash:SetAllPoints()
    UI.Skin(selWash, function(self) self:SetColorTexture(UI.Color("accent", 0.10)) end)
    selWash:Hide()
    local selEdge = gr:CreateTexture(nil, "BACKGROUND", nil, 1)
    selEdge:SetPoint("TOPLEFT", gr, "TOPLEFT", 0, 0)
    selEdge:SetPoint("BOTTOMLEFT", gr, "BOTTOMLEFT", 0, 0)
    selEdge:SetWidth(2)
    UI.Skin(selEdge, function(self) self:SetColorTexture(UI.Color("accent")) end)
    selEdge:Hide()
    gr._selWash, gr._selEdge = selWash, selEdge

    local hl = gr:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    UI.Skin(hl, function(self) self:SetColorTexture(UI.Color("accent", 0.10)) end)
    gr:SetHighlightTexture(hl)

    local nameFS = fstr(gr, "body", "LEFT")
    nameFS:SetPoint("LEFT", gr, "LEFT", 2, 0)
    nameFS:SetWidth(L.NAME_W - 6)
    gr._name = nameFS

    gr:SetScript("OnClick", function(self)
        if self._owner then pane.SelectCharacter(self._owner, nil) end
    end)

    -- PRIMARY cells.
    gr._cells = {}
    for slot = 1, L.PRIMARIES do
        local cell = CreateFrame("Button", nil, gr)
        cell:SetSize(L.CELL_W, L.ROW_H - 4)
        cell:SetPoint("TOPLEFT", gr, "TOPLEFT", L.NAME_W, -2)   -- re-fit per render
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
            if self._owner then pane.SelectCharacter(self._owner, self._profKey) end
        end)
        cell:SetScript("OnEnter", function(self) pane.CellTooltip(self) end)
        cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
        gr._cells[slot] = cell
    end

    -- SECONDARY chips — the GRID subset only (no poisons column).
    gr._secs = {}
    for i, profKey in ipairs(ProfUI.GRID_SECONDARIES) do
        local chip = CreateFrame("Button", nil, gr)
        chip:SetSize(L.SEC_W, L.ROW_H - 8)
        chip:SetPoint("TOPLEFT", gr, "TOPLEFT", L.NAME_W, -4)   -- re-fit per render
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
            if self._owner then pane.SelectCharacter(self._owner, self._profKey) end
        end)
        chip:SetScript("OnEnter", function(self) pane.CellTooltip(self) end)
        chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
        gr._secs[i] = chip
    end
    return gr
end

-- Re-fit one pooled row to the column geometry of THIS render. Every text is
-- width-capped at its own column, so a cell can never spill under a neighbour
-- (the crammed-secondaries defect of the pre-rework screenshot) — let alone
-- out of the pane.
local function fitGridRow(gr, cols)
    gr._name:SetWidth(math.max(1, cols.name.w - 4))
    for slot = 1, L.PRIMARIES do
        local cell, cc = gr._cells[slot], cols.prim[slot]
        cell:SetPoint("TOPLEFT", gr, "TOPLEFT", cc.x, -2)
        cell:SetWidth(math.max(1, cc.w))
        local tw = math.max(1, cc.w - L.ICON - 8)
        cell._top:SetWidth(tw)
        cell._bot:SetWidth(tw)
    end
    for i, profKey in ipairs(ProfUI.GRID_SECONDARIES) do
        local chip, sc = gr._secs[i], cols.sec[profKey]
        chip:SetPoint("TOPLEFT", gr, "TOPLEFT", sc.x, -4)
        chip:SetWidth(math.max(1, sc.w))
        chip._text:SetWidth(math.max(1, sc.w - L.SEC_ICON - 7))
    end
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
        if cell._text then
            -- An absent SECONDARY says so out loud: the ASCII "--" in the
            -- faint ink (owner's directive — an empty cell reads as "not
            -- painted yet", which is a different claim). No icon: there is no
            -- profession to draw one for.
            local at, ai = ProfUI.SecondaryCellText(nil)
            cell._text:SetText(at)
            cell._text:SetTextColor(UI.Color(ai))
        end
        cell:EnableMouse(false)
        cell:SetAlpha(cell._text and 1 or 0.35)
        return
    end
    cell:EnableMouse(true)
    cell:SetAlpha(1)
    cell._icon:SetTexture(ProfUI.ProfIcon(model.key) or "Interface\\Icons\\INV_Misc_QuestionMark")
    -- A DESATURATED ICON is the third state at a glance: we know this character
    -- has the profession, we have never looked inside it. The secondary chips
    -- have no room for the words, so this is the only signal they carry — and
    -- the primaries wear it too so the two blocks mean the same thing. A
    -- ZERO-RECIPE profession has no window to look inside, so "never looked"
    -- is not a fact about it and its icon stays saturated.
    cell._icon:SetDesaturated(((model.total or 0) > 0 and not model.scanned) and true or false)

    -- Owner's rule (ProfUI.LevelInk): current level only, green at the Era
    -- cap, yellow below it, em dash when never recorded.
    local lvlText, lvlInk = ProfUI.LevelInk(model.level)
    if compact then
        cell._text:SetText(lvlText)
        cell._text:SetTextColor(UI.Color(lvlInk))
        return
    end

    -- The spec marker: an IN-FONT lozenge (see THE GLYPH REGISTRY — the black
    -- diamond was a tofu box), inked accent so it reads as an annotation, not
    -- as part of the green/yellow level. The cell tooltip stays the explainer.
    cell._top:SetText(lvlText .. (model.hasSpec
        and ("  " .. Dashboard.Colored(ProfUI.GLYPHS.spec, "accent")) or ""))
    cell._top:SetTextColor(UI.Color(lvlInk))

    -- The bottom line answers the most URGENT thing we know, in this order:
    -- a ready cooldown, a running one, then the recipe census — which is an EM
    -- DASH + "not checked" when the window has never been opened, never a
    -- zero, and NOTHING AT ALL for a zero-recipe profession (CensusText's
    -- rule: no window exists, so there is nothing to have checked).
    local cd = model.cd
    if cd and cd.state == "ready" then
        cell._bot:SetText(ProfUI.GLYPHS.known .. " ready"
            .. (cd.ready > 1 and (" " .. ProfUI.GLYPHS.times .. cd.ready) or ""))
        cell._bot:SetTextColor(UI.Color("ok"))
    elseif cd and cd.state == "running" then
        cell._bot:SetText(Dashboard.FormatDuration(cd.remaining, "compact"))
        cell._bot:SetTextColor(UI.Color("warn"))
    else
        local ct, ci = ProfUI.CensusText(model)
        cell._bot:SetText(ct or "")
        if ci then cell._bot:SetTextColor(UI.Color(ci)) end
    end
end

-- ── the recipe list row (drill-in) ───────────────────────────────────────────
-- NOTHING here bakes an x-position: the render calls fitRecipeRow (below) with
-- the SAME ProfUI.RecipeColumns the header band uses, so the cells and their
-- headers cannot disagree (the grid rows' idiom).
local function makeRecipeRow(listChild, pane)
    local rr = CreateFrame("Button", nil, listChild)
    rr:SetSize(1, L.LIST_ROW_H)          -- width comes from the render; never born zero
    local rh = rr:CreateTexture(nil, "HIGHLIGHT")
    rh:SetAllPoints()
    UI.Skin(rh, function(self) self:SetColorTexture(UI.Color("accent", 0.12)) end)
    rr:SetHighlightTexture(rh)

    local mark = fstr(rr, "small", "CENTER")
    mark:SetPoint("LEFT", rr, "LEFT", L.REC_MARK_X, 0)     -- re-fit per render
    mark:SetWidth(L.REC_MARK_W)
    local title = fstr(rr, "body", "LEFT")
    title:SetPoint("LEFT", rr, "LEFT", L.REC_MARK_X + L.REC_MARK_W + L.REC_TITLE_GAP, 0)
    title:SetWidth(L.REC_TITLE_MIN)
    local skill = fstr(rr, "numeral", "RIGHT")
    skill:SetPoint("LEFT", rr, "LEFT", 1, 0)               -- re-fit per render
    skill:SetWidth(L.REC_SKILL_W)
    local src = fstr(rr, "small", "LEFT")
    src:SetPoint("LEFT", rr, "LEFT", 1, 0)                 -- re-fit per render
    src:SetWidth(1)

    rr._mark, rr._title, rr._skill, rr._src = mark, title, skill, src
    rr:SetScript("OnClick", function(self)
        if self._spell then pane.SelectRecipe(self._spell) end
    end)
    -- The hover tooltip (owner, 2026-08-10). OnEnter/OnLeave ride the SAME
    -- Button the OnClick already lives on — no new mouse-enabling, so the
    -- click/selection behavior is untouched.
    rr:SetScript("OnEnter", function(self)
        ProfUI.RowTooltipEnter(GameTooltip, self, ProfUI.LiveResolver())
    end)
    rr:SetScript("OnLeave", function()
        ProfUI.RowTooltipLeave(GameTooltip)
    end)
    -- A pooled row hidden mid-hover (scroll re-render, filter change) may not
    -- leave its tooltip standing either.
    rr:SetScript("OnHide", function(self)
        if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == self then
            GameTooltip:Hide()
        end
    end)
    return rr
end

-- Re-fit one pooled row to the column geometry of THIS render (the grid's
-- fitGridRow idiom): every text width-capped at its own column.
local function fitRecipeRow(rr, cols)
    rr._mark:SetPoint("LEFT", rr, "LEFT", cols.mark.x, 0)
    rr._mark:SetWidth(math.max(1, cols.mark.w))
    rr._title:SetPoint("LEFT", rr, "LEFT", cols.title.x, 0)
    rr._title:SetWidth(math.max(1, cols.title.w))
    rr._skill:SetPoint("LEFT", rr, "LEFT", cols.skill.x, 0)
    rr._skill:SetWidth(math.max(1, cols.skill.w))
    rr._src:SetPoint("LEFT", rr, "LEFT", cols.src.x, 0)
    rr._src:SetWidth(math.max(1, cols.src.w))
end

local function paintRecipeRow(rr, row, selected)
    -- The pooled-cell lesson: if the standing tooltip belongs to this row and
    -- the row is adopting a DIFFERENT recipe, hide it before the swap.
    ProfUI.RowTooltipOnPaint(GameTooltip, rr, row.spell)
    rr._spell = row.spell
    rr._row = row
    local grey = row.unavailable and true or false
    if row.state == "known" then
        -- The known marker is the IN-FONT dot (see THE GLYPH REGISTRY): the
        -- check mark it replaces is not in the suite face and shipped as a
        -- green tofu box. options.lua's mesh list already renders this dot.
        rr._mark:SetText(ProfUI.GLYPHS.known); rr._mark:SetTextColor(UI.Color("ok"))
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

-- ── the cooldown KIND row (name · the characters ready to craft it) ─────────
local function makeCdRow(cdParent)
    local kr = CreateFrame("Frame", nil, cdParent)
    kr:SetSize(1, L.LIST_ROW_H)
    local krWhat = fstr(kr, "body", "LEFT")
    krWhat:SetPoint("LEFT", kr, "LEFT", 2, 0)
    krWhat:SetWidth(L.CD_LABEL_W)
    local krWho = fstr(kr, "small", "LEFT")
    krWho:SetPoint("LEFT", krWhat, "RIGHT", 6, 0)
    krWho:SetPoint("RIGHT", kr, "RIGHT", -2, 0)
    kr._what, kr._who = krWhat, krWho
    return kr
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

-- (The material-row factory lived here until the owner retired the MATERIALS
-- block from the detail pane, 2026-08-10. The DATA layer stays: MaterialRows /
-- MaterialText above are the reagent join, professions.lua still harvests, and
-- the tooltip/mesh consumers still read the store — only the pane stopped
-- painting it, and the recipe list wears the freed height.)

-- Class-colored short name. `extra` appends an honest overflow marker.
local function nameInk(fs, nameRealm, classTag, extra)
    fs:SetText(Dashboard.ShortName(nameRealm)
        .. ((extra and extra > 0) and (" " .. Dashboard.Colored("+" .. extra, "warn")) or ""))
    fs:SetTextColor(Dashboard.ClassColor(classTag))
end

----------------------------------------------------------------------
-- THE GRID CHIP BAR's widgets — the characters view's segmented idiom,
-- restated here because ui_cards.lua's factories are file-locals (the visual
-- contract is shared; the code deliberately lives with its pane). Same shape,
-- same inks: one housing, touching segments with 1px dividers, active = accent
-- fill + contrast label; the faction pair is crest-only, active = faction fill.
----------------------------------------------------------------------
local CHIP_SEG_H = 28   -- the cards' segment height, inside the 44px bar

local function makeGridFilterSegmented(parent, onClick)
    local housing = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    housing:SetHeight(CHIP_SEG_H)
    UI.Skin(housing, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)
    housing._segs = {}
    local prevSeg
    for i, def in ipairs(ProfUI.GRID_FILTER_DEFS) do
        local seg = CreateFrame("Button", nil, housing, "BackdropTemplate")
        seg:SetHeight(CHIP_SEG_H)
        seg._key = def.key
        -- The cards' display rule: "60s" stays lowercase, the rest uppercase.
        local disp = (def.key == "60s") and "60s" or def.label:upper()
        local segLbl = fstr(seg, "microLabel", "CENTER")
        segLbl:SetPoint("CENTER", seg, "CENTER", 0, 0)
        segLbl:SetText(disp)
        Dashboard.SizedFont(segLbl, "microLabel", 1, "OUTLINE")
        seg._lbl = segLbl
        seg:SetWidth((segLbl:GetStringWidth() or 30) + 20)
        if prevSeg then seg:SetPoint("LEFT", prevSeg, "RIGHT", 0, 0)
        else seg:SetPoint("LEFT", housing, "LEFT", 0, 0) end
        if i > 1 then
            local div = housing:CreateTexture(nil, "OVERLAY")
            div:SetSize(1, CHIP_SEG_H - 8)
            div:SetPoint("RIGHT", seg, "LEFT", 0, 0)
            UI.Skin(div, function(self) self:SetColorTexture(UI.Color("borderLite")) end)
        end
        seg:SetScript("OnEnter", function(self)
            if not def.tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(def.tip, UI.Color("muted")); GameTooltip:Show()
        end)
        seg:SetScript("OnLeave", function() GameTooltip:Hide() end)
        seg:SetScript("OnClick", function() onClick(def.key) end)
        function seg:Apply(active)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            if active then
                local ar, ag, ab = UI.Color("accent")
                self:SetBackdropColor(ar, ag, ab, 1)
                self:SetBackdropBorderColor(ar, ag, ab, 1)
                -- The cards' contrast-by-construction rule for on-accent text.
                local C = ns.Cards
                local tok = (C and C.OnAccentTextColor) and C.OnAccentTextColor(ar, ag, ab) or "ground"
                self._lbl:SetTextColor(UI.Color(tok))
            else
                self:SetBackdropColor(0, 0, 0, 0)
                self:SetBackdropBorderColor(0, 0, 0, 0)
                self._lbl:SetTextColor(UI.Color("text"))
            end
        end
        housing._segs[#housing._segs + 1] = seg
        prevSeg = seg
    end
    function housing:Apply(filter)
        local total = 0
        for _, seg in ipairs(self._segs) do
            seg:Apply(filter == seg._key); total = total + seg:GetWidth()
        end
        self:SetWidth(math.max(1, total))
    end
    -- The cards' rounded-cap overlay: the segments draw over the housing, so
    -- the corner cover+stroke ride a non-interactive cap above them.
    local cap = CreateFrame("Frame", nil, housing)
    cap:SetAllPoints(housing)
    cap:SetFrameLevel(housing:GetFrameLevel() + 10)
    if Dashboard.RoundCorners then Dashboard.RoundCorners(cap, 5, "raised", "borderLite") end
    return housing
end

-- The faction A|H pair: NOT a grid-local filter — the same global faction
-- switch the cards' chip bar drives. Dashboard.SetFaction repaints the active
-- tab itself (RefreshActive), so the click needs no local refresh call.
local function makeGridFactionSeg(parent, faction)
    local fbtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    fbtn:SetSize(30, CHIP_SEG_H)
    fbtn._faction = faction
    local crest = fbtn:CreateTexture(nil, "ARTWORK")
    crest:SetSize(16, 16); crest:SetPoint("CENTER", fbtn, "CENTER", 0, 0)
    crest:SetTexture(Dashboard.FactionCrest(faction))
    crest:SetTexCoord(0.02, 0.62, 0.03, 0.63)
    fbtn._crest = crest
    fbtn:SetScript("OnClick", function() Dashboard.SetFaction(faction) end)
    fbtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(faction, UI.Color("muted")); GameTooltip:Show()
    end)
    fbtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function fbtn:Apply(active)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        if active then
            local r, g, bl = Dashboard.FactionColor(faction)
            self:SetBackdropColor(r, g, bl, 0.85); self:SetBackdropBorderColor(r, g, bl, 1)
            self._crest:SetDesaturated(false); self._crest:SetAlpha(1)
        else
            self:SetBackdropColor(0, 0, 0, 0)
            self:SetBackdropBorderColor(UI.Color("borderLite"))
            self._crest:SetDesaturated(true); self._crest:SetAlpha(0.55)
        end
    end
    -- Outer corners only, so the touching pair reads as one pill (cards' rule).
    local only = (faction == "Alliance")
        and { TOPLEFT = true, BOTTOMLEFT = true }
        or  { TOPRIGHT = true, BOTTOMRIGHT = true }
    if Dashboard.RoundCorners then Dashboard.RoundCorners(fbtn, 5, "raised", "borderLite", only) end
    return fbtn
end

----------------------------------------------------------------------
-- THE PANE
----------------------------------------------------------------------

local thePane = nil

Dashboard.RegisterTab("professions", function(host)
    local pane = {
        mode    = "grid",              -- "grid" | "search"
        sel     = nil,                 -- { owner =, profKey =, spell = } — the selected
                                       -- row, its detail tab, and its picked recipe
        query   = "",
        filters = { search = "", source = nil, missingOnly = false, showUnavailable = false },
        gridFilter = nil,              -- the chip bar's exclusive filter key, or
                                       -- nil = everyone (restored from st.prof below)
        obj     = {},
        _gridRows = {}, _cdRows = {}, _recRows = {}, _searchRows = {},
        _tabBtns = {},
    }
    thePane = pane

    -- Persisted filter choices + the selection (the cards persist theirs the
    -- same way — st.selectedCharacter — so a /reload lands where you left).
    -- The GRID CHIP diverges from the cards' trio on purpose: the cards keep
    -- their filter as session state, but this pane already persists every
    -- other filter in st.prof, and the owner's directive for these chips is
    -- persistence — healed through ValidGridFilter so a retired or never-
    -- offered key (summoners) can never filter invisibly from SavedVariables.
    local st = Dashboard.UIState and Dashboard.UIState() or {}
    st.prof = st.prof or {}
    pane.filters.source          = st.prof.source
    pane.filters.missingOnly     = st.prof.missingOnly and true or false
    pane.filters.showUnavailable = st.prof.showUnavailable and true or false
    pane.gridFilter              = ProfUI.ValidGridFilter(st.prof.gridFilter)
    if type(st.prof.selOwner) == "string" and st.prof.selOwner ~= "" then
        pane.sel = { owner = st.prof.selOwner, profKey = st.prof.selProf, spell = nil }
    end
    local function persist()
        st.prof.source          = pane.filters.source
        st.prof.missingOnly     = pane.filters.missingOnly
        st.prof.showUnavailable = pane.filters.showUnavailable
        st.prof.gridFilter      = pane.gridFilter or ""   -- "" = none (selOwner's idiom)
        st.prof.selOwner        = pane.sel and pane.sel.owner or ""
        st.prof.selProf         = pane.sel and pane.sel.profKey or nil
    end

    -- ── TOOLBAR: the who-can-craft box (the drill-in breadcrumb + back button
    -- are retired with the mode swap: the detail pane is simply always there) ─
    local toolbar = CreateFrame("Frame", nil, host)
    toolbar:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    toolbar:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
    toolbar:SetHeight(L.TOOLBAR_H)
    Dashboard.Tag(toolbar, "prof.toolbar")

    local who = searchBox(toolbar, "WHO CAN CRAFT", 320, function(text)
        pane.query = text or ""
        pane.mode = (pane.query ~= "") and "search" or "grid"
        pane.obj.Refresh()
    end)
    who:SetPoint("LEFT", toolbar, "LEFT", 2, 0)

    -- ── BODY: the pane host.
    -- Deliberately a frame of its own rather than anchoring the panels straight
    -- to `host`: the three-pane layout and the search results are mutually
    -- exclusive and therefore DO sit at the same origin, which the static
    -- anchor gate reads (correctly, for its narrow rule) as frames overlapping
    -- on a shared parent. One container makes the exclusivity structural
    -- instead of textual.
    local body = CreateFrame("Frame", nil, host)
    body:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -L.TOOLBAR_H)
    body:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
    Dashboard.Tag(body, "prof.body")

    -- ══ THE THREE PANES ═════════════════════════════════════════════════════
    -- Grid left (GRID_FRACTION of the width), detail top-right
    -- (DETAIL_FRACTION of the right column's height), cooldown kinds under it.
    -- Both axes re-fit from the body's REAL rect — OnSizeChanged is the belt,
    -- the applySplit at the top of every Refresh the braces — and the column
    -- geometry inside the grid pane re-derives from the pane's real width on
    -- every render, so no pane and no column ever leans on an assumed shell
    -- constant again (the overflow lesson).
    local gridP = panel(body, "prof.grid")
    gridP:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    gridP:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    -- Born at its natural-content width (standing rule: both dimensions at
    -- creation, never zero); applySplit re-fits it the moment the body has a
    -- real width, and again whenever that changes.
    gridP:SetWidth(ProfUI.GridWidth() + 2 * L.PANEL_PAD)

    local detailP = panel(body, "prof.detail")
    detailP:SetPoint("TOPLEFT", gridP, "TOPRIGHT", L.GUTTER, 0)
    detailP:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    detailP:SetHeight(300)               -- born non-zero; applySplit re-fits

    local cdP = panel(body, "prof.cooldowns")
    cdP:SetPoint("TOPLEFT", detailP, "BOTTOMLEFT", 0, -L.GUTTER)
    cdP:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)

    local function applySplit()
        local totalW, totalH = body:GetWidth(), body:GetHeight()
        if totalW and totalW > 0 then
            local gridW = ProfUI.SplitWidths(totalW)
            if math.abs((gridP:GetWidth() or 0) - gridW) > 0.5 then gridP:SetWidth(gridW) end
        end
        if totalH and totalH > 0 then
            local detailH = ProfUI.RightSplitHeights(totalH)
            if math.abs((detailP:GetHeight() or 0) - detailH) > 0.5 then detailP:SetHeight(detailH) end
        end
    end
    body:SetScript("OnSizeChanged", applySplit)
    applySplit()

    -- ── the grid pane ────────────────────────────────────────────────────────
    -- THE CHIP BAR (owner, 2026-08-10: "add these same filters (minus
    -- summoners)"): the characters view's chip-bar shape at the top of the
    -- grid panel — filter segments left, faction A|H right, hairline rule
    -- under the band — pushing the header band and the rows down by CHIP_H
    -- (GridHeaderTopInset / GridListTopInset, the pure readers).
    local chipbar = CreateFrame("Frame", nil, gridP)
    chipbar:SetPoint("TOPLEFT", gridP, "TOPLEFT", 1, -1)
    chipbar:SetPoint("TOPRIGHT", gridP, "TOPRIGHT", -1, -1)
    chipbar:SetHeight(L.CHIP_H)
    Dashboard.Tag(chipbar, "prof.chipbar")
    do
        -- The cards' hairline rule under the bar, through the same Core guard.
        local Hairline = ns.CoreAPI
            and ns:CoreAPI(ns.CORE_KIT_VERSION, "the professions chip bar", UI and UI.Hairline)
            or nil
        if Hairline then
            local chipRule = Hairline(gridP, { token = "borderLite" })
            chipRule:SetPoint("BOTTOMLEFT", chipbar, "BOTTOMLEFT", 0, 0)
            chipRule:SetPoint("BOTTOMRIGHT", chipbar, "BOTTOMRIGHT", 0, 0)
            Dashboard.Tag(chipRule, "prof.chiprule")
        end
    end
    local filterSeg = makeGridFilterSegmented(chipbar, function(key)
        pane.gridFilter = ProfUI.NextGridFilter(pane.gridFilter, key)
        persist()
        pane.obj.Refresh()
    end)
    filterSeg:SetPoint("LEFT", chipbar, "LEFT", 6, 0)
    pane._filterSeg = filterSeg
    Dashboard.Tag(filterSeg, "prof.chip.filter")
    local facA = makeGridFactionSeg(chipbar, "Alliance")
    local facH = makeGridFactionSeg(chipbar, "Horde")
    facH:SetPoint("RIGHT", chipbar, "RIGHT", -6, 0)
    facA:SetPoint("RIGHT", facH, "LEFT", 0, 0)   -- touching halves
    pane._factionSegs = { facA, facH }
    Dashboard.Tag(facA, "prof.chip.faction")

    -- The header band CLIPS and its labels are positioned per render from the
    -- SAME GridColumns the rows use — the header and the cells cannot drift
    -- apart, and neither can leave the pane.
    local gridHead = CreateFrame("Frame", nil, gridP)
    gridHead:SetPoint("TOPLEFT", gridP, "TOPLEFT", L.PANEL_PAD, -ProfUI.GridHeaderTopInset())
    gridHead:SetPoint("TOPRIGHT", gridP, "TOPRIGHT", -L.PANEL_PAD, -ProfUI.GridHeaderTopInset())
    gridHead:SetHeight(L.HEAD_H)
    gridHead:SetClipsChildren(true)
    local headFS = {}
    do
        local labels = ProfUI.GridHeaderLabels()
        for i = 1, #labels do
            local hf = eyebrow(gridHead, labels[i], "LEFT")
            hf:SetPoint("TOPLEFT", gridHead, "TOPLEFT", 0, 0)   -- re-fit per render
            headFS[i] = hf
        end
    end
    local function layoutHead(cols)
        headFS[1]:SetPoint("TOPLEFT", gridHead, "TOPLEFT", cols.name.x + 2, 0)
        headFS[1]:SetWidth(math.max(1, cols.name.w - 2))
        for slot = 1, L.PRIMARIES do
            local hf = headFS[1 + slot]
            hf:SetPoint("TOPLEFT", gridHead, "TOPLEFT", cols.prim[slot].x + 2, 0)
            hf:SetWidth(math.max(1, cols.prim[slot].w - 2))
        end
        for i, key in ipairs(ProfUI.GRID_SECONDARIES) do
            local hf = headFS[1 + L.PRIMARIES + i]
            hf:SetPoint("TOPLEFT", gridHead, "TOPLEFT", cols.sec[key].x, 0)
            hf:SetWidth(math.max(1, cols.sec[key].w))
        end
    end

    local gridScroll, gridChild = scroller(gridP, "prof.grid.list")
    gridScroll:SetPoint("TOPLEFT", gridP, "TOPLEFT", L.PANEL_PAD, -ProfUI.GridListTopInset())
    gridScroll:SetPoint("BOTTOMRIGHT", gridP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    pane._gridChild = gridChild

    -- Text set per render: with a chip active the emptiness has a CAUSE, and
    -- GridEmptyText names it instead of claiming nothing was ever recorded.
    local gridEmpty = fstr(gridChild, "muted", "LEFT")
    gridEmpty:SetPoint("TOPLEFT", gridChild, "TOPLEFT", 2, -4)
    gridEmpty:SetText(ProfUI.GridEmptyText(nil))
    gridEmpty:Hide()
    pane._gridEmpty = gridEmpty

    -- ── the cooldown kinds pane ──────────────────────────────────────────────
    local cdHead = eyebrow(cdP, "COOLDOWNS", "LEFT")
    cdHead:SetPoint("TOPLEFT", cdP, "TOPLEFT", L.PANEL_PAD, -L.PANEL_PAD)
    local cdCount = fstr(cdP, "numeral", "RIGHT")
    cdCount:SetPoint("TOPRIGHT", cdP, "TOPRIGHT", -L.PANEL_PAD, -L.PANEL_PAD)
    pane._cdCount = cdCount

    local cdScroll, cdChild = scroller(cdP, "prof.cooldowns.list")
    cdScroll:SetPoint("TOPLEFT", cdP, "TOPLEFT", L.PANEL_PAD, -(L.PANEL_PAD + L.HEAD_H + 2))
    cdScroll:SetPoint("BOTTOMRIGHT", cdP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    pane._cdChild = cdChild

    local cdEmpty = fstr(cdChild, "muted", "LEFT")
    cdEmpty:SetPoint("TOPLEFT", cdChild, "TOPLEFT", 2, -4)
    cdEmpty:SetText("No profession cooldowns recorded.")
    cdEmpty:Hide()
    pane._cdEmpty = cdEmpty

    -- ── the detail pane: eyebrow + name, the profession TAB strip, the filter
    -- rows, the recipe list, and the recipe detail band — the old drill-in's
    -- content re-homed into a pane that is simply always there ────────────────
    local dEyebrow = eyebrow(detailP, "DETAIL", "LEFT")
    dEyebrow:SetPoint("TOPLEFT", detailP, "TOPLEFT", L.PANEL_PAD, -L.PANEL_PAD)
    local dWho = fstr(detailP, "body", "LEFT")
    dWho:SetPoint("LEFT", dEyebrow, "RIGHT", 8, 0)
    pane._dWho = dWho

    -- The quiet hint when no character row is selected (or the selected one
    -- has no professions record at all).
    local dHint = fstr(detailP, "muted", "LEFT")
    dHint:SetPoint("TOPLEFT", detailP, "TOPLEFT", L.PANEL_PAD, -(L.PANEL_PAD + 24))
    dHint:SetPoint("RIGHT", detailP, "RIGHT", -L.PANEL_PAD, 0)
    dHint:SetText("Select a character to inspect their professions.")
    pane._dHint = dHint

    local tabStrip = CreateFrame("Frame", nil, detailP)
    tabStrip:SetPoint("TOPLEFT", detailP, "TOPLEFT", L.PANEL_PAD, -(L.PANEL_PAD + 20))
    tabStrip:SetPoint("RIGHT", detailP, "RIGHT", -L.PANEL_PAD, 0)
    tabStrip:SetHeight(L.DTAB_H)
    tabStrip:SetClipsChildren(true)
    Dashboard.Tag(tabStrip, "prof.detail.tabs")
    pane._tabStrip = tabStrip

    -- One profession tab (the shell titlebar's idiom: label + accent underline
    -- when active). Pooled; positioned per render from DetailTabLayout.
    local function getTabBtn(i)
        local b = pane._tabBtns[i]
        if not b then
            local tbtn = CreateFrame("Button", nil, tabStrip)
            tbtn:SetSize(L.DTAB_MAX, L.DTAB_H)
            local tlab = fstr(tbtn, "small", "CENTER")
            tlab:SetPoint("TOPLEFT", tbtn, "TOPLEFT", 2, -2)
            tlab:SetPoint("BOTTOMRIGHT", tbtn, "BOTTOMRIGHT", -2, 3)
            local tun = tbtn:CreateTexture(nil, "ARTWORK")
            tun:SetPoint("BOTTOMLEFT", tbtn, "BOTTOMLEFT", 2, 0)
            tun:SetPoint("BOTTOMRIGHT", tbtn, "BOTTOMRIGHT", -2, 0)
            tun:SetHeight(2)
            UI.Skin(tun, function(self) self:SetColorTexture(UI.Color("accent")) end)
            tun:Hide()
            local thl = tbtn:CreateTexture(nil, "HIGHLIGHT")
            thl:SetAllPoints()
            UI.Skin(thl, function(self) self:SetColorTexture(UI.Color("accent", 0.10)) end)
            tbtn:SetHighlightTexture(thl)
            tbtn._lbl, tbtn._under = tlab, tun
            tbtn:SetScript("OnClick", function(self)
                if self._profKey then pane.SelectProfTab(self._profKey) end
            end)
            b = tbtn
            pane._tabBtns[i] = b
        end
        return b
    end

    -- Filter row 1: the find box + the source chip.
    local filter1 = CreateFrame("Frame", nil, detailP)
    filter1:SetPoint("TOPLEFT", tabStrip, "BOTTOMLEFT", 0, -6)
    filter1:SetPoint("RIGHT", detailP, "RIGHT", -L.PANEL_PAD, 0)
    filter1:SetHeight(L.FILTER_H)
    Dashboard.Tag(filter1, "prof.filters")

    local rSearch = searchBox(filter1, "FIND", 200, function(text)
        pane.filters.search = text or ""
        pane.obj.Refresh()
    end)
    rSearch:SetPoint("LEFT", filter1, "LEFT", 0, 0)

    local SRC_VALUES = { false }
    local SRC_LABELS = { [false] = "All" }
    for _, k in ipairs(ProfUI.SOURCE_ORDER) do
        SRC_VALUES[#SRC_VALUES + 1] = k
        SRC_LABELS[k] = ProfUI.SOURCE_LABEL[k]
    end
    local srcChip = cycleChip(filter1, "SOURCE", SRC_VALUES, SRC_LABELS, 140, function(v)
        pane.filters.source = v or nil
        persist(); pane.obj.Refresh()
    end)
    srcChip:SetPoint("LEFT", rSearch, "RIGHT", L.GUTTER, 0)
    srcChip:SetValue(pane.filters.source or false)

    -- Filter row 2: the two toggles + the cold-name status. Two rows because
    -- the detail pane is a column, not the old full-width band — four controls
    -- on one 24px line would not fit its width.
    local filter2 = CreateFrame("Frame", nil, detailP)
    filter2:SetPoint("TOPLEFT", filter1, "BOTTOMLEFT", 0, -4)
    filter2:SetPoint("RIGHT", detailP, "RIGHT", -L.PANEL_PAD, 0)
    filter2:SetHeight(22)
    Dashboard.Tag(filter2, "prof.filters2")

    local missChk = checkBox(filter2, "Missing only",
        function() return pane.filters.missingOnly end,
        function(v) pane.filters.missingOnly = v; persist(); pane.obj.Refresh() end)
    missChk:SetPoint("LEFT", filter2, "LEFT", 0, 0)

    local unavChk = checkBox(filter2, "Show unavailable",
        function() return pane.filters.showUnavailable end,
        function(v) pane.filters.showUnavailable = v; persist(); pane.obj.Refresh() end)
    unavChk:SetPoint("LEFT", missChk, "RIGHT", L.GUTTER, 0)

    -- THE SHOPPING LIST BUTTON (owner's directive; see the pure layer's header
    -- beside RecipeRows). Raid Prep's shopping list is a one-click verb on the
    -- window that owns the data, so this one rides the detail pane's own
    -- control band, scoped to the selected character + profession tab. The
    -- render is a branded chat list (links shift-click into the AH search
    -- box); with Auctionator loaded at an open AH the names also fill the
    -- Shopping tab — the checklist gavel's behavior, scoped down.
    local shopBtn = CreateFrame("Button", nil, filter2, "BackdropTemplate")
    shopBtn:SetSize(108, 22)
    local shopLbl = fstr(shopBtn, "small", "CENTER")
    shopLbl:SetPoint("TOPLEFT", shopBtn, "TOPLEFT", 4, 0)
    shopLbl:SetPoint("BOTTOMRIGHT", shopBtn, "BOTTOMRIGHT", -4, 0)
    shopLbl:SetText("SHOPPING LIST")
    shopBtn._lbl = shopLbl
    UI.Skin(shopBtn, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("control"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
        self._lbl:SetTextColor(UI.Color("muted"))
    end)
    shopBtn:SetScript("OnEnter", function(self)
        self._lbl:SetTextColor(UI.Color("text"))
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Shopping list", 1, 1, 1)
        GameTooltip:AddLine("Chat list of this character's missing recipes that can"
            .. " be bought on the AH. With Auctionator loaded and the auction"
            .. " house open, the names also fill the Shopping tab.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    shopBtn:SetScript("OnLeave", function(self)
        self._lbl:SetTextColor(UI.Color("muted"))
        GameTooltip:Hide()
    end)
    shopBtn:SetScript("OnClick", function()
        ProfUI.RunShoplist(pane.sel and pane.sel.owner, pane.sel and pane.sel.profKey)
    end)
    shopBtn:SetPoint("LEFT", unavChk, "RIGHT", L.GUTTER, 0)

    local recStatus = fstr(filter2, "small", "RIGHT")
    recStatus:SetPoint("RIGHT", filter2, "RIGHT", 0, 0)
    UI.Skin(recStatus, function(self) self:SetTextColor(UI.Color("muted")) end)
    pane._recStatus = recStatus

    -- THE COLUMN HEADER BAND (owner, 2026-08-10: "add column headers in the
    -- Detail list") — the grid header's idiom restated: an eyebrow row that
    -- CLIPS, its labels positioned per render from the SAME RecipeColumns the
    -- rows use, so the captions and the cells cannot drift apart. It costs the
    -- list exactly one LIST_ROW_H (RecipeListHeaderHeight, pinned).
    local recHead = CreateFrame("Frame", nil, detailP)
    recHead:SetPoint("TOPLEFT", filter2, "BOTTOMLEFT", 0, -4)
    recHead:SetPoint("RIGHT", detailP, "RIGHT", -L.PANEL_PAD, 0)
    recHead:SetHeight(L.HEAD_H)
    recHead:SetClipsChildren(true)
    Dashboard.Tag(recHead, "prof.recipes.head")
    local recHeadFS = {}
    do
        local cells = ProfUI.RecipeHeaderCells(0)
        for i = 1, #cells do
            local hf = eyebrow(recHead, cells[i].label, cells[i].justify)
            hf:SetPoint("TOPLEFT", recHead, "TOPLEFT", 0, 0)   -- re-fit per render
            recHeadFS[i] = hf
        end
    end
    local function layoutRecHead(cells)
        for i = 1, #cells do
            local hf = recHeadFS[i]
            hf:SetPoint("TOPLEFT", recHead, "TOPLEFT", cells[i].x, 0)
            hf:SetWidth(math.max(1, cells[i].w))
        end
    end

    local recScroll, recChild = scroller(detailP, "prof.recipes.list")
    recScroll:SetPoint("TOPLEFT", recHead, "BOTTOMLEFT", 0, -2)
    recScroll:SetPoint("BOTTOMRIGHT", detailP, "BOTTOMRIGHT", -L.PANEL_PAD,
                       ProfUI.RecipeListBottomInset())
    pane._recChild = recChild

    local recEmpty = fstr(recChild, "muted", "LEFT")
    recEmpty:SetPoint("TOPLEFT", recChild, "TOPLEFT", 2, -4)
    recEmpty:Hide()
    pane._recEmpty = recEmpty

    -- The selected recipe's INFO BAND — name + where it comes from — pinned to
    -- the bottom of the detail pane so the list above it never has to reflow.
    -- The MATERIALS block that used to live under it is retired (owner's
    -- rework, 2026-08-10): the band shrank to its two lines of content and the
    -- recipe list above owns the freed height.
    local detail = CreateFrame("Frame", nil, detailP)
    detail:SetPoint("BOTTOMLEFT", detailP, "BOTTOMLEFT", L.PANEL_PAD, L.PANEL_PAD)
    detail:SetPoint("BOTTOMRIGHT", detailP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    detail:SetHeight(L.INFO_H)
    Dashboard.Tag(detail, "prof.recipe.detail")
    pane._detail = detail

    local dTitle = fstr(detail, "body", "LEFT")
    dTitle:SetPoint("TOPLEFT", detail, "TOPLEFT", 2, -2)
    dTitle:SetPoint("RIGHT", detail, "RIGHT", -2, 0)
    local dSource = fstr(detail, "small", "LEFT")
    dSource:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -3)
    dSource:SetPoint("RIGHT", detail, "RIGHT", -2, 0)
    -- TWO LINES for the acquisition text (owner, 2026-08-10): the zoned
    -- phrases ("Sold by Fradd Swiftgear \226\128\148 Gnomeregan area" style)
    -- outgrew one line. fstr()'s no-wrap default is overridden HERE ONLY: the
    -- wrap width is the TOPLEFT/RIGHT anchor pair above (the pane's real width,
    -- never a constant), the height is the fixed ACQ_LINES budget from the pure
    -- reader, and TOP justification keeps line one on the name's baseline gap
    -- so the band never crowds the name above or the panel pad below. Where the
    -- client offers SetMaxLines the overflow ellipsizes natively; without it
    -- the fixed height is the cap and line three simply clips. No scrolling.
    dSource:SetWordWrap(true)
    dSource:SetJustifyV("TOP")
    dSource:SetHeight(ProfUI.AcqTextHeight())
    if dSource.SetMaxLines then dSource:SetMaxLines(L.ACQ_LINES) end
    pane._dTitle, pane._dSource = dTitle, dSource

    -- ══ THE SEARCH OVERLAY: the who-can-craft results (typing in the toolbar
    -- box swaps the three panes for this, clearing it swaps them back) ═══════
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
    -- Selection + tooltips
    ----------------------------------------------------------------------

    -- The cards' idiom, deliberately: selection is a CURSOR, not a toggle —
    -- ui_cards re-selects on a re-click and never clears itself, so selecting
    -- the same row again simply keeps it. Selection also survives Refresh (it
    -- lives on the pane, and persists to the ui state like the cards' does).
    function pane.SelectCharacter(ownerKey, profKey)
        if pane.sel and pane.sel.owner == ownerKey then
            if profKey and profKey ~= pane.sel.profKey then
                pane.sel.profKey = profKey
                pane.sel.spell = nil
            end
        else
            pane.sel = { owner = ownerKey, profKey = profKey, spell = nil }
        end
        persist()
        pane.obj.Refresh()
    end
    function pane.SelectProfTab(profKey)
        if not pane.sel then return end
        if pane.sel.profKey ~= profKey then
            pane.sel.profKey = profKey
            pane.sel.spell = nil
        end
        persist()
        pane.obj.Refresh()
    end
    function pane.SelectRecipe(spell)
        if pane.sel then pane.sel.spell = spell end
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
        -- The recipe-census lines exist only for professions that HAVE a
        -- census. A zero-recipe profession (fishing, herbalism, skinning) has
        -- no window to open, so "NOT CHECKED — open it once" would be an
        -- instruction the game cannot follow (owner's rule, 2026-08-10).
        if (m.total or 0) > 0 then
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
    local function getCdRow(i)
        local r = pane._cdRows[i]
        if not r then r = makeCdRow(cdChild); pane._cdRows[i] = r end
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

    local function renderGrid(entries, lookup, nowE)
        local rows = ProfUI.GridRows(entries, lookup, nowE)
        -- THE REAL PANE WIDTH, at render time. Before the first layout pass the
        -- scroll may not have resolved a rect yet; the natural width stands in
        -- (clipped by the scroll regardless) and the OnSizeChanged → Refresh
        -- pass re-derives everything the moment the real number exists.
        local availW = gridScroll:GetWidth() or 0
        if availW < 2 then availW = ProfUI.GridWidth() end
        local cols = ProfUI.GridColumns(availW)
        layoutHead(cols)
        gridChild:SetWidth(availW)
        for _, r in ipairs(pane._gridRows) do r:Hide() end
        local selOwner = pane.sel and pane.sel.owner or nil
        local shown, y = 0, 0
        for i = 1, #rows do
            local model = rows[i]
            if model.hasAny then
                shown = shown + 1
                local gr = getGridRow(shown)
                gr:ClearAllPoints()
                gr:SetPoint("TOPLEFT", gridChild, "TOPLEFT", 0, -y)
                gr:SetWidth(availW)
                fitGridRow(gr, cols)
                gr._owner = model.key
                nameInk(gr._name, model.key, model.classTag, model.overflow)
                for slot = 1, L.PRIMARIES do
                    paintCell(gr._cells[slot], model.primaries[slot], model.key, false)
                end
                for si, profKey in ipairs(ProfUI.GRID_SECONDARIES) do
                    paintCell(gr._secs[si], model.secondaries[profKey], model.key, true)
                end
                local isSel = (selOwner ~= nil and model.key == selOwner)
                gr._selWash:SetShown(isSel)
                gr._selEdge:SetShown(isSel)
                gr:Show()
                y = y + L.ROW_H
            end
        end
        gridChild:SetHeight(math.max(y, 1))
        pane._gridEmpty:SetText(ProfUI.GridEmptyText(pane.gridFilter))
        pane._gridEmpty:SetShown(shown == 0)
    end

    local function renderCooldowns(entries, lookup, nowE, res)
        local rows = ProfUI.CooldownKindRows(entries, lookup, nowE, res)
        -- The ready count is the same number the badge counts: every ready
        -- INSTANCE lands in exactly one kind's ready list.
        local ready = 0
        for i = 1, #rows do ready = ready + #rows[i].ready end
        cdCount:SetText(ready > 0 and (ready .. " ready") or "")
        cdCount:SetTextColor(UI.Color(ready > 0 and "ok" or "muted"))
        cdChild:SetWidth(math.max(1, cdScroll:GetWidth() or 1))
        for _, r in ipairs(pane._cdRows) do r:Hide() end
        local pendingIDs, y = {}, 0
        for i = 1, #rows do
            local row = rows[i]
            if row.pending then pendingIDs[#pendingIDs + 1] = tonumber(row.cdKey) end
            local kr = getCdRow(i)
            kr:ClearAllPoints()
            kr:SetPoint("TOPLEFT", cdChild, "TOPLEFT", 0, -y)
            kr:SetPoint("RIGHT", cdChild, "RIGHT", 0, 0)
            kr._what:SetText(row.label or "\226\128\166")
            kr._what:SetTextColor(UI.Color("text"))
            if #row.ready > 0 then
                local parts = {}
                for j = 1, #row.ready do
                    parts[#parts + 1] = Dashboard.ColoredName(row.ready[j].key,
                                                              row.ready[j].classTag)
                end
                kr._who:SetText(table.concat(parts, ", "))
                kr._who:SetTextColor(UI.Color("text"))
            else
                -- Every holder is mid-cooldown. The row stays (the kind IS
                -- owned) but names nobody — that silence is the owner's rule,
                -- and the em dash keeps it from reading as "not rendered yet".
                kr._who:SetText("\226\128\148")
                kr._who:SetTextColor(UI.Color("faint"))
            end
            kr:Show()
            y = y + L.LIST_ROW_H
        end
        cdChild:SetHeight(math.max(y, 1))
        pane._cdEmpty:SetShown(#rows == 0)
        notePending("spell", pendingIDs)
    end

    -- Show/hide the detail pane's working furniture in one motion (the empty
    -- state hides all of it behind the hint line).
    local function setDetailShown(on)
        tabStrip:SetShown(on)
        filter1:SetShown(on)
        filter2:SetShown(on)
        recHead:SetShown(on)
        recScroll:SetShown(on)
        detail:SetShown(on)
    end

    local function renderDetail(lookup, nowE, res, allEntries)
        local sel = pane.sel

        -- FILTERED IS NOT DESELECTED (the chip contract): a selected character
        -- the active chip hides keeps their selection — the pane says so and
        -- waits. Clearing the chip (or the character coming online / hitting
        -- 60) restores the detail without a click, because pane.sel and
        -- st.prof.selOwner were never touched. Only a roster member hidden BY
        -- THE CHIP lands here; a character absent from the roster altogether
        -- keeps the existing empty states below.
        if sel and ProfUI.SelectionHiddenByFilter(allEntries, pane.gridFilter, sel.owner) then
            for _, b in ipairs(pane._tabBtns) do b:Hide() end
            setDetailShown(false)
            dWho:SetText(Dashboard.ShortName(sel.owner))
            dWho:SetTextColor(UI.Color("muted"))
            dHint:SetText(ProfUI.HiddenSelectionHint(Dashboard.ShortName(sel.owner), pane.gridFilter))
            dHint:Show()
            return
        end

        local payload = sel and lookup(sel.owner) or nil
        local tabs = ProfUI.DetailTabs(payload)

        -- EMPTY STATES: nothing selected, a selected character the store holds
        -- no professions record for, or a character whose recorded professions
        -- are all zero-recipe (nothing here can be "opened"). A quiet hint,
        -- not a blank pane — and NEVER "open X once" about a profession that
        -- has no window (owner's rule, 2026-08-10).
        if not sel or #tabs == 0 then
            for _, b in ipairs(pane._tabBtns) do b:Hide() end
            setDetailShown(false)
            dWho:SetText(sel and Dashboard.ShortName(sel.owner) or "")
            dWho:SetTextColor(UI.Color("muted"))
            local hint = "Select a character to inspect their professions."
            if sel then
                local held = ProfUI.ProfessionList(payload)
                if #held > 0 then
                    hint = Dashboard.ShortName(sel.owner)
                        .. "'s recorded professions have no recipe lists to browse."
                else
                    hint = "No professions recorded for " .. Dashboard.ShortName(sel.owner)
                        .. " yet \226\128\148 open a profession window on that character once."
                end
            end
            dHint:SetText(hint)
            dHint:Show()
            return
        end
        dHint:Hide()
        setDetailShown(true)

        -- A remembered tab that is no longer eligible — the character dropped
        -- the profession, or the tab belongs to a zero-recipe profession that
        -- no longer earns one — falls back to their first eligible profession
        -- rather than to a blank list (ProfUI.ResolveDetailTab).
        local cur = ProfUI.ResolveDetailTab(tabs, sel.profKey)
        if cur ~= sel.profKey then
            sel.profKey = cur
            sel.spell = nil
        end

        nameInk(dWho, sel.owner, (function()
            local rec = Dashboard.ResolveRosterOwner and select(1, Dashboard.ResolveRosterOwner(sel.owner))
            return rec and rec.classTag or nil
        end)())

        -- THE TAB STRIP — one tab per profession this character holds (the
        -- rogue's Poisons rides in payload.p, so its tab appears here and only
        -- here), evenly fitted to the strip's REAL width.
        local stripW = tabStrip:GetWidth() or 0
        if stripW < 2 then stripW = L.DTAB_MAX end
        local tl = ProfUI.DetailTabLayout(stripW, #tabs)
        for _, b in ipairs(pane._tabBtns) do b:Hide() end
        for i = 1, #tabs do
            local b = getTabBtn(i)
            b._profKey = tabs[i]
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", tabStrip, "TOPLEFT", tl.xs[i], 0)
            b:SetWidth(math.max(1, tl.w))
            b._lbl:SetText(ProfUI.ProfName(tabs[i]))
            local active = (tabs[i] == cur)
            b._lbl:SetTextColor(UI.Color(active and "text" or "muted"))
            b._under:SetShown(active)
            b:Show()
        end

        -- THE RECIPE LIST (the old drill-in's right pane, re-homed). Column
        -- geometry — the name column's share of the REAL list width, the
        -- source column's remainder — comes from ProfUI.RecipeColumns, and
        -- the header band lays its captions out from the SAME columns.
        local rows, pending, state = ProfUI.RecipeRows(payload, cur, pane.filters, res)
        local listW = math.max(1, recScroll:GetWidth() or 1)
        recChild:SetWidth(listW)
        local cols = ProfUI.RecipeColumns(listW)
        layoutRecHead(ProfUI.RecipeHeaderCells(listW))
        for _, r in ipairs(pane._recRows) do r:Hide() end
        local ry = 0
        for i = 1, #rows do
            local rr = getRecRow(i)
            rr:ClearAllPoints()
            rr:SetPoint("TOPLEFT", recChild, "TOPLEFT", 0, -ry)
            rr:SetPoint("RIGHT", recChild, "RIGHT", 0, 0)
            fitRecipeRow(rr, cols)
            paintRecipeRow(rr, rows[i], rows[i].spell == sel.spell)
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
                .. ProfUI.ProfName(cur) .. " on " .. Dashboard.ShortName(sel.owner)
                .. " once and this list fills in."
        end
        pane._recEmpty:SetText((#rows == 0) and (emptyText or "No recipes match.") or "")
        pane._recEmpty:SetShown(#rows == 0)
        recStatus:SetText(statusText or "")

        -- The selected recipe's INFO BAND: its name and where it comes from.
        -- (The MATERIALS block is retired; the reagent data still lives in the
        -- store for its other consumers.)
        if sel.spell then
            local nm = res.spell and res.spell(sel.spell) or nil
            pane._dTitle:SetText(nm or "\226\128\166")
            pane._dTitle:SetTextColor(UI.Color("text"))
            local src = ProfUI.SourceModel(sel.spell)
            local line = src and (#src.lines > 0 and table.concat(src.lines, "  \194\183  ") or src.text) or ""
            if src and src.unavailable then
                line = line .. "   [unavailable \226\128\148 " .. src.unavailable.text .. "]"
            end
            pane._dSource:SetText(line)
            pane._dSource:SetTextColor(UI.Color(src and src.unavailable and "danger" or "muted"))
        else
            pane._dTitle:SetText("")
            pane._dSource:SetText("Select a recipe to see where it comes from.")
            pane._dSource:SetTextColor(UI.Color("faint"))
        end
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
            gridP:Hide(); detailP:Hide(); cdP:Hide(); searchP:Hide()
            return
        end
        applySplit()      -- belt to OnSizeChanged's braces: a body whose rect
                          -- resolved after build still lands on the splits
        local nowE = now()
        local res = ProfUI.LiveResolver()
        local entries = ProfUI.Roster()
        local lookup = payloadLookup()
        pane._entries, pane._lookup = entries, lookup

        -- Chip repaint: at most one filter segment filled (none = everyone),
        -- and the faction pair mirrors the global Dashboard faction.
        pane._filterSeg:Apply(pane.gridFilter)
        local fac = Dashboard.GetFaction and Dashboard.GetFaction() or nil
        for _, s in ipairs(pane._factionSegs) do s:Apply(s._faction == fac) end

        local isSearch = (pane.mode == "search")
        gridP:SetShown(not isSearch)
        detailP:SetShown(not isSearch)
        cdP:SetShown(not isSearch)
        searchP:SetShown(isSearch)

        if isSearch then
            renderSearch(entries, lookup, res)
        else
            -- The chips scope THE GRID ONLY: the detail pane gets the full
            -- roster (to tell "hidden by chip" from "gone"), and the cooldown
            -- pane keeps every character — a hidden-but-ready alt still
            -- matters, which is that pane's reason to exist.
            renderGrid(ProfUI.FilterEntries(entries, pane.gridFilter), lookup, nowE)
            renderDetail(lookup, nowE, res, entries)
            renderCooldowns(entries, lookup, nowE, res)
        end
        if Dashboard.RefreshTabStrip then Dashboard.RefreshTabStrip() end
    end

    -- THE CHEAP HALF. Everything one second changes here is a COUNTDOWN (the
    -- grid cells' running timers and the cooldown pane's ready flips), and a
    -- countdown needs neither a fresh roster gather (which re-derives online
    -- winners across the whole store) nor a re-sort nor a scroll reset. So the
    -- ticker re-renders from the entries the last full Refresh already
    -- gathered. The detail pane carries no clock; membership, selection and
    -- store changes still arrive as engine events and still run the full
    -- Refresh. Search results carry no clock either, so that mode does not
    -- tick at all.
    function pane.obj.Repaint()
        if not enabled() then return end
        if pane.mode == "search" then return end
        local entries, lookup = pane._entries, pane._lookup
        if not (entries and lookup) then return pane.obj.Refresh() end
        local nowE = now()
        local res = ProfUI.LiveResolver()
        -- Same scoping as Refresh: chips filter the grid, never the cooldowns.
        renderGrid(ProfUI.FilterEntries(entries, pane.gridFilter), lookup, nowE)
        renderCooldowns(entries, lookup, nowE, res)
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

    -- The scrolls are where the REAL widths live; when either resolves or
    -- changes, the whole geometry re-derives (the overflow lesson again).
    gridScroll:SetScript("OnSizeChanged", function() pane.obj.Refresh() end)
    recScroll:SetScript("OnSizeChanged", function() pane.obj.Refresh() end)
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
-- THE SHOPPING LIST VERB  (the side-effect half; the pure layer lives beside
-- RecipeRows). One entry for both the detail-pane button and the slash.
----------------------------------------------------------------------

-- Is the auction house open? Read the OBJECT live (Raid Prep's RP-1 lesson,
-- class 2: the AH frame globals are load-on-demand, so an event-time snapshot
-- can freeze "no auction house" forever). Re-asked on every click instead.
function ProfUI.AHIsShown()
    local f = _G.AuctionFrame or _G.AuctionHouseFrame
    if not (f and f.IsShown) then return false end
    local ok, shown = pcall(f.IsShown, f)
    return (ok and shown) and true or false
end

function ProfUI.RunShoplist(ownerKey, profKey)
    if not enabled() then
        ns:Print("the professions module is disabled.")
        return false
    end
    if not (ownerKey and profKey) then
        ns:Print("shopping list: select a character and profession first, or use "
            .. "/nexus profs shoplist <character> [profession].")
        return false
    end
    local payload = payloadLookup()(ownerKey)
    local rows, pendingItems, state, missingN =
        ProfUI.ShoplistRows(payload, profKey, ProfUI.LiveResolver(), ProfUI.LiveItemInfo())
    -- Cold teaching items: ONE bounded warm-load request per id (class 4's fix
    -- shape — ask, never guess). No ladder here on purpose: the brief's rule
    -- is that re-running the list is the retry.
    if #pendingItems > 0 then ProfUI.AskFor("item", pendingItems) end
    local lines = ProfUI.ShoplistLines(ownerKey, profKey, rows, state, missingN)
    for i = 1, #lines do ns:Print(lines[i]) end
    -- The Raid Prep hand-off, verbatim in spirit: with Auctionator loaded and
    -- the AH open, the resolved names fill the Shopping tab. Everything
    -- defensive — a missing API is a quiet no (the chat list already stands).
    local terms = ProfUI.ShoplistSearchTerms(rows)
    if #terms > 0 and ProfUI.AHIsShown()
        and _G.Auctionator and Auctionator.API and Auctionator.API.v1
        and Auctionator.API.v1.MultiSearchExact then
        pcall(Auctionator.API.v1.MultiSearchExact, "Daseeki Nexus", terms)
        ns:Print("sent " .. #terms .. " name(s) to Auctionator's Shopping tab.")
    end
    return true
end

-- `/nexus profs shoplist [character] [profession]` — the module-owned
-- subcommand idiom (core.lua's dispatcher; import.lua registers the same way).
-- Defaults ride the pane's persisted selection, then the player's own
-- character; a character holding exactly one browsable profession needs no
-- second argument.
ns:RegisterSubcommand("profs", function(rest)
    rest = tostring(rest or ""):match("^%s*(.-)%s*$") or ""
    local verb, args = rest:match("^(%S*)%s*(.-)$")
    verb = (verb or ""):lower()
    if verb ~= "shoplist" then
        ns:Print("usage: /nexus profs shoplist [character] [profession]")
        return
    end
    if not enabled() then
        ns:Print("the professions module is disabled.")
        return
    end
    local sel = thePane and thePane.sel or nil
    local owner, profKey, err = ProfUI.ShoplistTarget(args, ProfUI.Roster(),
        payloadLookup(), { owner = sel and sel.owner, prof = sel and sel.profKey })
    if not (owner and profKey) then
        ns:Print("shopping list: " .. (err or "could not resolve a character and profession."))
        return
    end
    ProfUI.RunShoplist(owner, profKey)
end, "professions shopping list (missing AH-tradable recipes)")

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
    -- The recipe-tooltip session record: which render mode is winning, and the
    -- enchant-hyperlink verdict this client earned.
    local tw = ProfUI._tipEnchantWorks
    ns:Print(string.format("  recipe tooltips: enchant %d / item %d / facts %d; "
        .. "enchant hyperlink: %s",
        ProfUI._tipStats.enchant, ProfUI._tipStats.item, ProfUI._tipStats.facts,
        (tw == true and "works") or (tw == false and "REFUSED (latched off)") or "untested"))
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

    -- Layout maths. At or above the natural width the columns sit at their
    -- LAYOUT pitch — the constants still mean what they say.
    local nat = ProfUI.GridColumns(ProfUI.GridWidth() + 50)
    ck(nat.prim[1].x == L.NAME_W, "the first primary column moved off the name column")
    ck(nat.prim[2].x - nat.prim[1].x == L.CELL_W + L.CELL_GAP,
       "the second primary column is mis-pitched")
    ck(nat.sec.firstaid.x - nat.sec.cooking.x == L.SEC_W + L.SEC_GAP,
       "the secondary chips are mis-pitched")
    ck(nat.width == ProfUI.GridWidth(), "extra pane width grew the columns past natural")
    ck(nat.sec.poisons == nil, "a poisons column crept back into the grid geometry")
    ck(ProfUI.GridRowY(3) == 2 * L.ROW_H, "the grid row pitch is not ROW_H")

    -- MULTI-WIDTH FIT — the overflow lesson. The previous pass asserted the
    -- fit at exactly ONE assumed host width and the live pane still escaped;
    -- now the columns are a function of the real pane width, and the fit is
    -- exercised at several shell widths (the default 1120, the owner's
    -- screenshot-scale 1362, and two harsher ones) plus both conservation
    -- rules, both axes.
    local SHELL_PAD = 12     -- ui_shell: the non-characters tab host inset per side
    for _, shellW in ipairs({ 1120, 1362, 900, 700 }) do
        local hostW = shellW - 2 * SHELL_PAD
        local gw, rw = ProfUI.SplitWidths(hostW)
        ck(gw + rw + L.GUTTER == hostW,
           "the pane split does not conserve the body width at shell " .. shellW)
        local availW = gw - 2 * L.PANEL_PAD
        local cols = ProfUI.GridColumns(availW)
        ck(cols.width <= math.max(availW, 0),
           "the grid columns overflow their pane at shell " .. shellW
           .. " (" .. cols.width .. " > " .. availW .. ")")
    end
    -- Below the natural width every column shrinks (and still fits).
    local small = ProfUI.GridColumns(400)
    ck(small.width <= 400, "a 400px pane did not contain the columns")
    ck(small.name.w < L.NAME_W and small.prim[1].w < L.CELL_W and small.sec.fishing.w < L.SEC_W,
       "a narrow pane did not shrink the columns")
    for _, bodyH in ipairs({ 560, 820 }) do
        local dh, chh = ProfUI.RightSplitHeights(bodyH)
        ck(dh + chh + L.GUTTER == bodyH,
           "the right-column split does not conserve its height at " .. bodyH)
        ck(dh == math.floor((bodyH - L.GUTTER) * L.DETAIL_FRACTION + 0.5),
           "the detail pane is not DETAIL_FRACTION of the column")
    end
    local zg, zr = ProfUI.SplitWidths(0)
    ck(zg == 0 and zr == 0, "a zero-width body produced a negative pane")
    local zd, zc = ProfUI.RightSplitHeights(0)
    ck(zd == 0 and zc == 0, "a zero-height column produced a negative pane")
    ck(ProfUI.GridColumns(0).width == 0, "a zero-width pane produced columns anyway")

    -- Level ink, the owner's rule: current level ONLY (no /max), green at the
    -- Era cap, yellow below it, an em dash — never 0 — when never recorded.
    local lt, li = ProfUI.LevelInk(300)
    ck(lt == "300" and li == "ok", "the Era-cap level did not ink green")
    lt, li = ProfUI.LevelInk(299)
    ck(lt == "299" and li == "warn", "a below-cap level did not ink yellow")
    lt, li = ProfUI.LevelInk(nil)
    ck(lt == "\226\128\148" and li == "faint", "an unrecorded level did not render as the em dash")

    -- THE HEADER ROW PIN (owner's rework): CHARACTER | PRIMARY | PRIMARY |
    -- COOKING | FIRST AID | FISHING — full names, and NO POISONS column. The
    -- poisons DATA still travels (it is still a classified secondary, so it
    -- still costs no primary slot and still reaches the detail pane's tab).
    local heads = ProfUI.GridHeaderLabels()
    local wantHeads = { "CHARACTER", "PRIMARY", "PRIMARY", "COOKING", "FIRST AID", "FISHING" }
    ck(#heads == #wantHeads, "the grid header count changed (" .. #heads .. ")")
    for i = 1, #wantHeads do
        ck(heads[i] == wantHeads[i], "grid header " .. i .. " reads "
           .. tostring(heads[i]) .. ", wanted " .. wantHeads[i])
    end
    for i = 1, #heads do
        ck(heads[i] ~= "POISONS", "the POISONS column is back in the grid header")
    end
    local gridHasPoisons = false
    for _, key in ipairs(ProfUI.GRID_SECONDARIES) do
        if key == "poisons" then gridHasPoisons = true end
    end
    ck(not gridHasPoisons, "poisons is still a grid column")
    ck(ProfUI.IsSecondary("poisons"),
       "poisons stopped being classified a secondary (the detail tab and the "
       .. "primaries-slot rule both need it)")
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

local function testDetailAndKinds(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local NOW = 1700000000

    -- DETAIL TABS: one per profession the character actually holds, primaries
    -- leading — and Poisons ONLY for the character whose payload carries it.
    local rogue = { p = { poisons = { l = 300, m = 300 }, alchemy = { l = 240, m = 300 },
                          cooking = { l = 150, m = 225 } }, c = {} }
    local mage  = { p = { tailoring = { l = 300, m = 300 }, enchanting = { l = 285, m = 300 },
                          fishing = { l = 75, m = 150 } }, c = {} }
    local rt = ProfUI.DetailTabs(rogue)
    ck(#rt == 3, "the rogue's tab count is wrong (" .. #rt .. ")")
    ck(rt[1] == "alchemy", "primaries do not lead the tab strip")
    local sawPoisons = false
    for _, k in ipairs(rt) do if k == "poisons" then sawPoisons = true end end
    ck(sawPoisons, "the rogue did not get a Poisons tab")
    -- The mage HOLDS fishing, but fishing carries zero dataset recipes, so it
    -- earns NO tab (the owner's "Fishing doesnt need a tab", data-driven).
    local mt = ProfUI.DetailTabs(mage)
    ck(#mt == 2, "the mage's tab count is wrong (" .. #mt .. ")")
    for _, k in ipairs(mt) do
        ck(k ~= "poisons", "a non-rogue grew a Poisons tab")
        ck(k ~= "fishing", "a zero-recipe profession earned a detail tab")
    end
    ck(#ProfUI.DetailTabs(nil) == 0, "no payload still produced tabs")

    -- Losing the COLUMN did not lose the CAPTURE: the grid model still carries
    -- poisons among the secondaries (the tooltip path and the detail pane read
    -- it from there) — the renderer just paints no column for it.
    local rrow = ProfUI.GridRow({ nameRealm = "R-Realm", rec = { classTag = "ROGUE" } }, rogue, NOW)
    ck(rrow.secondaries.poisons ~= nil,
       "the poisons DATA fell out of the grid model (it lost its column, not its capture)")
    ck(rrow.secondaries.poisons and rrow.secondaries.poisons.level == 300,
       "the poisons cell model lost its level")

    -- The tab strip fits its real width, whatever that width is.
    local tl = ProfUI.DetailTabLayout(400, 6)
    ck(#tl.xs == 6, "the tab layout lost a tab")
    ck(tl.xs[6] + tl.w <= 400, "the tab strip overflows its pane")
    ck(ProfUI.DetailTabLayout(600, 2).w <= L.DTAB_MAX,
       "two tabs in a wide strip did not cap at DTAB_MAX")
    ck(ProfUI.DetailTabLayout(400, 0).w == 0, "zero tabs produced a tab width")

    -- COOLDOWN KIND ROWS: kinds enumerate from the payloads (never a hardcoded
    -- list), each row names ONLY the characters ready right now, in roster
    -- order and carrying class tags; a character mid-cooldown is not listed; a
    -- kind nobody owns is not a row.
    local payloads = {
        ["Aaa-Realm"] = { p = {}, c = { ["999"] = NOW - 5, ["g1"] = NOW + 3600 } },
        ["Bbb-Realm"] = { p = {}, c = { ["999"] = NOW + 60 } },
        ["Ccc-Realm"] = { p = {}, c = { ["999"] = NOW - 100 } },
    }
    local kinds = ProfUI.CooldownKindRows(fixtureEntries(), function(k) return payloads[k] end,
                                          NOW, fakeResolver({ [999] = "Mooncloth" }))
    ck(#kinds == 2, "three cooldown instances did not fold into two kinds (" .. #kinds .. ")")
    local moon, shared
    for _, k in ipairs(kinds) do
        if k.cdKey == "999" then moon = k elseif k.cdKey == "g1" then shared = k end
    end
    ck(moon ~= nil and shared ~= nil, "a cooldown kind vanished")
    ck(moon and moon.label == "Mooncloth", "the kind row did not wear the recipe name")
    ck(moon and moon.owners == 3, "the kind's owner count is wrong")
    ck(moon and #moon.ready == 2, "the ready list is wrong ("
       .. tostring(moon and #moon.ready) .. ")")
    if moon and #moon.ready == 2 then
        ck(moon.ready[1].key == "Aaa-Realm" and moon.ready[2].key == "Ccc-Realm",
           "the ready names are not in roster order")
        for _, r in ipairs(moon.ready) do
            ck(r.key ~= "Bbb-Realm", "a character still ON cooldown was listed as ready")
        end
        ck(moon.ready[1].classTag == "MAGE", "a ready name lost its class tag")
    end
    ck(shared and shared.owners == 1, "the shared-group kind lost its owner")
    ck(shared and #shared.ready == 0, "a kind with nobody ready invented ready names")

    -- Determinism (class 8): two walks of the same store, same order.
    local again = ProfUI.CooldownKindRows(fixtureEntries(), function(k) return payloads[k] end,
                                          NOW, fakeResolver({ [999] = "Mooncloth" }))
    ck(#again == #kinds, "two walks disagreed on the kind count")
    for i = 1, math.min(#kinds, #again) do
        if kinds[i].cdKey ~= again[i].cdKey then
            fails[#fails + 1] = "two walks of the same store ordered the kinds differently"
            break
        end
    end

    -- A cold kind name is PENDING — held, never guessed (the Bags lesson).
    local coldKinds = ProfUI.CooldownKindRows(fixtureEntries(), function(k) return payloads[k] end,
                                              NOW, fakeResolver({}))
    local coldMoon
    for _, k in ipairs(coldKinds) do if k.cdKey == "999" then coldMoon = k end end
    ck(coldMoon ~= nil and coldMoon.pending == true and coldMoon.label == nil,
       "a cold kind name was not held as pending")
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

local function testDetailRework(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local D = core()
    if not D then fails[#fails + 1] = "dataset unavailable for the rework tests" return end

    ------------------------------------------------------------------
    -- GLYPH PINS. The two sequences that shipped as tofu boxes (the spec
    -- diamond, the known check mark) may never come back — not in the
    -- registry, not in the pure outputs, and under the harness not anywhere
    -- in this file's source, in either raw-UTF-8 or decimal-escape form.
    ------------------------------------------------------------------
    ck(ProfUI.GLYPHS.spec == string.char(226, 151, 138),
       "the spec marker is not the in-font lozenge U+25CA")
    ck(ProfUI.GLYPHS.known == string.char(226, 151, 143),
       "the known marker is not the in-font dot U+25CF")
    for _, bad in ipairs(ProfUI.BANNED_GLYPH_BYTES) do
        local raw = string.char(bad[1], bad[2], bad[3])
        local esc = "\\" .. bad[1] .. "\\" .. bad[2] .. "\\" .. bad[3]
        for key, g in pairs(ProfUI.GLYPHS) do
            if tostring(g):find(raw, 1, true) then
                fails[#fails + 1] = "GLYPHS." .. key .. " carries the banned " .. bad.name
            end
        end
        -- Pure outputs that carry markers.
        local lvl = ProfUI.LevelInk(nil) or ""
        local cen = ProfUI.CensusText({ total = 5, scanned = false }) or ""
        ck(not lvl:find(raw, 1, true), "LevelInk emits the banned " .. bad.name)
        ck(not cen:find(raw, 1, true), "CensusText emits the banned " .. bad.name)
        -- The whole-file scan: harness only (io exists there; the client has
        -- no file access, and the registry/output pins above still hold).
        if io and io.open and debug and debug.getinfo then
            local src = debug.getinfo(ProfUI.CensusText, "S").source or ""
            local path = src:match("^@(.*)$")
            local fh = path and io.open(path, "rb")
            if fh then
                local text = fh:read("*a") or ""
                fh:close()
                ck(not text:find(raw, 1, true),
                   "this file carries the banned " .. bad.name .. " as raw bytes")
                ck(not text:find(esc, 1, true),
                   "this file carries the banned " .. bad.name .. " as decimal escapes")
            end
        end
    end

    ------------------------------------------------------------------
    -- WINDOWLESS PROFESSIONS — the zero-recipe rule, data-driven.
    ------------------------------------------------------------------
    ck(ProfUI.RecipeCount("fishing") == 0, "fishing grew dataset recipes")
    ck(ProfUI.RecipeCount("herbalism") == 0, "herbalism grew dataset recipes")
    ck(ProfUI.RecipeCount("skinning") == 0, "skinning grew dataset recipes")
    ck(ProfUI.HasBrowsableRecipes("fishing") == false, "fishing claims a browsable window")
    ck(ProfUI.HasBrowsableRecipes("herbalism") == false, "herbalism claims a browsable window")
    ck(ProfUI.HasBrowsableRecipes("skinning") == false, "skinning claims a browsable window")
    -- Mining is the deliberate NON-member: the dataset carries its Smelting
    -- recipes, so mining KEEPS its tab. The rule is the count, not the name.
    ck(ProfUI.RecipeCount("mining") > 0, "mining lost its Smelting recipes")
    ck(ProfUI.HasBrowsableRecipes("mining") == true, "mining lost its tab despite Smelting")
    ck(ProfUI.HasBrowsableRecipes("cooking") == true, "cooking lost its tab")
    ck(ProfUI.HasBrowsableRecipes("no-such-profession") == true,
       "an unknown key was silently hidden instead of failing open")

    -- The Senche case: Skinning remembered/selected, and the character's tabs
    -- no longer offer it — the fallback lands on the first eligible tab.
    local senche = { p = { skinning = { l = 300, m = 300 }, herbalism = { l = 225, m = 300 },
                          alchemy = { l = 265, m = 300 }, fishing = { l = 40, m = 150 } }, c = {} }
    local tabs = ProfUI.DetailTabs(senche)
    ck(#tabs == 1 and tabs[1] == "alchemy",
       "skinning/herbalism/fishing leaked into the tab strip (" .. #tabs .. ")")
    ck(ProfUI.ResolveDetailTab(tabs, "skinning") == "alchemy",
       "a remembered excluded tab did not fall back to the first eligible one")
    ck(ProfUI.ResolveDetailTab(tabs, "alchemy") == "alchemy",
       "an eligible remembered tab was not kept")
    ck(ProfUI.ResolveDetailTab({}, "skinning") == nil,
       "no eligible tabs still resolved a tab")

    -- No census, no "not checked", for a zero-recipe profession — the level
    -- alone is the whole truth. A recipe-bearing profession keeps both forms.
    local fishCell = ProfUI.CellModel(senche, "fishing", 1700000000)
    ck(fishCell ~= nil and fishCell.total == 0, "the fishing cell lost its zero-recipe fact")
    ck(ProfUI.CensusText(fishCell) == nil,
       "a zero-recipe profession still renders a census / 'not checked' line")
    local ct, ci = ProfUI.CensusText({ total = 81, scanned = true, known = 12 })
    ck(ct == "12/81" and ci == "muted", "a scanned census stopped rendering known/total")
    local ut, ui2 = ProfUI.CensusText({ total = 81, scanned = false })
    ck(ut == ProfUI.GLYPHS.dash .. " not checked" and ui2 == "faint",
       "an unscanned recipe-bearing profession lost its 'not checked' line")

    ------------------------------------------------------------------
    -- ABSENT SECONDARY: the "--" placeholder, faint, and only for absence.
    ------------------------------------------------------------------
    local at, ai = ProfUI.SecondaryCellText(nil)
    ck(at == "--" and ai == "faint",
       "an absent secondary does not render the faint '--' placeholder")
    local lt2, li2 = ProfUI.SecondaryCellText({ level = 300 })
    ck(lt2 == "300" and li2 == "ok", "a learned secondary stopped rendering its level")
    local nt, ni = ProfUI.SecondaryCellText({ level = nil })
    ck(nt == ProfUI.GLYPHS.dash and ni == "faint",
       "a learned-but-unrecorded secondary lost its em-dash state")

    ------------------------------------------------------------------
    -- THE FREED SPACE: retiring the materials band (132px) shrank the info
    -- band to content and the recipe list owns the difference. The two-line
    -- acquisition text (2026-08-10) then bought ONE line of it back — the
    -- band grew by exactly one ACQ_LINE_H over its one-line form (44) — so
    -- the list's net gain over the materials era is now at least THREE rows
    -- (it was four when the acquisition still truncated at one line).
    ------------------------------------------------------------------
    ck(ProfUI.RecipeListBottomInset() == L.INFO_H + L.PANEL_PAD + 4,
       "the list's bottom inset drifted off the LAYOUT reader")
    local RETIRED_MATERIALS_BAND = 132
    local ONE_LINE_INFO_BAND     = 44
    ck(L.INFO_H < RETIRED_MATERIALS_BAND,
       "the info band grew back toward the retired materials height")
    ck(math.floor((RETIRED_MATERIALS_BAND - L.INFO_H) / L.LIST_ROW_H) >= 3,
       "the recipe list did not keep at least three rows of the retired band")
    ck(L.INFO_H == ONE_LINE_INFO_BAND + L.ACQ_LINE_H,
       "the info band did not grow by exactly one acquisition line over its "
       .. "one-line form (the list must yield exactly that height, no more)")

    -- The acquisition text's two-line contract: the LAYOUT budget is two
    -- lines, and the pure reader the VIEW sizes the FontString with returns
    -- exactly that budget — the only observables the headless sim offers
    -- (the harness never builds frames), and the ones the view consumes.
    ck(L.ACQ_LINES == 2,
       "the acquisition text's line budget is not two lines")
    ck(ProfUI.AcqTextHeight() == L.ACQ_LINES * L.ACQ_LINE_H,
       "AcqTextHeight drifted off the ACQ_LINES \195\151 ACQ_LINE_H contract")
    ck(ProfUI.AcqTextHeight() > L.ACQ_LINE_H,
       "the acquisition FontString's height holds fewer than two lines")

    ------------------------------------------------------------------
    -- ACQUISITION LINES WITH ZONES — fixture first, then the real dataset.
    ------------------------------------------------------------------
    local FD = {
        zone  = { [1] = { name = "Badlands" }, [2] = { name = "Westfall" } },
        npc   = { [10] = { zone = 1, name = "Dan Golthas" },
                  [11] = { zone = 2, name = "Kriggon Talsone" },
                  [12] = { name = "Wandering Trader" } },
        quest = { [22] = { name = "Goretusk Liver Pie", givers = "11" },
                  [40] = { name = "The Spectral Chalice", givers = "-" } },
    }
    ck(ProfUI.VendorPhrase(FD, "10") == "Sold by Dan Golthas \226\128\148 Badlands",
       "the single-vendor line is not 'Sold by <name> \226\128\148 <zone>'")
    ck(ProfUI.VendorPhrase(FD, "10+11+12") ==
       "Sold by Dan Golthas \226\128\148 Badlands, Kriggon Talsone \226\128\148 Westfall +1 more",
       "the multi-vendor line does not name " .. ProfUI.VENDOR_NAMES .. " then '+N more'")
    ck(ProfUI.VendorPhrase(FD, "12") == "Sold by Wandering Trader",
       "a zone-less vendor invented a zone")
    ck(ProfUI.VendorPhrase(FD, "999") == "Sold by ?",
       "an unindexed vendor NPC did not degrade to '?'")
    ck(ProfUI.QuestPhrase(FD, 22) == "Quest: Goretusk Liver Pie \226\128\148 Westfall",
       "the quest line is not 'Quest: <name> \226\128\148 <zone>'")
    ck(ProfUI.QuestPhrase(FD, 40) == "Quest: The Spectral Chalice",
       "a giver-less quest invented a zone")
    ck(ProfUI.QuestPhrase(FD, 12345) == "Quest: ?",
       "an unindexed quest did not degrade to '?'")

    -- The real dataset speaks the owner's own example, through the same path
    -- the info band renders: quest 22's giver stands in Westfall.
    local SD = sourcesDS()
    if not SD then fails[#fails + 1] = "the source graph would not load for the zone tests" return end
    ck(ProfUI.QuestPhrase(SD, 22) == "Quest: Goretusk Liver Pie \226\128\148 Westfall",
       "the shipped dataset does not resolve quest 22 to Westfall ("
       .. tostring(ProfUI.QuestPhrase(SD, 22)) .. ")")

    -- Every shipped vendor token must produce a zoned "Sold by" phrase (the
    -- referential gate guarantees every [npc] row carries a zone ordinal), and
    -- at least one recipe-item must exercise the "+N more" overflow. World
    -- drops keep their existing note untouched.
    local vendors, zoned, overflowed, worldDrops = 0, 0, 0, 0
    for itemID, acq in pairs(SD.itemAcq or {}) do
        for tok in (tostring(acq) .. ";"):gmatch("(.-);") do
            local npcs = tok:match("^V%d+@([%d%+]+)$")
            if npcs then
                vendors = vendors + 1
                local phrase = ProfUI.VendorPhrase(SD, npcs)
                if phrase:find("^Sold by ") and phrase:find("\226\128\148", 1, true) then
                    zoned = zoned + 1
                end
                local ids = 0
                for _ in npcs:gmatch("%d+") do ids = ids + 1 end
                if ids > ProfUI.VENDOR_NAMES then
                    if phrase:find("%+%d+ more") then overflowed = overflowed + 1 end
                end
            elseif tok:find("^W%d") then
                worldDrops = worldDrops + 1
            end
        end
    end
    ck(vendors > 0, "the dataset stopped carrying vendor routes")
    ck(zoned == vendors, (vendors - zoned) .. " of " .. vendors
       .. " vendor phrases came out without a zone")
    ck(overflowed > 0, "no multi-vendor recipe exercised the '+N more' overflow")
    ck(worldDrops > 0, "the dataset stopped carrying world-drop routes")

    -- A world-drop teaching item still reads with its untouched note.
    for itemID, acq in pairs(SD.itemAcq or {}) do
        local lo, hi = tostring(acq):match("W(%d+)%-(%d+)")
        if lo then
            local spell = SD.itemOfRecipe and SD.itemOfRecipe[itemID]
            local m = spell and ProfUI.SourceModel(spell)
            if m then
                local all = table.concat(m.lines, "; ")
                ck(all:find("World drop (mobs ", 1, true) ~= nil,
                   "the world-drop note changed shape (" .. all .. ")")
            end
            break
        end
    end
end

----------------------------------------------------------------------
-- Suite: the grid filter chips (owner, 2026-08-10 — "same filters, minus
-- summoners"). Pure predicates, the cards-parity pins, the selection-survives
-- contract, the persistence heal, and the chip bar's layout cost.
----------------------------------------------------------------------
local function testGridChips(fails)
    local function ck(cond, msg) if not cond then fails[#fails + 1] = msg end end
    local L = ProfUI.LAYOUT

    -- Chip roster: exactly 60s + Online, in that order, and NO summoners chip
    -- (the owner's explicit "minus summoners" — it is a world-buff-roster
    -- concept with no professions meaning).
    ck(#ProfUI.GRID_FILTER_DEFS == 2, "the chip roster is not exactly two chips")
    ck(ProfUI.GRID_FILTER_DEFS[1].key == "60s" and ProfUI.GRID_FILTER_DEFS[2].key == "online",
       "the chip roster is not 60s then Online")
    for _, def in ipairs(ProfUI.GRID_FILTER_DEFS) do
        ck(def.key ~= "summoners", "the summoners chip leaked into the professions tab")
    end

    -- The predicate matrix over the fixture roster: a 60 online, a 60 offline,
    -- a 42 offline.
    local entries = fixtureEntries()
    ck(#ProfUI.FilterEntries(entries, nil) == 3, "no chip active did not show everyone")
    local sixties = ProfUI.FilterEntries(entries, "60s")
    ck(#sixties == 2 and sixties[1].nameRealm == "Aaa-Realm" and sixties[2].nameRealm == "Bbb-Realm",
       "the 60s chip did not keep exactly the two 60s in roster order")
    local online = ProfUI.FilterEntries(entries, "online")
    ck(#online == 1 and online[1].nameRealm == "Aaa-Realm",
       "the Online chip did not keep exactly the online character")
    ck(ProfUI.GridFilterMatch(entries[3], "60s") == false, "a 42 passed the 60s chip")
    ck(ProfUI.GridFilterMatch(entries[2], "online") == false, "an offline 60 passed the Online chip")
    ck(ProfUI.GridFilterMatch(entries[3], nil) == true, "nil filter rejected a character")

    -- PARITY: the two tabs' predicates and transitions may never drift. The
    -- harness always loads ui_cards.lua, so the delegate path is the live one;
    -- this pins delegate == the fallback's own answers AND the transition
    -- table against Cards.NextFilter.
    local Cards = ns.Cards
    ck(Cards and Cards.FilterMatch ~= nil, "ns.Cards.FilterMatch missing under the harness")
    if Cards and Cards.FilterMatch then
        for _, e in ipairs(entries) do
            for _, f in ipairs({ "60s", "online" }) do
                ck(ProfUI.GridFilterMatch(e, f) == (Cards.FilterMatch(e, f) and true or false),
                   "chip predicate drifted from the cards' for " .. e.nameRealm .. "/" .. f)
            end
        end
    end
    ck(ProfUI.NextGridFilter(nil, "60s") == "60s", "click from none did not select")
    ck(ProfUI.NextGridFilter("60s", "60s") == nil, "click the active chip did not clear")
    ck(ProfUI.NextGridFilter("60s", "online") == "online", "click another chip did not switch")
    if Cards and Cards.NextFilter then
        for _, cur in ipairs({ "60s", "online" }) do
            for _, clk in ipairs({ "60s", "online" }) do
                ck(ProfUI.NextGridFilter(cur, clk) == Cards.NextFilter(cur, clk),
                   "chip transition drifted from Cards.NextFilter (" .. cur .. "->" .. clk .. ")")
            end
        end
        ck(ProfUI.NextGridFilter(nil, "online") == Cards.NextFilter(nil, "online"),
           "chip transition drifted from Cards.NextFilter (none->online)")
    end

    -- SELECTION SURVIVES FILTERING: the 42 selected, the 60s chip active —
    -- hidden (the detail pane's hint case), NOT deselected; clearing the chip
    -- re-admits them with the selection intact (nothing here ever wrote the
    -- selection, which is the whole mechanism).
    ck(ProfUI.SelectionHiddenByFilter(entries, "60s", "Ccc-Realm") == true,
       "a chip-hidden selection did not read as hidden")
    ck(ProfUI.SelectionHiddenByFilter(entries, nil, "Ccc-Realm") == false,
       "no chip active still read the selection as hidden")
    ck(ProfUI.SelectionHiddenByFilter(entries, "60s", "Aaa-Realm") == false,
       "a chip-admitted selection read as hidden")
    ck(ProfUI.SelectionHiddenByFilter(entries, "60s", "Zzz-Realm") == false,
       "an owner absent from the roster was blamed on the chip (that case keeps "
       .. "its own empty states)")
    ck(ProfUI.SelectionHiddenByFilter(entries, "60s", nil) == false,
       "no selection still read as hidden")
    local hint = ProfUI.HiddenSelectionHint("Ccc", "60s")
    ck(type(hint) == "string" and hint:find("Ccc", 1, true) ~= nil
       and hint:find("60s", 1, true) ~= nil and hint:find("kept", 1, true) ~= nil,
       "the hidden-selection hint does not name the character, the chip, and the keeping")
    ck(ProfUI.HiddenSelectionHint("Ccc", nil) == nil,
       "a hint was invented with no chip active")

    -- ZERO VISIBLE ROWS: the empty line names the active chip and the way out;
    -- with no chip it keeps the original never-recorded wording.
    local et = ProfUI.GridEmptyText("online")
    ck(type(et) == "string" and et:find("Online", 1, true) ~= nil
       and et:find("again", 1, true) ~= nil,
       "the filtered empty state does not name the chip and the way out")
    ck(ProfUI.GridEmptyText(nil):find("No professions recorded yet", 1, true) ~= nil,
       "the unfiltered empty state lost its original wording")

    -- PERSISTENCE HEAL: only a real chip key survives the round-trip; the ""
    -- none-sentinel, the never-offered summoners, and garbage all heal to nil.
    ck(ProfUI.ValidGridFilter("60s") == "60s", "60s did not survive persistence")
    ck(ProfUI.ValidGridFilter("online") == "online", "online did not survive persistence")
    ck(ProfUI.ValidGridFilter("") == nil, "the none-sentinel did not heal to nil")
    ck(ProfUI.ValidGridFilter("summoners") == nil,
       "a persisted summoners filter survived onto a tab that has no such chip")
    ck(ProfUI.ValidGridFilter(nil) == nil, "nil did not heal to nil")
    ck(ProfUI.ValidGridFilter(42) == nil, "a non-string healed to something")

    -- LAYOUT: the chip bar is the cards' 44px band (one shared rhythm), the
    -- header and list insets flow through the pure readers, and the bar costs
    -- the grid at most one-and-a-fraction 32px rows.
    ck(L.CHIP_H == 44, "the chip bar drifted off the cards' 44px band")
    ck(ProfUI.GridHeaderTopInset() == L.CHIP_H + L.PANEL_PAD,
       "the grid header inset drifted off the LAYOUT reader")
    ck(ProfUI.GridListTopInset() == L.CHIP_H + L.PANEL_PAD + L.HEAD_H + 2,
       "the grid list inset drifted off the LAYOUT reader")
    ck(L.CHIP_H < 2 * L.ROW_H,
       "the chip bar costs the grid two or more full rows")
end

----------------------------------------------------------------------
-- Suite: the recipe hover tooltip (owner, 2026-08-10: "recipes in the
-- professions tab show their tooltip when hovered over") — the enchant/item/
-- facts chain, the session latch, cold-item honesty (class 4), pooled-row
-- hygiene. Everything drives ProfUI.* with a RECORDING tooltip (the parity
-- gate's idiom); the view's handlers are thin delegates over these functions.
----------------------------------------------------------------------
local function makeRecordingTip(behavior)
    -- behavior[kind] = "render" (title+body) | "title" (cold: title only)
    --                | "empty" (renders nothing) | "error" (client refuses)
    local tip = { lines = {}, owner = nil, shown = false, hides = 0, hyperlinks = {} }
    function tip:SetOwner(o, anchor) self.owner = o; self.anchor = anchor end
    function tip:SetHyperlink(link)
        self.hyperlinks[#self.hyperlinks + 1] = tostring(link)
        local kind = tostring(link):match("^(%a+):")
        local b = behavior and behavior[kind]
        if b == "error" then error("refused " .. tostring(link)) end
        if b == "render" then
            self.lines[#self.lines + 1] = "title " .. tostring(link)
            self.lines[#self.lines + 1] = "body " .. tostring(link)
        elseif b == "title" then
            self.lines[#self.lines + 1] = "title " .. tostring(link)
        end
    end
    function tip:NumLines() return #self.lines end
    function tip:ClearLines() self.lines = {} end
    function tip:AddLine(text) self.lines[#self.lines + 1] = tostring(text) end
    function tip:Show() self.shown = true end
    function tip:Hide()
        self.hides = self.hides + 1; self.shown = false
        self.lines = {}; self.owner = nil
    end
    function tip:GetOwner() return self.owner end
    return tip
end

local function testRecipeTooltips(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedWorks, savedStats = ProfUI._tipEnchantWorks, ProfUI._tipStats
    ProfUI._tipStats = { enchant = 0, item = 0, facts = 0 }

    local row = { spell = 12345, item = 777, name = "Fixture Robe", state = "missing",
                  skill = 250, source = "Trainer" }

    -- 1) the enchant hyperlink renders: that mode wins and latches true.
    ProfUI._tipEnchantWorks = nil
    local tip = makeRecordingTip({ enchant = "render" })
    local rr = { _row = row, _spell = row.spell }
    local mode = ProfUI.RowTooltipEnter(tip, rr, fakeResolver({}))
    ck(mode == "enchant", "a working enchant hyperlink did not win (" .. tostring(mode) .. ")")
    ck(tip.owner == rr and tip.anchor == "ANCHOR_RIGHT",
       "the tooltip did not anchor ANCHOR_RIGHT on its row (the suite idiom)")
    ck(tip.shown and #tip.lines > 0, "the enchant mode left no visible tooltip")
    ck(ProfUI._tipEnchantWorks == true, "a working enchant hyperlink did not latch true")
    ck(ProfUI._tipStats.enchant == 1, "the enchant win was not recorded")

    -- 2) the enchant hyperlink ERRORS: fall to the teaching item, latch false,
    --    and never try enchant again this session (consistent per session).
    ProfUI._tipEnchantWorks = nil
    tip = makeRecordingTip({ enchant = "error", item = "render" })
    mode = ProfUI.RowTooltipEnter(tip, { _row = row }, fakeResolver({}))
    ck(mode == "item", "a refused enchant did not fall through to the item tooltip")
    ck(ProfUI._tipEnchantWorks == false, "a refused enchant hyperlink did not latch false")
    ck(#tip.lines > 0, "the item fallback left no visible tooltip")
    local tip2 = makeRecordingTip({ enchant = "render", item = "render" })
    ProfUI.RowTooltipEnter(tip2, { _row = row }, fakeResolver({}))
    for _, l in ipairs(tip2.hyperlinks) do
        ck(not l:find("^enchant:"),
           "the session latch did not stick: enchant was re-tried after failing")
    end

    -- 3) enchant renders EMPTY (no error): the same fall-through and latch.
    ProfUI._tipEnchantWorks = nil
    tip = makeRecordingTip({ enchant = "empty", item = "render" })
    mode = ProfUI.RenderRecipeTooltip(tip, row, fakeResolver({}))
    ck(mode == "item", "an empty enchant render was allowed to stand")
    ck(ProfUI._tipEnchantWorks == false, "an empty enchant render did not latch false")

    -- 4) COLD ITEM (class 4): a title-only item tooltip is not an answer —
    --    the dataset facts render instead, a warm load is requested, and the
    --    failure does NOT latch anything (the re-hover is the retry, no ladder).
    ProfUI._tipEnchantWorks = false          -- enchant already proven broken
    local asked = {}
    tip = makeRecordingTip({ item = "title" })
    mode = ProfUI.RenderRecipeTooltip(tip, row, fakeResolver({}),
        function(kind, ids) asked[#asked + 1] = { kind = kind, id = ids and ids[1] } end)
    ck(mode == "facts", "a title-only (cold) item tooltip was allowed to stand")
    ck(#asked == 1 and asked[1].kind == "item" and asked[1].id == 777,
       "a cold item tooltip did not request a warm load")
    ck(#tip.lines > 0, "the cold fallback left a BLANK tooltip standing")
    local blob = table.concat(tip.lines, "\n")
    ck(blob:find("Fixture Robe", 1, true) ~= nil and blob:find("250", 1, true) ~= nil
       and blob:find("Trainer", 1, true) ~= nil,
       "the facts tooltip lost the name/skill/source strings (" .. blob .. ")")

    -- 5) no teaching item and enchant broken: straight to facts; a cold NAME
    --    still renders an honest identity line, never a blank tooltip.
    local bare = { spell = 999 }
    tip = makeRecordingTip({})
    mode = ProfUI.RenderRecipeTooltip(tip, bare, fakeResolver({}))
    ck(mode == "facts" and #tip.lines > 0,
       "a bare row (no item, no name) rendered a blank tooltip")
    ck(table.concat(tip.lines, "\n"):find("999", 1, true) ~= nil,
       "the bare facts tooltip does not even identify the recipe")

    -- 6) the plan itself honours the latch and the missing item.
    ProfUI._tipEnchantWorks = nil
    local plan = ProfUI.RecipeTooltipPlan(row)
    ck(#plan == 3 and plan[1].kind == "enchant" and plan[2].kind == "item"
       and plan[3].kind == "facts", "the untested plan is not enchant->item->facts")
    ProfUI._tipEnchantWorks = false
    plan = ProfUI.RecipeTooltipPlan({ spell = 1 })
    ck(#plan == 1 and plan[1].kind == "facts",
       "a latched-broken enchant + itemless row did not reduce to facts alone")

    -- 7) POOLED-ROW HYGIENE (the Daseeki-Bags bank-tooltip lesson): a recycled
    --    row adopting a different recipe hides the tooltip it owns; the same
    --    recipe repainting does not; somebody else's tooltip is never touched.
    ck(ProfUI.TooltipStaleOnPaint(1, 2, true) == true, "recycle+change did not read stale")
    ck(ProfUI.TooltipStaleOnPaint(1, 1, true) == false, "same-recipe repaint read stale")
    ck(ProfUI.TooltipStaleOnPaint(1, 2, false) == false, "an unowned tooltip read stale")
    ProfUI._tipEnchantWorks = true
    tip = makeRecordingTip({ enchant = "render" })
    local rrP = { _row = { spell = 111 }, _spell = 111 }
    ProfUI.RowTooltipEnter(tip, rrP, fakeResolver({}))
    ck(tip.shown, "the recycle fixture never showed a tooltip")
    local hid = ProfUI.RowTooltipOnPaint(tip, rrP, 222)
    ck(hid == true and tip.shown == false and tip.hides == 1,
       "a recycled row left the previous recipe's tooltip standing")
    tip = makeRecordingTip({ enchant = "render" })
    ProfUI.RowTooltipEnter(tip, rrP, fakeResolver({}))
    ck(ProfUI.RowTooltipOnPaint(tip, rrP, 111) == false and tip.shown,
       "a same-recipe repaint hid its own tooltip")
    ck(ProfUI.RowTooltipOnPaint(tip, { _spell = 500 }, 501) == false and tip.shown,
       "a repaint of a DIFFERENT row hid somebody else's tooltip")

    -- 8) OnLeave hides.
    ProfUI.RowTooltipLeave(tip)
    ck(tip.shown == false, "OnLeave did not hide the tooltip")

    -- 9) the view wiring pins (harness-only source scan, the retint-gate
    --    idiom): the row still SELECTS on click — the hover work may not have
    --    touched the click path — and the three hover scripts are wired.
    if io and io.open and debug and debug.getinfo then
        local srcPath = (debug.getinfo(ProfUI.RecipeTooltipPlan, "S").source or ""):match("^@(.*)$")
        local fh = srcPath and io.open(srcPath, "rb")
        if fh then
            local text = fh:read("*a") or ""
            fh:close()
            ck(text:find("pane.SelectRecipe(self._spell)", 1, true) ~= nil,
               "the recipe row's OnClick -> SelectRecipe wiring is gone (click behavior changed)")
            ck(text:find('rr:SetScript("OnEnter"', 1, true) ~= nil
               and text:find('rr:SetScript("OnLeave"', 1, true) ~= nil
               and text:find('rr:SetScript("OnHide"', 1, true) ~= nil,
               "the recipe row's hover scripts are not wired")
        end
    end

    -- 10) the dataset really carries teaching items for the item fallback.
    local D = sourcesDS()
    if D then
        local sawItem = false
        for pIdx = 1, #D.profs do
            local list = D.profRecipes[pIdx]
            for i = 1, math.min(#list, 40) do
                local m = ProfUI.SourceModel(list[i])
                if m and m.teachItem then
                    sawItem = true
                    ck(type(m.teachItem) == "number", "teachItem is not an item id")
                    break
                end
            end
            if sawItem then break end
        end
        ck(sawItem, "no sampled recipe carries a teaching item \226\128\148 the item fallback is dead code")
    end

    ProfUI._tipEnchantWorks, ProfUI._tipStats = savedWorks, savedStats
end

----------------------------------------------------------------------
-- Suite: the recipe list's column header band (owner, 2026-08-10: "add column
-- headers in the Detail list") — the labels, the one-source geometry at
-- multiple widths, and the height cost.
----------------------------------------------------------------------
local function testRecipeHeader(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- The labels, in column order; SKILL right-justifies over its numerals.
    local cells = ProfUI.RecipeHeaderCells(523)
    ck(#cells == 3, "the header row is not three cells (" .. #cells .. ")")
    ck(cells[1].label == "RECIPE" and cells[2].label == "SKILL"
       and cells[3].label == "SOURCE", "the header labels are not RECIPE | SKILL | SOURCE")
    ck(cells[2].justify == "RIGHT",
       "SKILL does not right-justify over its right-justified numerals")

    -- ONE SOURCE: at every width, each caption wears EXACTLY its column's
    -- x/width — the header can never drift off the rows (the grid's lesson).
    -- The widths bracket the real pane: the 700px shell (~313), the default
    -- 1120 (~523), and points between/beyond.
    for _, w in ipairs({ 313, 420, 523, 700 }) do
        local c = ProfUI.RecipeColumns(w)
        local hc = ProfUI.RecipeHeaderCells(w)
        ck(hc[1].x == c.title.x and hc[1].w == c.title.w,
           "RECIPE drifted off the title column at width " .. w)
        ck(hc[2].x == c.skill.x and hc[2].w == c.skill.w,
           "SKILL drifted off the skill column at width " .. w)
        ck(hc[3].x == c.src.x and hc[3].w == c.src.w,
           "SOURCE drifted off the source column at width " .. w)
        ck(c.mark.x < c.title.x and c.title.x < c.skill.x and c.skill.x < c.src.x,
           "the recipe columns are out of order at width " .. w)
        ck(c.src.x + c.src.w <= w, "the source column overflows the list at width " .. w)
        ck(c.title.w >= L.REC_TITLE_MIN and c.title.w <= L.REC_TITLE_MAX,
           "the title column left its clamp at width " .. w)
    end
    -- The clamp's two ends actually engage (the pre-refactor behavior, kept).
    ck(ProfUI.RecipeColumns(200).title.w == L.REC_TITLE_MIN,
       "a narrow list did not floor the title column")
    ck(ProfUI.RecipeColumns(900).title.w == L.REC_TITLE_MAX,
       "a wide list did not cap the title column")

    -- The height cost: the band + its gap == EXACTLY one list row, taken from
    -- the list (the visible-rows arithmetic shrinks by one row, no more).
    ck(ProfUI.RecipeListHeaderHeight() == L.HEAD_H + 2,
       "the header height reader drifted off the LAYOUT arithmetic")
    ck(ProfUI.RecipeListHeaderHeight() == L.LIST_ROW_H,
       "the header band does not cost the list exactly one row ("
       .. ProfUI.RecipeListHeaderHeight() .. " vs " .. L.LIST_ROW_H .. ")")
end

----------------------------------------------------------------------
-- Suite: the spec rule (owner, 2026-08-10: "we shouldnt display recipes as
-- missing if they are for a different specialization than selected"). The
-- fixture is the owner's screenshot case generalised from the SHIPPED
-- dataset: a character holding spec A of a family, looking at a recipe
-- locked to sibling spec B (his Gnomish Engineer vs the Goblin-only
-- Dimensional Ripper - Everlook).
----------------------------------------------------------------------
local function testSpecRule(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local P = ns.Professions
    local D = core()
    if not D then fails[#fails + 1] = "dataset unavailable for the spec tests" return end

    -- Find a two-spec family and a recipe locked to one of its specs.
    local specA, specB, lockedSpell
    for idx = 1, #(D.specs or {}) do
        local sB = D.specs[idx]
        for spell, rec in pairs(D.recipe) do
            if rec.spec == idx then
                for j = 1, #D.specs do
                    if j ~= idx and D.specs[j].p == sB.p then
                        specA, specB, lockedSpell = D.specs[j], sB, spell
                        break
                    end
                end
            end
            if specA then break end
        end
        if specA then break end
    end
    ck(specA ~= nil, "the dataset carries no two-spec family with a spec-locked recipe")
    if not specA then return end
    local profKey = D.profs[specB.p] and D.profs[specB.p].key
    ck(profKey ~= nil, "the spec family's profession key is unresolvable")
    if not profKey then return end
    local rec = D.recipe[lockedSpell]
    local NOW = 1700000000
    local DS = ns.ProfessionsDataMeta.version
    -- A resolver that answers EVERY spell (no cold names in these legs).
    local res = fakeResolver(setmetatable({}, {
        __index = function(_, id) return "R" .. tostring(id) end }))

    -- THE PREDICATE, all three answers.
    ck(ProfUI.SpecStanding(D, { spec = 0 }, { specA.id }) == "ok",
       "a no-requirement recipe did not read ok")
    ck(ProfUI.SpecStanding(D, rec, { specB.id }) == "ok",
       "holding the required spec did not read ok")
    ck(ProfUI.SpecStanding(D, rec, { specA.id }) == "conflict",
       "holding the SIBLING spec did not read as a conflict")
    ck(ProfUI.SpecStanding(D, rec, {}) == "openable",
       "no spec chosen did not read openable")
    ck(ProfUI.SpecStanding(D, rec, nil) == "openable",
       "a payload with no spec list did not read openable")

    -- Payloads: the owner's character (sibling spec, scanned, knows nothing),
    -- the same character unspecced, and one holding the required spec.
    local empty = P.EncodeKnown(profKey, {})
    local function payloadWith(specList)
        return { v = 1, ds = DS,
                 p = { [profKey] = { l = 300, m = 300, k = empty, n = 0, a = NOW,
                                     s = specList } }, c = {} }
    end
    local conflicted = payloadWith({ specA.id })
    local unspecced  = payloadWith(nil)
    local rightSpec  = payloadWith({ specB.id })

    local function findRow(rows)
        for _, r in ipairs(rows) do if r.spell == lockedSpell then return r end end
        return nil
    end

    -- 1) DEFAULT VIEW: the conflicted recipe is HIDDEN (not shown missing).
    ck(findRow(ProfUI.RecipeRows(conflicted, profKey, {}, res)) == nil,
       "a spec-conflicted recipe still shows in the default (obtainable-now) list")

    -- 2) MISSING ONLY: never rides it, even with Show unavailable ticked —
    --    the owner's exact complaint.
    ck(findRow(ProfUI.RecipeRows(conflicted, profKey,
        { missingOnly = true, showUnavailable = true }, res)) == nil,
       "a spec-conflicted recipe still counts as MISSING")

    -- 3) SHOW UNAVAILABLE: present, classified unavailable(spec), the spec
    --    named as the visible reason (the greyed-row render keys off
    --    row.unavailable, same as every other unavailable).
    local r = findRow(ProfUI.RecipeRows(conflicted, profKey, { showUnavailable = true }, res))
    ck(r ~= nil, "Show unavailable does not surface the spec-conflicted recipe")
    if r then
        ck(r.specConflict == true, "the conflicted row does not carry its flag")
        ck(r.unavailable ~= nil and r.unavailable.key == "spec",
           "the conflicted row is not classified unavailable(spec)")
        ck(r.unavailable ~= nil and specB.name ~= nil
           and tostring(r.unavailable.text):find(specB.name, 1, true) ~= nil,
           "the unavailable reason does not name the spec ("
           .. tostring(r.unavailable and r.unavailable.text) .. ")")
    end

    -- 4) NO SPEC CHOSEN: unchanged — the recipe is plain missing.
    r = findRow(ProfUI.RecipeRows(unspecced, profKey,
        { missingOnly = true, showUnavailable = true }, res))
    ck(r ~= nil and r.state == "missing" and not r.specConflict
       and not (r.unavailable and r.unavailable.key == "spec"),
       "an unspecced character's spec-locked recipe changed behavior")

    -- 5) HOLDS THE REQUIRED SPEC: plain missing too.
    r = findRow(ProfUI.RecipeRows(rightSpec, profKey,
        { missingOnly = true, showUnavailable = true }, res))
    ck(r ~= nil and r.state == "missing" and not r.specConflict,
       "holding the required spec still conflicted its own recipe")

    -- 6) THE CENSUS: the conflicted character's denominator shrinks by exactly
    --    the conflicted recipes; unspecced keeps the full catalogue count; a
    --    KNOWN conflicted recipe is never censused out from under its own
    --    numerator; the grid cell reads the same denominator.
    local full = ProfUI.RecipeCount(profKey)
    local obt  = ProfUI.ObtainableTotal(conflicted, profKey)
    ck(obt < full, "the conflicted census denominator did not shrink ("
       .. obt .. " vs " .. full .. ")")
    ck(ProfUI.ObtainableTotal(unspecced, profKey) == full,
       "an unspecced census denominator moved")
    local conflicts = 0
    local list = D.profRecipes[D.profIdx[profKey]]
    for i = 1, #list do
        if ProfUI.SpecStanding(D, D.recipe[list[i]], { specA.id }) == "conflict" then
            conflicts = conflicts + 1
        end
    end
    ck(obt == full - conflicts, "the census delta is not exactly the conflicted count ("
       .. obt .. " vs " .. full .. "-" .. conflicts .. ")")
    local knowsIt = payloadWith({ specA.id })
    knowsIt.p[profKey].k = P.EncodeKnown(profKey, { lockedSpell })
    knowsIt.p[profKey].n = 1
    ck(ProfUI.ObtainableTotal(knowsIt, profKey) == full - conflicts + 1,
       "a KNOWN conflicted recipe was censused out from under its numerator")
    local kr = findRow(ProfUI.RecipeRows(knowsIt, profKey, { showUnavailable = true }, res))
    ck(kr ~= nil and kr.state == "known" and not kr.specConflict,
       "a KNOWN recipe was reclassified by the spec rule")
    local cell = ProfUI.CellModel(conflicted, profKey, NOW)
    ck(cell ~= nil and cell.total == obt,
       "the grid cell's census total is not ObtainableTotal's")

    -- 7) ONE PREDICATE, ALL CONSUMERS: wrap SpecStanding and prove BOTH the
    --    list classification and the who-can-craft learnable gate call it.
    local realStanding = ProfUI.SpecStanding
    local calls = 0
    ProfUI.SpecStanding = function(...) calls = calls + 1; return realStanding(...) end
    ProfUI.RecipeRows(conflicted, profKey, { showUnavailable = true }, res)
    local afterRows = calls
    local lockedName = "R" .. tostring(lockedSpell)
    local specEntry = { { nameRealm = "Spec-Realm", rec = { classTag = "MAGE", level = 60 },
                          online = true } }
    ProfUI.SearchRows(lockedName, specEntry, function() return conflicted end,
        fakeResolver({ [lockedSpell] = lockedName }))
    local afterSearch = calls
    ProfUI.SpecStanding = realStanding
    ck(afterRows > 0, "RecipeRows never consulted the shared spec predicate")
    ck(afterSearch > afterRows, "SearchRows never consulted the shared spec predicate")

    -- 8) ... and the learnable gate itself: the sibling spec at full skill is
    --    NOT learnable; the required spec is.
    local sRows = ProfUI.SearchRows(lockedName, specEntry, function() return conflicted end,
        fakeResolver({ [lockedSpell] = lockedName }))
    ck(#sRows == 1 and #sRows[1].learnable == 0,
       "who-can-craft called a spec-conflicted character learnable")
    local sRows2 = ProfUI.SearchRows(lockedName, specEntry, function() return rightSpec end,
        fakeResolver({ [lockedSpell] = lockedName }))
    ck(#sRows2 == 1 and #sRows2[1].learnable == 1,
       "who-can-craft denied the character who holds the required spec")
end

----------------------------------------------------------------------
-- Suite: the shopping list (owner, 2026-08-10: "can we do the same thing with
-- missing recipes via professions? should only be recipes that are actually
-- tradable via the AH"). The tradability matrix runs on a SYNTHETIC dataset
-- (every acquisition shape pinned by construction); the seams — known never
-- rides, the shared spec predicate, unscanned honesty, ordering — run on the
-- SHIPPED dataset like every other suite here. Item bind/cold is modeled with
-- an injected reader, the resolver-fake idiom.
----------------------------------------------------------------------
local function testShoplist(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local P = ns.Professions
    local D = core()
    if not D then fails[#fails + 1] = "dataset unavailable for the shoplist tests" return end

    -- (a) Bind classification is position-DEFENSIVE: a non-number is UNKNOWN,
    -- never a verdict (the catalog is names-only; the 14th-return convention
    -- is verified live, not trusted).
    ck(ProfUI.BindTradable(0) == true,  "no-bind did not read tradable")
    ck(ProfUI.BindTradable(2) == true,  "BoE did not read tradable")
    ck(ProfUI.BindTradable(1) == false, "BoP read tradable")
    ck(ProfUI.BindTradable(3) == false, "bind-on-use read tradable")
    ck(ProfUI.BindTradable(4) == false, "quest-bind read tradable")
    ck(ProfUI.BindTradable("2") == nil, "a string bind did not read UNKNOWN")
    ck(ProfUI.BindTradable(nil) == nil, "a missing bind did not read UNKNOWN")

    -- (b) THE TRADABILITY MATRIX, on a synthetic dataset whose shapes are
    -- pinned by construction.
    local SD = {
        acq = {
            [101] = "T500@1",           -- trainer only: no teaching item
            [102] = "I9001",            -- teaching item is a quest reward only
            [103] = "I9002",            -- BoP vendor item
            [104] = "I9003",            -- BoE vendor item
            [105] = "I9004",            -- no-bind world drop
            [106] = "I9005",            -- BoE mob drop
            [107] = "I9006",            -- COLD item on a vendor route
            [108] = "Q777",             -- quest-taught, no item at all
            [109] = "I9007",            -- event-gated vendor item
            [110] = "T500@1;I9003",     -- trainer AND a BoE item: item route includes
        },
        itemAcq = {
            [9001] = "Q777",
            [9002] = "V2000@77",
            [9003] = "V2000@77",
            [9004] = "W40-50",
            [9005] = "D88",
            [9006] = "V150@77",
            [9007] = "V100@77;E5",
        },
        npc  = { [77] = { name = "Vendor Vic", zone = 3 }, [88] = { name = "Mob Mo", zone = 3 } },
        zone = { [3] = { name = "Testland" } },
        quest = { [777] = { name = "Some Quest" } },
        event = { [5] = "Test Festival" },
    }
    -- The item-info fake: id -> {name, link, bind} | nil (COLD — 9006 is
    -- absent on purpose, the class-4 cold read).
    local info = {
        [9001] = { name = "Plans: Quest Thing",  link = "|Hitem:9001|h[q]|h", bind = 0 },
        [9002] = { name = "Plans: Bound Thing",  link = "|Hitem:9002|h[b]|h", bind = 1 },
        [9003] = { name = "Plans: Vendor Thing", link = "|Hitem:9003|h[v]|h", bind = 2 },
        [9004] = { name = "Plans: World Thing",  link = "|Hitem:9004|h[w]|h", bind = 0 },
        [9005] = { name = "Plans: Drop Thing",   link = "|Hitem:9005|h[d]|h", bind = 2 },
        [9007] = { name = "Plans: Event Thing",  link = "|Hitem:9007|h[e]|h", bind = 2 },
    }
    local fakeInfo = function(id) return info[id] end

    local v = ProfUI.ShopTradability(SD, 101, fakeInfo)
    ck(v.state == "excluded" and v.reason == "no-item",
       "trainer-only was not excluded as no-item")
    v = ProfUI.ShopTradability(SD, 108, fakeInfo)
    ck(v.state == "excluded" and v.reason == "no-item",
       "quest-taught (no item) was not excluded")
    v = ProfUI.ShopTradability(SD, 102, fakeInfo)
    ck(v.state == "excluded" and v.reason == "unreachable",
       "a quest-reward-only teaching item was not excluded")
    v = ProfUI.ShopTradability(SD, 103, fakeInfo)
    ck(v.state == "excluded" and v.reason == "bound",
       "a BoP teaching item was not excluded")
    v = ProfUI.ShopTradability(SD, 104, fakeInfo)
    ck(v.state == "tradable" and v.vendor == true,
       "a BoE vendor item was not included with its vendor flag")
    ck(v.tag ~= nil and v.tag:find("Vendor Vic", 1, true) ~= nil
       and v.tag:find("Testland", 1, true) ~= nil,
       "the vendor tag does not name vendor and zone (" .. tostring(v.tag) .. ")")
    v = ProfUI.ShopTradability(SD, 105, fakeInfo)
    ck(v.state == "tradable" and v.tag == "World drop" and v.vendor == false,
       "a no-bind world drop was not included as 'World drop'")
    v = ProfUI.ShopTradability(SD, 106, fakeInfo)
    ck(v.state == "tradable" and v.tag ~= nil and v.tag:find("Mob Mo", 1, true) ~= nil,
       "a BoE mob drop was not included with its drop tag")
    v = ProfUI.ShopTradability(SD, 107, fakeInfo)
    ck(v.state == "unresolved" and v.item == 9006,
       "a cold teaching item was not held UNRESOLVED (" .. tostring(v.state) .. ")")
    v = ProfUI.ShopTradability(SD, 109, fakeInfo)
    ck(v.state == "excluded",
       "an event-gated teaching item was not excluded")
    v = ProfUI.ShopTradability(SD, 110, fakeInfo)
    ck(v.state == "tradable",
       "trainer+item did not include via the item route")
    -- A bind slot that fails the TYPE check is the same unknown as cold.
    v = ProfUI.ShopTradability(SD, 104, function() return { name = "N", bind = "2" } end)
    ck(v.state == "unresolved",
       "a type-drifted bind return was not held unresolved")

    -- (c) THE SEAMS, on the shipped dataset. A scanned character missing
    -- everything: rows exist, no known recipe rides, no unavailable rides,
    -- ordering is skill-ascending and deterministic.
    local NOW = 1700000000
    local DS = ns.ProfessionsDataMeta.version
    local names = setmetatable({}, { __index = function(_, id) return "R" .. tostring(id) end })
    local res = fakeResolver(names)
    local allBoE  = function(id) return { name = "Item " .. tostring(id), bind = 2 } end
    local allCold = function() return nil end
    local knowsNothing = { v = 1, ds = DS,
        p = { alchemy = { l = 300, m = 300, k = P.EncodeKnown("alchemy", {}), n = 0, a = NOW } },
        c = {} }

    local rows, pendingItems, state, missingN =
        ProfUI.ShoplistRows(knowsNothing, "alchemy", res, allBoE)
    ck(state == "scanned", "a scanned profession did not report scanned")
    ck(#rows > 0, "an all-missing alchemist has an empty shopping list "
       .. "(the dataset should carry BoE-taught alchemy recipes)")
    ck(#pendingItems == 0, "an all-warm item reader still produced pending items")
    ck(missingN >= #rows, "the missing count is smaller than the filtered list")
    for _, r in ipairs(rows) do
        local src = ProfUI.SourceModel(r.spell)
        if src and src.unavailable then
            fails[#fails + 1] = "an unavailable recipe rode the shopping list"
            break
        end
        if not r.unresolved and not (r.item and r.itemName and r.tag) then
            fails[#fails + 1] = "a tradable row is missing item/name/tag"
            break
        end
    end
    for i = 2, #rows do
        local sa = tonumber(rows[i - 1].skill) or 0
        local sb = tonumber(rows[i].skill) or 0
        if sa > sb or (sa == sb and rows[i - 1].spell >= rows[i].spell) then
            fails[#fails + 1] = "the list is not skill-ascending with a deterministic tiebreak"
            break
        end
    end
    local again = ProfUI.ShoplistRows(knowsNothing, "alchemy", res, allBoE)
    ck(#again == #rows, "two identical runs disagreed on the row count")
    for i = 1, math.min(#rows, #again) do
        if rows[i].spell ~= again[i].spell then
            fails[#fails + 1] = "two identical runs ordered the rows differently"
            break
        end
    end

    -- KNOWN NEVER RIDES: know two recipes, and neither may appear.
    local ids = pickProf(D, "alchemy", 2)
    local knowsTwo = { v = 1, ds = DS,
        p = { alchemy = { l = 300, m = 300, k = P.EncodeKnown("alchemy", { ids[1], ids[2] }),
                          n = 2, a = NOW } }, c = {} }
    local rows2 = ProfUI.ShoplistRows(knowsTwo, "alchemy", res, allBoE)
    for _, r in ipairs(rows2) do
        if r.spell == ids[1] or r.spell == ids[2] then
            fails[#fails + 1] = "a KNOWN recipe rode the shopping list"
            break
        end
    end

    -- THE SHARED SPEC PREDICATE, pinned: the list consults SpecStanding, and a
    -- spec-conflicted recipe never appears (the testSpecRule fixture, reused).
    local realStanding = ProfUI.SpecStanding
    local calls = 0
    ProfUI.SpecStanding = function(...) calls = calls + 1; return realStanding(...) end
    ProfUI.ShoplistRows(knowsNothing, "alchemy", res, allBoE)
    ProfUI.SpecStanding = realStanding
    ck(calls > 0, "the shopping list never consulted the shared spec predicate")
    local specA, specB, lockedSpell
    for idx = 1, #(D.specs or {}) do
        local sB = D.specs[idx]
        for spell, rec in pairs(D.recipe) do
            if rec.spec == idx then
                for j = 1, #D.specs do
                    if j ~= idx and D.specs[j].p == sB.p then
                        specA, specB, lockedSpell = D.specs[j], sB, spell
                        break
                    end
                end
            end
            if specA then break end
        end
        if specA then break end
    end
    if specA then
        local sProf = D.profs[specB.p] and D.profs[specB.p].key
        local conflicted = { v = 1, ds = DS,
            p = { [sProf] = { l = 300, m = 300, k = P.EncodeKnown(sProf, {}), n = 0,
                              a = NOW, s = { specA.id } } }, c = {} }
        local sRows = ProfUI.ShoplistRows(conflicted, sProf, res, allBoE)
        for _, r in ipairs(sRows) do
            if r.spell == lockedSpell then
                fails[#fails + 1] = "a spec-conflicted recipe rode the shopping list"
                break
            end
        end
    end

    -- (d) COLD ITEMS: every candidate holds UNRESOLVED — none scored tradable,
    -- none silently dropped (row count matches the warm run), all pending, and
    -- none leaks into the Auctionator terms.
    local coldRows, coldPending = ProfUI.ShoplistRows(knowsNothing, "alchemy", res, allCold)
    ck(#coldRows == #rows, "cold item reads changed the row count ("
       .. #coldRows .. " vs " .. #rows .. ")")
    for _, r in ipairs(coldRows) do
        if not r.unresolved then
            fails[#fails + 1] = "a cold item was scored tradable"
            break
        end
    end
    if #coldRows > 0 then
        ck(#coldPending > 0, "cold items produced no pending warm-load ids")
    end
    ck(#ProfUI.ShoplistSearchTerms(coldRows) == 0,
       "unresolved rows leaked into the Auctionator terms")

    -- (e) THE THIRD STATE: a never-scanned profession produces NO list, and
    -- its message says "not checked", never "nothing to buy".
    local unscanned = { v = 1, ds = DS, p = { alchemy = { l = 300, m = 300 } }, c = {} }
    local uRows, _, uState = ProfUI.ShoplistRows(unscanned, "alchemy", res, allBoE)
    ck(uState == "unscanned" and #uRows == 0,
       "a never-scanned profession invented a shopping list")
    local uLines = ProfUI.ShoplistLines("Aaa-Realm", "alchemy", uRows, uState, 0)
    ck(#uLines == 1 and uLines[1]:find("Not checked", 1, true) ~= nil,
       "the unscanned message does not say 'Not checked'")

    -- (f) EMPTY STATES tell "all known" from "nothing tradable".
    local eKnown = ProfUI.ShoplistLines("Aaa-Realm", "alchemy", {}, "scanned", 0)
    ck(#eKnown == 1 and eKnown[1]:find("already knows", 1, true) ~= nil,
       "the all-known empty message is wrong (" .. tostring(eKnown[1]) .. ")")
    local eTrade = ProfUI.ShoplistLines("Aaa-Realm", "alchemy", {}, "scanned", 5)
    ck(#eTrade == 1 and eTrade[1]:find("tradable", 1, true) ~= nil,
       "the nothing-tradable empty message is wrong (" .. tostring(eTrade[1]) .. ")")

    -- (g) LINE RENDER: header + one line per row; tradable lines carry link
    -- or name, skill and tag; unresolved lines wear their state in words; the
    -- Auctionator terms are exactly the resolved names.
    local fRows = {
        { spell = 1, skill = 100, item = 9003, itemName = "Plans: Vendor Thing",
          link = nil, tag = "Sold by Vendor Vic \226\128\148 Testland",
          vendor = true, unresolved = false },
        { spell = 2, skill = 150, item = 9006, tag = "World drop", unresolved = true },
    }
    local fLines = ProfUI.ShoplistLines("Aaa-Realm", "alchemy", fRows, "scanned", 4)
    ck(#fLines == 3, "the header+rows line count is wrong (" .. #fLines .. ")")
    ck(fLines[2]:find("Vendor Vic", 1, true) ~= nil
       and fLines[2]:find("skill 100", 1, true) ~= nil,
       "a tradable line lost its tag or skill (" .. tostring(fLines[2]) .. ")")
    ck(fLines[3]:find("unresolved", 1, true) ~= nil,
       "an unresolved line does not wear its state (" .. tostring(fLines[3]) .. ")")
    local terms = ProfUI.ShoplistSearchTerms(fRows)
    ck(#terms == 1 and terms[1] == "Plans: Vendor Thing",
       "the search terms are not exactly the resolved item names")

    -- (h) THE SLASH TARGET RESOLVER.
    local entries = {
        { nameRealm = "Aaa-Realm", isSelf = false },
        { nameRealm = "Bbb-Realm", isSelf = true },
    }
    local lookup = function(k) return (k == "Aaa-Realm") and knowsNothing or nil end
    local o, pk = ProfUI.ShoplistTarget("aaa alchemy", entries, lookup, {})
    ck(o == "Aaa-Realm" and pk == "alchemy", "explicit character+profession did not resolve")
    o, pk = ProfUI.ShoplistTarget("", entries, lookup, { owner = "Aaa-Realm", prof = "alchemy" })
    ck(o == "Aaa-Realm" and pk == "alchemy", "the pane-selection default did not resolve")
    o, pk = ProfUI.ShoplistTarget("aaa", entries, lookup, {})
    ck(o == "Aaa-Realm" and pk == "alchemy", "a sole recorded profession was not defaulted")
    o, pk = ProfUI.ShoplistTarget("alchemy", entries, lookup, {})
    ck(o == "Bbb-Realm" and pk == "alchemy", "profession-only did not target the self character")
    local o2, pk2, err = ProfUI.ShoplistTarget("nosuch", entries, lookup, {})
    ck(o2 == nil and pk2 == nil and type(err) == "string",
       "an unknown name did not error usefully")
    local o3, pk3, err3 = ProfUI.ShoplistTarget("aaa e", entries, lookup, {})
    ck(pk3 == nil and type(err3) == "string",
       "an ambiguous profession prefix resolved instead of erroring")
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("professionsui", function(verbose)
        local suites = {
            { name = "grid model (roster order, the third state, cooldown decay, "
                  .. "multi-width fit, header pins)",
              fn = testGridModel },
            { name = "cooldown rollup (ready-first ordering, shared groups, determinism)",
              fn = testRollup },
            { name = "detail tabs + cooldown kinds (rogue poisons tab, ready-only names, "
                  .. "kind determinism)",
              fn = testDetailAndKinds },
            { name = "detail-pane filters (missing-only, source, unavailable toggle, cold search)",
              fn = testFilters },
            { name = "materials join (mesh counts, unknown vs zero, unharvested state)",
              fn = testMaterials },
            { name = "who-can-craft search (known / learnable / not checked, cold names)",
              fn = testSearch },
            { name = "tab badge + login line (count, cap, latch, off switch)",
              fn = testBadgeAndLoginLine },
            { name = "source display (mask reader + every sampled recipe answers)",
              fn = testSourceModel },
            { name = "detail rework (glyph pins, windowless professions, absent "
                  .. "secondaries, freed list space, zoned acquisitions)",
              fn = testDetailRework },
            { name = "grid filter chips (60s/Online/faction parity with the cards, "
                  .. "no summoners, selection survives, persistence heal, chip-bar layout)",
              fn = testGridChips },
            { name = "recipe hover tooltip (enchant/item/facts chain, session latch, "
                  .. "cold-item honesty, pooled-row hygiene, click unchanged)",
              fn = testRecipeTooltips },
            { name = "recipe list column headers (RECIPE|SKILL|SOURCE, one column "
                  .. "source at multiple widths, one-row height cost)",
              fn = testRecipeHeader },
            { name = "spec rule (conflicted recipes never missing, unavailable-with-"
                  .. "reason, census denominator, one shared predicate)",
              fn = testSpecRule },
            { name = "shopping list (AH-tradability matrix, defensive bind read, "
                  .. "cold-item unresolved, known/spec seams, ordering, empty "
                  .. "messages, slash target)",
              fn = testShoplist },
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
