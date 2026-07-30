-- Daseeki Nexus — ui_timersdock.lua
-- The RIGHT-BOTTOM "timers dock" of the control-panel dashboard.
--
-- NEXUS DIRECTION PIVOT (BRAND_SPEC 2026-07-29): the Timers TAB DISSOLVES — its
-- content docks here, in the lower-right pane region of the Characters screen. This
-- file re-houses the proven timer logic from the retired ui_tab_timers.lua: the
-- world-buff cooldown rows (icon tile · name+crest · green "Open" / outlined
-- countdown · off-CD stamp · Log link + pop-log popup), the songflower strip (a
-- compact 2×5 mini grid), and the Broadcast button. It ALSO subsumes the former
-- status bar's live world-buff readouts (that band is removed from the window).
--
-- AESTHETIC (control-panel, pivot §10 vetoes): flat token fills, sharp 1px
-- UI.Hairline rules, uppercase microLabels, outlined numerals. NO PaintLedgerGround
-- / grain / ceremonial serif here (that dress is retired on the dashboard). All
-- colors via theme tokens. Off-cooldown reads as the green "Open" term (§6; the
-- old can-pop phrasing is banned suite-wide).
--
-- GEOMETRY (mockup nexus-controlpanel-notes.md, dock = 260 tall):
--   pad 11/14 · WB header + 3 rows @ ~25 · SF header + 2×5 grid gap 4 · Broadcast.
--
-- Clean-room build on our own DaseekiUI stack. No third-party code or identifiers.

local ADDON, ns = ...
local UI = DaseekiUI                 -- nil under the headless harness; only ever
local Dashboard = ns.Dashboard       -- dereferenced inside function bodies below.
local TimersDock = {}
ns.TimersDock = TimersDock

----------------------------------------------------------------------
-- Metrics (mockup dock values).
----------------------------------------------------------------------
local PAD_V     = 11
local PAD_H     = 14
-- Round-4: the dock grew to 292 (from 260). Rows + songflower cells BREATHE into the
-- reclaimed space (taller WB rows; 2-line songflower cells) so the content fills the
-- dock top-down instead of leaving a dead band above/below Broadcast.
local WB_ROW_H  = 31
local WB_TILE   = 18
local SF_COLS   = 5
local SF_GAP    = 6
local SF_CELL_H = 38
local SF_IMMINENT = 20 * 60   -- CD ≤ 20 min = danger + brighten pulse

-- Raise luminance of a color toward white (never darkens) — an imminent countdown
-- BRIGHTENS instead of alpha-dimming.
local function brighten(r, g, b, t)
    t = t or 0.35
    return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

----------------------------------------------------------------------
-- PURE grid-cell layout math (harness-testable; no frames). Re-housed from
-- ui_tab_timers.lua onto the Dashboard table so the "timersui" self-test — which
-- pins the 2×5 songflower placement — keeps its exact target. 0-based col/row +
-- x offset, negative top-anchored y offset, and flexed cell width.
----------------------------------------------------------------------
function Dashboard.TimersGridCell(index, cols, areaW, gap, cellH, rowGap)
    cols   = cols or SF_COLS
    gap    = gap or SF_GAP
    rowGap = rowGap or gap
    local col = (index - 1) % cols
    local row = math.floor((index - 1) / cols)
    local cellW = (areaW - (cols - 1) * gap) / cols
    return { col = col, row = row, x = col * (cellW + gap),
             y = -(row * ((cellH or SF_CELL_H) + rowGap)), w = cellW }
end

-- Compact single-unit duration ("12s" / "18m" / "2h"). Pure.
function Dashboard.ShortDur(s)
    s = math.max(0, math.floor((tonumber(s) or 0) + 0.5))
    if s >= 3600 then return math.floor(s / 3600) .. "h" end
    if s >= 60   then return math.floor(s / 60) .. "m" end
    return s .. "s"
end

-- Map a node state ({ state = "up"/"down"/"unknown", remaining = n }) to hero-cell
-- content. Returns (heroText, heroColorToken, captionColorToken). Pure.
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

-- World-buff rows. Onyxia rows carry a faction crest; `title` names the pop-log.
local WB_ROWS = {
    { key = "rend", logKey = "rend", slot = 2, label = "Rend (Warchief's)", title = "Rend" },
    { key = "onyH", logKey = "onyH", slot = 1, label = "Onyxia", crest = "Horde",    title = "Onyxia (Horde)" },
    { key = "onyA", logKey = "onyA", slot = 1, label = "Onyxia", crest = "Alliance", title = "Onyxia (Alliance)" },
}

