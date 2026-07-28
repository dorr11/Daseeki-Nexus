-- Daseeki Nexus — ui_tab_online.lua
-- The "Online" tab (spec §4): the full roster for the selected faction, online
-- characters first, in the same two-pane shape as 60s and sharing the detail
-- panel. Warlock cards show a soul-shard count with a severity stripe.

local ADDON, ns = ...
local UI = DaseekiUI
local Dashboard = ns.Dashboard

local CARD_H = 62

local function fstr(parent, key)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[key] or UI.fonts.body)
    return f
end

-- Shard severity token (spec §4): green >=40, yellow(accent) >=20, red below.
local function shardToken(n)
    if n >= 40 then return "ok" elseif n >= 20 then return "accent" else return "danger" end
end

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
    card.pip = card:CreateTexture(nil, "ARTWORK")
    card.pip:SetSize(8, 8)
    card.pip:SetPoint("TOPLEFT", card, "TOPLEFT", PADX, -10)

    card.name = fstr(card, "body")
    card.name:SetPoint("LEFT", card.pip, "RIGHT", 6, 0)

    card.acct = fstr(card, "small")
    card.acct:SetPoint("LEFT", card.name, "RIGHT", 6, 0)

    card.state = fstr(card, "small")
    card.state:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PADX, -10)
    card.state:SetJustifyH("RIGHT")

    card.loc = fstr(card, "small")
    card.loc:SetPoint("TOPLEFT", card, "TOPLEFT", PADX, -28)
    card.loc:SetPoint("RIGHT", card, "RIGHT", -PADX, 0)
    card.loc:SetJustifyH("LEFT")
    card.loc:SetWordWrap(false)

    -- Meta / shard line.
    card.meta = fstr(card, "small")
    card.meta:SetPoint("TOPLEFT", card, "TOPLEFT", PADX, -44)

    -- Warlock shard severity stripe (right side of the meta line).
    card.stripe = card:CreateTexture(nil, "ARTWORK")
    card.stripe:SetSize(60, 6)
    card.stripe:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PADX, -46)
    card.stripe:Hide()

    function card:Populate(entry, selected)
        self._selected = selected
        self:SetBackdropBorderColor(UI.Color(selected and "accent" or "border"))
        local rec = entry.rec

        self.pip:SetColorTexture(UI.Color(entry.online and "ok" or "faint"))
        self.name:SetText(Dashboard.ColoredName(entry.nameRealm, rec.classTag))
        if entry.aid and entry.aid ~= "" then
            self.acct:SetText("#" .. entry.aid); self.acct:SetTextColor(UI.Color("accent"))
        else
            self.acct:SetText("")
        end
        self.state:SetText(entry.online and Dashboard.Colored("Online","ok") or Dashboard.Colored("Offline","faint"))

        if rec.location and rec.location ~= "" then
            self.loc:SetText(rec.location); self.loc:SetTextColor(UI.Color("muted"))
        else
            self.loc:SetText("Missing location"); self.loc:SetTextColor(UI.Color("danger"))
        end

        if rec.classTag == "WARLOCK" then
            local n = rec.shardCount or 0
            self.meta:SetText("Summoner  |  Shards " .. n)
            self.meta:SetTextColor(UI.Color(shardToken(n)))
            self.stripe:SetColorTexture(UI.Color(shardToken(n)))
            self.stripe:Show()
        else
            self.meta:SetText((rec.className or "?") .. "  |  " .. (rec.faction or "?"))
            self.meta:SetTextColor(UI.Color("faint"))
            self.stripe:Hide()
        end
    end

    return card
end

Dashboard.RegisterTab("online", function(host)
    local pane
    pane = Dashboard.BuildRosterPane(host, {
        listTitle = "Online Roster",
        listHint  = "online only",
        cardHeight = CARD_H,
        enableDrag = false,
        makeCard = makeCard,
        emptyText = "No characters online",
        gather = function()
            -- Owner feedback: show ONLY currently-online characters (like the
            -- reference), not the full roster sorted online-first. Empty list ->
            -- the muted "No characters online" state (opts.emptyText).
            local faction = Dashboard.GetFaction()
            local roster = Dashboard.GatherRoster(faction, { includeHomeless = true })
            local online = {}
            for _, e in ipairs(roster) do
                if e.online then online[#online + 1] = e end
            end
            table.sort(online, function(a, b) return a.nameRealm < b.nameRealm end)
            return online
        end,
    })
    return { Refresh = pane.Refresh, _pane = pane }
end)
