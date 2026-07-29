-- Daseeki Nexus — ui_tab_timers.lua
-- The "Timers" tab — BRAND_SPEC §7 "Field Ledger" Screen 2 (WAVE R2-a).
--
-- Owner-locked shape (mockup Screen 2, BRAND_SPEC §6/§7/§8):
--   * World buffs = COMPACT ledger rows (~31px): real spell-icon tile · name
--     (+faction crest / source) · status = green "Open" (ok token) when the buff
--     is off-cooldown OR an OUTLINED countdown numeral when on CD · absolute
--     off-CD stamp · Log link (existing pop-log popups kept). NO large HUD bars
--     on this page — pull bars live only in the HUD (Screen 4).
--   * Songflowers = a fixed 2×5 grid (no scroll). Each cell: node number + label,
--     plain state copy ("Respawn M:SS" / "UP?" / "No data"), fed by GetNodeState.
--   * Broadcast Timers button + hint (plain copy) at the foot.
--
-- Ledger dress: UI.PaintLedgerGround (grain + vignette + the window's ONE bronze
-- keyline), ceremonial section headers (MORPHEUS ≥16, §3/§7), microLabel / numeral
-- telemetry fonts. Attention inversion (§5/§8): off-cooldown = calm green "Open";
-- an imminent CD (≤20 min) uses danger red with a BRIGHTEN pulse (raises luminance,
-- never alpha-dims — §8). Text/numerals live on child frames with flat fills so no
-- glyph ever sits on the grain (§4 layering contract).
--
-- Clean-room build on our own DaseekiUI/Ledger stack. No third-party code.

local ADDON, ns = ...
local UI = DaseekiUI                 -- nil under the headless harness; only ever
local Dashboard = ns.Dashboard       -- dereferenced inside function bodies below.

----------------------------------------------------------------------
-- Metrics.
----------------------------------------------------------------------

local PAD      = 10
local WB_ROW_H = 31     -- compact world-buff ledger row (mockup .wbrow)
local WB_GAP   = 2
local WB_TILE  = 20     -- real-spell-icon tile edge
local SF_COLS  = 5      -- songflower grid = 2 rows × 5 cols = 10 nodes (no scroll)
local SF_GAP   = 6
local SF_CELL_H = 50
local SF_IMMINENT = 20 * 60   -- CD ≤ 20 min = danger + brighten pulse (§8)

-- Raise luminance of a color toward white (never darkens); mirrors the ledger
-- kit's urgency-brighten so an imminent countdown BRIGHTENS instead of dimming
-- (BRAND_SPEC §8 — "brighten, not alpha-dim").
local function brighten(r, g, b, t)
    t = t or 0.35
    return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

----------------------------------------------------------------------
-- PURE grid-cell layout math (harness-testable; no frames touched). Returns the
-- 0-based col/row plus the x offset, y offset (negative, top-anchored) and cell
-- width for a 1-based `index` in a `cols`-wide grid that fills `areaW` with `gap`
-- between cells and `cellH` tall rows. Exported so the self-test can exercise the
-- 2×5 songflower placement without a live UI.
----------------------------------------------------------------------

function Dashboard.TimersGridCell(index, cols, areaW, gap, cellH, rowGap)
    cols   = cols or SF_COLS
    gap    = gap or SF_GAP
    rowGap = rowGap or gap
    local col = (index - 1) % cols
    local row = math.floor((index - 1) / cols)
    local cellW = (areaW - (cols - 1) * gap) / cols
    return {
        col = col,
        row = row,
        x   = col * (cellW + gap),
        y   = -(row * ((cellH or SF_CELL_H) + rowGap)),
        w   = cellW,
    }
end

----------------------------------------------------------------------
-- PURE songflower-cell CONTENT builder (harness-testable; no frames). The owner
-- round-1 flip makes the TIMER the hero of each cell (not the location name), so
-- the state->numeral/color mapping is factored out here and exercised by the
-- "timersui" self-test matrix.
--
-- Compact hero numeral: "12s" / "18m" / "2h" while respawning, "UP?" when up, an
-- em-dash when there's no data. Colors follow BRAND_SPEC §5a (calm must never read
-- lifeless): a respawning numeral is warm CREAM ("text"), brightening to AMBER
-- ("warn") under 60s; UP? is ok GREEN; no-data is FAINT.
----------------------------------------------------------------------

