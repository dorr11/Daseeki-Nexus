-- Daseeki Nexus — ui_tab_summoners.lua
-- The "Summoners" tab (spec §5): a single-panel, click-sortable table of the
-- faction's warlock summoners (shards >= 20), with alternating row shading and
-- a per-row free-text Note editor popup. The Location column shows the
-- game-captured location only; a separate Notes column holds the user's note
-- (the old location-override concept is retired). Column headers are always
-- present (style guide: every column labeled); default sort is Shards ascending.

local ADDON, ns = ...
local UI = DaseekiUI
local Dashboard = ns.Dashboard

local ROW_H     = 22
local HEADER_H  = 24
local SHARD_MIN = 20   -- warlocks with at least this many shards are "summoners"
local COL_GAP   = 14   -- inter-column spacing (owner feedback: columns crowded left)
local SOULSHARD_ITEM = 6265   -- Soul Shard (its icon prefixes the Shards count)
local SOULSTONE_ICON = "Interface\\Icons\\Spell_Shadow_SoulGem"  -- soulstone availability pip

-- Fixed column widths (Location flexes to fill). Grid discipline: comfortable
-- widths so the columns distribute across the table instead of bunching left.
-- The trailing "Soulstone" column (parity item 6) is a non-sortable icon column
-- (marked `icon`): lit when a soulstone is available, greyed on CD/none/unknown.
local COLS = {
    { key = "name",      label = "Name",      w = 158, just = "LEFT"  },
    -- Level (secondary info): narrow 2-digit slot, centered to match the numeric
    -- rhythm of Account/Shards; value rendered muted, em-dash when 0/unknown.
    { key = "level",     label = "Lvl",       w = 40,  just = "CENTER"},
    { key = "account",   label = "Account",   w = 78,  just = "CENTER"},
    { key = "shards",    label = "Shards",    w = 84,  just = "CENTER"},
    { key = "class",     label = "Class",     w = 96,  just = "LEFT"  },
    { key = "location",  label = "Location",  w = 0,   just = "LEFT", flex = true },
    -- Notes (secondary info): user free-text, muted; long notes truncate with a
    -- trailing ellipsis (non-wrapping FontString) and show in full on hover.
    { key = "notes",     label = "Notes",     w = 110, just = "LEFT"  },
    { key = "status",    label = "Status",    w = 78,  just = "CENTER"},
    { key = "soulstone", label = "Soulstone", w = 76,  just = "CENTER", icon = true },
    { key = "edit",      label = "",          w = 30,  just = "CENTER"},
}

-- Indexes of columns whose cells are drawn/handled specially (computed so row
-- layout can place the soulstone icon and the note hover region).
local SOUL_COL_INDEX, NOTES_COL_INDEX
for i, c in ipairs(COLS) do
    if c.key == "soulstone" then SOUL_COL_INDEX = i end
    if c.key == "notes"     then NOTES_COL_INDEX = i end
end

-- Soulstone availability for a record (parity item 6, engine half not yet landed).
-- The tracker will write a warlock soulstone-ready flag into the character record;
-- accept any of the candidate field names so this lights up the moment the engine
-- ships, and return nil (= unknown / no data) until then. Returns true/false/nil.
local function soulstoneAvailable(rec)
    if not rec then return nil end
    local v = rec.soulstoneReady
    if v == nil then v = rec.soulstoneAvailable end
    if v == nil then v = rec.soulstone end
    return v
end

local function fstr(parent, key)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    return f
end

----------------------------------------------------------------------
-- Per-row Note editor popup (single shared instance, anchored per row).
-- Same popup mechanics as the retired location-override editor; writes the
-- character's free-text note via Store.SetNote / prefills via Store.GetNote.
----------------------------------------------------------------------

