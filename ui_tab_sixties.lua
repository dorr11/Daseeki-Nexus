-- Daseeki Nexus — ui_tab_sixties.lua
-- The "60s" tab (spec §1): every level-60 character on the selected faction as
-- a rich card in a drag-reorderable left list, with the shared detail panel on
-- the right. Card + detail composition follows the DaseekiUI style guide:
-- fixed-width bands, labeled sub-rows, compact, no stretch.

local ADDON, ns = ...
local UI = DaseekiUI
local Dashboard = ns.Dashboard

local CARD_H = 96

-- Real item IDs for the card's cooldown icons (owner feedback #7). Resolved to
-- their true inventory art via Dashboard.ItemIcon (C_Item.GetItemIconByID).
local CHRONOBOON_ITEM  = 184937   -- Chronoboon Displacer
local HEARTHSTONE_ITEM = 6948     -- Hearthstone

-- Naxx raid-diamond prototype (owner task 7): the leftmost raid diamond ("Naxx")
-- renders the raid's identifying item icon clipped to a diamond, keeping the
-- green(available)/red(locked) state via a tinted diamond rim. Icon source is a
-- real item (C_Item.GetItemIconByID via Dashboard.ItemIcon); the diamond shape
-- comes from a brand-original alpha mask shipped with the addon.
local NAXX_KEY     = "Naxx"
local NAXX_ITEM    = 22520   -- The Phylactery of Kel'Thuzad (KT quest drop)
local DIAMOND_MASK = "Interface\\AddOns\\Daseeki-Nexus\\textures\\diamond-mask"

local function fstr(parent, key)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    return f
end

-- Card name reads one readable step above body (owner task 1): a card-scoped
-- title font at bodySize+2 (12 -> 14). Built on the framework font-object path
-- (SetFontObject), not a raw per-string SetFont, and rebuilt on theme change so a
-- future body-face swap tracks. The name's own colour comes from ColoredName's
-- inline class-colour escape codes, so this object only carries face + size (its
-- SetTextColor is a harmless default the class colour overrides).
local NAME_FONT = CreateFont("DaseekiNexusSixtyCardNameFont")
local function applyNameFont()
    local face = (UI.Token and UI.Token("bodyFace")) or "Fonts\\FRIZQT__.TTF"
    local size = ((UI.Token and UI.Token("bodySize")) or 12) + 2
    NAME_FONT:SetFont(face, size, "")
    NAME_FONT:SetTextColor(UI.Color("text"))
    NAME_FONT:SetJustifyH("LEFT")
end
applyNameFont()
if UI.OnThemeChanged then UI.OnThemeChanged(applyNameFont) end

