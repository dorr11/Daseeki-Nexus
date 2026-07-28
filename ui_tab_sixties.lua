-- Daseeki Network — ui_tab_sixties.lua
-- The "60s" tab (spec §1): every level-60 character on the selected faction as
-- a rich card in a drag-reorderable left list, with the shared detail panel on
-- the right. Card + detail composition follows the DaseekiUI style guide:
-- fixed-width bands, labeled sub-rows, compact, no stretch.

local ADDON, ns = ...
local UI = DaseekiUI
local Dashboard = ns.Dashboard

local CARD_H = 96

-- 2-char raid codes (the code IS the label; colored green available / red locked).
local RAID_CODE = {
    Naxx = "Nx", AQ40 = "A4", BWL = "BW", MC = "MC", ZG = "ZG", AQ20 = "A2", Ony = "On",
}

local function fstr(parent, key)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    return f
end

----------------------------------------------------------------------
-- Card factory
----------------------------------------------------------------------

local function makeCard(parent)
    local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
    UI.Skin(card, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("raised"))
        self:SetBackdropBorderColor(UI.Color(self._selected and "accent" or "border"))
    end)
    local hover = card:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    UI.Skin(hover, function(self) self:SetColorTexture(UI.Color("accent", 0.10)) end)
    card:SetHighlightTexture(hover)

    local PADX = 8
    -- Line 1: pip + name + account, crest at the right.
    card.pip = card:CreateTexture(nil, "ARTWORK")
    card.pip:SetSize(8, 8)
    card.pip:SetPoint("TOPLEFT", card, "TOPLEFT", PADX, -10)

    card.name = fstr(card, "body")
    card.name:SetPoint("LEFT", card.pip, "RIGHT", 6, 0)
    card.name:SetJustifyH("LEFT")

    card.acct = fstr(card, "small")
    card.acct:SetPoint("LEFT", card.name, "RIGHT", 6, 0)

    card.crest = card:CreateTexture(nil, "ARTWORK")
    card.crest:SetSize(18, 18)
    card.crest:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PADX, -8)
    card.crest:SetTexCoord(0.02, 0.62, 0.03, 0.63)
    card.crest:Hide()

    -- Line 2: location.
    card.loc = fstr(card, "small")
    card.loc:SetPoint("TOPLEFT", card, "TOPLEFT", PADX, -30)
    card.loc:SetPoint("RIGHT", card, "RIGHT", -PADX, 0)
    card.loc:SetJustifyH("LEFT")
    card.loc:SetWordWrap(false)

    -- Line 3: raid codes (left) + freshness (right).
    card.raid = {}
    local prev
    for i, key in ipairs(Dashboard.RAID_DISPLAY) do
        local t = fstr(card, "small")
        if prev then t:SetPoint("LEFT", prev, "RIGHT", 5, 0)
        else t:SetPoint("TOPLEFT", card, "TOPLEFT", PADX, -46) end
        t._raidKey = key
        card.raid[i] = t
        prev = t
    end
    card.fresh = fstr(card, "small")
    card.fresh:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PADX, -46)
    card.fresh:SetJustifyH("RIGHT")

    -- Line 4: collapsing buff-icon strip (left) + chrono/hearth (right).
    card.buffSlots = {}
    for i = 1, 10 do
        local slot = CreateFrame("Frame", nil, card, "BackdropTemplate")
        slot:SetSize(18, 18)
        local ic = slot:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", slot, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        slot.icon = ic
        slot:Hide()
        card.buffSlots[i] = slot
    end

    -- Chrono + hearth at the right of line 4.
    card.hearth = card:CreateTexture(nil, "ARTWORK")
    card.hearth:SetSize(16, 16)
    card.hearth:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -PADX, 8)
    card.hearth:SetTexture("Interface\\Icons\\INV_Misc_Rune_01")
    card.hearth:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card.hearthCD = fstr(card, "small")
    card.hearthCD:SetPoint("BOTTOMRIGHT", card.hearth, "BOTTOMLEFT", -2, 2)
    card.hearthCD:SetJustifyH("RIGHT")

    card.chrono = CreateFrame("Frame", nil, card, "BackdropTemplate")
    card.chrono:SetSize(18, 18)
    card.chrono:SetPoint("RIGHT", card.hearthCD, "LEFT", -6, 0)
    local chIc = card.chrono:CreateTexture(nil, "ARTWORK")
    chIc:SetPoint("TOPLEFT", card.chrono, "TOPLEFT", 1, -1)
    chIc:SetPoint("BOTTOMRIGHT", card.chrono, "BOTTOMRIGHT", -1, 1)
    chIc:SetTexture("Interface\\Icons\\Spell_Nature_TimeStop")
    chIc:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card.chrono.icon = chIc
    card.chrono:Hide()

    -- Raid-code row tooltip (explains the abbreviations).
    card:SetScript("OnEnter", function() end)  -- highlight handled by texture

    function card:Populate(entry, selected)
        self._selected = selected
        self:SetBackdropBorderColor(UI.Color(selected and "accent" or "border"))
        local rec = entry.rec

        self.pip:SetColorTexture(UI.Color(entry.online and "ok" or "faint"))
        self.name:SetText(Dashboard.ColoredName(entry.nameRealm, rec.classTag))
        if entry.aid and entry.aid ~= "" then
            self.acct:SetText("#" .. entry.aid); self.acct:SetTextColor(UI.Color("accent")); self.acct:Show()
        else
            self.acct:SetText(""); self.acct:Hide()
        end

        if rec.pvpFlagged and rec.faction then
            self.crest:SetTexture(Dashboard.FactionCrest(rec.faction))
            self.crest:Show()
        else
            self.crest:Hide()
        end

        if rec.location and rec.location ~= "" then
            self.loc:SetText(rec.location); self.loc:SetTextColor(UI.Color("muted"))
        else
            self.loc:SetText("Missing location"); self.loc:SetTextColor(UI.Color("danger"))
        end

        -- Raid codes colored by lockout.
        local nowE = Dashboard.Now()
        for _, t in ipairs(self.raid) do
            local expiry = rec.raidLockouts and rec.raidLockouts[t._raidKey]
            local locked = expiry and expiry > nowE
            t:SetText(RAID_CODE[t._raidKey] or t._raidKey)
            t:SetTextColor(UI.Color(locked and "danger" or "ok"))
        end

        self.fresh:SetText(Dashboard.FreshnessText(rec.lastDataUpdate))
        self.fresh:SetTextColor(UI.Color("faint"))

        -- Collapsing buff-icon strip (present auras only, in display order).
        for _, s in ipairs(self.buffSlots) do s:Hide() end
        local placed, x = 0, 0
        for _, slotIdx in ipairs(Dashboard.AURA_DISPLAY_ORDER) do
            local meta = Dashboard.AURA_META[slotIdx]
            local st = rec.auraStates and rec.auraStates[slotIdx]
            if st and (st.duration or 0) > 0 then
                placed = placed + 1
                local slot = self.buffSlots[placed]
                slot:ClearAllPoints()
                slot:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", PADX + x, 8)
                slot.icon:SetTexture(meta.icon)
                slot.icon:SetDesaturated(false)
                local th = Dashboard.GetThreshold(entry.faction or rec.faction, meta.thresholdKey)
                local tok = Dashboard.AuraColorToken(st.duration, th)
                slot:SetBackdrop(UI.FLAT_BACKDROP)
                slot:SetBackdropColor(UI.Color("inset"))
                slot:SetBackdropBorderColor(UI.Color(tok))
                slot:Show()
                x = x + 20
            end
        end

        -- Chrono + hearth.
        if rec.chronoboonActive then
            self.chrono:Show()
            self.chrono:SetBackdrop(UI.FLAT_BACKDROP)
            self.chrono:SetBackdropColor(UI.Color("inset"))
            self.chrono:SetBackdropBorderColor(UI.Color((rec.boonCount or 0) == 0 and "danger" or "accent"))
        else
            self.chrono:Hide()
        end
        if (rec.hearthstoneCD or 0) > 0 then
            self.hearthCD:SetText(Dashboard.FormatDuration(rec.hearthstoneCD))
            self.hearthCD:SetTextColor(UI.Color("faint"))
            self.hearth:SetDesaturated(true)
        else
            self.hearthCD:SetText("")
            self.hearth:SetDesaturated(false)
        end
    end

    return card
end

----------------------------------------------------------------------
-- Tab registration
----------------------------------------------------------------------

Dashboard.RegisterTab("sixties", function(host)
    local pane
    pane = Dashboard.BuildRosterPane(host, {
        listTitle = "Tracked 60s",
        listHint  = "drag to reorder",
        cardHeight = CARD_H,
        enableDrag = true,
        makeCard = makeCard,
        gather = function()
            local faction = Dashboard.GetFaction()
            local roster = Dashboard.GatherRoster(faction, { minLevel = 60 })
            return Dashboard.OrderRoster(faction, roster)
        end,
    })
    return { Refresh = pane.Refresh, _pane = pane }
end)
