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

-- Chronoboon Displacer item IDs (Classic Era). The item's USE cooldown is what we
-- surface as rec.itemCooldown so the roster card can show "when can I re-boon".
-- 184937 = Chronoboon Displacer, 184938 = Super-charged Chronoboon Displacer.
-- Both are probed and the max remaining is taken; a character that owns neither
-- simply gets no cooldown (GetItemCooldown returns nothing for an absent item).
local CHRONOBOON_ITEMS = { 184937, 184938 }

-- Created Soulstone reagent item IDs (any in bags => a soulstone is available).
-- Minor / Lesser / (regular) / Greater / Major Soulstone. Item 6.
local SOULSTONE_ITEMS = { 5232, 16892, 16893, 16895, 16896 }
-- Create Soulstone spell (rank-agnostic; highest known rank id is fine for a
-- cooldown probe — a ready spell also means a soulstone can be made). [verify id]
local SPELL_CREATE_SOULSTONE = 20758

-- FFF seasonal world buff. The behavioural spec names it "Fire Festival Fury"
-- and pins it to spell IDs 29338 / 29846, which are now the PRIMARY matcher
-- (see BUFF_SPELL_IDS). This name prefix is only the localization fallback and
-- replaces the former self-declared placeholder (A6.6).
local FFF_AURA_PREFIX = "fire festival fury"

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

-- Spell ID -> Daseeki slot. This is the PRIMARY matcher (A6.4): it is immune to
-- client localization and to the alternate IDs Blizzard shipped for the reissued
-- world buffs, which a name prefix cannot see. Name matching (BUFF_SLOTS above)
-- stays as the fallback for any ID we have not enumerated.
--
-- IDs are unprotectable game facts, taken from the behavioural spec's tracked-set
-- table. Slot numbers are Daseeki's own layout (BUFF_SLOTS), NOT the spec's.
local BUFF_SPELL_IDS = {
    -- slot 1 — Rallying Cry of the Dragonslayer (Ony); reissue 355363
    [22888] = 1, [355363] = 1,
    -- slot 2 — Warchief's Blessing (Rend); reissue 355366
    [16609] = 2, [355366] = 2,
    -- slot 3 — Spirit of Zandalar (ZG); reissue 355365
    [24425] = 3, [355365] = 3,
    -- slot 4 — Songflower Serenade
    [15366] = 4,
    -- slot 5 — Sayge's Dark Fortune, all 8 fortune variants
    [23768] = 5, [23769] = 5, [23767] = 5, [23766] = 5,
    [23738] = 5, [23737] = 5, [23735] = 5, [23736] = 5,
    -- slot 6 — Fengus' Ferocity (DMT AP)
    [22817] = 6,
    -- slot 7 — Mol'dar's Moxie (DMT Stam)
    [22818] = 7,
    -- slot 8 — Slip'kik's Savvy (DMT SP)
    [22820] = 8,
    -- slot 9 — Battle Shout, the NPC ("Fallen Hero") cast. A PLAYER self-cast
    -- Battle Shout is a different spell ID and therefore only ever reaches slot 9
    -- through the name fallback, where the 240 s filter below rejects it.
    [25101] = 9,
    -- slot 10 — Fire Festival Fury (seasonal)
    [29338] = 10, [29846] = 10,
}

-- Slot indices the capture guards need by name.
local SLOT_REND = 2      -- Warchief's Blessing
local SLOT_BS   = 9      -- Battle Shout

-- A6.3: a Battle Shout matched by NAME ONLY with this much time or less left is a
-- player self-cast (base duration 2 min), not the "Fallen Hero" world buff. An
-- ID-matched (25101) Battle Shout is always accepted regardless of remaining.
local BS_SELFCAST_MAX = 240

-- A6.1: a slot known live during teardown but carrying no readable duration is
-- given a synthetic one rather than being dropped.
local SYNTH_DURATION_REND  = 3600
local SYNTH_DURATION_OTHER = 7200

-- A6.2 / A17.2: a scan taken within this many seconds of PLAYER_ENTERING_WORLD is
-- treated as partial (the aura list and the map position are not warm yet).
local ENTERING_WORLD_GRACE = 2

-- A9.2: the item-cooldown API is ignored for this long after entering the world —
-- the documented post-loading-screen race that produces stuck cooldowns.
local COOLDOWN_GRACE = 3

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

-- Escape a string's non-ASCII / non-printable bytes to \ddd so a typographic
-- apostrophe (U+2019 -> \226\128\153) is visible in the debug dump. Pure.
local function byteEscape(s)
    if not s or s == "" then return "" end
    return (s:gsub("[^\32-\126]", function(c) return "\\" .. string.byte(c) end))
end

-- Return the BUFF_SLOTS slot index whose prefix BEGINS the given (raw) buff
-- name, or nil. normName folds typographic apostrophes to ASCII first, so a
-- live buff rendered "Warchief\226\128\153s Blessing" (U+2019) still matches the
-- ASCII-apostrophe prefix. This is the single matcher used by the live aura scan
-- AND the self-test, so the wire behaviour and the test can never drift apart.
function Tracker.MatchBuffSlot(name)
    local nm = normName(name)
    if nm == "" then return nil end
    for s = 1, #BUFF_SLOTS do
        local def = BUFF_SLOTS[s]
        if def.prefix ~= "" and nm:find(def.prefix, 1, true) == 1 then
            return def.slot
        end
    end
    return nil
end

-- Spell-ID matcher (A6.4, PRIMARY). Returns the slot or nil.
function Tracker.MatchBuffSlotByID(spellID)
    if type(spellID) ~= "number" then return nil end
    return BUFF_SPELL_IDS[spellID]
end

-- The single aura matcher used by the live scan. Spell ID first, then the name
-- prefix. Returns (slot, matchedByID) so the caller can apply the ID-only
-- exemptions (the Battle Shout self-cast filter). Pure + self-tested.
function Tracker.MatchAura(spellID, name)
    local slot = Tracker.MatchBuffSlotByID(spellID)
    if slot then return slot, true end
    return Tracker.MatchBuffSlot(name), false
end

----------------------------------------------------------------------
-- Teardown / loading-screen latch (A6.1, A6.2, A17.2, A9.2)
--
-- During logout and while leaving the world the aura, map and item-cooldown APIs
-- return nothing or garbage. Capturing then is what wiped every buff off the
-- record at logout. The latch below is the single gate all three capture pieces
-- consult.
--
-- Event ordering (Classic Era 1.15.9):
--   * PLAYER_LEAVING_WORLD fires before EVERY loading screen — logout, /reload,
--     and ordinary instance / continent transitions alike. It is NOT a
--     logout-only signal, so the latch must RE-ARM.
--   * PLAYER_ENTERING_WORLD fires on the far side of every loading screen except
--     the final one of a logout. It is therefore the re-arm point: it clears
--     _leavingWorld and stamps _enteredWorldAt, which opens the short
--     ENTERING_WORLD_GRACE / COOLDOWN_GRACE windows during which a scan is still
--     treated as partial (A6.2). Once that grace expires a normal full scan runs
--     and the new zone's buffs/location/cooldowns are captured for real — so a
--     loading-screen zone change still updates the record, it is just deferred by
--     ~2 s instead of writing the cold-API emptiness.
--   * PLAYER_LOGOUT sets _loggingOut, which is never cleared: the session ends.
----------------------------------------------------------------------

Tracker._leavingWorld   = false
Tracker._loggingOut     = false
Tracker._enteredWorldAt = nil   -- GetTime() frame stamp, nil until the first EW

