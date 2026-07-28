-- Daseeki Nexus — tracker.lua
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

-- Created Soulstone reagent item IDs (any in bags => a soulstone is available).
-- Minor / Lesser / (regular) / Greater / Major Soulstone. Item 6.
local SOULSTONE_ITEMS = { 5232, 16892, 16893, 16895, 16896 }
-- Create Soulstone spell (rank-agnostic; highest known rank id is fine for a
-- cooldown probe — a ready spell also means a soulstone can be made). [verify id]
local SPELL_CREATE_SOULSTONE = 20758

-- FFF seasonal world buff. Its exact in-game aura name is NOT a clean-room fact
-- (the spec calls it only "seasonal FFF"); this prefix is a best-guess PLACEHOLDER
-- the owner confirms in-game and corrects here if it differs. A non-match simply
-- leaves slot 10 empty (safe) — it never errors. [verify — owner in-game]
local FFF_AURA_PREFIX = "fervor of the first feast"

-- World-buff aura name -> fixed slot (1..8). Names are matched
-- case-insensitively by prefix so localized suffixes (e.g. Sayge's
-- fortune variants) still land in one slot. Slot layout is Daseeki's own.
-- Slots 9/10 (Traces of Silithyst, Boon of Blackfathom) were removed as
-- not-relevant tracked buffs; they were the tail entries, so no live slot
-- index shifts (the mesh binary schema still reserves up to 10 sparse slots).
-- Additive trailing slots 9 (Battle Shout) + 10 (seasonal FFF) added in R3
-- (item 36). The removed Silithyst/Blackfathom were the tail entries, so slots
-- 1-8 keep their indices — the mesh binary schema already reserves up to 10.
local BUFF_SLOTS = {
    { slot = 1,  prefix = "rallying cry of the dragonslayer" },
    { slot = 2,  prefix = "warchief's blessing" },
    { slot = 3,  prefix = "spirit of zandalar" },
    { slot = 4,  prefix = "songflower serenade" },
    { slot = 5,  prefix = "sayge's dark fortune" },
    { slot = 6,  prefix = "fengus' ferocity" },
    { slot = 7,  prefix = "mol'dar's moxie" },
    { slot = 8,  prefix = "slip'kik's savvy" },
    { slot = 9,  prefix = "battle shout" },            -- world Battle Shout ("Fallen Hero")
    { slot = 10, prefix = FFF_AURA_PREFIX },           -- seasonal FFF [verify prefix]
}

-- Names that mark a stored-buff chronoboon aura (tooltip capture target).
local CHRONOBOON_MARKERS = {
    "chronoboon displacement",
    "supercharged chronoboon displacer",
}