-- Compact single-unit duration ("12s" / "18m" / "2h"). Pure.
function Dashboard.ShortDur(s)
    s = math.max(0, math.floor((tonumber(s) or 0) + 0.5))
    if s >= 3600 then return math.floor(s / 3600) .. "h" end
    if s >= 60   then return math.floor(s / 60) .. "m" end
    return s .. "s"
end

-- Map a node state ({ state = "up"/"down"/"unknown", remaining = n }) to the hero
-- cell content. Returns (heroText, heroColorToken, captionColorToken). Pure.
function Dashboard.SongflowerCellContent(st)
    if not st or st.state == "unknown" then
        return "\226\128\148", "faint", "faint"   -- em-dash, no data
    elseif st.state == "down" then
        local rem = st.remaining or 0
        return Dashboard.ShortDur(rem), (rem < 60) and "warn" or "text", "muted"
    else
        return "UP?", "ok", "muted"
    end
end

local function fstr(parent, key)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    return f
end

-- A ceremonial section header (MORPHEUS ≥16, §3/§7) reusing the kit header (which
-- carries the ruled hairline under the title) with the font swapped to ceremonial.
-- Returns header, metaFontString (right-aligned microLabel caption).
local function sectionHeader(parent, title)
    local h = UI.MakeSectionHeader(parent, title)
    if h._label then h._label:SetFontObject(UI.fonts.ceremonial) end
    local meta = fstr(h, "microLabel")
    meta:SetJustifyH("RIGHT")
    meta:SetPoint("TOPRIGHT", h, "TOPRIGHT", 0, -4)
    meta:SetTextColor(UI.Color("faint"))
    h._meta = meta
    return h, meta
end

-- A small bordered tile holding a real spell icon (attention-inverted context is
-- carried by the row's status, not the tile — the icon just identifies the buff).
local function makeIconTile(parent, size)
    local t = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    t:SetSize(size, size)
    UI.Skin(t, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("bronzeDim"))
    end)
    local ic = t:CreateTexture(nil, "ARTWORK")
    ic:SetPoint("TOPLEFT", t, "TOPLEFT", 1, -1)
    ic:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -1, 1)
    ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.icon = ic
    return t
end

local function anchorOf(state)
    if not state then return 0 end
    return math.max(state.lastPop or 0, state.lastKilled or 0)
end

-- World-buff rows. Onyxia rows carry a faction `crest` (parity item 8) shown as a
-- PvP crest icon after the name; `title` disambiguates the pop-log headers.
local WB_ROWS = {
    { key = "rend", logKey = "rend", slot = 2, label = "Rend (Warchief's)", title = "Rend" },
    { key = "onyH", logKey = "onyH", slot = 1, label = "Onyxia", crest = "Horde",    title = "Onyxia (Horde)" },
    { key = "onyA", logKey = "onyA", slot = 1, label = "Onyxia", crest = "Alliance", title = "Onyxia (Alliance)" },
}

----------------------------------------------------------------------
-- Pop-log popup (shared instance; retargeted per buff). Unchanged from R1.
----------------------------------------------------------------------

local function ensurePopLog()
    if Dashboard._popLog then return Dashboard._popLog end
    local p = CreateFrame("Frame", "DaseekiNexusPopLog", UIParent, "BackdropTemplate")
    p:SetFrameStrata("DIALOG")
    p:SetSize(320, 300)
    p:SetPoint("CENTER")
    p:SetMovable(true); p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function(self) self:StartMoving() end)
    p:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    p:Hide()
    tinsert(UISpecialFrames, "DaseekiNexusPopLog")
    UI.Skin(p, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("ground"))
        self:SetBackdropBorderColor(UI.Color("accent"))
    end)
    local title = fstr(p, "header")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -10)
    p.title = title
    local close = UI.MakeButton(p, { text = "X", variant = "quiet", width = 22, height = 20,
        onClick = function() p:Hide() end })
    close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)

    local scroll = CreateFrame("ScrollFrame", nil, p)
    scroll:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -36)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -12, 12)
    scroll:SetClipsChildren(true)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1); scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 28)))
    end)
    p._child = child
    p._lines = {}
    Dashboard._popLog = p
    return p
end