local function ensureNotePopup()
    if Dashboard._summonNotePopup then return Dashboard._summonNotePopup end
    local p = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    p:SetFrameStrata("DIALOG")
    p:SetSize(280, 40)
    p:Hide()
    UI.Skin(p, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("panel"))
        self:SetBackdropBorderColor(UI.Color("accent"))
    end)
    local box = CreateFrame("EditBox", nil, p, "BackdropTemplate")
    box:SetPoint("LEFT", p, "LEFT", 8, 0)
    box:SetSize(200, 22); box:SetAutoFocus(true)
    box:SetFontObject(UI.fonts.body); box:SetTextInsets(6, 6, 0, 0)
    UI.Skin(box, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    p.box = box
    local function commit()
        if p._nameRealm then
            local t = box:GetText()
            ns.Store.SetNote(p._nameRealm, (t ~= "" and t) or nil)
        end
        p:Hide()
        if p._onDone then p._onDone() end
    end
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEscapePressed", function() p:Hide() end)
    local done = UI.MakeButton(p, { text = "Done", width = 48, height = 22, onClick = commit })
    done:SetPoint("RIGHT", p, "RIGHT", -30, 0)
    local x = UI.MakeButton(p, { text = "X", variant = "quiet", width = 22, height = 22,
        onClick = function() p:Hide() end })
    x:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    -- Click-away closer.
    local closer = CreateFrame("Button", nil, UIParent)
    closer:SetFrameStrata("FULLSCREEN_DIALOG")
    closer:SetAllPoints(UIParent)
    closer:Hide()
    closer:SetScript("OnClick", function() p:Hide() end)
    p:SetScript("OnHide", function() closer:Hide() end)
    p._closer = closer
    Dashboard._summonNotePopup = p
    return p
end

local function openNotePopup(anchor, nameRealm, onDone)
    local p = ensureNotePopup()
    p._nameRealm = nameRealm
    p._onDone = onDone
    p.box:SetText(ns.Store.GetNote(nameRealm) or "")
    p:ClearAllPoints()
    p:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
    p._closer:Show()
    p:Show()
    p.box:SetFocus()
end

----------------------------------------------------------------------
-- Tab registration
----------------------------------------------------------------------

Dashboard.RegisterTab("summoners", function(host)
    local obj = {}
    local box = UI.FlatFrame(host, "inset", "border")
    box:SetAllPoints(host)

    local title = fstr(box, "accent")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -8)
    title:SetText("Summoners")

    -- Header row.
    local header = CreateFrame("Frame", nil, box)
    header:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -30)
    header:SetPoint("TOPRIGHT", box, "TOPRIGHT", -8, -30)
    header:SetHeight(HEADER_H)
    local hrule = box:CreateTexture(nil, "ARTWORK")
    hrule:SetHeight(1)
    hrule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    hrule:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    UI.Skin(hrule, function(self) self:SetColorTexture(UI.Color("borderLite")) end)

    -- Scroll body.
    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 8)
    scroll:SetClipsChildren(true)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 28)))
    end)

    -- Sort state (persisted).
    local st = Dashboard.UIState()
    st.summonerSortKey = st.summonerSortKey or "shards"
    st.summonerSortDir = st.summonerSortDir or "asc"

    -- Header buttons with sort arrows. Column x offsets computed on layout.
    local headerBtns = {}
    for i, col in ipairs(COLS) do
        local b = CreateFrame("Button", nil, header)
        b:SetHeight(HEADER_H)
        local lbl = fstr(b, "small")
        lbl:SetPoint("LEFT", b, "LEFT", 2, 0)
        lbl:SetText(col.label)
        b._label, b._col = lbl, col
        if col.key ~= "edit" and not col.icon then
            b:SetScript("OnClick", function()
                if st.summonerSortKey == col.key then
                    st.summonerSortDir = (st.summonerSortDir == "asc") and "desc" or "asc"
                else
                    st.summonerSortKey = col.key
                    st.summonerSortDir = "asc"
                end
                obj.Refresh()
            end)
            b:SetScript("OnEnter", function() lbl:SetFontObject(UI.fonts.accent) end)
            b:SetScript("OnLeave", function() lbl:SetFontObject(UI.fonts.small) end)
        end
        headerBtns[i] = b
    end

    obj._rows = {}
    local function getRow(i)
        local r = obj._rows[i]
        if not r then
            r = CreateFrame("Button", nil, child)
            r:SetHeight(ROW_H)
            r.bg = r:CreateTexture(nil, "BACKGROUND")
            r.bg:SetAllPoints()
            r.cells = {}
            for c = 1, #COLS - 1 do
                r.cells[c] = fstr(r, "body")
            end
            -- Soulstone availability icon + hover (parity item 6). Lit when a
            -- soulstone is available, greyed on cooldown / none / unknown.
            r.soulIcon = r:CreateTexture(nil, "ARTWORK")
            r.soulIcon:SetSize(16, 16)
            r.soulIcon:SetTexture(SOULSTONE_ICON)
            r.soulIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            r.soulIcon:Hide()
            r.soulHit = CreateFrame("Frame", nil, r)
            r.soulHit:EnableMouse(true)
            r.soulHit:Hide()
            r.soulHit:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine("Soulstone", UI.Color("text"))
                if self._avail == true then
                    GameTooltip:AddLine("Available", UI.Color("ok"))
                elseif self._avail == false then
                    GameTooltip:AddLine("On cooldown or not created", UI.Color("muted"))
                else
                    GameTooltip:AddLine("Status unknown \226\128\148 needs a data update", UI.Color("faint"))
                end
                GameTooltip:Show()
            end)
            r.soulHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
            -- Note hover region: reveals the full note (the cell truncates with an
            -- ellipsis). Shown only when the row carries a note.
            r.noteHit = CreateFrame("Frame", nil, r)
            r.noteHit:EnableMouse(true)
            r.noteHit:Hide()
            r.noteHit:SetScript("OnEnter", function(self)
                if not self._note then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine("Note", UI.Color("text"))
                local cr, cg, cb = UI.Color("muted")
                GameTooltip:AddLine(self._note, cr, cg, cb, true)   -- wrapText = true
                GameTooltip:Show()
            end)
            r.noteHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
            -- Edit button (last column).
            r.edit = UI.MakeButton(r, { text = "…", variant = "quiet", width = 22, height = 18 })
            obj._rows[i] = r
        end
        return r
    end

    -- Compute column x offsets + widths for a given total width.
    local function layoutColumns(totalW)
        local fixed = 0
        for _, c in ipairs(COLS) do if not c.flex then fixed = fixed + c.w end end
        local flexW = math.max(120, totalW - fixed - (#COLS - 1) * COL_GAP)
        local x = 0
        local geom = {}
        for i, c in ipairs(COLS) do
            local w = c.flex and flexW or c.w
            geom[i] = { x = x, w = w }
            x = x + w + COL_GAP
        end
        return geom
    end

    function obj.Refresh()
        local faction = Dashboard.GetFaction()
        -- Informational roster of the faction's warlocks (spec §5). Shard data
        -- is only known for online/self warlocks, so we list every warlock and
        -- let the Shards column + sort surface who is ready (>= 20).
        local rows = Dashboard.GatherRoster(faction, { warlockOnly = true, includeHomeless = true })
        -- Sort.
        local key, dir = st.summonerSortKey, st.summonerSortDir
        local function keyval(e)
            local rec = e.rec
            if key == "name" then return (e.nameRealm or ""):lower()
            elseif key == "level" then return rec.level or 0
            elseif key == "account" then return tonumber(e.aid) or 999
            elseif key == "shards" then return rec.shardCount or 0
            elseif key == "class" then return (rec.className or ""):lower()
            elseif key == "location" then return (rec.location or ""):lower()
            elseif key == "notes" then return (ns.Store.GetNote(e.nameRealm) or ""):lower()
            elseif key == "status" then return e.online and 1 or 0 end
            return 0
        end
        table.sort(rows, function(a, b)
            local ka, kb = keyval(a), keyval(b)
            if ka == kb then return (a.nameRealm or "") < (b.nameRealm or "") end
            if dir == "asc" then return ka < kb else return ka > kb end
        end)

        -- Layout columns.
        local totalW = header:GetWidth(); if totalW < 1 then totalW = host:GetWidth() - 16 end
        local geom = layoutColumns(totalW)
        for i, b in ipairs(headerBtns) do
            b:ClearAllPoints()
            b:SetPoint("LEFT", header, "LEFT", geom[i].x, 0)
            b:SetWidth(geom[i].w)
            local arrow = ""
            if st.summonerSortKey == b._col.key then
                arrow = (dir == "asc") and "  ^" or "  v"
            end
            b._label:SetText(b._col.label .. arrow)
        end
        child:SetWidth(totalW)

        for _, r in ipairs(obj._rows) do r:Hide() end
        local nowE = Dashboard.Now()
        for i, e in ipairs(rows) do
            local r = getRow(i)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -((i - 1) * ROW_H))
            r:SetWidth(totalW)
            r.bg:SetColorTexture(UI.Color((i % 2 == 0) and "raised" or "panel", 0.5))
            local rec = e.rec
            -- Shards cell: warlocks show the real Soul Shard item icon before the
            -- count (owner feedback); "-" for non-warlocks. Inline texture escape
            -- keeps it in one sortable FontString cell.
            local shardCell
            if rec.classTag == "WARLOCK" then
                local ic = Dashboard.ItemIcon(SOULSHARD_ITEM)
                shardCell = ("|T%s:13:13:0:0|t %d"):format(ic, rec.shardCount or 0)
            else
                shardCell = "-"
            end
            -- Level cell: muted 2-digit number; em-dash (faint) when 0/nil so an
            -- unknown level never reads as a real "0".
            local lvl = rec.level
            local levelCell = (lvl and lvl > 0)
                and Dashboard.Colored(lvl, "muted")
                or Dashboard.Colored("\226\128\148", "faint")
            -- Note cell: muted free-text; the non-wrapping FontString truncates a
            -- long note with a trailing ellipsis, full text on hover (noteHit).
            local note = ns.Store.GetNote(e.nameRealm)
            local noteCell = (note and note ~= "") and Dashboard.Colored(note, "muted") or ""
            local cells = {
                Dashboard.ColoredName(e.nameRealm, rec.classTag),
                levelCell,
                (e.aid ~= "" and e.aid) or "-",
                shardCell,
                rec.className or "?",
                rec.location or Dashboard.Colored("Missing","danger"),
                noteCell,
                e.online and Dashboard.Colored("Online","ok") or Dashboard.Colored("Offline","faint"),
            }
            for c = 1, #COLS - 1 do
                local fsc = r.cells[c]
                if COLS[c].icon then
                    fsc:Hide()   -- icon columns are drawn separately, not as text
                else
                    fsc:Show()
                    fsc:ClearAllPoints()
                    fsc:SetPoint("LEFT", r, "LEFT", geom[c].x + 2, 0)
                    fsc:SetWidth(geom[c].w)
                    fsc:SetJustifyH(COLS[c].just)
                    fsc:SetWordWrap(false)
                    fsc:SetText(cells[c])
                end
            end
            -- Soulstone availability pip (parity item 6): warlocks only. Lit when
            -- available, greyed/dim on cooldown, none, or unknown (engine field
            -- not yet written — nil-guarded, defaults to greyed "unknown").
            if SOUL_COL_INDEX and rec.classTag == "WARLOCK" then
                local avail = soulstoneAvailable(rec)
                local g = geom[SOUL_COL_INDEX]
                r.soulIcon:ClearAllPoints()
                r.soulIcon:SetPoint("LEFT", r, "LEFT", g.x + (g.w - 16) / 2, 0)
                r.soulIcon:SetDesaturated(avail ~= true)
                r.soulIcon:SetAlpha(avail == true and 1 or 0.4)
                r.soulIcon:Show()
                r.soulHit:ClearAllPoints()
                r.soulHit:SetPoint("LEFT", r, "LEFT", g.x, 0)
                r.soulHit:SetSize(g.w, ROW_H)
                r.soulHit._avail = avail
                r.soulHit:Show()
            else
                r.soulIcon:Hide()
                r.soulHit:Hide()
            end
            -- Note hover region (full-text tooltip): only when a note exists.
            if NOTES_COL_INDEX and note and note ~= "" then
                local g = geom[NOTES_COL_INDEX]
                r.noteHit:ClearAllPoints()
                r.noteHit:SetPoint("LEFT", r, "LEFT", g.x, 0)
                r.noteHit:SetSize(g.w, ROW_H)
                r.noteHit._note = note
                r.noteHit:Show()
            else
                r.noteHit._note = nil
                r.noteHit:Hide()
            end
            -- Edit button (opens the per-row Note editor).
            r.edit:ClearAllPoints()
            r.edit:SetPoint("LEFT", r, "LEFT", geom[#COLS].x, 0)
            r.edit._nameRealm = e.nameRealm
            r.edit:SetScript("OnClick", function(self)
                openNotePopup(self, self._nameRealm, obj.Refresh)
            end)
            r:Show()
        end
        child:SetHeight(math.max(#rows * ROW_H, 1))
    end

    scroll:SetScript("OnSizeChanged", function() obj.Refresh() end)
    header:SetScript("OnSizeChanged", function() obj.Refresh() end)

    return obj
end)
