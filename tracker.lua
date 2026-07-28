-- Daseeki Network — tracker.lua
-- Live capture of THIS character's state (spec §6) into the store's self
-- record, firing the local "STATE_CHANGED" callback the mesh layer hooks
-- in wave N2.
--
-- API discipline (target Interface 11509 only): auras via C_UnitAuras,
-- bags/item cooldowns via C_Container / C_Item, group state via
-- C_PartyInfo, map coords via C_Map. NO legacy global fallbacks.

local ADDON, ns = ...

local Tracker = {}
ns.Tracker = Tracker

----------------------------------------------------------------------
-- Static tables
----------------------------------------------------------------------

-- Stable Classic Era item IDs.
local ITEM_SOUL_SHARD  = 6265
local ITEM_HEARTHSTONE = 6948

-- World-buff aura name -> fixed slot (1..10). Names are matched
-- case-insensitively by prefix so localized suffixes (e.g. Sayge's
-- fortune variants) still land in one slot. Slot layout is Daseeki's own.
local BUFF_SLOTS = {
    { slot = 1,  prefix = "rallying cry of the dragonslayer" },
    { slot = 2,  prefix = "warchief's blessing" },
    { slot = 3,  prefix = "spirit of zandalar" },
    { slot = 4,  prefix = "songflower serenade" },
    { slot = 5,  prefix = "sayge's dark fortune" },
    { slot = 6,  prefix = "fengus' ferocity" },
    { slot = 7,  prefix = "mol'dar's moxie" },
    { slot = 8,  prefix = "slip'kik's savvy" },
    { slot = 9,  prefix = "traces of silithyst" },
    { slot = 10, prefix = "boon of blackfathom" },
}

-- Names that mark a stored-buff chronoboon aura (tooltip capture target).
local CHRONOBOON_MARKERS = {
    "chronoboon displacement",
    "supercharged chronoboon displacer",
}

-- Names counted as stored world buffs when scanning the chronoboon tooltip.
local STORED_BUFF_NAMES = {
    "rallying cry of the dragonslayer",
    "warchief's blessing",
    "spirit of zandalar",
    "songflower serenade",
    "sayge's dark fortune",
    "fengus' ferocity",
    "mol'dar's moxie",
    "slip'kik's savvy",
    "boon of blackfathom",
    "spark of inspiration",
}

-- Saved-instance name substring -> our raid key.
local RAID_NAME_MAP = {
    { needle = "naxxramas",            key = "Naxx" },
    { needle = "temple of ahn'qiraj",  key = "AQ40" },
    { needle = "blackwing lair",       key = "BWL"  },
    { needle = "molten core",          key = "MC"   },
    { needle = "zul'gurub",            key = "ZG"   },
    { needle = "ruins of ahn'qiraj",   key = "AQ20" },
    { needle = "onyxia",               key = "Ony"  },
}

-- Names of Darkmoon Faire (Sayge) fortune buffs, for DMF lifecycle.
local DMF_BUFF_PREFIX = "sayge's dark fortune"

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function lower(s) return s and s:lower() or "" end

local function selfNameRealm()
    local name = UnitName("player")
    local realm = GetRealmName() or ""
    realm = realm:gsub("%s+", "")
    return name .. "-" .. realm
end

-- Remaining seconds on an aura's expiration, clamped to >= 0.
local function auraRemaining(aura)
    if not aura or not aura.expirationTime or aura.expirationTime == 0 then
        return 0
    end
    local rem = aura.expirationTime - GetTime()
    if rem < 0 then rem = 0 end
    return math.floor(rem)
end

----------------------------------------------------------------------
-- Chronoboon tooltip capture
--
-- The stored-buff count is not exposed through the aura API, so we hook
-- the tooltip: whenever GameTooltip renders the chronoboon aura, scan its
-- text lines and count recognised stored world buffs. The most recent
-- count is cached and folded into the next capture.
----------------------------------------------------------------------

Tracker._boonTooltipCount = 0
Tracker._boonTooltipSeen  = 0

local function scanTooltipForStoredBuffs()
    if not GameTooltip or not GameTooltip.NumLines then return end
    local lines = GameTooltip:NumLines()
    if not lines or lines < 1 then return end
    -- Confirm this tooltip is actually a chronoboon aura before counting.
    local firstLine = _G["GameTooltipTextLeft1"]
    local title = firstLine and firstLine.GetText and firstLine:GetText()
    title = lower(title)
    local isBoon = false
    for i = 1, #CHRONOBOON_MARKERS do
        if title:find(CHRONOBOON_MARKERS[i], 1, true) then isBoon = true break end
    end
    if not isBoon then return end

    local count = 0
    for i = 1, lines do
        local fs = _G["GameTooltipTextLeft" .. i]
        local text = lower(fs and fs.GetText and fs:GetText())
        if text ~= "" then
            for j = 1, #STORED_BUFF_NAMES do
                if text:find(STORED_BUFF_NAMES[j], 1, true) then
                    count = count + 1
                    break
                end
            end
        end
    end
    Tracker._boonTooltipCount = count
    Tracker._boonTooltipSeen  = GetTime()