function Tracker.IsTeardown()
    return (Tracker._loggingOut or Tracker._leavingWorld) and true or false
end

-- Seconds since the last PLAYER_ENTERING_WORLD, or math.huge before the first.
function Tracker.SinceEnteringWorld()
    local at = Tracker._enteredWorldAt
    if not at then return math.huge end
    local now = (GetTime and GetTime()) or 0
    local d = now - at
    if d < 0 then return 0 end
    return d
end

function Tracker.InEnteringWorldGrace(window)
    return Tracker.SinceEnteringWorld() < (window or ENTERING_WORLD_GRACE)
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

-- Experience + rested pool (self only). A sub-60 character carries live XP into
-- the current level plus its rested (double-XP) pool; a max-level (>=60) character
-- earns no XP, so all three fields are stored as 0/0/0 (the UI shows "Level 60"
-- only — no XP/rested line). The >=60 gate matches instances.lua sampleXP() so the
-- two capture paths agree on what "max level" means. restedXP is 0 when unrested
-- (GetXPExhaustion() returns nil off-rest). All three are Classic Era 1.15.9
-- globals — UnitXP / UnitXPMax are already used live in instances.lua on 11509,
-- GetXPExhaustion is the stock rested-pool global. Values ride the u32 wire fields
-- (see protocol.lua EncodeCharacter) which clamp to the u32 range.
local function captureXP(rec)
    local level = rec.level or (UnitLevel and UnitLevel("player")) or 0
    if level >= 60 or not (UnitXP and UnitXPMax) then
        rec.xp, rec.xpMax, rec.restedXP = 0, 0, 0
        return
    end
    rec.xp       = UnitXP("player") or 0
    rec.xpMax    = UnitXPMax("player") or 0
    rec.restedXP = (GetXPExhaustion and GetXPExhaustion()) or 0
    -- Defensive: if xpMax reads 0 below 60 (API not yet warm on a fresh login),
    -- zero the trio so Store.RestedPercent yields nil rather than dividing by 0.
    if rec.xpMax == 0 then rec.xp, rec.restedXP = 0, 0 end
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

-- Zone / location: coordinate overrides first, then the game's zone text.
-- (Owner task 10) The manual-location override is no longer blended into the
-- captured record — rec.location is always the game-captured zone. The free-text
-- per-character annotation now lives in the separate Notes field (Store.*Note);
-- Store.GetManualLocation/SetManualLocation remain for data preservation but are
-- no longer consumed at capture time.
--
-- (A17.2) Two guards protect the stored value from teardown / loading-screen
-- garbage: the location is FROZEN entirely while logging out or leaving the
-- world, and a coordinate override is not downgraded to a plain zone name within
-- ENTERING_WORLD_GRACE of entering the world (the map position reads cold or
-- (0,0) there, so ResolveCoordinateOverride would return nil for a character who
-- is still standing in the override box).
local function isOverrideLabel(loc)
    if not loc or loc == "" then return false end
    local db = ns.Store.GetSettings()
    local overrides = db and db.coordinateOverrides
    if not overrides then return false end
    for i = 1, #overrides do
        local o = overrides[i]
        if (o.label or o.name) == loc then return true end
    end
    return false
end

local function captureLocation(rec)
    -- A17.2: teardown freeze. C_Map returns nothing mid-unload, so the last
    -- known-good location is what the character logs out holding.
    if Tracker.IsTeardown() then return end

    local override = Tracker.ResolveCoordinateOverride()
    if override then
        rec.location = override
        return
    end

    -- A17.2: post-loading-screen grace — do not demote a coordinate override to a
    -- zone name until the map APIs are warm.
    if Tracker.InEnteringWorldGrace(ENTERING_WORLD_GRACE) and isOverrideLabel(rec.location) then
        return
    end

    local sub = GetSubZoneText()
    local zone = GetRealZoneText()
    local loc
    if sub and sub ~= "" then
        loc = sub
    elseif zone and zone ~= "" then
        loc = zone
    else
        loc = GetMinimapZoneText()
    end
    -- Never overwrite a good location with nothing (same family as the freeze:
    -- all three getters read empty while the world is still streaming in).
    if loc and loc ~= "" then
        rec.location = loc
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

-- Hearthstone + Chronoboon Displacer remaining cooldowns (seconds).
-- rec.itemCooldown now carries the Chronoboon Displacer USE cooldown remaining
-- (max across the two Era item IDs) — it was previously a hardcoded-0 placeholder
-- but is already an existing u16 wire field, so repurposing it needs no schema
-- bump. Both values are clamped to the u16 range (<=65535s) before the wire.
local function itemCooldownRemaining(itemID)
    local start, duration, enable = C_Container.GetItemCooldown(itemID)
    if start and duration and duration > 0 and (enable == nil or enable == 1) then
        local rem = (start + duration) - GetTime()
        if rem > 0 then return rem end
    end
    return 0
end

-- Carry a stored remaining-seconds cooldown forward across a suppressed capture,
-- decaying it by the time that has passed since it was last actually read. The
-- storage model is unchanged (remaining seconds, not a start epoch — that is a
-- later designed change); this only keeps the preserved value honest, because
-- Store.WriteSelfCharacter re-stamps lastDataUpdate on every capture and the UI
-- decays against that stamp.
local function carryCooldown(v, elapsed)
    v = (tonumber(v) or 0) - elapsed
    if v < 0 then v = 0 end
    return math.floor(v)
end

-- Seconds since the last trusted read of a given piece, or 0 when we have no
-- in-session reference (a fresh login must FREEZE, never decay by the whole
-- offline duration — that would wipe the record the moment we log in).
local function sinceCapture(stamp, now)
    if not stamp then return 0 end
    local d = now - stamp
    if d < 0 then return 0 end
    return d
end

Tracker._cdCapturedAt   = nil   -- Store.Now() of the last trusted cooldown read
Tracker._auraCapturedAt = nil   -- Store.Now() of the last aura slot write

local function captureCooldowns(rec)
    -- A9.2: BAG_UPDATE_COOLDOWN and the login capture both hit C_Container while
    -- it is cold right after a loading screen, which is the documented race that
    -- produces stuck multi-thousand-minute cooldowns. Suppress the read during
    -- teardown and for COOLDOWN_GRACE seconds after entering the world; carry the
    -- previous values forward instead of writing the API's garbage (or its 0).
    if Tracker.IsTeardown() or Tracker.InEnteringWorldGrace(COOLDOWN_GRACE) then
        local now = ns.Store.Now()
        local elapsed = sinceCapture(Tracker._cdCapturedAt, now)
        rec.hearthstoneCD = carryCooldown(rec.hearthstoneCD, elapsed)
        rec.itemCooldown  = carryCooldown(rec.itemCooldown, elapsed)
        Tracker._cdCapturedAt = now
        return
    end

    rec.itemCooldown = 0
    rec.hearthstoneCD = 0
    if C_Container and C_Container.GetItemCooldown then
        rec.hearthstoneCD = math.min(65535, math.floor(itemCooldownRemaining(ITEM_HEARTHSTONE)))
        -- Chronoboon Displacer: max remaining across the base + super-charged IDs.
        local best = 0
        for i = 1, #CHRONOBOON_ITEMS do
            local rem = itemCooldownRemaining(CHRONOBOON_ITEMS[i])
            if rem > best then best = rem end
        end
        rec.itemCooldown = math.min(65535, math.floor(best))
    end
    Tracker._cdCapturedAt = ns.Store.Now()
end