local function anchorOf(state)
    if not state then return 0 end
    return math.max(state.lastPop or 0, state.lastKilled or 0)
end

----------------------------------------------------------------------
-- In-game helpers (UI non-nil here).
----------------------------------------------------------------------
local function tag(frame, id)
    if ns.Audit and ns.Audit.Tag and frame then ns.Audit.Tag(frame, id) end
    return frame
end
local function fstr(parent, key, justify)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(Dashboard.Font(key))   -- round-11 item 2: ARIALN dashboard type
    if justify then f:SetJustifyH(justify) end
    return f
end
-- Pop pass (round-4): section labels read at `muted` (a tier up from faint).
local function microLabel(parent, text)
    local l = fstr(parent, "microLabel")
    l:SetTextColor(UI.Color("muted"))
    if text then l:SetText(text) end
    return l
end
local function makeIconTile(parent, size)
    local t = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    t:SetSize(size, size)
    UI.Skin(t, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))   -- pop pass: visible edge
    end)
    local ic = t:CreateTexture(nil, "ARTWORK")
    ic:SetPoint("TOPLEFT", t, "TOPLEFT", 1, -1)
    ic:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -1, 1)
    ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.icon = ic
    return t
end

----------------------------------------------------------------------
-- Pop-log popup (shared instance; retargeted per buff). Flat control-panel dress.
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
    scroll:SetClipsChildren(true); scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1); scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 28)))
    end)
    p._child = child; p._lines = {}
    Dashboard._popLog = p
    return p
end

local function showPopLog(logKey, titleText)
    local p = ensurePopLog()
    p.title:SetText(titleText)
    local child = p._child
    for _, l in ipairs(p._lines) do l:Hide() end
    local logs = (ns.Store.GetTimers().logs) or {}
    local list = logs[logKey] or {}
    local W = p:GetWidth() - 24
    child:SetWidth(W)
    local y = 0
    local now = Dashboard.Now()
    if #list == 0 then
        local l = p._lines[1] or fstr(child, "muted"); p._lines[1] = l
        l:ClearAllPoints(); l:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0); l:SetWidth(W)
        l:SetText("No pops recorded this reset."); l:Show()
        y = 20
    else
        for i = 1, math.min(#list, 50) do
            local ev = list[i]
            local l = p._lines[i]
            if not l then l = fstr(child, "body"); l:SetJustifyH("LEFT"); l:SetWordWrap(false); p._lines[i] = l end
            l:ClearAllPoints(); l:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y); l:SetWidth(W)
            local tag2 = ev.killed and Dashboard.Colored("NPC Killed", "danger")
                or (ev.quest and Dashboard.Colored("Quest", "ok") or Dashboard.Colored("Pop", "muted"))
            local when = date("%m/%d %H:%M", ev.epoch or now)
            local ago = Dashboard.FormatDuration(now - (ev.epoch or now))
            l:SetText(("%s  %s  %s  (%s ago)"):format(when, tag2, ev.who or "?", ago))
            l:Show()
            y = y + 18
        end
    end
    child:SetHeight(math.max(y, 1))
    p:Show()
end

