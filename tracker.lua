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

-- A7 / spec §4.4 — the chronoboon CAST lifecycle. Using the item to store buffs
-- casts 349858; using the Super-charged item to restore them casts 349863. This
-- is the reference's PRIMARY way of learning what is in the boon; the tooltip
-- parser (below) drops to a secondary, reconciling source.
local SPELL_BOON_CAST   = 349858
local SPELL_UNBOON_CAST = 349863

-- Item USE cooldown for both the hearthstone and the chronoboon (spec §4.4/§6)
-- now lives in ONE place, store.lua's Store.ITEM_CD_DURATION, alongside the
-- shared start-epoch helpers every reader and writer goes through (A9.1).

-- A removal seen within this many seconds BEFORE the boon cast succeeded is the
-- chronoboon stripping the aura (restore it as booned). Anything earlier is a
-- deliberate player cancel and stays gone (spec §4.4 step 4, A7.3).
local BOON_STRIP_WINDOW = 0.3

-- A delayed re-snapshot this long after cast start catches buffs GAINED during
-- the cast (spec §4.4 step 3).
local BOON_RESNAPSHOT_DELAY = 5

-- After an unboon, restored buffs are not "fresh" for this long (spec §4.4).
local UNBOON_WINDOW = 3
-- ...and a rescan this soon after picks up their real durations.
local UNBOON_RESCAN_DELAY = 0.25

-- A tooltip-vs-stored duration disagreement larger than this is corrected from
-- the tooltip (spec §4.4 "Reading the boon's contents" reconciliation).
local BOON_DRIFT_TOLERANCE = 120

-- Which of OUR ten slots can actually go into a chronoboon. Slots 9 (Battle
-- Shout) and 10 (Fire Festival Fury) are explicitly NOT boonable per the spec's
-- tracked-set table, so a live Battle Shout must never be flipped to "booned"
-- when a boon cast succeeds. Slots 1-8 are the boonable world buffs.
local BOONABLE_SLOT = {
    [1] = true, [2] = true, [3] = true, [4] = true,
    [5] = true, [6] = true, [7] = true, [8] = true,
}

-- Our DMF slot (Sayge's Dark Fortune). Named because the whole A8 lifecycle
-- keys off it.
local SLOT_DMF = 5

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

-- A7.5 — tooltip RECONCILIATION (spec §4.4 "Reading the boon's contents").
--
-- Since A7.1 the cast path writes the boon cache directly, so a hover is no
-- longer how we LEARN what is booned — it is a second opinion that corrects the
-- first. The spec's two corrections, and only those:
--   (a) any slot we claim is booned that the tooltip does NOT list is a phantom
--       and is dropped;
--   (b) a slot the tooltip DOES list whose stored duration is off by more than
--       120 s is corrected to the tooltip's value. Smaller disagreements keep
--       the cached value — the cast snapshot is the more precise number and we
--       do not want a hover to jitter the display by a few seconds.
-- The DMF slot's `option` (fortune variant) is NEVER taken from a tooltip: the
-- tooltip renders the generic "Sayge's Dark Fortune" name and adopting it would
-- destroy a variant the live scan resolved by spell ID.
--
-- `parsed` is the fresh tooltip read, `cached` the snapshot we already hold
-- (nil on the very first hover, in which case the tooltip is adopted whole).
-- Returns a NEW snapshot table; pure and self-tested.
function Tracker.ReconcileBoonSnapshot(parsed, cached)
    if type(parsed) ~= "table" then return cached end
    if type(cached) ~= "table" or type(cached.slots) ~= "table" then
        return { slots = parsed.slots or {}, dmf = parsed.dmf or false,
                 count = parsed.count or 0 }
    end
    local out = {}
    for slot, tip in pairs(parsed.slots or {}) do
        local have = cached.slots[slot]
        local tipDur = tonumber(tip and tip.duration) or 0
        if have then
            local haveDur = tonumber(have.duration) or 0
            local drift = haveDur - tipDur
            if drift < 0 then drift = -drift end
            -- (b) correct only a real disagreement; keep `option` either way.
            local dur = (drift > BOON_DRIFT_TOLERANCE) and tipDur or haveDur
            out[slot] = { duration = dur, option = have.option }
        else
            -- The tooltip knows about a slot we did not: adopt it.
            out[slot] = { duration = tipDur }
        end
    end
    -- (a) every cached slot absent from `out` was a phantom and is now dropped.
    return { slots = out, dmf = parsed.dmf or false, count = parsed.count or 0 }
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

    -- A7.5: the cast path (if it ran) already wrote the authoritative snapshot;
    -- this hover reconciles it rather than replacing it wholesale.
    local parsed = Tracker.ReconcileBoonSnapshot(
        { slots = slots, dmf = dmf, count = count }, Tracker._boonParsed)
    Tracker._boonTooltipCount = parsed.count or count
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
-- A7 — chronoboon CAST lifecycle (spec §4.4). THE HEADLINE FIX.
--
-- Before this, the tooltip parser was the ONLY way we ever learned what was in
-- a chronoboon: boon your buffs and walk away without hovering the icon, and
-- every other account saw `chronoboonActive = true` with zero slots — a booned
-- 60 rendering as a character with no buffs at all (A7.1).
--
-- The cast is now the primary source, exactly as the reference has it:
--   * cast START   snapshots every live BOONABLE slot (duration + variant + the
--                  frame time it was taken) and opens an "in boon cast" window;
--   * DURING       a boonable aura that vanishes is recorded as "removed at T"
--                  (see the recorder in captureAuras);
--   * cast SUCCESS re-classifies those removals — within 0.3 s of the success it
--                  was the chronoboon stripping the aura (restore as BOONED with
--                  the snapshot duration minus what elapsed), earlier than that
--                  it was a deliberate player cancel (stays gone, and is dropped
--                  from the snapshot so the next scan cannot resurrect it).
--                  Every boonable slot still live is flipped to BOONED, the
--                  cache is rewritten FROM THAT PROJECTION, the item cooldown is
--                  stamped, and a forced mesh push fires;
--   * INTERRUPT    drops the pending state; nothing is retroactively flipped.
-- Unboon flips BOONED back to LIVE, opens the 3 s unboon window and schedules a
-- 0.25 s rescan for the real durations.
--
-- SIMPLIFICATIONS vs the spec, and why (all deliberate, none silent):
--   1. The spec's cast-start step does "a fresh scan" before snapshotting. We
--      snapshot from `rec.auraStates`, which UNIT_AURA has kept current to
--      within the same frame — the tracker has no scan entry point separate
--      from a full capture, and forcing a whole capture inside a cast-start
--      handler would re-enter the change filter for no new information.
--   2. `boonCount` keeps OUR meaning (buffs in the boon), per the standing owner
--      decision; the items-in-bags meaning (A7.4) is queued separately.
--   3. The 3 s unboon window is exposed as `Tracker.InUnboonWindow()` but is not
--      yet consumed: the fresh-buff / alert filter that should honour it lives in
--      timers.lua, which this batch does not own. FLAGGED FOLLOW-UP.
----------------------------------------------------------------------

Tracker._inBoonCast   = false   -- a boon cast is in flight
Tracker._boonCastAt   = nil     -- GetTime() of cast start
Tracker._boonSnapshot = nil     -- [slot] = { duration, option, at }
Tracker._boonRemovals = {}      -- [slot] = GetTime() the aura vanished
Tracker._unboonUntil  = 0       -- GetTime() the 3 s unboon window closes

local function frameTime()
    return (GetTime and GetTime()) or 0
end

-- Snapshot every LIVE boonable slot from the record. Pure over `rec`.
function Tracker.SnapshotBoonable(rec, atFrame)
    local snap = {}
    local states = rec and rec.auraStates
    if type(states) ~= "table" then return snap end
    atFrame = atFrame or frameTime()
    for slot, cell in pairs(states) do
        if BOONABLE_SLOT[slot] and type(cell) == "table" then
            local dur = tonumber(cell.duration) or 0
            if dur > 0 and (cell.source or 0) ~= BOON_SOURCE then
                snap[slot] = { duration = dur, option = cell.option or 0, at = atFrame }
            end
        end
    end
    return snap
end

-- Project the record's BOONED slots into a cache snapshot ({slots, dmf, count}).
local function projectBoonCache(rec)
    local parsed = { slots = {}, dmf = false, count = 0 }
    local states = rec and rec.auraStates
    if type(states) ~= "table" then return parsed end
    for slot, cell in pairs(states) do
        if type(cell) == "table" and (cell.source or 0) == BOON_SOURCE
           and (tonumber(cell.duration) or 0) > 0 then
            parsed.slots[slot] = { duration = math.floor(cell.duration),
                                   option = cell.option or 0 }
            parsed.count = parsed.count + 1
            if slot == SLOT_DMF then parsed.dmf = true end
        end
    end
    return parsed
end

-- Cast START.
function Tracker.BeginBoonCast(rec, atFrame)
    atFrame = atFrame or frameTime()
    Tracker._inBoonCast   = true
    Tracker._boonCastAt   = atFrame
    Tracker._boonRemovals = {}
    Tracker._boonSnapshot = Tracker.SnapshotBoonable(rec, atFrame)
    -- Spec: write the local boon cache now and drop the tooltip's stale opinion.
    -- Safe to do before the cast lands: captureAuras only injects boon slots when
    -- the chronoboon AURA is actually present, so an interrupted cast never shows
    -- these as booned, and the next full scan clears the cache.
    if next(Tracker._boonSnapshot) ~= nil then
        local parsed = { slots = {}, dmf = false, count = 0 }
        for slot, s in pairs(Tracker._boonSnapshot) do
            parsed.slots[slot] = { duration = s.duration, option = s.option }
            parsed.count = parsed.count + 1
            if slot == SLOT_DMF then parsed.dmf = true end
        end
        Tracker._boonParsed = parsed
        Tracker._boonTooltipCount = parsed.count
    end
end

-- Cast INTERRUPTED / FAILED (spec §4.4 step 5): drop the pending state only.
function Tracker.AbortBoonCast()
    Tracker._inBoonCast   = false
    Tracker._boonCastAt   = nil
    Tracker._boonSnapshot = nil
    Tracker._boonRemovals = {}
end

-- Record a boonable aura that vanished during the cast. Idempotent per slot
-- (the FIRST disappearance is the one that matters).
function Tracker.NoteBoonRemoval(slot, atFrame)
    if not Tracker._inBoonCast or not BOONABLE_SLOT[slot] then return end
    Tracker._boonRemovals = Tracker._boonRemovals or {}
    if Tracker._boonRemovals[slot] == nil then
        Tracker._boonRemovals[slot] = atFrame or frameTime()
    end
end

-- Cast SUCCESS. Mutates `rec` into the post-boon projection and returns the
-- cache snapshot it wrote. `atFrame` / `atEpoch` are injectable for the suite.
function Tracker.FinishBoonCast(rec, atFrame, atEpoch)
    if type(rec) ~= "table" then return nil end
    atFrame = atFrame or frameTime()
    atEpoch = atEpoch or (ns.Store and ns.Store.Now and ns.Store.Now()) or 0
    local snap     = Tracker._boonSnapshot or {}
    local removals = Tracker._boonRemovals or {}
    local states   = rec.auraStates or {}
    rec.auraStates = states

    -- (1) Re-classify every removal seen during the cast.
    for slot, removedAt in pairs(removals) do
        if BOONABLE_SLOT[slot] then
            local s = snap[slot]
            if s and (atFrame - removedAt) <= BOON_STRIP_WINDOW then
                -- The chronoboon stripped it: restore as BOONED, snapshot-adjusted.
                local dur = math.floor(s.duration - (removedAt - s.at))
                states[slot] = (dur > 0)
                    and { duration = dur, option = s.option or 0, source = BOON_SOURCE }
                    or nil
            else
                -- Deliberate player cancel: stays gone, and is dropped from the
                -- snapshot so no later scan or cache write can resurrect it.
                snap[slot]   = nil
                states[slot] = nil
            end
        end
    end

    -- (2) Every boonable slot still LIVE is flipped to BOONED. Only existing
    -- keys are rewritten here, so the traversal is well-defined.
    for slot, cell in pairs(states) do
        if BOONABLE_SLOT[slot] and type(cell) == "table"
           and (cell.source or 0) ~= BOON_SOURCE then
            local s   = snap[slot]
            local dur = tonumber(cell.duration) or 0
            if s then dur = math.floor(s.duration - (atFrame - s.at)) end
            states[slot] = (dur > 0)
                and { duration = dur, option = cell.option or (s and s.option) or 0,
                      source = BOON_SOURCE }
                or nil
        end
    end

    -- (3) Rewrite the cache FROM THE PROJECTION (not from the pre-cast snapshot).
    local parsed = projectBoonCache(rec)
    Tracker._boonParsed       = parsed
    Tracker._boonTooltipCount = parsed.count
    persistBoonCache(rec.nameRealm or selfNameRealm(), parsed)

    rec.chronoboonActive   = true
    rec.chronoboonLastSeen = atEpoch
    rec.dmfInBoon          = parsed.dmf
    -- A7.4 (owner decision): boonCount is ITEMS IN BAGS. The cast consumed one,
    -- so decrement optimistically here (spec §4.4 step 4) — BAG_UPDATE_DELAYED
    -- will re-read the true count a moment later and correct any drift.
    if Tracker._noteBoonCount then
        Tracker._noteBoonCount(rec, math.max(0, (tonumber(rec.boonCount) or 0) - 1))
    end
    -- A7.2/A9.1: the cast is authoritative for the item cooldown; the bag API is
    -- a fallback from here on (see captureCooldowns). `force` because a cast is
    -- ground truth — it displaces whatever epoch we were holding, newer or not.
    ns.Store.ItemCdSetStart(rec, "chronoboon", atEpoch, atEpoch, true)

    -- A8.5: entering a boon CARRYING DMF re-stamps a full 4 h. Safety net for a
    -- missed unboon edge — the cooldown then freezes until the buffs come out.
    if parsed.dmf and ns.Store and ns.Store.DMFCooldownStart then
        ns.Store.DMFCooldownStart(rec, atEpoch)
    end

    Tracker._boonSnapshot = nil
    Tracker._boonRemovals = {}
    -- Spec: the window closes on the NEXT frame, so same-frame aura events stay
    -- gated behind it.
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            Tracker._inBoonCast = false
            Tracker._boonCastAt = nil
        end)
    else
        Tracker._inBoonCast = false
        Tracker._boonCastAt = nil
    end
    return parsed