-- A6.1: a slot the record knows was live but which carries no readable duration
-- gets a synthetic one rather than reading as "missing" on every dashboard.
local function synthDuration(slot)
    if slot == SLOT_REND then return SYNTH_DURATION_REND end
    return SYNTH_DURATION_OTHER
end

-- Copy the previous capture's slots forward into `into` for every slot the
-- current (untrusted / partial / skipped) scan did not fill. LIVE slots decay by
-- the time elapsed since they were written and drop out once they hit zero;
-- BOON-sourced slots are frozen (a suspended buff does not tick).
local function preserveSlots(prev, elapsed, into)
    if type(prev) ~= "table" then return into end
    for slot, cell in pairs(prev) do
        if type(cell) == "table" and into[slot] == nil then
            local src = cell.source or 0
            local dur = tonumber(cell.duration) or 0
            if src ~= BOON_SOURCE then
                if dur <= 0 then
                    dur = synthDuration(slot)     -- known live, duration unreadable
                else
                    dur = dur - elapsed
                end
            end
            if dur > 0 then
                into[slot] = {
                    duration = math.floor(dur),
                    option   = cell.option or 0,
                    source   = src,
                }
            end
        end
    end
    return into
end

-- Scan player buffs, fill the 10 aura slots, track chronoboon + DMF.
--
-- Three trust states (A6.1 / A6.2):
--   TEARDOWN  — logging out or leaving the world. The aura API returns nothing,
--               so we do not scan at all: every prior slot is carried forward and
--               the chronoboon / DMF flags are left untouched. This is the fix for
--               "every buff is wiped from the record at logout".
--   PARTIAL   — the scan saw ZERO buffs, or we are inside ENTERING_WORLD_GRACE of
--               a loading screen. Whatever the scan did find is trusted and wins,
--               but slots it did not find are carried forward instead of being
--               written as empty, and the boon state is not cleared on this
--               evidence.
--   FULL      — normal. The scan is authoritative; anything absent is absent.
local function captureAuras(rec)
    local now = ns.Store.Now()
    local prev = rec.auraStates
    local elapsed = sinceCapture(Tracker._auraCapturedAt, now)

    if Tracker.IsTeardown() then
        rec.auraStates = preserveSlots(prev, elapsed, {})
        Tracker._auraCapturedAt = now
        return
    end

    local slots = {}
    local chronoActive = false
    local dmfInBoon = false
    local sawAnyBuff = 0

    if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        for i = 1, 40 do
            local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
            if not aura then break end
            sawAnyBuff = sawAnyBuff + 1
            -- Apostrophe-normalized name for EVERY comparison below. The live
            -- client can render buff names with a typographic apostrophe (U+2019),
            -- so a plain lower() missed "Warchief's Blessing" et al and left the
            -- slot dark (owner-observed). normName folds it to ASCII first.
            local nm = normName(aura.name)
            local rem = auraRemaining(aura)

            -- World-buff slot assignment. Spell ID first (A6.4), name prefix as
            -- the fallback; shared matcher so the live path, the self-test and
            -- the boon-tooltip parse can never drift apart.
            local slot, byID = Tracker.MatchAura(aura.spellId or aura.spellID, aura.name)

            -- A6.3: reject a NAME-matched Battle Shout that is short enough to be
            -- the player's own 2-minute self-cast. An ID match (25101 = the NPC
            -- cast) is authoritative and skips the filter.
            if slot == SLOT_BS and not byID and rem <= BS_SELFCAST_MAX then
                slot = nil
            end

            if slot then
                slots[slot] = {
                    duration = rem,
                    option   = 0,     -- per-aura option code (later waves)
                    source   = 0,     -- 0 = live/self (Store.AURA_SOURCE.LIVE)
                }
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

    -- A6.2: a scan that saw nothing at all, or one taken inside the loading-screen
    -- grace, is partial evidence — never proof that the buffs are gone.
    local partial = (sawAnyBuff == 0) or Tracker.InEnteringWorldGrace(ENTERING_WORLD_GRACE)
    if partial then
        preserveSlots(prev, elapsed, slots)
    end

    -- Chronoboon fields (count sourced from the tooltip parse cache).
    if chronoActive then
        rec.chronoboonActive = true
        rec.chronoboonLastSeen = now
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
    elseif partial then
        -- A6.2: "no chronoboon aura found" from a partial scan is not an unboon.
        -- Leave chronoboonActive / boonCount / the persisted boon cache alone.
        if rec.chronoboonActive and Tracker._boonParsed and Tracker._boonParsed.dmf then
            dmfInBoon = true
        end
    else
        rec.chronoboonActive = false
        rec.boonCount = 0
        -- Unboon: drop any boon-sourced state so stale frozen slots don't linger.
        if Tracker._boonParsed then
            Tracker._boonParsed = nil
            persistBoonCache(rec.nameRealm, nil)
        end
    end

    rec.auraStates = slots
    Tracker._auraCapturedAt = now

    -- DMF lifecycle: holding a fortune (live OR stored-in-boon) means the daily
    -- has been taken, so the cooldown is active. offlineSince stays 0 while
    -- online; the store stamps it at logout and clears it after ~8h offline.
    -- A partial scan must not clear the flag either.
    if partial and not dmfInBoon then
        dmfInBoon = rec.dmfInBoon and true or false
    end
    rec.dmfInBoon = dmfInBoon
    if dmfInBoon then
        rec.dmfCooldownActive = true
        rec.dmfCooldown = rec.dmfCooldown or {}
        rec.dmfCooldown.offlineSince = 0
    end
end

-- Exposed for the self-test harness (pure-Lua fixtures drive these directly;
-- Tracker.Capture itself needs the whole live client).
Tracker._captureAuras     = captureAuras
Tracker._captureLocation  = captureLocation
Tracker._captureCooldowns = captureCooldowns

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
            -- normName (not plain lower): raid names carry apostrophes
            -- ("Zul'Gurub", "Temple of Ahn'Qiraj"), so fold typographic ones to
            -- ASCII to match the ASCII-apostrophe needles in RAID_NAME_MAP.
            local lname = normName(name)
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

----------------------------------------------------------------------
-- A10.1 — the state-push CHANGE FILTER lives here.
--
-- Capture is bound to UNIT_AURA, BAG_UPDATE_DELAYED, BAG_UPDATE_COOLDOWN,
-- resting, flags, XP and exhaustion. Firing STATE_CHANGED unconditionally at
-- the end of every capture meant a raid produced a continuous stream of full
-- state whispers to every peer plus two backup relays, saturating the 8-token /
-- 1-per-second bucket and starving the heartbeat behind it — which is what made
-- live peers read OFFLINE. We now fire ONLY when the record's content hash
-- (Mesh.StateHash: volatile epochs excluded, aura durations rounded to the
-- minute) differs from the last one we pushed.
--
-- FORCED pushes bypass the filter entirely (spec §9.4 forces on logout, on
-- entering the world, and on boon/unboon casts):
--   * PLAYER_LEAVING_WORLD / PLAYER_LOGOUT  -- the final state must always land
--   * 1.0s after PLAYER_ENTERING_WORLD      -- spec §9.4
--   * every FORCE_REFRESH_INTERVAL of quiet -- OURS, see below.
--
-- OURS: the reference has no periodic forced push at all (§9.4 lists only the
-- event-driven forces). A max-quiet refresh is cheap insurance that a peer whose
-- direct send was dropped, or who joined the mesh while we were idle, still
-- converges without waiting for the next real state change. 5 minutes is well
-- inside the dashboard's 30-minute stale flag and costs at most one whisper per
-- peer per 5 minutes.
----------------------------------------------------------------------

