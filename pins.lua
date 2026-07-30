-- Daseeki Nexus — pins.lua
-- Felwood songflower / tuber node pins on the world map and minimap, driven by
-- Timers.NODES (16 fixed nodes) + the NODE_UPDATED callback.
--
-- Map-pin strategy (decision): own minimal placement, NOT a vendored map lib.
-- The node set is fixed (10 flowers + 6 tubers on one zone, uiMap 1448), so a
-- self-contained C_Map placement is smaller than vendoring HereBeDragons +
-- CallbackHandler and adds no cross-agent toc/lib merge surface.
--   World-map pins use exact C_Map canvas coordinates (already correct).
--   Minimap pins now use a PROPER world projection (R2-c): each node's fixed
--   normalized map position is converted to continent/world yards ONCE via
--   C_Map.GetWorldPosFromMapPos; the player's world position is converted each
--   refresh; the world-space delta is scaled to minimap pixels by the live
--   zoom radius. This is correct at every zoom level (replacing the old planar
--   normalized-scale approximation) and handles a rotating minimap via
--   GetPlayerFacing. Projection math is fresh HereBeDragons-style geometry, no
--   third-party code.
--
-- Clean-room build: functional reimplementation from spec; no third-party code.

local ADDON, ns = ...

local UI = DaseekiUI

local Pins = {}
ns.Pins = Pins

local FELWOOD_MAP = 1448
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- Node kind presentation. Icons are Blizzard built-ins (a missing path renders
-- blank, never an error).
local KIND_ICON = {
    flower = "Interface\\Icons\\INV_Misc_Herb_Fellotus",
    tuber  = "Interface\\Icons\\INV_Misc_Food_59",
}