----------------------------------------------------------------------
-- Build the dock into `parent` (the tagged dock.pane host from ui_cards).
-- Returns a controller with :Refresh() and .frame; runs its own 1s ticker.
----------------------------------------------------------------------
function TimersDock.Attach(parent)
    local D = { _wbRows = {}, _sfCells = {} }
    D.frame = parent

    -- ── World-buff timers section ────────────────────────────────────────────
    local wbHdr = microLabel(parent, "WORLD BUFF TIMERS")
    wbHdr:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_H, -PAD_V)
    local wbMeta = fstr(parent, "microLabel", "RIGHT")
    wbMeta:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_H, -PAD_V)
    wbMeta:SetTextColor(UI.Color("muted"))   -- pop pass
    D.wbMeta = wbMeta

    -- Rows container (tagged so the geometry checker can target the WB rows block).
    local wbRows = CreateFrame("Frame", nil, parent)
    wbRows:SetPoint("TOPLEFT", wbHdr, "BOTTOMLEFT", 0, -6)
    wbRows:SetPoint("RIGHT", parent, "RIGHT", -PAD_H, 0)
    wbRows:SetHeight(#WB_ROWS * WB_ROW_H)
    tag(wbRows, "dock.wbrows")
    D.wbRows = wbRows

    local prev
    for i, def in ipairs(WB_ROWS) do
        local r = CreateFrame("Frame", nil, wbRows)
        r:SetHeight(WB_ROW_H)
        if prev then
            r:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 0)
            r:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, 0)
        else
            r:SetPoint("TOPLEFT", wbRows, "TOPLEFT", 0, 0)
            r:SetPoint("TOPRIGHT", wbRows, "TOPRIGHT", 0, 0)
        end
        r._def = def
        r.tile = makeIconTile(r, WB_TILE); r.tile:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.tile.icon:SetTexture(Dashboard.AuraIcon(def.slot))
        r.name = fstr(r, "body"); r.name:SetPoint("LEFT", r.tile, "RIGHT", 8, 0); r.name:SetText(def.label)
        r.name:SetTextColor(UI.Color("text"))   -- pop pass: full text white
        if def.crest then
            r.crest = r:CreateTexture(nil, "ARTWORK")
            r.crest:SetSize(14, 14); r.crest:SetPoint("LEFT", r.name, "RIGHT", 5, 0)
            r.crest:SetTexture(Dashboard.FactionCrest(def.crest))
            r.crest:SetTexCoord(0.02, 0.62, 0.03, 0.63)
        end
        r.log = UI.MakeButton(r, { text = "Log", variant = "quiet", width = 40, height = 18,
            onClick = function() showPopLog(def.logKey, (def.title or def.label) .. " — Pop Log") end })
        r.log:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.stamp = fstr(r, "microLabel", "RIGHT"); r.stamp:SetPoint("RIGHT", r.log, "LEFT", -8, 0)
        r.stamp:SetTextColor(UI.Color("muted"))   -- pop pass (off-CD stamp is secondary)
        r.status = fstr(r, "numeral", "RIGHT"); r.status:SetPoint("RIGHT", r.stamp, "LEFT", -10, 0)
        -- One hairline per row (sharp control-panel rule). Pop pass: borderLite.
        r.rule = UI.Hairline(r, { token = "borderLite" })
        r.rule:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
        r.rule:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
        D._wbRows[i] = r
        prev = r
    end

    -- ── Songflowers section (compact 2×5 mini grid) ──────────────────────────
    local sfHdr = microLabel(parent, "SONGFLOWERS \194\183 FELWOOD")
    sfHdr:SetPoint("TOPLEFT", wbRows, "BOTTOMLEFT", 0, -10)
    local sfMeta = fstr(parent, "microLabel", "RIGHT")
    sfMeta:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_H, 0)
    -- keep the meta baseline aligned with the SF header.
    sfMeta:SetPoint("TOP", sfHdr, "TOP", 0, 0)
    sfMeta:SetTextColor(UI.Color("muted"))   -- pop pass
    D.sfMeta = sfMeta

    local sfGrid = CreateFrame("Frame", nil, parent)
    sfGrid:SetPoint("TOPLEFT", sfHdr, "BOTTOMLEFT", 0, -6)
    sfGrid:SetPoint("RIGHT", parent, "RIGHT", -PAD_H, 0)
    sfGrid:SetHeight(2 * SF_CELL_H + SF_GAP)
    tag(sfGrid, "dock.songflowers")
    D.sfGrid = sfGrid

    local nodes = (ns.Timers and ns.Timers.NODES and ns.Timers.NODES.flower) or {}
    for i = 1, #nodes do
        local cell = CreateFrame("Frame", nil, sfGrid, "BackdropTemplate")
        cell:SetHeight(SF_CELL_H)
        UI.Skin(cell, function(self)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("inset"))
            self:SetBackdropBorderColor(UI.Color("borderLite"))   -- pop pass
        end)
        -- Two-line cell (fills the taller round-4 cell): "N Label" on top, status below.
        cell.nm = fstr(cell, "microLabel"); cell.nm:SetPoint("TOPLEFT", cell, "TOPLEFT", 6, -5)
        cell.nm:SetWordWrap(false); cell.nm:SetTextColor(UI.Color("muted"))   -- pop pass
        cell.nm:SetText(("%d %s"):format(i, nodes[i].label or ("Node " .. i)))
        cell.st = fstr(cell, "numeral"); cell.st:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT", 6, 6)
        cell._nodeKey = "flower" .. i
        D._sfCells[i] = cell
    end

    local function layoutGrid()
        local areaW = sfGrid:GetWidth()
        if areaW <= 0 then return end
        for i, cell in ipairs(D._sfCells) do
            local g = Dashboard.TimersGridCell(i, SF_COLS, areaW, SF_GAP, SF_CELL_H)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", sfGrid, "TOPLEFT", g.x, g.y)
            cell:SetWidth(g.w)
            cell.nm:SetWidth(g.w - 10)   -- name on its own top line (2-line cell)
        end
    end
    D._layoutGrid = layoutGrid

    -- ── Bottom-right ICON PAIR (owner round-10 item 1): Broadcast + Refresh ──────
    -- Icon buttons (glyph + tooltip) in the dock's bottom-right corner. Refresh (right)
    -- pulls fresh timer data via the existing request path; Broadcast (left) pushes our
    -- snapshot to the mesh (60s throttle). The old text Broadcast button is removed.
    local function iconButton(iconTex, tip, onClick)
        local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
        b:SetSize(22, 22)
        UI.Skin(b, function(self)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("inset"))
            self:SetBackdropBorderColor(UI.Color("borderLite"))
        end)
        local ic = b:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2); ic:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
        ic:SetTexCoord(0.1, 0.9, 0.1, 0.9); ic:SetTexture(iconTex)
        b.icon = ic
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:AddLine(tip, UI.Color("text")); GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", onClick)
        return b
    end
    -- Refresh (circular-arrows / time glyph) — pull fresh timer data.
    local refreshBtn = iconButton("Interface\\Icons\\Spell_Nature_TimeStop", "Refresh timer data", function()
        if ns.Timers and ns.Timers.RequestTimerData then
            ns:SafeCall(ns.Timers.RequestTimerData); ns:Print("requesting timer data from the mesh...")
        else
            ns:Print("timer-data request arrives in a later update.")
        end
    end)
    refreshBtn:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD_H, PAD_V)
    -- Broadcast (signal/horn glyph) — push our snapshot to the mesh (60s throttle).
    local bcast = iconButton("Interface\\Icons\\INV_Misc_Horn_02", "Broadcast timers to the mesh (60s)", function()
        local t = GetTime()
        if D._lastBcast and (t - D._lastBcast) < 60 then ns:Print("broadcast throttled (60s)."); return end
        if ns.Mesh and ns.Mesh.BroadcastTimers and ns.Timers then
            ns:SafeCall(ns.Mesh.BroadcastTimers, ns.Timers.GetSnapshot())
            D._lastBcast = t; ns:Print("timers broadcast to guild/mesh.")
        else
            ns:Print("mesh broadcast arrives in a later update.")
        end
    end)
    bcast:SetPoint("RIGHT", refreshBtn, "LEFT", -6, 0)
    D.bcast, D.refresh = bcast, refreshBtn

    -- ── Refresh ──────────────────────────────────────────────────────────────
    function D.Refresh()
        local T = ns.Timers
        local now = Dashboard.Now()
        -- WB meta: realm · faction · live.
        local realm = (GetRealmName and GetRealmName()) or "?"
        wbMeta:SetText(("%s \194\183 %s \194\183 live"):format(realm, Dashboard.GetFaction()))

        for _, r in ipairs(D._wbRows) do
            local def = r._def
            local state = T and T.state and T.state[def.key]
            local anchor = anchorOf(state)
            local info = T and T.ComputeCD and T.ComputeCD(def.key, anchor, now)
            if not info or anchor <= 0 then
                r.status:SetText("No data"); r.status:SetTextColor(UI.Color("faint"))
                r.status._pulse = false; r.stamp:SetText("")
            elseif info.ready then
                r.status:SetText("Open"); r.status:SetTextColor(UI.Color("ok"))
                r.status._pulse = false; r.stamp:SetText("")
            else
                local rem = info.remaining or 0
                local killed = state.lastKilled and state.lastKilled >= (state.lastPop or 0)
                r.status:SetText((killed and "Killed \194\183 " or "") .. Dashboard.FormatDuration(rem))
                if rem <= SF_IMMINENT then
                    r.status:SetTextColor(UI.Color("danger")); r.status._pulse = true
                else
                    r.status:SetTextColor(UI.Color("warn")); r.status._pulse = false
                end
                r.stamp:SetText("off CD " .. date("%H:%M", info.nextAt))
                r.stamp:SetTextColor(UI.Color("faint"))
            end
        end

        local nUp, nDown, nUnknown = 0, 0, 0
        for _, cell in ipairs(D._sfCells) do
            local st = T and T.GetNodeState and T.GetNodeState(cell._nodeKey)
            local heroText, heroTok = Dashboard.SongflowerCellContent(st)
            if st and st.state == "up" then heroText = "Up" end
            cell.st:SetText(heroText); cell.st:SetTextColor(UI.Color(heroTok))
            if not st or st.state == "unknown" then nUnknown = nUnknown + 1
            elseif st.state == "down" then nDown = nDown + 1
            else nUp = nUp + 1 end
        end
        sfMeta:SetText(("%d up \194\183 %d respawning \194\183 %d unknown"):format(nUp, nDown, nUnknown))
    end

    -- ── 1s ticker + imminent-CD brighten pulse (pauses when hidden) ──────────
    local accum = 0
    parent:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsVisible() then return end
        accum = accum + elapsed
        local dr, dg, db = UI.Color("danger")
        local t = 0.4 * math.abs(math.sin(GetTime() * 3))
        for _, r in ipairs(D._wbRows) do
            r.status:SetAlpha(1)
            if r.status._pulse then r.status:SetTextColor(brighten(dr, dg, db, t)) end
        end
        if accum >= 1 then accum = 0; ns:SafeCall(D.Refresh) end
    end)
    parent:SetScript("OnSizeChanged", function() layoutGrid(); D.Refresh() end)
    layoutGrid()
    D.Refresh()
    return D
