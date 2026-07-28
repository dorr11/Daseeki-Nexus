-- Daseeki Network — interact.lua
-- Wave N4a: one-click click-to-target NPC popups (UI spec §6).
--
-- Floating SECURE buttons that /targetexact a fixed set of city service NPCs.
-- Each button is proximity + zone gated (C_Map position polled twice a second
-- after login), combat-safe (secure show/hide/move is deferred out of combat),
-- draggable with persisted positions, and carries a golden border + tooltip.
--
-- Clean-room build: functional reimplementation from spec only; no third-party
-- code or identifiers.
--
-- API discipline (Interface 11509, catalog-verified):
--   CreateFrame (SecureActionButtonTemplate + BackdropTemplate) ; C_Map.
--   GetBestMapForUnit / .GetPlayerMapPosition ; GetRealZoneText ;
--   InCombatLockdown ; C_Timer.NewTicker. The secure action itself is a
--   `macrotext` attribute ("/targetexact <name>") — no protected API is called
--   from insecure code.

local ADDON, ns = ...

local Interact = {}
ns.Interact = Interact

local Store = ns.Store

----------------------------------------------------------------------
-- Shipped NPC catalog (spec §6). Extensible: other modules may append to
-- Interact.NPCS before login. Coordinates are in their zone's map space
-- (0..1); exact values are refined in-game (the zone gate is the reliable
-- filter, proximity is a refinement). `key` indexes settings.autoInteract.
----------------------------------------------------------------------

Interact.NPCS = {
    { key = "keldric",  name = "Keldric Boucher",    zone = "Stormwind City", x = 0.532, y = 0.868, label = "Keldric" },
    { key = "jaxon",    name = "Auctioneer Jaxon",   zone = "Stormwind City", x = 0.614, y = 0.703, label = "Jaxon (AH)" },
    { key = "gunther",  name = "Gunther Weller",     zone = "Stormwind City", x = 0.530, y = 0.688, label = "Gunther" },
    { key = "mangorn",  name = "Mangorn Flinthammer", zone = "Ironforge",     x = 0.628, y = 0.377, label = "Mangorn" },
}

-- Proximity threshold in normalized map units (~sub-zone sized box). Applied
-- only when the player is on the same map as the NPC.
local PROX = 0.10

-- Golden border color.
local GOLD = { 1.0, 0.82, 0.0 }

----------------------------------------------------------------------
-- Settings access
----------------------------------------------------------------------

-- Per-NPC enable flag (settings.autoInteract[key]). Default OFF.
local function npcEnabled(key)
    local fs = Store.GetFactionSettings(UnitFactionGroup and UnitFactionGroup("player") or "Alliance")
    return fs.autoInteract and fs.autoInteract[key] == true
end

-- Persisted button positions live in the settings SV under `interact.positions`
-- (additive key; store defaults leave it nil, which we lazily create).
local function positionsTable()
    local db = Store.GetSettings()
    db.interact = db.interact or {}
    db.interact.positions = db.interact.positions or {}
    return db.interact.positions
end

----------------------------------------------------------------------
-- Geometry helpers
----------------------------------------------------------------------

local function playerZoneAndPos()
    local zone = GetRealZoneText() or ""
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not mapID then return zone, nil, nil end
    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return zone, nil, nil end
    local x, y = pos:GetXY()
    return zone, x, y
end

-- Distance (normalized units) from player to an NPC on the same map. Returns
-- nil when position is unavailable. Pure over its numeric inputs (self-tested).
function Interact.Distance(px, py, nx, ny)
    if not (px and py and nx and ny) then return nil end
    local dx, dy = px - nx, py - ny
    return math.sqrt(dx * dx + dy * dy)
end

-- Should the button for `def` be visible given the player's zone + position?
-- Pure decision so the gate is testable without frames or the game.
function Interact.ShouldShow(def, zone, px, py)
    if zone ~= def.zone then return false end
    -- Same zone but no coords yet (map not loaded): show on zone match alone.
    if not (px and py) then return true end
    local d = Interact.Distance(px, py, def.x, def.y)
    if d == nil then return true end
    return d <= PROX
end

----------------------------------------------------------------------
-- Secure button construction
----------------------------------------------------------------------

Interact._buttons = {}     -- [key] = Button
Interact._pending = {}     -- [key] = bool desired-visible (applied out of combat)

local function savePosition(key, btn)
    local point, _, relPoint, x, y = btn:GetPoint()
    positionsTable()[key] = { point = point, relPoint = relPoint, x = x, y = y }
end

local function restorePosition(key, btn)
    local p = positionsTable()[key]
    btn:ClearAllPoints()
    if p then
        btn:SetPoint(p.point or "CENTER", UIParent, p.relPoint or p.point or "CENTER",
                     p.x or 0, p.y or 0)
    else
        -- Stagger defaults so buttons don't stack on first use.
        local idx = 0
        for i, d in ipairs(Interact.NPCS) do if d.key == key then idx = i end end
        btn:SetPoint("CENTER", UIParent, "CENTER", 0, -120 - (idx - 1) * 44)
    end
end

