-- Daseeki Nexus — ui_tab_summoners.lua
-- The "Summoners" tab (spec §5): a single-panel, click-sortable 6-column table
-- of the faction's warlock summoners (shards >= 20), with alternating row
-- shading and a per-row location-override popup. Column headers are always
-- present (style guide: every column labeled); default sort is Shards ascending.

local ADDON, ns = ...
local UI = DaseekiUI
local Dashboard = ns.Dashboard

local ROW_H     = 22
local HEADER_H  = 24
local SHARD_MIN = 20   -- warlocks with at least this many shards are "summoners"

-- Fixed column widths (Location flexes to fill). Grid discipline.
local COLS = {
    { key = "name",     label = "Name",     w = 130, just = "LEFT"  },
    { key = "account",  label = "Acct",     w = 46,  just = "CENTER"},
    { key = "shards",   label = "Shards",   w = 58,  just = "CENTER"},
    { key = "class",    label = "Class",    w = 78,  just = "LEFT"  },
    { key = "location", label = "Location", w = 0,   just = "LEFT", flex = true },
    { key = "status",   label = "Status",   w = 62,  just = "CENTER"},
    { key = "edit",     label = "",         w = 26,  just = "CENTER"},
}

local function fstr(parent, key)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    return f
end

----------------------------------------------------------------------
-- Location-override popup (single shared instance, anchored per row).
----------------------------------------------------------------------

local function ensureLocPopup()
    if Dashboard._summonLocPopup then return Dashboard._summonLocPopup end
    local p = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    p:SetFrameStrata("DIALOG")
    p:SetSize(240, 40)
    p:Hide()
    UI.Skin(p, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("panel"))
        self:SetBackdropBorderColor(UI.Color("accent"))
    end)
    local box = CreateFrame("EditBox", nil, p, "BackdropTemplate")
    box:SetPoint("LEFT", p, "LEFT", 8, 0)
    box:SetSize(160, 22); box:SetAutoFocus(true)
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
            ns.Store.SetManualLocation(p._nameRealm, (t ~= "" and t) or nil)
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
    Dashboard._summonLocPopup = p
    return p
end

local function openLocPopup(anchor, nameRealm, onDone)
    local p = ensureLocPopup()
    p._nameRealm = nameRealm
    p._onDone = onDone
    p.box:SetText(ns.Store.GetManualLocation(nameRealm) or "")
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
        if col.key ~= "edit" then
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
        local flexW = math.max(80, totalW - fixed - (#COLS - 1) * 6)
        local x = 0
        local geom = {}
        for i, c in ipairs(COLS) do
            local w = c.flex and flexW or c.w
            geom[i] = { x = x, w = w }
            x = x + w + 6
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
            elseif key == "account" then return tonumber(e.aid) or 999
            elseif key == "shards" then return rec.shardCount or 0
            elseif key == "class" then return (rec.className or ""):lower()
            elseif key == "location" then return (rec.location or ""):lower()
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
            local cells = {
                Dashboard.ColoredName(e.nameRealm, rec.classTag),
                (e.aid ~= "" and e.aid) or "-",
                tostring(rec.shardCount or 0),
                rec.className or "?",
                rec.location or Dashboard.Colored("Missing","danger"),
                e.online and Dashboard.Colored("Online","ok") or Dashboard.Colored("Offline","faint"),
            }
            for c = 1, #COLS - 1 do
                local fsc = r.cells[c]
                fsc:ClearAllPoints()
                fsc:SetPoint("LEFT", r, "LEFT", geom[c].x + 2, 0)
                fsc:SetWidth(geom[c].w)
                fsc:SetJustifyH(COLS[c].just)
                fsc:SetWordWrap(false)
                fsc:SetText(cells[c])
            end
            -- Edit button.
            r.edit:ClearAllPoints()
            r.edit:SetPoint("LEFT", r, "LEFT", geom[#COLS].x, 0)
            r.edit._nameRealm = e.nameRealm
            r.edit:SetScript("OnClick", function(self)
                openLocPopup(self, self._nameRealm, obj.Refresh)
            end)
            r:Show()
        end
        child:SetHeight(math.max(#rows * ROW_H, 1))
    end

    scroll:SetScript("OnSizeChanged", function() obj.Refresh() end)
    header:SetScript("OnSizeChanged", function() obj.Refresh() end)

    return obj
end)