end

local function installTooltipHooks()
    if Tracker._tooltipHooked then return end
    if not (GameTooltip and hooksecurefunc) then return end
    -- SetUnitAura / SetUnitBuff both render player auras; hook whichever
    -- exist on this client.
    if GameTooltip.SetUnitAura then
        hooksecurefunc(GameTooltip, "SetUnitAura", function(_, unit)
            if unit == "player" then scanTooltipForStoredBuffs() end
        end)
    end
    if GameTooltip.SetUnitBuff then
        hooksecurefunc(GameTooltip, "SetUnitBuff", function(_, unit)
            if unit == "player" then scanTooltipForStoredBuffs() end
        end)
    end
    Tracker._tooltipHooked = true
end

----------------------------------------------------------------------
-- Field capture pieces
----------------------------------------------------------------------

-- Identity + level + faction. Class token is the non-localized filename.
local function captureIdentity(rec)
    rec.level = UnitLevel("player") or 0
    local className, classTag = UnitClass("player")
    rec.className = className
    rec.classTag  = classTag
    local eng = UnitFactionGroup("player")
    if eng == "Alliance" or eng == "Horde" then
        rec.faction = eng
    else
        rec.faction = nil
    end
end

-- Resting / PvP / instance flags.
local function captureFlags(rec)
    rec.isResting = IsResting() and true or false

    local pvp = UnitIsPVP("player") or UnitIsPVPFreeForAll("player")
    rec.pvpFlagged = pvp and true or false
    -- WoW does not expose the flag's drop time directly; the mesh layer
    -- fills pvpExpiry from PLAYER_FLAGS_CHANGED timing in a later wave.
    if not rec.pvpFlagged then rec.pvpExpiry = 0 end

    local inInstance, instanceType = IsInInstance()
    rec.inInstance = inInstance and true or false
    rec._instanceType = instanceType
end

-- Zone / location: coordinate overrides first, then a user manual label,
-- then the game's zone text.
local function captureLocation(rec)
    local nameRealm = rec.nameRealm
    local override = Tracker.ResolveCoordinateOverride()
    if override then
        rec.location = override
        return
    end
    local manual = ns.Store.GetManualLocation(nameRealm)
    if manual and manual ~= "" then
        rec.location = manual
        return
    end
    local sub = GetSubZoneText()
    local zone = GetRealZoneText()
    if sub and sub ~= "" then
        rec.location = sub
    elseif zone and zone ~= "" then
        rec.location = zone
    else
        rec.location = GetMinimapZoneText()
    end
end

-- Match the current map + player position against configured coordinate
-- override boxes. Returns the label or nil.
function Tracker.ResolveCoordinateOverride()
    local db = ns.Store.GetSettings()
    local overrides = db and db.coordinateOverrides
    if not overrides or #overrides == 0 then return nil end

    local zone = GetRealZoneText() or ""
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local posTbl = C_Map.GetPlayerMapPosition(mapID, "player")
    if not posTbl then return nil end
    local x, y = posTbl:GetXY()
    if not x or not y then return nil end

    for i = 1, #overrides do
        local o = overrides[i]
        if (not o.zone or o.zone == zone)
            and x >= (o.minX or 0) and x <= (o.maxX or 1)
            and y >= (o.minY or 0) and y <= (o.maxY or 1) then
            return o.label or o.name
        end
    end
    return nil
end

-- Warlock soul-shard count (bag item count).
local function captureShards(rec)
    if rec.classTag == "WARLOCK" and C_Item and C_Item.GetItemCount then
        rec.shardCount = C_Item.GetItemCount(ITEM_SOUL_SHARD) or 0
    else
        rec.shardCount = 0
    end
end

-- Hearthstone remaining cooldown (seconds). itemCooldown (a tracked
-- trinket) is left extensible for a later wave and reported as 0 here.
local function captureCooldowns(rec)
    rec.itemCooldown = 0
    rec.hearthstoneCD = 0
    if C_Container and C_Container.GetItemCooldown then
        local start, duration, enable = C_Container.GetItemCooldown(ITEM_HEARTHSTONE)
        if start and duration and duration > 0 and (enable == nil or enable == 1) then
            local rem = (start + duration) - GetTime()
            if rem > 0 then rec.hearthstoneCD = math.floor(rem) end
        end
    end
end

