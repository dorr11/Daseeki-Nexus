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
-- Click matrix (owner directive 2026-07-31: SN parity — the muscle memory is
-- "left-click the ball, everyone gets invited". This is an OWNER OVERRIDE of
-- BRAND_SPEC §8's "mass-invite is NEVER an unmodified single click" law, scoped
-- to this button only; see the dated amendment in BRAND_SPEC.md §8):
--   Left            invite all online mesh characters, then raid-convert +
--                   assist-all per the global toggles (ns.Auto.InviteOnline())
--   Shift+Left      invite WITHOUT raid convert / assist-all
--                   (ns.Auto.InviteOnline(true) — same semantic as
--                    /nexus invite noconvert)
--   Right           toggle dashboard
--   Shift+Right     context menu (native dropdown):
--                     Toggle dashboard / Invite online / Timers dock /
--                     Cancel Buffs / Felwood map / Lock minimap button / Settings
--   Alt+Left        (OMITTED) /camp logout — a secure /camp macro would make
--                   this frame PROTECTED, and it is exactly that omission that
--                   keeps ring-anchoring safe. Deferred; refusal print stays.
-- Alt is tested before Shift, so any Alt+Left combination lands on the refusal.
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
-- Live world-buff text (Rend / Ony) via Timers.BuffStatus — the engine owns the
-- kill-vs-pop precedence and the 360s announcer-respawn model, so the tooltip
-- just renders the four states it reports.
----------------------------------------------------------------------

local function nowEpoch()
    if ns.Store and ns.Store.Now then return ns.Store.Now() end
    return (GetServerTime and GetServerTime()) or 0
end

