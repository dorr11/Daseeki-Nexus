-- Daseeki Nexus — minimap.lua
-- Free-floating, draggable launcher button. Per engine spec §9 it is NOT
-- parented or anchored to the minimap cluster (protected-frame anchoring to the
-- Edit-Mode minimap blanks the minimap on relogin); it free-floats on UIParent
-- and persists its own position.
--
-- Click matrix (UI spec §8):
--   Left            invite all online   (ns.Auto soft-guard; N4 tooltip)
--   Right           toggle dashboard    (ns.UI soft-guard)
--   Ctrl+Right      Cancel Buffs        (ns.HUD.ShowCancelBuffs)
--   Shift+Right     dashboard Timers tab(ns.UI soft-guard)
--   Alt+Right       world map -> Felwood
--   Alt+Left        (OMITTED) /camp logout — a secure /camp macro would make
--                   this frame PROTECTED (engine §9), breaking free-float combat
--                   repositioning. Deferred this wave; documented deviation.
--
-- Clean-room build: functional reimplementation from spec; no third-party code.

local ADDON, ns = ...

local UI = DaseekiUI

local Button = {}
ns.MinimapButton = Button

if type(UI) ~= "table" or type(UI.Color) ~= "function" then
    return
end

local FELWOOD_MAP = 1448

----------------------------------------------------------------------
-- Settings access
----------------------------------------------------------------------

local function minimapCfg()
    local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    local m = s and s.minimap
    if not m then return { point = "CENTER", x = 0, y = 200 } end
    return m
end

----------------------------------------------------------------------
-- Live cooldown text (Rend / Ony) via Timers.ComputeCD + Timers.state
----------------------------------------------------------------------

local function nowEpoch()
    if ns.Store and ns.Store.Now then return ns.Store.Now() end
    return (GetServerTime and GetServerTime()) or 0
end

local function anchorOf(buffKey)
    local st = ns.Timers and ns.Timers.state and ns.Timers.state[buffKey]
    if not st then return 0 end
    return math.max(st.lastPop or 0, st.lastKilled or 0)
end