-- Scan player buffs, fill the 10 aura slots, track chronoboon + DMF.
local function captureAuras(rec)
    local slots = {}
    local chronoActive = false
    local dmfInBoon = false

    if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        for i = 1, 40 do
            local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
            if not aura then break end
            local nm = lower(aura.name)

            -- World-buff slot assignment.
            for s = 1, #BUFF_SLOTS do
                local def = BUFF_SLOTS[s]
                if nm:find(def.prefix, 1, true) == 1 then
                    slots[def.slot] = {
                        duration = auraRemaining(aura),
                        option   = 0,     -- per-aura option code (later waves)
                        source   = 0,     -- 0 = live/self (trust); relayed set by mesh
                    }
                    break
                end
            end

            -- Chronoboon (stored-buff) marker.
            for m = 1, #CHRONOBOON_MARKERS do
                if nm:find(CHRONOBOON_MARKERS[m], 1, true) then
                    chronoActive = true
                    break
                end
            end

            -- DMF fortune.
            if nm:find(DMF_BUFF_PREFIX, 1, true) == 1 then
                dmfInBoon = true
            end
        end
    end

    rec.auraStates = slots

    -- Chronoboon fields (count sourced from the tooltip hook cache).
    rec.chronoboonActive = chronoActive
    if chronoActive then
        rec.chronoboonLastSeen = ns.Store.Now()
        rec.boonCount = Tracker._boonTooltipCount or 0
    else
        rec.boonCount = 0
    end

    -- DMF lifecycle: holding a fortune means the daily has been taken, so
    -- the cooldown is active. offlineSince stays 0 while online; the store
    -- stamps it at logout and clears it after ~8h offline.
    rec.dmfInBoon = dmfInBoon
    if dmfInBoon then
        rec.dmfCooldownActive = true
        rec.dmfCooldown = rec.dmfCooldown or {}
        rec.dmfCooldown.offlineSince = 0
    end
end

-- Raid lockouts from the saved-instance list. Requires a prior
-- RequestRaidInfo (fired on login and refreshed on UPDATE_INSTANCE_INFO).
local function captureRaidLockouts(rec)
    rec.raidLockouts = rec.raidLockouts or {}
    -- Clear stale keys; rebuild from the current saved list.
    for _, k in ipairs(ns.Store.RAID_KEYS) do
        rec.raidLockouts[k] = nil
    end
    local n = GetNumSavedInstances and GetNumSavedInstances() or 0
    local now = ns.Store.Now()
    for i = 1, n do
        local name, _, reset, _, locked = GetSavedInstanceInfo(i)
        if name and locked and reset and reset > 0 then
            local lname = lower(name)
            for _, m in ipairs(RAID_NAME_MAP) do
                if lname:find(m.needle, 1, true) then
                    rec.raidLockouts[m.key] = now + reset
                    break
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- Full capture + debounce
----------------------------------------------------------------------

function Tracker.Capture()
    if not ns.state.loggedIn then return end
    local nameRealm = selfNameRealm()
    local rec = ns.Store.EnsureSelfCharacter(nameRealm)
    if not rec then return end

    captureIdentity(rec)
    captureFlags(rec)
    captureLocation(rec)
    captureShards(rec)
    captureCooldowns(rec)
    captureAuras(rec)
    captureRaidLockouts(rec)

    rec.lastSeen = ns.Store.Now()
    rec.lastDataUpdate = rec.lastSeen
    rec.ownerEpoch = rec.lastSeen

    ns.Store.WriteSelfCharacter(nameRealm, rec)

    -- Local signal for the mesh layer (wave N2). No network I/O here.
    ns:Fire("STATE_CHANGED", nameRealm, rec)
end

-- Coalesce bursty events into one capture on the next frame tick.
function Tracker.RequestCapture()
    if Tracker._captureQueued then return end
    Tracker._captureQueued = true
    C_Timer.After(0, function()
        Tracker._captureQueued = false
        ns:SafeCall(Tracker.Capture)
    end)
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

function Tracker.OnLogin()
    installTooltipHooks()

    -- Ask the server for our saved-instance (lockout) data.
    if RequestRaidInfo then RequestRaidInfo() end

    local capEvents = {
        "PLAYER_ENTERING_WORLD",
        "ZONE_CHANGED_NEW_AREA",
        "UNIT_AURA",
        "PLAYER_UPDATE_RESTING",
        "PLAYER_FLAGS_CHANGED",
        "BAG_UPDATE_DELAYED",
        "BAG_UPDATE_COOLDOWN",
        "UPDATE_INSTANCE_INFO",
        "PLAYER_LEVEL_UP",
        "PLAYER_CONTROL_LOST",
        "PLAYER_CONTROL_GAINED",
    }
    for _, evt in ipairs(capEvents) do
        ns:RegisterEvent(evt, function(event, unit)
            -- UNIT_AURA fires for many units; only react to the player.
            if event == "UNIT_AURA" and unit ~= "player" then return end
            if event == "UPDATE_INSTANCE_INFO" then
                -- lockout data just refreshed; recapture directly
                Tracker.RequestCapture()
                return
            end
            Tracker.RequestCapture()
        end)
    end

    -- First snapshot once the world is ready.
    Tracker.RequestCapture()
end
