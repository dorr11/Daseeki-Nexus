-- Daseeki Nexus — minimap.lua
-- Minimap launcher button with TWO backends and one shared brain.
--
-- BACKEND 1 (preferred): LibDBIcon-1.0, when some other installed addon has
-- already embedded it (BugSack, Details, WeakAuras, Questie, DBM, Bartender4 …
-- all do). We do NOT vendor the library: LibDBIcon is GPLv2-or-later (see its
-- upstream header / its .toc "X-License: GPLv2 or later"), and Daseeki-Nexus
-- ships only permissive libs. So we CONSUME it opportunistically via
-- LibStub("LibDBIcon-1.0", true) and never redistribute it.
--   Why this matters (owner symptom 2026-07-31): minimap-button managers such as
--   Leatrix Plus intercept unrecognised custom buttons and replace their tooltip
--   with "This is a custom button. Please ask the addon author to use the
--   standard LibDBIcon library instead", swallowing our tooltip and clicks.
--   Registering through LibDBIcon puts us in the collectors' managed lists and
--   our own tooltip/clicks survive.
--   Note lib:Register only asserts object.icon — it does NOT require the object
--   be registered with LibDataBroker — so the data object below is LDB-SHAPED
--   but needs no LDB dependency of its own.
--
-- BACKEND 2 (fallback): the original custom ring-anchored button, unchanged.
-- It runs only when no LibDBIcon is present anywhere in the client — and in that
-- situation, by definition, no LibDBIcon-based button manager is loaded either,
-- so the interception symptom that motivated this migration cannot occur on the
-- fallback path. It stays as the clean-install path.
--
-- Position: the lib backend stores its angle in settings.minimap.libIcon
-- (LibDBIcon's own db shape: minimapPos/hide/lock) and is SEEDED ONCE from the
-- custom path's settings.minimap.angle, so the button stays exactly where the
-- owner dragged it. settings.minimap.angle is never written by the migration —
-- the fallback keeps its own position intact.
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
--                   this frame PROTECTED. Deferred; refusal print stays.
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

-- LibDBIcon registration name. This is the string collectors/managers display,
-- so it is the addon's public button identity.
local ICON_NAME = "DaseekiNexus"
local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Net_01"

local BACKEND_LIB   = "lib"
local BACKEND_FRAME = "frame"

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
-- Ring position math (angle -> x,y offset from Minimap center). FALLBACK PATH
-- ONLY — when LibDBIcon is driving, the library owns positioning entirely.
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

-- Forward declaration: toggleLock re-applies state, which needs the backend
-- router defined further down.
local applyState

local function toggleLock()
    local cfg = minimapCfg()
    cfg.lock = not cfg.lock
    if applyState then applyState() end
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
-- drive every modifier combination directly; sharedOnClick reads the live
-- modifier state and dispatches. BOTH backends install sharedOnClick verbatim —
-- LibDBIcon calls it as OnClick(frame, mouseButton) and the fallback frame calls
-- it as its OnClick script with the same signature — so the matrix below is the
-- single source of truth for click behaviour on either path.
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

-- dryRun / explicit modifiers exist so the self-test can drive the real dispatch
-- path without touching Blizzard's modifier globals and without firing invites.
local function dispatchClick(self, mouseButton, dryRun, shift, alt)
    if shift == nil then
        shift = (IsShiftKeyDown and IsShiftKeyDown()) and true or false
        alt   = (IsAltKeyDown   and IsAltKeyDown())   and true or false
    end
    local action = resolveClick(mouseButton, shift, alt)
    if not action then return nil end
    if not dryRun then
        local fn = CLICK_ACTIONS[action]
        if fn then fn(self) end
    end
    return action
end

-- The one handler both backends install.
local function sharedOnClick(self, mouseButton)
    return dispatchClick(self, mouseButton)
end

----------------------------------------------------------------------
-- Tooltip. buildTooltipModel takes its settings by argument and returns a plain
-- description of the tooltip; renderTooltip writes that model into WHATEVER
-- tooltip frame it is handed. LibDBIcon passes its OWN tooltip frame
-- (LibDBIconTooltip) to OnTooltipShow — not GameTooltip — so the renderer must
-- never reach for a global tooltip. The fallback path hands it GameTooltip.
-- Same model, same lines, both backends.
----------------------------------------------------------------------

local function buildTooltipModel(cfg)
    cfg = cfg or minimapCfg()
    local rendT, rendC = cdStatus("rend")
    local onyAT, onyAC = cdStatus("onyA")
    local onyHT, onyHC = cdStatus("onyH")

    local model = {
        { k = "line",   text  = "Daseeki Nexus",                 color = "accent" },
        { k = "double", left = "Rend",    right = rendT, color = "muted", token = rendC },
        { k = "double", left = "Ony (A)", right = onyAT, color = "muted", token = onyAC },
        { k = "double", left = "Ony (H)", right = onyHT, color = "muted", token = onyHC },
        { k = "blank" },
        { k = "line",   text = "Left: invite online",            color = "faint" },
        { k = "line",   text = "Shift-Left: invite, no convert", color = "faint" },
        { k = "line",   text = "Right: toggle dashboard",        color = "faint" },
        { k = "line",   text = "Shift-Right: menu",              color = "faint" },
    }
    if not cfg.lock then
        model[#model + 1] = { k = "line", text = "Drag to move", color = "faint" }
    end
    return model
end

local function renderTooltip(tt, model)
    if not tt then return end
    model = model or buildTooltipModel()
    for _, e in ipairs(model) do
        if e.k == "double" then
            tt:AddDoubleLine(e.left, e.right, UI.Color(e.color))
        elseif e.k == "blank" then
            tt:AddLine(" ")
        else
            tt:AddLine(e.text, UI.Color(e.color))
        end
    end
end

-- LibDBIcon's OnTooltipShow contract: it has already set the owner, anchored and
-- cleared the frame, and it calls tt:Show() afterwards. We only add lines.
local function sharedOnTooltipShow(tt)
    renderTooltip(tt, buildTooltipModel())
end

----------------------------------------------------------------------
-- BACKEND 1 — LibDBIcon
----------------------------------------------------------------------

local iconLib          -- the live LibDBIcon handle, once registered
local backend          -- BACKEND_LIB | BACKEND_FRAME

local function getIconLib()
    if not _G.LibStub then return nil end
    local ok, lib = pcall(LibStub, "LibDBIcon-1.0", true)
    if ok then return lib end
    return nil
end

-- Pure backend decision, so the self-test can assert both arms.
local function chooseBackend(lib)
    if lib and type(lib.Register) == "function" then return BACKEND_LIB end
    return BACKEND_FRAME
end

-- One-time settings migration into LibDBIcon's db shape. IDEMPOTENT: minimapPos
-- is seeded from the custom path's angle only when it has never been set, so the
-- button lands exactly where the owner dragged it and LibDBIcon's own drag
-- writes win thereafter. settings.minimap.angle is deliberately left untouched —
-- the fallback path keeps its position if the lib ever disappears.
local function migrateLibDB(cfg)
    cfg = cfg or minimapCfg()
    local db = cfg.libIcon
    if type(db) ~= "table" then
        db = {}
        cfg.libIcon = db
    end
    if type(db.minimapPos) ~= "number" then
        db.minimapPos = tonumber(cfg.angle) or DEFAULT_ANGLE
    end
    -- hide/lock stay slaved to the settings keys the options checkboxes write.
    db.hide = cfg.hide and true or false
    db.lock = cfg.lock and true or false
    return db
end

local function buildDataObject()
    -- LDB launcher shape, handed straight to LibDBIcon (no LibDataBroker
    -- dependency — lib:Register only requires .icon).
    return {
        type          = "launcher",
        label         = "Daseeki Nexus",
        text          = "Daseeki Nexus",
        icon          = ICON_TEXTURE,
        OnClick       = sharedOnClick,
        OnTooltipShow = sharedOnTooltipShow,
    }
end

local function applyLibState(lib, cfg)
    cfg = cfg or minimapCfg()
    local db = migrateLibDB(cfg)
    if cfg.hide then lib:Hide(ICON_NAME) else lib:Show(ICON_NAME) end
    if cfg.lock then lib:Lock(ICON_NAME) else lib:Unlock(ICON_NAME) end
    return db
end

local function registerWithLib(lib, cfg)
    cfg = cfg or minimapCfg()
    local db  = migrateLibDB(cfg)
    local obj = buildDataObject()
    if not (lib.IsRegistered and lib:IsRegistered(ICON_NAME)) then
        lib:Register(ICON_NAME, obj, db)
    end
    applyLibState(lib, cfg)
    return obj, db
end

-- LibDBIcon renders OnTooltipShow ONCE, on enter — it has no re-show timer, so
-- the world-buff countdowns would freeze while the cursor rests on the button.
-- This adds a 1s re-render that does NOT fight the library: we only hook
-- (additively) the button's OnEnter/OnLeave and, between them, re-fill the
-- library's own tooltip frame with ClearLines + our model. Owner, anchor and
-- lifecycle stay entirely the library's. If the hooks are unavailable we simply
-- accept render-on-enter.
local ttDriver

local function startTooltipTicker(lib)
    if not (lib.GetMinimapButton and CreateFrame) then return false end
    local btn = lib:GetMinimapButton(ICON_NAME)
    if not (btn and type(btn.HookScript) == "function") then return false end

    ttDriver = ttDriver or CreateFrame("Frame")
    local accum = 0

    btn:HookScript("OnEnter", function()
        accum = 0
        ttDriver:SetScript("OnUpdate", function(_, elapsed)
            accum = accum + (elapsed or 0)
            if accum < 1 then return end
            accum = 0
            local tt = lib.tooltip
            if tt and tt.IsShown and tt:IsShown() and tt.ClearLines then
                tt:ClearLines()
                renderTooltip(tt, buildTooltipModel())
                tt:Show()
            end
        end)
    end)
    btn:HookScript("OnLeave", function()
        ttDriver:SetScript("OnUpdate", nil)
    end)
    return true
end

----------------------------------------------------------------------
-- BACKEND 2 — the original custom button (clean-install fallback; behaviour
-- unchanged. Its tooltip body now goes through the shared renderer so both
-- backends are guaranteed to show identical lines).
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
    icon:SetTexture(ICON_TEXTURE)
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

    b:SetScript("OnClick", sharedOnClick)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        renderTooltip(GameTooltip, buildTooltipModel())
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

----------------------------------------------------------------------
-- Backend router + public API (Button.Toggle / Button.Refresh unchanged for
-- callers; they now drive whichever backend is live).
----------------------------------------------------------------------

-- (declared local above, assigned here so toggleLock can reach it)
function applyState()
    local cfg = minimapCfg()
    if backend == BACKEND_LIB and iconLib then
        ns:SafeCall(applyLibState, iconLib, cfg)
        return
    end
    if not button then return end
    updatePosition(button, cfg.angle or DEFAULT_ANGLE)
    if cfg.hide then button:Hide() else button:Show() end
end

function Button.Refresh() applyState() end

function Button.Toggle()
    local cfg = minimapCfg()
    cfg.hide = not cfg.hide
    applyState()
end

-- Diagnostics / release beacon: which path is live this session.
function Button.Backend() return backend end

----------------------------------------------------------------------
-- Settings observer. options.lua's "Show minimap button" / "Lock button
-- position" checkboxes write DaseekiNexusDB.minimap.hide / .lock directly and
-- call nothing back — so this module WATCHES those two keys rather than
-- requiring an options.lua edit. Half-second poll, two boolean compares, and it
-- only touches the backend when a value actually changed.
----------------------------------------------------------------------

local observer, lastHide, lastLock

local function startSettingsObserver()
    if not CreateFrame then return end
    observer = observer or CreateFrame("Frame")
    local cfg = minimapCfg()
    lastHide = cfg.hide and true or false
    lastLock = cfg.lock and true or false
    local accum = 0
    observer:SetScript("OnUpdate", function(_, elapsed)
        accum = accum + (elapsed or 0)
        if accum < 0.5 then return end
        accum = 0
        local c = minimapCfg()
        local h = c.hide and true or false
        local l = c.lock and true or false
        if h ~= lastHide or l ~= lastLock then
            lastHide, lastLock = h, l
            applyState()
        end
    end)
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------

ns:On("LOGIN", function()
    local lib = getIconLib()
    local ok  = false

    if chooseBackend(lib) == BACKEND_LIB then
        ok = pcall(registerWithLib, lib, minimapCfg())
        if ok then
            iconLib = lib
            backend = BACKEND_LIB
            pcall(startTooltipTicker, lib)
        end
    end

    if not ok then
        -- No LibDBIcon anywhere in the client (or it refused us): run the
        -- original custom button. No LibDBIcon also means no LibDBIcon-based
        -- button manager is loaded, so the interception symptom cannot arise.
        backend = BACKEND_FRAME
        if not button then button = buildButton() end
    end

    ns:SafeCall(applyState)
    ns:SafeCall(startSettingsObserver)
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

    ------------------------------------------------------------------
    -- Backend selection (LibDBIcon present vs absent).
    ------------------------------------------------------------------
    check(chooseBackend(nil) == BACKEND_FRAME,
          "no LibDBIcon -> custom-button fallback backend")
    check(chooseBackend({}) == BACKEND_FRAME,
          "a LibDBIcon-shaped table without Register is not usable")
    check(chooseBackend({ Register = function() end }) == BACKEND_LIB,
          "LibDBIcon present -> library backend")

    ------------------------------------------------------------------
    -- Settings migration: minimap {hide, lock, angle} -> LibDBIcon db shape.
    ------------------------------------------------------------------
    local cfg = { angle = 137, hide = true, lock = true }
    local db  = migrateLibDB(cfg)
    check(db.minimapPos == 137, "migration seeds minimapPos from the dragged angle")
    check(db.hide == true and db.lock == true, "migration passes hide/lock through")
    check(cfg.angle == 137, "migration never destroys the fallback path's angle")
    check(cfg.libIcon == db, "migrated db is persisted on settings.minimap.libIcon")
    -- Idempotent: a later drag moved the lib button; re-running must not reseed.
    db.minimapPos = 42
    local db2 = migrateLibDB(cfg)
    check(db2 == db and db.minimapPos == 42,
          "re-migration keeps LibDBIcon's own position (one-time seed only)")
    -- No stored angle at all -> the default ring slot.
    local fresh = migrateLibDB({})
    check(fresh.minimapPos == DEFAULT_ANGLE, "no saved angle -> DEFAULT_ANGLE")
    check(fresh.hide == false and fresh.lock == false, "fresh db defaults to shown+unlocked")

    ------------------------------------------------------------------
    -- Registration against a fake LibDBIcon: correct name, LDB-shaped object,
    -- migrated db handed to the lib, hide/lock routed through the lib API.
    ------------------------------------------------------------------
    local function fakeLib()
        local L = { calls = {}, registered = false }
        function L:Register(name, obj, d)
            self.calls[#self.calls + 1] = "Register"
            self.name, self.obj, self.db, self.registered = name, obj, d, true
        end
        function L:IsRegistered(name) return self.registered and self.name == name end
        function L:Hide()   self.calls[#self.calls + 1] = "Hide";   self.hidden = true  end
        function L:Show()   self.calls[#self.calls + 1] = "Show";   self.hidden = false end
        function L:Lock()   self.calls[#self.calls + 1] = "Lock";   self.locked = true  end
        function L:Unlock() self.calls[#self.calls + 1] = "Unlock"; self.locked = false end
        return L
    end

    local L = fakeLib()
    local scfg = { angle = 90, hide = false, lock = false }
    local obj, rdb = registerWithLib(L, scfg)
    check(L.registered and L.name == ICON_NAME,
          "registers under the public button name \"" .. ICON_NAME .. "\"")
    check(L.obj == obj and L.db == rdb, "the migrated db + data object reach the lib")
    check(rdb.minimapPos == 90, "registration carries the migrated position")
    check(obj.icon == ICON_TEXTURE, "data object carries our icon (lib:Register requires it)")
    check(obj.type == "launcher", "data object is LDB launcher-shaped")
    check(obj.OnClick == sharedOnClick, "LDB backend drives the SHARED click handler")
    check(obj.OnTooltipShow == sharedOnTooltipShow, "LDB backend drives the SHARED tooltip")
    check(L.hidden == false and L.locked == false, "shown+unlocked routed to the lib")
    -- Re-register must not double-register; state still re-applies.
    scfg.hide, scfg.lock = true, true
    registerWithLib(L, scfg)
    local registerCalls = 0
    for _, c in ipairs(L.calls) do if c == "Register" then registerCalls = registerCalls + 1 end end
    check(registerCalls == 1, "already-registered button is never registered twice")
    check(L.hidden == true and L.locked == true,
          "checkbox writes to minimap.hide/.lock route through lib:Hide/lib:Lock")

    ------------------------------------------------------------------
    -- Click matrix driven through the REAL dispatcher both backends install.
    ------------------------------------------------------------------
    local function click(btn, shift, alt) return dispatchClick(nil, btn, true, shift, alt) end
    check(click("LeftButton",   false, false) == ACTION_INVITE,      "dispatch: Left -> invite")
    check(click("LeftButton",   true,  false) == ACTION_INVITE_ONLY, "dispatch: Shift+Left -> invite, no convert")
    check(click("RightButton",  false, false) == ACTION_DASHBOARD,   "dispatch: Right -> dashboard")
    check(click("RightButton",  true,  false) == ACTION_MENU,        "dispatch: Shift+Right -> menu")
    check(click("LeftButton",   false, true)  == ACTION_ALT_REFUSED, "dispatch: Alt+Left -> refusal")
    check(click("MiddleButton", false, false) == nil,                "dispatch: unbound button -> nil")

    ------------------------------------------------------------------
    -- Tooltip content, rendered through the LDB OnTooltipShow callback into a
    -- recording tooltip (proves the lib backend emits our lines into the frame
    -- the library hands us, not GameTooltip).
    ------------------------------------------------------------------
    local function recorder()
        local r = { lines = {} }
        function r:AddLine(text) self.lines[#self.lines + 1] = { k = "line", text = text } end
        function r:AddDoubleLine(l, rt) self.lines[#self.lines + 1] = { k = "double", left = l, right = rt } end
        function r:ClearLines() self.lines = {} end
        function r:Show() self.shown = true end
        return r
    end

    local rec = recorder()
    sharedOnTooltipShow(rec)
    local L1 = rec.lines
    check(L1[1] and L1[1].k == "line" and L1[1].text == "Daseeki Nexus", "tooltip header")
    check(L1[2] and L1[2].k == "double" and L1[2].left == "Rend",    "tooltip Rend doubleline")
    check(L1[3] and L1[3].k == "double" and L1[3].left == "Ony (A)", "tooltip Ony (A) doubleline")
    check(L1[4] and L1[4].k == "double" and L1[4].left == "Ony (H)", "tooltip Ony (H) doubleline")
    check(L1[5] and L1[5].k == "line" and L1[5].text == " ",         "tooltip blank separator")
    check(L1[6] and L1[6].text == "Left: invite online",             "tooltip hint 1")
    check(L1[7] and L1[7].text == "Shift-Left: invite, no convert",  "tooltip hint 2")
    check(L1[8] and L1[8].text == "Right: toggle dashboard",         "tooltip hint 3")
    check(L1[9] and L1[9].text == "Shift-Right: menu",               "tooltip hint 4")

    -- Drag hint is conditional on the lock setting, on BOTH backends.
    local unlocked = buildTooltipModel({ lock = false })
    check(unlocked[#unlocked].text == "Drag to move", "unlocked -> \"Drag to move\" hint")
    local locked = buildTooltipModel({ lock = true })
    check(locked[#locked].text == "Shift-Right: menu", "locked -> no drag hint")
    check(#unlocked == #locked + 1, "the drag hint is the only lock-dependent line")

    -- The fallback path renders the SAME model through the SAME renderer, so a
    -- recorder fed that model must match the lib path line-for-line.
    local rec2 = recorder()
    renderTooltip(rec2, buildTooltipModel())
    check(#rec2.lines == #L1, "fallback renderer emits the same line count as the lib path")
    local sameLines = true
    for i = 1, #L1 do
        local a, b = L1[i], rec2.lines[i]
        if not b or a.k ~= b.k or a.text ~= b.text or a.left ~= b.left then sameLines = false end
    end
    check(sameLines, "both backends render identical tooltip lines")

    -- ClearLines + re-render is exactly what the 1s mid-hover refresh does.
    rec2:ClearLines()
    check(#rec2.lines == 0, "recorder clears")
    renderTooltip(rec2, buildTooltipModel())
    check(#rec2.lines == #L1, "mid-hover refresh re-renders a full tooltip")

    if verbose then ns:Print("  minimap selftest " .. (pass and "PASS" or "FAIL")) end
    return pass
end)