local function showPopLog(logKey, titleText)
    local p = ensurePopLog()
    p.title:SetText(titleText)
    local child = p._child
    for _, l in ipairs(p._lines) do l:Hide() end
    local logs = ns.Store.GetTimers().logs or {}
    local list = logs[logKey] or {}
    local W = p:GetWidth() - 24
    child:SetWidth(W)
    local y = 0
    local nowE = Dashboard.Now()
    if #list == 0 then
        local l = p._lines[1] or fstr(child, "muted"); p._lines[1] = l
        l:ClearAllPoints(); l:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0); l:SetWidth(W)
        l:SetText("No pops recorded this reset."); l:Show()
        y = 20
    else
        for i = 1, math.min(#list, 50) do
            local e = list[i]
            local l = p._lines[i]
            if not l then l = fstr(child, "body"); l:SetJustifyH("LEFT"); l:SetWordWrap(false); p._lines[i] = l end
            l:ClearAllPoints()
            l:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            l:SetWidth(W)
            local tag = e.killed and Dashboard.Colored("NPC Killed","danger") or (e.quest and Dashboard.Colored("Quest","ok") or Dashboard.Colored("Pop","muted"))
            local when = date("%m/%d %H:%M", e.epoch or nowE)
            local ago = Dashboard.FormatDuration(nowE - (e.epoch or nowE))
            l:SetText(("%s  %s  %s  (%s ago)"):format(when, tag, e.who or "?", ago))
            l:Show()
            y = y + 18
        end
    end
    child:SetHeight(math.max(y, 1))
    p:Show()
end

----------------------------------------------------------------------
-- Tab registration — Screen 2.
----------------------------------------------------------------------

Dashboard.RegisterTab("timers", function(host)
    local obj = {}

    -- Ledger ground for the whole page (grain + vignette + the window's ONE bronze
    -- keyline). Rows/cells carry their own flat fills so glyphs never sit on grain.
    local box = UI.FlatFrame(host, "ground", "border")
    box:SetAllPoints(host)
    UI.PaintLedgerGround(box, { keyline = true })

    ------------------------------------------------------------------
    -- World buffs section — compact ledger rows.
    ------------------------------------------------------------------
    local wbHdr = sectionHeader(box, "World buffs")
    wbHdr:SetPoint("TOPLEFT", box, "TOPLEFT", PAD, -PAD)
    wbHdr:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PAD, -PAD)
    wbHdr._meta:SetText("live board")

    local wbRows, prev = {}, nil
    for i, def in ipairs(WB_ROWS) do
        local r = CreateFrame("Frame", nil, box)
        r:SetHeight(WB_ROW_H)
        if prev then
            r:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -WB_GAP)
            r:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -WB_GAP)
        else
            r:SetPoint("TOPLEFT", wbHdr, "BOTTOMLEFT", 0, -4)
            r:SetPoint("TOPRIGHT", wbHdr, "BOTTOMRIGHT", 0, -4)
        end
        r._def = def

        -- Flat row fill (token "ground") so the row's text sits on flat colour, not
        -- grain (§4 layering) — reads as the same worn ground the box paints.
        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints(r)
        UI.Skin(r.bg, function(self) self:SetColorTexture(UI.Color("ground")) end)

        r.tile = makeIconTile(r, WB_TILE)
        r.tile:SetPoint("LEFT", r, "LEFT", 4, 0)
        r.tile.icon:SetTexture(Dashboard.AuraIcon(def.slot))

        r.name = fstr(r, "body"); r.name:SetPoint("LEFT", r.tile, "RIGHT", 9, 0); r.name:SetText(def.label)
        local afterName = r.name
        if def.crest then
            r.crest = r:CreateTexture(nil, "ARTWORK")
            r.crest:SetSize(16, 16); r.crest:SetPoint("LEFT", r.name, "RIGHT", 5, 0)
            r.crest:SetTexture(Dashboard.FactionCrest(def.crest))
            r.crest:SetTexCoord(0.02, 0.62, 0.03, 0.63)
            afterName = r.crest
        end

        -- Log link (kept — existing pop-log popup).
        r.log = UI.MakeButton(r, { text = "Log", variant = "quiet", width = 44, height = 20,
            onClick = function() showPopLog(def.logKey, (def.title or def.label) .. " — Pop Log") end })
        r.log:SetPoint("RIGHT", r, "RIGHT", 2, 0)
        -- Absolute off-CD stamp (microLabel), left of the Log link.
        r.stamp = fstr(r, "microLabel"); r.stamp:SetPoint("RIGHT", r.log, "LEFT", -10, 0); r.stamp:SetJustifyH("RIGHT")
        -- Status: green "Open" OR an outlined countdown numeral, right of the stamp.
        r.status = fstr(r, "numeral"); r.status:SetPoint("RIGHT", r.stamp, "LEFT", -12, 0); r.status:SetJustifyH("RIGHT")

        -- ONE hairline per row (§5/§6): a bottom rule.
        r.rule = UI.Hairline(r, { token = "border" })
        r.rule:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 2, 0)
        r.rule:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -2, 0)

        wbRows[i] = r
        prev = r
    end

    ------------------------------------------------------------------
    -- Songflowers section — fixed 2×5 grid (no scroll).
    ------------------------------------------------------------------
    local sfHdr, sfMeta = sectionHeader(box, "Songflowers")
    sfHdr:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -12)
    sfHdr:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -12)

    local nodes = ns.Timers and ns.Timers.NODES and ns.Timers.NODES.flower or {}
    local sfCells = {}
    for i = 1, #nodes do
        local cell = UI.FlatFrame(box, "panel", "border")
        cell:SetHeight(SF_CELL_H)
        -- Cell number stays a small corner microlabel (top-left).
        cell.no = fstr(cell, "microLabel"); cell.no:SetPoint("TOPLEFT", cell, "TOPLEFT", 7, -5)
        cell.no:SetTextColor(UI.Color("faint")); cell.no:SetText(("%02d"):format(i))
        -- HERO: the timer is the focal point — a large outlined countdown numeral
        -- centered in the cell (owner round-1 flip). Enlarge the telemetry numeral
        -- face to hero size, keeping its OUTLINE.
        cell.timer = fstr(cell, "numeral")
        do
            local fp, _, ff = cell.timer:GetFont()
            if fp then cell.timer:SetFont(fp, 22, (ff and ff ~= "" and ff) or "OUTLINE") end
        end
        cell.timer:SetPoint("CENTER", cell, "CENTER", 0, 6)
        cell.timer:SetJustifyH("CENTER")
        -- Location name demoted to a small caption beneath the numeral.
        cell.nm = fstr(cell, "microLabel"); cell.nm:SetPoint("BOTTOM", cell, "BOTTOM", 0, 5)
        cell.nm:SetJustifyH("CENTER"); cell.nm:SetWordWrap(false)
        cell.nm:SetText(nodes[i].label or ("Node " .. i))
        cell.nm:SetTextColor(UI.Color("muted"))
        cell._nodeKey = "flower" .. i
        sfCells[i] = cell
    end

    -- Lay the grid out from the current box width (called on every resize). Cell
    -- width flexes; the label wraps inside. Pure math via Dashboard.TimersGridCell.
    local function layoutGrid()
        local areaW = box:GetWidth() - 2 * PAD
        if areaW <= 0 then return end
        for i, cell in ipairs(sfCells) do
            local g = Dashboard.TimersGridCell(i, SF_COLS, areaW, SF_GAP, SF_CELL_H)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", sfHdr, "BOTTOMLEFT", g.x, -6 + g.y)
            cell:SetWidth(g.w)
            cell.nm:SetWidth(g.w - 10)
            cell.timer:SetWidth(g.w - 8)
        end
    end

    ------------------------------------------------------------------
    -- Broadcast Timers button + hint (plain copy).
    ------------------------------------------------------------------
    local bcast = UI.MakeButton(box, {
        text = "Broadcast Timers", variant = "normal", width = 160, height = 24,
        onClick = function(self)
            local nowT = GetTime()
            if obj._lastBcast and (nowT - obj._lastBcast) < 60 then
                ns:Print("broadcast throttled (60s).")
                return
            end
            if ns.Mesh and ns.Mesh.BroadcastTimers and ns.Timers then
                ns:SafeCall(ns.Mesh.BroadcastTimers, ns.Timers.GetSnapshot())
                obj._lastBcast = nowT
                ns:Print("timers broadcast to guild/mesh.")
            else
                ns:Print("mesh broadcast arrives in a later update.")
            end
        end,
    })
    bcast:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", PAD, 10)
    local bcastHint = fstr(box, "microLabel")
    bcastHint:SetPoint("LEFT", bcast, "RIGHT", 10, 0)
    bcastHint:SetText("Sends your timer data to the mesh (throttled 60s).")
    bcastHint:SetTextColor(UI.Color("muted"))

    ------------------------------------------------------------------
    -- Refresh routine.
    ------------------------------------------------------------------
    function obj.Refresh()
        local T = ns.Timers
        local nowE = Dashboard.Now()

        for _, r in ipairs(wbRows) do
            local def = r._def
            local state = T and T.state and T.state[def.key]
            local anchor = anchorOf(state)
            local info = T and T.ComputeCD and T.ComputeCD(def.key, anchor, nowE)
            if not info or anchor <= 0 then
                r.status:SetText("No data"); r.status:SetTextColor(UI.Color("faint"))
                r.status._pulse = false
                r.stamp:SetText("")
            elseif info.ready then
                -- Off-cooldown = green "Open" (§6 binding; ok token). Calm, not urgent.
                r.status:SetText("Open"); r.status:SetTextColor(UI.Color("ok"))
                r.status._pulse = false
                r.stamp:SetText("")
            else
                local rem = info.remaining or 0
                local killed = state.lastKilled and state.lastKilled >= (state.lastPop or 0)
                r.status:SetText((killed and "Killed · " or "") .. Dashboard.FormatDuration(rem))
                if rem <= SF_IMMINENT then
                    -- Imminent: danger red + brighten pulse (driven by the ticker, §8).
                    r.status:SetTextColor(UI.Color("danger"))
                    r.status._pulse = true
                else
                    -- Steady amber for CD > 20 min (§3 "steady orange").
                    r.status:SetTextColor(UI.Color("warn"))
                    r.status._pulse = false
                end
                r.stamp:SetText("off CD " .. date("%H:%M:%S", info.nextAt))
                r.stamp:SetTextColor(UI.Color("muted"))
            end
        end

        local nUp, nDown, nUnknown = 0, 0, 0
        for _, cell in ipairs(sfCells) do
            local st = T and T.GetNodeState and T.GetNodeState(cell._nodeKey)
            -- Hero numeral + caption color from the PURE content mapper (flip: the
            -- timer leads, the name is the caption).
            local heroText, heroTok, capTok = Dashboard.SongflowerCellContent(st)
            cell.timer:SetText(heroText); cell.timer:SetTextColor(UI.Color(heroTok))
            cell.nm:SetTextColor(UI.Color(capTok))
            if not st or st.state == "unknown" then
                nUnknown = nUnknown + 1
            elseif st.state == "down" then
                nDown = nDown + 1
            else -- up
                nUp = nUp + 1
            end
        end
        sfMeta:SetText(("Felwood · %d up · %d respawning · %d unknown"):format(nUp, nDown, nUnknown))
    end

    ------------------------------------------------------------------
    -- 1s ticker + brighten pulse for imminent world-buff countdowns (§8). A hidden
    -- frame receives no OnUpdate, so the ticker pauses when another tab is shown.
    ------------------------------------------------------------------
    local accum = 0
    host:SetScript("OnUpdate", function(self, elapsed)
        accum = accum + elapsed
        local dr, dg, db = UI.Color("danger")
        local t = 0.4 * math.abs(math.sin(GetTime() * 3))   -- 0 .. 0.4 toward white
        for _, r in ipairs(wbRows) do
            r.status:SetAlpha(1)   -- never alpha-dim (§8)
            if r.status._pulse then
                r.status:SetTextColor(brighten(dr, dg, db, t))
            end
        end
        if accum >= 1 then accum = 0; ns:SafeCall(obj.Refresh) end
    end)

    box:SetScript("OnSizeChanged", function() layoutGrid(); obj.Refresh() end)
    layoutGrid()
    return obj