end

-- Unboon SUCCESS: every BOONED slot flips back to LIVE.
function Tracker.FinishUnboonCast(rec, atFrame, atEpoch)
    if type(rec) ~= "table" then return false end
    atFrame = atFrame or frameTime()
    atEpoch = atEpoch or (ns.Store and ns.Store.Now and ns.Store.Now()) or 0
    local states = rec.auraStates or {}
    rec.auraStates = states

    local restoredDMF = false
    for slot, cell in pairs(states) do
        if type(cell) == "table" and (cell.source or 0) == BOON_SOURCE then
            states[slot] = { duration = tonumber(cell.duration) or 0,
                             option = cell.option or 0, source = 0 }
            if slot == SLOT_DMF then restoredDMF = true end
        end
    end

    Tracker._unboonUntil      = atFrame + UNBOON_WINDOW
    Tracker._boonParsed       = nil
    Tracker._boonTooltipCount = 0
    persistBoonCache(rec.nameRealm or selfNameRealm(), nil)

    rec.chronoboonActive = false
    rec.dmfInBoon        = false
    -- A7.4: boonCount is items-in-bags, so an unboon does NOT zero it. The bag
    -- re-read that follows the item use reports the true remaining count.

    -- A8.5: an unboon that RESTORES DMF re-stamps a full 4 h (spec §5 Start).
    if restoredDMF and ns.Store and ns.Store.DMFCooldownStart then
        ns.Store.DMFCooldownStart(rec, atEpoch)
    end
    return restoredDMF
end

-- Is a boonable buff gained right now a RESTORED one rather than a fresh pickup?
-- Exposed for the fresh-buff / alert filter (see simplification 3 above).
function Tracker.InUnboonWindow(atFrame)
    return (atFrame or frameTime()) < (Tracker._unboonUntil or 0)
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

-- A9.1 — the bag API reduced to a START EPOCH, with the spec §6 sanity gates.
--
-- C_Container.GetItemCooldown reports (start, duration, enable) where `start` is
-- in GetTime()'s monotonic frame; converting it to a server epoch is
--     epoch = now - (GetTime() - start)
-- Everything the spec calls garbage is rejected HERE, before any of it can reach
-- a record:
--   * duration <= 1.5s  -> that is the global cooldown, not an item cooldown
--   * duration > 7200s  -> loading-screen garbage (this is the shape behind the
--                          documented "9000-minute stuck cooldown")
--   * negative elapsed  -> a start time in the future; discard
--   * enable == 0       -> the item reports no usable cooldown
-- Returns the derived START EPOCH, or 0 for "nothing believable to read".
local function itemCooldownStartEpoch(itemID, nowE)
    if not (C_Container and C_Container.GetItemCooldown) then return 0 end
    local start, duration, enable = C_Container.GetItemCooldown(itemID)
    if not (start and duration) then return 0 end
    if enable ~= nil and enable ~= 1 then return 0 end
    if duration <= (ns.Store.ITEM_CD_GCD_MAX or 1.5) then return 0 end
    if duration > (ns.Store.ITEM_CD_ABSURD or 7200) then return 0 end
    if start <= 0 then return 0 end
    local elapsed = GetTime() - start
    if elapsed < 0 then return 0 end                 -- start in the future
    local rem = duration - elapsed
    if rem <= 0 then return 0 end                    -- already expired
    return math.floor(nowE - elapsed)
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

