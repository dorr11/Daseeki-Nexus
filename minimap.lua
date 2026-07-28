-- Daseeki Nexus — minimap.lua
-- Standard minimap-ring launcher button (owner feedback 2b): parented to the
-- Minimap and angle-anchored on the ring like every other minimap button.
-- Position is stored as an angle in settings.minimap.angle; dragging slides the
-- button around the ring; SetPoint("CENTER", Minimap, "CENTER", x, y) is derived
-- from the angle via the standard LibDBIcon-style trig (reused from
-- Daseeki-Core/minimap.lua). This is safe because our button carries NO secure
-- bindings (the Alt+Left /camp logout is intentionally omitted), so anchoring to
-- the minimap cluster never makes the frame protected.
--
-- Click matrix (UI spec §8):
--   Left            invite all online   (ns.Auto soft-guard; N4 tooltip)
--   Right           toggle dashboard    (ns.UI soft-guard)
--   Ctrl+Right      Cancel Buffs        (ns.HUD.ShowCancelBuffs)
--   Shift+Right     dashboard Timers tab(ns.UI soft-guard)
--   Alt+Right       world map -> Felwood
--   Alt+Left        (OMITTED) /camp logout — a secure /camp macro would make
--                   this frame PROTECTED, and it is exactly that omission that
--                   keeps ring-anchoring safe. Deferred; documented deviation.
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

local DEFAULT_ANGLE = 220   -- degrees on the ring (lower-left, out of the way)

local function minimapCfg()
    local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    local m = s and s.minimap
    if not m then return { angle = DEFAULT_ANGLE } end
    return m
end

----------------------------------------------------------------------
-- Ring position math (angle -> x,y offset from Minimap center). Reused from
-- Daseeki-Core/minimap.lua (LibDBIcon-compatible), so our button sits on the
-- ring identically to the Core button and respects non-round minimap shapes.
----------------------------------------------------------------------

local MINIMAP_SHAPES = {
    ["ROUND"]                = { true,  true,  true,  true  },
    ["SQUARE"]               = { false, false, false, false },
    ["CORNER-TOPLEFT"]       = { false, false, false, true  },
    ["CORNER-TOPRIGHT"]      = { false, false, true,  false },
    ["CORNER-BOTTOMLEFT"]    = { false, true,  false, false },
    ["CORNER-BOTTOMRIGHT"]   = { true,  false, false, false },
    ["SIDE-LEFT"]            = { false, true,  false, true  },
    ["SIDE-RIGHT"]           = { true,  false, true,  false },
    ["SIDE-TOP"]             = { false, false, true,  true  },
    ["SIDE-BOTTOM"]          = { true,  true,  false, false },
    ["TRICORNER-TOPLEFT"]    = { false, true,  true,  true  },
    ["TRICORNER-TOPRIGHT"]   = { true,  false, true,  true  },
    ["TRICORNER-BOTTOMLEFT"] = { true,  true,  false, true  },
    ["TRICORNER-BOTTOMRIGHT"]= { true,  true,  true,  false },
}
local MINIMAP_RADIUS = 5

local function updatePosition(btn, angle)
    angle = (angle or DEFAULT_ANGLE) % 360
    local rad = math.rad(angle)
    local cosA, sinA = math.cos(rad), math.sin(rad)

    local q = 1
    if cosA < 0 then q = q + 1 end
    if sinA > 0 then q = q + 2 end

    local shape = MINIMAP_SHAPES[(GetMinimapShape and GetMinimapShape()) or "ROUND"]
    local w = (Minimap:GetWidth()  / 2) + MINIMAP_RADIUS
    local h = (Minimap:GetHeight() / 2) + MINIMAP_RADIUS
    local x, y

    if not shape or shape[q] then
        x, y = cosA * w, sinA * h
    else
        local dw = math.sqrt(2 * w * w) - 10
        local dh = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(cosA * dw, w))
        y = math.max(-h, math.min(sinA * dh, h))
    end

    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
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
-- Button construction (ring-anchored to the Minimap; both dims set at creation)
----------------------------------------------------------------------

local button

local function buildButton()
    local b = CreateFrame("Button", "DaseekiNexusMinimapButton", Minimap)
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

    -- Ring drag: slide around the Minimap by tracking the cursor's angle from the
    -- minimap center and re-anchoring. Angle persists to settings.minimap.angle.
    b:SetScript("OnDragStart", function(self)
        if minimapCfg().lock then return end
        self._moving = true
        self:SetScript("OnUpdate", function(s)
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale  = Minimap:GetEffectiveScale()
            if mx and scale and scale > 0 then
                px, py = px / scale, py / scale
                local angle = math.deg(math.atan2(py - my, px - mx)) % 360
                minimapCfg().angle = angle
                updatePosition(s, angle)
            end
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self._moving = false
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
        -- Do not tear down the OnUpdate while a ring-drag is in progress (the
        -- button slides out from under the cursor, firing OnLeave mid-drag).
        if self._moving then return end
        self:SetScript("OnUpdate", nil)
        GameTooltip:Hide()
    end)

    return b
end

-- Apply saved ring angle + visibility.
local function applyState()
    if not button then return end
    local cfg = minimapCfg()
    updatePosition(button, cfg.angle or DEFAULT_ANGLE)
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