-- Names counted as stored world buffs when scanning the chronoboon tooltip.
-- Includes the two new tracked slots plus the chronoboon-only extras that count
-- toward boonCount but have no dashboard slot (Boon of Blackfathom / Spark).
local STORED_BUFF_NAMES = {
    "rallying cry of the dragonslayer",
    "warchief's blessing",
    "spirit of zandalar",
    "songflower serenade",
    "sayge's dark fortune",
    "fengus' ferocity",
    "mol'dar's moxie",
    "slip'kik's savvy",
    "battle shout",
    FFF_AURA_PREFIX,
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

-- Normalize a tooltip/buff string for NAME matching: lowercased, with any
-- typographic apostrophe folded to ASCII so "Mol'dar's" / "Fengus'" still match
-- the ASCII-apostrophe prefixes in BUFF_SLOTS regardless of how the client
-- renders the glyph. Belt-and-suspenders for the boon parse.
local function normName(s)
    s = lower(s)
    s = s:gsub("\226\128\153", "'")   -- U+2019 RIGHT SINGLE QUOTATION MARK (UTF-8)
    s = s:gsub("\226\128\152", "'")   -- U+2018 LEFT SINGLE QUOTATION MARK  (UTF-8)
    s = s:gsub("\194\180", "'")        -- U+00B4 ACUTE ACCENT (UTF-8)
    s = s:gsub("`", "'")               -- ASCII backtick, occasionally substituted
    return s
end

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
-- Chronoboon tooltip capture + booned-buff parsing (item 37, HEADLINE)
--
-- The stored-buff durations are not exposed through the aura API, so we hook
-- the tooltip: whenever GameTooltip renders the Chronoboon Displacement (or the
-- Supercharged Chronoboon Displacer) aura, we scan its text lines and parse each
-- recognised stored buff's IDENTITY + remaining duration ("Fengus' Ferocity
-- (119m)" -> slot 6, 119min). The parsed set is written into the character
-- record's aura slots with source = BOON so the dashboard renders "1h 59m
-- (Boon)". The snapshot is cached in DaseekiNexusData (tooltipBoon) so a relog
-- keeps it (the stored durations are frozen while booned). Re-parsed on every
-- hover; cleared when the boon aura vanishes (unboon).
----------------------------------------------------------------------

Tracker._boonTooltipCount = 0
Tracker._boonTooltipSeen  = 0
-- Parsed boon snapshot: { slots = { [slot] = { duration=sec }, ... },
--                         dmf = bool, count = n }.  Nil until first parse.
Tracker._boonParsed = nil

local BOON_SOURCE = 2   -- Store.AURA_SOURCE.BOON (kept local so the pure parser
                        -- runs even before Store loads in the self-test harness).

-- Parse a Chronoboon tooltip duration parenthetical into SECONDS.
-- Accepts "(119m)", "(1h)", "(1h 59m)", "(59m)" case-insensitively; returns the
-- seconds or nil if no duration is present. Pure + self-tested.
function Tracker.ParseBoonDuration(text)
    text = lower(text)
    local paren = text:match("%(([^)]*)%)")
    if not paren then return nil end
    local h = tonumber(paren:match("(%d+)%s*h"))
    local m = tonumber(paren:match("(%d+)%s*m"))
    if not h and not m then
        -- Bare number in parens (some clients render "(119)") -> minutes.
        local bare = tonumber(paren:match("^%s*(%d+)%s*$"))
        if bare then m = bare end
    end
    if not h and not m then return nil end
    return (h or 0) * 3600 + (m or 0) * 60
end

-- Parse ONE tooltip line to (slotIndex, durationSeconds, isDMF) or nil.
-- Matches a tracked-slot buff name anywhere in the line (the chronoboon tooltip
-- lists stored buffs); resolves its slot via BUFF_SLOTS. Pure + self-tested.
function Tracker.ParseBoonLine(text)
    text = normName(text)
    if text == "" then return nil end
    for s = 1, #BUFF_SLOTS do
        local def = BUFF_SLOTS[s]
        if def.prefix ~= "" and text:find(def.prefix, 1, true) then
            local dur = Tracker.ParseBoonDuration(text) or 0
            local isDMF = (def.prefix == DMF_BUFF_PREFIX)
            return def.slot, dur, isDMF
        end
    end
    return nil
end

-- Parse a whole Chronoboon tooltip TEXT BLOCK into a per-slot duration map.
-- ROOT CAUSE of the "only one buff booned" bug: the live Supercharged Chronoboon
-- Displacer renders ALL suspended world effects inside a SINGLE tooltip
-- FontString (one NumLines "line" with embedded newlines), e.g.
--   "World effects suspended:\nFengus' Ferocity (119m)\nMol'dar's Moxie (120m)\n..."
-- The old scan called the single-match ParseBoonLine on that whole string, which
-- returned only the FIRST slot prefix found (slot 1, Rallying Cry) with the FIRST
-- parenthetical (Fengus' 119m -> "1h 59m"). So exactly one buff booned and its
-- duration was wrong -- matching the owner's live report precisely.
--
-- This scans the block for EVERY tracked-slot buff and pairs each with the
-- parenthetical that follows ITS OWN name, so ordering and newline-vs-space
-- separation don't matter. Returns (slots, dmf) where slots[slot] = { duration }.
function Tracker.ParseBoonBlock(text)
    local slots, dmf = {}, false
    text = normName(text)
    if text == "" then return slots, dmf end
    for s = 1, #BUFF_SLOTS do
        local def = BUFF_SLOTS[s]
        if def.prefix ~= "" then
            local from = text:find(def.prefix, 1, true)
            if from then
                -- Duration = first "(...)" AFTER this buff name starts, so each
                -- buff resolves to its OWN remaining time, not the block's first.
                local dur = Tracker.ParseBoonDuration(text:sub(from)) or 0
                slots[def.slot] = { duration = dur }
                if def.prefix == DMF_BUFF_PREFIX then dmf = true end
            end
        end
    end
    return slots, dmf
end

-- Persist the current parsed boon snapshot to DaseekiNexusData.caches.tooltipBoon
-- keyed by our Name-Realm, so a relog can rehydrate it before the next hover.
local function persistBoonCache(nameRealm, parsed)
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    local caches = data and data.caches
    if not caches then return end
    caches.tooltipBoon = caches.tooltipBoon or {}
    if parsed and (next(parsed.slots) ~= nil or parsed.dmf) then
        caches.tooltipBoon[nameRealm] = {
            slots = parsed.slots, dmf = parsed.dmf, count = parsed.count,
            at = ns.Store.Now and ns.Store.Now() or 0,
        }
    else
        caches.tooltipBoon[nameRealm] = nil   -- unboon / empty -> drop the cache
    end
end

-- Rehydrate the parsed boon snapshot from the persisted cache (login path).
function Tracker.RehydrateBoonCache()
    local nameRealm = selfNameRealm()
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    local cached = data and data.caches and data.caches.tooltipBoon
                   and data.caches.tooltipBoon[nameRealm]
    if type(cached) == "table" and type(cached.slots) == "table" then
        Tracker._boonParsed = { slots = cached.slots, dmf = cached.dmf or false,
                                count = cached.count or 0 }
        Tracker._boonTooltipCount = cached.count or 0
    end
end

-- Shallow-equality of two parsed boon snapshots (for change detection).
local function boonSnapshotsEqual(a, b)
    if (a == nil) ~= (b == nil) then return false end
    if a == nil then return true end
    if a.dmf ~= b.dmf or a.count ~= b.count then return false end
    for slot, cell in pairs(a.slots) do
        local other = b.slots[slot]
        if not other or other.duration ~= cell.duration then return false end
    end
    for slot in pairs(b.slots) do
        if not a.slots[slot] then return false end
    end
    return true
end

local function scanTooltipForStoredBuffs()
    if not GameTooltip or not GameTooltip.NumLines then return end
    local lines = GameTooltip:NumLines()
    if not lines or lines < 1 then return end
    -- Confirm this tooltip is actually a chronoboon aura before parsing.
    local firstLine = _G["GameTooltipTextLeft1"]
    local title = firstLine and firstLine.GetText and firstLine:GetText()
    title = normName(title)
    local isBoon = false
    for i = 1, #CHRONOBOON_MARKERS do
        if title:find(CHRONOBOON_MARKERS[i], 1, true) then isBoon = true break end
    end
    if not isBoon then return end

    -- Concatenate EVERY tooltip FontString into one normalized text block. The
    -- live Supercharged Chronoboon Displacer packs all suspended effects into a
    -- SINGLE FontString with embedded newlines; other clients may split them
    -- across separate FontStrings. Joining + block-parsing handles both, so all
    -- stored buffs resolve in one scan (fixes "only one buff booned").
    local parts = {}
    for i = 1, lines do
        local fs = _G["GameTooltipTextLeft" .. i]
        local t = fs and fs.GetText and fs:GetText()
        if t and t ~= "" then parts[#parts + 1] = t end
    end
    local block = normName(table.concat(parts, "\n"))

    -- Count every stored buff present in the block (each name once). Includes the
    -- non-slot extras (Boon of Blackfathom / Spark of Inspiration) that still
    -- count toward boonCount but have no dashboard slot.
    local count = 0
    for j = 1, #STORED_BUFF_NAMES do
        if STORED_BUFF_NAMES[j] ~= "" and block:find(STORED_BUFF_NAMES[j], 1, true) then
            count = count + 1
        end
    end

    -- Per-slot identity + duration from the whole block (see ParseBoonBlock).
    local slots, dmf = Tracker.ParseBoonBlock(block)

    local parsed = { slots = slots, dmf = dmf, count = count }
    Tracker._boonTooltipCount = count
    Tracker._boonTooltipSeen  = GetTime()

    -- Only re-capture/propagate when the parsed set actually changed (a hover
    -- fires this repeatedly; we don't want a STATE_CHANGED storm).
    local changed = not boonSnapshotsEqual(parsed, Tracker._boonParsed)
    Tracker._boonParsed = parsed
    persistBoonCache(selfNameRealm(), parsed)
    if changed then
        Tracker.RequestCapture()   -- fold boon slots into the record + fire STATE_CHANGED
    end
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

-- Warlock soulstone availability (item 6): a created soulstone item is in bags,
-- OR the Create Soulstone spell is off cooldown (so one can be made now).
local function captureSoulstone(rec)
    rec.soulstoneReady = false
    if rec.classTag ~= "WARLOCK" then return end
    -- 1) A soulstone reagent already sitting in bags.
    if C_Item and C_Item.GetItemCount then
        for i = 1, #SOULSTONE_ITEMS do
            if (C_Item.GetItemCount(SOULSTONE_ITEMS[i]) or 0) > 0 then
                rec.soulstoneReady = true
                return
            end
        end
    end
    -- 2) Create Soulstone spell off cooldown (C_Spell in 11509).
    if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(SPELL_CREATE_SOULSTONE)
        if type(cd) == "table" then
            -- Ready when there is no active cooldown (duration 0 or elapsed).
            local dur = cd.duration or 0
            local start = cd.startTime or 0
            if dur <= 1.6 then                      -- <=GCD => effectively ready
                rec.soulstoneReady = true
            elseif start > 0 and (start + dur) - GetTime() <= 0 then
                rec.soulstoneReady = true
            end
        end
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
                if def.prefix ~= "" and nm:find(def.prefix, 1, true) == 1 then
                    slots[def.slot] = {
                        duration = auraRemaining(aura),
                        option   = 0,     -- per-aura option code (later waves)
                        source   = 0,     -- 0 = live/self (Store.AURA_SOURCE.LIVE)
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

    -- Chronoboon fields (count sourced from the tooltip parse cache).
    rec.chronoboonActive = chronoActive
    if chronoActive then
        rec.chronoboonLastSeen = ns.Store.Now()
        -- Fold the parsed booned buffs into the aura slots as source = BOON so
        -- the dashboard shows their frozen durations with "(Boon)" (item 37).
        -- Booned buffs are NOT live on the character, so only inject slots that
        -- live capture did not already fill.
        local parsed = Tracker._boonParsed
        if parsed then
            for slot, cell in pairs(parsed.slots) do
                if not slots[slot] then
                    slots[slot] = { duration = cell.duration or 0, option = 0, source = BOON_SOURCE }
                end
            end
            if parsed.dmf then dmfInBoon = true end
            rec.boonCount = parsed.count or Tracker._boonTooltipCount or 0
        else
            rec.boonCount = Tracker._boonTooltipCount or 0
        end
    else
        rec.boonCount = 0
        -- Unboon: drop any boon-sourced state so stale frozen slots don't linger.
        if Tracker._boonParsed then
            Tracker._boonParsed = nil
            persistBoonCache(rec.nameRealm, nil)
        end
    end

    rec.auraStates = slots

    -- DMF lifecycle: holding a fortune (live OR stored-in-boon) means the daily
    -- has been taken, so the cooldown is active. offlineSince stays 0 while
    -- online; the store stamps it at logout and clears it after ~8h offline.
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
    captureSoulstone(rec)
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

    -- Rehydrate the booned-buff snapshot from the persisted cache so a relog
    -- keeps showing "(Boon)" durations before the next tooltip hover (item 37).
    Tracker.RehydrateBoonCache()

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

----------------------------------------------------------------------
-- Self-tests (pure Lua; registered as suite "tracker")
----------------------------------------------------------------------

local function testBoonParsing(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Duration parsing across the reference formats.
    ck(Tracker.ParseBoonDuration("Fengus' Ferocity (119m)") == 119 * 60, "(119m) -> 7140s")
    ck(Tracker.ParseBoonDuration("Rallying Cry (1h 59m)") == 3600 + 59 * 60, "(1h 59m) -> 7140s")
    ck(Tracker.ParseBoonDuration("Warchief's Blessing (1h)") == 3600, "(1h) -> 3600s")
    ck(Tracker.ParseBoonDuration("Songflower Serenade (25m)") == 25 * 60, "(25m) -> 1500s")
    ck(Tracker.ParseBoonDuration("no parens here") == nil, "no duration -> nil")

    -- Line identity -> slot + DMF detection (incl. the two new slots).
    local slot, dur, dmf = Tracker.ParseBoonLine("Fengus' Ferocity (119m)")
    ck(slot == 6 and dur == 7140 and dmf == false, "Fengus -> slot 6, 7140s, not DMF")
    slot, dur, dmf = Tracker.ParseBoonLine("Sayge's Dark Fortune: Damage (57m)")
    ck(slot == 5 and dmf == true, "Sayge -> slot 5, DMF flagged")
    slot = Tracker.ParseBoonLine("Rallying Cry of the Dragonslayer (55m)")
    ck(slot == 1, "Rallying Cry -> slot 1")
    slot = Tracker.ParseBoonLine("Battle Shout (110m)")
    ck(slot == 9, "Battle Shout -> slot 9 (new)")
    ck(Tracker.ParseBoonLine("Chronoboon Displacement") == nil, "boon aura title itself not a slot")
    ck(Tracker.ParseBoonLine("") == nil, "empty line -> nil")
end

-- REGRESSION (owner live report): the Supercharged Chronoboon Displacer renders
-- ALL suspended effects inside ONE tooltip FontString, so the old per-line parse
-- booned only slot 1 (Rallying Cry) and even showed Fengus' 119m ("1h 59m") on
-- it. ParseBoonBlock must resolve all seven stored buffs in ONE scan, each with
-- its OWN minute value. Fixture is the owner's exact 7-line tooltip.
local function testBoonBlock(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local FIX =
        "World effects suspended:\n" ..
        "Fengus' Ferocity (119m)\n" ..
        "Mol'dar's Moxie (120m)\n" ..
        "Rallying Cry of the Dragonslayer (115m)\n" ..
        "Warchief's Blessing (60m)\n" ..
        "Spirit of Zandalar (114m)\n" ..
        "Songflower Serenade (59m)\n" ..
        "Sayge's Dark Fortune (119m)"

    local slots, dmf = Tracker.ParseBoonBlock(FIX)
    -- All seven tracked slots resolve, each with its OWN duration:
    ck(slots[1] and slots[1].duration == 115 * 60, "ony/RallyingCry -> slot1, 115m")
    ck(slots[2] and slots[2].duration ==  60 * 60, "rend/Warchief -> slot2, 60m")
    ck(slots[3] and slots[3].duration == 114 * 60, "zg/Zandalar -> slot3, 114m")
    ck(slots[4] and slots[4].duration ==  59 * 60, "songflower -> slot4, 59m")
    ck(slots[5] and slots[5].duration == 119 * 60, "dmf/Sayge -> slot5, 119m")
    ck(slots[6] and slots[6].duration == 119 * 60, "dmtAP/Fengus -> slot6, 119m")
    ck(slots[7] and slots[7].duration == 120 * 60, "dmtStam/Mol'dar -> slot7, 120m")
    ck(dmf == true, "Sayge present -> dmf flagged")

    local n = 0; for _ in pairs(slots) do n = n + 1 end
    ck(n == 7, "all 7 tracked slots resolved in one scan (got " .. n .. ")")

    -- Guard the exact visible symptom: slot 1 must NOT inherit Fengus' 119m.
    ck(not (slots[1] and slots[1].duration == 119 * 60), "slot1 must not show Fengus' 119m (1h59m)")

    -- Apostrophe robustness: same fixture with typographic apostrophes (U+2019)
    -- must still resolve the apostrophe-named DMT buffs.
    local CURLY = FIX:gsub("'", "\226\128\153")
    local cs = Tracker.ParseBoonBlock(CURLY)
    ck(cs[6] and cs[6].duration == 119 * 60, "curly-apos Fengus -> slot6, 119m")
    ck(cs[7] and cs[7].duration == 120 * 60, "curly-apos Mol'dar -> slot7, 120m")
end

function Tracker.RunSelfTests(verbose)
    local suites = {
        { name = "boon parsing", fn = testBoonParsing },
        { name = "boon block (owner 7-line fixture)", fn = testBoonBlock },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local f = {}
        local ok = pcall(suite.fn, f)
        local passed = ok and #f == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS tracker/" .. suite.name)
            elseif not ok then ns:Print("  FAIL tracker/" .. suite.name .. " :: error in test")
            else for _, m in ipairs(f) do ns:Print("  FAIL tracker/" .. suite.name .. " :: " .. m) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("tracker", Tracker.RunSelfTests)
end