local function fmtCountdown(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    if sec >= 60 then
        return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
    end
    return sec .. "s"
end

----------------------------------------------------------------------
-- Pure minimap projection (registered ABOVE the DaseekiUI guard so the
-- fixture self-test runs headless).
--
-- WoW world/continent coordinates (as returned by GetWorldPosFromMapPos):
--   worldX increases toward NORTH, worldY increases toward WEST.
-- The north-up minimap has +x = EAST (right), +y = NORTH (up). So for a node
-- relative to the player:
--   eastPixels  = (playerWorldY - nodeWorldY) * pixelsPerYard   (west is -x)
--   northPixels = (nodeWorldX  - playerWorldX) * pixelsPerYard   (north is +y)
-- A rotating minimap puts the player's facing at the top: rotate the (E,N)
-- vector by GetPlayerFacing (radians, CCW from north).
----------------------------------------------------------------------

local MINIMAP_YARDS_OUTDOOR = {
    [0] = 466 + 2/3, [1] = 400, [2] = 333 + 1/3, [3] = 266 + 2/3, [4] = 200, [5] = 133 + 1/3,
}
local MINIMAP_YARDS_INDOOR = {
    [0] = 300, [1] = 240, [2] = 180, [3] = 120, [4] = 80, [5] = 50,
}

-- world coords -> minimap pixel offset (dx east+, dy north+). Pure; the caller
-- supplies pixelsPerYard (from the live minimap zoom) and an optional facing.
function Pins._ProjectMinimap(pWX, pWY, nWX, nWY, pixelsPerYard, facing)
    local E = (pWY - nWY) * pixelsPerYard   -- east pixels (+right)
    local N = (nWX - pWX) * pixelsPerYard   -- north pixels (+up)
    facing = facing or 0
    if facing ~= 0 then
        local cs, sn = math.cos(facing), math.sin(facing)
        E, N = E * cs + N * sn, -E * sn + N * cs
    end
    return E, N
end

-- Self-test: pure geometry helpers + minimap projection fixture (headless).
ns:RegisterSelfTest("pins", function(verbose)
    local pass = true
    local function check(c, m) if not c then pass = false; if verbose then ns:Print("  FAIL: " .. m) end end end
    check(fmtCountdown(90) == "1:30", "fmtCountdown 90 -> 1:30")
    check(fmtCountdown(5) == "5s", "fmtCountdown 5 -> 5s")
    check(KIND_ICON.flower ~= nil and KIND_ICON.tuber ~= nil, "kind icons present")

    -- Projection: fixture world coords -> expected minimap offsets (north-up).
    -- player @ (0,0); node 100yd north (worldX+100) and 100yd east (worldY-100),
    -- at 0.5 px/yd -> (+50 right, +50 up).
    local dx, dy = Pins._ProjectMinimap(0, 0, 100, -100, 0.5, 0)
    check(math.abs(dx - 50) < 1e-6 and math.abs(dy - 50) < 1e-6, "projection north-up fixture")
    -- Axis sanity: node due east -> +x only; node due north -> +y only.
    local ex, ey = Pins._ProjectMinimap(0, 0, 0, -100, 1, 0)
    check(ex > 0 and math.abs(ey) < 1e-6, "east node -> +x")
    local nx, ny = Pins._ProjectMinimap(0, 0, 100, 0, 1, 0)
    check(ny > 0 and math.abs(nx) < 1e-6, "north node -> +y")
    -- Rotation: facing 90deg (pi/2) rotates the (E,N)=(50,50) vector to (50,-50).
    local rx, ry = Pins._ProjectMinimap(0, 0, 100, -100, 0.5, math.pi / 2)
    check(math.abs(rx - 50) < 1e-4 and math.abs(ry + 50) < 1e-4, "projection rotated 90deg")

    if verbose then ns:Print("  pins selftest " .. (pass and "PASS" or "FAIL")) end
    return pass
end)

----------------------------------------------------------------------
-- Everything below needs DaseekiUI (tokens/widgets). Degrade to the pure
-- surface above if Core is absent (HUD.lua already surfaces the notice).
----------------------------------------------------------------------
if type(UI) ~= "table" or type(UI.Color) ~= "function" then
    return
end

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
-- World-map pin countdown font size, pt (round-12 restore 3a: the options slider
-- writes felwood.worldTimerFont but nothing read it — the pin timer used a fixed
-- font object). Clamped to the slider's 6-20 range; default 10.
local function worldTimerFont()
    local v = felwoodCfg().worldTimerFont
    if type(v) == "number" and v >= 6 and v <= 20 then return v end
    return 10
end

----------------------------------------------------------------------
-- Node state colouring (via Timers)
--   up      -> available now (green / ok)
--   down    -> respawning (amber / warn), world pin shows countdown
--   unknown -> no data (faint)
----------------------------------------------------------------------

local function nodeState(kind, index)
    if ns.Timers and ns.Timers.GetNodeState then
        return ns.Timers.GetNodeState(kind .. index)
    end
    return { state = "unknown", remaining = 0 }
end

-- Respawning ("down") pins tint amber via Core's `warn` token; fall back to the
-- historical literal on an older Core that predates the token (UI.Color yields
-- white for an unknown token, so detect presence via UI.Token).
local WARN_RGB = { 0.96, 0.76, 0.18 }
local function warnColor()
    if UI.Token and type(UI.Token("warn")) == "table" then return UI.Color("warn") end
    return WARN_RGB[1], WARN_RGB[2], WARN_RGB[3], 1
end

-- BRAND_SPEC §5: pins are a diamond BACKING (state-tinted) with a PLAIN icon on
-- top — the icon is never masked (masked-icon diamonds are >=24px hero spots
-- only, never repeated). State tint lives on the backing, icon stays legible.
local function tintPin(pin, state)
    local back = pin._back
    if not back then return end
    if state == "up" then
        back:SetVertexColor(UI.Color("ok"))
    elseif state == "down" then
        back:SetVertexColor(warnColor())
    else
        back:SetVertexColor(UI.Color("faint"))
    end
end

-- Shared pin styling: a rotated-square diamond backing on BACKGROUND (tinted by
-- state) + a plain square icon on ARTWORK above it. `sz` is the pin box size;
-- the diamond side is sized so its diagonal ~= the box (points reach the edges)
-- and the icon sits centered inside, unmasked.
local function stylePin(pin, kind, sz)
    local back = pin._back
    if not back then
        back = pin:CreateTexture(nil, "BACKGROUND")
        back:SetTexture(WHITE)
        back:SetRotation(math.rad(45))
        back:SetPoint("CENTER", pin, "CENTER", 0, 0)
        pin._back = back
    end
    back:SetSize(sz * 0.72, sz * 0.72)

    local tex = pin._tex
    if not tex then
        tex = pin:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("CENTER", pin, "CENTER", 0, 0)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        pin._tex = tex
    end
    tex:SetTexture(KIND_ICON[kind])
    tex:SetSize(sz * 0.58, sz * 0.58)
end

----------------------------------------------------------------------
-- World-map pins
--
-- Parented to the WorldMapFrame canvas; shown only while the displayed map is
-- Felwood. Positioned by exact normalized node coords × canvas size (already
-- correct — normalized placement is kept verbatim).
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
    stylePin(pin, kind, sz)

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
                    stylePin(pin, kind, sz)
                    -- Apply the configured world-map timer font size (restore 3a); cached
                    -- so SetFont only runs when the slider value actually changes.
                    local fsz = worldTimerFont()
                    if pin._timerSz ~= fsz then
                        local face, _, fl = pin._timer:GetFont()
                        if face then pin._timer:SetFont(face, fsz, fl); pin._timerSz = fsz end
                    end
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", canvas, "TOPLEFT", node.x * cw, -node.y * ch)
                    local st = nodeState(kind, index)
                    tintPin(pin, st.state)
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
-- Minimap pins — proper world projection (R2-c). Pixels-per-yard from the live
-- minimap zoom (outdoor table: Felwood pins only ever render in the outdoor
-- world zone; the indoor table is kept for defensive completeness).
----------------------------------------------------------------------

local minimapPins = {}
local nodeWorld   = {}   -- "kind"..index -> {wx, wy}, computed once (nodes are fixed)

-- Live pixels-per-yard from the current minimap zoom. nil if unresolvable.
local function minimapPixelsPerYard()
    local w = (Minimap and Minimap.GetWidth and Minimap:GetWidth()) or 140
    local zoom = (Minimap and Minimap.GetZoom and Minimap:GetZoom()) or 0
    local indoors = IsInInstance and IsInInstance()
    local tbl = indoors and MINIMAP_YARDS_INDOOR or MINIMAP_YARDS_OUTDOOR
    local diameter = tbl[zoom] or tbl[0]
    if not diameter or diameter <= 0 or not w or w <= 0 then return nil end
    return w / diameter
end

-- Resolve the projection facing. Returns (facing, ok):
--   north-up             -> (0, true)
--   rotating + facing     -> (facing, true)
--   rotating, no facing   -> (nil, false)  [cannot project; caller hides pins]
local function minimapProjectionFacing()
    local rotating = GetCVar and GetCVar("rotateMinimap") == "1"
    if rotating then
        if GetPlayerFacing then return GetPlayerFacing() or 0, true end
        return nil, false
    end
    return 0, true
end

-- Continent/world position of a fixed node — computed once and cached.
local function nodeWorldPos(kind, index, node)
    local key = kind .. index
    local cached = nodeWorld[key]
    if cached then return cached[1], cached[2] end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local _, wpos = C_Map.GetWorldPosFromMapPos(FELWOOD_MAP, CreateVector2D(node.x, node.y))
    if not wpos then return nil end
    local wx, wy = wpos:GetXY()
    if not wx then return nil end
    nodeWorld[key] = { wx, wy }
    return wx, wy
end

-- Continent/world position of the player, recomputed each refresh.
local function playerWorldPos()
    if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetPlayerMapPosition) then return nil end
    local mpos = C_Map.GetPlayerMapPosition(FELWOOD_MAP, "player")
    if not mpos then return nil end
    local _, wpos = C_Map.GetWorldPosFromMapPos(FELWOOD_MAP, mpos)
    if not wpos then return nil end
    return wpos:GetXY()