Tracker.FORCE_REFRESH_INTERVAL = 300   -- OURS: max quiet before a forced push
Tracker._lastPushHash = nil            -- content hash of the last fired state
Tracker._lastPushAt   = 0              -- Store.Now() of that fire

-- PURE-ish decision: should this capture fire STATE_CHANGED?
-- Returns fire(bool), hash(string|nil). A nil hash (no Mesh yet, or a hasher
-- that refused the record) always fires — the filter must never be able to
-- silence the mesh through an error path.
function Tracker.ShouldPush(rec, nowT, force)
    local Mesh = ns.Mesh
    local hash = Mesh and Mesh.StateHash and Mesh.StateHash(rec) or nil
    if force or not hash then return true, hash end
    if hash ~= Tracker._lastPushHash then return true, hash end
    if (nowT - (Tracker._lastPushAt or 0)) >= Tracker.FORCE_REFRESH_INTERVAL then
        return true, hash
    end
    return false, hash
end

function Tracker.Capture(force)
    if not ns.state.loggedIn then return end
    local nameRealm = selfNameRealm()
    local rec = ns.Store.EnsureSelfCharacter(nameRealm)
    if not rec then return end

    captureIdentity(rec)
    captureXP(rec)
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

    -- A10.1 change filter: the record is ALWAYS written to the store above (the
    -- local dashboard stays live); only the MESH signal is gated.
    local fire, hash = Tracker.ShouldPush(rec, rec.lastSeen, force)
    if not fire then
        Tracker._capturesFiltered = (Tracker._capturesFiltered or 0) + 1
        return
    end
    Tracker._lastPushHash = hash
    Tracker._lastPushAt   = rec.lastSeen

    -- Local signal for the mesh layer (wave N2). No network I/O here.
    ns:Fire("STATE_CHANGED", nameRealm, rec, force and true or nil)
end

-- Coalesce bursty events into one capture on the next frame tick. A forced
-- request wins the coalesce: if a plain capture is already queued, the force
-- flag is promoted onto it rather than dropped.
function Tracker.RequestCapture(force)
    if force then Tracker._forcePending = true end
    if Tracker._captureQueued then return end
    Tracker._captureQueued = true
    C_Timer.After(0, function()
        Tracker._captureQueued = false
        local f = Tracker._forcePending
        Tracker._forcePending = nil
        ns:SafeCall(Tracker.Capture, f)
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

    -- Teardown / loading-screen latch (see IsTeardown above). Registered BEFORE
    -- the generic capture events so the latch is already correct by the time the
    -- PLAYER_ENTERING_WORLD capture is queued.
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        -- Re-arm: this is the far side of a loading screen, so we are back in a
        -- live world. Open the partial-scan grace windows.
        Tracker._leavingWorld = false
        Tracker._enteredWorldAt = (GetTime and GetTime()) or 0
        -- A10.1 / spec §9.4: a FORCED push 1.0s after entering the world, once
        -- the aura and bag APIs have warmed up. This is the push that re-seeds
        -- every peer after a /reload or a zone change, and it must bypass the
        -- change filter (our pre-loading-screen hash is very often identical).
        if C_Timer and C_Timer.After then
            C_Timer.After(1.0, function() ns:SafeCall(Tracker.Capture, true) end)
        end
    end)

    ns:RegisterEvent("PLAYER_LEAVING_WORLD", function()
        Tracker._leavingWorld = true
        -- Capture SYNCHRONOUSLY, not via RequestCapture: C_Timer.After(0) is not
        -- guaranteed another frame during teardown, and the mesh's final state
        -- push must carry the frozen (real) buffs rather than a cold-API scan.
        -- FORCED: the teardown capture preserves slots verbatim, so its hash is
        -- usually identical to the last one — the filter would eat the final
        -- push that the whole logout-flush path depends on.
        ns:SafeCall(Tracker.Capture, true)
    end)

    ns:RegisterEvent("PLAYER_LOGOUT", function()
        Tracker._loggingOut = true
        ns:SafeCall(Tracker.Capture, true)
    end)

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
        "PLAYER_XP_UPDATE",       -- XP earned -> refresh xp/xpMax (debounced)
        "UPDATE_EXHAUSTION",      -- rested pool changed -> refresh restedXP
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
-- Diagnostic: /nexus debug auras
--
-- Ground truth for the apostrophe-matching bug. Prints every live player buff:
-- its raw name, the byte-escaped form (so a typographic apostrophe shows as
-- \226\128\153), and which dashboard slot it matched (or "none"). If the
-- normalization ever fails to cure a dark slot in-game, this shows exactly which
-- byte sequence the client rendered so the fix can target it.
----------------------------------------------------------------------

function Tracker.DebugAuras()
    if not (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex) then
        ns:Print("debug auras: C_UnitAuras.GetBuffDataByIndex unavailable")
        return
    end
    ns:Print(string.format("capture gate — teardown=%s leaving=%s logout=%s sinceEW=%.1fs",
        tostring(Tracker.IsTeardown()), tostring(Tracker._leavingWorld),
        tostring(Tracker._loggingOut), Tracker.SinceEnteringWorld()))
    ns:Print("player buffs — [index] raw :: bytes :: id :: slot(via) :: remaining")
    local any = false
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        any = true
        local raw = aura.name or "?"
        local id = aura.spellId or aura.spellID
        local slot, byID = Tracker.MatchAura(id, raw)
        local rem = auraRemaining(aura)
        local via = slot and (byID and "id" or "name") or "-"
        local note = ""
        if slot == SLOT_BS and not byID and rem <= BS_SELFCAST_MAX then
            note = "  <- REJECTED (self-cast Battle Shout <=240s)"
        end
        ns:Print(string.format("  [%d] %s :: %s :: %s :: %s(%s) :: %ds%s",
            i, raw, byteEscape(raw), tostring(id),
            slot and ("slot " .. slot) or "none", via, rem, note))
    end
    if not any then ns:Print("  (no player buffs)") end
end

if ns.RegisterDebugCommand then
    ns:RegisterDebugCommand("auras", function() Tracker.DebugAuras() end)
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

