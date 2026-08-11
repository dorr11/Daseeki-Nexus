-- Daseeki Nexus — ui_inventorytab.lua  (THE INVENTORY TAB)
--
-- Owner's framing: "a one-stop shop for ALL of the inventory on all of the mesh
-- accounts… listed by item and quantity… categories for filtering and searching…
-- a pseudo inventory-management module of an ERP system, but much much simpler
-- and in WoW."
--
-- So: one top-level tab, peer to Characters and Professions, holding ONE TABLE —
-- one row per distinct item across every character on every account, carrying the
-- summed quantity, with the per-character split one hover away.
--
--   ROW      [icon] Netherweave Cloth            1,204   Trade Goods
--   HOVER    the per-character breakdown, class-colored, this account above the
--            line and Other Accounts below it. Shift-hover swaps in the client's
--            real item tooltip.
--   FILTERS  a live name search and a CATEGORY chip built from the client's own
--            item classes. They COMPOSE.
--   SORT     name ascending by default; the QTY header toggles quantity-desc.
--   FOOTER   distinct items · total items · roster coverage and its oldest stamp.
--
-- ALWAYS PRESENT. Unlike Professions, this tab carries NO gate: it is a view onto
-- data Nexus holds either way, and the ledger's own emptiness (or the Inventory
-- module being switched off) is stated in words on the page rather than by making
-- the tab vanish. See InvUI.EmptyText.
--
----------------------------------------------------------------------
-- THE DATA SEAM — REUSED, NOT REBUILT
--
-- Nexus already holds the mesh-wide item ledger, and it already has a reader that
-- turns it into per-character, per-item counts with account attribution: the one
-- tooltips.lua uses for the cross-account item block (the same pure model
-- Daseeki-Bags' Find uses, pinned to it by the harness's cross-addon parity gate).
-- This file consumes that reader at its HIGHEST level and adds exactly one thing
-- the tooltip never needed — the transpose.
--
--   ns.Tooltips.Owners()          -> [ownerKey] = <Bags-shaped owner record>
--                                    { name, class, race, sex, faction, source
--                                      ("full" = this account | "summary" = another),
--                                      itemCounts = { [itemID] = count } }
--                                    Built from Store.InventoryOwners() (bags+bank+
--                                    mail+equipped, already summed by the wire
--                                    contract) and cached 1s. Nothing new is read.
--   ns.Tooltips.BuildCountLines() -> the per-character holder lines for ONE item
--   ns.Tooltips.BuildTooltipRows()-> those lines partitioned into the rendered rows
--
-- InvUI.BuildLedger is the ONE new pure function: owners (item-major per character)
-- -> rows (character-major per item). It is pure, deterministic and self-tested,
-- and the suite pins its per-character split against BuildCountLines row for row —
-- so the table and the hover can never drift into disagreeing about who holds what.
--
-- WHY THE TRANSPOSE IS NEW AND NOTHING ELSE IS: every existing consumer asks
-- "who holds item X?" one item at a time, from a hover. This tab asks "what does
-- the mesh hold?" — every item at once — and there was no reader for that.
--
----------------------------------------------------------------------
-- CLASS 4 HONESTY: COLD ITEM DATA IS THE HARD PART
-- (CLIENT_ASYNC_LESSONS class 4 — "partial/cold data reads presented as complete")
--
-- The ledger is a map of item IDs. Names, qualities, icons and item classes are
-- NOT in it — they come from GetItemInfo, which is asynchronous and cold-cache on
-- Era. On a fresh login most of this table has no names at all.
--
-- ONE CERTAINTY PER ROW, and it is THE NAME. GetItemInfo is the sole source for
-- every fact a row shows; when it has not answered, the row has no name, no
-- quality, no icon and no category. GetItemInfoInstant is DELIBERATELY NOT
-- consulted as a partial source: it would answer the item class for a row whose
-- name is still "item #12345", and then the search filter and the category filter
-- would be composing over two DIFFERENT certainties inside one row — which is
-- precisely the shape class 4 is about. One certainty means "(unresolved)" means
-- exactly one thing, everywhere, and the filter rules can be stated once.
--
-- AN UNRESOLVED ROW IS NEVER DROPPED. It renders honestly — "item #12345", the
-- neutral question-mark icon, an ellipsis where its category goes — it COUNTS
-- toward the footer's distinct and total figures, it fires one bounded warm-load
-- request through the ask counter, and it heals in place on GET_ITEM_INFO_RECEIVED
-- or the next refresh. The suite carries a RED CONTROL for this: a filter pass
-- that silently drops unresolved rows must fail the suite.
--
-- THE FILTER POLICY, PICKED AND DOCUMENTED (the brief asked for a choice):
--   * NAME SEARCH. An unresolved row has no name, so it cannot match a substring
--     — it is EXCLUDED from the result and COUNTED as pending, and the status line
--     says "still loading N names…". Scoring a cold id as a MISS is exactly the
--     defect Bags' ui_find.lua paid for (a search that said "nobody has this"
--     about an item three alts were holding), so it is counted, never miscounted.
--   * CATEGORY. With NO category chosen, unresolved rows are SHOWN — no claim is
--     being made about them. With a CONCRETE category chosen they are EXCLUDED:
--     we were not told their class and will not guess one. They remain reachable
--     under their own explicit bucket, InvUI.UNRESOLVED ("(unresolved)"), which
--     the chip offers whenever any row is cold.
--   * The two compose: search AND category must both admit a row.
--
-- THE ASK is ProfUI.AskFor's idiom, in this file's own copy so the tab does not
-- depend on the professions module's files being present: bounded at MAX_ASKS per
-- id, driven through C_Item.RequestLoadItemDataByID, with a five-rung ladder and a
-- per-id EXHAUSTED mark so a server that will never answer for an id costs one
-- ladder and then nothing. An id the client reports as already cached is skipped
-- outright — it cannot get warmer, so the ask would be pure noise.
--
----------------------------------------------------------------------
-- VIRTUALIZED, NOT MERELY POOLED
--
-- The professions recipe list POOLS its rows (one frame per rendered row, reused
-- across renders) and that is enough there, because a profession's recipe count is
-- bounded by the dataset. This table is not bounded by anything: a well-played
-- mesh is thousands of distinct items, and pooling alone would create thousands of
-- frames the moment the tab opened.
--
-- So the pool here is bounded by the VIEWPORT, not by the row count:
-- InvUI.VisibleWindow maps a scroll offset to the first/last row indices actually
-- on screen, the scroll child wears the full virtual height so the wheel and the
-- scrollbar still describe the whole list, and the pool never grows past
-- InvUI.PoolCeiling (viewport rows + 1). Both are pure and pinned. Scrolling
-- repositions and repaints the same frames; it never creates one.
--
-- POOLED-ROW HYGIENE (the Daseeki-Bags bank-tooltip lesson, transcribed from
-- ProfUI.RowTooltipOnPaint): a recycled frame must not keep the PREVIOUS item's
-- tooltip standing when it adopts a new item. InvUI.TooltipStaleOnPaint is the
-- pure rule, the paint path consults it before every swap, and OnHide drops a
-- tooltip the row still owns. Virtualization makes this sharper than it is in the
-- professions list — here a row is recycled on every scroll tick, not only on a
-- filter change — so the suite exercises the recycle path directly.
--
----------------------------------------------------------------------
-- FIRST OPEN COSTS WHAT IT MEASURES  (owner, live 2026-08-11: "when i clicked
-- the inventory tab for the first time there was a huge lag spike")
--
-- MEASURED, headless, against a 40-character / 1,617-distinct-item mesh — the
-- shape of a well-played account, which is what the owner has:
--
--   BuildLedger (the transpose)      10.8 ms   + 3.1 MB allocated in one frame
--   Decorate (1,617 GetItemInfo)      1.6 ms
--   AskFor (1,617 warm-load asks)     3.0 ms   + 1,617 client item queries
--   FilterRows                        0.2 ms
--   SortRows                          2.9 ms cold / 6.3 ms once names land
--   ---- first frame                 18.5 ms
--
-- 18 ms is a dropped frame, not a "huge spike". THE SPIKE WAS NEVER ONE FRAME:
-- the ask flood buys ~1,617 GET_ITEM_INFO_RECEIVED events, and every one of
-- them ran a FULL repaint — Decorate + Filter + Sort over every row, 8.0 ms
-- each. 1,617 x 8.0 ms = ~13 SECONDS of aggregate work, arriving as a stutter
-- over the seconds after the click. The cost was O(N^2) in the ledger size.
--
-- And it was not only the first click: Dashboard.RefreshActive calls this
-- pane's Refresh on STORE_REFRESHED, STATE_CHANGED, TIMER_UPDATED, NODE_UPDATED
-- and CD_WARNING whenever the window is open — so the 10.8 ms transpose re-ran
-- on every world-buff tick and every peer payload, and each one also snapped the
-- list back to the top mid-scroll.
--
-- FIVE FIXES, ONE PER MEASURED CAUSE:
--
--   1 COALESCE THE REPAINT. GET_ITEM_INFO_RECEIVED sets a dirty flag;
--     REPAINT_DEBOUNCE later exactly one repaint runs. ~1,617 repaints become
--     a handful. This is the ~13 seconds.
--   2 BUDGET THE ASKS. Cold ids go into a QUEUE drained ASK_BUDGET at a time,
--     ASK_PERIOD apart, VIEWPORT FIRST — the rows on screen are asked about
--     before the rows nobody has scrolled to. The existing AskFor is the drain's
--     one exit, so its per-id MAX_ASKS bound and its already-cached suppression
--     are untouched. This also spreads the echoes the client sends back.
--   3 SLICE THE TRANSPOSE. NewLedgerJob/StepLedger fold BUILD_CHUNK
--     (owner,item) entries per frame through the timer seam. The FIRST slice
--     paints, so the table is on screen while the rest is still being folded in,
--     and the pane says "indexing 12 of 40 characters…" rather than showing
--     partial sums as if they were totals (InvUI.ProgressText).
--   4 PRECOMPUTE THE SORT KEY. SortRows' comparator called name:lower() per
--     COMPARISON — measured, that is why a warm sort (6.3 ms) cost more than
--     twice a cold one (2.9 ms). Decorate stores `sortKey` once per row.
--   5 CACHE BY GENERATION. The ledger is rebuilt only when the store actually
--     moved (InvUI.Generation, bumped by the same STORE_REFRESHED /
--     ACCOUNT_ID_CHANGED signals Tooltips.Owners' own 1s cache listens to), and
--     the filtered+sorted view is cached on top of it. A second visit to the tab
--     is a repaint; a TIMER_UPDATED while the tab is open is a repaint; and
--     neither loses the owner's scroll position any more.
--
-- InvUI.WORK is the call meter the suite budgets against, bumped once per PASS
-- (never per item), so the pins cost nothing in the hot loop.
--
----------------------------------------------------------------------
-- DETERMINISM (class 8)
--
-- Every ordering in this file is a TOTAL order, and every table walk that feeds one
-- is sorted first. pairs() decides nothing: the ledger walks owner keys sorted and
-- each owner's item ids sorted, the base row order is item id ascending, both sort
-- modes fall through to item id as the final tiebreak, the category list is sorted,
-- and the pending-id list handed to the ask ladder is sorted. The suite asserts
-- that two builds of the same fixture are identical row for row and that each sort
-- mode is stable across repeated application.
--
----------------------------------------------------------------------
-- GEOMETRY (the professions overflow lesson, followed from day one)
--
-- Every metric lives in one table (L) and every placement goes through a pure
-- reader over it — InvUI.RowColumns, InvUI.HeaderCells, InvUI.ListTopInset,
-- InvUI.ListBottomInset. RowColumns is a function of the width ACTUALLY available
-- at render time: above the natural sum the surplus is split between the two text
-- columns so the table fills its pane, below it every column and gap shrinks
-- proportionally and floors, so the band's right edge can never pass the pane at
-- ANY width. The suite exercises the fit at seven widths from 200 to 2000 rather
-- than pinning one, and asserts no overlap and no overrun at every one of them.
--
-- Clean-room build on our own DaseekiUI stack and our own store. No third-party
-- code or identifiers were read.

local ADDON, ns = ...
local UI = DaseekiUI                  -- nil under the headless harness; only ever
local Dashboard = ns.Dashboard        -- dereferenced inside function bodies below.

local InvUI = {}
ns.InventoryUI = InvUI

local EMPTY = {}

----------------------------------------------------------------------
-- GLYPHS — the tofu lesson (ui_professions.lua's THE GLYPH REGISTRY).
--
-- Every non-ASCII byte this file prints lives here, and each one is a sequence
-- already PROVEN to render in the vendored suite face by shipped suite text. This
-- table is a local copy rather than a reference to ProfUI.GLYPHS on purpose: the
-- inventory tab must not acquire a load-order dependency on the professions files,
-- which the harness's hotfix-line tolerance can drop entirely. The suite pins the
-- bytes AND pins that they agree with ProfUI's copy whenever that copy is present.
----------------------------------------------------------------------

InvUI.GLYPHS = {
    dots   = "\226\128\166",   -- U+2026 ellipsis      (the unresolved category cell)
    middot = "\194\183",       -- U+00B7 middle dot    (the suite separator)
    dash   = "\226\128\148",   -- U+2014 em dash
    down   = "v",              -- ASCII: the sort-direction mark on a header
}

----------------------------------------------------------------------
-- LAYOUT — the one table.
----------------------------------------------------------------------

local L = {
    GUTTER      = 10,
    PANEL_PAD   = 10,
    TOOLBAR_H   = 30,   -- the search + category band above the table
    HEAD_H      = 18,   -- the clickable column-header band
    FOOTER_H    = 18,   -- the coverage line under the table
    ROW_H       = 22,   -- one item row (the 18px icon plus its breathing room)
    SCROLL_STEP = 44,   -- two rows per wheel tick

    -- The row's column band. ICON and QTY are FIXED (an icon has one size and a
    -- quantity has a known digit budget); NAME and CATEGORY are the flexible pair
    -- that absorbs the surplus and the shrink. See InvUI.RowColumns.
    ICON_X    = 2,
    ICON_W    = 18,
    NAME_GAP  = 6,
    NAME_NAT  = 210,    -- the name column's NATURAL width
    QTY_GAP   = 8,
    QTY_W     = 64,     -- right-justified numerals; fits a comma-grouped 7 digits
    CAT_GAP   = 10,
    CAT_NAT   = 120,    -- the category column's NATURAL width
    CAT_PAD   = 4,      -- category column -> the band's right edge
    NAME_GROW = 0.60,   -- the name column's share of any surplus width

    SEARCH_W  = 260,    -- the toolbar's search control
    CHIP_W    = 190,    -- the category chip
}
InvUI.LAYOUT = L

-- PURE. One row's y within the virtual list.
function InvUI.RowY(i) return (tonumber(i) or 1) - 1 end

-- PURE. The row band's column geometry, from the width ACTUALLY available at
-- render time (the professions overflow lesson).
--
-- At or below the natural sum every column AND gap shrinks by the same factor and
-- FLOORS, so the accumulated right edge can only fall short of availW, never pass
-- it. Above it the surplus is split between the two flexible text columns
-- (NAME_GROW to the name, the remainder to the category) so the table fills its
-- pane instead of leaving a dead strip — and the right edge lands exactly at
-- availW - CAT_PAD.
--
-- Returns { icon={x,w}, name={x,w}, qty={x,w}, cat={x,w}, width=<right edge>,
--           scale=<1 or the shrink factor> }.
function InvUI.RowColumns(availW)
    availW = tonumber(availW) or 0
    if availW < 0 then availW = 0 end
    local gaps    = L.ICON_X + L.NAME_GAP + L.QTY_GAP + L.CAT_GAP + L.CAT_PAD
    local natural = L.ICON_W + L.NAME_NAT + L.QTY_W + L.CAT_NAT
    local full    = natural + gaps

    local scale, grow = 1, 0
    if availW < full then
        scale = (availW > 0) and (availW / full) or 0
    else
        grow = availW - full
    end
    local function dim(n)
        local v = math.floor(n * scale)
        if v < 0 then v = 0 end
        return v
    end
    local nameGrow = math.floor(grow * L.NAME_GROW)
    local catGrow  = grow - nameGrow

    local x = dim(L.ICON_X)
    local icon = { x = x, w = dim(L.ICON_W) }
    x = x + icon.w + dim(L.NAME_GAP)
    local name = { x = x, w = dim(L.NAME_NAT) + nameGrow }
    x = x + name.w + dim(L.QTY_GAP)
    local qty = { x = x, w = dim(L.QTY_W) }
    x = x + qty.w + dim(L.CAT_GAP)
    local cat = { x = x, w = dim(L.CAT_NAT) + catGrow }
    x = x + cat.w

    return { icon = icon, name = name, qty = qty, cat = cat, width = x, scale = scale }
end

-- The NATURAL width of the band — the born-size for pooled rows and the point at
-- which the columns stop shrinking and start growing.
function InvUI.RowWidth()
    return InvUI.RowColumns(1e9).width
end

-- PURE. The column-header row: label + the EXACT x/width of the column it
-- captions, derived FROM RowColumns so a header can never sit where its column
-- does not. `sort` names the sort mode a click on that header selects (nil = the
-- header is a caption only). QTY right-justifies because its numerals do.
function InvUI.HeaderCells(availW)
    local c = InvUI.RowColumns(availW)
    return {
        { label = "ITEM",     x = c.name.x, w = c.name.w, justify = "LEFT",  sort = "name" },
        { label = "QTY",      x = c.qty.x,  w = c.qty.w,  justify = "RIGHT", sort = "qty"  },
        { label = "CATEGORY", x = c.cat.x,  w = c.cat.w,  justify = "LEFT"                 },
    }
end

-- PURE. What the header band costs the list, top to bottom, and what the footer
-- costs it bottom to top. Two readers so the view and the suite share ONE
-- arithmetic rather than two copies of the same sum.
function InvUI.ListTopInset()    return L.HEAD_H + 2 end
function InvUI.ListBottomInset() return L.FOOTER_H + 4 end

----------------------------------------------------------------------
-- VIRTUALIZATION — pure window maths
----------------------------------------------------------------------

-- PURE. How many row frames a viewport of `viewH` can ever need: the rows that
-- fit, plus one for the partially-scrolled row at the top edge. The pool never
-- grows past this, whatever the list length.
function InvUI.PoolCeiling(viewH, rowH)
    rowH = tonumber(rowH) or L.ROW_H
    if rowH < 1 then rowH = 1 end
    viewH = tonumber(viewH) or 0
    if viewH < 0 then viewH = 0 end
    return math.ceil(viewH / rowH) + 1
end

-- PURE. The visible slice of a virtual list. Returns first, last, yTop — where
-- yTop is the y of row `first` in the scroll child's own space, so the renderer
-- places the pooled frames at real virtual positions rather than at the top of
-- the viewport.
--
-- last < first (specifically last == 0) means "nothing to draw", which an empty
-- list and a zero-height viewport both produce.
function InvUI.VisibleWindow(scrollOffset, viewH, rowH, n)
    rowH = tonumber(rowH) or L.ROW_H
    if rowH < 1 then rowH = 1 end
    n     = tonumber(n) or 0
    viewH = tonumber(viewH) or 0
    scrollOffset = tonumber(scrollOffset) or 0
    if scrollOffset < 0 then scrollOffset = 0 end
    if n <= 0 or viewH <= 0 then return 1, 0, 0 end

    local maxOff = n * rowH - viewH
    if maxOff < 0 then maxOff = 0 end
    if scrollOffset > maxOff then scrollOffset = maxOff end

    local first = math.floor(scrollOffset / rowH) + 1
    if first < 1 then first = 1 end
    local last = first + InvUI.PoolCeiling(viewH, rowH) - 1
    if last > n then last = n end
    return first, last, (first - 1) * rowH
end

----------------------------------------------------------------------
-- PURE PRESENTATION HELPERS
----------------------------------------------------------------------

-- PURE. Thousands separators. (tooltips.lua carries the same routine for the money
-- tooltip; this is a local copy for the same reason the glyph table is — no
-- load-order dependency on a file the harness may drop.)
function InvUI.Commas(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s
    while true do
        local rep
        out, rep = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if rep == 0 then break end
    end
    return out
end

-- PURE. Blizzard item-quality ink. The client's own table is preferred when it is
-- there (C_Item.GetItemQualityColor / GetItemQualityColor are both catalog-present
-- for 1.15.9); the literals below are the same canonical values and exist so the
-- colour rule is assertable headless, where no client function is loaded.
-- An unknown or absent quality answers the neutral text ink, never a guessed one.
InvUI.QUALITY_RGB = {
    [0] = { 0.616, 0.616, 0.616 },   -- Poor
    [1] = { 1.000, 1.000, 1.000 },   -- Common
    [2] = { 0.118, 1.000, 0.000 },   -- Uncommon
    [3] = { 0.000, 0.439, 0.867 },   -- Rare
    [4] = { 0.639, 0.208, 0.933 },   -- Epic
    [5] = { 1.000, 0.502, 0.000 },   -- Legendary
    [6] = { 0.902, 0.800, 0.502 },   -- Artifact
    [7] = { 0.000, 0.800, 1.000 },   -- Heirloom
}

-- PURE over the table above; the live client's answer wins when `useClient` is not
-- false and the function exists. Returns r,g,b or nil for "no quality known".
function InvUI.QualityRGB(quality, useClient)
    local q = tonumber(quality)
    if q == nil then return nil end
    if useClient ~= false then
        local f = (_G.C_Item and _G.C_Item.GetItemQualityColor) or _G.GetItemQualityColor
        if f then
            local ok, r, g, b = pcall(f, q)
            if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
                return r, g, b
            end
        end
    end
    local c = InvUI.QUALITY_RGB[q]
    if not c then return nil end
    return c[1], c[2], c[3]
end

-- PURE. What a row's NAME cell says. An unresolved row says what it actually
-- knows — its id — and says it in a form nobody can mistake for a name.
function InvUI.DisplayName(row)
    if type(row) == "table" and row.resolved and type(row.name) == "string" and row.name ~= "" then
        return row.name
    end
    local id = (type(row) == "table" and row.id) or "?"
    return "item #" .. tostring(id)
end

-- PURE. What a row's CATEGORY cell says. Unresolved is an ellipsis: a blank cell
-- would read as "this item has no category", which is a claim we cannot make.
function InvUI.DisplayCategory(row)
    if type(row) == "table" and row.resolved and type(row.category) == "string"
       and row.category ~= "" then
        return row.category
    end
    return InvUI.GLYPHS.dots
end

----------------------------------------------------------------------
-- THE LEDGER — the one new pure function (see the DATA SEAM header)
----------------------------------------------------------------------

-- PURE. owners (item-major per character) -> rows (character-major per item).
--
--   owners = { [ownerKey] = { itemCounts = { [itemID] = count }, … } }
--         (the Bags-shaped record ns.Tooltips.Owners produces; every other field
--          is ignored here — the hover reads them through Tooltips' own model)
--
-- Returns rows, stats where
--   rows  = { { id, total, holders, split = { { key, count }, … } }, … }
--           ordered by item id ascending — the CANONICAL base order every sort
--           mode falls through to, so no ordering in this file inherits pairs().
--   stats = { distinct, total, chars }
--
-- `split` is the per-character breakdown, retained on the row so the table's own
-- numbers are provable without a second pass over the graph. It is built in
-- sorted-owner order and therefore needs no sort of its own. The RENDERED hover
-- does not read it — that goes through ns.Tooltips.BuildCountLines, the exact
-- machinery the cross-account item tooltips use — and the suite pins the two
-- against each other so they cannot drift.
function InvUI.BuildLedger(owners)
    local rows, byId = {}, {}
    local stats = { distinct = 0, total = 0, chars = 0 }
    if type(owners) ~= "table" then return rows, stats end

    -- class 8: the walk order is chosen, not inherited.
    local keys = {}
    for key, o in pairs(owners) do
        if type(key) == "string" and key ~= "" and type(o) == "table" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    stats.chars = #keys

    for i = 1, #keys do
        local key = keys[i]
        local counts = owners[key].itemCounts
        if type(counts) == "table" then
            local ids = {}
            for id, n in pairs(counts) do
                local ni, nn = tonumber(id), tonumber(n)
                if ni and nn and ni > 0 and nn > 0 then ids[#ids + 1] = ni end
            end
            table.sort(ids)
            for j = 1, #ids do
                local id = ids[j]
                local n  = tonumber(counts[id])
                local row = byId[id]
                if not row then
                    row = { id = id, total = 0, holders = 0, split = {} }
                    byId[id] = row
                    rows[#rows + 1] = row
                end
                row.total   = row.total + n
                row.holders = row.holders + 1
                row.split[#row.split + 1] = { key = key, count = n }
                stats.total = stats.total + n
            end
        end
    end

    table.sort(rows, function(a, b) return a.id < b.id end)
    stats.distinct = #rows
    return rows, stats
end

----------------------------------------------------------------------
-- THE WORK METER
--
-- One counter per PASS, bumped once when the pass runs and never once per item,
-- so the budget pins are call-counted evidence rather than a tax on the hot
-- loop. `slices` is how many frames a build took; `repaintsAsked` vs
-- `repaintsRun` is the coalescer's whole story in two numbers.
----------------------------------------------------------------------

InvUI.WORK = {
    ledger = 0,        -- (owner,item) entries folded
    slices = 0,        -- ledger slices run (== frames a build occupied)
    builds = 0,        -- ledger builds STARTED (a cache hit starts none)
    decorate = 0,      -- rows re-read from the client
    filter = 0,        -- rows judged by the filter
    sort = 0,          -- rows handed to a sort
    ask = 0,           -- warm-load asks actually issued
    paint = 0,         -- row frames painted
    repaintsAsked = 0, -- repaints REQUESTED (one per client answer)
    repaintsRun = 0,   -- repaints actually run (the coalescer's output)
}

function InvUI.ResetWork()
    for k in pairs(InvUI.WORK) do InvUI.WORK[k] = 0 end
end

----------------------------------------------------------------------
-- THE STORE GENERATION
--
-- The ledger is a pure function of the owners graph, so it only needs rebuilding
-- when that graph moves. The signal is not invented here: it is the SAME pair
-- ns.Tooltips already listens to in order to drop its own 1-second owners cache
-- (tooltips.lua: STORE_REFRESHED, ACCOUNT_ID_CHANGED). Reusing it means the
-- ledger cache can never outlive the data it was built from — the two caches
-- are dropped by one signal, not by two rules that could drift.
--
-- `factGen` is the other axis: it moves when the CLIENT answers something (a
-- coalesced GET_ITEM_INFO_RECEIVED burst), which is what makes a re-decorate
-- worth doing. A refresh that moves neither is a repaint.
----------------------------------------------------------------------

InvUI._gen, InvUI._factGen = 1, 1
function InvUI.Generation()        return InvUI._gen end
function InvUI.FactGeneration()    return InvUI._factGen end
function InvUI.BumpGeneration()     InvUI._gen     = InvUI._gen + 1     end
function InvUI.BumpFactGeneration() InvUI._factGen = InvUI._factGen + 1 end

if ns.On then
    ns:On("STORE_REFRESHED",    function() InvUI.BumpGeneration() end)
    ns:On("ACCOUNT_ID_CHANGED", function() InvUI.BumpGeneration() end)
end

----------------------------------------------------------------------
-- THE SLICED LEDGER — the same transpose, spread over frames
--
-- BuildLedger above is kept EXACTLY as it was and is now the ORACLE: the suite
-- pins the sliced job against it row for row, split for split, stat for stat, at
-- several chunk sizes. Two independent implementations agreeing is a real pin;
-- one implementation compared with itself is not. It is also the RED CONTROL —
-- yesterday's shape, every entry in one frame — and the budget pins assert the
-- sliced path never does that much in one step.
--
-- Resumption is at (owner, item) granularity. An owner's id collection and sort
-- happens when that owner is first entered and is charged to the budget at #ids,
-- so a character holding a very full bank cannot silently buy a long frame.
----------------------------------------------------------------------

-- (owner,item) entries folded per slice. Measured at ~0.8us per entry headless,
-- so 2000 is a ~1.6ms slice — under a frame at 60fps with room for the client.
InvUI.BUILD_CHUNK = 2000

-- Repaint the partial table every Nth slice (and always on the first). A
-- filter+sort per slice would make the slicing itself quadratic, which is the
-- defect this whole section exists to remove.
InvUI.PAINT_EVERY = 8

function InvUI.NewLedgerJob(owners, chunk)
    return {
        owners = (type(owners) == "table") and owners or EMPTY,
        chunk  = math.max(1, math.floor(tonumber(chunk) or InvUI.BUILD_CHUNK)),
        keys = {}, ki = 0,          -- the sorted owner keys, and how far in we are
        ids  = nil, ii = 0,         -- the current owner's sorted ids, and our place
        byId = {},
        rows = {},                  -- LIVE: the pane paints this array as it grows
        stats = { distinct = 0, total = 0, chars = 0 },
        phase = "keys", done = false,
    }
end

-- How far along a job is, in CHARACTERS — the unit the progress line speaks in.
function InvUI.LedgerProgress(job)
    if type(job) ~= "table" then return 0, 0 end
    local total = #(job.keys or EMPTY)
    if job.done then return total, total end
    local at = math.floor(tonumber(job.ki) or 0)
    if at < 0 then at = 0 end
    if at > total then at = total end
    return at, total
end

-- Run ONE slice. Returns done, work. Calling it on a finished job is a no-op, so
-- a stray pump cannot corrupt a completed ledger.
function InvUI.StepLedger(job)
    if type(job) ~= "table" or job.done then return true, 0 end
    local budget, work = job.chunk, 0

    if job.phase == "keys" then
        -- class 8: the walk order is chosen, not inherited (BuildLedger's rule).
        local keys = {}
        for key, o in pairs(job.owners) do
            if type(key) == "string" and key ~= "" and type(o) == "table" then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        job.keys = keys
        job.stats.chars = #keys
        job.phase = "scan"
        InvUI.WORK.ledger = InvUI.WORK.ledger + #keys
        InvUI.WORK.slices = InvUI.WORK.slices + 1
        return false, #keys
    end

    if job.phase == "scan" then
        while work < budget do
            if job.ids == nil then
                job.ki = job.ki + 1
                if job.ki > #job.keys then job.phase = "order" break end
                local counts = job.owners[job.keys[job.ki]].itemCounts
                local ids = {}
                if type(counts) == "table" then
                    for id, n in pairs(counts) do
                        local ni, nn = tonumber(id), tonumber(n)
                        if ni and nn and ni > 0 and nn > 0 then ids[#ids + 1] = ni end
                    end
                    table.sort(ids)
                end
                job.ids, job.ii = ids, 0
                work = work + #ids          -- the collect + sort is real work
            end
            local key    = job.keys[job.ki]
            local counts = job.owners[key].itemCounts
            local ids    = job.ids
            while job.ii < #ids and work < budget do
                job.ii = job.ii + 1
                local id  = ids[job.ii]
                local n   = tonumber(counts[id])
                local row = job.byId[id]
                if not row then
                    row = { id = id, total = 0, holders = 0, split = {} }
                    job.byId[id] = row
                    job.rows[#job.rows + 1] = row
                end
                row.total   = row.total + n
                row.holders = row.holders + 1
                row.split[#row.split + 1] = { key = key, count = n }
                job.stats.total = job.stats.total + n
                work = work + 1
            end
            if job.ii >= #ids then job.ids = nil end
        end
        -- The partial truth, so a mid-build reader sees what has landed rather
        -- than a zero. The pane still refuses to PRINT these as totals — see
        -- InvUI.ProgressText.
        job.stats.distinct = #job.rows
        InvUI.WORK.ledger = InvUI.WORK.ledger + work
        InvUI.WORK.slices = InvUI.WORK.slices + 1
        -- ALWAYS hand the frame back here, even when the scan just finished: the
        -- closing sort is its own unit of work (D rows, not entries) and gets its
        -- own slice, so no single frame pays for both.
        return false, work
    end

    -- The canonical base order, item id ascending — BuildLedger's own final sort,
    -- run once at the end for exactly the same result.
    table.sort(job.rows, function(a, b) return a.id < b.id end)
    job.stats.distinct = #job.rows
    job.phase, job.done = "done", true
    InvUI.WORK.ledger = InvUI.WORK.ledger + #job.rows
    InvUI.WORK.slices = InvUI.WORK.slices + 1
    return true, #job.rows
end

-- Drive a job to completion here and now. The no-timer fallback, and the suite's
-- handle on the sliced path.
function InvUI.RunLedger(owners, chunk)
    local job = InvUI.NewLedgerJob(owners, chunk)
    local steps = 0
    while not InvUI.StepLedger(job) do
        steps = steps + 1
        if steps > 1e6 then break end     -- a fuse, never reached by real data
    end
    return job.rows, job.stats, steps + 1
end

-- PURE. What the pane says WHILE the transpose is running. The COUNTS are
-- deliberately absent: a partial transpose understates every total, and a number
-- that is still going to change is not a total. The rows paint as they arrive;
-- this line is what stops them being read as the whole answer.
function InvUI.ProgressText(charsDone, charsTotal)
    local t = math.floor(tonumber(charsTotal) or 0)
    if t <= 0 then return nil end
    local d = math.floor(tonumber(charsDone) or 0)
    if d < 0 then d = 0 end
    if d > t then d = t end
    return "indexing " .. InvUI.Commas(d) .. " of " .. InvUI.Commas(t)
        .. (t == 1 and " character" or " characters") .. InvUI.GLYPHS.dots
end

-- PURE. Roster coverage, for the footer. `chars` is every owner record we hold;
-- `oldest` is the age in seconds of the STALEST stamped record, or nil when no
-- record carries a usable stamp (in which case the footer omits the age clause
-- rather than inventing one). `stamped` is how many records had a stamp at all,
-- so "oldest" is never quoted as if it covered characters it did not.
--
-- The stamp is the owner record's `ts` — the payload's own capture time, which
-- ns.Tooltips.ToOwnerRecord already resolves from the payload with the store
-- entry's updatedAt as its fallback. Nothing new is stored for this.
function InvUI.Coverage(owners, nowE)
    local out = { chars = 0, stamped = 0, oldest = nil, oldestKey = nil }
    if type(owners) ~= "table" then return out end
    nowE = tonumber(nowE) or 0

    local keys = {}
    for key, o in pairs(owners) do
        if type(key) == "string" and key ~= "" and type(o) == "table" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)                       -- class 8: the tie-break below depends on it
    out.chars = #keys

    for i = 1, #keys do
        local ts = tonumber(owners[keys[i]].ts) or 0
        if ts > 0 then
            out.stamped = out.stamped + 1
            local age = nowE - ts
            if age < 0 then age = 0 end    -- a clock ahead of us is not negative staleness
            if out.oldest == nil or age > out.oldest then
                out.oldest, out.oldestKey = age, keys[i]
            end
        end
    end
    return out
end

-- PURE. The footer line. `fmt` formats a duration (Dashboard.FormatDuration live,
-- injectable so this stays pure); when it is absent the age clause is dropped
-- rather than printed in raw seconds.
function InvUI.FooterText(stats, cov, fmt)
    stats = type(stats) == "table" and stats or EMPTY
    cov   = type(cov)   == "table" and cov   or EMPTY
    local mid = " " .. InvUI.GLYPHS.middot .. " "

    local distinct = tonumber(stats.distinct) or 0
    local total    = tonumber(stats.total) or 0
    local parts = {
        InvUI.Commas(distinct) .. (distinct == 1 and " item" or " items"),
        InvUI.Commas(total) .. " total",
    }

    local chars = tonumber(cov.chars) or 0
    if chars > 0 then
        local line = InvUI.Commas(chars) .. (chars == 1 and " character" or " characters")
        if cov.oldest and fmt then
            local ok, age = pcall(fmt, cov.oldest)
            if ok and type(age) == "string" and age ~= "" then
                line = line .. ", oldest data " .. age .. " ago"
            end
        end
        parts[#parts + 1] = line
    end
    return table.concat(parts, mid)
end

----------------------------------------------------------------------
-- COLD ITEM DATA  (class 4 — see the header)
----------------------------------------------------------------------

local _facts = {}          -- [itemID] = <resolved facts>, session cache
local _askCount = {}       -- ["item:<id>"] = asks spent

function InvUI.ClearCaches()
    _facts, _askCount = {}, {}
    InvUI.ClearAskQueue()          -- defined with the ask ladder below
end

-- The live resolver. `item(id)` answers a facts table, or nil meaning "the client
-- has not told us yet". nil is never a name and never an empty string.
--
-- GetItemInfo's returns, by position: 1 name, 3 quality, 6 itemType, 10 texture.
-- The NAME is the resolution test: no name, no facts at all (see the ONE CERTAINTY
-- rule in the header). A row is only ever cached once it has resolved, so a cold
-- read is re-asked on the next render rather than being remembered as a miss.
function InvUI.LiveResolver()
    return {
        item = function(id)
            id = tonumber(id)
            if not id then return nil end
            local hit = _facts[id]
            if hit then return hit end

            local name, quality, itemType, texture
            local f = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
            if f then
                local ok, n1, _link, q, _ilvl, _minl, ity, _sub, _stack, _eq, tex =
                    pcall(f, id)
                if ok then name, quality, itemType, texture = n1, q, ity, tex end
            end
            if type(name) ~= "string" or name == "" then return nil end

            local rec = {
                id       = id,
                name     = name,
                quality  = tonumber(quality),
                icon     = texture,
                category = (type(itemType) == "string" and itemType ~= "") and itemType or nil,
            }
            _facts[id] = rec
            return rec
        end,
        -- The client's own answer to "is this item's data already here?". Used
        -- ONLY to suppress a pointless warm-load request; it never decides
        -- whether a row is resolved (the name does).
        cached = function(id)
            local f = _G.C_Item and _G.C_Item.IsItemDataCachedByID
            if not f then return nil end
            local ok, v = pcall(f, id)
            if not ok then return nil end
            return v and true or false
        end,
    }
end

-- Attach the client's facts to every row IN PLACE, and answer the sorted list of
-- ids still cold.
--
-- A row that was resolved and is being re-decorated keeps its facts; a row that is
-- NOT resolved has its fact fields CLEARED rather than left standing, so a stale
-- name from an earlier decoration can never survive a cache wipe and be presented
-- as current.
--
-- `sortKey` is the row's lowercased name, computed ONCE here. SortRows compares
-- names O(n log n) times and used to call name:lower() inside the comparator,
-- allocating a transient string per COMPARISON — measured, that is why a warm
-- sort (6.3 ms over 1,617 rows) cost more than twice a cold one (2.9 ms). It is
-- cleared with the rest of the facts when a row goes cold, so it can never
-- outlive the name it was derived from.
function InvUI.Decorate(rows, res)
    local pending = {}
    if type(rows) ~= "table" then return pending end
    local get = res and res.item
    for i = 1, #rows do
        local r = rows[i]
        local f = get and get(r.id) or nil
        if f then
            r.name, r.quality, r.icon, r.category = f.name, f.quality, f.icon, f.category
            r.sortKey  = (type(f.name) == "string") and f.name:lower() or nil
            r.resolved = true
        else
            r.name, r.quality, r.icon, r.category = nil, nil, nil, nil
            r.sortKey  = nil
            r.resolved = false
            pending[#pending + 1] = r.id
        end
    end
    table.sort(pending)        -- class 8: this list drives a bounded retry loop
    InvUI.WORK.decorate = InvUI.WORK.decorate + #rows
    return pending
end

-- Ask the client to warm the ids we could not read, bounded per id. An id the
-- server has no data for answers forever with success=false, so an unbounded
-- ask/repaint pair trades a stuck table for an event storm.
InvUI.MAX_ASKS = 3
function InvUI.AskFor(ids, res)
    if type(ids) ~= "table" then return 0 end
    local isCached = res and res.cached
    local asked = 0
    for i = 1, #ids do
        local id = ids[i]
        local key = "item:" .. tostring(id)
        local n = _askCount[key] or 0
        if n < InvUI.MAX_ASKS then
            -- Already in the client's cache: another request cannot make it
            -- warmer, so it is spent noise. (The ask counter is still charged,
            -- so a permanently-cached-but-nameless id cannot loop either.)
            local skip = false
            if isCached then skip = (isCached(id) == true) end
            _askCount[key] = n + 1
            asked = asked + 1
            if not skip and _G.C_Item and _G.C_Item.RequestLoadItemDataByID then
                pcall(_G.C_Item.RequestLoadItemDataByID, id)
            end
        end
    end
    return asked
end

----------------------------------------------------------------------
-- THE ASK QUEUE — bounded rate, viewport first
--
-- MEASURED (see FIRST OPEN COSTS WHAT IT MEASURES): a fresh session's first open
-- fired ~1,617 warm-load asks in ONE frame, and the client answered every one
-- with its own GET_ITEM_INFO_RECEIVED — an echo per ask, each of which used to
-- buy a full repaint. Asking for everything at once is what made the answers
-- arrive as a storm.
--
-- So the asks go through a QUEUE instead. It is drained ASK_BUDGET at a time,
-- ASK_PERIOD apart, and the rows ACTUALLY ON SCREEN are moved to the head
-- (PromoteAsks, called by the renderer): the owner gets names for what they are
-- looking at first, and the rest trickle in — or arrive sooner, as they scroll
-- into view and get promoted.
--
-- AskFor is the queue's ONE exit. Its per-id MAX_ASKS bound, its EXHAUSTED
-- marking and its already-cached suppression are untouched and still the only
-- rules about whether an id may be asked at all; the queue only decides WHEN.
----------------------------------------------------------------------

InvUI.ASK_BUDGET = 40      -- asks per drain
InvUI.ASK_PERIOD = 1       -- seconds between drains

local askQueue, askQueued = {}, {}

function InvUI.AskQueueDepth() return #askQueue end
function InvUI.ClearAskQueue() askQueue, askQueued = {}, {} end

-- Enqueue ids we still need names for. Duplicates are dropped, order of first
-- arrival is kept (class 8: the drain order is chosen, never inherited).
function InvUI.QueueAsks(ids)
    if type(ids) ~= "table" then return 0 end
    local added = 0
    for i = 1, #ids do
        local id = tonumber(ids[i])
        if id and not askQueued[id] then
            askQueued[id] = true
            askQueue[#askQueue + 1] = id
            added = added + 1
        end
    end
    return added
end

-- Move the ids on screen to the head of the queue, KEEPING relative order inside
-- both halves — a stable partition, so two renders of one viewport produce one
-- queue order. Returns how many were promoted.
function InvUI.PromoteAsks(ids)
    if type(ids) ~= "table" or #ids == 0 or #askQueue == 0 then return 0 end
    local want = {}
    for i = 1, #ids do
        local id = tonumber(ids[i])
        if id and askQueued[id] then want[id] = true end
    end
    local head, tail = {}, {}
    for i = 1, #askQueue do
        local id = askQueue[i]
        if want[id] then head[#head + 1] = id else tail[#tail + 1] = id end
    end
    if #head == 0 or #tail == 0 then return #head end
    for i = 1, #head do askQueue[i] = head[i] end
    for i = 1, #tail do askQueue[#head + i] = tail[i] end
    return #head
end

-- Drain at most `budget` ids through AskFor. Returns asked, remaining.
function InvUI.DrainAsks(res, budget)
    budget = math.floor(tonumber(budget) or InvUI.ASK_BUDGET)
    if budget < 0 then budget = 0 end
    if budget == 0 or #askQueue == 0 then return 0, #askQueue end
    local n = math.min(budget, #askQueue)
    local slice = {}
    for i = 1, n do
        slice[i] = askQueue[i]
        askQueued[askQueue[i]] = nil
    end
    local rest = {}
    for i = n + 1, #askQueue do rest[#rest + 1] = askQueue[i] end
    askQueue = rest
    local asked = InvUI.AskFor(slice, res)
    InvUI.WORK.ask = InvUI.WORK.ask + asked
    return asked, #askQueue
end

-- PURE. The bounded re-ask ladder (ProfUI's idiom): rungs, then STOP claiming to
-- be loading. A ladder with no last rung is the same lie in a slower voice.
InvUI.WATCH_LADDER = { 0.25, 0.5, 1, 2, 4 }
function InvUI.LadderDelay(round)
    local n = tonumber(round)
    if not n then return nil end
    return InvUI.WATCH_LADDER[n]
end
function InvUI.LadderCeiling()
    local t = 0
    for i = 1, #InvUI.WATCH_LADDER do t = t + InvUI.WATCH_LADDER[i] end
    return t
end

----------------------------------------------------------------------
-- CATEGORIES, SEARCH, SORT — all pure, all composing
----------------------------------------------------------------------

-- The explicit bucket that holds every row the client has not named. It is a
-- SENTINEL, not a localized item class: no client itemType can collide with it,
-- because every real one is a plain word in the player's own language.
InvUI.UNRESOLVED = "(unresolved)"
InvUI.ALL        = ""            -- "no category filter", persisted as ""

-- PURE. The distinct item classes present in the ledger, sorted, plus whether any
-- row is still cold. The chip offers ONLY categories that actually exist, so it
-- can never present an empty bucket.
function InvUI.Categories(rows)
    local seen, out, cold = {}, {}, false
    if type(rows) ~= "table" then return out, false end
    for i = 1, #rows do
        local r = rows[i]
        if r.resolved and type(r.category) == "string" and r.category ~= "" then
            if not seen[r.category] then
                seen[r.category] = true
                out[#out + 1] = r.category
            end
        elseif not r.resolved then
            cold = true
        end
    end
    table.sort(out)
    return out, cold
end

-- PURE. The chip's value ring, in order: All, every present category, and the
-- unresolved bucket last when there is anything in it.
function InvUI.CategoryChoices(rows)
    local cats, cold = InvUI.Categories(rows)
    local out = { InvUI.ALL }
    for i = 1, #cats do out[#out + 1] = cats[i] end
    if cold then out[#out + 1] = InvUI.UNRESOLVED end
    return out
end

-- PURE. What the chip prints for a value.
function InvUI.CategoryLabel(v)
    if v == nil or v == InvUI.ALL then return "All" end
    return tostring(v)
end

-- PURE. A persisted category that no longer exists in the current ledger must not
-- filter invisibly from SavedVariables (the ValidGridFilter idiom). Returns the
-- value to use — the saved one when it is still offered, InvUI.ALL otherwise.
function InvUI.ValidCategory(v, choices)
    if v == nil or v == InvUI.ALL then return InvUI.ALL end
    if type(choices) ~= "table" then return InvUI.ALL end
    for i = 1, #choices do
        if choices[i] == v then return v end
    end
    return InvUI.ALL
end

-- PURE. Search + category, composed. See THE FILTER POLICY in the header for why
-- each unresolved branch answers the way it does.
--
-- Returns rows, state where state = { matched, pendingHidden, unresolvedShown,
-- hasQuery } — `pendingHidden` is the count of cold rows this pass could not
-- judge, which is what the status line reports and what makes "no matches" and
-- "we have not been told yet" different sentences.
function InvUI.FilterRows(rows, query, category)
    local out = {}
    local state = { matched = 0, pendingHidden = 0, unresolvedShown = 0, hasQuery = false }
    if type(rows) ~= "table" then return out, state end

    local q = ""
    if type(query) == "string" then
        q = query:lower()
        q = q:gsub("^%s+", "")
        q = q:gsub("%s+$", "")
    end
    local hasQuery = (q ~= "")
    state.hasQuery = hasQuery

    local cat = (type(category) == "string" and category ~= "") and category or nil

    for i = 1, #rows do
        local r = rows[i]
        local keep
        if r.resolved then
            keep = true
            -- plain find: a user typing "+" is searching, not writing a pattern.
            if hasQuery and not tostring(r.name):lower():find(q, 1, true) then keep = false end
            if keep and cat then
                if cat == InvUI.UNRESOLVED then keep = false
                elseif r.category ~= cat then keep = false end
            end
        elseif hasQuery then
            -- No name to match. NOT a miss — an unanswered question, counted.
            keep = false
            state.pendingHidden = state.pendingHidden + 1
        elseif cat == nil then
            keep = true                                  -- no claim is being made
        elseif cat == InvUI.UNRESOLVED then
            keep = true                                  -- the explicit bucket
        else
            keep = false                                 -- we were not told its class
            state.pendingHidden = state.pendingHidden + 1
        end
        if keep then
            out[#out + 1] = r
            if not r.resolved then
                state.unresolvedShown = state.unresolvedShown + 1
            end
        end
    end
    state.matched = #out
    InvUI.WORK.filter = InvUI.WORK.filter + #rows
    return out, state
end

InvUI.SORTS = { "name", "qty" }

-- PURE. The QTY header toggles quantity-desc on and back off; the ITEM header
-- always selects name-ascending. (ProfUI.NextGridFilter's shape.)
function InvUI.NextSort(current, clicked)
    if clicked == "qty" then
        return (current == "qty") and "name" or "qty"
    end
    return "name"
end

-- PURE. A TOTAL order, in every mode (class 8).
--   qty  : quantity descending, then the name rule, then item id
--   name : resolved rows first (an unresolved row has no name to place, so it
--          sorts to the end rather than to a guessed position), then name
--          ascending case-insensitively, then item id
-- Item id is the final tiebreak in both modes, so two builds of one fixture — and
-- two applications of one mode — are identical row for row.
-- Returns a NEW array; the input order is never mutated.
function InvUI.SortRows(rows, mode)
    mode = (mode == "qty") and "qty" or "name"
    local out = {}
    if type(rows) ~= "table" then return out end
    for i = 1, #rows do out[i] = rows[i] end
    InvUI.WORK.sort = InvUI.WORK.sort + #out

    -- PRECOMPUTED by Decorate (see its note): this runs once per COMPARISON, so
    -- a :lower() here allocated O(n log n) transient strings. A hand-built row
    -- that never met Decorate still answers correctly — it just pays for it.
    -- Nothing is written back: SortRows stays pure.
    local function nameKey(r)
        if r.resolved and type(r.name) == "string" and r.name ~= "" then
            return r.sortKey or r.name:lower()
        end
        return nil
    end

    table.sort(out, function(a, b)
        if mode == "qty" then
            local at, bt = tonumber(a.total) or 0, tonumber(b.total) or 0
            if at ~= bt then return at > bt end
        end
        local an, bn = nameKey(a), nameKey(b)
        if (an ~= nil) ~= (bn ~= nil) then return an ~= nil end
        if an and bn and an ~= bn then return an < bn end
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    return out
end

-- PURE. The two things this table may say about its own certainty, and the words
-- it says them in. (ProfUI.StatusText, specialised to items.)
--   state = { matched, pendingHidden, hasQuery, exhausted, ledgerEmpty, moduleOff,
--             indexing }
-- `indexing` is the transpose still running (a string = the progress line to
-- print). It outranks ledgerEmpty because an empty PARTIAL ledger is not an
-- empty one, and "No item counts yet" would be a claim we cannot make while we
-- are still counting.
-- Returns emptyText (nil when rows are on screen) and statusText (nil when there
-- is nothing to add). matched == 0 with pendingHidden > 0 is NOT "no matches" — it
-- is "we have not been told yet", and it must read as that.
function InvUI.StatusText(state)
    state = type(state) == "table" and state or EMPTY
    local matched   = tonumber(state.matched) or 0
    local pending   = tonumber(state.pendingHidden) or 0
    local exhausted = state.exhausted and true or false
    local dots      = InvUI.GLYPHS.dots

    local phrase = (pending == 1) and "1 name" or (tostring(pending) .. " names")

    if matched == 0 then
        if state.moduleOff then
            return InvUI.EmptyText({ moduleOff = true }), nil
        end
        if state.indexing then
            return (type(state.indexing) == "string" and state.indexing ~= "")
                and state.indexing or ("indexing" .. dots), nil
        end
        if state.ledgerEmpty then
            return InvUI.EmptyText({ ledgerEmpty = true }), nil
        end
        if pending > 0 and not exhausted then
            return "Still loading " .. phrase .. dots, nil
        elseif pending > 0 then
            return "No match among the names that answered " .. InvUI.GLYPHS.dash
                .. " " .. phrase .. " never loaded.", nil
        end
        return state.hasQuery and "No match." or "Nothing here.", nil
    end
    if pending > 0 and not exhausted then
        return nil, "still loading " .. phrase .. dots
    elseif pending > 0 then
        return nil, phrase .. " never loaded"
    end
    return nil, nil
end

-- PURE. The honest empty page. A tab that is ALWAYS present has to explain its own
-- emptiness in words, because it cannot explain it by being absent.
function InvUI.EmptyText(state)
    state = type(state) == "table" and state or EMPTY
    if state.moduleOff then
        return "The Inventory module is switched off, so no cross-account item"
            .. " counts are being collected. Turn it on in Settings."
    end
    if state.ledgerEmpty then
        return "No item counts yet. Each character fills this in the first time you"
            .. " play it; peers arrive over the mesh."
    end
    return "Nothing here."
end

----------------------------------------------------------------------
-- THE HOVER — the per-character breakdown, through the EXISTING machinery
----------------------------------------------------------------------

-- The per-character holder rows for one item, from ns.Tooltips: BuildCountLines
-- produces the class-colored, self-first holder lines and BuildTooltipRows
-- partitions them into the rendered row model (Total header, this account's rows,
-- a spacer, the "Other Accounts" section, the rest). That is the exact machinery
-- the cross-account item tooltips and Daseeki-Bags' Find already render, pinned
-- across both addons by the harness's parity gate — so this tab's hover is the
-- same block the owner already knows, not a lookalike.
--
-- Returns rows, total, or nil when the seam is absent or nobody holds the item.
function InvUI.BreakdownRows(owners, itemID, viewerKey)
    local T = ns.Tooltips
    if not (T and T.BuildCountLines and T.BuildTooltipRows) then return nil end
    if type(owners) ~= "table" or not itemID then return nil end
    local lines = T.BuildCountLines(owners, itemID, viewerKey)
    if type(lines) ~= "table" or #lines == 0 then return nil end
    local rows, total = T.BuildTooltipRows(lines)
    return rows, total
end

-- PURE. The pooled-cell lesson (Daseeki-Bags' bank tooltips, via
-- ProfUI.TooltipStaleOnPaint): may a repaint leave the standing tooltip up? Only
-- if this row still shows the SAME item. Virtualization recycles a row on every
-- scroll tick, so this is consulted far more often here than in a pooled list.
function InvUI.TooltipStaleOnPaint(prevItem, newItem, ownedByRow)
    return (ownedByRow and prevItem ~= newItem) and true or false
end

-- Called by the paint path BEFORE a recycled row adopts a new item. Returns true
-- when it hid a tooltip (the re-hover renders the new content naturally).
function InvUI.RowTooltipOnPaint(tip, rr, newItem)
    if not tip then return false end
    local owned = (tip.GetOwner and tip:GetOwner() == rr) and true or false
    if InvUI.TooltipStaleOnPaint(rr and rr._item, newItem, owned) then
        if tip.Hide then tip:Hide() end
        return true
    end
    return false
end

-- Render one row's tooltip. Everything takes the TOOLTIP AS A PARAMETER (GameTooltip
-- live, a recording fake under the harness — the parity gate's idiom), so the whole
-- chain is exercised headless.
--
--   ctx = { owners, viewerKey, shift, ask, colored }
--
-- SHIFT is the real item tooltip, and it follows ProfUI.RenderRecipeTooltip's
-- precedent verbatim: SetHyperlink, then a >= 2 LINE COLD-READ CHECK — a title-only
-- item tooltip is the class-4 cold read, not an answer — and on a cold cache, ask
-- for the warm load, clear the half-drawn lines and fall through to the breakdown
-- rather than leaving a stub standing.
--
-- The DEFAULT (unshifted) hover deliberately does NOT SetHyperlink. Populating
-- GameTooltip with an item fires OnTooltipSetItem, which tooltips.lua hooks to
-- append this very block — so a hyperlink on every hover would draw the breakdown
-- twice on a Bags-less install. Shift is the one place the real tooltip is asked
-- for, and there the appended block is the same block every other item hover in
-- the game already gets.
--
-- Returns the mode that rendered: "item" | "breakdown" | "bare".
function InvUI.RenderRowTooltip(tip, row, ctx)
    ctx = type(ctx) == "table" and ctx or EMPTY
    if not (tip and type(row) == "table") then return nil end

    if ctx.shift then
        local ok = false
        if tip.SetHyperlink then
            ok = pcall(tip.SetHyperlink, tip, "item:" .. tostring(row.id))
        end
        local lines = 0
        if ok and tip.NumLines then
            local okN, n = pcall(tip.NumLines, tip)
            lines = (okN and tonumber(n)) or 0
        end
        if ok and lines >= 2 then return "item" end
        -- Cold cache: a fact about the CACHE, not about the item. Ask, wipe the
        -- partial draw, and show what we do know.
        if ctx.ask then ctx.ask({ row.id }) end
        if tip.ClearLines then pcall(tip.ClearLines, tip) end
    end

    local col = ctx.colored
    local function line(text, ink)
        if not (tip and tip.AddLine) then return end
        if col then
            local r, g, b = col(ink)
            if type(r) == "number" then tip:AddLine(text, r, g, b) return end
        end
        tip:AddLine(text)
    end

    -- The header: the item's own name, or the honest id when it has not answered.
    line(InvUI.DisplayName(row), "text")
    if not row.resolved then
        line("name not loaded yet" .. InvUI.GLYPHS.dots, "faint")
    end

    local rows = InvUI.BreakdownRows(ctx.owners, row.id, ctx.viewerKey)
    if not rows then
        line("Held by nobody we have counts for.", "faint")
        if tip.Show then tip:Show() end
        return "bare"
    end

    local T = ns.Tooltips
    for i = 1, #rows do
        local r = rows[i]
        if r.kind == "total" then
            line("Total: " .. InvUI.Commas(r.total), "muted")
        elseif r.kind == "char" then
            local left, right = r.line.name, tostring(r.line.total or 0)
            if T and T.RowStrings then
                local l, rt = T.RowStrings(r.line, r.badges)
                if l then left, right = l, rt end
            end
            if tip.AddDoubleLine then tip:AddDoubleLine(left, right)
            else line(tostring(left) .. "  " .. tostring(right), "text") end
        elseif r.kind == "spacer" then
            line(" ", "text")
        elseif r.kind == "section" then
            line(tostring(r.label), "muted")
        end
    end
    if tip.Show then tip:Show() end
    return "breakdown"
end

----------------------------------------------------------------------
-- THE OWNERS VIEW (the live seam; guarded, degrades to no rows)
----------------------------------------------------------------------

-- The owners universe this tab reads: ns.Tooltips.Owners(), which is
-- Store.InventoryOwners() converted to Bags-shaped records with this account's
-- characters stamped "full" and everybody else "summary", behind a 1-second cache.
-- Deliberately NOT gated on Tooltips.Status(): that gate answers "should Nexus
-- DRAW a block on somebody else's tooltip", which stands down whenever
-- Daseeki-Bags is loaded. This tab is Nexus's own surface and always draws itself.
function InvUI.Owners()
    local T = ns.Tooltips
    if T and T.Owners then
        local ok, owners = pcall(T.Owners)
        if ok and type(owners) == "table" then return owners end
    end
    return EMPTY
end

function InvUI.ViewerKey()
    local T = ns.Tooltips
    if T and T.SelfKey then
        local ok, k = pcall(T.SelfKey)
        if ok and type(k) == "string" and k ~= "" then return k end
    end
    local I = ns.Inventory
    if I and I.SelfKey then
        local ok, k = pcall(I.SelfKey)
        if ok and type(k) == "string" and k ~= "" then return k end
    end
    return nil
end

-- Is the data-collecting module switched off? (The tab still exists; it says so.)
function InvUI.ModuleOff()
    local I = ns.Inventory
    if I and I.IsEnabled then
        local ok, on = pcall(I.IsEnabled)
        if ok then return not on end
    end
    return false
end

----------------------------------------------------------------------
-- THE COLD-ITEM WATCHER
--
-- Created lazily, the FIRST time a render actually holds a pending id, and dropped
-- the moment nothing is pending. A tab that never meets a cold item never registers
-- a Blizzard event.
--
-- THE TERMINAL CONDITION IS PER ID, not per ladder (ProfUI's lesson): a ladder that
-- merely ends is not enough, because the next render finds the same unanswered id
-- and starts a fresh one — a loop with a LadderCeiling period that runs all session.
-- So when a ladder ends every id it was waiting on is marked EXHAUSTED and can
-- never start another. A NEW cold id still gets its own full ladder.
----------------------------------------------------------------------

local watcher    = nil
local watchRound = 0
local watching   = {}      -- "<id>" -> true, the ids this ladder is waiting on
local exhausted  = {}      -- "<id>" -> true, ids a completed ladder never got

local repaintPane          -- forward declaration; defined with the pane below

----------------------------------------------------------------------
-- THE COALESCER — the ~13 seconds, in one flag
--
-- Every warm-load ask the client answers fires GET_ITEM_INFO_RECEIVED, and a
-- fresh session's first open used to buy ~1,617 of them. Running the repaint
-- inline meant ~1,617 full Decorate+Filter+Sort passes, 8.0 ms each, arriving as
-- a stutter over the seconds after the click. It was never the click that was
-- slow; it was the answers.
--
-- So an answer no longer repaints. It marks the pane DIRTY and, if nothing is
-- armed already, arms ONE repaint REPAINT_DEBOUNCE later. A burst of a thousand
-- answers inside one window costs one repaint. WORK.repaintsAsked vs
-- WORK.repaintsRun is the whole story, and the suite budgets on the ratio.
--
-- With no timer seam (the harness, a client that never loaded C_Timer) the
-- repaint runs inline: refusing to repaint at all would be a worse answer than
-- repainting eagerly, and the harness drives this path deliberately.
----------------------------------------------------------------------

InvUI.REPAINT_DEBOUNCE = 0.2

local repaintDirty, repaintArmed = false, false

-- Run the pending repaint, if there is one. Returns whether it did anything.
function InvUI.RunRepaint()
    if not repaintDirty then return false end
    repaintDirty = false
    InvUI.WORK.repaintsRun = InvUI.WORK.repaintsRun + 1
    -- The client answered SOMETHING, so a re-decorate is now worth doing; the
    -- pane's warm path reads this to decide exactly that.
    InvUI.BumpFactGeneration()
    if repaintPane then repaintPane() end
    return true
end

function InvUI.RequestRepaint()
    InvUI.WORK.repaintsAsked = InvUI.WORK.repaintsAsked + 1
    repaintDirty = true
    if repaintArmed then return false end
    if not (_G.C_Timer and _G.C_Timer.After) then
        InvUI.RunRepaint()
        return true
    end
    repaintArmed = true
    _G.C_Timer.After(InvUI.REPAINT_DEBOUNCE, function()
        repaintArmed = false
        ns:SafeCall(InvUI.RunRepaint)
    end)
    return true
end

function InvUI._resetRepaint() repaintDirty, repaintArmed = false, false end

----------------------------------------------------------------------
-- THE ASK DRAIN — one ticker, alive only while the queue is
----------------------------------------------------------------------

local askTicking = false

local function startAskDrain()
    if askTicking then return end
    if not (_G.C_Timer and _G.C_Timer.After) then
        -- No timer seam: drain what we can now rather than queueing forever.
        InvUI.DrainAsks(InvUI.LiveResolver(), InvUI.ASK_BUDGET)
        return
    end
    askTicking = true
    local function tick()
        if InvUI.AskQueueDepth() == 0 then askTicking = false return end
        InvUI.DrainAsks(InvUI.LiveResolver(), InvUI.ASK_BUDGET)
        if InvUI.AskQueueDepth() == 0 then askTicking = false return end
        _G.C_Timer.After(InvUI.ASK_PERIOD, function() ns:SafeCall(tick) end)
    end
    tick()          -- the first budget goes out immediately (viewport first)
end
InvUI._startAskDrain = startAskDrain
function InvUI._resetAskDrain() askTicking = false end

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
InvUI.StopWatch = stopWatch

-- True once every pending id this session has run out its ladder — which is what
-- turns "still loading" into "never loaded" instead of leaving the first sentence
-- up forever.
function InvUI.Exhausted(ids)
    if type(ids) ~= "table" or #ids == 0 then return false end
    for i = 1, #ids do
        if not exhausted[tostring(ids[i])] then return false end
    end
    return true
end

local function startWatch()
    if watcher then return end
    if not _G.CreateFrame then return end
    local wf = _G.CreateFrame("Frame")
    -- COALESCED (see THE COALESCER): the event marks the pane dirty; it does not
    -- repaint. A thousand answers inside one debounce window cost one repaint.
    wf:SetScript("OnEvent", function() InvUI.RequestRepaint() end)
    pcall(function() wf:RegisterEvent("GET_ITEM_INFO_RECEIVED") end)
    watcher = wf
    if _G.C_Timer and _G.C_Timer.After then
        watchRound = 0
        local function rung()
            watchRound = watchRound + 1
            local d = InvUI.LadderDelay(watchRound)
            if not d then
                stopWatch()
                InvUI.RequestRepaint()
                return
            end
            _G.C_Timer.After(d, function()
                InvUI.RequestRepaint()
                rung()
            end)
        end
        rung()
    end
end

-- Called by every render that produced pending ids. Ids a completed ladder has
-- already given up on are dropped here, so they can neither re-ask nor re-arm.
--
-- BUDGETED (see THE ASK QUEUE): the fresh ids are QUEUED, not asked. The drain
-- sends ASK_BUDGET of them per ASK_PERIOD, viewport first. On a fresh session
-- this is the difference between 1,617 client queries in one frame and 40.
local function notePending(ids, res)
    if type(ids) ~= "table" or #ids == 0 then return false end
    local fresh = {}
    for i = 1, #ids do
        local key = tostring(ids[i])
        if not exhausted[key] then
            fresh[#fresh + 1] = ids[i]
            watching[key] = true
        end
    end
    if #fresh == 0 then return false end
    InvUI.QueueAsks(fresh)
    startAskDrain()
    startWatch()
    return true
end
InvUI._notePending = notePending

-- One reset for the whole cold-name machine, so a fresh look is genuinely fresh:
-- the ladder, the exhausted verdicts, the ask queue and the pending repaint.
function InvUI._resetWatchState()
    stopWatch()
    watching, exhausted = {}, {}
    InvUI.ClearAskQueue()
    InvUI._resetAskDrain()
    InvUI._resetRepaint()
end

-- ════════════════════════════════════════════════════════════════════════════
--  THE VIEW
--
--  Everything above this line is pure and headless-testable. Everything below is
--  frames, and is never reached by the harness (the pane is only built when the
--  shell selects the tab).
-- ════════════════════════════════════════════════════════════════════════════

-- Factory-local names are kept DISTINCT from every other UI file's (the static
-- anchor-graph gate is textual and conflates same-named locals), which is why each
-- helper below wears an `inv` prefix and its internals do too.

local function invFstr(invParent, roleKey, justify)
    local fs = invParent:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(Dashboard.Font(roleKey))
    if justify then fs:SetJustifyH(justify) end
    fs:SetWordWrap(false)
    return fs
end

local function invPanel(invHost, tagID)
    local pnl = CreateFrame("Frame", nil, invHost, "BackdropTemplate")
    UI.Skin(pnl, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("raised"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
    end)
    if Dashboard.RoundCorners then Dashboard.RoundCorners(pnl, 7, "ground") end
    Dashboard.Tag(pnl, tagID)
    return pnl
end

-- The labeled inline search box (the professions toolbar's control, in this
-- file's own names).
local function invSearchBox(invBar, captionText, boxWidth, onType)
    local sHolder = CreateFrame("Frame", nil, invBar)
    sHolder:SetSize(boxWidth, 24)
    local sCap = invFstr(sHolder, "small", "LEFT")
    sCap:SetText(captionText)
    sCap:SetPoint("LEFT", sHolder, "LEFT", 0, 0)
    UI.Skin(sCap, function(self) self:SetTextColor(UI.Color("muted")) end)
    local capW = math.max(1, (sCap:GetStringWidth() or 46) + 6)

    local sEdit = CreateFrame("EditBox", nil, sHolder, "BackdropTemplate")
    sEdit:SetPoint("LEFT", sCap, "RIGHT", 6, 0)
    sEdit:SetSize(math.max(60, boxWidth - capW), 22)
    sEdit:SetAutoFocus(false)
    sEdit:SetFontObject(Dashboard.Font("body"))
    sEdit:SetTextInsets(6, 6, 0, 0)
    UI.Skin(sEdit, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    sEdit:SetScript("OnTextChanged", function(self)
        if onType then onType(self:GetText() or "") end
    end)
    sEdit:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    sEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    sHolder._box = sEdit
    return sHolder
end

-- The CATEGORY chip. The professions SOURCE filter's cycling chip, with one
-- difference that matters: its ring is DATA-DERIVED, so it is rebuilt from the
-- ledger on every refresh and can only ever offer buckets that have something in
-- them. Left-click steps forward, right-click backward (a long ring is never a
-- long click), and the chip prints its axis with its value so the control is
-- labeled without a separate caption.
local function invCategoryChip(invBar, chipW, onPick)
    local chip = CreateFrame("Button", nil, invBar, "BackdropTemplate")
    chip:SetSize(chipW, 22)
    chip._ring  = { InvUI.ALL }
    chip._value = InvUI.ALL
    local cLbl = invFstr(chip, "small", "LEFT")
    cLbl:SetPoint("LEFT", chip, "LEFT", 7, 0)
    cLbl:SetPoint("RIGHT", chip, "RIGHT", -7, 0)
    chip._lbl = cLbl

    local function chipPaint()
        local on = (chip._value ~= InvUI.ALL)
        cLbl:SetText("CATEGORY: " .. InvUI.CategoryLabel(chip._value))
        chip:SetBackdropBorderColor(UI.Color(on and "accentDim" or "controlBorder"))
        cLbl:SetTextColor(UI.Color(on and "text" or "muted"))
    end
    UI.Skin(chip, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("control"))
        chipPaint()
    end)

    chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    chip:SetScript("OnClick", function(self, whichButton)
        local ring = self._ring
        if #ring < 2 then return end
        local at = 1
        for i = 1, #ring do if ring[i] == self._value then at = i break end end
        local step = (whichButton == "RightButton") and -1 or 1
        self._value = ring[((at - 1 + step) % #ring) + 1]
        chipPaint()
        if onPick then onPick(self._value) end
    end)

    -- Re-seat the ring from the current ledger, healing a persisted value that no
    -- longer exists (ValidCategory). Returns the value actually in force.
    function chip:SetRing(newRing, wanted)
        self._ring = (type(newRing) == "table" and #newRing > 0) and newRing or { InvUI.ALL }
        self._value = InvUI.ValidCategory(wanted or self._value, self._ring)
        chipPaint()
        return self._value
    end
    chipPaint()
    return chip
end

local function invScroller(invParent, tagID)
    local scr = CreateFrame("ScrollFrame", nil, invParent)
    scr:SetClipsChildren(true)
    scr:EnableMouseWheel(true)
    local kid = CreateFrame("Frame", nil, scr)
    kid:SetSize(1, 1)
    scr:SetScrollChild(kid)
    Dashboard.Tag(scr, tagID)
    return scr, kid
end

-- One pooled item row. NOTHING here bakes an x-position: every render calls
-- invFitRow with the SAME InvUI.RowColumns the header band uses, so a cell and its
-- caption cannot disagree and neither can outrun the pane that produced them.
local function invMakeRow(invListKid)
    local ir = CreateFrame("Button", nil, invListKid)
    ir:SetSize(1, L.ROW_H)                       -- width comes from the render
    local iHi = ir:CreateTexture(nil, "HIGHLIGHT")
    iHi:SetAllPoints()
    UI.Skin(iHi, function(self) self:SetColorTexture(UI.Color("accent", 0.12)) end)
    ir:SetHighlightTexture(iHi)

    local iIcon = ir:CreateTexture(nil, "ARTWORK")
    iIcon:SetPoint("LEFT", ir, "LEFT", L.ICON_X, 0)
    iIcon:SetSize(L.ICON_W, L.ICON_W)
    iIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)    -- trim the stock icon border

    local iName = invFstr(ir, "body", "LEFT")
    iName:SetPoint("LEFT", ir, "LEFT", 1, 0)     -- re-fit per render
    iName:SetWidth(1)
    local iQty = invFstr(ir, "numeral", "RIGHT")
    iQty:SetPoint("LEFT", ir, "LEFT", 1, 0)
    iQty:SetWidth(1)
    local iCat = invFstr(ir, "small", "LEFT")
    iCat:SetPoint("LEFT", ir, "LEFT", 1, 0)
    iCat:SetWidth(1)

    ir._icon, ir._name, ir._qty, ir._cat = iIcon, iName, iQty, iCat
    ir._item = nil

    ir:SetScript("OnEnter", function(self)
        if not self._row then return end
        if GameTooltip and GameTooltip.SetOwner then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        end
        InvUI.RenderRowTooltip(GameTooltip, self._row, {
            owners    = InvUI.Owners(),
            viewerKey = InvUI.ViewerKey(),
            shift     = _G.IsShiftKeyDown and _G.IsShiftKeyDown() or false,
            ask       = function(ids) return InvUI.AskFor(ids, InvUI.LiveResolver()) end,
            colored   = function(ink) return UI.Color(ink) end,
        })
    end)
    ir:SetScript("OnLeave", function()
        if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
    end)
    -- A pooled row hidden mid-hover (a scroll tick, a filter change) may not leave
    -- its tooltip standing either.
    ir:SetScript("OnHide", function(self)
        if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == self then
            GameTooltip:Hide()
        end
    end)
    return ir
end

-- Re-fit one pooled row to THIS render's column geometry: every cell width-capped
-- at its own column (the professions fitRecipeRow idiom).
local function invFitRow(ir, cols)
    ir._icon:SetPoint("LEFT", ir, "LEFT", cols.icon.x, 0)
    ir._icon:SetSize(math.max(1, cols.icon.w), math.max(1, cols.icon.w))
    ir._name:SetPoint("LEFT", ir, "LEFT", cols.name.x, 0)
    ir._name:SetWidth(math.max(1, cols.name.w))
    ir._qty:SetPoint("LEFT", ir, "LEFT", cols.qty.x, 0)
    ir._qty:SetWidth(math.max(1, cols.qty.w))
    ir._cat:SetPoint("LEFT", ir, "LEFT", cols.cat.x, 0)
    ir._cat:SetWidth(math.max(1, cols.cat.w))
end

local INV_NEUTRAL_ICON = "Interface/Icons/INV_Misc_QuestionMark"

local function invPaintRow(ir, row)
    -- The pooled-cell lesson, BEFORE the row adopts its new item.
    InvUI.RowTooltipOnPaint(GameTooltip, ir, row.id)
    ir._item, ir._row = row.id, row

    ir._icon:SetTexture(row.resolved and (row.icon or INV_NEUTRAL_ICON) or INV_NEUTRAL_ICON)
    ir._icon:SetDesaturated(not row.resolved)

    ir._name:SetText(InvUI.DisplayName(row))
    if row.resolved then
        local qr, qg, qb = InvUI.QualityRGB(row.quality)
        if qr then ir._name:SetTextColor(qr, qg, qb)
        else ir._name:SetTextColor(UI.Color("text")) end
    else
        ir._name:SetTextColor(UI.Color("faint"))
    end

    ir._qty:SetText(InvUI.Commas(row.total))
    ir._qty:SetTextColor(UI.Color("text"))
    ir._cat:SetText(InvUI.DisplayCategory(row))
    ir._cat:SetTextColor(UI.Color(row.resolved and "muted" or "faint"))
end

----------------------------------------------------------------------
-- THE PANE
----------------------------------------------------------------------

local thePane = nil

Dashboard.RegisterTab("inventory", function(host)
    local pane = {
        query    = "",
        category = InvUI.ALL,
        sort     = "name",
        obj      = {},
        _rows    = {},          -- the VIEWPORT-BOUNDED frame pool
        _ledger  = {},          -- the built ledger (base order: item id ascending)
        _stats   = {},
        _cov     = {},
        _view    = {},          -- filtered + sorted, what the window indexes into
        _pending = {},
        _state   = {},
        _job     = nil,         -- the sliced ledger build in flight, or nil
        _slice   = 0,
        _ledgerGen = nil,       -- the store generation _ledger was built from
        _factSeen  = nil,       -- the fact generation _ledger was decorated at
        _viewKey   = nil,       -- everything _view depends on, as one string
    }
    thePane = pane

    -- Persisted choices (the professions pane's st.prof idiom). The category is
    -- healed through ValidCategory on every rebuild, so a bucket that no longer
    -- exists can never filter invisibly out of SavedVariables.
    local st = Dashboard.UIState and Dashboard.UIState() or {}
    st.inv = st.inv or {}
    pane.category = (type(st.inv.category) == "string") and st.inv.category or InvUI.ALL
    pane.sort     = (st.inv.sort == "qty") and "qty" or "name"

    local function persist()
        st.inv.category = pane.category or InvUI.ALL
        st.inv.sort     = pane.sort
    end

    -- ── TOOLBAR: search + category ───────────────────────────────────────────
    local toolbar = CreateFrame("Frame", nil, host)
    toolbar:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    toolbar:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
    toolbar:SetHeight(L.TOOLBAR_H)
    Dashboard.Tag(toolbar, "inv.toolbar")

    local searchCtl = invSearchBox(toolbar, "SEARCH", L.SEARCH_W, function(text)
        pane.query = text or ""
        pane.obj.Apply()
    end)
    searchCtl:SetPoint("LEFT", toolbar, "LEFT", 2, 0)

    local catChip = invCategoryChip(toolbar, L.CHIP_W, function(v)
        pane.category = v
        persist()
        pane.obj.Apply()
    end)
    catChip:SetPoint("LEFT", searchCtl, "RIGHT", L.GUTTER, 0)

    -- ── THE TABLE PANEL ──────────────────────────────────────────────────────
    local tableP = invPanel(host, "inv.table")
    tableP:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -4)
    tableP:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)

    -- The clickable column-header band. Each cell is a Button so ITEM and QTY can
    -- select their sort; CATEGORY is a caption (the chip is its control).
    local headBand = CreateFrame("Frame", nil, tableP)
    headBand:SetPoint("TOPLEFT", tableP, "TOPLEFT", L.PANEL_PAD, -L.PANEL_PAD)
    headBand:SetPoint("TOPRIGHT", tableP, "TOPRIGHT", -L.PANEL_PAD, -L.PANEL_PAD)
    headBand:SetHeight(L.HEAD_H)
    headBand:SetClipsChildren(true)
    Dashboard.Tag(headBand, "inv.head")

    local headCells = {}
    for hi = 1, 3 do
        local hb = CreateFrame("Button", nil, headBand)
        hb:SetSize(1, L.HEAD_H)
        local hLbl = invFstr(hb, "small", "LEFT")
        hLbl:SetAllPoints(hb)
        hb._lbl = hLbl
        UI.Skin(hb, function(self) self._lbl:SetTextColor(UI.Color("muted")) end)
        hb:SetScript("OnClick", function(self)
            if not self._sort then return end
            pane.sort = InvUI.NextSort(pane.sort, self._sort)
            persist()
            pane.obj.Apply()
        end)
        headCells[hi] = hb
    end

    local listScroll, listKid = invScroller(tableP, "inv.list")
    listScroll:SetPoint("TOPLEFT", headBand, "BOTTOMLEFT", 0, -2)
    listScroll:SetPoint("BOTTOMRIGHT", tableP, "BOTTOMRIGHT",
        -L.PANEL_PAD, L.PANEL_PAD + InvUI.ListBottomInset())

    local emptyFS = invFstr(tableP, "body", "LEFT")
    emptyFS:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 2, -4)
    emptyFS:SetPoint("RIGHT", listScroll, "RIGHT", -2, 0)
    emptyFS:SetWordWrap(true)
    UI.Skin(emptyFS, function(self) self:SetTextColor(UI.Color("faint")) end)

    -- The footer band carries two texts and they share one baseline, so the
    -- coverage line ENDS where the loading note begins rather than running under
    -- it: the note sizes to its own content on the right, the footer's right edge
    -- is anchored to the note's left edge. With no note the footer has the band.
    local statusFS = invFstr(tableP, "small", "RIGHT")
    statusFS:SetPoint("BOTTOMRIGHT", tableP, "BOTTOMRIGHT", -L.PANEL_PAD, L.PANEL_PAD)
    UI.Skin(statusFS, function(self) self:SetTextColor(UI.Color("faint")) end)

    local footerFS = invFstr(tableP, "small", "LEFT")
    footerFS:SetPoint("BOTTOMLEFT", tableP, "BOTTOMLEFT", L.PANEL_PAD, L.PANEL_PAD)
    footerFS:SetPoint("RIGHT", statusFS, "LEFT", -L.GUTTER, 0)
    UI.Skin(footerFS, function(self) self:SetTextColor(UI.Color("muted")) end)

    ------------------------------------------------------------------
    -- Renderers
    ------------------------------------------------------------------

    local function getRow(i)
        local r = pane._rows[i]
        if not r then r = invMakeRow(listKid); pane._rows[i] = r end
        return r
    end

    -- The header band reads the SAME availW the rows do, through the same pure
    -- reader, so a caption can never sit where its column does not.
    local function layoutHead(availW)
        local cells = InvUI.HeaderCells(availW)
        for hi = 1, #cells do
            local spec = cells[hi]
            local hb = headCells[hi]
            hb:ClearAllPoints()
            hb:SetPoint("LEFT", headBand, "LEFT", spec.x, 0)
            hb:SetWidth(math.max(1, spec.w))
            hb._sort = spec.sort
            hb._lbl:SetJustifyH(spec.justify)
            local mark = ""
            if spec.sort and pane.sort == spec.sort then
                mark = (spec.sort == "qty") and (" " .. InvUI.GLYPHS.down) or " ^"
            end
            hb._lbl:SetText(spec.label .. mark)
            hb._lbl:SetTextColor(UI.Color(
                (spec.sort and pane.sort == spec.sort) and "text" or "muted"))
        end
    end

    -- Draw the VISIBLE SLICE only. The scroll child wears the full virtual height
    -- so the wheel still describes the whole list; the pool never grows past
    -- InvUI.PoolCeiling of the viewport (see VIRTUALIZED in the header).
    local function renderWindow()
        local availW = listScroll:GetWidth() or 0
        if availW < 2 then availW = InvUI.RowWidth() end
        local viewH = listScroll:GetHeight() or 0
        if viewH < 2 then viewH = L.ROW_H * 8 end

        local cols = InvUI.RowColumns(availW)
        layoutHead(availW)

        local n = #pane._view
        listKid:SetSize(math.max(1, availW), math.max(1, n * L.ROW_H))

        -- A list that just got SHORTER (a filter narrowing, names resolving into a
        -- category) can leave the ScrollFrame holding an offset past the new end,
        -- which draws a blank page with a full scrollbar. VisibleWindow clamps its
        -- own arithmetic; the frame has to be told separately or the two disagree.
        local scrolled = listScroll:GetVerticalScroll() or 0
        local maxOff = math.max(0, (n * L.ROW_H) - viewH)
        if scrolled > maxOff then
            scrolled = maxOff
            listScroll:SetVerticalScroll(scrolled)
        end

        local first, last, yTop = InvUI.VisibleWindow(scrolled, viewH, L.ROW_H, n)

        local slot, onScreen = 0, nil
        for i = first, last do
            slot = slot + 1
            local row = pane._view[i]
            local ir = getRow(slot)
            ir:ClearAllPoints()
            ir:SetPoint("TOPLEFT", listKid, "TOPLEFT", 0, -(yTop + (i - first) * L.ROW_H))
            ir:SetWidth(math.max(1, availW))
            invFitRow(ir, cols)
            invPaintRow(ir, row)
            ir:Show()
            if not row.resolved then
                onScreen = onScreen or {}
                onScreen[#onScreen + 1] = row.id
            end
        end
        for j = slot + 1, #pane._rows do pane._rows[j]:Hide() end
        InvUI.WORK.paint = InvUI.WORK.paint + slot

        -- VIEWPORT FIRST: the names the owner is looking at jump the ask queue.
        -- Scrolling is therefore also what fetches — a row asked for as it comes
        -- into view, rather than in a flood nobody was reading.
        if onScreen then InvUI.PromoteAsks(onScreen) end

        emptyFS:SetShown(n == 0)
    end

    listScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, (listKid:GetHeight() or 0) - (self:GetHeight() or 0))
        local cur = self:GetVerticalScroll() or 0
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * L.SCROLL_STEP)))
        renderWindow()
    end)
    listScroll:SetScript("OnSizeChanged", renderWindow)

    ------------------------------------------------------------------
    -- The three passes. Kept apart so a keystroke costs a filter+sort and never a
    -- rebuild of the whole ledger (thousands of rows, once per data change).
    ------------------------------------------------------------------

    -- Everything the rendered view is a function of, as one comparable string.
    -- When none of it moved, an Apply is a repaint and nothing more — which is
    -- what makes a second visit to the tab near-free, and what stops
    -- Dashboard.RefreshActive (STORE_REFRESHED, STATE_CHANGED, TIMER_UPDATED,
    -- NODE_UPDATED, CD_WARNING — several a second while the window is open) from
    -- re-filtering and re-sorting the whole mesh for a world-buff tick.
    local function viewKey()
        return table.concat({
            tostring(pane._ledgerGen), tostring(pane._factSeen),
            tostring(pane.query), tostring(pane.category), tostring(pane.sort),
            tostring(#pane._ledger),
        }, "\1")
    end

    -- filter -> sort -> draw. `force` is the build path, which must repaint even
    -- when the key has not moved (the ledger array grew in place).
    function pane.obj.Apply(force)
        local key = viewKey()
        if not force and pane._viewKey == key then
            -- Nothing the view depends on moved. Re-place the pooled rows (the
            -- pane may have been resized or re-shown) and stop. The owner's
            -- scroll position survives, which it did not before.
            renderWindow()
            return false
        end
        pane._viewKey = key

        local view, state = InvUI.FilterRows(pane._ledger, pane.query, pane.category)
        pane._view  = InvUI.SortRows(view, pane.sort)
        pane._state = state
        state.exhausted   = InvUI.Exhausted(pane._pending)
        state.moduleOff   = InvUI.ModuleOff()
        -- A build in flight: the ledger is PARTIAL, so it is neither empty nor a
        -- total. The progress line says which, and the footer says it instead of
        -- counts that are still moving.
        local job = pane._job
        local doneC, totalC = InvUI.LedgerProgress(job)
        local progress = job and InvUI.ProgressText(doneC, totalC) or nil
        state.indexing    = progress or (job and true or nil)
        state.ledgerEmpty = (not job) and (#pane._ledger == 0) or false

        local emptyText, statusText = InvUI.StatusText(state)
        emptyFS:SetText(emptyText or "")
        statusFS:SetText(statusText or "")
        footerFS:SetText(progress
            or InvUI.FooterText(pane._stats, pane._cov, Dashboard.FormatDuration))

        listScroll:SetVerticalScroll(0)
        renderWindow()
        return true
    end

    -- Re-read the client's item facts and queue what is still cold. Cheap (the
    -- resolver caches every answer), so the coalesced repaint can drive it.
    function pane.obj.Decorate()
        local res = InvUI.LiveResolver()
        pane._pending = InvUI.Decorate(pane._ledger, res)
        notePending(pane._pending, res)
        pane.category = catChip:SetRing(InvUI.CategoryChoices(pane._ledger), pane.category)
        persist()
        pane._factSeen = InvUI.FactGeneration()
    end

    -- ONE SLICE, then hand the frame back. The first slice paints, so the table
    -- is on screen while the rest of the mesh is still being folded in.
    function pane.obj.PumpBuild()
        local job = pane._job
        if not job then return end
        local finish = function()
            pane._job, pane._slice = nil, 0
            pane._ledgerGen = pane._buildGen
            pane.obj.Decorate()
            pane.obj.Apply(true)
        end
        if InvUI.StepLedger(job) then return finish() end
        pane._slice = pane._slice + 1
        if pane._slice == 1 or (pane._slice % InvUI.PAINT_EVERY) == 0 then
            pane.obj.Apply(true)
        end
        if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0, function() ns:SafeCall(pane.obj.PumpBuild) end)
        else
            -- No timer seam: finishing here beats leaving a half-built ledger
            -- standing and calling it the mesh's contents.
            while not InvUI.StepLedger(job) do end
            finish()
        end
    end

    -- Start a sliced rebuild for store generation `gen`.
    function pane.obj.StartBuild(gen)
        local owners = InvUI.Owners()
        pane._cov = InvUI.Coverage(owners,
            (GetServerTime and GetServerTime()) or (time and time()) or 0)
        local job = InvUI.NewLedgerJob(owners, InvUI.BUILD_CHUNK)
        pane._job, pane._buildGen, pane._slice = job, gen, 0
        -- The pane paints job.rows AS IT GROWS — the array is the live one, not
        -- a copy handed over at the end.
        pane._ledger, pane._stats = job.rows, job.stats
        pane._viewKey = nil
        InvUI.WORK.builds = InvUI.WORK.builds + 1
        pane.obj.PumpBuild()
    end

    -- The shell's entry point, called on every tab selection AND on five store
    -- events. It rebuilds ONLY when the store actually moved.
    function pane.obj.Refresh()
        if pane._job then return end                  -- a build is already running
        local gen = InvUI.Generation()
        if pane._ledgerGen == gen then
            -- WARM. Re-read the client only if it has answered since we looked.
            if pane._factSeen ~= InvUI.FactGeneration() then pane.obj.Decorate() end
            pane.obj.Apply()
            return
        end
        pane.obj.StartBuild(gen)
    end

    -- The coalescer's repaint: names only, never a ledger rebuild.
    repaintPane = function()
        if not thePane then return end
        if thePane._job then return end               -- the build will decorate
        thePane.obj.Decorate()
        thePane.obj.Apply(true)
    end

    pane.obj.Refresh()
    return pane.obj
end)

----------------------------------------------------------------------
-- SELF-TESTS
----------------------------------------------------------------------

-- Two accounts, five characters, overlapping stock — plus one item nobody but a
-- peer holds and one held by everybody, so the transpose has something to get
-- wrong. `source` is what tooltips.lua's model reads to partition the hover.
local function fixtureOwners()
    return {
        ["Poonyx-Whitemane"] = {
            nameRealm = "Poonyx-Whitemane", name = "Poonyx", class = "WARRIOR",
            race = "Human", sex = 2, faction = "Alliance", source = "full",
            ts = 1000, itemCounts = { [4306] = 120, [6948] = 1, [12811] = 4 },
        },
        ["Puucons-Whitemane"] = {
            nameRealm = "Puucons-Whitemane", name = "Puucons", class = "PRIEST",
            race = "Dwarf", sex = 2, faction = "Alliance", source = "full",
            ts = 900, itemCounts = { [4306] = 40, [6948] = 1 },
        },
        ["Shalk-Whitemane"] = {
            nameRealm = "Shalk-Whitemane", name = "Shalk", class = "SHAMAN",
            race = "Orc", sex = 3, faction = "Horde", source = "full",
            ts = 800, itemCounts = { [6948] = 1 },
        },
        ["Zug-Faerlina"] = {          -- another account
            nameRealm = "Zug-Faerlina", name = "Zug", class = "ROGUE",
            race = "Troll", sex = 2, faction = "Horde", source = "summary",
            ts = 500, itemCounts = { [4306] = 77, [6948] = 1, [99001] = 3 },
        },
        ["Bank-Faerlina"] = {
            nameRealm = "Bank-Faerlina", name = "Bank", class = "MAGE",
            race = "Gnome", sex = 2, faction = "Alliance", source = "summary",
            ts = 0,                    -- deliberately UNSTAMPED
            itemCounts = { [6948] = 1 },
        },
    }
end

-- A resolver that answers for some ids and stays cold for others, so every cold
-- leg is exercised without touching the client.
local function fixtureResolver(known)
    return {
        item = function(id)
            local rec = known[id]
            if not rec then return nil end
            return { id = id, name = rec[1], quality = rec[2],
                     icon = rec[3], category = rec[4] }
        end,
        cached = function() return false end,
    }
end

local function warmResolver()
    return fixtureResolver({
        [4306]  = { "Silk Cloth",       1, "tex/silk",  "Trade Goods" },
        [6948]  = { "Hearthstone",      1, "tex/hs",    "Miscellaneous" },
        [12811] = { "Righteous Orb",    3, "tex/orb",   "Trade Goods" },
        [99001] = { "Arcanite Reaper",  4, "tex/reap",  "Weapon" },
    })
end

-- One item (6948) resolved, everything else cold.
local function coldResolver()
    return fixtureResolver({
        [6948] = { "Hearthstone", 1, "tex/hs", "Miscellaneous" },
    })
end

local function builtLedger(res)
    local owners = fixtureOwners()
    local rows, stats = InvUI.BuildLedger(owners)
    local pending = InvUI.Decorate(rows, res or warmResolver())
    return rows, stats, pending, owners
end

----------------------------------------------------------------------

local function testLedger(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local rows, stats, _, owners = builtLedger()
    ck(#rows == 4, "the transpose produced " .. #rows .. " distinct items, expected 4")
    ck(stats.distinct == 4, "stats.distinct disagrees with the row count")
    ck(stats.chars == 5, "stats.chars counted " .. tostring(stats.chars) .. ", expected 5")

    local byId = {}
    for i = 1, #rows do byId[rows[i].id] = rows[i] end

    -- totals sum every holder across BOTH accounts
    ck(byId[4306] and byId[4306].total == 237,
       "the cross-account total is wrong: " .. tostring(byId[4306] and byId[4306].total))
    ck(byId[4306] and byId[4306].holders == 3, "holder count wrong for a 3-holder item")
    ck(byId[6948] and byId[6948].total == 5, "an item every character holds did not sum to 5")
    ck(byId[6948] and byId[6948].holders == 5, "holder count wrong for a 5-holder item")
    ck(byId[12811] and byId[12811].total == 4, "a single-holder item did not survive")
    ck(byId[99001] and byId[99001].total == 3,
       "an item only ANOTHER ACCOUNT holds was dropped — the mesh is the whole point")

    -- grand total is the sum of every count in the graph
    local hand = 0
    for _, o in pairs(owners) do
        for _, n in pairs(o.itemCounts) do hand = hand + n end
    end
    ck(stats.total == hand,
       "stats.total (" .. tostring(stats.total) .. ") /= the graph's own sum (" .. hand .. ")")

    -- the split is retained, complete, and sums to the row total
    local split = byId[4306] and byId[4306].split or {}
    ck(#split == 3, "the per-character split was not retained (" .. #split .. " entries)")
    local sum, keys = 0, {}
    for i = 1, #split do sum = sum + split[i].count; keys[#keys + 1] = split[i].key end
    ck(sum == 237, "the split does not sum to the row total")
    ck(table.concat(keys, ",") == "Poonyx-Whitemane,Puucons-Whitemane,Zug-Faerlina",
       "the split is not in sorted-owner order: " .. table.concat(keys, ","))

    -- junk in the graph never reaches a row
    local junk = InvUI.BuildLedger({
        ["A-R"] = { itemCounts = { [0] = 5, [-3] = 2, [10] = 0, [11] = -1,
                                   ["x"] = 9, [12] = 7 } },
        ["B-R"] = { itemCounts = "not a table" },
        ["C-R"] = "not a table",
        [7]     = { itemCounts = { [12] = 1 } },      -- a non-string owner key
    })
    ck(#junk == 1 and junk[1].id == 12 and junk[1].total == 7,
       "the ledger admitted junk: " .. #junk .. " row(s)")
    ck(#InvUI.BuildLedger(nil) == 0, "a nil graph did not answer an empty ledger")

    -- DETERMINISM (class 8): two builds of one fixture are identical row for row.
    local a = InvUI.BuildLedger(fixtureOwners())
    local b = InvUI.BuildLedger(fixtureOwners())
    local same = (#a == #b)
    if same then
        for i = 1, #a do
            if a[i].id ~= b[i].id or a[i].total ~= b[i].total then same = false break end
            if #a[i].split ~= #b[i].split then same = false break end
            for j = 1, #a[i].split do
                if a[i].split[j].key ~= b[i].split[j].key then same = false break end
            end
        end
    end
    ck(same, "two builds of the same graph disagreed — pairs() leaked into the order")
    for i = 2, #a do
        ck(a[i - 1].id < a[i].id, "the base order is not item id ascending")
    end
end

----------------------------------------------------------------------

-- THE ANTI-DRIFT PIN: the ledger's own split must agree, holder for holder, with
-- the machinery the HOVER actually renders (ns.Tooltips.BuildCountLines). If these
-- two ever disagree the table and its own tooltip are telling different stories
-- about who holds what — which is the entire failure this pin exists to prevent.
local function testSplitAgreesWithTooltipModel(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = ns.Tooltips
    if not (T and T.BuildCountLines and T.BuildTooltipRows) then
        fails[#fails + 1] = "ns.Tooltips is absent — the hover seam this tab reuses is gone"
        return
    end

    local rows, _, _, owners = builtLedger()
    for i = 1, #rows do
        local row = rows[i]
        local lines = T.BuildCountLines(owners, row.id, "Poonyx-Whitemane")
        local byKey, total = {}, 0
        for j = 1, #lines do
            byKey[lines[j].key] = lines[j].total
            total = total + lines[j].total
        end
        ck(total == row.total,
           "item " .. row.id .. ": the tooltip model totals " .. total
           .. " but the ledger row says " .. row.total)
        ck(#lines == row.holders,
           "item " .. row.id .. ": holder counts disagree (" .. #lines
           .. " vs " .. row.holders .. ")")
        for j = 1, #row.split do
            local s = row.split[j]
            ck(byKey[s.key] == s.count,
               "item " .. row.id .. ": " .. s.key .. " holds " .. s.count
               .. " in the ledger but " .. tostring(byKey[s.key]) .. " in the tooltip model")
        end
    end

    -- and the rendered block partitions the two accounts the way it always has
    local blockRows, blockTotal = InvUI.BreakdownRows(owners, 6948, "Poonyx-Whitemane")
    ck(blockRows ~= nil, "the breakdown block did not build for a 5-holder item")
    if blockRows then
        local kinds, chars = {}, 0
        for i = 1, #blockRows do
            kinds[blockRows[i].kind] = (kinds[blockRows[i].kind] or 0) + 1
            if blockRows[i].kind == "char" then chars = chars + 1 end
        end
        ck(chars == 5, "the breakdown lost a holder (" .. chars .. " of 5)")
        ck((kinds.section or 0) == 1, "the Other Accounts section did not appear")
        ck(blockTotal == 5, "the breakdown total is wrong: " .. tostring(blockTotal))
    end
    ck(InvUI.BreakdownRows(owners, 4242424, "Poonyx-Whitemane") == nil,
       "an item nobody holds produced a breakdown block")
end

----------------------------------------------------------------------

local function testSortMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rows = builtLedger()

    local byName = InvUI.SortRows(rows, "name")
    local names = {}
    for i = 1, #byName do names[i] = InvUI.DisplayName(byName[i]) end
    ck(table.concat(names, "|") == "Arcanite Reaper|Hearthstone|Righteous Orb|Silk Cloth",
       "name-ascending is wrong: " .. table.concat(names, "|"))

    local byQty = InvUI.SortRows(rows, "qty")
    ck(byQty[1].id == 4306 and byQty[1].total == 237,
       "quantity-desc did not put the biggest stack first")
    for i = 2, #byQty do
        ck(byQty[i - 1].total >= byQty[i].total, "quantity-desc is not monotone")
    end
    -- the qty tiebreak falls through to the NAME rule, then the id
    local tie = {
        { id = 30, total = 5, resolved = true, name = "Beta" },
        { id = 10, total = 5, resolved = true, name = "Alpha" },
        { id = 20, total = 5, resolved = true, name = "Alpha" },
    }
    local tied = InvUI.SortRows(tie, "qty")
    ck(tied[1].id == 10 and tied[2].id == 20 and tied[3].id == 30,
       "the quantity tiebreak is not (name, id)")

    -- SORT IS NON-DESTRUCTIVE and TOTAL: repeated application is a fixed point.
    local base = {}
    for i = 1, #rows do base[i] = rows[i].id end
    InvUI.SortRows(rows, "qty")
    local after = {}
    for i = 1, #rows do after[i] = rows[i].id end
    ck(table.concat(base, ",") == table.concat(after, ","),
       "SortRows mutated the array it was given")
    for _, mode in ipairs(InvUI.SORTS) do
        local once  = InvUI.SortRows(rows, mode)
        local twice = InvUI.SortRows(once, mode)
        local ids1, ids2 = {}, {}
        for i = 1, #once do ids1[i] = once[i].id; ids2[i] = twice[i].id end
        ck(table.concat(ids1, ",") == table.concat(ids2, ","),
           "sort mode '" .. mode .. "' is not idempotent — the order is not total")
    end

    -- the QTY header toggles; the ITEM header always lands on name
    ck(InvUI.NextSort("name", "qty") == "qty", "the QTY header did not switch to quantity")
    ck(InvUI.NextSort("qty", "qty") == "name", "the QTY header did not toggle back")
    ck(InvUI.NextSort("qty", "name") == "name", "the ITEM header did not select name")
    ck(InvUI.NextSort("name", "name") == "name", "the ITEM header changed a name sort")
end

----------------------------------------------------------------------

local function testFilterCompose(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rows = builtLedger()

    -- no filter at all: everything
    local all = InvUI.FilterRows(rows, "", InvUI.ALL)
    ck(#all == 4, "an unfiltered pass dropped rows")

    -- search alone, case- and substring-insensitive
    local s1 = InvUI.FilterRows(rows, "cloth", InvUI.ALL)
    ck(#s1 == 1 and s1[1].id == 4306, "the name search missed")
    ck(#InvUI.FilterRows(rows, "CLOTH", InvUI.ALL) == 1, "the name search is case sensitive")
    ck(#InvUI.FilterRows(rows, "ilk Clo", InvUI.ALL) == 1, "the name search is not a substring")
    ck(#InvUI.FilterRows(rows, "  cloth  ", InvUI.ALL) == 1, "the name search does not trim")
    ck(#InvUI.FilterRows(rows, "zzz", InvUI.ALL) == 0, "a miss still matched")
    -- a search term that is a Lua pattern must be treated as text
    ck(#InvUI.FilterRows(rows, "%d+", InvUI.ALL) == 0,
       "the search treated its input as a Lua pattern")

    -- category alone
    local c1 = InvUI.FilterRows(rows, "", "Trade Goods")
    ck(#c1 == 2, "the category filter kept " .. #c1 .. " rows, expected 2")
    ck(#InvUI.FilterRows(rows, "", "Weapon") == 1, "a one-item category is wrong")
    ck(#InvUI.FilterRows(rows, "", "Nonexistent") == 0, "an absent category matched something")

    -- THEY COMPOSE: both must admit the row
    local both = InvUI.FilterRows(rows, "orb", "Trade Goods")
    ck(#both == 1 and both[1].id == 12811, "search+category did not compose")
    ck(#InvUI.FilterRows(rows, "orb", "Weapon") == 0,
       "search+category composed as OR — a row matching only one filter survived")
    ck(#InvUI.FilterRows(rows, "cloth", "Miscellaneous") == 0,
       "search+category composed as OR (second direction)")

    -- the choices ring is derived from the data, sorted, All first
    local choices = InvUI.CategoryChoices(rows)
    ck(choices[1] == InvUI.ALL, "the category ring does not open on All")
    ck(table.concat(choices, "|") == "|Miscellaneous|Trade Goods|Weapon",
       "the category ring is wrong: " .. table.concat(choices, "|"))
    ck(InvUI.ValidCategory("Weapon", choices) == "Weapon", "a live category was healed away")
    ck(InvUI.ValidCategory("Gone", choices) == InvUI.ALL,
       "a category that no longer exists still filters out of SavedVariables")
    ck(InvUI.ValidCategory(nil, choices) == InvUI.ALL, "a nil category did not resolve to All")
end

----------------------------------------------------------------------

-- CLASS 4: the cold-item legs. Every one of these is about an item the client has
-- not named yet, and the rule is the same each time — it is rendered honestly,
-- counted, and healed; it is never dropped and never miscategorized.
local function testColdItemHonesty(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local rows, stats, pending = builtLedger(coldResolver())

    -- 1. UNRESOLVED ROWS EXIST AND ARE COUNTED
    ck(#rows == 4, "a cold client changed the row count")
    ck(stats.distinct == 4, "cold items were dropped from the distinct count")
    -- 237 (Silk) + 5 (Hearthstones) + 4 (Orb) + 3 (Reaper) = 249, of which only
    -- the 5 Hearthstones are named: the counts do not depend on the client at all.
    ck(stats.total == 249, "cold items were dropped from the total count")
    ck(table.concat(pending, ",") == "4306,12811,99001",
       "the pending list is wrong or unsorted: " .. table.concat(pending, ","))

    local cold, warm
    for i = 1, #rows do
        if rows[i].id == 4306 then cold = rows[i] end
        if rows[i].id == 6948 then warm = rows[i] end
    end
    ck(cold and cold.resolved == false, "a cold row claims to be resolved")
    ck(warm and warm.resolved == true, "a resolved row claims to be cold")

    -- 2. RENDERED HONESTLY
    ck(InvUI.DisplayName(cold) == "item #4306",
       "a cold row does not name itself honestly: " .. InvUI.DisplayName(cold))
    ck(InvUI.DisplayCategory(cold) == InvUI.GLYPHS.dots,
       "a cold row's category is not the ellipsis")
    ck(cold.name == nil and cold.category == nil and cold.quality == nil,
       "a cold row carries facts it was never told")
    ck(InvUI.QualityRGB(nil) == nil, "an unknown quality produced a colour")
    ck(InvUI.DisplayName(warm) == "Hearthstone", "a resolved row lost its name")

    -- 3. THE COUNTS ARE STILL RIGHT — a nameless item is still inventory
    ck(cold.total == 237, "a cold row lost its quantity")
    ck(#cold.split == 3, "a cold row lost its per-character split")

    -- 4. FILTERS TREAT IT HONESTLY (the documented policy)
    local noFilter, st1 = InvUI.FilterRows(rows, "", InvUI.ALL)
    ck(#noFilter == 4, "an unfiltered pass DROPPED cold rows")
    ck(st1.unresolvedShown == 3, "the unfiltered pass did not report the cold rows it showed")

    local searched, st2 = InvUI.FilterRows(rows, "hearth", InvUI.ALL)
    ck(#searched == 1 and searched[1].id == 6948, "the search did not match the warm row")
    ck(st2.pendingHidden == 3,
       "a name search hid cold rows WITHOUT counting them — that is the Bags Find defect")

    local catted, st3 = InvUI.FilterRows(rows, "", "Miscellaneous")
    ck(#catted == 1 and catted[1].id == 6948,
       "a concrete category admitted a row whose class we were never told")
    ck(st3.pendingHidden == 3, "the category pass did not count the cold rows it withheld")

    local bucket = InvUI.FilterRows(rows, "", InvUI.UNRESOLVED)
    ck(#bucket == 3, "the explicit (unresolved) bucket did not hold the cold rows")
    for i = 1, #bucket do
        ck(bucket[i].resolved == false, "a RESOLVED row leaked into the (unresolved) bucket")
    end
    local choices = InvUI.CategoryChoices(rows)
    ck(choices[#choices] == InvUI.UNRESOLVED,
       "the chip does not offer the (unresolved) bucket while rows are cold")

    -- 5. THE STATUS SENTENCE — "not told yet" is not "no match"
    local loadingText = InvUI.StatusText({ matched = 0, pendingHidden = 3, hasQuery = true })
    ck(loadingText and loadingText:find("Still loading", 1, true),
       "zero matches with cold names read as 'no match' instead of 'not told yet'")
    local neverText = InvUI.StatusText({ matched = 0, pendingHidden = 3, hasQuery = true,
                                         exhausted = true })
    ck(neverText and neverText:find("never loaded", 1, true),
       "an exhausted ladder still claims to be loading")
    local _, note = InvUI.StatusText({ matched = 1, pendingHidden = 2, hasQuery = true })
    ck(note and note:find("still loading 2 names", 1, true),
       "rows on screen with cold names said nothing about them")
    ck(select(1, InvUI.StatusText({ matched = 0, pendingHidden = 0, hasQuery = true }))
       == "No match.", "a genuine miss did not read as a miss")

    -- 6. IT HEALS IN PLACE when the client answers
    local healed = InvUI.Decorate(rows, warmResolver())
    ck(#healed == 0, "the ladder still reports pending ids after every name landed")
    ck(cold.resolved == true and cold.name == "Silk Cloth", "a cold row did not heal in place")
    ck(cold.category == "Trade Goods", "a healed row did not gain its category")
    ck(#InvUI.FilterRows(rows, "cloth", InvUI.ALL) == 1, "the healed row is not searchable")
    ck(#InvUI.FilterRows(rows, "", "Trade Goods") == 2, "the healed row is not in its category")
    ck(InvUI.CategoryChoices(rows)[#InvUI.CategoryChoices(rows)] ~= InvUI.UNRESOLVED,
       "the (unresolved) bucket is still offered after everything resolved")

    -- 7. A ROW THAT GOES COLD AGAIN LOSES ITS FACTS rather than showing a stale name
    InvUI.Decorate(rows, coldResolver())
    ck(cold.resolved == false and cold.name == nil,
       "a re-decorated cold row kept the name it can no longer prove")

    -- 8. RED CONTROL. A filter pass that silently drops unresolved rows is the
    --    defect this whole section exists to prevent, so it is written out and
    --    asserted to DISAGREE with the shipped one. If someone ever "simplifies"
    --    FilterRows into this shape, this check turns red.
    local function droppingFilter(src)
        local out = {}
        for i = 1, #src do
            if src[i].resolved then out[#out + 1] = src[i] end
        end
        return out
    end
    local dropped = droppingFilter(rows)
    local kept    = InvUI.FilterRows(rows, "", InvUI.ALL)
    ck(#dropped == 1, "the red-control fixture is not exercising what it claims")
    ck(#kept > #dropped,
       "RED CONTROL: the shipped filter drops unresolved rows exactly like the "
       .. "defect fixture — cold items are vanishing from the table")
    ck(#kept == 4, "the shipped filter did not keep every row with no filter active")
end

----------------------------------------------------------------------

-- The pooled/recycled row must not carry one item's tooltip onto the next item.
local function testRecycleHygiene(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- the pure rule
    ck(InvUI.TooltipStaleOnPaint(4306, 6948, true) == true,
       "a recycled row adopting a DIFFERENT item did not retire its tooltip")
    ck(InvUI.TooltipStaleOnPaint(4306, 4306, true) == false,
       "a row repainting the SAME item needlessly dropped its own tooltip")
    ck(InvUI.TooltipStaleOnPaint(4306, 6948, false) == false,
       "a row retired a tooltip that belongs to somebody else")
    ck(InvUI.TooltipStaleOnPaint(nil, 6948, true) == true,
       "a freshly-adopted row did not clear whatever was standing")

    -- the live path, with a recording tooltip and two plain-table rows
    local hidden = 0
    local owner = nil
    local tip = {
        GetOwner = function(self) return owner end,
        Hide     = function() hidden = hidden + 1 end,
    }
    local rowA = { _item = 4306 }

    owner = rowA
    ck(InvUI.RowTooltipOnPaint(tip, rowA, 6948) == true, "the recycle path did not fire")
    ck(hidden == 1, "the recycled row's tooltip was not hidden")

    hidden = 0
    ck(InvUI.RowTooltipOnPaint(tip, rowA, 4306) == false,
       "a same-item repaint hid the tooltip")
    ck(hidden == 0, "a same-item repaint hid the tooltip (count)")

    owner = { _item = 999 }        -- the tooltip belongs to a DIFFERENT row now
    hidden = 0
    ck(InvUI.RowTooltipOnPaint(tip, rowA, 6948) == false,
       "a row stole a tooltip that was not its own")
    ck(hidden == 0, "a row hid another row's tooltip")

    -- ...and the RENDER path itself, driven headless through a recording tooltip.
    local rows, _, _, owners = builtLedger()
    local rec = { lines = {}, doubles = {}, shown = 0 }
    function rec:AddLine(t) self.lines[#self.lines + 1] = tostring(t) end
    function rec:AddDoubleLine(l, r)
        self.doubles[#self.doubles + 1] = tostring(l) .. "=" .. tostring(r)
    end
    function rec:Show() self.shown = self.shown + 1 end

    local mode = InvUI.RenderRowTooltip(rec, rows[1], { owners = owners,
        viewerKey = "Poonyx-Whitemane" })
    ck(mode == "breakdown", "the default hover did not render the breakdown: " .. tostring(mode))
    ck(#rec.doubles == 3, "the breakdown drew " .. #rec.doubles .. " holder rows, expected 3")
    ck(rec.shown > 0, "the tooltip was never shown")

    -- SHIFT with a COLD cache: a title-only tooltip is not an answer, so the chain
    -- asks for the warm load and falls through instead of leaving a stub standing.
    local asked = {}
    local cold = { lines = {} }
    function cold:SetHyperlink() self.lines = { "Silk Cloth" } return true end
    function cold:NumLines() return #self.lines end
    function cold:ClearLines() self.lines = {} end
    function cold:AddLine(t) self.lines[#self.lines + 1] = tostring(t) end
    function cold:AddDoubleLine(l, r) self.lines[#self.lines + 1] = tostring(l) end
    function cold:Show() end
    local coldMode = InvUI.RenderRowTooltip(cold, rows[1], {
        owners = owners, viewerKey = "Poonyx-Whitemane", shift = true,
        ask = function(ids) for i = 1, #ids do asked[#asked + 1] = ids[i] end end,
    })
    ck(coldMode == "breakdown",
       "a COLD item tooltip was accepted as the real one (class 4): " .. tostring(coldMode))
    ck(#asked == 1 and asked[1] == rows[1].id,
       "a cold item tooltip did not request the warm load")

    -- SHIFT with a WARM cache: the real item tooltip wins and nothing is appended.
    local warm = { lines = {} }
    function warm:SetHyperlink() self.lines = { "Silk Cloth", "Trade Goods", "Sell: 1s" } return true end
    function warm:NumLines() return #self.lines end
    function warm:ClearLines() self.lines = {} end
    function warm:AddLine(t) self.lines[#self.lines + 1] = tostring(t) end
    function warm:Show() end
    ck(InvUI.RenderRowTooltip(warm, rows[1], { owners = owners, shift = true }) == "item",
       "a warm item tooltip was not used for the shift hover")
    ck(#warm.lines == 3, "the shift hover appended to the client's own item tooltip")
end

----------------------------------------------------------------------

local function testGeometry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- MULTI-WIDTH FIT: the band never overruns the pane, at any width.
    local widths = { 200, 320, 480, 700, 900, 1096, 2000 }
    for _, w in ipairs(widths) do
        local c = InvUI.RowColumns(w)
        local at = "@" .. w .. "px"
        ck(c.width <= w, "the row band overruns the pane " .. at
           .. " (" .. c.width .. " > " .. w .. ")")
        -- strictly increasing origins, no column starting inside its neighbour
        ck(c.icon.x <= c.name.x, "icon/name columns are out of order " .. at)
        ck(c.icon.x + c.icon.w <= c.name.x, "the icon overlaps the name " .. at)
        ck(c.name.x + c.name.w <= c.qty.x, "the name overlaps the quantity " .. at)
        ck(c.qty.x + c.qty.w <= c.cat.x, "the quantity overlaps the category " .. at)
        ck(c.cat.x + c.cat.w == c.width, "the band width is not the category's right edge " .. at)
        ck(c.name.w >= 0 and c.qty.w >= 0 and c.cat.w >= 0, "a negative column width " .. at)

        -- the header band is derived FROM the columns, never placed independently
        local cells = InvUI.HeaderCells(w)
        ck(#cells == 3, "the header lost a cell " .. at)
        ck(cells[1].x == c.name.x and cells[1].w == c.name.w, "ITEM header /= name column " .. at)
        ck(cells[2].x == c.qty.x  and cells[2].w == c.qty.w,  "QTY header /= qty column " .. at)
        ck(cells[3].x == c.cat.x  and cells[3].w == c.cat.w,  "CATEGORY header /= cat column " .. at)
        ck(cells[2].justify == "RIGHT", "the QTY header does not right-justify " .. at)
        ck(cells[1].sort == "name" and cells[2].sort == "qty",
           "the sortable headers lost their modes " .. at)
        ck(cells[3].sort == nil, "the CATEGORY header claims a sort mode " .. at)
    end

    -- above the natural sum the table FILLS the pane rather than leaving a strip
    local natural = InvUI.RowWidth()
    local wide = InvUI.RowColumns(natural + 400)
    ck(wide.scale == 1, "a pane wider than natural still shrank the columns")
    ck(wide.width == natural + 400 - L.CAT_PAD,
       "surplus width was not absorbed: " .. wide.width .. " of " .. (natural + 400))
    ck(wide.name.w > InvUI.RowColumns(natural).name.w, "the name column did not take its share")
    ck(wide.cat.w > InvUI.RowColumns(natural).cat.w, "the category column did not take its share")

    -- below it, everything shrinks together and still fits
    local tight = InvUI.RowColumns(240)
    ck(tight.scale < 1, "a pane narrower than natural did not shrink")
    ck(tight.width <= 240, "the shrunk band still overruns")

    -- degenerate inputs answer something drawable rather than throwing
    for _, w in ipairs({ 0, -50 }) do
        local c = InvUI.RowColumns(w)
        ck(c.width <= math.max(0, w), "a degenerate width produced a band " .. c.width .. "px wide")
    end

    -- the insets are the ONE arithmetic the view and this pin share
    ck(InvUI.ListTopInset() == L.HEAD_H + 2, "the header's cost to the list drifted")
    ck(InvUI.ListBottomInset() == L.FOOTER_H + 4, "the footer's cost to the list drifted")
    ck(InvUI.ListTopInset() <= L.ROW_H, "the header band grew past one row of list")
end

----------------------------------------------------------------------

local function testVirtualization(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local rowH, viewH, n = 22, 300, 4000
    local ceiling = InvUI.PoolCeiling(viewH, rowH)
    ck(ceiling == math.ceil(300 / 22) + 1, "the pool ceiling is wrong: " .. ceiling)

    -- NO UNBOUNDED FRAME CREATION: at every scroll position in a 4000-row list the
    -- window is never wider than the viewport's own ceiling.
    local maxSlice, sawFull = 0, false
    for off = 0, n * rowH, 137 do
        local first, last = InvUI.VisibleWindow(off, viewH, rowH, n)
        local slice = last - first + 1
        if slice > maxSlice then maxSlice = slice end
        ck(first >= 1, "the window started before row 1 at offset " .. off)
        ck(last <= n, "the window ran past the last row at offset " .. off)
        ck(slice <= ceiling, "the window (" .. slice .. ") exceeded the pool ceiling ("
           .. ceiling .. ") at offset " .. off)
        -- the slice must COVER the viewport: the last row's bottom is at or below
        -- the viewport's bottom, unless we have run out of list.
        if last < n then
            ck(last * rowH >= off + viewH,
               "the window left a gap at the bottom of the viewport, offset " .. off)
        end
        if slice == ceiling then sawFull = true end
    end
    ck(maxSlice <= ceiling, "some scroll position wanted more frames than the ceiling")
    ck(sawFull, "the window never filled the viewport — the ceiling is not tight")

    -- the first row is the one the offset actually lands on, and yTop is virtual
    local f1, _, y1 = InvUI.VisibleWindow(0, viewH, rowH, n)
    ck(f1 == 1 and y1 == 0, "a zero scroll did not start at row 1")
    local f2, _, y2 = InvUI.VisibleWindow(rowH * 10, viewH, rowH, n)
    ck(f2 == 11, "an exact ten-row scroll did not start at row 11")
    ck(y2 == 10 * rowH, "yTop is not the first row's VIRTUAL position")

    -- an over-scroll is clamped to the end rather than running off it
    local f3, l3 = InvUI.VisibleWindow(999999, viewH, rowH, n)
    ck(l3 == n, "an over-scroll did not clamp to the last row")
    ck(f3 <= n, "an over-scroll started past the end")

    -- degenerate: empty list, zero viewport, a shorter-than-viewport list
    local _, le = InvUI.VisibleWindow(0, viewH, rowH, 0)
    ck(le == 0, "an empty list still asked for rows")
    local _, lz = InvUI.VisibleWindow(0, 0, rowH, 100)
    ck(lz == 0, "a zero-height viewport still asked for rows")
    local fs, ls = InvUI.VisibleWindow(0, viewH, rowH, 3)
    ck(fs == 1 and ls == 3, "a short list was not drawn whole")
end

----------------------------------------------------------------------

local function testFooterAndCoverage(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local owners = fixtureOwners()

    local cov = InvUI.Coverage(owners, 1000 + 7200)
    ck(cov.chars == 5, "coverage counted " .. cov.chars .. " characters, expected 5")
    ck(cov.stamped == 4, "coverage counted the UNSTAMPED record as stamped")
    ck(cov.oldest == (1000 + 7200) - 500, "the oldest stamp is wrong: " .. tostring(cov.oldest))
    ck(cov.oldestKey == "Zug-Faerlina", "the oldest record was misidentified")

    -- a clock ahead of the stamp is not negative staleness
    local ahead = InvUI.Coverage({ ["A-R"] = { ts = 5000 } }, 1000)
    ck(ahead.oldest == 0, "a future stamp produced negative staleness")

    -- nothing stamped at all: chars still count, the age clause simply is not made up
    local none = InvUI.Coverage({ ["A-R"] = { ts = 0 }, ["B-R"] = {} }, 9999)
    ck(none.chars == 2 and none.stamped == 0 and none.oldest == nil,
       "an unstamped roster invented an age")
    ck(InvUI.Coverage(nil, 0).chars == 0, "a nil graph produced coverage")

    -- the footer says all three things, and drops the age when it cannot prove one
    local fmt = function(sec) return math.floor(sec / 3600) .. "h" end
    local text = InvUI.FooterText({ distinct = 1204, total = 38551 }, cov, fmt)
    ck(text:find("1,204 items", 1, true), "the footer lost the distinct count: " .. text)
    ck(text:find("38,551 total", 1, true), "the footer lost the total count: " .. text)
    ck(text:find("5 characters", 1, true), "the footer lost the roster coverage: " .. text)
    ck(text:find("oldest data 2h ago", 1, true), "the footer lost the staleness: " .. text)

    local noAge = InvUI.FooterText({ distinct = 1, total = 1 }, none, fmt)
    ck(noAge:find("2 characters", 1, true), "the footer lost coverage with no stamps")
    ck(not noAge:find("oldest", 1, true), "the footer invented an age it could not prove")
    ck(noAge:find("1 item ", 1, true) or noAge:find("1 item" .. InvUI.GLYPHS.middot, 1, true)
       or noAge:match("^1 item"), "the footer did not singularise one item")

    -- no formatter at hand: the age clause is dropped, never printed raw
    local noFmt = InvUI.FooterText({ distinct = 2, total = 3 }, cov, nil)
    ck(not noFmt:find("oldest", 1, true), "the footer printed an age with no formatter")
    ck(noFmt:find("5 characters", 1, true), "the footer dropped coverage with no formatter")

    ck(InvUI.Commas(0) == "0" and InvUI.Commas(999) == "999"
       and InvUI.Commas(1000) == "1,000" and InvUI.Commas(1234567) == "1,234,567",
       "the thousands separator is wrong")
end

----------------------------------------------------------------------

local function testTabRegistrationAndInertness(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- REGISTERED, as a builder the shell can call.
    ck(type(Dashboard.tabBuilders) == "table", "the shell has no tab registry")
    ck(type(Dashboard.tabBuilders["inventory"]) == "function",
       "the inventory tab registered no pane builder")

    -- PRESENT IN THE STRIP, in canonical order, and UNGATED (owner's directive:
    -- this tab is always there — it explains its own emptiness in words).
    local def, at = nil, nil
    for i = 1, #Dashboard.TAB_DEFS do
        if Dashboard.TAB_DEFS[i].id == "inventory" then def, at = Dashboard.TAB_DEFS[i], i end
    end
    ck(def ~= nil, "the inventory tab is not in Dashboard.TAB_DEFS")
    if def then
        ck(def.label == "Inventory", "the tab label is wrong: " .. tostring(def.label))
        ck(def.gate == nil, "the inventory tab acquired a module gate — it must always be there")
        ck(def.badge == nil, "the inventory tab acquired a badge it does not define")
    end
    ck(Dashboard.TAB_DEFS[1].id == "characters", "Characters is no longer the first tab")
    ck(at ~= nil and at > 1, "the inventory tab displaced an existing tab")

    -- THE SHELL IS UNAFFECTED: exactly one gated tab (professions), the gating rule
    -- still holds, and a visible tab still resolves to itself.
    local gated = 0
    for i = 1, #Dashboard.TAB_DEFS do
        if Dashboard.TAB_DEFS[i].gate then gated = gated + 1 end
    end
    ck(gated == 1, "adding the inventory tab changed the gated-tab count to " .. gated)

    local vis = Dashboard.VisibleTabs()
    local seen = {}
    for i = 1, #vis do seen[vis[i]] = true end
    ck(seen["characters"], "Characters left the strip")
    ck(seen["inventory"], "the ungated inventory tab is not visible")
    ck(Dashboard.ResolveTab("inventory", vis) == "inventory",
       "the inventory tab does not resolve to itself")
    ck(Dashboard.ResolveTab("nonsense", vis) == vis[1],
       "an unknown tab id no longer falls back to the first visible one")

    -- INERT UNTIL SELECTED: loading this file builds no frames and registers no
    -- event. The watcher is created lazily by the first render that meets a cold
    -- id, which the harness never reaches.
    ck(thePane == nil, "the inventory pane was built at load time")
    ck(InvUI.Exhausted({}) == false, "an empty pending list claimed to be exhausted")

    -- The honest empty page exists for every reason the table can be empty.
    local off = InvUI.EmptyText({ moduleOff = true })
    ck(off:find("switched off", 1, true), "the module-off page does not say so")
    local none = InvUI.EmptyText({ ledgerEmpty = true })
    ck(none:find("No item counts yet", 1, true), "the empty-ledger page does not say so")
    ck(select(1, InvUI.StatusText({ matched = 0, moduleOff = true })) == off,
       "the status line does not defer to the module-off page")
    ck(select(1, InvUI.StatusText({ matched = 0, ledgerEmpty = true })) == none,
       "the status line does not defer to the empty-ledger page")
end

----------------------------------------------------------------------
-- THE FIRST-OPEN BUDGET  (owner, live 2026-08-11: "a huge lag spike")
--
-- Every pin here is CALL-COUNTED off InvUI.WORK — no wall-clock, so the suite
-- says the same thing on any machine. The RED CONTROL throughout is yesterday's
-- shape: the whole mesh folded, decorated, sorted and asked for in ONE frame.
----------------------------------------------------------------------

-- A mesh big enough that "all in one frame" and "a slice at a time" are
-- different sentences: 24 characters, ~600 distinct items, ~7,200 (char,item)
-- entries. Deterministic — no math.random anywhere near a pin.
local function bigOwners(nChars, universe, perChar)
    nChars, universe, perChar = nChars or 24, universe or 601, perChar or 300
    local owners = {}
    for c = 1, nChars do
        local counts, n, at = {}, 0, (c * 37) % universe
        for i = 1, 60 do counts[1000 + i] = 10 + i; n = n + 1 end   -- the common core
        while n < perChar do
            at = (at + c) % universe          -- universe is PRIME: every stride walks it all
            local id = 2000 + at
            if not counts[id] then counts[id] = 1 + (at % 40); n = n + 1 end
        end
        owners[string.format("Big%03d-Realm", c)] =
            { nameRealm = "Big" .. c, ts = 1000 + c, itemCounts = counts }
    end
    return owners
end

local function testFirstOpenBudget(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local owners = bigOwners()
    local entries = 0
    for _, o in pairs(owners) do
        for _ in pairs(o.itemCounts) do entries = entries + 1 end
    end
    ck(entries > 5000, "the budget fixture is too small to distinguish the shapes ("
       .. entries .. " entries)")

    ------------------------------------------------------------------
    -- 1. CORRECTNESS FIRST. The sliced job and the one-shot oracle must agree
    --    completely — row for row, split for split, stat for stat — at several
    --    chunk sizes INCLUDING ones that land mid-character. A faster wrong
    --    answer is not a fix.
    ------------------------------------------------------------------
    local oneRows, oneStats = InvUI.BuildLedger(owners)
    for _, chunk in ipairs({ 1, 7, 250, 2000, 1e9 }) do
        local rows, stats = InvUI.RunLedger(owners, chunk)
        local at = " (chunk " .. chunk .. ")"
        ck(#rows == #oneRows, "the sliced ledger has " .. #rows .. " rows, the one-shot "
           .. #oneRows .. at)
        ck(stats.distinct == oneStats.distinct, "distinct disagrees" .. at)
        ck(stats.total == oneStats.total, "the grand total disagrees: " .. stats.total
           .. " vs " .. oneStats.total .. at)
        ck(stats.chars == oneStats.chars, "the character count disagrees" .. at)
        local bad = nil
        for i = 1, math.min(#rows, #oneRows) do
            local a, b = rows[i], oneRows[i]
            if a.id ~= b.id or a.total ~= b.total or a.holders ~= b.holders
               or #a.split ~= #b.split then bad = bad or i end
            if not bad then
                for j = 1, #a.split do
                    if a.split[j].key ~= b.split[j].key
                       or a.split[j].count ~= b.split[j].count then bad = bad or i end
                end
            end
        end
        ck(bad == nil, "the sliced ledger disagrees with the one-shot at row "
           .. tostring(bad) .. at)
    end

    -- ...and it is still a TOTAL order (class 8), still item id ascending.
    local rows = InvUI.RunLedger(owners, 97)
    for i = 2, #rows do
        ck(rows[i - 1].id < rows[i].id, "the sliced base order is not id ascending")
    end
    -- two sliced builds of one graph are identical (chunking may not leak in)
    local r2 = InvUI.RunLedger(owners, 13)
    local same = (#rows == #r2)
    for i = 1, math.min(#rows, #r2) do
        if rows[i].id ~= r2[i].id or rows[i].total ~= r2[i].total then same = false end
    end
    ck(same, "two sliced builds at different chunk sizes disagreed")

    ------------------------------------------------------------------
    -- 2. THE BUDGET. No single slice may fold more than the chunk (plus the one
    --    owner's id list it had to open to get there). The RED CONTROL is the
    --    one-shot: it folds EVERYTHING in one step, and the pin is that the
    --    sliced path does not.
    ------------------------------------------------------------------
    local job = InvUI.NewLedgerJob(owners, InvUI.BUILD_CHUNK)
    local worst, steps, biggestOwner = 0, 0, 0
    for _, o in pairs(owners) do
        local n = 0
        for _ in pairs(o.itemCounts) do n = n + 1 end
        if n > biggestOwner then biggestOwner = n end
    end
    -- A slice may overshoot its chunk by at most the ONE owner id list it had to
    -- open to get there — which is why opening an owner is charged at #ids
    -- rather than being free.
    local ceiling, finalWork = InvUI.BUILD_CHUNK + biggestOwner, nil
    while true do
        local done, work = InvUI.StepLedger(job)
        steps = steps + 1
        if done then finalWork = work break end
        if work > worst then worst = work end
        ck(steps < 10000, "the sliced build did not terminate")
        if steps >= 10000 then break end
    end
    ck(worst <= ceiling, "a single slice folded " .. worst .. " entries, over the "
       .. ceiling .. " ceiling — the frame budget is not bounded")
    ck(steps > 3, "the build finished in " .. steps
       .. " steps — it is not actually being sliced")
    -- The CLOSING slice is the canonical id sort and gets a frame of its own, so
    -- no single frame pays for the fold AND the sort. Its unit is distinct rows,
    -- which is far below the entry count.
    ck(finalWork == #oneRows, "the closing sort slice did " .. tostring(finalWork)
       .. " units of work, expected the " .. #oneRows .. " rows it sorts")
    ck(finalWork * 4 < entries,
       "the closing sort is not meaningfully smaller than the fold it follows")

    -- RED CONTROL: yesterday's shape, stated and asserted to be the thing we no
    -- longer do. If someone "simplifies" the job back into one step, this turns.
    local redJob = InvUI.NewLedgerJob(owners, 1e9)
    InvUI.StepLedger(redJob)                       -- phase "keys"
    local _, redWork = InvUI.StepLedger(redJob)    -- phase "scan": ALL of it
    ck(redWork >= entries,
       "the red-control fixture is not exercising one-frame-does-everything")
    ck(worst < redWork,
       "RED CONTROL: the sliced build does as much in one step as the one-shot did "
       .. "— the lag spike is back")

    ------------------------------------------------------------------
    -- 3. THE ASK BURST IS BOUNDED, AND VIEWPORT-FIRST.
    ------------------------------------------------------------------
    InvUI.ClearCaches()
    InvUI._resetWatchState()
    local ids = {}
    for i = 1, #rows do ids[i] = rows[i].id end
    ck(InvUI.QueueAsks(ids) == #ids, "the queue did not accept every cold id")
    ck(InvUI.QueueAsks(ids) == 0, "the queue accepted the same ids twice")
    ck(InvUI.AskQueueDepth() == #ids, "the queue depth is wrong")

    -- the rows ON SCREEN jump the queue, keeping relative order inside both
    -- halves (a stable partition, so one viewport implies one queue order)
    local onScreen = { ids[#ids], ids[#ids - 1], ids[#ids - 2] }
    ck(InvUI.PromoteAsks(onScreen) == 3, "the viewport rows were not promoted")
    local drained = {}
    local askRes = { cached = function() return false end }
    InvUI.ResetWork()
    local asked, left = InvUI.DrainAsks(askRes, InvUI.ASK_BUDGET)
    ck(asked == InvUI.ASK_BUDGET, "the first drain issued " .. asked .. " asks, not "
       .. InvUI.ASK_BUDGET)
    ck(left == #ids - InvUI.ASK_BUDGET, "the drain did not consume exactly its budget")
    ck(InvUI.WORK.ask == InvUI.ASK_BUDGET,
       "the work meter disagrees with the drain (" .. InvUI.WORK.ask .. ")")
    -- RED CONTROL: the old shape asked for EVERY cold id at once.
    ck(asked < #ids,
       "RED CONTROL: the first frame still asks for every cold id at once ("
       .. asked .. " of " .. #ids .. ")")
    ck(asked * 8 < #ids, "the ask budget is not meaningfully smaller than the flood")

    -- the promoted ids were in that first budget — that is the whole point
    InvUI.ClearCaches()
    InvUI._resetWatchState()
    InvUI.QueueAsks(ids)
    InvUI.PromoteAsks({ ids[#ids] })
    local seen = {}
    local spyRes = { cached = function(id) seen[id] = true return true end }
    InvUI.DrainAsks(spyRes, InvUI.ASK_BUDGET)
    ck(seen[ids[#ids]] == true,
       "a row the owner is LOOKING AT was not in the first ask budget")

    -- draining empties the queue and then costs nothing
    local guard = 0
    while InvUI.AskQueueDepth() > 0 and guard < 1000 do
        InvUI.DrainAsks(spyRes, InvUI.ASK_BUDGET); guard = guard + 1
    end
    ck(InvUI.AskQueueDepth() == 0, "the queue never drained")
    ck(select(1, InvUI.DrainAsks(spyRes, InvUI.ASK_BUDGET)) == 0,
       "draining an empty queue still issued asks")
    ck(guard >= 2, "the whole queue went out in one drain")
    -- a zero budget is a refusal, not an unbounded pass
    InvUI.QueueAsks({ 1, 2, 3 })
    ck(select(1, InvUI.DrainAsks(spyRes, 0)) == 0, "a zero budget still asked")
    ck(InvUI.AskQueueDepth() == 3, "a zero-budget drain consumed the queue anyway")
    InvUI.ClearAskQueue()
    ck(InvUI.AskQueueDepth() == 0, "the queue did not clear")
    ck(InvUI.PromoteAsks({ 1 }) == 0, "promoting into an empty queue reported work")

    ------------------------------------------------------------------
    -- 4. THE COALESCER — the ~13 seconds, as a ratio.
    ------------------------------------------------------------------
    -- 100 client answers inside one debounce window. THE RED CONTROL is the old
    -- shape — one full repaint per answer, which is where the ~13 seconds lived.
    InvUI._resetRepaint()
    InvUI.ResetWork()
    for _ = 1, 100 do InvUI.RequestRepaint() end
    ck(InvUI.WORK.repaintsAsked == 100, "the repaint requests were not counted")
    ck(InvUI.WORK.repaintsRun == 0,
       "a repaint ran the moment it was asked for — the debounce is not arming")
    ck(InvUI.RunRepaint() == true, "the coalesced repaint never ran at all")
    ck(InvUI.WORK.repaintsRun == 1,
       "RED CONTROL: 100 client answers cost " .. InvUI.WORK.repaintsRun
       .. " repaints instead of 1 — the echo storm is back")
    ck(InvUI.RunRepaint() == false,
       "a clean pane repainted anyway — the dirty flag is not the gate")
    -- and the fact generation moves ONLY when a repaint actually runs, which is
    -- what the warm path uses to decide a re-decorate is worth doing
    local g0 = InvUI.FactGeneration()
    InvUI.RunRepaint()                       -- clean: nothing to do
    ck(InvUI.FactGeneration() == g0, "a no-op repaint moved the fact generation")
    InvUI.RequestRepaint(); InvUI.RunRepaint()
    ck(InvUI.FactGeneration() > g0, "a real repaint did not move the fact generation")

    ------------------------------------------------------------------
    -- 5. THE LEDGER CACHE'S SIGNAL. The generation moves on the SAME store
    --    signal Tooltips.Owners' own cache listens to, and on nothing else.
    ------------------------------------------------------------------
    local g = InvUI.Generation()
    if ns.Fire then
        ns:Fire("STORE_REFRESHED")
        ck(InvUI.Generation() > g,
           "STORE_REFRESHED did not invalidate the ledger cache — a stale mesh "
           .. "would be shown as current")
        local g2 = InvUI.Generation()
        ns:Fire("ACCOUNT_ID_CHANGED")
        ck(InvUI.Generation() > g2, "ACCOUNT_ID_CHANGED did not invalidate the ledger")
        local g3 = InvUI.Generation()
        ns:Fire("TIMER_UPDATED")
        ck(InvUI.Generation() == g3,
           "an unrelated event invalidated the ledger — the cache would never hold")
    else
        fails[#fails + 1] = "the event bus is absent; the cache-invalidation pin could not run"
    end

    ------------------------------------------------------------------
    -- 6. THE WARM REOPEN CEILING. A second look at an unchanged store must not
    --    re-fold the mesh. The pin is on the work METER, so it measures the
    --    passes, not the clock.
    ------------------------------------------------------------------
    InvUI.ResetWork()
    InvUI.RunLedger(owners, InvUI.BUILD_CHUNK)
    local coldLedger = InvUI.WORK.ledger
    ck(coldLedger >= entries, "the cold build did not fold the whole mesh")
    InvUI.ResetWork()
    -- A warm reopen is a filter+sort at most (and, with the view cache holding,
    -- not even that) — never a ledger pass.
    InvUI.FilterRows(rows, "", "")
    InvUI.SortRows(rows, "name")
    ck(InvUI.WORK.ledger == 0, "a warm reopen folded the ledger again")
    ck(InvUI.WORK.filter + InvUI.WORK.sort <= 2 * #rows,
       "a warm reopen cost more than one filter and one sort")
    ck(InvUI.WORK.filter + InvUI.WORK.sort < coldLedger,
       "the warm ceiling is not below the cold build's cost")
end

----------------------------------------------------------------------

-- The sort key Decorate precomputes, and the progress sentence the pane says
-- while the transpose is still running.
local function testSliceHonesty(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- THE SORT KEY. Set on resolve, CLEARED when a row goes cold, and never
    -- allowed to change the ORDER — the optimisation may not move a row.
    local rows = builtLedger()
    for i = 1, #rows do
        ck(rows[i].sortKey == rows[i].name:lower(),
           "a resolved row's sortKey is not its lowercased name")
    end
    local keyed = InvUI.SortRows(rows, "name")
    for i = 1, #rows do rows[i].sortKey = nil end        -- force the slow path
    local unkeyed = InvUI.SortRows(rows, "name")
    local a, b = {}, {}
    for i = 1, #keyed do a[i] = keyed[i].id; b[i] = unkeyed[i].id end
    ck(table.concat(a, ",") == table.concat(b, ","),
       "the precomputed sort key changed the order the comparator produces")
    -- a row that goes cold loses it, so a stale key can never outlive its name
    InvUI.Decorate(rows, coldResolver())
    for i = 1, #rows do
        if not rows[i].resolved then
            ck(rows[i].sortKey == nil,
               "a cold row kept a sort key derived from a name it can no longer prove")
        end
    end
    -- SortRows is still PURE: it may not write the key back onto the rows
    InvUI.Decorate(rows, warmResolver())
    for i = 1, #rows do rows[i].sortKey = nil end
    InvUI.SortRows(rows, "name")
    local wrote = false
    for i = 1, #rows do if rows[i].sortKey ~= nil then wrote = true end end
    ck(not wrote, "SortRows memoised onto its input — it is documented pure")

    -- THE PROGRESS LINE. It counts CHARACTERS and prints NO totals: a partial
    -- transpose understates every sum, and a number still moving is not a total.
    local p = InvUI.ProgressText(12, 40)
    ck(p == "indexing 12 of 40 characters" .. InvUI.GLYPHS.dots,
       "the progress line is wrong: " .. tostring(p))
    ck(InvUI.ProgressText(1, 1) == "indexing 1 of 1 character" .. InvUI.GLYPHS.dots,
       "the progress line did not singularise one character")
    ck(InvUI.ProgressText(2000, 4000):find("2,000 of 4,000", 1, true),
       "the progress line does not group its thousands")
    ck(InvUI.ProgressText(0, 0) == nil, "a job with no characters printed a progress line")
    ck(InvUI.ProgressText(99, 40):find("40 of 40", 1, true),
       "the progress line ran past its own total")
    for _, txt in ipairs({ InvUI.ProgressText(1, 4) }) do
        ck(txt:find("item", 1, true) == nil and txt:find("total", 1, true) == nil,
           "the progress line quotes counts it cannot yet stand behind: " .. txt)
    end

    -- LedgerProgress tracks it, and lands exactly on the total when done.
    local owners = bigOwners(6, 101, 60)
    local job = InvUI.NewLedgerJob(owners, 40)
    local d0, t0 = InvUI.LedgerProgress(job)
    ck(d0 == 0 and t0 == 0, "a job reported progress before it had a roster")
    InvUI.StepLedger(job)                                -- the "keys" phase
    local _, t1 = InvUI.LedgerProgress(job)
    ck(t1 == 6, "the job did not learn its character count: " .. t1)
    local guard = 0
    while not InvUI.StepLedger(job) and guard < 1000 do
        local d, t = InvUI.LedgerProgress(job)
        ck(d >= 0 and d <= t, "progress left its own bounds (" .. d .. " of " .. t .. ")")
        guard = guard + 1
    end
    local dEnd, tEnd = InvUI.LedgerProgress(job)
    ck(dEnd == tEnd and tEnd == 6, "a finished job did not report itself finished")
    ck(job.done == true, "the job did not mark itself done")
    ck(select(2, InvUI.StepLedger(job)) == 0, "stepping a finished job did more work")

    -- "INDEXING" OUTRANKS "EMPTY". A partial ledger with nothing in it yet is
    -- not an empty one, and must not read as "No item counts yet".
    local indexingText = InvUI.StatusText({ matched = 0, ledgerEmpty = true,
                                            indexing = "indexing 3 of 40 characters" })
    ck(indexingText == "indexing 3 of 40 characters",
       "an indexing pane claimed to be empty: " .. tostring(indexingText))
    ck(select(1, InvUI.StatusText({ matched = 0, indexing = true })):find("indexing", 1, true),
       "an indexing pane with no progress string said nothing about it")
    -- ...but the module being OFF still outranks indexing (there is nothing to index)
    ck(select(1, InvUI.StatusText({ matched = 0, indexing = "x", moduleOff = true }))
       == InvUI.EmptyText({ moduleOff = true }),
       "a switched-off module claimed to be indexing")
    -- and with the build finished, the honest empty page comes back
    ck(select(1, InvUI.StatusText({ matched = 0, ledgerEmpty = true }))
       == InvUI.EmptyText({ ledgerEmpty = true }),
       "the empty-ledger page was lost to the indexing branch")

    -- A JOB OVER A JUNK GRAPH admits exactly what BuildLedger admits.
    local junk = {
        ["A-R"] = { itemCounts = { [0] = 5, [-3] = 2, [10] = 0, [11] = -1,
                                   ["x"] = 9, [12] = 7 } },
        ["B-R"] = { itemCounts = "not a table" },
        ["C-R"] = "not a table",
        [7]     = { itemCounts = { [12] = 1 } },
    }
    local jr, js = InvUI.RunLedger(junk, 2)
    ck(#jr == 1 and jr[1].id == 12 and jr[1].total == 7,
       "the sliced ledger admitted junk the one-shot rejects (" .. #jr .. " rows)")
    -- "C-R" holds a non-table and the numeric key 7 is not a string: both are
    -- refused, exactly as BuildLedger refuses them.
    ck(js.chars == 2, "the sliced ledger's character count admitted junk keys ("
       .. js.chars .. ")")
    ck(js.chars == select(2, InvUI.BuildLedger(junk)).chars,
       "the sliced and one-shot ledgers disagree about who counts as a character")
    ck(#InvUI.RunLedger(nil) == 0, "a nil graph did not answer an empty sliced ledger")
    ck(select(1, InvUI.StepLedger(nil)) == true, "a nil job was not a no-op")
end

----------------------------------------------------------------------

-- The glyph registry: only sequences PROVEN to render, and no drift from the
-- professions copy of the same table when that file is present.
local function testGlyphs(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(InvUI.GLYPHS.dots   == "\226\128\166", "the ellipsis glyph drifted")
    ck(InvUI.GLYPHS.middot == "\194\183",     "the middot glyph drifted")
    ck(InvUI.GLYPHS.dash   == "\226\128\148", "the em dash glyph drifted")
    ck(InvUI.GLYPHS.down == "v" and #InvUI.GLYPHS.down == 1,
       "the sort mark is not the ASCII it claims to be")

    local P = ns.ProfessionsUI
    if P and P.GLYPHS then
        for _, key in ipairs({ "dots", "middot", "dash" }) do
            ck(InvUI.GLYPHS[key] == P.GLYPHS[key],
               "the '" .. key .. "' glyph disagrees with the professions registry")
        end
    end

    -- the banned sequences that already shipped as tofu once must not reappear
    for _, banned in ipairs({ "\226\156\147", "\226\151\134" }) do   -- U+2713, U+25C6
        for key, g in pairs(InvUI.GLYPHS) do
            ck(g:find(banned, 1, true) == nil,
               "glyph '" .. key .. "' carries a sequence proven to render as tofu")
        end
    end

    -- the ask ladder is bounded and terminates
    ck(#InvUI.WATCH_LADDER == 5, "the re-ask ladder changed length")
    ck(InvUI.LadderDelay(#InvUI.WATCH_LADDER + 1) == nil, "the ladder has no last rung")
    ck(InvUI.LadderCeiling() == 7.75, "the ladder ceiling drifted: " .. InvUI.LadderCeiling())
    ck(InvUI.MAX_ASKS == 3, "the per-id ask bound changed")
end

----------------------------------------------------------------------

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("inventoryui", function(verbose)
        local suites = {
            { name = "ledger transpose (cross-account totals, splits, junk, determinism)",
              fn = testLedger },
            { name = "split agrees with the hover's own model (anti-drift pin)",
              fn = testSplitAgreesWithTooltipModel },
            { name = "sort matrix (name, qty-desc, total order, idempotence, header toggle)",
              fn = testSortMatrix },
            { name = "search + category compose (substring, case, plain-text, ring heal)",
              fn = testFilterCompose },
            { name = "cold-item honesty (rendered, counted, filtered, healed, RED CONTROL)",
              fn = testColdItemHonesty },
            { name = "pooled-row recycle hygiene (tooltip never crosses rows, cold shift)",
              fn = testRecycleHygiene },
            { name = "geometry (multi-width fit, header/column single source, insets)",
              fn = testGeometry },
            { name = "virtualization (viewport-bounded pool, window coverage, clamping)",
              fn = testVirtualization },
            { name = "footer + roster coverage (staleness, unstamped honesty, formatting)",
              fn = testFooterAndCoverage },
            { name = "tab registration + shell inertness (ungated, ordered, builds nothing)",
              fn = testTabRegistrationAndInertness },
            { name = "glyph registry + ask ladder bounds",
              fn = testGlyphs },
            { name = "first-open budget (sliced ledger == one-shot, per-slice "
                  .. "ceiling, bounded viewport-first asks, coalesced repaints, "
                  .. "cache invalidation, warm ceiling, RED CONTROLS)",
              fn = testFirstOpenBudget },
            { name = "slice honesty (precomputed sort key cannot move a row, "
                  .. "progress line quotes no totals, indexing outranks empty)",
              fn = testSliceHonesty },
        }
        local allPass = true
        for _, suite in ipairs(suites) do
            local f = {}
            local ok, err = pcall(suite.fn, f)
            local passed = ok and #f == 0
            if not passed then allPass = false end
            if verbose and ns and ns.Print then
                if passed then ns:Print("  PASS inventoryui/" .. suite.name)
                elseif not ok then
                    ns:Print("  FAIL inventoryui/" .. suite.name .. " :: error in test: " .. tostring(err))
                else
                    for _, m in ipairs(f) do ns:Print("  FAIL inventoryui/" .. suite.name .. " :: " .. m) end
                end
            end
        end
        return allPass
    end)
end