end

local function ensureMinimapPin(kind, index, node)
    local key = kind .. index
    local pin = minimapPins[key]
    if pin then return pin end
    pin = CreateFrame("Frame", nil, Minimap)
    local sz = minimapPinSize()
    pin:SetSize(sz, sz)
    pin:SetFrameStrata("HIGH")
    stylePin(pin, kind, sz)
    minimapPins[key] = pin
    return pin
end

local function hideAllMinimapPins()
    for _, p in pairs(minimapPins) do p:Hide() end
end

local function refreshMinimapPins()
    if not Minimap then return end
    -- Only in Felwood.
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID ~= FELWOOD_MAP then
        hideAllMinimapPins()
        return
    end
    -- Projection facing (handles rotating minimap; hides if unresolvable).
    local facing, projOK = minimapProjectionFacing()
    if not projOK then
        hideAllMinimapPins()
        return
    end
    local ppy = minimapPixelsPerYard()
    if not ppy then
        hideAllMinimapPins()
        return
    end
    local pWX, pWY = playerWorldPos()
    if not pWX then
        hideAllMinimapPins()
        return
    end

    local radius = ((Minimap.GetWidth and Minimap:GetWidth()) or 140) / 2
    local nodes = ns.Timers and ns.Timers.NODES
    if not nodes then return end

    for kind, list in pairs(nodes) do
        for index = 1, #list do
            local node = list[index]
            if kindEnabled(kind) then
                local pin = ensureMinimapPin(kind, index, node)
                local sz = minimapPinSize()
                pin:SetSize(sz, sz)
                stylePin(pin, kind, sz)
                local nWX, nWY = nodeWorldPos(kind, index, node)
                if nWX then
                    local dx, dy = Pins._ProjectMinimap(pWX, pWY, nWX, nWY, ppy, facing)
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist <= radius then
                        pin:ClearAllPoints()
                        pin:SetPoint("CENTER", Minimap, "CENTER", dx, dy)
                        tintPin(pin, nodeState(kind, index).state)
                        pin:Show()
                    else
                        pin:Hide()   -- outside the minimap view
                    end
                else
                    pin:Hide()       -- projection API unavailable / node not resolvable
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
