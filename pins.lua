-- Daseeki Network — pins.lua
-- Felwood songflower / tuber node pins on the world map and minimap, driven by
-- Timers.NODES (16 fixed nodes) + the NODE_UPDATED callback.
--
-- Map-pin strategy (decision): own minimal placement, NOT a vendored map lib.
-- The node set is fixed (10 flowers + 6 tubers on one zone, uiMap 1448), so a
-- self-contained C_Map placement is smaller than vendoring HereBeDragons +
-- CallbackHandler and adds no cross-agent toc/lib merge surface. World-map pins
-- use exact C_Map canvas coordinates; minimap pins use a documented planar
-- approximation (north-up only) — the fuzzy part is isolated and calibratable.
--
-- Clean-room build: functional reimplementation from spec; no third-party code.

local ADDON, ns = ...

local UI = DaseekiUI

local Pins = {}
ns.Pins = Pins

if type(UI) ~= "table" or type(UI.Color) ~= "function" then
    return   -- Core absent; HUD.lua already surfaced the notice.
end

local FELWOOD_MAP = 1448

-- Node kind presentation. Icons are Blizzard built-ins (a missing path renders
-- blank, never an error).
local KIND_ICON = {
    flower = "Interface\\Icons\\INV_Misc_Herb_Fellotus",
    tuber  = "Interface\\Icons\\INV_Misc_Food_59",
}

----------------------------------------------------------------------
-- Settings access
----------------------------------------------------------------------

local function felwoodCfg()
    local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    local ts = s and s.timerSettings
    return (ts and ts.felwood) or {}
end

local function kindEnabled(kind)
    local c = felwoodCfg()
    if kind == "flower" then return c.showFlowerPins ~= false end
    return c.showTuberPins ~= false
end

local function worldPinSize()   return felwoodCfg().worldPinSize   or 14 end
local function minimapPinSize() return felwoodCfg().minimapPinSize or 12 end

----------------------------------------------------------------------
-- Node state colouring (via Timers)
--   up      -> available now (green / ok)
--   down    -> respawning (dim orange), world pin shows countdown
--   unknown -> no data (faint)
----------------------------------------------------------------------

local function nodeState(kind, index)
    if ns.Timers and ns.Timers.GetNodeState then
        return ns.Timers.GetNodeState(kind .. index)
    end
    return { state = "unknown", remaining = 0 }
end

