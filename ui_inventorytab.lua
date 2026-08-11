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
function InvUI.Decorate(rows, res)
    local pending = {}
    if type(rows) ~= "table" then return pending end
    local get = res and res.item
    for i = 1, #rows do
        local r = rows[i]
        local f = get and get(r.id) or nil
        if f then
            r.name, r.quality, r.icon, r.category = f.name, f.quality, f.icon, f.category
            r.resolved = true
        else
            r.name, r.quality, r.icon, r.category = nil, nil, nil, nil
            r.resolved = false
            pending[#pending + 1] = r.id
        end
    end
    table.sort(pending)        -- class 8: this list drives a bounded retry loop
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

    local function nameKey(r)
        if r.resolved and type(r.name) == "string" and r.name ~= "" then
            return r.name:lower()
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
--   state = { matched, pendingHidden, hasQuery, exhausted, ledgerEmpty, moduleOff }
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
    wf:SetScript("OnEvent", function()
        if repaintPane then ns:SafeCall(repaintPane) end
    end)
    pcall(function() wf:RegisterEvent("GET_ITEM_INFO_RECEIVED") end)
    watcher = wf
    if _G.C_Timer and _G.C_Timer.After then
        watchRound = 0
        local function rung()
            watchRound = watchRound + 1
            local d = InvUI.LadderDelay(watchRound)
            if not d then
                stopWatch()
                if repaintPane then ns:SafeCall(repaintPane) end
                return
            end
            _G.C_Timer.After(d, function()
                if repaintPane then ns:SafeCall(repaintPane) end
                rung()
            end)
        end
        rung()
    end
end

-- Called by every render that produced pending ids. Ids a completed ladder has
-- already given up on are dropped here, so they can neither re-ask nor re-arm.
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
    InvUI.AskFor(fresh, res)
    startWatch()
    return true
end
InvUI._notePending = notePending

-- One reset for both halves, so a fresh look is genuinely fresh.
function InvUI._resetWatchState()
    stopWatch()
    watching, exhausted = {}, {}
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

        local slot = 0
        for i = first, last do
            slot = slot + 1
            local ir = getRow(slot)
            ir:ClearAllPoints()
            ir:SetPoint("TOPLEFT", listKid, "TOPLEFT", 0, -(yTop + (i - first) * L.ROW_H))
            ir:SetWidth(math.max(1, availW))
            invFitRow(ir, cols)
            invPaintRow(ir, pane._view[i])
            ir:Show()
        end
        for j = slot + 1, #pane._rows do pane._rows[j]:Hide() end

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

    -- filter -> sort -> draw.
    function pane.obj.Apply()
        local view, state = InvUI.FilterRows(pane._ledger, pane.query, pane.category)
        pane._view  = InvUI.SortRows(view, pane.sort)
        pane._state = state
        state.exhausted   = InvUI.Exhausted(pane._pending)
        state.ledgerEmpty = (#pane._ledger == 0)
        state.moduleOff   = InvUI.ModuleOff()

        local emptyText, statusText = InvUI.StatusText(state)
        emptyFS:SetText(emptyText or "")
        statusFS:SetText(statusText or "")
        footerFS:SetText(InvUI.FooterText(pane._stats, pane._cov, Dashboard.FormatDuration))

        listScroll:SetVerticalScroll(0)
        renderWindow()
    end

    -- Re-read the client's item facts and re-ask for what is still cold. Cheap
    -- (the resolver caches every answer), so the watcher can drive it.
    function pane.obj.Decorate()
        local res = InvUI.LiveResolver()
        pane._pending = InvUI.Decorate(pane._ledger, res)
        notePending(pane._pending, res)
        pane.category = catChip:SetRing(InvUI.CategoryChoices(pane._ledger), pane.category)
        persist()
    end

    -- Rebuild the ledger from the owners graph.
    function pane.obj.Refresh()
        local owners = InvUI.Owners()
        local rows, stats = InvUI.BuildLedger(owners)
        pane._ledger, pane._stats = rows, stats
        pane._cov = InvUI.Coverage(owners, (GetServerTime and GetServerTime()) or (time and time()) or 0)
        pane.obj.Decorate()
        pane.obj.Apply()
    end

    -- The watcher's repaint: names only, never a ledger rebuild.
    repaintPane = function()
        if not thePane then return end
        thePane.obj.Decorate()
        thePane.obj.Apply()
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