local function fmtRemaining(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

-- The announcer respawn is a ~6 minute window, far below fmtRemaining's h/m
-- resolution, so the killed line gets its own M:SS formatter.
local function fmtMSS(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Map a Timers.BuffStatus readout to tooltip text + color token. Pure (the
-- self-test drives the four states through it directly).
local function statusFor(st)
    local state = st and st.state
    -- BRAND_SPEC §6: a world buff off-cooldown is green "Open" (the old
    -- pop-phrasing is retired suite-wide).
    if state == "canpop" then return "Open", "ok" end
    -- A kill is a respawn countdown, not a cooldown — amber, seconds resolution.
    if state == "killed" then return "Killed \194\183 respawns " .. fmtMSS(st.remaining), "warn" end
    if state == "cd" then
        -- pulse semantics live in the dashboard; the tooltip just states time.
        local token = ((st.remaining or 0) <= 20 * 60) and "danger" or "accent"
        return fmtRemaining(st.remaining or 0), token
    end
    return "no data", "faint"
end

-- Returns text, colorToken for a buff's state.
local function cdStatus(buffKey)
    if not (ns.Timers and ns.Timers.BuffStatus) then return "no data", "faint" end
    return statusFor(ns.Timers.BuffStatus(buffKey, nowEpoch()))
end

----------------------------------------------------------------------
-- Soft-guarded actions (parallel agents own ns.Auto / ns.UI)
----------------------------------------------------------------------

-- skipConvert=true suppresses the post-invite raid convert + assist-all pass
-- (auto.lua honours it exactly as /nexus invite noconvert does).
local function inviteAll(skipConvert)
    -- Real engine entry point is ns.Auto.InviteOnline(skipConvert) (auto.lua).
    if ns.Auto and ns.Auto.InviteOnline then
        ns.Auto.InviteOnline(skipConvert and true or nil)
    else
        ns:Print("mass invite is unavailable (auto module not loaded).")
    end
end

-- Hand-merge reconciliation: the dashboard shell registers as ns.Dashboard
-- (Toggle/Show), not the ns.UI surface this file originally guessed at.
local function toggleDashboard()
    local d = ns.Dashboard
    if d and d.Toggle then ns:SafeCall(d.Toggle); return end
    ns:Print("dashboard arrives with the UI module.")
end

-- The Timers TAB dissolved (control-panel rebuild): world-buff timers now live in
-- the lower-right DOCK of the Characters screen, so this opens the dashboard there.
local function openDashboardTimers()
    local d = ns.Dashboard
    if d and d.Show then ns:SafeCall(d.Show, "characters"); return end
    ns:Print("dashboard arrives with the UI module.")
end

local function openFelwoodMap()
    if not WorldMapFrame then return end
    if not WorldMapFrame:IsShown() then
        if ToggleWorldMap then ToggleWorldMap()
        elseif ShowUIPanel then ShowUIPanel(WorldMapFrame) end
    end
    if WorldMapFrame.SetMapID then WorldMapFrame:SetMapID(FELWOOD_MAP) end
end

local function openSettings()
    if _G.DaseekiSuite and DaseekiSuite.Open then
        DaseekiSuite:Open("nexus")
    else
        ns:Print("the Daseeki hub (Daseeki Core) is not available.")
    end
end

local function toggleLock()
    local cfg = minimapCfg()
    cfg.lock = not cfg.lock
    ns:Print(cfg.lock and "minimap button locked." or "minimap button unlocked (drag to move).")
end

----------------------------------------------------------------------
-- Right-click context menu (§8: minimap included). Native dropdown built on the
-- catalog-verified UIDropDownMenu surface (UIDropDownMenu_Initialize /
-- _CreateInfo / _AddButton / ToggleDropDownMenu). Built lazily on first use so
-- the headless harness (no dropdown globals) loads without error.
----------------------------------------------------------------------

local contextMenu

local function buildContextMenu()
    if contextMenu then return contextMenu end
    if type(UIDropDownMenu_Initialize) ~= "function" then return nil end

    contextMenu = CreateFrame("Frame", "DaseekiNexusMinimapMenu", UIParent, "UIDropDownMenuTemplate")

    local function add(level, text, fn, checked)
        local info = UIDropDownMenu_CreateInfo()
        info.text = text
        info.notCheckable = (checked == nil) and true or nil
        if checked ~= nil then
            info.isNotRadio = true
            info.checked = checked and true or false
        end
        info.func = fn
        UIDropDownMenu_AddButton(info, level)
    end

    local function separator(level)
        local info = UIDropDownMenu_CreateInfo()
        info.text = ""
        info.disabled = true
        info.notClickable = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
    end

    UIDropDownMenu_Initialize(contextMenu, function(_, level)
        if not level then return end
        local title = UIDropDownMenu_CreateInfo()
        title.text = "Daseeki Nexus"
        title.isTitle = true
        title.notCheckable = true
        UIDropDownMenu_AddButton(title, level)

        add(level, "Toggle dashboard", function() toggleDashboard() end)
        add(level, "Invite online",    function() inviteAll() end)
        add(level, "Timers dock",      function() openDashboardTimers() end)
        add(level, "Cancel Buffs",     function()
            if ns.HUD and ns.HUD.ShowCancelBuffs then ns.HUD.ShowCancelBuffs() end
        end)
        add(level, "Felwood map",      function() openFelwoodMap() end)
        separator(level)
        add(level, "Lock minimap button", function() toggleLock() end, minimapCfg().lock and true or false)
        add(level, "Settings",         function() openSettings() end)
        add(level, "Close",            function() if CloseDropDownMenus then CloseDropDownMenus() end end)
    end, "MENU")

    return contextMenu
end

local function showContextMenu(anchor)
    local menu = buildContextMenu()
    if not (menu and type(ToggleDropDownMenu) == "function") then
        ns:Print("right-click menu unavailable (dropdown API missing).")
        return
    end
    -- Anchor at the cursor so the menu opens beside the button (WoW-native).
    ToggleDropDownMenu(1, nil, menu, "cursor", 0, 0)
end

----------------------------------------------------------------------
-- Click matrix. resolveClick is PURE (no frame, no globals) so the self-test can
-- drive every modifier combination directly; OnClick only reads the live
-- modifier state and dispatches. Keeping the two apart is what makes the matrix
-- testable headlessly.
----------------------------------------------------------------------

local ACTION_INVITE      = "invite"           -- + raid convert / assist per settings
local ACTION_INVITE_ONLY = "invite_noconvert" -- invites only, no convert / assist
local ACTION_DASHBOARD   = "dashboard"
local ACTION_MENU        = "menu"
local ACTION_ALT_REFUSED = "alt_refused"

local function resolveClick(mouseButton, shift, alt)
    if mouseButton == "LeftButton" then
        -- Alt outranks Shift: the /camp slot is refused however it is decorated.
        if alt then return ACTION_ALT_REFUSED end
        if shift then return ACTION_INVITE_ONLY end
        return ACTION_INVITE
    elseif mouseButton == "RightButton" then
        if shift then return ACTION_MENU end
        return ACTION_DASHBOARD
    end
    return nil
end

local CLICK_ACTIONS = {
    [ACTION_INVITE]      = function() inviteAll(false) end,
    [ACTION_INVITE_ONLY] = function() inviteAll(true) end,
    [ACTION_DASHBOARD]   = function() toggleDashboard() end,
    [ACTION_MENU]        = function(self) showContextMenu(self) end,
    [ACTION_ALT_REFUSED] = function()
        ns:Print("Alt+Left logout is disabled this build (secure-frame safety).")
    end,
}

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
        local action = resolveClick(mouseButton, IsShiftKeyDown(), IsAltKeyDown())
        local fn = action and CLICK_ACTIONS[action]
        if fn then fn(self) end
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
        GameTooltip:AddLine("Left: invite online",             UI.Color("faint"))
        GameTooltip:AddLine("Shift-Left: invite, no convert",  UI.Color("faint"))
        GameTooltip:AddLine("Right: toggle dashboard",         UI.Color("faint"))
        GameTooltip:AddLine("Shift-Right: menu",               UI.Color("faint"))
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
    check(fmtMSS(0) == "0:00", "fmtMSS zero")
    check(fmtMSS(59) == "0:59", "fmtMSS sub-minute pads seconds")
    check(fmtMSS(365) == "6:05", "fmtMSS M:SS")
    local t, tok = cdStatus("rend")
    check(type(t) == "string" and type(tok) == "string", "cdStatus returns text+token")
    -- Four-state readout matrix (Timers.BuffStatus -> tooltip line).
    t, tok = statusFor(nil)
    check(t == "no data" and tok == "faint", "no status -> no data / faint")
    t, tok = statusFor({ state = "nodata" })
    check(t == "no data" and tok == "faint", "nodata -> no data / faint")
    t, tok = statusFor({ state = "canpop" })
    check(t == "Open" and tok == "ok", "canpop -> Open / ok (BRAND_SPEC 6)")
    t, tok = statusFor({ state = "killed", remaining = 125 })
    check(t == "Killed \194\183 respawns 2:05" and tok == "warn", "killed -> respawn M:SS / warn")
    t, tok = statusFor({ state = "cd", remaining = 20 * 60 })
    check(t == "20m" and tok == "danger", "cd at 20m -> danger")
    t, tok = statusFor({ state = "cd", remaining = 3 * 3600 })
    check(t == "3h 00m" and tok == "accent", "cd above 20m -> accent")

    -- Click matrix (owner directive 2026-07-31, SN parity). Left is the invite;
    -- the dashboard lives on right-click. Every case below is a shipped binding.
    check(resolveClick("LeftButton",  false, false) == ACTION_INVITE,
          "Left -> invite online (convert per settings)")
    check(resolveClick("LeftButton",  true,  false) == ACTION_INVITE_ONLY,
          "Shift+Left -> invite without raid convert / assist")
    check(resolveClick("RightButton", false, false) == ACTION_DASHBOARD,
          "Right -> toggle dashboard")
    check(resolveClick("RightButton", true,  false) == ACTION_MENU,
          "Shift+Right -> context menu")
    check(resolveClick("LeftButton",  false, true) == ACTION_ALT_REFUSED,
          "Alt+Left -> refusal print (secure-frame safety)")
    check(resolveClick("LeftButton",  true,  true) == ACTION_ALT_REFUSED,
          "Alt outranks Shift on the left button")
    check(resolveClick("RightButton", false, true) == ACTION_DASHBOARD,
          "Alt+Right is unbound -> plain right-click behavior")
    check(resolveClick("MiddleButton", false, false) == nil,
          "no other mouse button is bound")
    for _, act in ipairs({ ACTION_INVITE, ACTION_INVITE_ONLY, ACTION_DASHBOARD,
                           ACTION_MENU, ACTION_ALT_REFUSED }) do
        check(type(CLICK_ACTIONS[act]) == "function", "click action wired: " .. act)
    end
    if verbose then ns:Print("  minimap selftest " .. (pass and "PASS" or "FAIL")) end
    return pass
end)