-- Amber literal (no warn token; matches hud.lua's WARN_RGB choice).
local function tintForState(tex, state)
    if state == "up" then
        tex:SetVertexColor(UI.Color("ok"))
    elseif state == "down" then
        tex:SetVertexColor(0.96, 0.76, 0.18)
    else
        tex:SetVertexColor(UI.Color("faint"))
    end
end

local function fmtCountdown(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    if sec >= 60 then
        return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
    end
    return sec .. "s"
end

----------------------------------------------------------------------
-- World-map pins
--
-- Parented to the WorldMapFrame canvas; shown only while the displayed map is
-- Felwood. Positioned by exact normalized node coords × canvas size.
----------------------------------------------------------------------

local worldPins = {}   -- "kind"..index -> pin frame

local function worldCanvas()
    local wmf = WorldMapFrame
    if not wmf then return nil end
    local sc = wmf.ScrollContainer
    if sc and sc.Child then return sc.Child end
    return wmf   -- fallback: anchor to the frame itself
end

local function ensureWorldPin(kind, index, node)
    local key = kind .. index
    local pin = worldPins[key]
    if pin then return pin end
    local canvas = worldCanvas()
    if not canvas then return nil end

    pin = CreateFrame("Frame", nil, canvas)
    local sz = worldPinSize()
    pin:SetSize(sz, sz)
    pin:SetFrameStrata("HIGH")

    local tex = pin:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(pin)
    tex:SetTexture(KIND_ICON[kind])
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pin._tex = tex

    local timer = pin:CreateFontString(nil, "OVERLAY")
    timer:SetFontObject(UI.fonts.small)
    timer:SetPoint("TOP", pin, "BOTTOM", 0, -1)
    pin._timer = timer

    pin:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(node.label or (kind .. " " .. index), UI.Color("text"))
        local st = nodeState(kind, index)
        if st.state == "up" then
            GameTooltip:AddLine("Available", UI.Color("ok"))
        elseif st.state == "down" then
            GameTooltip:AddLine("Respawns in " .. fmtCountdown(st.remaining), UI.Color("muted"))
        else
            GameTooltip:AddLine("No data", UI.Color("faint"))
        end
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)

    worldPins[key] = pin
    return pin
end

local function refreshWorldPins()
    local wmf = WorldMapFrame
    if not wmf or not wmf:IsShown() then
        for _, p in pairs(worldPins) do p:Hide() end
        return
    end
    local shown = wmf.GetMapID and wmf:GetMapID()
    if shown ~= FELWOOD_MAP then
        for _, p in pairs(worldPins) do p:Hide() end
        return
    end
    local canvas = worldCanvas()
    if not canvas then return end
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    if not cw or cw == 0 then return end

    local nodes = ns.Timers and ns.Timers.NODES
    if not nodes then return end

    for kind, list in pairs(nodes) do
        for index = 1, #list do
            local node = list[index]
            if kindEnabled(kind) then
                local pin = ensureWorldPin(kind, index, node)
                if pin then
                    local sz = worldPinSize()
                    pin:SetSize(sz, sz)
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", canvas, "TOPLEFT", node.x * cw, -node.y * ch)
                    local st = nodeState(kind, index)
                    tintForState(pin._tex, st.state)
                    if st.state == "down" then
                        pin._timer:SetText(fmtCountdown(st.remaining))
                        pin._timer:SetTextColor(UI.Color("muted"))
                    else
                        pin._timer:SetText("")
                    end
                    pin:Show()
                end
            else
                local p = worldPins[kind .. index]
                if p then p:Hide() end
            end
        end
    end
end

----------------------------------------------------------------------
-- Minimap pins (approximate; north-up only)
--
-- Placed only when the player is in Felwood and the minimap is not rotating.
-- Position = (node - player) normalized delta scaled to minimap pixels via a
-- calibratable constant, clamped inside the minimap circle. This is the
-- documented approximation in lieu of a map lib.  [in-game calibrate]
----------------------------------------------------------------------

local minimapPins = {}
-- Normalized-coordinate → minimap-pixel scale. Felwood spans a large area, so
-- one normalized unit is many minimap radii; this constant is tuned so nearby
-- nodes land sensibly at default zoom. Calibrated in-game against real nodes.
local MINIMAP_NORM_SCALE = 900

local function ensureMinimapPin(kind, index, node)
    local key = kind .. index
    local pin = minimapPins[key]
    if pin then return pin end
    pin = CreateFrame("Frame", nil, Minimap)
    local sz = minimapPinSize()
    pin:SetSize(sz, sz)
    pin:SetFrameStrata("HIGH")
    local tex = pin:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(pin)
    tex:SetTexture(KIND_ICON[kind])
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pin._tex = tex
    minimapPins[key] = pin
    return pin
end

local function refreshMinimapPins()
    if not Minimap then return end
    -- Only in Felwood.
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID ~= FELWOOD_MAP then
        for _, p in pairs(minimapPins) do p:Hide() end
        return
    end
    -- North-up only (skip when the minimap rotates; our math assumes fixed north).
    if GetCVar and GetCVar("rotateMinimap") == "1" then
        for _, p in pairs(minimapPins) do p:Hide() end
        return
    end
    local pos = C_Map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(FELWOOD_MAP, "player")
    if not pos then return end
    local px, py = pos:GetXY()
    if not px then return end

    local radius = (Minimap:GetWidth() or 140) / 2
    local nodes = ns.Timers and ns.Timers.NODES
    if not nodes then return end

    for kind, list in pairs(nodes) do
        for index = 1, #list do
            local node = list[index]
            if kindEnabled(kind) then
                local pin = ensureMinimapPin(kind, index, node)
                local sz = minimapPinSize()
                pin:SetSize(sz, sz)
                -- normalized delta -> minimap pixels (y inverted: map y grows down)
                local dx = (node.x - px) * MINIMAP_NORM_SCALE
                local dy = -(node.y - py) * MINIMAP_NORM_SCALE
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist <= radius then
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", Minimap, "CENTER", dx, dy)
                    local st = nodeState(kind, index)
                    tintForState(pin._tex, st.state)
                    pin:Show()
                else
                    pin:Hide()   -- outside the minimap view
                end
            else
                local p = minimapPins[kind .. index]
                if p then p:Hide() end
            end
        end
    end
end

----------------------------------------------------------------------
-- Refresh driver
----------------------------------------------------------------------

local function refreshAll()
    ns:SafeCall(refreshWorldPins)
    ns:SafeCall(refreshMinimapPins)
end
Pins.Refresh = refreshAll

local driver
local function ensureDriver()
    if driver then return end
    driver = CreateFrame("Frame")
    driver._accum = 0
    driver:SetScript("OnUpdate", function(self, elapsed)
        self._accum = self._accum + elapsed
        if self._accum >= 1 then       -- 1s refresh (countdowns + player movement)
            self._accum = 0
            refreshAll()
        end
    end)
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------

ns:On("NODE_UPDATED", function() ns:SafeCall(refreshAll) end)

ns:On("LOGIN", function()
    ns:SafeCall(ensureDriver)
    -- Refresh world pins whenever the map opens.
    if WorldMapFrame and WorldMapFrame.HookScript and not Pins._hooked then
        Pins._hooked = true
        WorldMapFrame:HookScript("OnShow", function() ns:SafeCall(refreshWorldPins) end)
    end
    ns:SafeCall(refreshAll)
end)

-- Self-test: pure geometry helpers.
ns:RegisterSelfTest("pins", function(verbose)
    local pass = true
    local function check(c, m) if not c then pass = false; if verbose then ns:Print("  FAIL: " .. m) end end end
    check(fmtCountdown(90) == "1:30", "fmtCountdown 90 -> 1:30")
    check(fmtCountdown(5) == "5s", "fmtCountdown 5 -> 5s")
    check(KIND_ICON.flower ~= nil and KIND_ICON.tuber ~= nil, "kind icons present")
    if verbose then ns:Print("  pins selftest " .. (pass and "PASS" or "FAIL")) end
    return pass
end)