-- MATCHING MATRIX (owner live report): a world buff whose live name renders with
-- a typographic apostrophe (U+2019) must still land in its slot. Every BUFF_SLOTS
-- prefix is asserted to match BOTH the ASCII-apostrophe and the U+2019 rendition
-- of its own name (the curly variant is built by replacing ' with \226\128\153).
local function testLiveAuraMatching(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    for s = 1, #BUFF_SLOTS do
        local def = BUFF_SLOTS[s]
        if def.prefix ~= "" then
            ck(Tracker.MatchBuffSlot(def.prefix) == def.slot,
               "ascii '" .. def.prefix .. "' -> slot " .. def.slot)
            local curly = def.prefix:gsub("'", "\226\128\153")
            ck(Tracker.MatchBuffSlot(curly) == def.slot,
               "typographic-apos '" .. def.prefix .. "' -> slot " .. def.slot)
        end
    end
    -- The exact owner symptom: title-cased "Warchief's Blessing" with U+2019.
    ck(Tracker.MatchBuffSlot("Warchief\226\128\153s Blessing") == 2,
       "Warchief's Blessing (U+2019, title case) -> slot 2")
    -- Apostrophe-heavy DMT names both renditions.
    ck(Tracker.MatchBuffSlot("Mol\226\128\153dar's Moxie") == 7, "Mol'dar (U+2019) -> slot 7")
    ck(Tracker.MatchBuffSlot("Slip'kik's Savvy") == 8, "Slip'kik (ascii) -> slot 8")
    -- Non-buff / empty -> nil.
    ck(Tracker.MatchBuffSlot("Some Random Buff") == nil, "unmatched -> nil")
    ck(Tracker.MatchBuffSlot("") == nil, "empty -> nil")
    ck(Tracker.MatchBuffSlot(nil) == nil, "nil -> nil")
end

-- A6.4 / A6.6: spell-ID-first matching, the alternate reissue IDs, and FFF by ID.
local function testSpellIDMatching(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Every enumerated ID resolves to its slot.
    for id, slot in pairs(BUFF_SPELL_IDS) do
        ck(Tracker.MatchBuffSlotByID(id) == slot, "id " .. id .. " -> slot " .. slot)
    end

    -- The alternate (reissue) ID pairs from the spec land on the SAME slot.
    ck(Tracker.MatchBuffSlotByID(22888) == Tracker.MatchBuffSlotByID(355363), "Ony 22888 == 355363")
    ck(Tracker.MatchBuffSlotByID(24425) == Tracker.MatchBuffSlotByID(355365), "ZG 24425 == 355365")
    ck(Tracker.MatchBuffSlotByID(16609) == Tracker.MatchBuffSlotByID(355366), "Rend 16609 == 355366")
    ck(Tracker.MatchBuffSlotByID(29338) == Tracker.MatchBuffSlotByID(29846), "FFF 29338 == 29846")

    -- A6.6: FFF resolves by ID (both) and by its real name, not the old placeholder.
    ck(Tracker.MatchBuffSlotByID(29338) == 10, "FFF 29338 -> slot 10")
    ck(Tracker.MatchBuffSlotByID(29846) == 10, "FFF 29846 -> slot 10")
    ck(Tracker.MatchBuffSlot("Fire Festival Fury") == 10, "FFF by name -> slot 10")
    ck(Tracker.MatchBuffSlot("Fervor of the First Feast") == nil,
       "retired FFF placeholder prefix no longer matches")

    -- Unknown / non-numeric IDs fall through cleanly.
    ck(Tracker.MatchBuffSlotByID(1) == nil, "unknown id -> nil")
    ck(Tracker.MatchBuffSlotByID(nil) == nil, "nil id -> nil")
    ck(Tracker.MatchBuffSlotByID("22888") == nil, "string id -> nil (no coercion)")

    -- A6.4: the ID matcher BEATS the name matcher. A localized / renamed aura
    -- still lands by ID, and a conflicting name loses.
    local slot, byID = Tracker.MatchAura(22888, "Sammelruf des Drachentoeters")
    ck(slot == 1 and byID == true, "localized Ony name still lands slot 1 by ID")
    slot, byID = Tracker.MatchAura(16609, "Battle Shout")
    ck(slot == 2 and byID == true, "ID 16609 beats the name 'Battle Shout' -> slot 2")
    -- Name fallback still works when the ID is unknown.
    slot, byID = Tracker.MatchAura(999999, "Warchief's Blessing")
    ck(slot == 2 and byID == false, "unknown id falls back to name -> slot 2")
    slot, byID = Tracker.MatchAura(nil, "Songflower Serenade")
    ck(slot == 4 and byID == false, "nil id falls back to name -> slot 4")
    ck(Tracker.MatchAura(nil, "Some Random Buff") == nil, "no id, no name match -> nil")
end

-- Capture guards (A6.1, A6.2, A6.3, A17.2, A9.2). These drive the real capture
-- pieces against stubbed WoW globals and restore every global afterwards, so the
-- suite is self-contained under the headless harness.
local function testCaptureGuards(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- ---- stub scaffolding -------------------------------------------------
    local saved = {
        auras   = _G.C_UnitAuras,
        cont    = _G.C_Container,
        getTime = _G.GetTime,
        sub     = _G.GetSubZoneText,
        zone    = _G.GetRealZoneText,
        mini    = _G.GetMinimapZoneText,
        map     = _G.C_Map,
        now     = ns.Store and ns.Store.Now,
        settings = ns.Store and ns.Store.GetSettings,
    }
    local savedLatch = {
        leaving = Tracker._leavingWorld,
        logout  = Tracker._loggingOut,
        entered = Tracker._enteredWorldAt,
        auraAt  = Tracker._auraCapturedAt,
        cdAt    = Tracker._cdCapturedAt,
        parsed  = Tracker._boonParsed,
    }

    local FRAME = 10000          -- GetTime() base
    local EPOCH = 1700000000     -- Store.Now() base
    local frameNow, epochNow = FRAME, EPOCH

    _G.GetTime = function() return frameNow end
    ns.Store.Now = function() return epochNow end

    local auraList = {}
    _G.C_UnitAuras = { GetBuffDataByIndex = function(_, i) return auraList[i] end }

    -- Build an aura fixture. `rem` seconds of remaining time.
    local function A(name, id, rem)
        return { name = name, spellId = id, expirationTime = frameNow + rem }
    end
    local function setAuras(...) auraList = { ... } end

    local overrides = { { label = "Rend Staging (N)", zone = "Orgrimmar",
                          minX = 0.4, maxX = 0.6, minY = 0.4, maxY = 0.6 } }
    ns.Store.GetSettings = function() return { coordinateOverrides = overrides } end

    local zoneText, subText, miniText = "Orgrimmar", "", ""
    _G.GetRealZoneText    = function() return zoneText end
    _G.GetSubZoneText     = function() return subText end
    _G.GetMinimapZoneText = function() return miniText end
    -- Map position: nil => ResolveCoordinateOverride bails (cold API).
    local mapPos = nil
    _G.C_Map = {
        GetBestMapForUnit = function() return mapPos and 1454 or nil end,
        GetPlayerMapPosition = function()
            if not mapPos then return nil end
            return { GetXY = function() return mapPos[1], mapPos[2] end }
        end,
    }

    local cdStart, cdDuration = 0, 0
    _G.C_Container = {
        GetItemCooldown = function() return cdStart, cdDuration, 1 end,
    }

    -- Reset the latch to "settled, live world" before each case.
    local function settle()
        Tracker._leavingWorld = false
        Tracker._loggingOut   = false
        Tracker._enteredWorldAt = frameNow - 60   -- long past any grace
        Tracker._auraCapturedAt = nil
        Tracker._cdCapturedAt   = nil
        Tracker._boonParsed     = nil
    end

    local function liveSlot(dur) return { duration = dur, option = 0, source = 0 } end

    local ok, err = pcall(function()

    -- ---- A6.1 capture during logout -> slots preserved --------------------
    settle()
    local rec = { auraStates = { [1] = liveSlot(3000), [4] = liveSlot(900) },
                  chronoboonActive = true, boonCount = 3, dmfInBoon = true }
    Tracker._auraCapturedAt = epochNow
    setAuras()                                   -- teardown: API returns nothing
    Tracker._loggingOut = true
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 3000, "logout: slot 1 preserved (3000s)")
    ck(rec.auraStates[4] and rec.auraStates[4].duration == 900,  "logout: slot 4 preserved (900s)")
    ck(rec.chronoboonActive == true, "logout: chronoboonActive not cleared")
    ck(rec.boonCount == 3, "logout: boonCount not cleared")
    ck(rec.dmfInBoon == true, "logout: dmfInBoon not cleared")

    -- Teardown must SKIP the scan outright, not merely distrust an empty one.
    -- Here the API is still handing back one buff mid-unload: a full scan would
    -- overwrite slot 4 with it, drop slot 1, and clear the boon state. It must not.
    settle()
    rec = { auraStates = { [1] = liveSlot(3000), [4] = liveSlot(900) },
            chronoboonActive = true, boonCount = 2 }
    Tracker._auraCapturedAt = epochNow
    setAuras(A("Songflower Serenade", 15366, 111))
    Tracker._loggingOut = true
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 3000,
       "teardown: scan skipped entirely, slot 1 survives a non-empty API")
    ck(rec.auraStates[4] and rec.auraStates[4].duration == 900,
       "teardown: slot 4 kept verbatim, NOT overwritten by the mid-unload read")
    ck(rec.chronoboonActive == true and rec.boonCount == 2,
       "teardown: boon state survives a non-empty mid-unload scan")

    -- Same via PLAYER_LEAVING_WORLD (instance transition uses the same latch).
    settle()
    rec = { auraStates = { [2] = liveSlot(1800) } }
    Tracker._auraCapturedAt = epochNow
    Tracker._leavingWorld = true
    Tracker._captureAuras(rec)
    ck(rec.auraStates[2] and rec.auraStates[2].duration == 1800, "leaving-world: slot 2 preserved")

    -- A6.1 synthetic duration: known live, no readable duration.
    settle()
    rec = { auraStates = { [SLOT_REND] = liveSlot(0), [1] = liveSlot(0) } }
    Tracker._auraCapturedAt = epochNow
    Tracker._loggingOut = true
    Tracker._captureAuras(rec)
    ck(rec.auraStates[SLOT_REND] and rec.auraStates[SLOT_REND].duration == 3600,
       "logout synth: Rend with no duration -> 3600s")
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 7200,
       "logout synth: non-Rend with no duration -> 7200s")

    -- Preserved LIVE slots decay by in-session elapsed; BOON slots stay frozen.
    settle()
    rec = { auraStates = { [1] = liveSlot(3000),
                           [3] = { duration = 5000, option = 0, source = BOON_SOURCE } } }
    Tracker._auraCapturedAt = epochNow - 100
    Tracker._loggingOut = true
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1].duration == 2900, "preserve: live slot decays 100s -> 2900")
    ck(rec.auraStates[3].duration == 5000, "preserve: booned slot frozen at 5000")

    -- A fresh login (no in-session stamp) must FREEZE, never decay by the whole
    -- offline duration -- otherwise the login capture wipes the record.
    settle()
    rec = { auraStates = { [1] = liveSlot(3000) } }
    Tracker._auraCapturedAt = nil
    Tracker._loggingOut = true
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1].duration == 3000, "no in-session stamp -> freeze, no decay")

    -- ---- A6.2 zero-buff scan -> previous kept -----------------------------
    settle()
    rec = { auraStates = { [1] = liveSlot(3000), [4] = liveSlot(900) },
            chronoboonActive = true, boonCount = 2 }
    Tracker._auraCapturedAt = epochNow
    setAuras()                                   -- scan sees ZERO buffs
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 3000, "zero-buff scan: slot 1 kept")
    ck(rec.auraStates[4] and rec.auraStates[4].duration == 900,  "zero-buff scan: slot 4 kept")
    ck(rec.chronoboonActive == true, "zero-buff scan: boon state not cleared")
    ck(rec.boonCount == 2, "zero-buff scan: boonCount not cleared")

    -- Inside the entering-world grace a PARTIAL scan merges: what it found wins,
    -- what it missed is carried forward.
    settle()
    Tracker._enteredWorldAt = frameNow - 1        -- 1s after EW: inside the 2s grace
    rec = { auraStates = { [1] = liveSlot(3000), [4] = liveSlot(900) } }
    Tracker._auraCapturedAt = epochNow
    setAuras(A("Rallying Cry of the Dragonslayer", 22888, 2400))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 2400, "EW grace: scanned slot 1 wins (2400)")
    ck(rec.auraStates[4] and rec.auraStates[4].duration == 900,  "EW grace: unscanned slot 4 carried")

    -- After the grace a full scan is authoritative: the missing buff really is gone.
    settle()
    Tracker._enteredWorldAt = frameNow - 5        -- outside the 2s grace
    rec = { auraStates = { [1] = liveSlot(3000), [4] = liveSlot(900) } }
    Tracker._auraCapturedAt = epochNow
    setAuras(A("Rallying Cry of the Dragonslayer", 22888, 2400))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 2400, "post-grace: slot 1 fresh")
    ck(rec.auraStates[4] == nil, "post-grace: full scan drops the buff that really expired")

    -- ---- A6.3 Battle Shout self-cast filter -------------------------------
    settle()
    rec = { auraStates = {} }
    setAuras(A("Battle Shout", 6673, 110), A("Songflower Serenade", 15366, 1200))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[SLOT_BS] == nil, "BS by name, 110s (<=240) -> REJECTED")
    ck(rec.auraStates[4] ~= nil, "BS rejection does not disturb other slots")

    settle()
    rec = { auraStates = {} }
    setAuras(A("Battle Shout", 6673, 240))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[SLOT_BS] == nil, "BS by name, exactly 240s -> REJECTED (<=)")

    settle()
    rec = { auraStates = {} }
    setAuras(A("Battle Shout", 6673, 241))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[SLOT_BS] and rec.auraStates[SLOT_BS].duration == 241,
       "BS by name, 241s (>240) -> ACCEPTED")

    settle()
    rec = { auraStates = {} }
    setAuras(A("Battle Shout", 25101, 110))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[SLOT_BS] and rec.auraStates[SLOT_BS].duration == 110,
       "BS by ID 25101, 110s -> ACCEPTED (ID match skips the filter)")

    -- ---- A6.4 spell-ID match beats name in the LIVE scan ------------------
    settle()
    rec = { auraStates = {} }
    -- Name says Battle Shout, ID says Warchief's Blessing: the ID must win.
    setAuras(A("Battle Shout", 16609, 3600))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[2] and rec.auraStates[2].duration == 3600, "live scan: ID 16609 -> slot 2")
    ck(rec.auraStates[SLOT_BS] == nil, "live scan: name 'Battle Shout' loses to the ID")

    -- Reissue IDs land live.
    settle()
    rec = { auraStates = {} }
    setAuras(A("(unlocalized)", 355363, 3000), A("(unlocalized)", 355365, 2000),
             A("(unlocalized)", 355366, 1000))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 3000, "live scan: Ony reissue 355363 -> slot 1")
    ck(rec.auraStates[3] and rec.auraStates[3].duration == 2000, "live scan: ZG reissue 355365 -> slot 3")
    ck(rec.auraStates[2] and rec.auraStates[2].duration == 1000, "live scan: Rend reissue 355366 -> slot 2")

    -- ---- A6.6 FFF by ID in the live scan ----------------------------------
    settle()
    rec = { auraStates = {} }
    setAuras(A("Fire Festival Fury", 29338, 600))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[10] and rec.auraStates[10].duration == 600, "live scan: FFF 29338 -> slot 10")

    settle()
    rec = { auraStates = {} }
    setAuras(A("(unlocalized)", 29846, 600))
    Tracker._captureAuras(rec)
    ck(rec.auraStates[10] and rec.auraStates[10].duration == 600, "live scan: FFF 29846 -> slot 10")

    -- ---- A17.2 location freeze + override grace ---------------------------
    settle()
    rec = { location = "Orgrimmar" }
    zoneText, subText, mapPos = "Wrong Zone During Teardown", "", nil
    Tracker._loggingOut = true
    Tracker._captureLocation(rec)
    ck(rec.location == "Orgrimmar", "logout: location frozen at 'Orgrimmar'")

    settle()
    rec = { location = "Orgrimmar" }
    Tracker._leavingWorld = true
    Tracker._captureLocation(rec)
    ck(rec.location == "Orgrimmar", "leaving-world: location frozen")

    -- Inside the grace, an override label is NOT downgraded to a zone name even
    -- though the cold map API makes ResolveCoordinateOverride return nil.
    settle()
    Tracker._enteredWorldAt = frameNow - 1
    rec = { location = "Rend Staging (N)" }
    zoneText, subText, mapPos = "Orgrimmar", "", nil
    Tracker._captureLocation(rec)
    ck(rec.location == "Rend Staging (N)", "EW grace: override label not downgraded")

    -- After the grace, with the map still cold, the zone name legitimately wins.
    settle()
    Tracker._enteredWorldAt = frameNow - 5
    rec = { location = "Rend Staging (N)" }
    Tracker._captureLocation(rec)
    ck(rec.location == "Orgrimmar", "post-grace: override downgrades to the zone name")

    -- A warm map inside the box re-establishes the override immediately.
    settle()
    Tracker._enteredWorldAt = frameNow - 1
    rec = { location = "Somewhere Else" }
    mapPos = { 0.5, 0.5 }
    Tracker._captureLocation(rec)
    ck(rec.location == "Rend Staging (N)", "warm map inside the box -> override wins")

    -- A non-override location is not protected by the grace.
    settle()
    Tracker._enteredWorldAt = frameNow - 1
    rec = { location = "Stormwind City" }
    mapPos, zoneText = nil, "Orgrimmar"
    Tracker._captureLocation(rec)
    ck(rec.location == "Orgrimmar", "EW grace: plain zone name is still updated")

    -- Empty zone text never wipes a good location.
    settle()
    rec = { location = "Orgrimmar" }
    zoneText, subText, miniText, mapPos = "", "", "", nil
    Tracker._captureLocation(rec)
    ck(rec.location == "Orgrimmar", "empty zone text does not wipe the location")
    zoneText, subText, miniText = "Orgrimmar", "", ""

    -- ---- A9.2 cooldown capture suppression --------------------------------
    -- Garbage the cold API would hand us right after a loading screen.
    cdStart, cdDuration = frameNow, 540000        -- 9000 minutes

    settle()
    Tracker._enteredWorldAt = frameNow - 1        -- inside the 3s window
    rec = { hearthstoneCD = 1200, itemCooldown = 600 }
    Tracker._cdCapturedAt = epochNow
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCD == 1200, "EW +1s: hearthstone CD preserved, garbage ignored")
    ck(rec.itemCooldown == 600, "EW +1s: item CD preserved, garbage ignored")

    settle()
    Tracker._enteredWorldAt = frameNow - 2.9      -- still inside the 3s window
    rec = { hearthstoneCD = 1200, itemCooldown = 0 }
    Tracker._cdCapturedAt = epochNow
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCD == 1200, "EW +2.9s: still suppressed")

    settle()
    Tracker._loggingOut = true
    rec = { hearthstoneCD = 1200, itemCooldown = 600 }
    Tracker._cdCapturedAt = epochNow
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCD == 1200 and rec.itemCooldown == 600, "logout: cooldowns frozen")

    -- Preserved cooldowns decay by in-session elapsed (lastDataUpdate re-stamps).
    settle()
    Tracker._loggingOut = true
    rec = { hearthstoneCD = 1200, itemCooldown = 30 }
    Tracker._cdCapturedAt = epochNow - 60
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCD == 1140, "preserved hearthstone CD decays 60s -> 1140")
    ck(rec.itemCooldown == 0, "preserved item CD floors at 0, never negative")

    -- Outside the window the API is trusted again.
    settle()
    Tracker._enteredWorldAt = frameNow - 3.1
    cdStart, cdDuration = frameNow - 100, 3600
    rec = { hearthstoneCD = 0, itemCooldown = 0 }
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCD == 3500, "EW +3.1s: API trusted again -> 3500s")
    ck(Tracker._cdCapturedAt == epochNow, "a trusted read stamps _cdCapturedAt")

    end)

    -- ---- restore ----------------------------------------------------------
    _G.C_UnitAuras        = saved.auras
    _G.C_Container        = saved.cont
    _G.GetTime            = saved.getTime
    _G.GetSubZoneText     = saved.sub
    _G.GetRealZoneText    = saved.zone
    _G.GetMinimapZoneText = saved.mini
    _G.C_Map              = saved.map
    ns.Store.Now          = saved.now
    ns.Store.GetSettings  = saved.settings
    Tracker._leavingWorld   = savedLatch.leaving
    Tracker._loggingOut     = savedLatch.logout
    Tracker._enteredWorldAt = savedLatch.entered
    Tracker._auraCapturedAt = savedLatch.auraAt
    Tracker._cdCapturedAt   = savedLatch.cdAt
    Tracker._boonParsed     = savedLatch.parsed

    if not ok then fails[#fails + 1] = "error in capture-guard fixtures: " .. tostring(err) end
end

-- The teardown latch's re-arm contract (event ordering matters: LEAVING_WORLD
-- also fires on ordinary instance transitions, so it must not be a one-way trip).
local function testTeardownLatch(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local savedGetTime = _G.GetTime
    local savedLatch = { Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt }
    local frameNow = 10000
    _G.GetTime = function() return frameNow end

    local ok, err = pcall(function()
        Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt = false, false, nil
        ck(Tracker.IsTeardown() == false, "settled: not teardown")
        ck(Tracker.SinceEnteringWorld() == math.huge, "before the first EW: no grace window open")
        ck(Tracker.InEnteringWorldGrace(2) == false, "before the first EW: not in grace")

        -- Zoning into an instance: LEAVING_WORLD latches...
        Tracker._leavingWorld = true
        ck(Tracker.IsTeardown() == true, "leaving world: teardown latched")

        -- ...and ENTERING_WORLD on the far side of the loading screen RE-ARMS it.
        Tracker._leavingWorld = false
        Tracker._enteredWorldAt = frameNow
        ck(Tracker.IsTeardown() == false, "entering world: latch re-armed")
        ck(Tracker.InEnteringWorldGrace(2) == true, "entering world: 2s grace open")
        ck(Tracker.InEnteringWorldGrace(3) == true, "entering world: 3s cooldown grace open")

        frameNow = frameNow + 2.5
        ck(Tracker.InEnteringWorldGrace(2) == false, "+2.5s: aura grace closed")
        ck(Tracker.InEnteringWorldGrace(3) == true,  "+2.5s: cooldown grace still open")
        frameNow = frameNow + 1
        ck(Tracker.InEnteringWorldGrace(3) == false, "+3.5s: cooldown grace closed")

        -- Logout is terminal: ENTERING_WORLD never follows, so it does not re-arm.
        Tracker._loggingOut = true
        ck(Tracker.IsTeardown() == true, "logout: teardown latched")
        Tracker._leavingWorld = false
        ck(Tracker.IsTeardown() == true, "logout latch is not cleared by the leaving-world re-arm")
    end)

    _G.GetTime = savedGetTime
    Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt =
        savedLatch[1], savedLatch[2], savedLatch[3]
    if not ok then fails[#fails + 1] = "error in latch fixtures: " .. tostring(err) end
end

-- A10.1 — the change filter, end to end through the real Tracker.Capture.
-- Counts actual STATE_CHANGED fires, so it proves the MESH signal is gated and
-- (just as important) that the local store write is NOT.
local function testChangeFilter(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local saved = {
        auras = _G.C_UnitAuras, cont = _G.C_Container, item = _G.C_Item,
        map = _G.C_Map, getTime = _G.GetTime,
        resting = _G.IsResting, pvp = _G.UnitIsPVP, ffa = _G.UnitIsPVPFreeForAll,
        inInst = _G.IsInInstance, saved = _G.GetNumSavedInstances,
        now = ns.Store.Now, settings = ns.Store.GetSettings,
        ensure = ns.Store.EnsureSelfCharacter, write = ns.Store.WriteSelfCharacter,
        loggedIn = ns.state.loggedIn,
        sub = _G.GetSubZoneText, mini = _G.GetMinimapZoneText,
    }
    local savedLatch = {
        Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt,
        Tracker._auraCapturedAt, Tracker._cdCapturedAt,
        Tracker._lastPushHash, Tracker._lastPushAt,
    }

    local FRAME, EPOCH = 20000, 1700000000
    local frameNow, epochNow = FRAME, EPOCH
    _G.GetTime   = function() return frameNow end
    ns.Store.Now = function() return epochNow end
    ns.state.loggedIn = true

    local auraList = {}
    _G.C_UnitAuras = { GetBuffDataByIndex = function(_, i) return auraList[i] end }
    _G.C_Container = { GetItemCooldown = function() return 0, 0, 1 end }
    _G.C_Item = { GetItemCount = function() return 0 end }
    _G.C_Map  = { GetBestMapForUnit = function() return nil end,
                  GetPlayerMapPosition = function() return nil end }
    _G.IsResting = function() return true end
    _G.UnitIsPVP = function() return false end
    _G.UnitIsPVPFreeForAll = function() return false end
    _G.IsInInstance = function() return false, "none" end
    _G.GetNumSavedInstances = function() return 0 end
    _G.GetSubZoneText     = function() return "" end
    _G.GetMinimapZoneText = function() return "" end
    ns.Store.GetSettings = function() return { coordinateOverrides = {} } end

    -- One durable record the capture path writes into, so consecutive captures
    -- see the previous values exactly as they do in game.
    local rec = {}
    local writes = 0
    ns.Store.EnsureSelfCharacter = function() return rec end
    ns.Store.WriteSelfCharacter  = function() writes = writes + 1 end

    -- Count STATE_CHANGED fires and remember the force flag. `counting` gates
    -- the closure: ns has no unsubscribe, so the listener stays registered for
    -- the session and must go inert the moment this suite finishes.
    local fires, lastForce, counting = 0, nil, true
    ns:On("STATE_CHANGED", function(_, _, force)
        if not counting then return end
        fires = fires + 1
        lastForce = force
    end)

    local ok, err = pcall(function()
        Tracker._leavingWorld, Tracker._loggingOut = false, false
        Tracker._enteredWorldAt = frameNow - 60
        Tracker._auraCapturedAt, Tracker._cdCapturedAt = nil, nil
        Tracker._lastPushHash, Tracker._lastPushAt = nil, 0

        -- Songflower Serenade: a real slot with a readable duration we control.
        local function setAura(rem)
            auraList = { { name = "Songflower Serenade", spellId = 15366,
                           expirationTime = frameNow + rem } }
        end

        -- 1) FIRST capture always pushes (no prior hash).
        --    1795s remaining == minute bucket 29 (not on a boundary, so the
        --    10s tick in case 3 stays inside the same bucket).
        setAura(1795)
        Tracker.Capture()
        ck(fires == 1, "first capture must push (got " .. fires .. ")")
        ck(writes == 1, "first capture must write the store")

        -- 2) IDENTICAL capture -> NO push, but the store is still written.
        Tracker.Capture()
        ck(fires == 1, "identical capture pushed anyway (fires=" .. fires .. ")")
        ck(writes == 2, "identical capture must still write the store locally")

        -- 3) VOLATILE-ONLY change: the clock moved 10s, so lastSeen /
        --    lastDataUpdate / ownerEpoch all moved and the aura ticked 10s —
        --    but not across a minute boundary (1795 -> 1785, both bucket 29).
        --    Must NOT push.
        epochNow = epochNow + 10
        frameNow = frameNow + 10
        setAura(1785)
        Tracker.Capture()
        ck(fires == 1, "volatile-only change pushed (fires=" .. fires .. ")")

        -- 4) One aura MINUTE-BOUNDARY change -> push (bucket 29 -> 28).
        setAura(1739)
        Tracker.Capture()
        ck(fires == 2, "aura minute boundary did not push (fires=" .. fires .. ")")

        -- 5) A real content change (resting flips) -> push.
        _G.IsResting = function() return false end
        Tracker.Capture()
        ck(fires == 3, "resting flip did not push (fires=" .. fires .. ")")

        -- 6) FORCED capture pushes even though nothing changed, and the force
        --    flag reaches the subscriber so Mesh.PushState skips ITS filter too.
        lastForce = nil
        Tracker.Capture(true)
        ck(fires == 4, "forced capture was filtered (fires=" .. fires .. ")")
        ck(lastForce == true, "force flag did not reach STATE_CHANGED")

        -- 7) Unforced again right after -> filtered.
        Tracker.Capture()
        ck(fires == 4, "post-force identical capture pushed (fires=" .. fires .. ")")

        -- 8) MAX-QUIET refresh (OURS, 5 min): nothing changed, but the last push
        --    is FORCE_REFRESH_INTERVAL old, so we push anyway.
        epochNow = epochNow + Tracker.FORCE_REFRESH_INTERVAL
        frameNow = frameNow + Tracker.FORCE_REFRESH_INTERVAL
        setAura(1739)                      -- unchanged content: same minute bucket
        Tracker.Capture()
        ck(fires == 5, "max-quiet forced refresh did not fire (fires=" .. fires .. ")")

        -- 9) And it re-arms: immediately after, the filter is active again.
        Tracker.Capture()
        ck(fires == 5, "filter did not re-arm after the quiet refresh")
    end)

    counting = false   -- the listener is permanent; make it a no-op from here.

    _G.C_UnitAuras, _G.C_Container, _G.C_Item, _G.C_Map = saved.auras, saved.cont, saved.item, saved.map
    _G.GetTime, _G.IsResting = saved.getTime, saved.resting
    _G.UnitIsPVP, _G.UnitIsPVPFreeForAll = saved.pvp, saved.ffa
    _G.IsInInstance, _G.GetNumSavedInstances = saved.inInst, saved.saved
    _G.GetSubZoneText, _G.GetMinimapZoneText = saved.sub, saved.mini
    ns.Store.Now, ns.Store.GetSettings = saved.now, saved.settings
    ns.Store.EnsureSelfCharacter, ns.Store.WriteSelfCharacter = saved.ensure, saved.write
    ns.state.loggedIn = saved.loggedIn
    Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt = savedLatch[1], savedLatch[2], savedLatch[3]
    Tracker._auraCapturedAt, Tracker._cdCapturedAt = savedLatch[4], savedLatch[5]
    Tracker._lastPushHash, Tracker._lastPushAt = savedLatch[6], savedLatch[7]

    if not ok then fails[#fails + 1] = "error in change-filter fixtures: " .. tostring(err) end
end

function Tracker.RunSelfTests(verbose)
    local suites = {
        { name = "state-push change filter (A10.1)", fn = testChangeFilter },
        { name = "boon parsing", fn = testBoonParsing },
        { name = "boon block (owner 7-line fixture)", fn = testBoonBlock },
        { name = "live aura matching (apostrophe matrix)", fn = testLiveAuraMatching },
        { name = "spell-ID matching (A6.4/A6.6)", fn = testSpellIDMatching },
        { name = "teardown latch + grace windows", fn = testTeardownLatch },
        { name = "capture guards (A6.1/A6.2/A6.3/A17.2/A9.2)", fn = testCaptureGuards },
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