end

-- ════════════════════════════════════════════════════════════════════════════
--  SELF-TEST  (suite "timersui"): the pure songflower-grid math + cell-content
--  matrix, re-housed verbatim. Runs headless (no frames).
-- ════════════════════════════════════════════════════════════════════════════

local function testGridLayout(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local areaW, cols, gap, cellH = 400, 5, 6, 50
    local expW = (areaW - (cols - 1) * gap) / cols
    for i = 1, 5 do
        local g = Dashboard.TimersGridCell(i, cols, areaW, gap, cellH)
        ck(g.row == 0, "index " .. i .. " on row 0")
        ck(g.col == i - 1, "index " .. i .. " col == " .. (i - 1))
        ck(math.abs(g.w - expW) < 1e-9, "index " .. i .. " width == " .. expW)
        ck(math.abs(g.x - (i - 1) * (expW + gap)) < 1e-9, "index " .. i .. " x offset")
        ck(g.y == 0, "row-0 cells sit at y == 0")
    end
    local g6 = Dashboard.TimersGridCell(6, cols, areaW, gap, cellH)
    ck(g6.col == 0 and g6.row == 1, "index 6 wraps to col 0 / row 1")
    ck(g6.x == 0, "index 6 x resets to 0 on the new row")
    ck(g6.y == -(cellH + gap), "index 6 drops one row (y == -(cellH+gap))")
    local g10 = Dashboard.TimersGridCell(10, cols, areaW, gap, cellH)
    ck(g10.col == 4 and g10.row == 1, "index 10 is col 4 / row 1 (grid corner)")
    local gr = Dashboard.TimersGridCell(6, cols, areaW, gap, cellH, 20)
    ck(gr.y == -(cellH + 20), "custom rowGap applied to y")
end

local function testCellContent(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local EMDASH = "\226\128\148"
    ck(Dashboard.ShortDur(12) == "12s", "ShortDur seconds -> '12s'")
    ck(Dashboard.ShortDur(0)  == "0s",  "ShortDur zero -> '0s'")
    ck(Dashboard.ShortDur(59) == "59s", "ShortDur 59 -> '59s'")
    ck(Dashboard.ShortDur(60) == "1m",  "ShortDur 60 -> '1m'")
    ck(Dashboard.ShortDur(18 * 60) == "18m", "ShortDur 1080 -> '18m'")
    ck(Dashboard.ShortDur(2 * 3600) == "2h", "ShortDur 7200 -> '2h'")
    local t, c, cap = Dashboard.SongflowerCellContent(nil)
    ck(t == EMDASH and c == "faint" and cap == "faint", "no state -> em-dash / faint / faint")
    t, c = Dashboard.SongflowerCellContent({ state = "unknown" })
    ck(t == EMDASH and c == "faint", "unknown -> em-dash / faint")
    t, c, cap = Dashboard.SongflowerCellContent({ state = "down", remaining = 18 * 60 })
    ck(t == "18m" and c == "text" and cap == "muted", "down >60s -> '18m' / cream / muted")
    t, c = Dashboard.SongflowerCellContent({ state = "down", remaining = 45 })
    ck(t == "45s" and c == "warn", "down <60s -> '45s' / warn (amber)")
    ck(select(2, Dashboard.SongflowerCellContent({ state = "down", remaining = 60 })) == "text", "60s boundary is cream")
    ck(select(2, Dashboard.SongflowerCellContent({ state = "down", remaining = 59 })) == "warn", "59s is amber")
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