-- A7.2/A9.1 — remaining on the chronoboon item, from its START EPOCH.
--
-- The bag API was once our only source, which meant a boon cast while
-- C_Container was cold, or any relog, lost the "when can I re-boon" countdown
-- entirely. The cast writes rec.chronoboonCDStart and that is authoritative; the
-- API is a fallback consulted only when no stamp exists (spec §6: "the API is
-- only consulted when nothing is stored").
--
-- The arithmetic now lives in Store.ItemCdRemaining (one helper for both items);
-- this wrapper keeps the WRITE-side self-heal — a stamp in the future (clock
-- skew) or older than the cooldown is cleared, not merely read as zero.
local function chronoboonStampRemaining(rec, now)
    local rem = ns.Store.ItemCdRemaining(rec, "chronoboon", now)
    if rem <= 0 and (tonumber(rec.chronoboonCDStart) or 0) > 0 then
        rec.chronoboonCDStart = 0
    end
    return rem
end
Tracker._chronoboonStampRemaining = chronoboonStampRemaining

-- A9.1 — capture BOTH item cooldowns as START EPOCHS.
--
-- What actually gets written is rec.hearthstoneCDStart / rec.chronoboonCDStart;
-- rec.hearthstoneCD / rec.itemCooldown are recomputed from them as the legacy
-- mirrors the frozen wire schema still carries (see the CHANGELOG note in
-- store.lua). Nothing here decays or carries a remaining value any more — an
-- epoch is exact through a loading screen, a suppressed capture and a relog,
-- which is the entire point of the model.
local function captureCooldowns(rec)
    local now = ns.Store.Now()

    -- MIGRATION: a record written by an older client carries only the mirrors.
    -- Synthesize its epochs on this first capture, then heal anything stale.
    ns.Store.MigrateItemCdEpochs(rec, now)
    ns.Store.HealItemCdEpochs(rec, now)

    -- A9.2: BAG_UPDATE_COOLDOWN and the login capture both hit C_Container while
    -- it is cold right after a loading screen — the documented race that produces
    -- stuck multi-thousand-minute cooldowns. Suppress the READ during teardown
    -- and for COOLDOWN_GRACE seconds after entering the world. The stored epochs
    -- are untouched and simply keep counting down.
    if Tracker.IsTeardown() or Tracker.InEnteringWorldGrace(COOLDOWN_GRACE) then
        chronoboonStampRemaining(rec, now)          -- write-side self-heal
        ns.Store.RefreshItemCdMirrors(rec, now)
        Tracker._cdCapturedAt = now
        return
    end

    -- HEARTHSTONE: the bag API is the only source we have (there is no cast hook
    -- for 8690 in this batch), and it is accepted per spec §6 — when nothing is
    -- stored, or when its derived start is NEWER than the stored one (a genuine
    -- re-use, or the instance-kick reset). It can never CLEAR a stored cooldown:
    -- a cold or empty API read must not delete a live countdown, which is exactly
    -- how a failed capture used to write 0 and make the cooldown disappear.
    local hearthStart = itemCooldownStartEpoch(ITEM_HEARTHSTONE, now)
    if hearthStart > 0 then
        ns.Store.ItemCdSetStart(rec, "hearthstone", hearthStart, now)
    end

    -- CHRONOBOON: cast stamp first, bag API only when nothing is stored. Both Era
    -- item IDs are probed and the EARLIEST believable start wins (= the longest
    -- remaining), which is the epoch-space equivalent of the old max-remaining.
    local stamped = chronoboonStampRemaining(rec, now)
    if stamped <= 0 then
        local best = 0
        for i = 1, #CHRONOBOON_ITEMS do
            local e = itemCooldownStartEpoch(CHRONOBOON_ITEMS[i], now)
            if e > 0 and (best == 0 or e < best) then best = e end
        end
        if best > 0 then
            ns.Store.ItemCdSetStart(rec, "chronoboon", best, now)
        end
    end

    ns.Store.RefreshItemCdMirrors(rec, now)
    Tracker._cdCapturedAt = now
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

            -- NOTE (A8): a LIVE Sayge's fortune used to set `dmfInBoon` here.
            -- It is not "in boon" — it is on your character — and the flag now
            -- freezes the 4 h cooldown, so setting it for a live fortune would
            -- stop the clock for exactly the two hours you are holding the buff.
            -- `dmfInBoon` is set below, from BOON-sourced state only.
        end
    end

    -- A7.3: while a boon cast is in flight, a boonable aura that DISAPPEARS is
    -- recorded with the frame time it went. FinishBoonCast then decides whether
    -- the chronoboon stripped it (restore as booned) or the player cancelled it
    -- (stays gone) from how close that moment was to the cast succeeding.
    if Tracker._inBoonCast and type(prev) == "table" then
        local atFrame = frameTime()
        for slot, cell in pairs(prev) do
            if type(cell) == "table" and slots[slot] == nil
               and (cell.source or 0) ~= BOON_SOURCE
               and (tonumber(cell.duration) or 0) > 0 then
                Tracker.NoteBoonRemoval(slot, atFrame)
            end
        end
    end

    -- A6.2: a scan that saw nothing at all, or one taken inside the loading-screen
    -- grace, is partial evidence — never proof that the buffs are gone.
    -- A7: a scan taken DURING a boon cast is partial for the same reason — the
    -- buffs are mid-transfer into the chronoboon, so nothing may be dropped on
    -- its evidence. The removals recorded just above are the real signal, and
    -- FinishBoonCast is what resolves them.
    local partial = (sawAnyBuff == 0) or Tracker.InEnteringWorldGrace(ENTERING_WORLD_GRACE)
                    or (Tracker._inBoonCast and true or false)
    if partial then
        preserveSlots(prev, elapsed, slots)
    end

    -- Chronoboon fields. NOTE (A7.4): `boonCount` no longer lives here — it is
    -- now "Chronoboon Displacer ITEMS IN BAGS" and is captured from the bags in
    -- captureBoonItems below. The buffs-actually-in-the-boon number stays
    -- available as Tracker.BoonedBuffCount() for anything that wants it.
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
                    slots[slot] = { duration = cell.duration or 0,
                                    option = cell.option or 0, source = BOON_SOURCE }
                end
            end
            if parsed.dmf then dmfInBoon = true end
        end
    elseif partial then
        -- A6.2: "no chronoboon aura found" from a partial scan is not an unboon.
        -- Leave chronoboonActive / the persisted boon cache alone.
        if rec.chronoboonActive and Tracker._boonParsed and Tracker._boonParsed.dmf then
            dmfInBoon = true
        end
    else
        rec.chronoboonActive = false
        -- Unboon: drop any boon-sourced state so stale frozen slots don't linger.
        if Tracker._boonParsed then
            Tracker._boonParsed = nil
            Tracker._boonTooltipCount = 0
            persistBoonCache(rec.nameRealm, nil)
        end
    end

    -- A7.6 / A6.8: a BOON-sourced slot must never be dropped for having "run
    -- out" — suspended buffs do not tick. The injection above and preserveSlots
    -- both keep them verbatim; the DISPLAY-side freeze is Dashboard.AuraRemaining.
    rec.auraStates = slots
    Tracker._auraCapturedAt = now

    -- A8: `dmfInBoon` is now literally "the fortune is stashed in the boon", and
    -- nothing else. The cooldown itself is owned by captureDMF.
    if partial and not dmfInBoon then
        dmfInBoon = rec.dmfInBoon and true or false
    end
    rec.dmfInBoon = dmfInBoon
end

-- How many tracked world buffs are currently inside the boon (our old
-- boonCount meaning). Kept for callers that want it; `rec.boonCount` is now
-- items-in-bags (A7.4, owner decision).
function Tracker.BoonedBuffCount()
    local p = Tracker._boonParsed
    return (p and p.count) or 0
end

----------------------------------------------------------------------
-- A7.4 — boonCount = Chronoboon Displacer ITEMS IN BAGS (owner decision).
--
-- It used to be "how many buffs did the tooltip parser find inside the boon",
-- which answers a question nobody asks; the reference's meaning answers the
-- actionable one — "do I have a boon left to use". Both card and detail already
-- render this number as "N in bags", so the label was simply wrong before.
--
-- Counted across BOTH probed item IDs (base + Super-charged). Bag reads are
-- suppressed during teardown and the post-loading-screen grace for the same
-- reason the item cooldowns are: C_Item is cold there and reports 0, which would
-- fire a spurious "no boons left" warning on every zone change.
----------------------------------------------------------------------

Tracker._boonCountSeeded = false

local function bagItemCount(itemID)
    if C_Item and C_Item.GetItemCount then
        return tonumber(C_Item.GetItemCount(itemID)) or 0
    end
    return 0
end

-- Warn once per transition into "none left" (spec §6). Pure-ish: the warning is
-- suppressed until we have seen at least one honest count this session, so a
-- login does not open with it.
local function noteBoonCount(rec, count)
    local prev = Tracker._lastBoonCount
    rec.boonCount = count
    if Tracker._boonCountSeeded and (prev or 0) > 0 and count == 0 then
        if ns and ns.Print then
            ns:Print("|cffff5555You have no Chronoboon Displacers left.|r")
        end
    end
    Tracker._boonCountSeeded = true
    Tracker._lastBoonCount = count
end
Tracker._noteBoonCount = noteBoonCount

local function captureBoonItems(rec)
    if Tracker.IsTeardown() or Tracker.InEnteringWorldGrace(COOLDOWN_GRACE) then
        return   -- cold API: keep the last honest count
    end
    local n = 0
    for i = 1, #CHRONOBOON_ITEMS do
        n = n + bagItemCount(CHRONOBOON_ITEMS[i])
    end
    noteBoonCount(rec, n)
end

----------------------------------------------------------------------
-- A8 — the DMF (Darkmoon fortune) cooldown lifecycle (spec §5).
--
-- The store owns the arithmetic (Store.DMFCooldown*); this owns the EDGES that
-- drive it: a fresh fortune starts the 4 h, every capture ticks it down by the
-- online time that passed, logout stamps the offline epoch, and the debuff-bar
-- push clears it. The boon/unboon re-stamps live in the A7 cast handlers.
--
-- The FIRST capture of a session only seeds the edge detector. Login fires aura
-- events for every buff already on the character, so treating that as a fresh
-- fortune would re-stamp a full 4 h on every /reload — the exact failure the
-- reference's "login stabilized" latch exists to prevent.
----------------------------------------------------------------------

-- A8.4 — DEBUFF-BAR PUSH DETECTION.
--
-- Classic Era shows at most 16 debuffs. The DMF cooldown is enforced by a hidden
-- debuff, so once the visible debuff count reaches 16 that hidden aura has been
-- evicted server-side and the cooldown is genuinely gone — you can take another
-- fortune immediately. We presume the eviction, clear the cooldown, and
-- (optionally) tell the raid, because in a 40-man everyone's DMF is being pushed
-- at the same moment and nobody can see it happen.
--
-- Skipped entirely inside any instance (the debuff bar fills for ordinary raid
-- reasons there and the eviction heuristic is not trustworthy), and skipped when
-- DMF is booned or no cooldown is tracked.
local DEBUFF_BAR_LIMIT = 16

local function visibleDebuffCount()
    if not (C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex) then return 0 end
    local n = 0
    for i = 1, 40 do
        if not C_UnitAuras.GetDebuffDataByIndex("player", i) then break end
        n = n + 1
    end
    return n
end

-- Should the push heuristic fire? PURE — takes the facts, returns a decision, so
-- the whole gate matrix is testable without a client.
function Tracker.ShouldClearDMFOnDebuffPush(rec, debuffCount)
    if type(rec) ~= "table" then return false end
    if not rec.dmfCooldownActive then return false end   -- nothing tracked
    if rec.dmfInBoon then return false end               -- stashed: not on the bar
    if rec.inInstance then return false end              -- untrustworthy in here
    return (tonumber(debuffCount) or 0) >= DEBUFF_BAR_LIMIT
end

-- Is the public announcement enabled? Additive setting, DEFAULT ON: absent means
-- on, so an existing SavedVariables file keeps the spec'd behaviour.
function Tracker.DMFPushAnnounceEnabled()
    local db = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    if type(db) ~= "table" then return true end
    if db.dmfPushAnnounce == nil then return true end
    return db.dmfPushAnnounce and true or false
end

-- Which channels the announcement goes to (spec §5: SAY always, plus RAID when
-- in a raid or PARTY when in a party). PURE so the routing is testable.
function Tracker.DMFPushChannels(inRaid, inParty)
    local out = { "SAY" }
    if inRaid then out[#out + 1] = "RAID"
    elseif inParty then out[#out + 1] = "PARTY" end
    return out
end

local DMF_PUSH_MESSAGE = "DMF cooldown got pushed off the debuff bar."

local function announceDMFPush()
    if not Tracker.DMFPushAnnounceEnabled() then return end
    local inRaid  = IsInRaid and IsInRaid() or false
    local inParty = IsInGroup and IsInGroup() or false
    local channels = Tracker.DMFPushChannels(inRaid, inParty)
    for i = 1, #channels do
        if SendChatMessage then SendChatMessage(DMF_PUSH_MESSAGE, channels[i]) end
    end
end

Tracker._dmfSeeded  = false   -- first capture only seeds the fresh-gain edge
Tracker._dmfWasLive = false

local function captureDMF(rec)
    local Store = ns.Store
    if not (Store and Store.DMFCooldownTick) then return end
    local now = Store.Now()

    -- Teardown: a final tick, then stamp the offline epoch (spec §5 Logout).
    -- isResting was refreshed by captureFlags moments ago, so the value the
    -- login-resume rule reads is genuinely "resting at logout".
    if Tracker.IsTeardown() then
        Store.DMFCooldownStampOffline(rec, now)
        return
    end

    local cell = rec.auraStates and rec.auraStates[SLOT_DMF]
    local live = (type(cell) == "table"
                  and (tonumber(cell.duration) or 0) > 0
                  and (cell.source or 0) ~= BOON_SOURCE) and true or false

    if not Tracker._dmfSeeded then
        Tracker._dmfSeeded = true                       -- seed only; no edge
    elseif live and not Tracker._dmfWasLive
           and not rec.dmfInBoon and not rec.dmfCooldownActive then
        Store.DMFCooldownStart(rec, now)                -- fresh fortune: 0 -> live
    end
    Tracker._dmfWasLive = live

    -- A8.4: the push check runs BEFORE the tick so a cleared cooldown does not
    -- also get billed for the elapsed time on its way out.
    if Tracker.ShouldClearDMFOnDebuffPush(rec, visibleDebuffCount()) then
        Store.DMFCooldownClear(rec, rec.nameRealm, "pushed off the debuff bar")
        announceDMFPush()
        Tracker._dmfPushes = (Tracker._dmfPushes or 0) + 1
        return
    end

    Store.DMFCooldownTick(rec, now, rec.nameRealm)
end

-- Exposed for the self-test harness (pure-Lua fixtures drive these directly;
-- Tracker.Capture itself needs the whole live client).
Tracker._captureAuras     = captureAuras
Tracker._captureLocation  = captureLocation
Tracker._captureCooldowns = captureCooldowns
Tracker._captureDMF       = captureDMF
Tracker._captureBoonItems = captureBoonItems

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
-- RAID ATTUNEMENT (personal, Classic Era)
--
-- The roster/detail views grey a raid's lockout text for a character that
-- cannot actually zone in. Only FOUR Classic Era raids have a PERSONAL
-- attunement; the other three are ungated per-character and therefore always
-- read as attuned:
--
--   MC    Attunement to the Core          — one neutral quest
--   BWL   Blackhand's Command             — one neutral quest (UBRS)
--   Ony   Drakefire Amulet chain          — FACTION-SPLIT: two different final
--                                           quests, one per faction
--   Naxx  The Dread Citadel - Naxxramas   — THREE quest IDs sharing ONE name,
--                                           gated by Argent Dawn rep tier
--                                           (Honored / Revered / Exalted).
--                                           ANY ONE completed = attuned; the
--                                           name is identical across all three,
--                                           so ONLY the id distinguishes them.
--
--   ZG    no personal attunement — walk in with a group.
--   AQ20  no personal attunement.
--   AQ40  no personal attunement. AQ access is gated at the REALM level (the
--         War Effort + "Bang a Gong!" / Scarab Gong), not per character, and
--         the Scepter of the Shifting Sands chain is optional. Nothing about
--         AQ is a per-character flag, so it must never grey a card.
--
-- QUEST IDS — every id below was web-verified against Wowhead Classic before
-- shipping (page fetched, quest name read back). Do NOT "correct" these from
-- memory; re-verify against the cited URL instead.
--
--   7487  Attunement to the Core                  https://www.wowhead.com/classic/quest=7487
--   7761  Blackhand's Command                     https://www.wowhead.com/classic/quest=7761
--   6502  Drakefire Amulet             (ALLIANCE) https://www.wowhead.com/classic/quest=6502
--   6602  Blood of the Black Dragon Champion
--                                         (HORDE) https://www.wowhead.com/classic/quest=6602
--   9121  The Dread Citadel - Naxxramas (Honored) https://www.wowhead.com/classic/quest=9121
--   9122  The Dread Citadel - Naxxramas (Revered) https://www.wowhead.com/classic/quest=9122
--   9123  The Dread Citadel - Naxxramas (Exalted) https://www.wowhead.com/classic/quest=9123
--
-- Cross-checked against warcraft.wiki.gg "Instance attunement (Classic)", which
-- lists MC / Onyxia / BWL / Naxxramas as the ONLY vanilla raid attunements:
--   https://warcraft.wiki.gg/wiki/Instance_attunement_(Classic)
-- ZG/AQ20/AQ40 negative confirmed by Blizzard's own AQ announcement (no
-- attunement or key for either AQ raid):
--   https://news.blizzard.com/en-us/world-of-warcraft/23493335/explore-the-temple-of-ahn-qiraj-and-ruins-of-ahn-qiraj
--
-- FACTION SPLIT is implemented as a UNION, not a faction branch: a Horde
-- character can never have completed 6502 and an Alliance character can never
-- have completed 6602, so "either one complete" is exactly equivalent to the
-- per-faction test — and it stays correct without depending on a faction field
-- that may not be captured yet on a cold record.
----------------------------------------------------------------------

-- PURE: raidKey -> the quest ids that grant it. ANY ONE complete = attuned.
local ATTUNE_QUESTS = {
    MC   = { 7487 },
    BWL  = { 7761 },
    Ony  = { 6502, 6602 },              -- Alliance final, Horde final
    Naxx = { 9121, 9122, 9123 },        -- Honored, Revered, Exalted
}

-- PURE: raids with NO personal attunement — always attuned, never greyed.
local ATTUNE_ALWAYS = { ZG = true, AQ20 = true, AQ40 = true }

Tracker.ATTUNE_QUESTS = ATTUNE_QUESTS
Tracker.ATTUNE_ALWAYS = ATTUNE_ALWAYS

-- The Daseeki.Sync namespace key this data rides cross-account on.
local ATTUNE_NS = "attune"
Tracker.ATTUNE_NS = ATTUNE_NS

-- Attunements only ever flip false->true, so re-probing hot is pure waste.
Tracker.ATTUNE_RECHECK_INTERVAL = 60    -- seconds between unforced re-probes
Tracker._attuneCheckedAt = nil          -- Store.Now() of the last probe
Tracker._attuneForce     = false        -- set by QUEST_TURNED_IN / entering world

-- Probe one quest id. Returns true/false, or NIL when the API is unavailable —
-- nil must never be coerced to false, or a cold client would grey every raid.
--
-- API (catalog-verified, build 1.15.9.68808):
--   C_QuestLog.IsQuestFlaggedCompleted(questID:number) -> isCompleted:bool
-- The 1.15.9 catalog lists NO bare `IsQuestFlaggedCompleted` global, so the
-- C_QuestLog namespace is the only supported spelling; the global branch below
-- is defensive belt-and-braces for a build that still exposes the old alias.
local function questCompleted(questID)
    local fn = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
    if type(fn) == "function" then
        local ok, res = pcall(fn, questID)
        if ok then return res and true or false end
    end
    local g = rawget(_G, "IsQuestFlaggedCompleted")
    if type(g) == "function" then
        local ok, res = pcall(g, questID)
        if ok then return res and true or false end
    end
    return nil
end
Tracker._questCompleted = questCompleted

-- PURE: build the full { [raidKey] = bool } matrix from a completion probe.
-- `probe(questID)` returns true/false/nil. Returns nil (NOT a table of falses)
-- when the probe could not answer a single gated quest — the caller must then
-- leave whatever it already had alone.
function Tracker.AttunementFlags(probe)
    if type(probe) ~= "function" then return nil end
    local out, answered = {}, false
    for _, key in ipairs(ns.Store.RAID_KEYS) do
        if ATTUNE_ALWAYS[key] then
            out[key] = true
        else
            local ids = ATTUNE_QUESTS[key]
            local val = false
            if ids then
                for _, id in ipairs(ids) do
                    local done = probe(id)
                    if done ~= nil then answered = true end
                    if done == true then val = true; break end
                end
            end
            out[key] = val
        end
    end
    if not answered then return nil end
    return out
end

-- PURE: fold a previous matrix into a fresh one. Attunement is MONOTONIC — it
-- can only ever go false->true — so a stored `true` is never allowed to regress
-- to false. This is what protects the record from a probe taken before the
-- client's completed-quest cache has warmed up after login.
function Tracker.MergeAttunements(prev, fresh)
    if type(fresh) ~= "table" then return nil end
    if type(prev) == "table" then
        for k, v in pairs(prev) do
            if v == true then fresh[k] = true end
        end
    end
    return fresh
end

-- PURE: do two matrices differ? Drives the MarkDirty decision.
local function attuneChanged(a, b)
    if type(a) ~= "table" then return type(b) == "table" end
    if type(b) ~= "table" then return true end
    for k, v in pairs(a) do if b[k] ~= v then return true end end
    for k, v in pairs(b) do if a[k] ~= v then return true end end
    return false
end
Tracker._attuneChanged = attuneChanged

-- Our own account's payload for the "attune" namespace:
--   { [nameRealm] = { [raidKey] = bool } } for every character WE own.
-- Only records that actually carry a matrix are published, so a character that
-- has not logged in since the update stays absent (reads as nil = unknown) and
-- is never greyed on a peer's screen.
function Tracker.AttunePayload()
    local out = {}
    local S = ns.Store
    local bucket = S and S.GetSelfAccount and S.GetSelfAccount(false)
    if not bucket then return out end
    for _, tbl in ipairs({ bucket.characters, bucket.homeless }) do
        if type(tbl) == "table" then
            for nameRealm, rec in pairs(tbl) do
                if type(rec) == "table" and type(rec.attunements) == "table" then
                    out[nameRealm] = rec.attunements
                end
            end
        end
    end
    return out
end

-- Hand our payload to the mesh. Defensive lookup: Daseeki.Sync is created in
-- syncns.lua, which loads AFTER this file.
local function markAttuneDirty()
    local Sync = _G and _G.Daseeki and _G.Daseeki.Sync
    if Sync and Sync.MarkDirty then Sync.MarkDirty(ATTUNE_NS) end
end
Tracker._markAttuneDirty = markAttuneDirty

----------------------------------------------------------------------
-- Cross-account read index.
--
-- A namespace payload must NOT be written into peer character records: those
-- records are owned by the mesh's character graph and are wholesale-replaced by
-- Store.WriteInboundCharacter on every state push, so anything we merged in
-- would be silently erased. (This is the same reason the Bags syncBridge keeps
-- its data in the namespace and reads it through Daseeki.Sync rather than
-- decorating records.) We therefore keep a lazily-rebuilt nameRealm -> flags
-- index projected FROM the namespace, and consult it only as the fallback for a
-- record that carries no matrix of its own.
--
-- Two accounts advertising the SAME character (a machine re-set-up under a new
-- account id, before Store.ReconcileStaleTwins retires the old copy) are folded
-- with OR rather than last-writer-wins: attunement is monotonic, so the
-- attuned answer is the true one and the fold is order-independent.
----------------------------------------------------------------------

Tracker._attuneIndex      = nil
Tracker._attuneIndexDirty = true

function Tracker.InvalidateAttuneIndex()
    Tracker._attuneIndexDirty = true
end

function Tracker.AttuneIndex()
    if Tracker._attuneIndex and not Tracker._attuneIndexDirty then
        return Tracker._attuneIndex
    end
    local idx = {}
    local S = ns.Store
    if S and S.SyncNSAll then
        for _, entry in pairs(S.SyncNSAll(ATTUNE_NS)) do
            local data = entry and entry.data
            if type(data) == "table" then
                for nameRealm, flags in pairs(data) do
                    if type(nameRealm) == "string" and type(flags) == "table" then
                        local cur = idx[nameRealm]
                        if not cur then
                            cur = {}
                            idx[nameRealm] = cur
                        end
                        for k, v in pairs(flags) do
                            if v == true then cur[k] = true
                            elseif cur[k] == nil then cur[k] = false end
                        end
                    end
                end
            end
        end
    end
    Tracker._attuneIndex      = idx
    Tracker._attuneIndexDirty = false
    return idx
end

-- A peer account's payload arrived (or was replayed from the cache at login).
-- Nothing to merge: the namespace store already holds it, we just drop the
-- projected index so the next read rebuilds.
function Tracker.OnRemoteAttune(_ownerKey, _data)
    Tracker.InvalidateAttuneIndex()
end

----------------------------------------------------------------------
-- Store.RaidAttuned — the READ API the detail/roster views consume.
--
-- ADDITIVE FUNCTION INJECTION: this is attached to the ns.Store table from
-- tracker.lua rather than declared in store.lua. store.lua is owned elsewhere
-- and its migration block must not be touched; the attunement feature is
-- otherwise entirely self-contained in this file plus the syncns namespace
-- registration. tracker.lua loads after store.lua in the .toc, so ns.Store
-- always exists here. If this ever moves into store.lua proper, delete the
-- injection below and nothing else changes — the signature is identical.
--
--   Store.RaidAttuned(rec, raidKey) -> true | false | nil
--     true   attuned (or the raid has no personal attunement at all)
--     false  definitively NOT attuned -> the caller greys the lockout text
--     nil    NO DATA — an old peer that has not updated, or a record written
--            before this feature shipped. Callers treat nil as attuned, so a
--            mid-rollout mesh never greys a character it simply cannot see.
----------------------------------------------------------------------

if ns.Store then
    function ns.Store.RaidAttuned(rec, raidKey)
        if type(raidKey) ~= "string" then return nil end
        -- Ungated raids answer true unconditionally — even for a nil record.
        if ATTUNE_ALWAYS[raidKey] then return true end
        if not ATTUNE_QUESTS[raidKey] then return nil end   -- not a tracked raid
        if type(rec) ~= "table" then return nil end
        local a = rec.attunements
        if type(a) == "table" and a[raidKey] ~= nil then
            return a[raidKey] and true or false
        end
        -- Cross-account fallback: the "attune" namespace projection.
        local nameRealm = rec.nameRealm
        if type(nameRealm) == "string" and nameRealm ~= "" then
            local flags = Tracker.AttuneIndex()[nameRealm]
            if type(flags) == "table" and flags[raidKey] ~= nil then
                return flags[raidKey] and true or false
            end
        end
        return nil
    end
end

-- Capture THIS character's attunement matrix onto its record. Throttled: an
-- unforced call inside ATTUNE_RECHECK_INTERVAL of the last probe is a no-op,
-- because attunements cannot change without a quest turn-in (which forces).
-- Returns true when the stored matrix actually changed.
local function captureAttunements(rec, force)
    local now = ns.Store.Now()
    local prev = rec.attunements
    if not force and type(prev) == "table" then
        local at = Tracker._attuneCheckedAt
        if at and (now - at) < Tracker.ATTUNE_RECHECK_INTERVAL then return false end
    end
    local fresh = Tracker.AttunementFlags(questCompleted)
    if not fresh then return false end          -- API cold: keep what we had
    Tracker._attuneCheckedAt = now
    local merged = Tracker.MergeAttunements(prev, fresh)
    if not attuneChanged(prev, merged) then
        rec.attunements = merged
        return false
    end
    rec.attunements = merged
    return true
end
Tracker._captureAttunements = captureAttunements

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
    captureBoonItems(rec)      -- A7.4: boonCount = displacers in bags
    captureAuras(rec)
    captureDMF(rec)            -- A8: must follow captureAuras (reads the DMF slot)
    captureRaidLockouts(rec)

    -- Personal raid attunement. Throttled internally; a pending force (quest
    -- turn-in / entering the world) bypasses the throttle exactly once.
    local attuneForce = Tracker._attuneForce and true or false
    Tracker._attuneForce = false
    if captureAttunements(rec, attuneForce) then
        -- The matrix moved: republish our account's payload so every peer
        -- (and every other account of ours) sees the new flag. The namespace
        -- push is debounced by the mesh, so a burst costs one propagation.
        Tracker.InvalidateAttuneIndex()
        markAttuneDirty()
    end

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
    -- HASH-AFTER-SEND.
    --
    -- The stamp below is a claim that this state has been DELIVERED — the change
    -- filter reads it to suppress every later capture that hashes the same. It
    -- used to be written before the push was even attempted, so a change
    -- captured while we knew zero peers (alone at login, mesh still joining, the
    -- peer relogging) was recorded as delivered and then suppressed forever. The
    -- state escaped only when something ELSE about the character changed, which
    -- is exactly the "remote character frozen until it does something" symptom.
    --
    -- So: stamp optimistically, fire, then roll back to the PREVIOUS stamp if the
    -- transport reports it reached nobody. Rolling back to the previous values
    -- (not to nil) keeps FORCE_REFRESH_INTERVAL measured from the last genuine
    -- delivery. `receipt.sent` is left nil when no transport is subscribed at
    -- all — a mesh-less build must keep its historic behaviour, so nil never
    -- triggers a rollback.
    local prevHash, prevAt = Tracker._lastPushHash, Tracker._lastPushAt
    Tracker._lastPushHash = hash
    Tracker._lastPushAt   = rec.lastSeen

    -- Local signal for the mesh layer (wave N2). No network I/O here.
    local receipt = {}
    ns:Fire("STATE_CHANGED", nameRealm, rec, force and true or nil, receipt)

    if type(receipt.sent) == "number" and receipt.sent <= 0 then
        Tracker._lastPushHash = prevHash
        Tracker._lastPushAt   = prevAt
        Tracker._pushRollbacks = (Tracker._pushRollbacks or 0) + 1
    end
end

----------------------------------------------------------------------
-- ARMED SAFETY NET (spec §4.2's periodic rescan)
--
-- Capture is entirely event-driven: UNIT_AURA, BAG_UPDATE_*, resting, flags, XP.
-- A character parked in a city — the alt sitting in Orgrimmar with a world buff
-- ticking down, which is precisely the character the roster exists to show —
-- fires NONE of those. It never captures, so:
--   * Tracker.FORCE_REFRESH_INTERVAL was UNREACHABLE. The 5-minute "max quiet"
--     forced push is evaluated inside ShouldPush, and ShouldPush only runs from
--     a capture, so the one backstop that was supposed to cover a dropped push
--     could never fire on the characters that needed it most.
--   * a push that reached nobody (see the hash-after-send rollback above) had
--     nothing to retry it.
--
-- A 30s ticker fixes both by guaranteeing the capture path runs. It is cheap
-- BECAUSE of the A10.1 change filter: a capture whose content hash is unchanged
-- writes the store and returns without firing STATE_CHANGED, so a parked
-- character costs one local record refresh per 30s and zero network traffic.
--
-- Guarded on both ends: nothing before login (no record to capture, and
-- Tracker.Capture would bail anyway) and nothing during teardown (the logout
-- flush has already sent the final forced state; another capture racing it can
-- only re-open work the client is in the middle of tearing down).
----------------------------------------------------------------------
Tracker.SAFETY_RESCAN_INTERVAL = 30

function Tracker.SafetyRescanTick()
    if not (ns.state and ns.state.loggedIn) then return end
    if Tracker.IsTeardown and Tracker.IsTeardown() then return end
    Tracker._safetyRescans = (Tracker._safetyRescans or 0) + 1
    ns:SafeCall(Tracker.RequestCapture)
end

function Tracker.ArmSafetyRescan()
    if Tracker._safetyTicker then return Tracker._safetyTicker end
    if not (C_Timer and C_Timer.NewTicker) then return nil end
    Tracker._safetyTicker = C_Timer.NewTicker(Tracker.SAFETY_RESCAN_INTERVAL, function()
        ns:SafeCall(Tracker.SafetyRescanTick)
    end)
    return Tracker._safetyTicker
end

function Tracker.DisarmSafetyRescan()
    local t = Tracker._safetyTicker
    if t and t.Cancel then t:Cancel() end
    Tracker._safetyTicker = nil
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

    -- A8 login resume (spec §5): either forgive the cooldown (logged out RESTING
    -- with DMF not booned, gone >= 8h01m) or resume it from the SAME value with a
    -- fresh tick base, so the offline span is never billed as online time. Runs
    -- BEFORE the first capture, whose tick would otherwise see a stale timestamp.
    if ns.Store and ns.Store.DMFCooldownResume then
        local selfRec = ns.Store.EnsureSelfCharacter(selfNameRealm())
        if selfRec then ns.Store.DMFCooldownResume(selfRec, ns.Store.Now()) end
    end

    -- Ask the server for our saved-instance (lockout) data.
    if RequestRaidInfo then RequestRaidInfo() end

    -- Arm the periodic rescan (spec §4.2). Idempotent, so a second OnLogin — a
    -- /reload path, or the harness calling it twice — cannot stack tickers.
    Tracker.ArmSafetyRescan()

    -- Teardown / loading-screen latch (see IsTeardown above). Registered BEFORE
    -- the generic capture events so the latch is already correct by the time the
    -- PLAYER_ENTERING_WORLD capture is queued.
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        -- Re-arm: this is the far side of a loading screen, so we are back in a
        -- live world. Open the partial-scan grace windows.
        Tracker._leavingWorld = false
        Tracker._enteredWorldAt = (GetTime and GetTime()) or 0
        -- Attunement: re-probe unthrottled on the far side of every loading
        -- screen. The completed-quest cache is one of the things that is cold
        -- right after login, so the FIRST honest read is often this one.
        Tracker._attuneForce = true
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
        -- Stop the safety rescan BEFORE the final forced capture, so the ticker
        -- can never queue work behind the mesh's logout flush. (SafetyRescanTick
        -- also checks IsTeardown; this is the belt to that suspenders.)
        Tracker.DisarmSafetyRescan()
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
    ----------------------------------------------------------------------
    -- A7 — chronoboon cast wiring (spec §4.4). This is what removes the hover
    -- dependency: boon your buffs and walk away, and the card still shows them.
    --
    -- Both are registered even though using the ITEM often produces no visible
    -- cast bar: an instant use fires only _SUCCEEDED, and FinishBoonCast handles
    -- an empty snapshot by falling back to each slot's own live duration.
    ----------------------------------------------------------------------
    ns:RegisterEvent("UNIT_SPELLCAST_START", function(_, unit, _, spellID)
        if unit ~= "player" or spellID ~= SPELL_BOON_CAST then return end
        local rec = ns.Store.EnsureSelfCharacter(selfNameRealm())
        if not rec then return end
        Tracker.BeginBoonCast(rec)
        -- Spec step 3: a delayed re-snapshot catches buffs gained DURING the cast.
        if C_Timer and C_Timer.After then
            C_Timer.After(BOON_RESNAPSHOT_DELAY, function()
                if not Tracker._inBoonCast then return end
                local r = ns.Store.EnsureSelfCharacter(selfNameRealm())
                if not r then return end
                local fresh = Tracker.SnapshotBoonable(r)
                local snap = Tracker._boonSnapshot or {}
                for slot, s in pairs(fresh) do
                    if snap[slot] == nil then snap[slot] = s end
                end
                Tracker._boonSnapshot = snap
            end)
        end
    end)

    ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
        if unit ~= "player" then return end
        if spellID ~= SPELL_BOON_CAST and spellID ~= SPELL_UNBOON_CAST then return end
        local rec = ns.Store.EnsureSelfCharacter(selfNameRealm())
        if not rec then return end
        if spellID == SPELL_BOON_CAST then
            Tracker.FinishBoonCast(rec)
        else
            Tracker.FinishUnboonCast(rec)
            -- Spec: rescan 0.25 s later for the restored buffs' real durations.
            if C_Timer and C_Timer.After then
                C_Timer.After(UNBOON_RESCAN_DELAY, function()
                    ns:SafeCall(Tracker.Capture, true)
                end)
            end
        end
        -- Spec §9.4: boon and unboon success are FORCED pushes — the change
        -- filter must never be able to swallow them.
        ns:SafeCall(Tracker.Capture, true)
    end)

    for _, evt in ipairs({ "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
                           "UNIT_SPELLCAST_STOP" }) do
        ns:RegisterEvent(evt, function(_, unit, _, spellID)
            if unit ~= "player" or spellID ~= SPELL_BOON_CAST then return end
            -- Spec step 5: drop the pending state. Nothing is re-flipped, so an
            -- interrupted boon leaves the buffs exactly as live as they still are.
            -- _STOP also fires immediately after a SUCCESS, in the SAME frame in
            -- which FinishBoonCast is still holding the window open on purpose.
            -- FinishBoonCast nils the snapshot, so its absence is how we tell a
            -- real interrupt from the tail of a successful cast.
            if Tracker._inBoonCast and Tracker._boonSnapshot then
                Tracker.AbortBoonCast()
            end
        end)
    end

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

    -- Attunement: a quest hand-in is the ONLY way an attunement can flip, so it
    -- is the one event that must force an unthrottled re-probe. We register our
    -- OWN handler rather than extending the world-buff detector in timers.lua —
    -- ns:RegisterEvent appends to a per-event handler list, so both run.
    -- QUEST_TURNED_IN(questID, xpReward, moneyReward) — signature already relied
    -- on by timers.lua's hand-in detector.
    ns:RegisterEvent("QUEST_TURNED_IN", function()
        Tracker._attuneForce = true
        Tracker.RequestCapture()
    end)

    -- Attunement: force the first probe of the session, and seed the namespace
    -- projection from whatever cross-account data the store already holds.
    Tracker._attuneForce = true
    Tracker.InvalidateAttuneIndex()

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
    -- A9.1: the same suppressed capture MIGRATED both legacy remainings into
    -- start epochs (no lastDataUpdate on this record, so `now` is the reference
    -- and the countdown freezes at its stored value rather than back-dating).
    ck(rec.hearthstoneCDStart == epochNow - 2400, "A9.1: legacy hearth remaining -> start epoch")
    ck(rec.chronoboonCDStart  == epochNow - 3000, "A9.1: legacy chrono remaining -> start epoch")

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

    -- ---- A9.1 the epoch model replaces carry-forward -----------------------
    -- There is no "carry a remaining value forward" step any more: the stored
    -- epoch is exact, so a suppressed capture derives from it and _cdCapturedAt
    -- (which used to drive the decay) no longer affects the value at all.
    settle()
    Tracker._loggingOut = true
    rec = { hearthstoneCDStart = epochNow - 2400, chronoboonCDStart = epochNow - 3570 }
    Tracker._cdCapturedAt = epochNow - 60
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCD == 1200, "suppressed: remaining derives from the epoch, not _cdCapturedAt")
    ck(rec.itemCooldown == 30, "suppressed: the chronoboon epoch derives the same way")
    epochNow = epochNow + 60
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCD == 1140, "60s of real time later the SAME epoch reads 1140")
    ck(rec.itemCooldown == 0, "an elapsed cooldown floors at 0, never negative")
    ck(rec.chronoboonCDStart == 0, "an elapsed chronoboon stamp is self-healed away")
    epochNow = EPOCH

    -- Outside the window the API is trusted again.
    settle()
    Tracker._enteredWorldAt = frameNow - 3.1
    cdStart, cdDuration = frameNow - 100, 3600
    rec = { hearthstoneCD = 0, itemCooldown = 0 }
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCD == 3500, "EW +3.1s: API trusted again -> 3500s")
    ck(rec.hearthstoneCDStart == epochNow - 100, "A9.1: the API read is stored as a START EPOCH")
    ck(Tracker._cdCapturedAt == epochNow, "a trusted read stamps _cdCapturedAt")

    -- ---- A9.5 sanity gates on the API read ---------------------------------
    settle()
    cdStart, cdDuration = frameNow - 0.2, 1.5
    rec = {}
    Tracker._captureCooldowns(rec)
    ck((rec.hearthstoneCDStart or 0) == 0, "A9.5: duration <=1.5s is the GCD -> rejected")

    settle()
    cdStart, cdDuration = frameNow, 7201
    rec = {}
    Tracker._captureCooldowns(rec)
    ck((rec.hearthstoneCDStart or 0) == 0, "A9.5: duration >7200s is garbage -> rejected")

    settle()
    cdStart, cdDuration = frameNow + 50, 3600
    rec = {}
    Tracker._captureCooldowns(rec)
    ck((rec.hearthstoneCDStart or 0) == 0, "A9.1: a start time in the future is discarded")

    -- ---- A9.1 the API can never DELETE a stored cooldown -------------------
    -- This is the failure the gap analysis called BROKEN: "any capture that
    -- failed to read the API writes 0 and the cooldown disappears."
    settle()
    cdStart, cdDuration = 0, 0
    rec = { hearthstoneCDStart = epochNow - 1200 }
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCDStart == epochNow - 1200, "an empty API read leaves the stored epoch alone")
    ck(rec.hearthstoneCD == 2400, "...and the countdown keeps running")

    -- ...but a NEWER derived start (a real re-use, or the instance-kick reset
    -- the spec calls out) does displace it.
    settle()
    cdStart, cdDuration = frameNow - 10, 3600
    rec = { hearthstoneCDStart = epochNow - 1200 }
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCDStart == epochNow - 10, "a newer derived start displaces the stored one")

    -- Re-reading the SAME live cooldown must not creep the stamp forward.
    settle()
    cdStart, cdDuration = frameNow - 1200, 3600
    rec = { hearthstoneCDStart = epochNow - 1201 }
    Tracker._captureCooldowns(rec)
    ck(rec.hearthstoneCDStart == epochNow - 1201, "a same-cooldown re-read inside the slack is ignored")

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

