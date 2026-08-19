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
--   Left            invite all online mesh characters, then raid-convert per the
--                   global toggles (ns.Auto.InviteOnline()). This click is also
--                   what ARMS the mesh-assembly gate — see auto.lua's gate block;
--                   nothing else in the addon may act on a roster change.
--   Shift+Left      invite WITHOUT raid convert (and without arming)
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
        -- F-KILL: the same rule the dashboard row uses. A cooldown longer than the
        -- respawn keeps `state` at "cd" (F3), so without this the minimap tooltip
        -- silently omitted a kill that had in fact been detected and recorded.
        if st.killActive then
            return "Killed \194\183 respawns " .. fmtMSS(st.killRemaining or 0)
                   .. " \194\183 CD " .. fmtRemaining(st.remaining or 0), "warn"
        end
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

-- skipConvert=true suppresses the post-invite raid convert pass AND leaves the
-- mesh-assembly gate disarmed (auto.lua honours it exactly as
-- /nexus invite noconvert does).
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

----------------------------------------------------------------------
-- The "Instances" section — the rolling 5/hr picture, rendered BELOW the world
-- buff timers as its own block.
--
-- This is a PURE READ over data instances.lua already owns. Nothing here detects,
-- records, prunes or merges an instance entry: entry detection (PLAYER_ENTERING_WORLD
-- -> IsInInstance/GetInstanceInfo), the server-time stamp, the rolling-window prune
-- and the same-live-instance merge all live in instances.lua and are driven by its
-- own sim. The section is a VIEW, so it adds no client-mutating call and therefore
-- no Class 9 in-call dispatch surface of its own.
--
-- THIS ACCOUNT ONLY (owner, verbatim: "i dont need it to show information for
-- other accounts on the hover, just the current account"). The peer-account lines
-- this section used to carry are gone from the HOVER; the underlying replication
-- is untouched — instances.lua still merges every peer's ledger and the Instances
-- PANEL still reads it, because a cross-account view is exactly what a panel is
-- for and exactly what a one-second glance at a minimap button is not.
----------------------------------------------------------------------

local HOUR_SECS   = 3600
-- The "Today" line stays HIDDEN below this. The 30/day limit only becomes
-- actionable near its cap, and the tooltip's job here is to stay quiet: an
-- ever-present "4/30" is noise the owner would learn to stop reading.
local DAY_SHOW_AT = 20
-- Defensive bound on the row list. The hourly cap is 5, so a healthy ledger can
-- never exceed it; a drifted or hand-imported one must not be able to grow the
-- tooltip without limit.
local MAX_ROWS    = 6

-- Class ink for a character name. Same doctrine as the item-count tooltip and the
-- Instances panel's roster grid: an UNKNOWN class renders NEUTRAL, never a guessed
-- grey — a confidently wrong class colour is worse than no colour at all.
local function classInk(tag)
    local c = tag and ((_G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS or {})[tag])
    if c and type(c.r) == "number" then return c.r, c.g, c.b end
    return nil
end

local function inkHex(r, g, b)
    if type(r) ~= "number" then return "" end
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Minutes until an entry ages out of the rolling hour. Minute precision, never
-- below 1: an entry with 20 seconds left has NOT freed yet, and "frees in 0m"
-- would read as a slot the owner does not actually have.
local function freesInMinutes(entryT, nowE)
    local rem = (entryT or 0) + HOUR_SECS - (nowE or 0)
    if rem < 0 then rem = 0 end
    return math.max(1, math.ceil(rem / 60))
end

local function meterToken(count, cap, warn)
    local IUI = ns.InstancesUI
    if not (IUI and IUI.MeterState and IUI.StateToken) then return "muted" end
    return IUI.StateToken(IUI.MeterState(count, cap, warn))
end

----------------------------------------------------------------------
-- THE CURRENT-RUN BLOCK — what this run has taken so far, while inside.
--
-- Rendered ONLY while a run is open, and "open" is not a guess: it is
-- `Instances.CurrentRun()`, which hands back the very entry table the capture
-- path is writing into. So the block cannot show for a run that has ended, and
-- the numbers in it cannot be a stale copy of anything. The instant the exit
-- routine fires, CurrentRun answers nil and the whole block is gone — the
-- attribution rule and the display rule are the same rule.
--
-- OUR GRAMMAR, NOT THE REFERENCE'S. The reference fences this block with grey
-- hairline textures and paints it cyan-label / white-value. We have a blank line
-- and colour tokens: the label side takes `muted`, the figure side takes `text`,
-- the run's identity takes the same treatment a section's lead row takes
-- elsewhere in this tooltip, and a sub-section header takes `faint`. Every figure
-- reaches AddDoubleLine as a real colour triple, not as an escape sequence buried
-- in a string — THE INK IS NOT IN A STRING, the same rule the instance rows
-- below already keep, so a recorder that drops the numeric arguments watches the
-- colour disappear instead of going quietly green.
--
-- SUPPRESSION follows the spec: a field with nothing to say is omitted rather
-- than printed as a zero, and GOLD is the single exception that always prints —
-- "0c" is a real answer to "what did this run pay", and its absence would read as
-- a missing row rather than an empty purse.
--
-- Experience and XP/hour disappear at max level without this code knowing what
-- max level is: the engine refuses to store a zero level requirement, so
-- XPPercentOfLevel has no denominator and returns nil. The XP total itself still
-- shows if any XP landed, and the mob count — which the kill-derived counter
-- keeps alive on a run of greys — is what carries a max-level run.
local MAX_REP_ROWS = 4      -- a dungeon awards one or two factions; the cap is a bound, not a rule

local function currentRunLines(nowE)
    local E, IUI = ns.Instances, ns.InstancesUI
    if not (E and IUI and E.CurrentRun and IUI.FormatCount) then return nil end
    local e = E.CurrentRun()
    if type(e) ~= "table" then return nil end

    local out = {}
    local dur = (E.EntryDuration and E.EntryDuration(e, nowE, true)) or 0
    local D = ns.Dashboard
    local durText = (D and D.FormatDuration and D.FormatDuration(dur))
                    or (math.floor(dur) .. "s")
    -- The run's identity and its live clock, one row: the instance you are in and
    -- how long you have been in it are one fact, and the tooltip has a two-column
    -- line for exactly that shape.
    out[#out + 1] = { k = "double", color = "text", token = "accent",
                      left = tostring(e.name or "?"), right = durText }

    local mobs = (IUI.MobCount and IUI.MobCount(e)) or 0
    if mobs > 0 then
        out[#out + 1] = { k = "double", color = "muted", token = "text",
                          left = "Mob count", right = IUI.FormatCount(mobs) }
    end
    local honor = tonumber(e.honor) or 0
    if honor > 0 then
        out[#out + 1] = { k = "double", color = "muted", token = "text",
                          left = "Honor", right = IUI.FormatCount(honor) }
    end
    local xp = math.max(0, tonumber(e.xp) or 0)
    if xp > 0 then
        local right = IUI.FormatCount(xp, true)
        local pct = IUI.XPPercentOfLevel and IUI.XPPercentOfLevel(xp, e.xpMax)
        if pct then right = right .. string.format("  (%.1f%% of level)", pct) end
        out[#out + 1] = { k = "double", color = "muted", token = "text",
                          left = "Experience", right = right }
        local rate = IUI.XPPerHour and IUI.XPPerHour(xp, dur)
        if rate then
            out[#out + 1] = { k = "double", color = "muted", token = "text",
                              left = "XP/hour", right = IUI.FormatCount(rate) }
        end
    end
    -- Gold ALWAYS prints, and by the spec's precedence: the looted-coin
    -- accumulator, with the wallet delta consulted only when the accumulator is
    -- zero AND the wallet rose.
    local gold = (IUI.RunGold and IUI.RunGold(e)) or 0
    out[#out + 1] = { k = "double", color = "muted", token = "text",
                      left = "Gold", right = IUI.FormatMoneyFull(gold) }

    -- Every faction that fired, alphabetical, losses signed. No primary faction,
    -- no filtering of small amounts — a dungeon awarding two factions simply
    -- produces two rows.
    local reps = (IUI.RepRows and IUI.RepRows(e.repBy)) or {}
    if #reps > 0 then
        out[#out + 1] = { k = "line", text = "Reputation", color = "faint" }
        for i = 1, math.min(#reps, MAX_REP_ROWS) do
            out[#out + 1] = { k = "double", color = "muted", token = "text",
                              left = "  " .. reps[i].faction, right = reps[i].text }
        end
        if #reps > MAX_REP_ROWS then
            out[#out + 1] = { k = "line", color = "faint",
                              text = string.format("  +%d more faction(s)", #reps - MAX_REP_ROWS) }
        end
    end

    -- The blank line that closes the block — our hairline.
    out[#out + 1] = { k = "blank" }
    return out
end

-- Build the section as model entries, or nil when it must not render at all.
-- cfg.showInstances == false is the ONLY off switch; an ABSENT key renders (the
-- stored default is true, and a caller handing us a partial cfg table — the
-- self-test's { lock = ... } — must not silently lose the section).
local function instanceSection(cfg, nowE)
    if cfg and cfg.showInstances == false then return nil end

    local E, IUI, Store = ns.Instances, ns.InstancesUI, ns.Store
    if not (E and IUI and Store) then return nil end
    if not (E.AllAccounts and IUI.GatherEntries and IUI.FilterEntries and IUI.ClassLookup) then
        return nil
    end

    -- Server time, via the same helper the world-buff rows above use (Store.Now,
    -- GetServerTime fallback). Entries are stamped with server time by
    -- instances.lua, so the window arithmetic must be done in the same clock.
    nowE = nowE or nowEpoch()
    local selfAID = (ns.GetAccountID and ns:GetAccountID()) or ""
    local view    = E.AllAccounts(nowE) or {}
    local accounts = view.accounts or {}
    local mine     = accounts[selfAID] or { hour = 0, day = 0 }

    local hCap,  hWarn = E.HOURLY_CAP or 5, E.WARN_HOURLY or 4
    local dCap,  dWarn = E.DAILY_CAP or 30, E.WARN_DAILY  or 27

    local out = {}
    out[#out + 1] = { k = "blank" }
    out[#out + 1] = { k = "line", text = "Instances", color = "accent" }
    -- CURRENT RUN first, when there is one: while you are inside, what this run
    -- has taken is the news and the hour meter is the context. Outside, the block
    -- is absent entirely and the section opens on the meter exactly as before.
    local run = currentRunLines(nowE)
    if run then
        for i = 1, #run do out[#out + 1] = run[i] end
    end
    out[#out + 1] = { k = "double", left = "This hour", color = "muted",
                      right = string.format("%d/%d", mine.hour or 0, hCap),
                      token = meterToken(mine.hour, hCap, hWarn) }
    if (mine.day or 0) >= DAY_SHOW_AT then
        out[#out + 1] = { k = "double", left = "Today", color = "muted",
                          right = string.format("%d/%d", mine.day, dCap),
                          token = meterToken(mine.day, dCap, dWarn) }
    end

    -- The rows: this account's OWN entries still inside the rolling hour. `merged`
    -- entries are skipped for the same reason the cap math skips them — the serial
    -- watcher proved they were a re-entry into the SAME live instance, which the
    -- server never billed a second time.
    local data  = Store.data
    local list  = IUI.FilterEntries(IUI.GatherEntries(data and data.instances), { aid = selfAID })
    local classBy = IUI.ClassLookup(data)

    local rows = {}
    for i = 1, #list do
        local item = list[i]
        local e = item and item.entry
        local age = e and (nowE - (e.t or 0))
        if e and not e.merged and age and age >= 0 and age < HOUR_SECS then
            rows[#rows + 1] = item
        end
    end

    if #rows == 0 then
        -- Empty state matches the world-buff block above, which always states
        -- itself ("no data") rather than vanishing.
        out[#out + 1] = { k = "line", text = "none this hour", color = "faint" }
    else
        -- OLDEST FIRST, so "frees in" ascends and the top row is the next slot to
        -- re-open. GatherEntries hands us newest-first, so this walks backwards.
        local faintHex = inkHex(UI.Color("faint"))
        local drawn = 0
        for i = #rows, 1, -1 do
            if drawn >= MAX_ROWS then break end
            local item = rows[i]
            local e    = item.entry
            local short = tostring(item.nameRealm or "?"):match("^([^%-]+)") or item.nameRealm
            local cr, cg, cb = classInk(classBy[item.nameRealm])
            -- The right column carries its own colour escapes so the character and
            -- the countdown are inked separately; the numeric args are the class
            -- colour as the fallback for a client that strips escapes. The ink is
            -- NOT in a string alone — a recorder that drops the numeric args must
            -- still be able to see the class colour.
            local right = (cr and (inkHex(cr, cg, cb) .. short .. "|r") or short)
                          .. faintHex .. "  frees in " .. freesInMinutes(e.t, nowE) .. "m|r"
            local row = { k = "double", color = "text",
                          left = tostring(e.name or "?"), right = right }
            if cr then row.rgb2 = { cr, cg, cb } else row.token = "text" end
            out[#out + 1] = row
            drawn = drawn + 1
        end
        -- Truncation is SAID, never silent. The hourly cap is 5, so reaching this
        -- means a drifted or hand-imported ledger — and a tooltip that quietly drops
        -- rows would under-report exactly when the picture matters most.
        if #rows > drawn then
            out[#out + 1] = { k = "line", color = "faint",
                              text = string.format("+%d more this hour", #rows - drawn) }
        end
    end

    -- NO PEER-ACCOUNT LINES. This section used to close with one "Account 2  1/5"
    -- row per other account on the mesh. The owner does not want them here: the
    -- hover is a glance at YOUR five, and a second account's meter is a question
    -- you go to the Instances panel to ask. The replication that fed those rows is
    -- deliberately left in place (instances.lua MergeInbound, the panel's
    -- cross-account view) — this is a trim of the hover, not a retreat from the
    -- data. `accounts` above is still read for our OWN row and nothing else.
    return out
end

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
    }
    -- The Instances block sits BELOW the world buff timers and ABOVE the click
    -- hints, in its own blank-separated section.
    local inst = instanceSection(cfg)
    if inst then
        for i = 1, #inst do model[#model + 1] = inst[i] end
    end
    local tail = {
        { k = "blank" },
        { k = "line",   text = "Left: invite online",            color = "faint" },
        { k = "line",   text = "Shift-Left: invite, no convert", color = "faint" },
        { k = "line",   text = "Right: toggle dashboard",        color = "faint" },
        { k = "line",   text = "Shift-Right: menu",              color = "faint" },
    }
    for i = 1, #tail do model[#model + 1] = tail[i] end
    if not cfg.lock then
        model[#model + 1] = { k = "line", text = "Drag to move", color = "faint" }
    end
    return model
end

-- The ink for a double line, as NUMBERS. AddDoubleLine takes two colour triples;
-- the model has always carried a right-hand `token` (the world-buff state colour)
-- and the renderer passed only three arguments, so that token was computed on every
-- build and dropped on every render — the countdowns rendered default-white whatever
-- state they were in. Both triples are passed now.
--
-- `rgb2` is the raw-numbers escape hatch for a colour that is not a UI token: the
-- instance rows' CLASS ink. Deliberately numeric rather than a "|cff" string — a
-- colour that lives only inside a string is invisible to the recording tooltip the
-- self-test drives, so a regression that dropped it would render green.
local function doubleInk(e)
    local lr, lg, lb = UI.Color(e.color or "muted")
    local rr, rg, rb
    if type(e.rgb2) == "table" then
        rr, rg, rb = e.rgb2[1], e.rgb2[2], e.rgb2[3]
    elseif e.token then
        rr, rg, rb = UI.Color(e.token)
    end
    return lr, lg, lb, rr, rg, rb
end

local function renderTooltip(tt, model)
    if not tt then return end
    model = model or buildTooltipModel()
    for _, e in ipairs(model) do
        if e.k == "double" then
            local lr, lg, lb, rr, rg, rb = doubleInk(e)
            if type(rr) == "number" then
                tt:AddDoubleLine(e.left, e.right, lr, lg, lb, rr, rg, rb)
            else
                tt:AddDoubleLine(e.left, e.right, lr, lg, lb)
            end
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
    -- The recorder captures the COLOUR ARGUMENTS, not only the text. The class ink
    -- on an instance row is passed to AddDoubleLine as three numbers, so a recorder
    -- that only kept the strings would watch the ink disappear and still go green —
    -- the exact failure the Inventory tab's hand-written copy of the count block
    -- shipped (see tooltips.lua RenderCountRows). The ink is not in a string.
    local function recorder()
        local r = { lines = {} }
        function r:AddLine(text, cr, cg, cb)
            self.lines[#self.lines + 1] = { k = "line", text = text, r = cr, g = cg, b = cb }
        end
        function r:AddDoubleLine(l, rt, lr, lg, lb, rr, rg, rb)
            self.lines[#self.lines + 1] = { k = "double", left = l, right = rt,
                                            r = lr, g = lg, b = lb,
                                            r2 = rr, g2 = rg, b2 = rb }
        end
        function r:ClearLines() self.lines = {} end
        function r:Show() self.shown = true end
        return r
    end

    -- Find a line by its left/text content; returns index + line.
    local function findLine(lines, want)
        for i = 1, #lines do
            local e = lines[i]
            if e.text == want or e.left == want then return i, e end
        end
        return nil
    end

    local rec = recorder()
    sharedOnTooltipShow(rec)
    local L1 = rec.lines
    check(L1[1] and L1[1].k == "line" and L1[1].text == "Daseeki Nexus", "tooltip header")
    check(L1[2] and L1[2].k == "double" and L1[2].left == "Rend",    "tooltip Rend doubleline")
    check(L1[3] and L1[3].k == "double" and L1[3].left == "Ony (A)", "tooltip Ony (A) doubleline")
    check(L1[4] and L1[4].k == "double" and L1[4].left == "Ony (H)", "tooltip Ony (H) doubleline")
    local hintStart = findLine(L1, "Left: invite online")
    check(hintStart ~= nil, "tooltip hint 1")
    check(L1[hintStart - 1] and L1[hintStart - 1].text == " ", "tooltip blank separator before hints")
    check(L1[hintStart + 1] and L1[hintStart + 1].text == "Shift-Left: invite, no convert", "tooltip hint 2")
    check(L1[hintStart + 2] and L1[hintStart + 2].text == "Right: toggle dashboard",        "tooltip hint 3")
    check(L1[hintStart + 3] and L1[hintStart + 3].text == "Shift-Right: menu",              "tooltip hint 4")

    -- Drag hint is conditional on the lock setting, on BOTH backends.
    local unlocked = buildTooltipModel({ lock = false })
    check(unlocked[#unlocked].text == "Drag to move", "unlocked -> \"Drag to move\" hint")
    local locked = buildTooltipModel({ lock = true })
    check(locked[#locked].text == "Shift-Right: menu", "locked -> no drag hint")
    check(#unlocked == #locked + 1, "the drag hint is the only lock-dependent line")

    ------------------------------------------------------------------
    -- THE INSTANCES SECTION.
    --
    -- Driven against a hand-built store so the window boundaries are exact rather
    -- than whatever the harness happens to hold. The section is a pure READ over
    -- instances.lua's ledger — detection, the server-time stamp and the same-live-
    -- instance merge are that module's suite, and are not re-litigated here.
    ------------------------------------------------------------------
    local Store = ns.Store
    local savedData, savedNow, savedGet = Store.data, Store.Now, ns.GetAccountID
    local savedClasses = _G.RAID_CLASS_COLORS
    local T0 = 1000000

    _G.RAID_CLASS_COLORS = { ROGUE = { r = 1, g = 0.96, b = 0.41 },
                             MAGE  = { r = 0.41, g = 0.8, b = 0.94 } }
    ns.GetAccountID = function() return "1" end
    Store.Now = function() return T0 end
    Store.data = {
        accounts = { ["1"] = { characters = {
            ["Shalk-Sim"]   = { classTag = "ROGUE" },
            ["Bramble-Sim"] = { classTag = "MAGE"  },
            ["Nomad-Sim"]   = {},                     -- class UNKNOWN on purpose
        } } },
        instances = { ["1"] = {
            -- 12 minutes in  -> frees in 48m
            ["Shalk-Sim"]   = { entries = { { t = T0 - 12 * 60, name = "Scholomance" } } },
            -- 59m30s in -> still INSIDE the window, and rounds UP to 1m, never 0m
            ["Bramble-Sim"] = { entries = { { t = T0 - 3570, name = "Stratholme" } } },
            ["Nomad-Sim"]   = { entries = {
                { t = T0 - 30 * 60, name = "Maraudon" },
                -- EXACTLY 60m old: aged OUT (age < HOUR is strict), must not count
                { t = T0 - 3600,    name = "Uldaman" },
                -- inside the window but MERGED: same live instance, server never
                -- billed it twice, so it is neither counted nor listed
                { t = T0 - 20 * 60, name = "Maraudon", merged = true },
            } },
        } },
    }

    local sec = instanceSection({}, T0)
    check(sec ~= nil, "instances: section builds")
    check(sec[1].k == "blank" and sec[2].text == "Instances" and sec[2].color == "accent",
          "instances: own section, blank-separated, accent header like the tooltip's other header")
    check(sec[3].left == "This hour" and sec[3].right == "3/5",
          "instances: 3 counted (60m-old aged out, merged re-entry not double-counted)")

    -- The section sits BELOW the world buff timers and ABOVE the click hints.
    local recI = recorder()
    renderTooltip(recI, buildTooltipModel({ lock = true }))
    local iHdr = findLine(recI.lines, "Instances")
    local iHint = findLine(recI.lines, "Left: invite online")
    check(iHdr and recI.lines[iHdr - 1].text == " ", "instances: blank line opens the section")
    check(iHdr and recI.lines[iHdr - 2].left == "Ony (H)",
          "instances: section renders immediately BELOW the world buff timers")
    check(iHdr and iHint and iHdr < iHint, "instances: section renders ABOVE the click hints")

    -- Rows: oldest first, so "frees in" ascends and the top row is the next slot.
    local r1 = recI.lines[iHdr + 2]
    local r2 = recI.lines[iHdr + 3]
    local r3 = recI.lines[iHdr + 4]
    check(r1 and r1.left == "Stratholme" and r1.right:find("frees in 1m", 1, true),
          "instances: oldest row first; 59m30s rounds UP to 1m, never a phantom free slot")
    check(r2 and r2.left == "Maraudon" and r2.right:find("frees in 30m", 1, true),
          "instances: 30m-old entry frees in 30m")
    check(r3 and r3.left == "Scholomance" and r3.right:find("frees in 48m", 1, true),
          "instances: 12m-old entry frees in 48m")
    check(not findLine(recI.lines, "Uldaman"), "instances: the exactly-60m entry is not listed")
    -- The merged re-entry must not appear as a SECOND Maraudon row. The count above
    -- already excludes it (the engine's own rule); this pins the LIST as well, so a
    -- row filter that forgot `merged` cannot show the owner an instance they never
    -- paid a slot for.
    local maraudonRows = 0
    for _, e in ipairs(recI.lines) do if e.left == "Maraudon" then maraudonRows = maraudonRows + 1 end end
    check(maraudonRows == 1, "instances: a merged re-entry is not listed as a second row")

    -- THE INK IS NOT IN A STRING: the class colour reaches AddDoubleLine as numbers.
    check(r1.r2 == 0.41 and r1.g2 == 0.8 and r1.b2 == 0.94,
          "instances: MAGE class ink passed to AddDoubleLine as NUMERIC args")
    check(r3.r2 == 1 and r3.g2 == 0.96 and r3.b2 == 0.41,
          "instances: ROGUE class ink passed to AddDoubleLine as NUMERIC args")
    check(r1.right:find("Bramble", 1, true) and r3.right:find("Shalk", 1, true),
          "instances: the character that entered is named on its row")
    -- An unknown class renders NEUTRAL, never a guessed grey.
    check(r2.r2 ~= nil and r2.r2 == select(1, UI.Color("text")),
          "instances: unknown class falls back to the neutral text token, not a guess")

    -- The world-buff rows' own state token now reaches the tooltip too (it was
    -- computed into the model and dropped by the 3-argument AddDoubleLine call).
    local wb = recI.lines[2]
    check(wb.left == "Rend" and type(wb.r2) == "number",
          "world buff row carries its state token as numeric right-hand ink")

    ------------------------------------------------------------------
    -- Rolling-window boundary, walked one second at a time across 60m.
    ------------------------------------------------------------------
    Store.data.instances["1"] = { ["Shalk-Sim"] = { entries = { { t = T0, name = "Dire Maul" } } } }
    local function hourAt(tt) return instanceSection({}, tt)[3].right end
    check(hourAt(T0) == "1/5",              "window: an entry counts the instant it happens")
    check(hourAt(T0 + 3599) == "1/5",       "window: still counted at 59m59s")
    check(hourAt(T0 + 3600) == "0/5",       "window: aged out at EXACTLY 60m (age < HOUR is strict)")
    check(hourAt(T0 + 3601) == "0/5",       "window: stays out past 60m")

    ------------------------------------------------------------------
    -- The "Today" line: quiet until the daily count is actually actionable.
    ------------------------------------------------------------------
    local dayEntries = {}
    for i = 1, 19 do dayEntries[i] = { t = T0 - 7200 - i, name = "Old" .. i } end
    Store.data.instances["1"] = { ["Shalk-Sim"] = { entries = dayEntries } }
    check(findLine(instanceSection({}, T0), "Today") == nil,
          "today line: hidden at 19/30 — the tooltip stays quiet")
    dayEntries[20] = { t = T0 - 7200 - 20, name = "Old20" }
    local _, todayLine = findLine(instanceSection({}, T0), "Today")
    check(todayLine and todayLine.right == "20/30", "today line: appears at 20/30")

    ------------------------------------------------------------------
    -- A drifted ledger truncates the LIST but says so, and the meter above it
    -- still reports the true count.
    ------------------------------------------------------------------
    local manyEntries = {}
    for i = 1, 9 do manyEntries[i] = { t = T0 - i * 60, name = "Run" .. i } end
    Store.data.instances["1"] = { ["Shalk-Sim"] = { entries = manyEntries } }
    local many = instanceSection({}, T0)
    check(many[3].right == "9/5", "truncation: the meter still reports the true count")
    local _, moreLine = findLine(many, "+3 more this hour")
    check(moreLine and moreLine.color == "faint", "truncation: the dropped rows are SAID, not silently omitted")

    ------------------------------------------------------------------
    -- Empty state + the config toggle.
    ------------------------------------------------------------------
    Store.data.instances["1"] = {}
    local empty = instanceSection({}, T0)
    check(empty[3].right == "0/5", "empty: meter reads 0/5")
    check(empty[4] and empty[4].text == "none this hour" and empty[4].color == "faint",
          "empty: a single muted line, matching the world buff block's \"no data\" posture")

    check(instanceSection({ showInstances = false }, T0) == nil,
          "toggle off -> no section at all")
    check(instanceSection({ showInstances = true }, T0) ~= nil, "toggle on -> section present")
    check(instanceSection({}, T0) ~= nil,
          "ABSENT key renders: the stored default is ON, so a pre-existing SavedVariables shows it")

    local recOff = recorder()
    renderTooltip(recOff, buildTooltipModel({ lock = true, showInstances = false }))
    check(not findLine(recOff.lines, "Instances"), "toggle off -> \"Instances\" header absent from the tooltip")
    check(findLine(recOff.lines, "Rend") and findLine(recOff.lines, "Left: invite online"),
          "toggle off -> world buffs and hints are untouched")

    ------------------------------------------------------------------
    -- NO PEER ACCOUNTS ON THE HOVER (owner: "just the current account").
    --
    -- The pin is an ABSENCE, so it is built on a store that would have produced
    -- three peer rows on the previous build — two accounts inside the hour and
    -- one outside it — and it asserts BOTH halves: not one peer row anywhere in
    -- the section, and our own meter still reading only our own account. A test
    -- that merely said "no Account 2 line" over an empty store would go green
    -- forever without proving anything.
    ------------------------------------------------------------------
    Store.data.instances = {
        ["1"]  = { ["Shalk-Sim"] = { entries = { { t = T0 - 60, name = "Scholomance" } } } },
        ["3"]  = { ["Gorak-Sim"] = { entries = { { t = T0 - 60, name = "Stratholme" },
                                                 { t = T0 - 70, name = "Stratholme" } } } },
        ["2"]  = { ["Tuska-Sim"] = { entries = { { t = T0 - 60, name = "Maraudon" } } } },
        ["4"]  = { ["Idle-Sim"]  = { entries = { { t = T0 - 90000, name = "LastWeek" } } } },
    }
    local peers = instanceSection({}, T0)
    -- RED CONTROL for the fixture itself: the peer accounts really are in the
    -- window, so "no peer rows" is a statement about the SECTION, not about an
    -- empty store. Instances.AllAccounts is the source those rows were built from.
    local av = ns.Instances.AllAccounts(T0)
    check(av.accounts["2"] and av.accounts["2"].hour == 1
          and av.accounts["3"] and av.accounts["3"].hour == 2,
          "peer-absence fixture is vacuous: the peer accounts are not in the window at all")
    check(not findLine(peers, "Account 2"), "no peer lines: account 2 is absent from the hover")
    check(not findLine(peers, "Account 3"), "no peer lines: account 3 is absent from the hover")
    check(not findLine(peers, "Account 4"), "no peer lines: account 4 is absent from the hover")
    for _, e in ipairs(peers) do
        check(not (e.left and tostring(e.left):match("^Account ")),
              "no peer lines: a row still reads \"" .. tostring(e.left) .. "\"")
    end
    check(peers[3].left == "This hour" and peers[3].right == "1/5",
          "our OWN meter counts our OWN account only, peers excluded (got "
          .. tostring(peers[3].right) .. ")")
    -- The same absence, through the real renderer into the real tooltip frame.
    local recPeers = recorder()
    renderTooltip(recPeers, buildTooltipModel({ lock = true }))
    for _, e in ipairs(recPeers.lines) do
        check(not (e.left and tostring(e.left):match("^Account ")),
              "no peer lines: the rendered tooltip still carries \"" .. tostring(e.left) .. "\"")
    end

    ------------------------------------------------------------------
    -- THE CURRENT-RUN BLOCK.
    --
    -- Driven through Instances.CurrentRun — the same accessor the live path
    -- reads — by opening a run on a hand-built entry, so the block's presence,
    -- its ordering, its suppression rules and its ATTRIBUTION BOUNDARY are all
    -- asserted against the real builder.
    ------------------------------------------------------------------
    local savedOpenKey, savedOpenSample = ns.Instances._openKey, ns.Instances._openSample
    Store.data.instances = { ["1"] = { ["Shalk-Sim"] = { entries = {} } } }
    local liveEntry = {
        t = T0 - 1800, name = "Stratholme", mapID = 329,
        xp = 12500, xpMax = 20000, mobXP = 47, mobKill = 51,
        goldLoot = 48210, gold = -12000, honor = 0,
        repBy = { ["Timbermaw Hold"] = -75, ["Argent Dawn"] = 250 },
    }
    Store.data.instances["1"]["Shalk-Sim"].entries[1] = liveEntry
    local function openRun(entry)
        ns.Instances._openKey = { aid = "1", nameRealm = "Shalk-Sim" }
        ns.Instances._openSample = { entry = entry,
            entries = Store.data.instances["1"]["Shalk-Sim"].entries }
    end
    local function closeRun()
        ns.Instances._openKey, ns.Instances._openSample = nil, nil
    end

    -- OUTSIDE first: no block at all. This is the red control for everything
    -- below — the same store, the same entry, only the open run differs.
    closeRun()
    local outside = instanceSection({}, T0)
    check(outside[3].left == "This hour",
          "outside: the section opens straight onto the meter, no current-run block")
    check(not findLine(outside, "Experience"), "outside: no Experience row")
    check(not findLine(outside, "Gold"), "outside: no Gold row")

    openRun(liveEntry)
    local live = instanceSection({}, T0)
    check(live[2].text == "Instances", "current run: still inside the Instances section")
    check(live[3].left == "Stratholme" and live[3].right == "30m",
          "current run: instance name + LIVE elapsed lead the block (got "
          .. tostring(live[3].left) .. " / " .. tostring(live[3].right) .. ")")
    local _, mobLine = findLine(live, "Mob count")
    check(mobLine and mobLine.right == "47",
          "current run: mob count PREFERS the XP-derived tally (got "
          .. tostring(mobLine and mobLine.right) .. ")")
    local _, xpLine = findLine(live, "Experience")
    check(xpLine and xpLine.right == "+12,500  (62.5% of level)",
          "current run: XP comma-grouped with its percent of level (got "
          .. tostring(xpLine and xpLine.right) .. ")")
    local _, rateLine = findLine(live, "XP/hour")
    check(rateLine and rateLine.right == "25,000",
          "current run: XP/hour over the live elapsed (got "
          .. tostring(rateLine and rateLine.right) .. ")")
    local _, goldLine = findLine(live, "Gold")
    check(goldLine and goldLine.right == "4g 82s 10c",
          "current run: gold is the LOOT accumulator, not the negative wallet delta (got "
          .. tostring(goldLine and goldLine.right) .. ")")
    check(not findLine(live, "Honor"), "current run: a zero honor tally prints no row")
    -- Reputation: every faction, ALPHABETICAL, losses signed.
    local repHdr = findLine(live, "Reputation")
    check(repHdr and live[repHdr + 1].left == "  Argent Dawn" and live[repHdr + 1].right == "+250",
          "current run: rep rows are alphabetical, gains signed")
    check(repHdr and live[repHdr + 2].left == "  Timbermaw Hold" and live[repHdr + 2].right == "-75",
          "current run: a LOSS keeps its minus sign")
    -- The block is fenced from the meter by a blank line, and the meter follows.
    local hourIdx = findLine(live, "This hour")
    check(hourIdx and live[hourIdx - 1].k == "blank",
          "current run: a blank line closes the block before the hour meter")

    -- THE INK IS NOT IN A STRING: every figure reaches AddDoubleLine as numbers.
    local recRun = recorder()
    renderTooltip(recRun, buildTooltipModel({ lock = true }))
    local _, rXP = findLine(recRun.lines, "Experience")
    check(rXP and type(rXP.r2) == "number" and rXP.r2 == select(1, UI.Color("text")),
          "current run: the XP figure's ink reaches AddDoubleLine as NUMERIC args")
    local _, rName = findLine(recRun.lines, "Stratholme")
    check(rName and type(rName.r2) == "number" and rName.r2 == select(1, UI.Color("accent")),
          "current run: the run's live clock carries the accent triple as numbers")
    local _, rRep = findLine(recRun.lines, "  Argent Dawn")
    check(rRep and type(rRep.r) == "number" and type(rRep.r2) == "number",
          "current run: a rep row carries BOTH colour triples as numbers")

    -- SUPPRESSION: a run that has taken nothing shows its name, its clock and
    -- gold — and nothing else. Gold is the one field that always prints.
    local bare = { t = T0 - 90, name = "Deadmines", mapID = 36 }
    Store.data.instances["1"]["Shalk-Sim"].entries = { bare }
    openRun(bare)
    local quiet = instanceSection({}, T0)
    check(quiet[3].left == "Deadmines", "quiet run: the name still leads")
    check(not findLine(quiet, "Mob count"), "quiet run: no mob row")
    check(not findLine(quiet, "Experience"), "quiet run: no XP row")
    check(not findLine(quiet, "Reputation"), "quiet run: no reputation header")
    local _, qGold = findLine(quiet, "Gold")
    check(qGold and qGold.right == "0c", "quiet run: gold ALWAYS prints, as 0c")

    -- MAX LEVEL: XP landed but the engine stored no level requirement, so the
    -- percentage is absent while the total and the rate remain.
    local maxed = { t = T0 - 600, name = "Naxxramas", mapID = 533, xp = 900, mobXP = 3 }
    Store.data.instances["1"]["Shalk-Sim"].entries = { maxed }
    openRun(maxed)
    local mx = instanceSection({}, T0)
    local _, mxXP = findLine(mx, "Experience")
    check(mxXP and mxXP.right == "+900",
          "max level: the XP total shows with NO percent-of-level (got "
          .. tostring(mxXP and mxXP.right) .. ")")

    -- THE BOUNDARY, on the display side: closing the run removes the block in the
    -- same pass, with the entry still sitting in the ledger.
    closeRun()
    local after = instanceSection({}, T0)
    check(after[3].left == "This hour", "closed run: the section opens on the meter again")
    check(not findLine(after, "Experience") and not findLine(after, "Mob count"),
          "closed run: the current-run block is gone at once")
    -- The entry itself is untouched and simply becomes an ordinary hourly row —
    -- the block went away, the record did not.
    local _, naxRow = findLine(after, "Naxxramas")
    check(naxRow and naxRow.right and naxRow.right:find("frees in", 1, true),
          "closed run: the run survives as an ordinary hourly row")

    ns.Instances._openKey, ns.Instances._openSample = savedOpenKey, savedOpenSample
    Store.data, Store.Now, ns.GetAccountID = savedData, savedNow, savedGet
    _G.RAID_CLASS_COLORS = savedClasses

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