end)

----------------------------------------------------------------------
-- Self-test: the pure songflower-grid layout math (Dashboard.TimersGridCell).
-- Verifies the 2×5 placement (5 per row, correct col/row/x/width) that the live
-- layoutGrid relies on — runs headless (no frames). Registered as suite "timersui"
-- (distinct from timers.lua's engine "timers" suite).
----------------------------------------------------------------------

local function testGridLayout(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- 10 nodes, 5 columns, 400px area, 6px gap. cellW = (400 - 4*6)/5 = 75.2.
    local areaW, cols, gap, cellH = 400, 5, 6, 50
    local expW = (areaW - (cols - 1) * gap) / cols
    -- Row 0: indices 1..5 (col 0..4, row 0).
    for i = 1, 5 do
        local g = Dashboard.TimersGridCell(i, cols, areaW, gap, cellH)
        ck(g.row == 0, "index " .. i .. " on row 0")
        ck(g.col == i - 1, "index " .. i .. " col == " .. (i - 1))
        ck(math.abs(g.w - expW) < 1e-9, "index " .. i .. " width == " .. expW)
        ck(math.abs(g.x - (i - 1) * (expW + gap)) < 1e-9, "index " .. i .. " x offset")
        ck(g.y == 0, "row-0 cells sit at y == 0")
    end
    -- Row 1: index 6 is the first cell of the second row (col 0, row 1).
    local g6 = Dashboard.TimersGridCell(6, cols, areaW, gap, cellH)
    ck(g6.col == 0 and g6.row == 1, "index 6 wraps to col 0 / row 1")
    ck(g6.x == 0, "index 6 x resets to 0 on the new row")
    ck(g6.y == -(cellH + gap), "index 6 drops one row (y == -(cellH+gap))")
    -- Index 10 is the last cell (col 4, row 1).
    local g10 = Dashboard.TimersGridCell(10, cols, areaW, gap, cellH)
    ck(g10.col == 4 and g10.row == 1, "index 10 is col 4 / row 1 (grid corner)")
    -- Distinct rowGap is honored when supplied.
    local gr = Dashboard.TimersGridCell(6, cols, areaW, gap, cellH, 20)
    ck(gr.y == -(cellH + 20), "custom rowGap applied to y")
end

-- Cell CONTENT matrix (owner round-1 flip): the hero numeral text + color token
-- and the caption color token for every node state. Verifies compact numerals,
-- the <60s amber brighten, UP? green, and the no-data em-dash faint.
local function testCellContent(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local EMDASH = "\226\128\148"

    -- Compact single-unit durations.
    ck(Dashboard.ShortDur(12) == "12s", "ShortDur seconds -> '12s'")
    ck(Dashboard.ShortDur(0)  == "0s",  "ShortDur zero -> '0s'")
    ck(Dashboard.ShortDur(59) == "59s", "ShortDur 59 -> '59s'")
    ck(Dashboard.ShortDur(60) == "1m",  "ShortDur 60 -> '1m'")
    ck(Dashboard.ShortDur(18 * 60) == "18m", "ShortDur 1080 -> '18m'")
    ck(Dashboard.ShortDur(2 * 3600) == "2h", "ShortDur 7200 -> '2h'")

    -- No data -> em-dash, faint numeral + faint caption.
    local t, c, cap = Dashboard.SongflowerCellContent(nil)
    ck(t == EMDASH and c == "faint" and cap == "faint", "no state -> em-dash / faint / faint")
    t, c, cap = Dashboard.SongflowerCellContent({ state = "unknown" })
    ck(t == EMDASH and c == "faint", "unknown -> em-dash / faint")

    -- Respawning -> compact numeral, warm CREAM ('text'); caption muted.
    t, c, cap = Dashboard.SongflowerCellContent({ state = "down", remaining = 18 * 60 })
    ck(t == "18m" and c == "text" and cap == "muted", "down >60s -> '18m' / cream / muted")

    -- Respawning under 60s -> AMBER ('warn') brighten.
    t, c = Dashboard.SongflowerCellContent({ state = "down", remaining = 45 })
    ck(t == "45s" and c == "warn", "down <60s -> '45s' / warn (amber)")
    -- Boundary: exactly 60s is still cream, 59s is amber.
    ck(select(2, Dashboard.SongflowerCellContent({ state = "down", remaining = 60 })) == "text", "60s boundary is cream")
    ck(select(2, Dashboard.SongflowerCellContent({ state = "down", remaining = 59 })) == "warn", "59s is amber")

    -- Up -> 'UP?' in ok green.
    t, c = Dashboard.SongflowerCellContent({ state = "up" })
    ck(t == "UP?" and c == "ok", "up -> 'UP?' / ok green")
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("timersui", function(verbose)
        local fails = {}
        local ok = pcall(function() testGridLayout(fails); testCellContent(fails) end)
        local passed = ok and #fails == 0
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS timersui/songflower grid layout + cell content")
            elseif not ok then ns:Print("  FAIL timersui/songflower :: error in test")
            else for _, f in ipairs(fails) do ns:Print("  FAIL timersui/songflower :: " .. f) end end
        end
        return passed
    end)
end