-- Build the Naxx compound diamond (owner task 7 prototype). A nominal 9px slot
-- frame (so the raid row's pitch is IDENTICAL to the plain diamonds) holds a
-- diamond-masked raid icon over a tinted diamond rim, both centered and drawn a
-- touch larger so the icon is legible at diamond scale. Falls back gracefully:
-- the rim is a full green/red diamond, so an uncached icon still reads as the
-- correct lockout state until the next paint resolves the art.
local function makeNaxxDiamond(parent)
    local ICON, RIM = 15, 17
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(9, 9)   -- layout footprint == one plain diamond
    local rim = Dashboard.MakeDiamond(f, RIM, "BACKGROUND")
    rim:SetPoint("CENTER", f, "CENTER", 0, 0)
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON, ICON)
    icon:SetPoint("CENTER", f, "CENTER", 0, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local mask = f:CreateMaskTexture()
    mask:SetAllPoints(icon)
    mask:SetTexture(DIAMOND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    icon:AddMaskTexture(mask)
    f._naxx, f._rim, f._icon, f._mask = true, rim, icon, mask
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
    card.name:SetFontObject(NAME_FONT)         -- one readable step above body (task 1)
    card.name:SetPoint("LEFT", card.pip, "RIGHT", 6, 0)
    card.name:SetJustifyH("LEFT")
    card.name:SetWordWrap(false)               -- keep the taller name on one line

    card.acct = fstr(card, "small")
    card.acct:SetPoint("LEFT", card.name, "RIGHT", 6, 0)

    -- PvP-flag crest sits INLINE on the name line (owner nit #2): name · #acct ·
    -- crest. Small, vertically centered with the name text. The final left-anchor
    -- (after #acct, or after the name when #acct is hidden) is chosen in Populate.
    card.crest = card:CreateTexture(nil, "ARTWORK")
    card.crest:SetSize(14, 14)
    card.crest:SetPoint("LEFT", card.acct, "RIGHT", 6, 0)
    card.crest:SetTexCoord(0.02, 0.62, 0.03, 0.63)
    card.crest:Hide()

    -- Location (owner task 8a): no longer a line under the name — it now sits in
    -- the card's bottom-right, directly ABOVE the "Updated" freshness. Created here
    -- but anchored after the freshness label exists (below). Right-aligned, single
    -- line, truncating with an ellipsis so a long zone name can't run wide.
    card.loc = fstr(card, "small")
    card.loc:SetJustifyH("RIGHT")
    card.loc:SetWordWrap(false)

    -- Raid-lockout diamond pips (parity item 1). Row moved UP into the space the
    -- location line vacated (owner task 8a) so no dead band opens under the name.
    -- Green = available, red = locked; a hover frame spanning the row shows a
    -- tooltip naming each raid + its reset time. The leftmost ("Naxx") diamond is
    -- a masked-icon prototype (owner task 7); the rest stay plain diamonds.
    card.raid = {}
    local prev
    for i, key in ipairs(Dashboard.RAID_DISPLAY) do
        local d = (key == NAXX_KEY) and makeNaxxDiamond(card) or Dashboard.MakeDiamond(card, 9)
        if prev then d:SetPoint("LEFT", prev, "RIGHT", 6, 0)
        else d:SetPoint("TOPLEFT", card, "TOPLEFT", PADX + 2, -34) end
        d._raidKey = key
        card.raid[i] = d
        prev = d
    end
    card.raidHover = CreateFrame("Frame", nil, card)
    card.raidHover:SetSize(#Dashboard.RAID_DISPLAY * 15 + 8, 16)
    card.raidHover:SetPoint("TOPLEFT", card, "TOPLEFT", PADX, -30)
    card.raidHover:EnableMouse(true)
    card.raidHover:SetScript("OnEnter", function(self)
        local rec = self._rec
        if not rec then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Raid lockouts", UI.Color("accent"))
        local nowE = Dashboard.Now()
        for _, key in ipairs(Dashboard.RAID_DISPLAY) do
            local expiry = rec.raidLockouts and rec.raidLockouts[key]
            local locked = expiry and expiry > nowE
            local full = Dashboard.RAID_FULLNAME[key] or key
            if locked then
                GameTooltip:AddDoubleLine(full, "Locked \194\183 " .. Dashboard.FormatDuration(expiry - nowE),
                    UI.Color("text"), UI.Color("danger"))
            else
                GameTooltip:AddDoubleLine(full, "Available", UI.Color("text"), UI.Color("ok"))
            end
        end
        GameTooltip:Show()
    end)
    card.raidHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- "Updated Xd Yh ago" freshness sits in the card's BOTTOM-RIGHT corner
    -- (owner nit #1): muted, small, right-aligned, baseline near the bottom edge.
    card.fresh = fstr(card, "small")
    card.fresh:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -PADX, 8)
    card.fresh:SetJustifyH("RIGHT")

    -- Line 4 (bottom row): collapsing buff-icon strip (left) + "Updated" freshness
    -- (bottom-right, built above). Chrono/hearth now live in the upper-right corner.
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

    -- Chronoboon + hearthstone stack in the card's UPPER-RIGHT corner (owner
    -- nit #3): chronoboon on top, hearthstone directly below it. Small icons;
    -- the hearthstone keeps its cooldown sub-label to its left and the chronoboon
    -- keeps its border-colour status. The chronoboon holds a fixed slot whether
    -- or not it is shown, so the hearthstone never shifts.
    card.chrono = CreateFrame("Frame", nil, card, "BackdropTemplate")
    card.chrono:SetSize(16, 16)
    card.chrono:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PADX, -8)
    local chIc = card.chrono:CreateTexture(nil, "ARTWORK")
    chIc:SetPoint("TOPLEFT", card.chrono, "TOPLEFT", 1, -1)
    chIc:SetPoint("BOTTOMRIGHT", card.chrono, "BOTTOMRIGHT", -1, 1)
    chIc:SetTexture(Dashboard.ItemIcon(CHRONOBOON_ITEM))
    chIc:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card.chrono.icon = chIc
    card.chrono:Hide()

    -- Chronoboon Displacer USE-cooldown countdown, LEFT of the chrono icon
    -- (mirrors the hearthstone's cooldown label below it). Small + muted; hidden
    -- when the item is ready (icon-only). Decays client-side for remote records.
    card.chronoCD = fstr(card, "small")
    card.chronoCD:SetPoint("RIGHT", card.chrono, "LEFT", -3, 0)
    card.chronoCD:SetJustifyH("RIGHT")

    card.hearth = card:CreateTexture(nil, "ARTWORK")
    card.hearth:SetSize(16, 16)
    card.hearth:SetPoint("TOPRIGHT", card.chrono, "BOTTOMRIGHT", 0, -4)
    card.hearth:SetTexture(Dashboard.ItemIcon(HEARTHSTONE_ITEM))
    card.hearth:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card.hearthCD = fstr(card, "small")
    card.hearthCD:SetPoint("RIGHT", card.hearth, "LEFT", -3, 0)
    card.hearthCD:SetJustifyH("RIGHT")

    -- Location sits directly above the freshness line in the bottom-right (owner
    -- task 8a). Its LEFT is bounded well clear of the bottom-left buff strip so a
    -- long zone name truncates (ellipsis) instead of colliding at narrow widths.
    card.loc:SetPoint("BOTTOMRIGHT", card.fresh, "TOPRIGHT", 0, 3)
    card.loc:SetPoint("LEFT", card, "LEFT", PADX + 108, 0)

    -- Raid-code row tooltip (explains the abbreviations).
    card:SetScript("OnEnter", function() end)  -- highlight handled by texture

    function card:Populate(entry, selected)
        self._selected = selected
        self:SetBackdropBorderColor(UI.Color(selected and "accent" or "border"))
        local rec = entry.rec

        self.pip:SetColorTexture(UI.Color(entry.online and "ok" or "faint"))
        self.name:SetText(Dashboard.ColoredName(entry.nameRealm, rec.classTag))
        if entry.aid and entry.aid ~= "" then
            -- Bare account number, no "#" prefix (owner task 8b); colour/size keep
            -- it subordinate to the (now larger) name.
            self.acct:SetText(entry.aid); self.acct:SetTextColor(UI.Color("accent")); self.acct:Show()
        else
            self.acct:SetText(""); self.acct:Hide()
        end

        if rec.pvpFlagged and rec.faction then
            self.crest:SetTexture(Dashboard.FactionCrest(rec.faction))
            -- Sit the crest inline right after the account tag when it is shown,
            -- else right after the name, so it always hugs the end of the line.
            self.crest:ClearAllPoints()
            local afterName = (entry.aid and entry.aid ~= "") and self.acct or self.name
            self.crest:SetPoint("LEFT", afterName, "RIGHT", 6, 0)
            self.crest:Show()
        else
            self.crest:Hide()
        end

        if rec.location and rec.location ~= "" then
            self.loc:SetText(rec.location); self.loc:SetTextColor(UI.Color("muted"))
        else
            self.loc:SetText("Missing location"); self.loc:SetTextColor(UI.Color("danger"))
        end

        -- Raid-lockout diamond pips (parity item 1): green available / red locked.
        -- The Naxx slot (owner task 7 prototype) tints its diamond RIM with the
        -- same token and shows the raid's item icon clipped to the diamond; the
        -- locked state also desaturates the icon so it reads dimmer.
        local nowE = Dashboard.Now()
        for _, d in ipairs(self.raid) do
            local expiry = rec.raidLockouts and rec.raidLockouts[d._raidKey]
            local locked = expiry and expiry > nowE
            local tok = locked and "danger" or "ok"
            if d._naxx then
                Dashboard.SetDiamondColor(d._rim, tok)
                d._icon:SetTexture(Dashboard.ItemIcon(NAXX_ITEM))  -- re-set: late item-cache resolve
                d._icon:SetDesaturated(locked and true or false)
            else
                Dashboard.SetDiamondColor(d, tok)
            end
        end
        self.raidHover._rec = rec

        self.fresh:SetText(Dashboard.FreshnessText(rec.lastDataUpdate))
        self.fresh:SetTextColor(UI.Color("faint"))

        -- Collapsing buff-icon strip. Icons derive from the real spell (owner
        -- feedback #1). Missing state (owner feedback #3): present = full color +
        -- threshold border; missing+required = greyed icon + danger border;
        -- missing+optional = greyed icon, no border. Non-applicable (ignored
        -- class / absent seasonal) collapses out so icons hug left.
        for _, s in ipairs(self.buffSlots) do s:Hide() end
        local placed, x = 0, 0
        for _, slotIdx in ipairs(Dashboard.AURA_DISPLAY_ORDER) do
            local meta = Dashboard.AURA_META[slotIdx]
            local st = rec.auraStates and rec.auraStates[slotIdx]
            local present = st and (st.duration or 0) > 0
            local applicable, requirement = Dashboard.AuraRequirement(slotIdx, rec, entry.faction or rec.faction)
            if present or applicable then
                placed = placed + 1
                local slot = self.buffSlots[placed]
                if slot then
                    slot:ClearAllPoints()
                    slot:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", PADX + x, 8)
                    slot.icon:SetTexture(Dashboard.AuraIcon(slotIdx))
                    slot:SetBackdrop(UI.FLAT_BACKDROP)
                    slot:SetBackdropColor(UI.Color("inset"))
                    if present then
                        slot.icon:SetDesaturated(false); slot.icon:SetVertexColor(1, 1, 1); slot.icon:SetAlpha(1)
                        local th = Dashboard.GetThreshold(entry.faction or rec.faction, meta.thresholdKey)
                        slot:SetBackdropBorderColor(UI.Color(Dashboard.AuraColorToken(st.duration, th)))
                    else
                        slot.icon:SetDesaturated(true); slot.icon:SetVertexColor(0.6, 0.6, 0.6); slot.icon:SetAlpha(0.5)
                        if requirement == "required" then
                            slot:SetBackdropBorderColor(UI.Color("danger"))
                        else
                            slot:SetBackdropBorderColor(UI.Color("border", 0))   -- no border
                        end
                    end
                    slot:Show()
                    x = x + 20
                end
            end
        end

        -- Chrono + hearth in the upper-right stack (real item icons; re-set each
        -- refresh so a late item-cache resolve corrects a first-paint question mark).
        -- Cooldown remainders DECAY client-side off rec.lastDataUpdate so a remote
        -- card counts down between updates; both hide their label at 0 (icon-only
        -- = ready). FormatDuration is the card's existing formatter ("59m"/"23m").
        self.hearth:SetTexture(Dashboard.ItemIcon(HEARTHSTONE_ITEM))
        self.chrono.icon:SetTexture(Dashboard.ItemIcon(CHRONOBOON_ITEM))
        local chronoCDrem = Dashboard.DecayRemaining(rec.itemCooldown, rec.lastDataUpdate, nowE)
        -- Show the chrono icon while booned (border = boon status) OR while the
        -- Displacer is on its use cooldown (muted/desaturated) so the countdown
        -- label always has its icon to sit beside.
        if rec.chronoboonActive then
            self.chrono:Show()
            self.chrono:SetBackdrop(UI.FLAT_BACKDROP)
            self.chrono:SetBackdropColor(UI.Color("inset"))
            self.chrono:SetBackdropBorderColor(UI.Color((rec.boonCount or 0) == 0 and "danger" or "accent"))
            self.chrono.icon:SetDesaturated(false)
        elseif chronoCDrem > 0 then
            self.chrono:Show()
            self.chrono:SetBackdrop(UI.FLAT_BACKDROP)
            self.chrono:SetBackdropColor(UI.Color("inset"))
            self.chrono:SetBackdropBorderColor(UI.Color("border"))
            self.chrono.icon:SetDesaturated(true)
        else
            self.chrono:Hide()
        end
        if chronoCDrem > 0 then
            self.chronoCD:SetText(Dashboard.FormatDuration(chronoCDrem))
            self.chronoCD:SetTextColor(UI.Color("danger"))   -- RED while on cooldown (owner task 2)
        else
            self.chronoCD:SetText("")
        end
        local hearthCDrem = Dashboard.DecayRemaining(rec.hearthstoneCD, rec.lastDataUpdate, nowE)
        if hearthCDrem > 0 then
            self.hearthCD:SetText(Dashboard.FormatDuration(hearthCDrem))
            self.hearthCD:SetTextColor(UI.Color("danger"))   -- RED while on cooldown (owner task 2)
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
        listTitle = "Characters",              -- renamed (owner task 11)
        enableOnlineFilter = true,             -- All | Online toggle replaces the hint + Online tab
        emptyText = "No characters online",
        cardHeight = CARD_H,
        enableDrag = true,
        makeCard = makeCard,
        gather = function()
            -- Drag order first (persisted per faction), THEN a stable online-
            -- first partition (owner feedback #4): online characters float to
            -- the top automatically while drag order persists within each group.
            local faction = Dashboard.GetFaction()
            local roster = Dashboard.GatherRoster(faction, { minLevel = 60 })
            local ordered = Dashboard.OrderRoster(faction, roster)
            return Dashboard.PartitionOnlineFirst(ordered)
        end,
    })
    return { Refresh = pane.Refresh, _pane = pane }
end)