local function fmtRemaining(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

-- Returns text, colorToken for a buff's CD state.
local function cdStatus(buffKey)
    if not (ns.Timers and ns.Timers.ComputeCD) then return "no data", "faint" end
    local anchor = anchorOf(buffKey)
    if anchor <= 0 then return "no data", "faint" end
    local info = ns.Timers.ComputeCD(buffKey, anchor, nowEpoch())
    if info.ready then return "Can Pop", "ok" end
    -- pulse semantics live in the dashboard; the tooltip just states time.
    local token = (info.remaining <= 20 * 60) and "danger" or "accent"
    return fmtRemaining(info.remaining), token
end

----------------------------------------------------------------------
-- Soft-guarded actions (parallel agents own ns.Auto / ns.UI)
----------------------------------------------------------------------

local function inviteAll()
    if ns.Auto and ns.Auto.InviteAllOnline then
        ns.Auto.InviteAllOnline()
    else
        ns:Print("mass invite arrives in wave N4.")
    end
end

local function toggleDashboard()
    local u = ns.UI
    if u then
        local fn = u.Toggle or u.ToggleDashboard or u.Show
        if fn then ns:SafeCall(fn); return end
    end
    ns:Print("dashboard arrives with the UI module.")
end

local function openDashboardTimers()
    local u = ns.UI
    if u then
        if u.OpenTab then ns:SafeCall(u.OpenTab, "Timers"); return end
        if u.ShowTab then ns:SafeCall(u.ShowTab, "Timers"); return end
        local fn = u.Toggle or u.ToggleDashboard or u.Show
        if fn then ns:SafeCall(fn); return end
    end
    ns:Print("dashboard Timers tab arrives with the UI module.")
end

local function openFelwoodMap()
    if not WorldMapFrame then return end
    if not WorldMapFrame:IsShown() then
        if ToggleWorldMap then ToggleWorldMap()
        elseif ShowUIPanel then ShowUIPanel(WorldMapFrame) end
    end
    if WorldMapFrame.SetMapID then WorldMapFrame:SetMapID(FELWOOD_MAP) end
end

----------------------------------------------------------------------
-- Button construction (free-floating; both dimensions set at creation)
----------------------------------------------------------------------

local button

local function buildButton()
    local b = CreateFrame("Button", "DaseekiNexusMinimapButton", UIParent)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(20)

    -- Round background (Blizzard built-in).
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER", b, "CENTER", 0, 0)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    -- Icon (the addon's own IconTexture spirit — Blizzard built-in).
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19)
    icon:SetPoint("CENTER", b, "CENTER", 0, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Net_01")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b._icon = icon

    -- Round tracking border overlay (standard minimap-button ring).
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("TOPLEFT", b, "TOPLEFT", -1, 1)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b._border = border

    -- Subtle themed hover glow.
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetSize(24, 24)
    hl:SetPoint("CENTER", b, "CENTER", 0, 0)
    UI.Skin(hl, function(self) self:SetColorTexture(UI.Color("accent", 0.20)) end)
    b:SetHighlightTexture(hl)

    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")

    b:SetScript("OnDragStart", function(self)
        if minimapCfg().lock then return end
        self:StartMoving()
        self._moving = true
    end)
    b:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self._moving = false
        local point, _, _, x, y = self:GetPoint(1)
        local cfg = minimapCfg()
        cfg.point, cfg.x, cfg.y = point or "CENTER", x or 0, y or 0
    end)

    b:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            if IsAltKeyDown() then
                -- Alt+Left logout intentionally omitted (see header).
                ns:Print("Alt+Left logout is disabled this build (secure-frame safety).")
            else
                inviteAll()
            end
        elseif mouseButton == "RightButton" then
            if IsControlKeyDown() then
                if ns.HUD and ns.HUD.ShowCancelBuffs then ns.HUD.ShowCancelBuffs() end
            elseif IsShiftKeyDown() then
                openDashboardTimers()
            elseif IsAltKeyDown() then
                openFelwoodMap()
            else
                toggleDashboard()
            end
        end
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Daseeki Nexus", UI.Color("accent"))
        -- Live world-buff states.
        local rendT, rendC = cdStatus("rend")
        local onyAT, onyAC = cdStatus("onyA")
        local onyHT, onyHC = cdStatus("onyH")
        GameTooltip:AddDoubleLine("Rend",     rendT, UI.Color("muted"))
        GameTooltip:AddDoubleLine("Ony (A)",  onyAT, UI.Color("muted"))
        GameTooltip:AddDoubleLine("Ony (H)",  onyHT, UI.Color("muted"))
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left: invite online",           UI.Color("faint"))
        GameTooltip:AddLine("Right: toggle dashboard",       UI.Color("faint"))
        GameTooltip:AddLine("Ctrl+Right: Cancel Buffs",      UI.Color("faint"))
        GameTooltip:AddLine("Shift+Right: Timers tab",       UI.Color("faint"))
        GameTooltip:AddLine("Alt+Right: Felwood map",        UI.Color("faint"))
        if not minimapCfg().lock then
            GameTooltip:AddLine("Drag to move",              UI.Color("faint"))
        end
        GameTooltip:Show()
        -- keep tooltip cooldown times live while hovered
        self._ttAccum = 0
        self:SetScript("OnUpdate", function(s, e)
            s._ttAccum = (s._ttAccum or 0) + e
            if s._ttAccum >= 1 and GameTooltip:IsOwned(s) then
                s._ttAccum = 0
                s:GetScript("OnEnter")(s)
            end
        end)
    end)
    b:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        GameTooltip:Hide()
    end)

    b:SetMovable(true)
    b:SetClampedToScreen(true)
    return b
end

-- Apply saved position + visibility.
local function applyState()
    if not button then return end
    local cfg = minimapCfg()
    button:ClearAllPoints()
    button:SetPoint(cfg.point or "CENTER", UIParent, cfg.point or "CENTER", cfg.x or 0, cfg.y or 200)
    if cfg.hide then button:Hide() else button:Show() end
end

function Button.Refresh() applyState() end

function Button.Toggle()
    local cfg = minimapCfg()
    cfg.hide = not cfg.hide
    applyState()
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------

ns:On("LOGIN", function()
    if not button then button = buildButton() end
    ns:SafeCall(applyState)
end)

ns:RegisterSelfTest("minimap", function(verbose)
    local pass = true
    local function check(c, m) if not c then pass = false; if verbose then ns:Print("  FAIL: " .. m) end end end
    check(fmtRemaining(3661):find("1h"), "fmtRemaining hours")
    check(fmtRemaining(120) == "2m", "fmtRemaining minutes")
    local t, tok = cdStatus("rend")
    check(type(t) == "string" and type(tok) == "string", "cdStatus returns text+token")
    if verbose then ns:Print("  minimap selftest " .. (pass and "PASS" or "FAIL")) end
    return pass
end)
