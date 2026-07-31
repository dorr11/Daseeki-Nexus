-- Daseeki Nexus — ui_timersdock.lua
-- The RIGHT-BOTTOM "timers dock" of the control-panel dashboard.
--
-- NEXUS DIRECTION PIVOT (BRAND_SPEC 2026-07-29): the Timers TAB DISSOLVES — its
-- content docks here, in the lower-right pane region of the Characters screen. This
-- file re-houses the proven timer logic from the retired ui_tab_timers.lua: the
-- world-buff cooldown rows (icon tile · name+crest · green "Open" / outlined
-- countdown, whose HOVER names the off-CD clock time · Log link + pop-log popup —
-- round-16b retired the inline off-CD stamp), the songflower strip (a
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

-- Countdown numerals as M:SS. Pure. Dashboard.FormatDuration bottoms out at whole
-- minutes, which is far too coarse for the 360s announcer respawn — that row needs
-- a ticking seconds digit. Same shape as InstancesUI.FormatMSS.
function Dashboard.FormatMSS(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
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

-- Map a Timers.BuffStatus readout ({ state, remaining, nextAt }) to world-buff row
-- content. Returns (statusText, statusToken, pulse, tipText). Pure, so the
-- "timersui" suite drives the whole four-state matrix headless.
--   nodata : nothing observed yet
--   canpop : off cooldown / respawn elapsed — BRAND_SPEC §6 green "Open"
--   killed : the announcer died and is respawning. INFORMATIONAL, not a closing
--            window, so it reads warn and never pulses.
--   cd     : on cooldown — danger + brighten pulse once inside SF_IMMINENT.
-- ROUND-16b (owner): the 4th return was the INLINE "off CD 14:58" stamp micro-label that
-- sat between the countdown and the Log button. The stamp is deleted from the row; this
-- string is now the HOVER TOOLTIP line for the countdown numeral, so the clock time is
-- on demand instead of permanently occupying a column. Plain copy ("Off cooldown at
-- 14:58"). The two states that show no countdown (Open / No data) return "" — the numeral
-- already says everything, so a tooltip there would only repeat it.
function Dashboard.WBRowContent(st, imminent)
    imminent = imminent or SF_IMMINENT
    local state = st and st.state
    if state == "canpop" then
        return "Open", "ok", false, ""
    elseif state == "killed" then
        return "Killed \194\183 " .. Dashboard.FormatMSS(st.remaining), "warn", false,
               "Respawns at " .. date("%H:%M", st.nextAt)
    elseif state == "cd" then
        local rem = st.remaining or 0
        local imm = (rem <= imminent)
        return Dashboard.FormatDuration(rem), imm and "danger" or "warn", imm,
               "Off cooldown at " .. date("%H:%M", st.nextAt)
    end
    return "No data", "faint", false, ""
end

-- Round-16c: the songflower cell's HOVER state line. The grid cells are ~63px wide, so
-- long node names ("North of Emerald Sanctuary") can never fit the caption and always
-- ellipsize — the hover is where the full name and state are actually readable. Returns
-- the state sentence + its theme token. Pure, so the timersui suite covers it headless.
function Dashboard.SongflowerTipState(st)
    local state = st and st.state
    if state == "up" then return "Up", "ok" end
    if state == "down" then
        return "Respawning \226\128\148 " .. Dashboard.ShortDur(st.remaining), "warn"
    end
    return "No data", "faint"
end

-- ── DMF readout ink + copy (round-16b addendum) ──────────────────────────────
-- The bottom-left Darkmoon readout drops its "Darkmoon:" word prefix in favour of the
-- DMF BUFF ICON, and the remaining caption reads in the buff's own family hue (arcane
-- violet) so it matches the detail pane's buff-name language.
--
-- TECH DEBT: the caption string is built by ui_shell's Dashboard.FormatDMFCaption, which
-- still bakes in the "Darkmoon: " prefix. ui_shell is owned by the roster-dedup sibling
-- this round, so the prefix is stripped DOCK-SIDE here. Fold this into FormatDMFCaption
-- as a style option (e.g. `prefix=false`) when ui_shell is free again.
local DMF_PREFIX = "Darkmoon: "
function Dashboard.StripDMFPrefix(s)
    if type(s) ~= "string" then return "" end
    if s:sub(1, #DMF_PREFIX) == DMF_PREFIX then return s:sub(#DMF_PREFIX + 1) end
    return s
end

-- Mirrors ui_detail's BUFF_HUE.dmf + its lift/contrast-guard treatment (that table is a
-- file-local there, so the constant is duplicated rather than reached into).
local DMF_HUE = { 0.612, 0.420, 0.984 }   -- Sayge's fortune — arcane violet
local DMF_LIFT, DMF_MIN_CONTRAST = 0.14, 0.20
local function relLum(r, g, b) return 0.2126 * r + 0.7152 * g + 0.0722 * b end
-- Returns r, g, b, fellBack — the lifted violet, or the supplied fallback (the theme's
-- text colour) when the hue is too close to this theme's ground to stay readable.
function Dashboard.DMFInk(groundR, groundG, groundB, fbR, fbG, fbB)
    local hr = DMF_HUE[1] + (1 - DMF_HUE[1]) * DMF_LIFT
    local hg = DMF_HUE[2] + (1 - DMF_HUE[2]) * DMF_LIFT
    local hb = DMF_HUE[3] + (1 - DMF_HUE[3]) * DMF_LIFT
    local dl = math.abs(relLum(hr, hg, hb) - relLum(groundR or 0, groundG or 0, groundB or 0))
    if dl < DMF_MIN_CONTRAST then return fbR, fbG, fbB, true end
    return hr, hg, hb, false
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
        -- ROUND-16b (owner): the inline "off CD 14:58" stamp is GONE. The countdown now
        -- sits directly beside the Log button — the whole stamp column is reclaimed, so
        -- the name/status side of the row gains that width — and the clock time moved to
        -- a hover tooltip on the countdown itself.
        r.status = fstr(r, "numeral", "RIGHT"); r.status:SetPoint("RIGHT", r.log, "LEFT", -8, 0)
        -- A FontString cannot take mouse input, so a thin hit frame tracks the numeral's
        -- text extents (it re-anchors automatically as the countdown's width changes).
        -- It sits left of the Log button and never overlaps it, so the Log click and any
        -- row-level hover are untouched.
        local hit = CreateFrame("Frame", nil, r)
        hit:SetPoint("TOPLEFT", r.status, "TOPLEFT", -4, 2)
        hit:SetPoint("BOTTOMRIGHT", r.status, "BOTTOMRIGHT", 4, -2)
        hit:EnableMouse(true)
        hit:SetScript("OnEnter", function()
            if not r._tipText or r._tipText == "" then return end   -- Open / No data: nothing to add
            GameTooltip:SetOwner(hit, "ANCHOR_RIGHT")
            GameTooltip:AddLine(def.title or def.label, UI.Color("text"))
            GameTooltip:AddLine(r._tipText, UI.Color("muted"))
            GameTooltip:Show()
        end)
        hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.statusHit = hit
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
        -- Two-line cell (fills the taller round-4 cell): node name on top, status below.
        cell.nm = fstr(cell, "microLabel"); cell.nm:SetPoint("TOPLEFT", cell, "TOPLEFT", 6, -5)
        cell.nm:SetWordWrap(false); cell.nm:SetTextColor(UI.Color("muted"))   -- pop pass
        -- Round-16b addendum 2 (owner: "the names are getting cut off"): the numeric
        -- prefix is dropped so the full node name gets the cell width. Node indices are
        -- unaffected everywhere else (pop log / slash output still name them by number).
        cell.nm:SetText(nodes[i].label or ("Node " .. i))
        cell.st = fstr(cell, "numeral"); cell.st:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT", 6, 6)
        cell._nodeKey = "flower" .. i
        -- Round-16c: hover reveals the FULL node name + live state. The caption above is
        -- width-capped (~53px) so long names always ellipsize; this is where they read.
        cell._label = nodes[i].label or ("Node " .. i)
        cell:EnableMouse(true)
        cell:SetScript("OnEnter", function(self)
            local st = ns.Timers and ns.Timers.GetNodeState and ns.Timers.GetNodeState(self._nodeKey)
            local line, tok = Dashboard.SongflowerTipState(st)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self._label, UI.Color("text"))
            GameTooltip:AddLine(line, UI.Color(tok))
            GameTooltip:Show()
        end)
        cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
    -- Round-16c: the two dock buttons now carry OUR OWN glyph masks (textures/icon-*.tga,
    -- white-on-transparent) instead of borrowed game icons, so they tint with theme tokens
    -- like every other control: `muted` at rest, `accent` on hover. The glyphs are authored
    -- with their own margin, so no TexCoord crop (the old 0.1-0.9 trim existed only to cut
    -- a game icon's baked-in border). Size/tooltips/behavior are unchanged.
    local function iconButton(iconTex, tip, onClick)
        local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
        b:SetSize(22, 22)
        local ic = b:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2); ic:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
        ic:SetTexture(iconTex)
        b.icon = ic
        UI.Skin(b, function(self)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("inset"))
            self:SetBackdropBorderColor(UI.Color("borderLite"))
            -- re-tint on ThemeChanged, honouring whichever state the cursor left us in
            self.icon:SetVertexColor(UI.Color(self._hot and "accent" or "muted"))
        end)
        b:SetScript("OnEnter", function(self)
            self._hot = true
            self.icon:SetVertexColor(UI.Color("accent"))
            GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:AddLine(tip, UI.Color("text")); GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self)
            self._hot = nil
            self.icon:SetVertexColor(UI.Color("muted"))
            GameTooltip:Hide()
        end)
        b:SetScript("OnClick", onClick)
        return b
    end
    -- Refresh (circular-arrows / time glyph) — pull fresh timer data.
    local refreshBtn = iconButton("Interface\\AddOns\\Daseeki-Nexus\\textures\\icon-refresh", "Refresh timer data", function()
        if ns.Timers and ns.Timers.RequestTimerData then
            ns:SafeCall(ns.Timers.RequestTimerData); ns:Print("requesting timer data from the mesh...")
        else
            ns:Print("timer-data request arrives in a later update.")
        end
    end)
    refreshBtn:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD_H, PAD_V)
    -- Broadcast (signal/horn glyph) — push our snapshot to the mesh (60s throttle).
    local bcast = iconButton("Interface\\AddOns\\Daseeki-Nexus\\textures\\icon-broadcast", "Broadcast timers to the mesh (60s)", function()
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

    -- ── Darkmoon Faire schedule readout (round-12 restore #1) ───────────────────
    -- The computed DMF estimate (Dashboard.GetDMFSchedule) had lived only in the now-
    -- removed status bar. Home it bottom-left of the dock, sharing the footer baseline
    -- with the Broadcast/Refresh icons. Hover reveals zone + start/end. Estimate only
    -- (Classic Era exposes no faire-schedule API).
    local dmfHost = CreateFrame("Frame", nil, parent)
    dmfHost:SetHeight(20)
    dmfHost:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", PAD_H, PAD_V + 1)
    dmfHost:SetPoint("RIGHT", bcast, "LEFT", -10, 0)
    dmfHost:EnableMouse(true)
    -- Round-16b addendum: the "Darkmoon:" word prefix is replaced by the DMF BUFF ICON
    -- (Sayge's Dark Fortune, aura slot 5) in the dock's standard inset-framed tile
    -- treatment, sized to the 20px readout host.
    local dmfTile = makeIconTile(dmfHost, 16)
    dmfTile:SetPoint("LEFT", dmfHost, "LEFT", 0, 0)
    dmfTile.icon:SetTexture(Dashboard.AuraIcon(5))
    D.dmfTile = dmfTile
    local dmfFS = fstr(dmfHost, "small"); dmfFS:SetPoint("LEFT", dmfTile, "RIGHT", 6, 0)
    dmfFS:SetJustifyH("LEFT"); dmfFS:SetWordWrap(false)
    dmfHost:SetScript("OnEnter", function(self)
        local sc = Dashboard.GetDMFSchedule and Dashboard.GetDMFSchedule()
        if not sc then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Darkmoon Faire" .. (sc.estimated and " (estimated)" or ""), UI.Color("text"))
        GameTooltip:AddLine("Zone: " .. (sc.zone or "?"), UI.Color("muted"))
        if sc.startEpoch then GameTooltip:AddDoubleLine("Start", date("%b %d %H:%M", sc.startEpoch), UI.Color("muted"), 1, 1, 1) end
        if sc.endEpoch then GameTooltip:AddDoubleLine("End", date("%b %d %H:%M", sc.endEpoch), UI.Color("muted"), 1, 1, 1) end
        GameTooltip:Show()
    end)
    dmfHost:SetScript("OnLeave", function() GameTooltip:Hide() end)
    tag(dmfHost, "dock.dmf")
    D.dmf = dmfFS

    -- ── Refresh ──────────────────────────────────────────────────────────────
    function D.Refresh()
        local T = ns.Timers
        local now = Dashboard.Now()
        -- WB meta: realm · faction · live.
        local realm = (GetRealmName and GetRealmName()) or "?"
        wbMeta:SetText(("%s \194\183 %s \194\183 live"):format(realm, Dashboard.GetFaction()))
        -- Darkmoon Faire schedule readout (restore #1).
        if D.dmf and Dashboard.GetDMFSchedule and Dashboard.FormatDMFCaption then
            -- Round-16b: the icon carries the "Darkmoon" label, so the word prefix is
            -- stripped and the caption reads in the DMF family hue (violet), guarded for
            -- contrast against the active theme's ground.
            D.dmf:SetText(Dashboard.StripDMFPrefix(
                Dashboard.FormatDMFCaption(Dashboard.GetDMFSchedule(), now)))
            local gr, gg, gb = UI.Color("ground")
            local tr, tg, tb = UI.Color("text")
            -- NOTE: DMFInk returns a 4th value (fellBack). Bind r/g/b to locals — passing
            -- the call straight into SetTextColor would feed that boolean in as ALPHA
            -- (the multi-return trap that caused the round-4 crash).
            local ir, ig, ib = Dashboard.DMFInk(gr, gg, gb, tr, tg, tb)
            D.dmf:SetTextColor(ir, ig, ib)
        end

        for _, r in ipairs(D._wbRows) do
            local def = r._def
            -- Timers.BuffStatus is the single source of the row readout (it owns the
            -- kill-vs-pop precedence and the 360s respawn model). Soft-guarded like
            -- the old ComputeCD call so a partial engine load still renders.
            local st = T and T.BuffStatus and T.BuffStatus(def.key, now)
            local text, token, pulse, tip = Dashboard.WBRowContent(st)
            r.status:SetText(text); r.status:SetTextColor(UI.Color(token))
            r.status._pulse = pulse
            -- Round-16b: the clock time now rides the countdown's hover tooltip.
            r._tipText = tip
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
--  matrix (re-housed verbatim) plus the world-buff row matrix. Runs headless
--  (no frames).
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

-- Round-16c: the songflower cell hover state line (the full name lives beside it).
local function testSongflowerTip(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local line, tok = Dashboard.SongflowerTipState({ state = "up" })
    ck(line == "Up" and tok == "ok", "up -> 'Up' / ok")
    line, tok = Dashboard.SongflowerTipState({ state = "down", remaining = 13 * 60 })
    ck(line == "Respawning \226\128\148 13m" and tok == "warn", "down -> 'Respawning — 13m' / warn")
    line = Dashboard.SongflowerTipState({ state = "down", remaining = 45 })
    ck(line == "Respawning \226\128\148 45s", "down under a minute -> seconds")
    line, tok = Dashboard.SongflowerTipState({ state = "unknown" })
    ck(line == "No data" and tok == "faint", "unknown -> 'No data' / faint")
    line, tok = Dashboard.SongflowerTipState(nil)
    ck(line == "No data" and tok == "faint", "nil state -> 'No data' / faint (no error)")
end

-- Round-16b addendum: the DMF readout's caption prefix + family-hue ink. Pure.
local function testDMFReadout(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- The icon now carries the "Darkmoon" label, so the word prefix is stripped.
    ck(Dashboard.StripDMFPrefix("Darkmoon: Mulgore in 9d 10h (est.)") == "Mulgore in 9d 10h (est.)",
        "prefix stripped -> 'Mulgore in 9d 10h (est.)'")
    ck(Dashboard.StripDMFPrefix("Darkmoon: Elwynn Forest \194\183 up now, 2d left (est.)")
        == "Elwynn Forest \194\183 up now, 2d left (est.)", "active caption prefix stripped")
    -- Idempotent / defensive: an already-stripped or odd string passes through untouched.
    ck(Dashboard.StripDMFPrefix("Mulgore in 2d") == "Mulgore in 2d", "no prefix -> unchanged")
    ck(Dashboard.StripDMFPrefix("") == "", "empty -> empty")
    ck(Dashboard.StripDMFPrefix(nil) == "", "nil -> empty (no error)")
    -- Guard the em-dash no-schedule caption too (FormatDMFCaption's nil branch).
    ck(Dashboard.StripDMFPrefix("Darkmoon: \226\128\148") == "\226\128\148", "em-dash caption stripped")

    -- Ink: the lifted arcane violet on the dark Nexus ground, and the readable-contrast
    -- fallback when a theme's ground sits too close to that hue.
    local dark = { 0.086, 0.075, 0.059 }          -- ground-ish (dark themes)
    local r, g, b, fell = Dashboard.DMFInk(dark[1], dark[2], dark[3], 1, 1, 1)
    ck(fell == false, "violet clears the contrast guard on a dark ground")
    ck(r > 0.612 and b > 0.984, "hue is LIFTED toward white from the base violet (as detail rows do)")
    ck(b > r and b > g, "ink stays blue-dominant (violet, not grey)")
    -- A light ground close in luminance to the lifted violet must fall back to `text`.
    local r2, g2, b2, fell2 = Dashboard.DMFInk(0.62, 0.55, 0.90, 0.11, 0.11, 0.11)
    ck(fell2 == true, "low-contrast ground -> falls back")
    ck(r2 == 0.11 and g2 == 0.11 and b2 == 0.11, "fallback returns the supplied text colour")
    -- The 4th return exists precisely so callers do NOT feed it to SetTextColor as alpha.
    ck(select("#", Dashboard.DMFInk(dark[1], dark[2], dark[3], 1, 1, 1)) == 4,
        "DMFInk returns 4 values (r,g,b,fellBack) — bind r/g/b before SetTextColor")
end

-- M:SS formatting + the four-state world-buff row matrix (Timers.BuffStatus ->
-- text / token / pulse / tipText). Pure; no frames, no engine state.
local function testWBRow(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Dashboard.FormatMSS(0)    == "0:00", "FormatMSS 0 -> '0:00'")
    ck(Dashboard.FormatMSS(59)   == "0:59", "FormatMSS 59 -> '0:59'")
    ck(Dashboard.FormatMSS(60)   == "1:00", "FormatMSS 60 -> '1:00'")
    ck(Dashboard.FormatMSS(360)  == "6:00", "FormatMSS 360 (announcer respawn) -> '6:00'")
    ck(Dashboard.FormatMSS(95.7) == "1:35", "FormatMSS truncates fractional seconds")
    ck(Dashboard.FormatMSS(-5)   == "0:00", "FormatMSS clamps negatives to '0:00'")
    ck(Dashboard.FormatMSS(nil)  == "0:00", "FormatMSS nil -> '0:00'")

    local T0 = 1785000000

    -- nodata (and the soft-guard path where BuffStatus was unavailable).
    local txt, tok, pulse, stamp = Dashboard.WBRowContent(nil)
    ck(txt == "No data" and tok == "faint" and pulse == false and stamp == "",
       "nil status -> 'No data' / faint / no pulse / no tooltip")
    txt, tok, pulse, stamp = Dashboard.WBRowContent({ state = "nodata", remaining = 0, nextAt = 0 })
    ck(txt == "No data" and tok == "faint" and pulse == false and stamp == "",
       "nodata -> 'No data' / faint / no pulse / no tooltip")

    -- canpop: BRAND_SPEC §6 green "Open", exactly (no pop-phrasing, no suffix).
    txt, tok, pulse, stamp = Dashboard.WBRowContent({ state = "canpop", remaining = 0, nextAt = T0 })
    ck(txt == "Open" and tok == "ok" and pulse == false and stamp == "",
       "canpop -> exactly 'Open' / ok / no pulse / no tooltip")

    -- killed: live M:SS countdown, warn, NEVER pulses, stamp names the respawn clock.
    txt, tok, pulse, stamp = Dashboard.WBRowContent({ state = "killed", remaining = 125, nextAt = T0 })
    ck(txt == "Killed \194\183 2:05", "killed -> 'Killed \194\183 2:05' (M:SS resolution)")
    ck(tok == "warn", "killed reads warn")
    ck(pulse == false, "killed does NOT pulse (informational respawn)")
    ck(stamp == "Respawns at " .. date("%H:%M", T0), "killed tip -> 'Respawns at HH:MM'")
    txt = Dashboard.WBRowContent({ state = "killed", remaining = 359, nextAt = T0 })
    ck(txt == "Killed \194\183 5:59", "killed just after the kill -> '5:59'")

    -- cd: FormatDuration + the existing imminent rule (danger + pulse at/below).
    txt, tok, pulse, stamp = Dashboard.WBRowContent({ state = "cd", remaining = 3 * 3600, nextAt = T0 })
    ck(txt == Dashboard.FormatDuration(3 * 3600), "cd text is FormatDuration(remaining)")
    ck(tok == "warn" and pulse == false, "cd far out -> warn / no pulse")
    ck(stamp == "Off cooldown at " .. date("%H:%M", T0), "cd tip -> 'Off cooldown at HH:MM'")
    tok, pulse = select(2, Dashboard.WBRowContent({ state = "cd", remaining = SF_IMMINENT, nextAt = T0 }))
    ck(tok == "danger" and pulse == true, "cd AT SF_IMMINENT -> danger + pulse")
    tok, pulse = select(2, Dashboard.WBRowContent({ state = "cd", remaining = SF_IMMINENT - 1, nextAt = T0 }))
    ck(tok == "danger" and pulse == true, "cd below SF_IMMINENT -> danger + pulse")
    tok, pulse = select(2, Dashboard.WBRowContent({ state = "cd", remaining = SF_IMMINENT + 1, nextAt = T0 }))
    ck(tok == "warn" and pulse == false, "cd above SF_IMMINENT -> warn / no pulse")
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("timersui", function(verbose)
        local fails = {}
        local ok = pcall(function()
            testGridLayout(fails); testCellContent(fails); testWBRow(fails); testDMFReadout(fails)
            testSongflowerTip(fails)
        end)
        local passed = ok and #fails == 0
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS timersui/songflower grid layout + cell content + WB rows")
            elseif not ok then ns:Print("  FAIL timersui :: error in test")
            else for _, f in ipairs(fails) do ns:Print("  FAIL timersui :: " .. f) end end
        end
        return passed
    end)
end