----------------------------------------------------------------------
-- HASH-AFTER-SEND: a change that reached NO peer must be re-pushed when a
-- peer appears, instead of being recorded as delivered and filtered forever.
--
-- Runs the real Tracker.Capture against a stub transport that stamps the
-- receipt, so it exercises the exact path the mesh uses.
----------------------------------------------------------------------
local function testHashAfterSend(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local saved = {
        auras = _G.C_UnitAuras, cont = _G.C_Container, item = _G.C_Item,
        map = _G.C_Map, getTime = _G.GetTime,
        resting = _G.IsResting, pvp = _G.UnitIsPVP, ffa = _G.UnitIsPVPFreeForAll,
        inInst = _G.IsInInstance, savedInst = _G.GetNumSavedInstances,
        now = ns.Store.Now, settings = ns.Store.GetSettings,
        ensure = ns.Store.EnsureSelfCharacter, write = ns.Store.WriteSelfCharacter,
        loggedIn = ns.state.loggedIn,
        sub = _G.GetSubZoneText, mini = _G.GetMinimapZoneText,
    }
    local savedLatch = {
        Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt,
        Tracker._auraCapturedAt, Tracker._cdCapturedAt,
        Tracker._lastPushHash, Tracker._lastPushAt, Tracker._pushRollbacks,
    }

    local FRAME, EPOCH = 30000, 1700100000
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

    local rec = {}
    ns.Store.EnsureSelfCharacter = function() return rec end
    ns.Store.WriteSelfCharacter  = function() end

    -- Stub transport: `targets` is how many peers it can reach right now, and it
    -- stamps the receipt exactly as Mesh.PushState does.
    local fires, targets, counting = 0, 0, true
    ns:On("STATE_CHANGED", function(_, _, _, receipt)
        if not counting then return end
        fires = fires + 1
        if type(receipt) == "table" then receipt.sent = targets end
    end)

    local ok, err = pcall(function()
        Tracker._leavingWorld, Tracker._loggingOut = false, false
        Tracker._enteredWorldAt = frameNow - 60
        Tracker._auraCapturedAt, Tracker._cdCapturedAt = nil, nil
        Tracker._lastPushHash, Tracker._lastPushAt = nil, 0
        Tracker._pushRollbacks = 0

        local function setAura(rem)
            auraList = { { name = "Songflower Serenade", spellId = 15366,
                           expirationTime = frameNow + rem } }
        end

        -- 1) A real change captured with ZERO peers: it fires, but the transport
        --    reports nobody heard it, so the stamp must roll back.
        targets = 0
        setAura(1795)
        Tracker.Capture()
        ck(fires == 1, "first capture must fire (got " .. fires .. ")")
        ck(Tracker._lastPushHash == nil,
            "a push that reached nobody still stamped the delivered-hash")
        ck(Tracker._pushRollbacks == 1, "the rollback was not counted")

        -- 2) THE REGRESSION: with the state unchanged, the very next capture must
        --    still try again. Before the fix this was filtered out forever.
        Tracker.Capture()
        ck(fires == 2, "an undelivered change was not retried (fires=" .. fires .. ")")

        -- 3) A peer appears -> the push lands -> the stamp sticks.
        targets = 2
        Tracker.Capture()
        ck(fires == 3, "the retry did not fire once a peer existed")
        ck(Tracker._lastPushHash ~= nil, "a delivered push did not stamp the hash")
        ck(Tracker._lastPushAt == epochNow, "the delivered push did not stamp the time")
        local deliveredHash = Tracker._lastPushHash

        -- 4) ...and NOW the change filter engages normally again.
        Tracker.Capture()
        ck(fires == 3, "an identical capture pushed after a real delivery (fires=" .. fires .. ")")

        -- 5) A later undelivered push rolls back to the PREVIOUS stamp, not to
        --    nil, so FORCE_REFRESH_INTERVAL keeps measuring from the last genuine
        --    delivery rather than restarting.
        targets = 0
        _G.IsResting = function() return false end
        epochNow = epochNow + 5
        Tracker.Capture()
        ck(fires == 4, "a content change did not fire")
        ck(Tracker._lastPushHash == deliveredHash,
            "rollback did not restore the PREVIOUS delivered hash")
        ck(Tracker._lastPushAt == epochNow - 5,
            "rollback did not restore the previous delivery time")

        -- 6) A transport that leaves the receipt UNSTAMPED (no mesh subscribed)
        --    must not trigger a rollback — mesh-less builds keep old behaviour.
        counting = false
        Tracker._lastPushHash, Tracker._lastPushAt = nil, 0
        _G.IsResting = function() return true end
        Tracker.Capture()
        ck(Tracker._lastPushHash ~= nil,
            "an unstamped receipt was treated as a failed delivery")
        counting = true
    end)

    counting = false

    _G.C_UnitAuras, _G.C_Container, _G.C_Item, _G.C_Map = saved.auras, saved.cont, saved.item, saved.map
    _G.GetTime, _G.IsResting = saved.getTime, saved.resting
    _G.UnitIsPVP, _G.UnitIsPVPFreeForAll = saved.pvp, saved.ffa
    _G.IsInInstance, _G.GetNumSavedInstances = saved.inInst, saved.savedInst
    _G.GetSubZoneText, _G.GetMinimapZoneText = saved.sub, saved.mini
    ns.Store.Now, ns.Store.GetSettings = saved.now, saved.settings
    ns.Store.EnsureSelfCharacter, ns.Store.WriteSelfCharacter = saved.ensure, saved.write
    ns.state.loggedIn = saved.loggedIn
    Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt = savedLatch[1], savedLatch[2], savedLatch[3]
    Tracker._auraCapturedAt, Tracker._cdCapturedAt = savedLatch[4], savedLatch[5]
    Tracker._lastPushHash, Tracker._lastPushAt = savedLatch[6], savedLatch[7]
    Tracker._pushRollbacks = savedLatch[8]

    if not ok then fails[#fails + 1] = "error in hash-after-send fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- ARMED SAFETY NET: the 30s rescan ticker (spec §4.2).
----------------------------------------------------------------------
local function testSafetyRescan(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local savedTimer   = _G.C_Timer
    local savedTicker  = Tracker._safetyTicker
    local savedLoggedIn = ns.state.loggedIn
    local savedLatch   = { Tracker._leavingWorld, Tracker._loggingOut }
    local savedRequest = Tracker.RequestCapture
    local savedCount   = Tracker._safetyRescans

    -- Capture the interval + callback the ticker is armed with.
    local armed, cancels = {}, 0
    _G.C_Timer = {
        After = function() end,
        NewTicker = function(interval, fn)
            armed[#armed + 1] = { interval = interval, fn = fn }
            return { Cancel = function() cancels = cancels + 1 end }
        end,
    }

    local requests = 0
    Tracker.RequestCapture = function() requests = requests + 1 end
    Tracker._safetyTicker = nil
    Tracker._safetyRescans = 0

    local ok, err = pcall(function()
        Tracker.ArmSafetyRescan()
        ck(#armed == 1, "ArmSafetyRescan did not create a ticker")
        ck(armed[1] and armed[1].interval == 30,
            "the rescan interval is " .. tostring(armed[1] and armed[1].interval) .. ", expected 30")
        ck(Tracker.SAFETY_RESCAN_INTERVAL == 30, "SAFETY_RESCAN_INTERVAL is not 30s")

        -- Idempotent: a second arm (a /reload path) must not stack tickers.
        Tracker.ArmSafetyRescan()
        ck(#armed == 1, "ArmSafetyRescan stacked a second ticker")

        -- Logged in and live -> the tick requests a capture.
        ns.state.loggedIn = true
        Tracker._leavingWorld, Tracker._loggingOut = false, false
        armed[1].fn()
        ck(requests == 1, "the ticker did not request a capture (requests=" .. requests .. ")")
        ck(Tracker._safetyRescans == 1, "the rescan was not counted")

        -- Guard 1: not logged in -> no capture.
        ns.state.loggedIn = false
        armed[1].fn()
        ck(requests == 1, "the ticker captured while logged out")

        -- Guard 2: teardown -> no capture (the logout flush owns the final state).
        ns.state.loggedIn = true
        Tracker._loggingOut = true
        armed[1].fn()
        ck(requests == 1, "the ticker captured during teardown")
        Tracker._loggingOut = false

        -- Still live afterwards.
        armed[1].fn()
        ck(requests == 2, "the ticker stopped working after a guarded tick")

        -- Disarm cancels and allows a clean re-arm.
        Tracker.DisarmSafetyRescan()
        ck(cancels == 1, "DisarmSafetyRescan did not cancel the ticker")
        ck(Tracker._safetyTicker == nil, "the ticker handle was not cleared")
        Tracker.ArmSafetyRescan()
        ck(#armed == 2, "could not re-arm after a disarm")
        Tracker.DisarmSafetyRescan()

        -- No C_Timer.NewTicker at all (a bare environment) must not error.
        _G.C_Timer = { After = function() end }
        Tracker._safetyTicker = nil
        ck(Tracker.ArmSafetyRescan() == nil, "arming without NewTicker should return nil")
    end)

    _G.C_Timer = savedTimer
    Tracker._safetyTicker = savedTicker
    ns.state.loggedIn = savedLoggedIn
    Tracker._leavingWorld, Tracker._loggingOut = savedLatch[1], savedLatch[2]
    Tracker.RequestCapture = savedRequest
    Tracker._safetyRescans = savedCount

    if not ok then fails[#fails + 1] = "error in safety-rescan fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- A7 — the chronoboon CAST lifecycle. This is the suite that proves the
-- headline fix: booned buffs are known WITHOUT ever hovering the icon.
----------------------------------------------------------------------
local function testBoonCastLifecycle(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local savedGetTime = _G.GetTime
    local savedNow     = ns.Store and ns.Store.Now
    local savedState = {
        inCast   = Tracker._inBoonCast,
        snap     = Tracker._boonSnapshot,
        removals = Tracker._boonRemovals,
        parsed   = Tracker._boonParsed,
        unboon   = Tracker._unboonUntil,
        count    = Tracker._lastBoonCount,
        seeded   = Tracker._boonCountSeeded,
    }
    local FRAME, EPOCH = 10000, 1700000000
    local frameNow = FRAME
    _G.GetTime   = function() return frameNow end
    ns.Store.Now = function() return EPOCH end

    local function reset()
        Tracker._inBoonCast   = false
        Tracker._boonSnapshot = nil
        Tracker._boonRemovals = {}
        Tracker._boonParsed   = nil
        Tracker._unboonUntil  = 0
        frameNow = FRAME
    end
    local function live(dur) return { duration = dur, option = 0, source = 0 } end
    local function boon(dur) return { duration = dur, option = 0, source = BOON_SOURCE } end
    local function newRec(states)
        return { nameRealm = "Tester-TestRealm", auraStates = states, boonCount = 3 }
    end

    local ok, err = pcall(function()

    -- ---- A7.1 the headline: boon WITHOUT hovering -------------------------
    -- Cast start snapshots the live boonable slots; cast success flips them to
    -- BOONED. No tooltip is ever read.
    reset()
    local rec = newRec({ [1] = live(3000), [4] = live(900), [9] = live(1200) })
    Tracker.BeginBoonCast(rec, frameNow)
    ck(Tracker._inBoonCast == true, "cast start: the in-boon-cast window opens")
    ck(Tracker._boonSnapshot[1].duration == 3000, "cast start: slot 1 snapshotted at 3000")
    ck(Tracker._boonSnapshot[9] == nil,
       "cast start: Battle Shout (slot 9) is NOT boonable and is not snapshotted")

    frameNow = FRAME + 2                       -- a 2s cast
    local parsed = Tracker.FinishBoonCast(rec, frameNow, EPOCH)
    ck(rec.auraStates[1].source == BOON_SOURCE, "cast success: slot 1 is now BOONED")
    ck(rec.auraStates[1].duration == 2998, "cast success: slot 1 snapshot-adjusted 3000 -> 2998")
    ck(rec.auraStates[4].source == BOON_SOURCE, "cast success: slot 4 is now BOONED")
    ck(rec.auraStates[9].source == 0,
       "cast success: a live Battle Shout stays LIVE (not boonable)")
    ck(rec.chronoboonActive == true, "cast success: chronoboonActive set")
    ck(parsed.count == 2, "cast success: two buffs projected into the boon cache")
    ck(Tracker.BoonedBuffCount() == 2, "cast success: BoonedBuffCount reports 2")
    ck(Tracker._boonParsed ~= nil and Tracker._boonParsed.slots[1].duration == 2998,
       "cast success: the cache is rewritten FROM THE PROJECTION")

    -- ---- A7.2 the item cooldown is stamped from the cast ------------------
    ck(rec.chronoboonCDStart == EPOCH, "A7.2: chronoboon CD start epoch stamped by the cast")
    ck(rec.itemCooldown == 3600, "A7.2: item cooldown reads a full hour immediately")
    local cdRec = { chronoboonCDStart = EPOCH }
    ck(Tracker._chronoboonStampRemaining(cdRec, EPOCH + 600) == 3000,
       "A7.2: stamp derives 3000s remaining after 600s")
    ck(Tracker._chronoboonStampRemaining(cdRec, EPOCH + 3600) == 0,
       "A7.2: an elapsed stamp reads 0")
    ck(cdRec.chronoboonCDStart == 0, "A7.2: an elapsed stamp is self-healed away")
    local skew = { chronoboonCDStart = EPOCH + 500 }
    ck(Tracker._chronoboonStampRemaining(skew, EPOCH) == 0, "A7.2: a future stamp is discarded")

    -- ---- A7.4 boonCount is ITEMS IN BAGS, decremented by the cast ---------
    ck(rec.boonCount == 2, "A7.4: the cast consumed one displacer (3 -> 2 in bags)")

    -- ---- A7.3 strip vs player-cancel discrimination -----------------------
    -- Slot 1 vanished 0.1s before the success (the chronoboon stripping it);
    -- slot 4 vanished a full second before (the player cancelled it).
    reset()
    rec = newRec({ [1] = live(3000), [4] = live(900) })
    Tracker.BeginBoonCast(rec, frameNow)
    Tracker.NoteBoonRemoval(4, frameNow + 1.0)     -- deliberate cancel
    Tracker.NoteBoonRemoval(1, frameNow + 1.9)     -- stripped by the boon
    frameNow = FRAME + 2
    Tracker.FinishBoonCast(rec, frameNow, EPOCH)
    ck(rec.auraStates[1] and rec.auraStates[1].source == BOON_SOURCE,
       "A7.3: a removal 0.1s before success = STRIPPED -> restored as booned")
    -- Snapshot taken at FRAME with 3000s left; stripped at FRAME+1.9 -> 2998.1,
    -- floored to 2998. The credit is against the moment it was STRIPPED, not the
    -- moment the cast landed — that is the whole point of recording removal times.
    ck(rec.auraStates[1].duration == 2998,
       "A7.3: the stripped slot carries snapshot duration minus elapsed-at-strip")
    ck(rec.auraStates[4] == nil,
       "A7.3: a removal 1.0s before success = PLAYER CANCEL -> stays gone")
    ck(Tracker._boonParsed.slots[4] == nil,
       "A7.3: the cancelled slot is dropped from the cache, so no scan resurrects it")

    -- Exactly on the 0.3s boundary counts as a strip (spec says "within 0.3s").
    reset()
    rec = newRec({ [1] = live(3000) })
    Tracker.BeginBoonCast(rec, frameNow)
    Tracker.NoteBoonRemoval(1, frameNow + 1.7)
    frameNow = FRAME + 2.0
    Tracker.FinishBoonCast(rec, frameNow, EPOCH)
    ck(rec.auraStates[1] and rec.auraStates[1].source == BOON_SOURCE,
       "A7.3: exactly 0.3s before success still counts as stripped")

    -- ---- an INSTANT item use (no cast start) still works -------------------
    -- Using the item often fires only _SUCCEEDED. With no snapshot, each slot's
    -- own live duration is used.
    reset()
    rec = newRec({ [3] = live(1500) })
    Tracker.FinishBoonCast(rec, frameNow, EPOCH)
    ck(rec.auraStates[3].source == BOON_SOURCE and rec.auraStates[3].duration == 1500,
       "instant use (no cast start): live slots still flip to booned at their own duration")

    -- ---- interrupt: nothing is retroactively flipped -----------------------
    reset()
    rec = newRec({ [1] = live(3000) })
    Tracker.BeginBoonCast(rec, frameNow)
    Tracker.AbortBoonCast()
    ck(Tracker._inBoonCast == false, "interrupt: the cast window closes")
    ck(Tracker._boonSnapshot == nil, "interrupt: the snapshot is dropped")
    ck(rec.auraStates[1].source == 0, "interrupt: slot 1 is still LIVE, not booned")

    -- ---- unboon restores booned slots as LIVE ------------------------------
    reset()
    rec = newRec({ [1] = boon(2500), [SLOT_DMF] = boon(4000), [9] = live(600) })
    rec.chronoboonActive = true
    rec.dmfInBoon = true
    local restoredDMF = Tracker.FinishUnboonCast(rec, frameNow, EPOCH)
    ck(rec.auraStates[1].source == 0, "unboon: slot 1 flips BOONED -> LIVE")
    ck(rec.auraStates[1].duration == 2500, "unboon: the stored duration carries over intact")
    ck(rec.auraStates[9].source == 0, "unboon: an already-live slot is untouched")
    ck(rec.chronoboonActive == false, "unboon: chronoboonActive cleared")
    ck(rec.dmfInBoon == false, "unboon: dmfInBoon cleared")
    ck(restoredDMF == true, "unboon: reports that it restored DMF")
    ck(Tracker._boonParsed == nil, "unboon: the boon cache is dropped")
    ck(Tracker.InUnboonWindow(frameNow + 2.9) == true, "unboon: the 3s window is open at +2.9s")
    ck(Tracker.InUnboonWindow(frameNow + 3.1) == false, "unboon: the window has closed at +3.1s")

    -- ---- A8.5 the boon/unboon DMF re-stamps -------------------------------
    reset()
    rec = newRec({ [SLOT_DMF] = boon(4000) })
    rec.dmfCooldown = { offlineSince = 0, remainingOnlineSecs = 120, lastTickEpoch = EPOCH }
    rec.dmfCooldownActive = true
    Tracker.FinishUnboonCast(rec, frameNow, EPOCH)
    ck(ns.Store.DMFCooldownRemaining(rec) == 14400,
       "A8.5: an unboon that RESTORES DMF re-stamps a full 4h")

    reset()
    rec = newRec({ [SLOT_DMF] = live(3000) })
    rec.dmfCooldown = { offlineSince = 0, remainingOnlineSecs = 120, lastTickEpoch = EPOCH }
    rec.dmfCooldownActive = true
    Tracker.FinishBoonCast(rec, frameNow, EPOCH)
    ck(rec.dmfInBoon == true, "A8.5: booning a live DMF sets dmfInBoon")
    ck(ns.Store.DMFCooldownRemaining(rec) == 14400,
       "A8.5: entering a boon CARRYING DMF re-stamps a full 4h (missed-unboon safety net)")

    -- ---- the removal recorder fires from a scan during the cast -----------
    reset()
    local savedAuras = _G.C_UnitAuras
    _G.C_UnitAuras = { GetBuffDataByIndex = function(_, i)
        if i == 1 then
            return { name = "Songflower Serenade", spellId = 15366,
                     expirationTime = frameNow + 900 }
        end
        return nil
    end }
    Tracker._auraCapturedAt = nil
    Tracker._enteredWorldAt = frameNow - 60
    Tracker._leavingWorld, Tracker._loggingOut = false, false
    rec = newRec({ [1] = live(3000), [4] = live(900) })
    Tracker._inBoonCast = true                   -- pretend a cast is in flight
    Tracker._boonRemovals = {}
    Tracker._captureAuras(rec)
    ck(Tracker._boonRemovals[1] == frameNow,
       "in-cast scan: slot 1 vanishing is RECORDED with the frame time")
    ck(rec.auraStates[1] ~= nil,
       "in-cast scan: the vanished slot is preserved, not dropped (the cast resolves it)")
    _G.C_UnitAuras = savedAuras

    end)

    _G.GetTime   = savedGetTime
    ns.Store.Now = savedNow
    Tracker._inBoonCast      = savedState.inCast
    Tracker._boonSnapshot    = savedState.snap
    Tracker._boonRemovals    = savedState.removals
    Tracker._boonParsed      = savedState.parsed
    Tracker._unboonUntil     = savedState.unboon
    Tracker._lastBoonCount   = savedState.count
    Tracker._boonCountSeeded = savedState.seeded
    if not ok then fails[#fails + 1] = "error in boon-cast fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- A7.5 — tooltip reconciliation. The parser stays (it is better than the
-- reference's), but it is now the SECOND opinion, not the only one.
----------------------------------------------------------------------
local function testBoonReconcile(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local R = Tracker.ReconcileBoonSnapshot

    -- No cache yet (first hover ever): the tooltip is adopted whole.
    local out = R({ slots = { [1] = { duration = 3000 } }, dmf = false, count = 1 }, nil)
    ck(out.slots[1].duration == 3000, "reconcile: with no cache the tooltip is adopted")

    -- (a) a slot we claim is booned that the tooltip does NOT list is a phantom.
    local cached = { slots = { [1] = { duration = 3000 }, [4] = { duration = 900 } },
                     dmf = false, count = 2 }
    out = R({ slots = { [1] = { duration = 3000 } }, dmf = false, count = 1 }, cached)
    ck(out.slots[1] ~= nil, "reconcile: a slot present in both survives")
    ck(out.slots[4] == nil, "reconcile: a cached slot absent from the tooltip is a PHANTOM, dropped")
    ck(out.count == 1, "reconcile: the count comes from the tooltip (it saw the real thing)")

    -- (b) drift <= 120s keeps the cached (more precise) cast-snapshot value...
    cached = { slots = { [1] = { duration = 3000 } }, dmf = false, count = 1 }
    out = R({ slots = { [1] = { duration = 2910 } }, dmf = false, count = 1 }, cached)
    ck(out.slots[1].duration == 3000, "reconcile: 90s of drift is tolerated, cache wins")
    out = R({ slots = { [1] = { duration = 2880 } }, dmf = false, count = 1 }, cached)
    ck(out.slots[1].duration == 3000, "reconcile: exactly 120s of drift is still tolerated")
    -- ...but more than 120s is corrected from the tooltip.
    out = R({ slots = { [1] = { duration = 2879 } }, dmf = false, count = 1 }, cached)
    ck(out.slots[1].duration == 2879, "reconcile: >120s of drift is CORRECTED from the tooltip")

    -- The DMF variant is never overwritten from a tooltip (it shows the generic name).
    cached = { slots = { [SLOT_DMF] = { duration = 4000, option = 7 } }, dmf = true, count = 1 }
    out = R({ slots = { [SLOT_DMF] = { duration = 100 } }, dmf = true, count = 1 }, cached)
    ck(out.slots[SLOT_DMF].duration == 100, "reconcile: the DMF DURATION is corrected")
    ck(out.slots[SLOT_DMF].option == 7, "reconcile: the DMF VARIANT is never taken from a tooltip")

    -- A tooltip slot the cache never had is adopted.
    out = R({ slots = { [1] = { duration = 3000 }, [6] = { duration = 500 } }, count = 2 },
            { slots = { [1] = { duration = 3000 } }, count = 1 })
    ck(out.slots[6] and out.slots[6].duration == 500,
       "reconcile: a slot only the tooltip knows about is adopted")

    ck(R(nil, cached) == cached, "reconcile: a nil tooltip parse leaves the cache alone")
end

----------------------------------------------------------------------
-- A8 — the capture-side DMF edges (the arithmetic itself is store/dmf cooldown).
----------------------------------------------------------------------
local function testDMFCapture(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedNow    = ns.Store.Now
    local savedDebuff = _G.C_UnitAuras
    local savedSeeded, savedWasLive = Tracker._dmfSeeded, Tracker._dmfWasLive
    local savedLatch  = { Tracker._leavingWorld, Tracker._loggingOut }
    local EPOCH = 1700000000
    local epochNow = EPOCH
    ns.Store.Now = function() return epochNow end

    local nDebuffs = 0
    _G.C_UnitAuras = { GetDebuffDataByIndex = function(_, i)
        if i <= nDebuffs then return { name = "d" .. i } end
        return nil
    end }

    local ok, err = pcall(function()
    Tracker._leavingWorld, Tracker._loggingOut = false, false

    local function newRec(dmfCell)
        return { nameRealm = "Tester-TestRealm", auraStates = { [SLOT_DMF] = dmfCell },
                 dmfCooldown = { offlineSince = 0, remainingOnlineSecs = 0, lastTickEpoch = 0 } }
    end

    -- ---- the FIRST capture only seeds the edge (login must not re-stamp) ----
    Tracker._dmfSeeded, Tracker._dmfWasLive = false, false
    local rec = newRec({ duration = 3000, option = 0, source = 0 })
    Tracker._captureDMF(rec)
    ck(rec.dmfCooldownActive ~= true,
       "login seed: a fortune already live at login does NOT start a fresh 4h")

    -- ---- a genuine 0 -> live gain starts the cooldown ----------------------
    Tracker._dmfSeeded, Tracker._dmfWasLive = true, false
    rec = newRec({ duration = 7200, option = 0, source = 0 })
    Tracker._captureDMF(rec)
    ck(rec.dmfCooldownActive == true, "fresh gain: cooldown started")
    ck(ns.Store.DMFCooldownRemaining(rec) == 14400, "fresh gain: a full 4h is owed")

    -- ...and holding it does not re-stamp on every capture.
    epochNow = EPOCH + 900
    Tracker._captureDMF(rec)
    ck(ns.Store.DMFCooldownRemaining(rec) == 13500,
       "holding the fortune: the tick decrements, it does not re-stamp")

    -- ---- teardown stamps the offline epoch ---------------------------------
    Tracker._loggingOut = true
    epochNow = EPOCH + 1000
    Tracker._captureDMF(rec)
    ck(rec.dmfCooldown.offlineSince == EPOCH + 1000, "teardown: offlineSince stamped")
    Tracker._loggingOut = false

    -- ---- A8.4 debuff-bar push: the gate matrix (PURE) ----------------------
    local S = Tracker.ShouldClearDMFOnDebuffPush
    local on = { dmfCooldownActive = true, dmfInBoon = false, inInstance = false }
    ck(S(on, 15) == false, "push: 15 debuffs is below the 16-slot bar")
    ck(S(on, 16) == true,  "push: 16 debuffs means the hidden CD aura was evicted")
    ck(S(on, 20) == true,  "push: above 16 also fires")
    ck(S({ dmfCooldownActive = true, dmfInBoon = true }, 16) == false,
       "push: skipped while DMF is stashed in the boon")
    ck(S({ dmfCooldownActive = true, inInstance = true }, 16) == false,
       "push: skipped entirely inside an instance")
    ck(S({ dmfCooldownActive = false }, 16) == false,
       "push: skipped when no cooldown is tracked")
    ck(S(nil, 16) == false, "push: nil record is inert")

    -- ---- A8.4 the push actually clears, through the capture path -----------
    Tracker._dmfSeeded, Tracker._dmfWasLive = true, true
    rec = newRec({ duration = 7200, option = 0, source = 0 })
    ns.Store.DMFCooldownStart(rec, epochNow)
    nDebuffs = 16
    local before = Tracker._dmfPushes or 0
    Tracker._captureDMF(rec)
    ck(rec.dmfCooldownActive == false, "push: the capture path clears the cooldown")
    ck((Tracker._dmfPushes or 0) == before + 1, "push: the event is counted")
    nDebuffs = 0

    -- ---- A8.4 announcement routing (PURE) ----------------------------------
    local C = Tracker.DMFPushChannels
    local solo = C(false, false)
    ck(#solo == 1 and solo[1] == "SAY", "announce: solo -> SAY only")
    local party = C(false, true)
    ck(#party == 2 and party[1] == "SAY" and party[2] == "PARTY", "announce: party -> SAY + PARTY")
    local raid = C(true, true)
    ck(#raid == 2 and raid[1] == "SAY" and raid[2] == "RAID",
       "announce: raid -> SAY + RAID (RAID wins over PARTY)")

    -- The toggle defaults ON, including when the key is absent entirely.
    local savedGS = ns.Store.GetSettings
    ns.Store.GetSettings = function() return {} end
    ck(Tracker.DMFPushAnnounceEnabled() == true, "announce: an ABSENT setting means ON")
    ns.Store.GetSettings = function() return { dmfPushAnnounce = false } end
    ck(Tracker.DMFPushAnnounceEnabled() == false, "announce: the toggle can turn it off")
    ns.Store.GetSettings = savedGS

    end)

    ns.Store.Now   = savedNow
    _G.C_UnitAuras = savedDebuff
    Tracker._dmfSeeded, Tracker._dmfWasLive = savedSeeded, savedWasLive
    Tracker._leavingWorld, Tracker._loggingOut = savedLatch[1], savedLatch[2]
    if not ok then fails[#fails + 1] = "error in DMF capture fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- RAID ATTUNEMENT — quest-flag matrix, monotonic merge, capture throttle,
-- the cross-account index, and the Store.RaidAttuned tri-state.
--
-- The three facts most worth guarding here, because getting any of them wrong
-- greys a raid the owner CAN enter (or fails to grey one they cannot):
--   1. Naxx is ANY-OF-THREE ids that share one quest NAME — only the id tells
--      the rep tiers apart, so a name-based implementation would silently pass
--      a test written against names.
--   2. Ony is faction-split — EITHER final quest attunes, and neither faction
--      can ever hold the other's.
--   3. ZG / AQ20 / AQ40 have NO personal attunement and must answer true
--      unconditionally — including for a nil record, and even if a corrupt
--      record claims false.
----------------------------------------------------------------------
local function testAttunement(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- A probe factory: only the listed ids read as completed.
    local function probeFor(list)
        local done = {}
        for _, id in ipairs(list or {}) do done[id] = true end
        return function(id) return done[id] == true end
    end

    -- ---- 1) the full matrix, nothing completed ----------------------------
    local none = Tracker.AttunementFlags(probeFor({}))
    ck(type(none) == "table", "flags: a probe that answers returns a table")
    ck(none.MC == false and none.BWL == false, "flags: MC/BWL false when unquested")
    ck(none.Ony == false and none.Naxx == false, "flags: Ony/Naxx false when unquested")
    ck(none.ZG == true and none.AQ20 == true and none.AQ40 == true,
       "flags: ZG/AQ20/AQ40 are ALWAYS true (no personal attunement exists)")
    -- Every RAID_KEYS key is present -- the matrix mirrors the lockout keys.
    for _, k in ipairs(ns.Store.RAID_KEYS) do
        ck(none[k] ~= nil, "flags: RAID_KEYS key '" .. k .. "' present in the matrix")
    end

    -- ---- 2) single-quest raids -------------------------------------------
    ck(Tracker.AttunementFlags(probeFor({ 7487 })).MC == true, "MC: 7487 attunes")
    ck(Tracker.AttunementFlags(probeFor({ 7487 })).BWL == false, "MC quest does not attune BWL")
    ck(Tracker.AttunementFlags(probeFor({ 7761 })).BWL == true, "BWL: 7761 attunes")
    ck(Tracker.AttunementFlags(probeFor({ 7761 })).MC == false, "BWL quest does not attune MC")

    -- ---- 3) Onyxia FACTION SPLIT: either final quest attunes ---------------
    ck(Tracker.AttunementFlags(probeFor({ 6502 })).Ony == true,
       "Ony: 6502 (ALLIANCE Drakefire Amulet) attunes")
    ck(Tracker.AttunementFlags(probeFor({ 6602 })).Ony == true,
       "Ony: 6602 (HORDE Blood of the Black Dragon Champion) attunes")
    ck(Tracker.AttunementFlags(probeFor({ 6502, 6602 })).Ony == true,
       "Ony: both ids complete still attunes")
    ck(Tracker.AttunementFlags(probeFor({ 6403 })).Ony == false,
       "Ony: 6403 (The Great Masquerade, MID-chain) does NOT attune")
    ck(Tracker.AttunementFlags(probeFor({ 6501 })).Ony == false,
       "Ony: 6501 (The Dragon's Eye, mid-chain) does NOT attune")

    -- ---- 4) Naxxramas ANY-OF-THREE by Argent Dawn rep tier ----------------
    ck(Tracker.AttunementFlags(probeFor({ 9121 })).Naxx == true, "Naxx: 9121 (Honored) attunes")
    ck(Tracker.AttunementFlags(probeFor({ 9122 })).Naxx == true, "Naxx: 9122 (Revered) attunes")
    ck(Tracker.AttunementFlags(probeFor({ 9123 })).Naxx == true, "Naxx: 9123 (Exalted) attunes")
    ck(Tracker.AttunementFlags(probeFor({ 9120 })).Naxx == false, "Naxx: a neighbouring id does not attune")
    -- All three ids are distinct and all three are actually in the table.
    local naxx = Tracker.ATTUNE_QUESTS.Naxx
    ck(#naxx == 3, "Naxx: exactly three rep-tier variants are tracked")
    ck(naxx[1] ~= naxx[2] and naxx[2] ~= naxx[3] and naxx[1] ~= naxx[3],
       "Naxx: the three variant ids are distinct")

    -- ---- 5) the exact verified id set (guards a memory-based 'correction') --
    local EXPECT = { MC = { 7487 }, BWL = { 7761 }, Ony = { 6502, 6602 },
                     Naxx = { 9121, 9122, 9123 } }
    for key, ids in pairs(EXPECT) do
        local got = Tracker.ATTUNE_QUESTS[key]
        ck(got and #got == #ids, "ids: " .. key .. " has " .. #ids .. " quest id(s)")
        for i, id in ipairs(ids) do
            ck(got and got[i] == id, "ids: " .. key .. "[" .. i .. "] == " .. id)
        end
    end
    ck(Tracker.ATTUNE_QUESTS.ZG == nil and Tracker.ATTUNE_QUESTS.AQ20 == nil
       and Tracker.ATTUNE_QUESTS.AQ40 == nil,
       "ids: ZG/AQ20/AQ40 carry NO quest ids (no personal attunement)")

    -- ---- 6) an API that cannot answer must yield nil, never all-false ------
    ck(Tracker.AttunementFlags(function() return nil end) == nil,
       "flags: a probe that answers nothing returns nil (never a table of falses)")
    ck(Tracker.AttunementFlags(nil) == nil, "flags: a non-function probe returns nil")

    -- ---- 7) monotonic merge: true never regresses -------------------------
    local merged = Tracker.MergeAttunements({ MC = true, BWL = false },
                                            { MC = false, BWL = true, Ony = false })
    ck(merged.MC == true, "merge: a stored true survives a false re-probe")
    ck(merged.BWL == true, "merge: a fresh true is adopted")
    ck(merged.Ony == false, "merge: a key absent from prev takes the fresh value")
    ck(Tracker.MergeAttunements(nil, { MC = true }).MC == true, "merge: nil prev is fine")
    ck(Tracker.MergeAttunements({ MC = true }, nil) == nil, "merge: nil fresh returns nil")

    -- ---- 8) change detection ---------------------------------------------
    local CH = Tracker._attuneChanged
    ck(CH(nil, { MC = true }) == true, "changed: nil -> table is a change")
    ck(CH({ MC = true }, nil) == true, "changed: table -> nil is a change")
    ck(CH({ MC = true }, { MC = true }) == false, "changed: identical matrices are equal")
    ck(CH({ MC = true }, { MC = false }) == true, "changed: a flipped flag is a change")
    ck(CH({ MC = true }, { MC = true, BWL = false }) == true, "changed: an added key is a change")
    ck(CH(nil, nil) == false, "changed: nil vs nil is not a change")

    -- ---- 9) Store.RaidAttuned tri-state ------------------------------------
    local RA = ns.Store.RaidAttuned
    ck(type(RA) == "function", "RaidAttuned: injected onto ns.Store")

    -- Always-attuned raids answer true unconditionally.
    for _, k in ipairs({ "ZG", "AQ20", "AQ40" }) do
        ck(RA(nil, k) == true, "RaidAttuned: " .. k .. " is true even for a nil record")
        ck(RA({ nameRealm = "X-Y" }, k) == true, "RaidAttuned: " .. k .. " true with no matrix")
        ck(RA({ attunements = { [k] = false } }, k) == true,
           "RaidAttuned: " .. k .. " true even if a corrupt record claims false")
    end

    local recFull = { nameRealm = "Mine-Realm",
                      attunements = { MC = true, BWL = false, Ony = true, Naxx = false,
                                      ZG = true, AQ20 = true, AQ40 = true } }
    ck(RA(recFull, "MC") == true,   "RaidAttuned: MC true from the record")
    ck(RA(recFull, "BWL") == false, "RaidAttuned: BWL false from the record")
    ck(RA(recFull, "Ony") == true,  "RaidAttuned: Ony true from the record")
    ck(RA(recFull, "Naxx") == false,"RaidAttuned: Naxx false from the record")

    -- No data anywhere -> nil (an old peer / a pre-update record).
    local recBare = { nameRealm = "Stranger-Realm" }
    for _, k in ipairs({ "MC", "BWL", "Ony", "Naxx" }) do
        ck(RA(recBare, k) == nil, "RaidAttuned: " .. k .. " is nil with no data (old peer)")
    end
    ck(RA(nil, "MC") == nil, "RaidAttuned: nil record -> nil for a gated raid")
    ck(RA(recFull, "Karazhan") == nil, "RaidAttuned: an untracked raid key -> nil")
    ck(RA(recFull, nil) == nil, "RaidAttuned: a nil raid key -> nil")

    -- ---- 10) the cross-account namespace projection -----------------------
    local S = ns.Store
    if S and S.SyncNSPut then
        local NSK = Tracker.ATTUNE_NS
        local O1, O2 = "__attunetest-acct1", "__attunetest-acct2"
        local savedIdx, savedDirty = Tracker._attuneIndex, Tracker._attuneIndexDirty

        S.SyncNSPut(NSK, O1, 1, {
            ["Peer-Realm"]  = { MC = true,  BWL = false, Ony = false, Naxx = false },
            ["Alt-Realm"]   = { MC = false, BWL = false, Ony = false, Naxx = false },
        }, 100)
        Tracker.InvalidateAttuneIndex()

        ck(RA({ nameRealm = "Peer-Realm" }, "MC") == true,
           "index: a peer account's MC=true is read through the namespace")
        ck(RA({ nameRealm = "Peer-Realm" }, "BWL") == false,
           "index: a peer account's BWL=false greys through the namespace")
        ck(RA({ nameRealm = "Alt-Realm" }, "Naxx") == false,
           "index: a never-attuned alt reads false for Naxx")
        ck(RA({ nameRealm = "Alt-Realm" }, "ZG") == true,
           "index: ZG still true for that same never-attuned alt")
        ck(RA({ nameRealm = "Nobody-Realm" }, "MC") == nil,
           "index: an unknown character stays nil")

        -- The record's OWN matrix wins over the namespace projection.
        ck(RA({ nameRealm = "Peer-Realm", attunements = { MC = false } }, "MC") == false,
           "index: the record's own matrix takes precedence over the projection")

        -- Two accounts naming the same character fold with OR (monotonic).
        S.SyncNSPut(NSK, O2, 1, { ["Peer-Realm"] = { MC = false, BWL = true } }, 101)
        Tracker.InvalidateAttuneIndex()
        ck(RA({ nameRealm = "Peer-Realm" }, "MC") == true,
           "index: duplicate owners fold with OR (MC stays true)")
        ck(RA({ nameRealm = "Peer-Realm" }, "BWL") == true,
           "index: duplicate owners fold with OR (BWL becomes true)")

        -- The index is cached until invalidated.
        local i1 = Tracker.AttuneIndex()
        ck(Tracker.AttuneIndex() == i1, "index: cached between reads")
        Tracker.InvalidateAttuneIndex()
        ck(Tracker.AttuneIndex() ~= i1, "index: rebuilt after invalidation")

        -- onRemote invalidates.
        Tracker.AttuneIndex()
        Tracker.OnRemoteAttune(O1, {})
        ck(Tracker._attuneIndexDirty == true, "index: OnRemoteAttune marks it dirty")

        S.SyncNSDrop(NSK, O1)
        S.SyncNSDrop(NSK, O2)
        Tracker._attuneIndex, Tracker._attuneIndexDirty = savedIdx, savedDirty
        Tracker.InvalidateAttuneIndex()
    end

    -- ---- 11) capture: throttle, cold-API safety, live probe ----------------
    local savedQL   = _G.C_QuestLog
    local savedNow  = ns.Store.Now
    local savedAt   = Tracker._attuneCheckedAt
    local epochNow  = 1700000000
    local completed = {}
    _G.C_QuestLog = { IsQuestFlaggedCompleted = function(id) return completed[id] == true end }
    ns.Store.Now  = function() return epochNow end

    local ok, err = pcall(function()
        local cap = Tracker._captureAttunements
        local rec = { nameRealm = "Cap-Realm" }

        Tracker._attuneCheckedAt = nil
        ck(cap(rec, false) == true, "capture: the first probe writes the matrix")
        ck(type(rec.attunements) == "table", "capture: rec.attunements is a table")
        ck(rec.attunements.MC == false, "capture: MC false before the quest")
        ck(rec.attunements.ZG == true,  "capture: ZG true immediately")

        -- Throttled: a completed quest is NOT picked up until the window passes.
        completed[7487] = true
        ck(cap(rec, false) == false, "capture: an unforced re-probe inside the window is a no-op")
        ck(rec.attunements.MC == false, "capture: the throttled call did not re-probe")

        -- Forced (a quest turn-in) bypasses the throttle immediately.
        ck(cap(rec, true) == true, "capture: a FORCED probe bypasses the throttle")
        ck(rec.attunements.MC == true, "capture: MC flips true after the hand-in")

        -- Past the window, an unforced probe runs again.
        completed[9122] = true
        epochNow = epochNow + Tracker.ATTUNE_RECHECK_INTERVAL + 1
        ck(cap(rec, false) == true, "capture: past the window an unforced probe runs")
        ck(rec.attunements.Naxx == true, "capture: Naxx (Revered variant) picked up")

        -- No change -> no dirty signal.
        epochNow = epochNow + Tracker.ATTUNE_RECHECK_INTERVAL + 1
        ck(cap(rec, false) == false, "capture: an unchanged matrix reports no change")

        -- A COLD api must not wipe what we already knew.
        _G.C_QuestLog = { IsQuestFlaggedCompleted = function() error("cold") end }
        epochNow = epochNow + Tracker.ATTUNE_RECHECK_INTERVAL + 1
        ck(cap(rec, true) == false, "capture: a cold API reports no change")
        ck(rec.attunements.MC == true and rec.attunements.Naxx == true,
           "capture: a cold API does NOT regress stored attunements")

        -- The namespace payload only publishes records that carry a matrix.
        local payload = Tracker.AttunePayload()
        ck(type(payload) == "table", "payload: AttunePayload returns a table")
        for nameRealm, flags in pairs(payload) do
            ck(type(nameRealm) == "string" and type(flags) == "table",
               "payload: entries are nameRealm -> flags")
        end
    end)

    _G.C_QuestLog = savedQL
    ns.Store.Now  = savedNow
    Tracker._attuneCheckedAt = savedAt
    if not ok then fails[#fails + 1] = "error in attunement fixtures: " .. tostring(err) end
end

function Tracker.RunSelfTests(verbose)
    local suites = {
        { name = "state-push change filter (A10.1)", fn = testChangeFilter },
        { name = "hash-after-send rollback", fn = testHashAfterSend },
        { name = "armed safety rescan (30s)", fn = testSafetyRescan },
        { name = "boon parsing", fn = testBoonParsing },
        { name = "boon block (owner 7-line fixture)", fn = testBoonBlock },
        { name = "live aura matching (apostrophe matrix)", fn = testLiveAuraMatching },
        { name = "spell-ID matching (A6.4/A6.6)", fn = testSpellIDMatching },
        { name = "teardown latch + grace windows", fn = testTeardownLatch },
        { name = "capture guards (A6.1/A6.2/A6.3/A17.2/A9.2)", fn = testCaptureGuards },
        { name = "boon cast lifecycle (A7.1/A7.2/A7.3/A7.4)", fn = testBoonCastLifecycle },
        { name = "boon tooltip reconciliation (A7.5)", fn = testBoonReconcile },
        { name = "DMF capture edges + debuff push (A8)", fn = testDMFCapture },
        { name = "raid attunement (quest matrix + RaidAttuned tri-state)", fn = testAttunement },
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