local function buildButton(def)
    if Interact._buttons[def.key] then return Interact._buttons[def.key] end
    if not CreateFrame then return nil end

    local btn = CreateFrame("Button", "DaseekiNetworkInteract_" .. def.key, UIParent,
        "SecureActionButtonTemplate,BackdropTemplate")
    btn:SetSize(120, 32)
    btn:Hide()

    -- Secure click-to-target: a macro attribute (insecure code never calls a
    -- protected targeting API).
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", "/targetexact " .. def.name)
    btn:RegisterForClicks("AnyUp", "AnyDown")

    -- Golden border chrome.
    if btn.SetBackdrop then
        btn:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets   = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        btn:SetBackdropColor(0, 0, 0, 0.8)
        btn:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1)
    end

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER")
    fs:SetText(def.label or def.name)
    fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    btn._label = fs

    -- Tooltip.
    btn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(def.name, GOLD[1], GOLD[2], GOLD[3])
        GameTooltip:AddLine("Click to target. Drag to move.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- Draggable (out of combat only — moving a secure frame is protected).
    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self)
        if InCombatLockdown and InCombatLockdown() then return end
        self:StartMoving()
    end)
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePosition(def.key, self)
    end)

    restorePosition(def.key, btn)
    Interact._buttons[def.key] = btn
    return btn
end

----------------------------------------------------------------------
-- Combat-safe visibility
----------------------------------------------------------------------

-- Apply a desired-visible state to a secure button, deferring the actual
-- show/hide when in combat (secure frames can't change protected visibility
-- mid-lockdown). Pending states flush on PLAYER_REGEN_ENABLED.
local function applyVisibility(key, visible)
    local btn = Interact._buttons[key]
    if not btn then return end
    if InCombatLockdown and InCombatLockdown() then
        Interact._pending[key] = visible
        return
    end
    Interact._pending[key] = nil
    if visible then btn:Show() else btn:Hide() end
end

function Interact.FlushPending()
    if InCombatLockdown and InCombatLockdown() then return end
    for key, visible in pairs(Interact._pending) do
        local btn = Interact._buttons[key]
        if btn then
            if visible then btn:Show() else btn:Hide() end
        end
    end
    wipe(Interact._pending)
end

----------------------------------------------------------------------
-- Poll tick (2x/second)
----------------------------------------------------------------------

function Interact.Tick()
    if not ns.state.loggedIn then return end
    local zone, px, py = playerZoneAndPos()
    for _, def in ipairs(Interact.NPCS) do
        local btn = Interact._buttons[def.key]
        if npcEnabled(def.key) then
            if not btn then btn = buildButton(def) end
            local visible = Interact.ShouldShow(def, zone, px, py)
            applyVisibility(def.key, visible)
        elseif btn then
            applyVisibility(def.key, false)
        end
    end
end

----------------------------------------------------------------------
-- /dsn coord — zone, 4-decimal coords, per-NPC distance readout
----------------------------------------------------------------------

function Interact.PrintCoords()
    local zone, px, py = playerZoneAndPos()
    if px and py then
        ns:Print(("%s  %.4f, %.4f"):format(zone ~= "" and zone or "?", px, py))
    else
        ns:Print(("%s  (position unavailable)"):format(zone ~= "" and zone or "?"))
    end
    for _, def in ipairs(Interact.NPCS) do
        if def.zone == zone and px and py then
            local d = Interact.Distance(px, py, def.x, def.y)
            ns:Print(("  %s: %.4f away%s"):format(
                def.name, d or 0,
                (d and d <= PROX) and " (in range)" or ""))
        end
    end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function Interact.OnLogin()
    -- Build any already-enabled buttons up front (out of combat at login).
    for _, def in ipairs(Interact.NPCS) do
        if npcEnabled(def.key) then buildButton(def) end
    end
    if C_Timer and C_Timer.NewTicker then
        Interact._ticker = C_Timer.NewTicker(0.5, function() ns:SafeCall(Interact.Tick) end)
    end
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        ns:SafeCall(Interact.FlushPending)
    end)
    ns:SafeCall(Interact.Tick)
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; registered as suite "interact")
----------------------------------------------------------------------

local function testDistance()
    local d = Interact.Distance(0, 0, 0.3, 0.4)
    if math.abs(d - 0.5) > 1e-9 then return false, "pythagoras" end
    if Interact.Distance(nil, 0, 0, 0) ~= nil then return false, "nil guard" end
    return true
end

local function testShouldShow()
    local def = { zone = "Stormwind City", x = 0.5, y = 0.5 }
    -- wrong zone -> hidden.
    if Interact.ShouldShow(def, "Ironforge", 0.5, 0.5) then return false, "zone gate" end
    -- right zone, in range -> shown.
    if not Interact.ShouldShow(def, "Stormwind City", 0.52, 0.52) then return false, "in range" end
    -- right zone, out of range -> hidden.
    if Interact.ShouldShow(def, "Stormwind City", 0.9, 0.9) then return false, "out of range" end
    -- right zone, no coords -> shown (zone match alone).
    if not Interact.ShouldShow(def, "Stormwind City", nil, nil) then return false, "no-coord fallback" end
    return true
end

function Interact.RunSelfTests(verbose)
    local suite = {
        { name = "distance", fn = testDistance },
        { name = "should-show gate", fn = testShouldShow },
    }
    local allPass = true
    for _, t in ipairs(suite) do
        local ok, why = t.fn()
        if not ok then allPass = false end
        if verbose and ns and ns.Print then
            if ok then ns:Print("  PASS interact/" .. t.name)
            else ns:Print("  FAIL interact/" .. t.name .. " :: " .. tostring(why)) end
        end
    end
    return allPass
end

----------------------------------------------------------------------
-- Registration
----------------------------------------------------------------------

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("interact", Interact.RunSelfTests)
end

-- /dsn coord[s] -> position + per-NPC distance readout (overrides N1 stub).
ns:RegisterSubcommand("coord",  function() Interact.PrintCoords() end, "show zone/coords + NPC distances")
ns:RegisterSubcommand("coords", function() Interact.PrintCoords() end, "show zone/coords + NPC distances")

ns:On("LOGIN", function()
    ns:SafeCall(Interact.OnLogin)
end)
