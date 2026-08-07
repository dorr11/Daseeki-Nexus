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
--
-- THIS SET IS THE WHOLE TRUTH ABOUT "CAN BE BOONED", and every path that can
-- write source = BOON must consult it — not just the cast path. It was the cast
-- path alone that respected it, while ParseBoonBlock walked all ten slots, so a
-- chronoboon tooltip that merely mentioned "Battle Shout" wrote slot 9 as
-- boon-stored and the dashboard rendered the impossible "Battle Shout (Boon)".
--
-- Local mirror of Store.BOONABLE_AURA_SLOTS: the pure parser below has to run in
-- the headless harness before store.lua exists, so it cannot reach through ns.
-- testBoonScope asserts the mirror and the canonical set agree, so they cannot
-- drift apart silently.
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
--
-- BOONABLE NAMES ONLY. This list answers one question — "how many buffs are
-- inside the boon" (Tracker.BoonedBuffCount) — and a buff that cannot be boonzed
-- can never be one of them. "battle shout" and Fire Festival Fury used to sit
-- here and inflated the count by up to two whenever the words appeared anywhere
-- in the tooltip; they are the same two slots ParseBoonBlock now refuses (see
-- BOONABLE_SLOT).
--
-- Boon of Blackfathom / Spark of Inspiration STAY: they really are suspended by
-- the displacer and really do count, they simply have no dashboard slot of their
-- own, which is why they are named here and not in BUFF_SLOTS.
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
-- Diagnostic (read with /nexus debug sanity): how many times a chronoboon
-- tooltip named a buff that cannot be boonzed (slots 9/10) and was ignored. A
-- non-zero value here is normal — it is exactly the number of "Battle Shout
-- (Boon)" rows that would have been written before this fix.
Tracker._boonScopeRejects = 0
-- Parsed boon snapshot: { slots = { [slot] = { duration=sec }, ... },
--                         dmf = bool, count = n }.  Nil until first parse.
-- A `stale = true` field means "these slots were NOT refreshed by the last read;
-- they are preserved evidence" (see the evidence-preservation block below).
Tracker._boonParsed = nil

-- Diagnostics for the evidence-preservation rule, read with /nexus debug sanity.
--   _boonReadsPreserved — empty reads refused because the boon is provably still there
--   _boonReadsCleared   — empty reads honoured (the boon really is gone / really is empty)
--   _boonReadsCold      — of the preserved ones, how many were provably COLD item data
Tracker._boonReadsPreserved = 0
Tracker._boonReadsCleared   = 0
Tracker._boonReadsCold      = 0

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
--
-- TWO CORRECTNESS RULES, both learned from live tooltips:
--
--  (1) BOONABLE SLOTS ONLY. This loop used to walk all ten BUFF_SLOTS while the
--      cast path walked BOONABLE_SLOT, so the tooltip parser was the one writer
--      that could mark a non-boonable slot as boon-stored. Any chronoboon
--      tooltip whose text contained the words "Battle Shout" — a hover during a
--      raid, a client that lists the buffs it CANNOT hold, anything — wrote
--      slots[9], and every consumer downstream faithfully rendered "Battle Shout
--      (Boon)": a state the game cannot produce. Slots 9/10 are now skipped
--      outright and counted in Tracker._boonScopeRejects for /nexus debug sanity.
--
--  (2) EACH BUFF'S DURATION COMES FROM ITS OWN SEGMENT. Taking "the first (...)
--      after the name starts" is only right when the name HAS a parenthetical of
--      its own; when it does not, the search ran on to the end of the block and
--      adopted the NEXT buff's minutes. That is the same shape as the original
--      Fengus symptom the header describes and it survived the first fix:
--          "Rallying Cry of the Dragonslayer\nFengus' Ferocity (119m)"
--      gave slot 1 Fengus' 119m. The search is now clamped to the buff's own
--      segment — up to the next newline, or the start of the next tracked buff
--      name, whichever comes first — so a duration can never cross a name
--      boundary. A name with no readable duration of its own yields duration 0,
--      meaning "in the boon, remaining unknown"; ReconcileBoonSnapshot treats
--      that as presence-only and keeps whatever number it already had.
function Tracker.ParseBoonBlock(text)
    local slots, dmf = {}, false
    text = normName(text)
    if text == "" then return slots, dmf end

    -- Where does the segment belonging to a name starting at `from` end?
    -- The earliest of: the next newline, the start of any OTHER tracked buff
    -- name after this one, or the end of the block.
    local function segmentEnd(from, ownPrefix)
        local stop = text:find("\n", from + #ownPrefix, true) or (#text + 1)
        for j = 1, #BUFF_SLOTS do
            local other = BUFF_SLOTS[j]
            if other.prefix ~= "" and other.prefix ~= ownPrefix then
                local at = text:find(other.prefix, from + #ownPrefix, true)
                if at and at < stop then stop = at end
            end
        end
        return stop - 1
    end

    for s = 1, #BUFF_SLOTS do
        local def = BUFF_SLOTS[s]
        if def.prefix ~= "" then
            local from = text:find(def.prefix, 1, true)
            if from then
                if not BOONABLE_SLOT[def.slot] then
                    -- (1) Named in the tooltip but physically unboonable: ignore.
                    Tracker._boonScopeRejects = (Tracker._boonScopeRejects or 0) + 1
                else
                    -- (2) Own segment only.
                    local seg = text:sub(from, segmentEnd(from, def.prefix))
                    slots[def.slot] = { duration = Tracker.ParseBoonDuration(seg) or 0 }
                    if def.prefix == DMF_BUFF_PREFIX then dmf = true end
                end
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

-- Drop any non-boonable slot from a boon snapshot's slot table, in place.
-- Returns the number removed. Used on every snapshot that comes from OUTSIDE
-- this session's parser — the persisted cache written by an older build is the
-- one that matters — so a slots[9] booned before the fix cannot be rehydrated
-- back into the record on the next login. Pure over its argument.
function Tracker.ScrubNonBoonableSlots(slots)
    if type(slots) ~= "table" then return 0 end
    local removed = 0
    for slot in pairs(slots) do
        if not BOONABLE_SLOT[slot] then
            slots[slot] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- Rehydrate the parsed boon snapshot from the persisted cache (login path).
function Tracker.RehydrateBoonCache()
    local nameRealm = selfNameRealm()
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    local cached = data and data.caches and data.caches.tooltipBoon
                   and data.caches.tooltipBoon[nameRealm]
    if type(cached) == "table" and type(cached.slots) == "table" then
        -- The cache on disk may predate the boonable-scope fix and hold a
        -- slots[9]/[10]. Scrub before adopting, and take the count down with it
        -- so "N in the boon" does not keep counting a buff that was never there.
        local dropped = Tracker.ScrubNonBoonableSlots(cached.slots)
        local count = math.max(0, (tonumber(cached.count) or 0) - dropped)
        Tracker._boonParsed = { slots = cached.slots, dmf = cached.dmf or false,
                                count = count }
        Tracker._boonTooltipCount = count
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
            -- A tooltip duration of 0 is NOT a disagreement — ParseBoonBlock
            -- emits it for "the block names this buff but carries no readable
            -- parenthetical for it", i.e. presence without a number. Correcting
            -- a good cached duration down to that would be the leak bug wearing
            -- a different hat, so presence-only readings keep the cached value.
            local dur = (tipDur > 0 and drift > BOON_DRIFT_TOLERANCE) and tipDur or haveDur
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

-- Gather every scrap of text a tooltip is rendering into ONE block, in reading
-- order. Spec §4.4: the read scrapes "every left/right tooltip line plus every
-- font-string region".
--
-- WHY THE SCRAPE IS THAT WIDE. It used to read GameTooltipTextLeft1..NumLines
-- and nothing else, which is exactly the shape the Supercharged Chronoboon
-- Displacer happens to render — but it is not the only one:
--
--   * A duration is commonly laid out on the RIGHT FontString of the line whose
--     LEFT holds the buff's name ("Fengus' Ferocity" | "(119m)"). Reading only
--     the left column found the name and lost the minutes — presence without a
--     number. (Since 03be2a5 that degrades safely rather than stealing the next
--     buff's minutes, but the duration is still gone.)
--   * Some renderings put the suspended-effects block in an UNNAMED font-string
--     region that never appears in the TextLeft/TextRight enumeration at all,
--     so the buffs were invisible to us entirely.
--
-- THE TWO HALVES OF ONE LINE SHARE ONE TEXT LINE, joined by a space and not by
-- a newline. They are two columns of the same visual row, and ParseBoonBlock
-- clamps a buff's duration search to its own segment — up to the next NEWLINE
-- or the next tracked name (the 03be2a5 leak fix). Emitting "(119m)" on a line
-- of its own would therefore throw the duration away the instant we collected
-- it. Joined, the pair reads as the ordinary "Name (duration)" form the parser
-- already handles, and the clamp still stops a duration crossing into the row
-- below.
--
-- DEDUPE, TWO KINDS:
--   * IDENTITY. The numbered TextLeft/TextRight FontStrings are themselves
--     regions of the tooltip, so the region sweep would collect every line a
--     second time. An object already read is skipped outright.
--   * TEXT, in the region sweep only — so a tooltip with no right column and no
--     extra regions produces byte-for-byte the block it produced before. A
--     client that renders the same words twice must not hand the parser two
--     copies: an exact repeat is dropped, and a repeat that EXTENDS what we
--     already hold ("Fengus' Ferocity" -> "Fengus' Ferocity (119m)") REPLACES
--     it. ParseBoonBlock reads a slot's FIRST occurrence, so without that
--     replacement a bare-name line would shadow the region carrying the
--     minutes and the poorer reading (0 = "present, duration unknown") would
--     win — the highest duration must win per slot, never the lowest.
--
-- PURE given its arguments: `tip` defaults to GameTooltip and `lookup` to a _G
-- read, and the self-test hands it fakes for both, so exercising it stomps no
-- global. Returns the RAW joined block; the caller normalizes.
function Tracker.CollectBoonTooltipText(tip, lookup)
    tip = tip or GameTooltip
    lookup = lookup or function(name) return _G[name] end
    if not (tip and tip.NumLines) then return "" end
    local lines = tonumber(tip:NumLines()) or 0
    if lines < 1 then return "" end

    local parts, normed, taken = {}, {}, {}

    -- The text of one FontString, or nil for "nothing usable here". Marks the
    -- object as read either way, which is the identity half of the dedupe.
    local function textOf(fs)
        if type(fs) ~= "table" or taken[fs] then return nil end
        taken[fs] = true
        if type(fs.GetText) ~= "function" then return nil end
        local t = fs:GetText()
        if type(t) ~= "string" or t == "" then return nil end
        return t
    end

    local function append(t)
        parts[#parts + 1]  = t
        normed[#normed + 1] = normName(t)
    end

    -- 1) Every numbered line: left column, then right column, one text line.
    for i = 1, lines do
        local l = textOf(lookup("GameTooltipTextLeft" .. i))
        local r = textOf(lookup("GameTooltipTextRight" .. i))
        if l and r then append(l .. " " .. r)
        elseif l      then append(l)
        elseif r      then append(r) end
    end

    -- 2) Every font-string region we have not already read. The "not already
    -- read" half is textOf's alone — it returns nil for an object it has
    -- handed back once, and it is the ONLY place identity is tracked, so there
    -- is no second copy of that rule to rot out of step with this one.
    local function sweepRegions(...)
        for i = 1, select("#", ...) do
            local region = select(i, ...)
            if type(region) == "table"
               and type(region.GetObjectType) == "function"
               and region:GetObjectType() == "FontString" then
                local t = textOf(region)
                if t then
                    local rn, dup = normName(t), false
                    for k = 1, #normed do
                        local pn = normed[k]
                        if rn == pn then
                            dup = true break                      -- exact repeat
                        elseif #rn > #pn and rn:sub(1, #pn) == pn then
                            parts[k], normed[k] = t, rn           -- richer wins
                            dup = true break
                        elseif #pn > #rn and pn:sub(1, #rn) == rn then
                            dup = true break                      -- already richer
                        end
                    end
                    if not dup then append(t) end
                end
            end
        end
    end
    if type(tip.GetRegions) == "function" then sweepRegions(tip:GetRegions()) end

    return table.concat(parts, "\n")
end

----------------------------------------------------------------------
-- THE EVIDENCE-PRESERVATION RULE  (house principle: EVIDENCE WINS, ABSENCE
-- PRESERVES). This is the fix for the intermittent boon WIPE.
--
-- THE BUG IT REPAIRS. Owner report: "every so often the character I'm logged in
-- as will drop all its buffs in Nexus even though I have a full rack booned up —
-- they come back when I hover the chronoboon". His SavedVariables carry the
-- proof: Poonyx-Whitemane's SELF record with chronoboonActive = true,
-- boonCount = 4, dmfInBoon flipped true -> false, a FRESH lastSeen — and
-- auraStates = {} — while the peers' older copies of the same character still
-- hold all seven booned slots at source = BOON. The persisted
-- caches.tooltipBoon["Poonyx-Whitemane"] entry was gone too, while eight other
-- characters on the same account still had theirs.
--
-- HOW A CAPTURE READS ZERO. The chronoboon tooltip scan's only precondition was
-- that GameTooltipTextLeft1 names the chronoboon. That title line is written
-- SYNCHRONOUSLY by SetUnitAura; the suspended-effects BODY is not always there
-- on the same frame — cold item data renders a PARTIAL tooltip that is title and
-- little else. This is exactly the failure Armory's item scan hit on a cold
-- SetItemByID, and the lesson is the same: a partial tooltip reads as an honest
-- empty. ParseBoonBlock over a title-only block returns no slots, and
-- ReconcileBoonSnapshot's phantom rule ("a cached slot the tooltip does not list
-- was never really there") then dropped ALL of them, persistBoonCache dropped
-- the disk cache, and the capture that followed wrote an empty record. Nothing
-- upstream could catch it: the chronoboon aura itself makes the live scan see at
-- least one buff, so captureAuras' PARTIAL guard is false and preserveSlots
-- never runs. One bad frame is enough, and the next hover heals it — which is
-- precisely what the owner sees.
--
-- THE PRECEDENCE TABLE. Applied top-down; the first row that matches decides.
-- `parsed` = boonable slots this read resolved, `cached` = slots we already hold.
--
--  # CONDITION                                            VERDICT   WHY
--  1 parsed >= 1                                          ADOPT     Positive evidence.
--                                                                   Reconcile as before —
--                                                                   phantom rule included,
--                                                                   because a read that CAN
--                                                                   see buffs is a read that
--                                                                   would have seen this one.
--  2 parsed == 0 and cached == 0                          CLEAR     Nothing to lose. (No-op.)
--  3 parsed == 0 and the boon item is provably GONE       CLEAR     Used, sold or dropped.
--    (bag+bank count is 0 on a trustworthy read)                    An empty read agrees with
--                                                                   the bags: honour it.
--  4 parsed == 0 and the item's data is NOT cached        PRESERVE  Cold tooltip. The read is
--    (C_Item.IsItemDataCachedByID == false)                         not evidence of anything;
--                                                                   request the data and keep
--                                                                   what we have.
--  5 parsed == 0 and we CANNOT prove the data is warm     PRESERVE  Belt and braces: no
--    (no IsItemDataCachedByID on this client, or the                warmth proof means no
--    bag API was unreadable)                                        trust. A client that
--                                                                   cannot answer must not be
--                                                                   able to delete data.
--  6 parsed == 0, data warm, item present, but the        PRESERVE  A tooltip that rendered
--    tooltip rendered NO BODY beyond its title                      only its title is partial
--                                                                   by inspection, whatever
--                                                                   the item cache says.
--  7 parsed == 0, data warm, item present, body rendered  CLEAR     The genuine post-release
--                                                                   state: a real, complete
--                                                                   tooltip that lists nothing.
--
-- PRESERVE does NOT mean "pretend we read it". The kept snapshot is flagged
-- `stale = true` (un-refreshed evidence, not a fresh observation), the disk cache
-- is left exactly as it was rather than being nil'd, and no capture is requested
-- — a preserved read is by definition not a change. The slots themselves stay
-- verbatim, so what the mesh publishes is the last good reading and never an
-- authoritative empty.
--
-- The classifier is PURE over its argument so the whole table is mutation-testable
-- without a client; the impure probing lives in Tracker.BoonItemEvidence.
----------------------------------------------------------------------

Tracker.BOON_READ_ADOPT    = "ADOPT"
Tracker.BOON_READ_CLEAR    = "CLEAR"
Tracker.BOON_READ_PRESERVE = "PRESERVE"

-- ctx = { parsedSlots, cachedSlots, itemPresent, itemKnown, dataCached, hasBody }
--   dataCached: true / false / nil (nil = this client cannot tell us)
--   itemKnown:  false when the bag API could not be read at all (teardown, cold)
function Tracker.ClassifyBoonRead(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local parsed = tonumber(ctx.parsedSlots) or 0
    local cached = tonumber(ctx.cachedSlots) or 0

    if parsed > 0 then return Tracker.BOON_READ_ADOPT end          -- 1
    if cached <= 0 then return Tracker.BOON_READ_CLEAR end         -- 2
    if ctx.itemKnown and not ctx.itemPresent then                  -- 3
        return Tracker.BOON_READ_CLEAR
    end
    if ctx.dataCached == false then return Tracker.BOON_READ_PRESERVE end  -- 4
    if ctx.dataCached == nil or not ctx.itemKnown then             -- 5
        return Tracker.BOON_READ_PRESERVE
    end
    if not ctx.hasBody then return Tracker.BOON_READ_PRESERVE end  -- 6
    return Tracker.BOON_READ_CLEAR                                 -- 7
end

-- Probe the chronoboon ITEM: is one in the player's bags or bank, and is its item
-- data warm? Returns present(bool), known(bool), dataCached(bool|nil).
--
-- The BANK COUNTS. A charged displacer parked in the bank is still a boon the
-- character owns, and reading "no item" for it would let rule 3 clear a record
-- that is perfectly intact. rec.boonCount deliberately stays bags-only ("do I
-- have one on me right now"); this probe answers a different question and takes
-- the wider count.
--
-- `known` is false during teardown and inside the post-loading-screen grace, the
-- two windows where C_Item is documented to answer 0 for items that are really
-- there — the same guard captureBoonItems and captureCooldowns already use.
function Tracker.BoonItemEvidence()
    if not (C_Item and C_Item.GetItemCount) then return false, false, nil end
    if Tracker.IsTeardown() or Tracker.InEnteringWorldGrace(COOLDOWN_GRACE) then
        return false, false, nil
    end
    local present = false
    for i = 1, #CHRONOBOON_ITEMS do
        -- (itemID, includeBank) — see above for why the bank is in.
        if (tonumber(C_Item.GetItemCount(CHRONOBOON_ITEMS[i], true)) or 0) > 0 then
            present = true
            break
        end
    end
    local dataCached = nil
    if C_Item.IsItemDataCachedByID then
        dataCached = false
        for i = 1, #CHRONOBOON_ITEMS do
            if C_Item.IsItemDataCachedByID(CHRONOBOON_ITEMS[i]) then
                dataCached = true
                break
            end
        end
    end
    return present, true, dataCached
end

-- Ask the client to warm the chronoboon's item data so the NEXT read is honest.
local function requestBoonItemData()
    if not (C_Item and C_Item.RequestLoadItemDataByID) then return end
    for i = 1, #CHRONOBOON_ITEMS do
        C_Item.RequestLoadItemDataByID(CHRONOBOON_ITEMS[i])
    end
end

-- How many boonable slots a parsed snapshot holds (nil-safe).
local function boonSlotCount(parsed)
    local n = 0
    if type(parsed) == "table" and type(parsed.slots) == "table" then
        for _ in pairs(parsed.slots) do n = n + 1 end
    end
    return n
end
Tracker._boonSlotCount = boonSlotCount

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

    -- Concatenate EVERY tooltip FontString into one normalized text block —
    -- every LEFT line, every RIGHT line and every font-string REGION, per spec
    -- §4.4 (see Tracker.CollectBoonTooltipText for the shapes that needs to
    -- cover and how the two halves of a line are joined). The live Supercharged
    -- Chronoboon Displacer packs all suspended effects into a SINGLE FontString
    -- with embedded newlines; other clients split them across separate
    -- FontStrings, columns or unnamed regions. Joining + block-parsing handles
    -- all of them, so every stored buff resolves in one scan with its own
    -- duration (fixes "only one buff booned", then "the right column's minutes
    -- were never read").
    local block = normName(Tracker.CollectBoonTooltipText())

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

    -- EVIDENCE-PRESERVATION GATE (see the precedence table above). An empty read
    -- is only allowed to delete what we hold when the emptiness is PROVABLE.
    local parsedSlots = 0
    for _ in pairs(slots) do parsedSlots = parsedSlots + 1 end
    -- Did the tooltip render anything at all beyond its title line? `title` is
    -- the normalized TextLeft1 and `block` is the normalized whole tooltip, so a
    -- block no longer than its own title is a title-only render — partial by
    -- inspection (rule 6), whatever the item cache claims.
    local hasBody = (#block > #title)
    local present, known, dataCached = Tracker.BoonItemEvidence()
    local verdict = Tracker.ClassifyBoonRead({
        parsedSlots = parsedSlots,
        cachedSlots = boonSlotCount(Tracker._boonParsed),
        itemPresent = present, itemKnown = known,
        dataCached  = dataCached, hasBody = hasBody,
    })

    if verdict == Tracker.BOON_READ_PRESERVE then
        -- Keep every stored slot verbatim, mark the snapshot un-refreshed, leave
        -- the persisted cache untouched, and request the item data so the next
        -- read can be trusted. NO capture is fired: nothing changed.
        Tracker._boonReadsPreserved = (Tracker._boonReadsPreserved or 0) + 1
        if dataCached == false then
            Tracker._boonReadsCold = (Tracker._boonReadsCold or 0) + 1
        end
        if type(Tracker._boonParsed) == "table" then
            Tracker._boonParsed.stale   = true
            Tracker._boonParsed.staleAt = (GetTime and GetTime()) or 0
        end
        Tracker._boonTooltipSeen = (GetTime and GetTime()) or 0
        requestBoonItemData()
        return
    end
    if verdict == Tracker.BOON_READ_CLEAR and parsedSlots == 0 then
        Tracker._boonReadsCleared = (Tracker._boonReadsCleared or 0) + 1
    end

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

-- Exposed for the evidence-preservation suite: the whole point of that suite is
-- to drive the REAL scan against fake tooltips, not a re-implementation of it.
Tracker._scanTooltipForStoredBuffs = scanTooltipForStoredBuffs

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
-- BOONABLE_SLOT-gated: a record carrying a legacy boon-marked slot 9 (written by
-- a pre-fix build, or relayed from a peer still running one) must not be able to
-- launder it back into a fresh cache on the next cast.
local function projectBoonCache(rec)
    local parsed = { slots = {}, dmf = false, count = 0 }
    local states = rec and rec.auraStates
    if type(states) ~= "table" then return parsed end
    for slot, cell in pairs(states) do
        if BOONABLE_SLOT[slot] and type(cell) == "table"
           and (cell.source or 0) == BOON_SOURCE
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
--
-- ── THE LOGOUT WIPE (owner: "every character shows — for XP and REST") ────────
--
-- This function used to write UNCONDITIONALLY, and it is called from the same
-- Tracker.Capture that PLAYER_LEAVING_WORLD and PLAYER_LOGOUT fire SYNCHRONOUSLY
-- and FORCED as the session's final act. During teardown the unit APIs are cold —
-- exactly the condition the A17.2 latch above exists for, and which captureLocation
-- / captureCooldowns / preserveSlots / captureDMF all already consult. UnitXPMax
-- reads 0 there, the old "defensive" branch below turned that cold read into
-- 0/0/0, and WriteSelfCharacter persisted it. Since the LAST write of every
-- session was that teardown capture, what the SavedVariables held on the next
-- login was ALWAYS 0/0/0 — for every character, no matter how much real XP the
-- mid-session captures had written moments earlier. xpMax 0 makes
-- Store.RestedPercent nil and InstancesUI.ExpRow render the em-dash, which is the
-- entire reported bug. (Proof in the owner's live store: peers held Puucons at
-- ownerEpoch ...304 with a real 100/400/600 from a mid-session push, while that
-- character's OWN account held the same session 93s later at ...397 zeroed.)
--
-- TWO RULES, both "freeze, never wipe":
--   1. TEARDOWN — do not write at all. The record keeps the last known-good
--      values, which is what the whole logout flush is supposed to preserve.
--      PLAYER_LEAVING_WORLD also fires before every ORDINARY loading screen, so
--      this covers zone and instance transitions too.
--   2. A COLD xpMax ON A SUB-60 — every level below 60 has a non-zero XP
--      requirement, so xpMax <= 0 on a sub-60 character is not a fact about the
--      character, it is proof the API is not warm yet (a fresh login, mid-loading
--      screen). Freeze rather than zero. This also removes any need for a separate
--      ENTERING_WORLD grace window here: a cold read declares itself.
--
-- 0/0/0 is still written for a genuine level >= 60 — there the zero IS the fact.
local function captureXP(rec)
    -- Rule 1: teardown freeze (A17.2 latch, same gate captureLocation uses).
    if Tracker.IsTeardown() then return end

    local level = rec.level or (UnitLevel and UnitLevel("player")) or 0
    if level >= 60 then
        -- A max-level character earns no XP: the zeros are honest data.
        rec.xp, rec.xpMax, rec.restedXP = 0, 0, 0
        return
    end
    -- No API at all (headless / a stripped client): freeze, do not invent zeros.
    if not (UnitXP and UnitXPMax) then return end

    -- Rule 2: a sub-60 xpMax of 0 is a cold read, not "no XP". Freeze the trio.
    local xpMax = UnitXPMax("player") or 0
    if xpMax <= 0 then return end

    rec.xp       = UnitXP("player") or 0
    rec.xpMax    = xpMax
    rec.restedXP = (GetXPExhaustion and GetXPExhaustion()) or 0
end

-- Resting / PvP / instance flags.
local function captureFlags(rec)
    rec.isResting = IsResting() and true or false

    local pvp = UnitIsPVP("player") or UnitIsPVPFreeForAll("player")
    rec.pvpFlagged = pvp and true or false
    -- WoW does not expose the flag's drop time directly; the mesh layer
    -- fills pvpExpiry from PLAYER_FLAGS_CHANGED timing in a later wave.
    if not rec.pvpFlagged then rec.pvpExpiry = 0 end

    local inInstance = IsInInstance()
    rec.inInstance = inInstance and true or false
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

-- SHARED SEMANTIC (see HUD._RendOverrideHit, which matches the same stored
-- rules): an override rule's `zone` is a SCOPE, and an absent scope means
-- "anywhere". A rule is unscoped when zone is nil, empty, or whitespace-only;
-- otherwise it must equal the current real zone.
--
-- This used to read `(not o.zone or o.zone == zone)`, which is a live bug for
-- the zone="" shape both producers emit: `not ""` is false in Lua and "" never
-- equals a real zone name, so EVERY unscoped rule was dead here while the HUD
-- happily matched it — the two matchers disagreed about identical stored data.
-- Producers now normalize "" to nil (import.lua), but the lenient read stays:
-- SavedVariables written by older builds still carry "", and the options
-- "Add Location" path stores "" for a rule the user left unscoped.
--
-- Pure and non-string-safe by design: a corrupt `zone` of any non-string type
-- is treated as scoped-and-non-matching rather than erroring on the ticker.
function Tracker._OverrideZoneMatches(oz, zone)
    if oz == nil then return true end
    if type(oz) ~= "string" then return false end
    if oz:match("^%s*$") ~= nil then return true end
    return oz == zone
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
        if Tracker._OverrideZoneMatches(o.zone, zone)
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
--
-- `inSession` — WHY THIS PARAMETER EXISTS (the Wyx-Whitemane data-integrity bug).
--
-- A6.1's synthetic duration means "THIS SESSION watched the slot go live but the
-- aura API will not tell us how long is left". It was applied to any carried
-- slot with duration <= 0, which silently also caught a completely different
-- thing: a zero-duration slot LOADED FROM THE SAVED STORE, where zero means the
-- character does not hold the buff at all.
--
-- The SuperNova import (import.lua `mapAuraStates`) materialises ALL TEN slots
-- for every imported character as `{ duration = 0, option = 1, source = 0 }` —
-- source 0 is AURA_SOURCE.LIVE. So every imported record carried ten slots that
-- read as "live, duration unreadable". The first capture after login is ALWAYS
-- partial (PLAYER_ENTERING_WORLD is inside ENTERING_WORLD_GRACE), partial calls
-- preserveSlots, and all ten placeholders detonated into a full world-buff set:
-- 7200s on every slot and 3600s on Rend. A level-16 alt logged in for 28 seconds
-- came back out holding 10/10 world buffs at 1h59m. No other character's data
-- was involved — the record fabricated the buffs out of its own zero placeholders.
--
-- The discriminator is `Tracker._auraCapturedAt`: nil until THIS session's first
-- aura write, so a zero on the very first capture provably came off disk and is
-- "not held", never "live but unreadable". Once the session has written slots
-- itself, a zero really can be the unreadable-duration case A6.1 is about, and
-- the synthetic duration applies exactly as before.
local function preserveSlots(prev, elapsed, into, inSession)
    if type(prev) ~= "table" then return into end
    for slot, cell in pairs(prev) do
        if type(cell) == "table" and into[slot] == nil then
            local src = cell.source or 0
            local dur = tonumber(cell.duration) or 0
            if src ~= BOON_SOURCE then
                if dur <= 0 then
                    -- Known live this session with an unreadable duration -> synth.
                    -- Straight off disk -> the character simply does not hold it.
                    dur = inSession and synthDuration(slot) or 0
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
    -- Has THIS session written aura slots yet? Gates A6.1's synthetic duration —
    -- see the preserveSlots header for why a zero off disk must not synthesize.
    local inSession = (Tracker._auraCapturedAt ~= nil)

    if Tracker.IsTeardown() then
        rec.auraStates = preserveSlots(prev, elapsed, {}, inSession)
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
        preserveSlots(prev, elapsed, slots, inSession)
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
        -- BOONABLE_SLOT-gated and >0-gated: the last line of defence for the
        -- record itself. Even if some cache path upstream ever hands us a
        -- slots[9] again, it stops here rather than becoming a "Battle Shout
        -- (Boon)" card row; and a presence-only entry (duration 0, see
        -- ParseBoonBlock rule 2) is not injected, because a frozen "0s (Boon)"
        -- tells the owner strictly less than showing nothing at all.
        local parsed = Tracker._boonParsed
        local injected = 0
        if parsed then
            for slot, cell in pairs(parsed.slots) do
                local dur = tonumber(cell.duration) or 0
                if BOONABLE_SLOT[slot] and not slots[slot] and dur > 0 then
                    slots[slot] = { duration = dur,
                                    option = cell.option or 0, source = BOON_SOURCE }
                    injected = injected + 1
                end
            end
            if parsed.dmf then dmfInBoon = true end
        end

        -- EVIDENCE PRESERVATION, SECOND LAYER (see the precedence table above the
        -- tooltip scan). The first layer stops a cold tooltip read from emptying
        -- the boon cache; this one stops an ALREADY-empty cache from emptying the
        -- RECORD, whatever emptied it — a login before the cache rehydrates, a
        -- peer-relayed snapshot, a future path nobody has written yet.
        --
        -- THE PHYSICS IT LEANS ON: the chronoboon is all-or-nothing. While the
        -- Chronoboon Displacement AURA is on the character the stored buffs are
        -- inside it, frozen, and there is no game action that removes one of them
        -- and leaves the aura up. So "the aura is present and the previous record
        -- held boon-stored slots" is proof those slots are still stored, and an
        -- injection that contributed NOTHING is proof only that we have lost our
        -- own copy of the manifest.
        --
        -- NARROW ON PURPOSE: it fires only when the injection produced ZERO boon
        -- slots. Any read that resolved even one slot is real evidence, and the
        -- A7.5 phantom rule stays fully in force for it — a tooltip that lists
        -- three of four booned buffs still drops the fourth.
        if injected == 0 and type(prev) == "table" then
            local carried = 0
            for slot, cell in pairs(prev) do
                if BOONABLE_SLOT[slot] and type(cell) == "table"
                   and (cell.source or 0) == BOON_SOURCE
                   and (tonumber(cell.duration) or 0) > 0
                   and slots[slot] == nil then
                    slots[slot] = { duration = math.floor(cell.duration),
                                    option = cell.option or 0, source = BOON_SOURCE }
                    carried = carried + 1
                    if slot == SLOT_DMF then dmfInBoon = true end
                end
            end
            if carried > 0 then
                Tracker._boonReadsPreserved = (Tracker._boonReadsPreserved or 0) + 1
                -- Re-seed the cache from the record so the NEXT capture, the
                -- dashboard's "(Boon)" rows and a relog all agree again. Marked
                -- stale: preserved evidence, not a fresh observation.
                local reseed = { slots = {}, dmf = false, count = 0, stale = true }
                for slot, cell in pairs(slots) do
                    if (cell.source or 0) == BOON_SOURCE then
                        reseed.slots[slot] = { duration = cell.duration,
                                               option = cell.option or 0 }
                        reseed.count = reseed.count + 1
                        if slot == SLOT_DMF then reseed.dmf = true end
                    end
                end
                Tracker._boonParsed       = reseed
                Tracker._boonTooltipCount = reseed.count
                persistBoonCache(rec.nameRealm or selfNameRealm(), reseed)
            end
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

local function captureDMFEdges(rec)
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

-- J4 / schema v3: publish the cooldown to the WIRE MIRROR.
--
-- The edges above own rec.dmfCooldown.remainingOnlineSecs, which is the engine's
-- truth and is NOT something the binary STATE payload can carry (decode rebuilds
-- rec.dmfCooldown as `{ offlineSince = u32 }` and nothing else). rec
-- .dmfCooldownRemaining is the flat u32 the v3 tail DOES carry, and this is its
-- ONE writer — the same relationship Store.RefreshItemCdMirrors has with the
-- hearth/chrono epochs.
--
-- WHY IT IS WRITTEN HERE AND NOT AT SEND TIME. The value is only meaningful
-- paired with the stamp a reader will decay it against, and that stamp is
-- rec.lastDataUpdate, which this same capture pass re-writes. Deriving it again
-- in Mesh.WireRecord would re-read the identical field one capture later and
-- change nothing: unlike the item cooldowns (wall-clock, so they keep running
-- between captures) the DMF cooldown only advances when DMFCooldownTick is
-- called — i.e. exactly here.
--
-- WHY IT WRAPS RATHER THAN APPENDING TO THE BODY. captureDMFEdges returns early
-- on three paths (teardown, the debuff-bar push clear, a store too old to have
-- the A8 model). Every one of those CHANGES the cooldown, so every one must be
-- published — and a wrapper cannot forget a fourth one added later.
-- Store.DMFCooldownRemaining returns 0 when the cooldown is not active, so a
-- clear publishes 0, which is the "nothing to report" the tail already means.
local function captureDMF(rec)
    captureDMFEdges(rec)
    local Store = ns.Store
    rec.dmfCooldownRemaining =
        (Store and Store.DMFCooldownRemaining and Store.DMFCooldownRemaining(rec)) or 0
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
--   MC    Attunement to the Core          — FACTION-SPLIT: two quest ids share
--                                           this ONE name, one per faction, both
--                                           handed in to the same neutral NPC.
--                                           See the LIVE BUG note below.
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
--   7487  Attunement to the Core       (one faction) https://www.wowhead.com/classic/quest=7487
--   7848  Attunement to the Core      (the other)   https://www.wowhead.com/classic/quest=7848
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
--
-- LIVE BUG, 2026-08-02 — "MC shows grey on characters I know are attuned".
-- MC shipped with ONE quest id (7487) and was therefore the only gated raid
-- whose faction split was missed. Ony's split was handled; MC's identical split
-- was not, because both ids carry the SAME quest NAME ("Attunement to the
-- Core") and the same neutral quest giver, so nothing about the quest looks
-- faction-scoped from the outside — exactly the Naxx trap (one name, several
-- ids) wearing a different hat.
--
-- The owner's SavedVariables proved it rather than suggesting it: across three
-- accounts, MC read FALSE for every single character and `MC = true` did not
-- appear anywhere, while three of those same level-60 records carried
-- BWL/Ony/Naxx = TRUE. A matrix holding three TRUEs is proof the probe that
-- wrote it was WARM, so MC's false in that same matrix cannot be a cold-cache
-- artifact — it is a quest id the probe never asked about.
--
-- The union below is direction-agnostic ON PURPOSE. The secondary databases
-- disagree with the live client about which id belongs to which faction
-- (classicdb and a TrinityCore issue both map 7487->Horde / 7848->Alliance, yet
-- the owner's affected characters are all Horde), and this project has already
-- been bitten once by a reversed faction pair. Since no character can ever hold
-- both ids, asking about BOTH is correct under either mapping and cannot
-- produce a false positive — so the union is the fix, and the faction mapping
-- is deliberately NOT relied upon anywhere in the code.
----------------------------------------------------------------------

-- PURE: raidKey -> the quest ids that grant it. ANY ONE complete = attuned.
local ATTUNE_QUESTS = {
    MC   = { 7487, 7848 },              -- one per faction, SAME quest name
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

----------------------------------------------------------------------
-- WARMTH: when is a FALSE answer trustworthy?
--
-- C_QuestLog.IsQuestFlaggedCompleted does not report "I don't know yet". Before
-- the server's completed-quest data lands it answers a flat FALSE, which is
-- indistinguishable from an honest "never completed". The old code only guarded
-- the case where the API function was MISSING, which is not the case that
-- happens: the function is always there at PLAYER_ENTERING_WORLD, it just lies
-- for a moment. A probe taken in that window published an all-false matrix that
-- greyed every gated raid on every peer's screen until the next re-probe.
--
-- A false is therefore believed only when one of these holds:
--   * the SAME probe returned at least one gated TRUE. A true answer can only
--     come from loaded data, so it proves the cache is warm, and every false
--     beside it is honest. This covers every attuned character instantly.
--   * OR the character has been in-world at least ATTUNE_WARM_DELAY seconds AND
--     ATTUNE_AGREE_COUNT consecutive probes have all come back all-false. This
--     is the only path for a character attuned to NOTHING (a fresh alt), which
--     is a legitimate state that must eventually grey — it just has to earn it.
--
-- Until a false is trusted the matrix is treated as UNKNOWN: nothing is written
-- to the record and nothing is published, so the character reads nil on every
-- screen and renders ATTUNED. Greying a raid the owner can actually enter is
-- the loud, confusing failure; failing to grey one for another minute is not.
----------------------------------------------------------------------
Tracker.ATTUNE_WARM_DELAY  = 30         -- seconds in-world before a false counts
Tracker.ATTUNE_AGREE_COUNT = 2          -- consecutive all-false probes required
Tracker._attuneAllFalseRuns = 0         -- consecutive all-false probes so far

-- PURE: fold one all-false probe into the agreement counter.
-- Returns trusted(bool), runs(number). Explicit state in, explicit state out —
-- no clock and no globals, so the harness can drive it directly.
function Tracker.TrustAllFalse(prevRuns, onlineSecs)
    local runs = (tonumber(prevRuns) or 0) + 1
    local secs = tonumber(onlineSecs) or 0
    local trusted = secs >= Tracker.ATTUNE_WARM_DELAY
                and runs >= Tracker.ATTUNE_AGREE_COUNT
    return trusted, runs
end

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
--
-- SECOND RETURN — anyTrue: did any GATED raid probe true? The always-attuned
-- raids (ZG/AQ20/AQ40) are true by construction and deliberately do not count.
-- This is the warmth proof described above: a true can only come from loaded
-- data, so it licenses the caller to believe the falses sitting beside it.
function Tracker.AttunementFlags(probe)
    if type(probe) ~= "function" then return nil end
    local out, answered, anyTrue = {}, false, false
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
            if val then anyTrue = true end
        end
    end
    if not answered then return nil end
    return out, anyTrue
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
--
-- COPIED, never aliased. Publishing rec.attunements directly would hand the
-- namespace a LIVE reference into the character record: any later mutation of
-- the published payload would silently rewrite the stored matrix (and vice
-- versa), across a boundary where neither side can see the other. Today that
-- happens to be harmless only because CaptureAttunements routes through
-- MergeAttunements, which returns the FRESH table it was handed rather than
-- mutating the stored one — an accident of the current call path, not a
-- contract. One in-place merge anywhere downstream and a payload edit becomes
-- a store corruption. The matrix is flat by construction (Store.RAID_KEYS ->
-- boolean, or nil for UNKNOWN), so a one-level copy is a full copy.
function Tracker.AttunePayload()
    local out = {}
    local S = ns.Store
    local bucket = S and S.GetSelfAccount and S.GetSelfAccount(false)
    if not bucket then return out end
    for _, tbl in ipairs({ bucket.characters, bucket.homeless }) do
        if type(tbl) == "table" then
            for nameRealm, rec in pairs(tbl) do
                if type(rec) == "table" and type(rec.attunements) == "table" then
                    local flags = {}
                    for k, v in pairs(rec.attunements) do flags[k] = v end
                    out[nameRealm] = flags
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
--
-- TWO SOURCES, FOLDED WITH OR — the record's own matrix and the cross-account
-- namespace projection. TRUE from EITHER wins; false is returned only when a
-- source says false and none says true; nil when neither has an opinion.
--
-- This used to be a precedence rule (record first, namespace only as a
-- fallback), which had a permanent-staleness hole. Store.NON_WIRE_CARRY carries
-- `attunements` forward across every binary state push, so once a peer record
-- picked up a matrix over the segment path it kept it FOREVER — the binary wire
-- never refreshes it. A record holding a false from before the owner fixed
-- their attunement therefore outranked, and permanently suppressed, the fresh
-- TRUE arriving through the namespace: the self-heal reached the client and
-- then lost to a cached lie.
--
-- OR removes the hole by construction and needs no ordering, no timestamps and
-- no rev comparison between two transports that do not share a clock, because
-- attunement is MONOTONIC — it only ever goes false->true, so the attuned
-- answer is always the newer and the truer one no matter which pipe it came
-- down. It is also exactly the fold AttuneIndex already applies ACROSS peer
-- accounts, so both layers now obey one rule instead of two.
----------------------------------------------------------------------

if ns.Store then
    function ns.Store.RaidAttuned(rec, raidKey)
        if type(raidKey) ~= "string" then return nil end
        -- Ungated raids answer true unconditionally — even for a nil record.
        if ATTUNE_ALWAYS[raidKey] then return true end
        if not ATTUNE_QUESTS[raidKey] then return nil end   -- not a tracked raid
        if type(rec) ~= "table" then return nil end

        -- LEVEL IMPOSSIBILITY OUTRANKS BOTH SOURCES (the other half of the
        -- Wyx-Whitemane report: his raid row read attuned/green for MC, BWL,
        -- AQ40 and Naxx at level 16).
        --
        -- The nil = "treat as attuned" default above is deliberate and stays: it
        -- is what stops a mid-rollout mesh greying every character a peer on an
        -- older build cannot describe yet. But it was answering for characters
        -- who CANNOT be attuned at all, and "no data" is not the same as "no
        -- data and the answer is knowable anyway". Every gated chain here ends
        -- well above level 50 (see Store.SanitizeInboundRecord for the evidence
        -- and the gate), so a known level below it is positive proof of NOT
        -- attuned — an answer, not a default.
        --
        -- Deliberately BELOW the ATTUNE_ALWAYS check: ZG / AQ20 / AQ40 need no
        -- attunement and stay true at any level. Deliberately ABOVE the two data
        -- sources: a stored true for an impossible level is the corruption this
        -- batch exists to kill, so impossibility beats even a monotonic true.
        -- An unknown level (0 / nil) is not evidence and falls through.
        local level = tonumber(rec.level) or 0
        local minLevel = (ns.Store.ATTUNE_MIN_LEVEL) or 50
        if level > 0 and level < minLevel then return false end

        -- nil until some source has an opinion; a single TRUE short-circuits.
        local answer = nil

        local a = rec.attunements
        if type(a) == "table" and a[raidKey] ~= nil then
            if a[raidKey] then return true end
            answer = false
        end

        -- Cross-account source: the "attune" namespace projection.
        local nameRealm = rec.nameRealm
        if type(nameRealm) == "string" and nameRealm ~= "" then
            local flags = Tracker.AttuneIndex()[nameRealm]
            if type(flags) == "table" and flags[raidKey] ~= nil then
                if flags[raidKey] then return true end
                answer = false
            end
        end

        return answer
    end
end

----------------------------------------------------------------------
-- ONE-SHOT CLEANUP of the falses written by the single-id MC probe.
--
-- Every MC = false already sitting in a record or a published payload was
-- produced by a probe that only ever asked about ONE of the two MC quest ids,
-- so it is not evidence of anything — the character may well be attuned via the
-- id we never asked about. Those falses are demoted to nil (UNKNOWN), which
-- renders as attuned, and the next warm probe answers for real.
--
-- Only MC, and only false: TRUE is never touched (attunement is monotonic, and
-- a stored true is the one thing here that was always trustworthy), and the
-- other three raids always probed every id they have. Setting nil rather than
-- deleting a record honours store.lua's no-destructive-migrations rule.
--
-- Characters we own and re-log heal on their own within a minute; this pass
-- exists for the ones that will NOT log in again soon — without it a parked alt
-- keeps a wrong grey indefinitely, since nothing re-probes a character that
-- never comes online. Peers heal separately and need no migration: their copy
-- lives in the namespace, which a newer rev replaces wholesale.
--
-- Idempotent via a marker key, in the same style as Store.data.itemCdEpochsMigrated.
-- Returns the number of records touched.
----------------------------------------------------------------------
Tracker.ATTUNE_MC_MIGRATION_KEY = "attuneMCFactionMigrated"

-- PURE given its argument: demote every MC=false in ONE account bucket to nil.
-- Mutates the records it touches; returns how many.
function Tracker._MigrateMCFalsesIn(bucket)
    if type(bucket) ~= "table" then return 0 end
    local touched = 0
    for _, tbl in ipairs({ bucket.characters, bucket.homeless }) do
        if type(tbl) == "table" then
            for _, rec in pairs(tbl) do
                if type(rec) == "table" and type(rec.attunements) == "table"
                   and rec.attunements.MC == false then
                    rec.attunements.MC = nil
                    touched = touched + 1
                end
            end
        end
    end
    return touched
end

function Tracker.MigrateMCFalses()
    local S = ns.Store
    local data = S and S.data
    if type(data) ~= "table" then return 0 end
    if data[Tracker.ATTUNE_MC_MIGRATION_KEY] then return 0 end

    local touched = Tracker._MigrateMCFalsesIn(
        S.GetSelfAccount and S.GetSelfAccount(false))

    data[Tracker.ATTUNE_MC_MIGRATION_KEY] = true
    if touched > 0 then
        Tracker.InvalidateAttuneIndex()
        markAttuneDirty()               -- republish: rev bump, peers re-pull
    end
    return touched
end

----------------------------------------------------------------------
-- ONE-SHOT REPAIR of the records the synthetic-duration bug already wrote.
--
-- Layer (b) of the Wyx-Whitemane fix. preserveSlots can no longer fabricate a
-- world buff out of an imported zero placeholder, but it did so for weeks, and
-- nothing re-probes a character that never logs in again. Without this pass a
-- parked level-16 keeps "10/10 HELD" forever.
--
-- THREE RULES, each with its own evidence. All CLEAR fields (to nil = unknown);
-- none deletes a record, per store.lua's no-destructive-migrations rule.
--
-- R1 — THE FABRICATED AURA BLOCK. Fingerprint: eight or more slots present, and
--   EVERY present slot has source == LIVE and option == 1. That pair cannot
--   occur naturally. Live capture writes `option = 0` unconditionally (see
--   captureAuras), boon-sourced slots carry source == BOON, and mesh-relayed
--   slots carry source == RELAYED — so option == 1 on a LIVE slot only ever
--   comes from import.lua's `mapAuraStates`, whose default for an absent slot is
--   exactly `{ duration = 0, option = 1, source = 0 }`. Matching blocks are the
--   import placeholder skeleton, either still at zero (a live landmine waiting
--   for its character's next login) or already detonated into the full 7200s /
--   3600s set. Both are cleared: the character re-captures the truth the next
--   time it logs in, and the landmine is gone.
--
--   This rule is what actually heals Wyx. R2/R3 below are the level-impossibility
--   layers, and on their own they would only clear three of his ten buffs.
--
-- R2 — DIRE MAUL TRIBUTE slots (6/7/8) on a record whose known level is below
--   Store.DMT_MIN_LEVEL. Same evidence as the inbound guard.
--
-- R3 — GATED ATTUNEMENTS (MC/BWL/Ony/Naxx) claimed true by a record whose known
--   level is below Store.ATTUNE_MIN_LEVEL. Demoted to nil (UNKNOWN), never to
--   false — attunement is monotonic and an unproven false is its own bug (see
--   the MC cleanup above). Applied to the character records AND to the "attune"
--   namespace payloads, which are a second, independent source RaidAttuned ORs
--   in; healing only the record would leave the namespace copy to win.
--
-- A level of 0 / nil is UNKNOWN and is never judged, exactly as in the inbound
-- guard. Idempotent via a marker key, in the style of Tracker.MigrateMCFalses.
----------------------------------------------------------------------
Tracker.AURA_REPAIR_KEY = "impossibleRecordsRepaired"

-- PURE: is ONE slot import-born? source == LIVE with option == 1 is a pair the
-- live capture path cannot produce (it writes option 0 unconditionally), so it
-- only ever comes from import.lua's `mapAuraStates` default. See R1 above.
local function isImportBornSlot(cell)
    return type(cell) == "table"
       and (tonumber(cell.source) or 0) == 0
       and (tonumber(cell.option) or 0) == 1
end

-- PURE: how many slots in this block carry the import fingerprint.
function Tracker._FabricatedSlotCount(states)
    if type(states) ~= "table" then return 0 end
    local n = 0
    for _, cell in pairs(states) do
        if isImportBornSlot(cell) then n = n + 1 end
    end
    return n
end

-- PURE: does this block hold a whole import placeholder skeleton? The threshold
-- is what keeps the rule conservative — we clear a WHOLESALE fabricated set, not
-- an individual odd-looking slot, so a record that merely happens to carry one
-- import-born slot alongside real captures is left alone.
--
-- The clearing itself is PER SLOT, not whole-block: a character can hold a
-- genuine live buff (option 0) captured after the skeleton was written, and that
-- one must survive. Ceporah-Whitemane in the owner's store is exactly this shape
-- — nine fabricated slots plus one real capture — and a whole-block rule either
-- spared all ten or destroyed the real one.
Tracker.FABRICATED_BLOCK_MIN = 8

function Tracker._IsFabricatedAuraBlock(states)
    return Tracker._FabricatedSlotCount(states) >= Tracker.FABRICATED_BLOCK_MIN
end

-- PURE: strip the import-born slots from a block that qualifies. Returns how
-- many slots were removed (0 when the block does not meet the threshold).
function Tracker._StripFabricatedSlots(states)
    if not Tracker._IsFabricatedAuraBlock(states) then return 0 end
    local removed = 0
    for slot, cell in pairs(states) do
        if isImportBornSlot(cell) then
            states[slot] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- PURE given its arguments: repair ONE account bucket. Mutates the records it
-- touches and accumulates into `counts`; returns the number of records changed.
function Tracker._RepairImpossibleIn(bucket, counts)
    if type(bucket) ~= "table" then return 0 end
    counts = counts or {}
    local S = ns.Store
    local attuneMin = (S and S.ATTUNE_MIN_LEVEL) or 50
    local dmtMin    = (S and S.DMT_MIN_LEVEL) or 45
    local gated     = (S and S.ATTUNE_GATED_RAIDS) or { MC = true, BWL = true, Ony = true, Naxx = true }
    local dmtSlots  = (S and S.DMT_AURA_SLOTS) or { [6] = true, [7] = true, [8] = true }

    local touched = 0
    for _, tbl in ipairs({ bucket.characters, bucket.homeless }) do
        if type(tbl) == "table" then
            for _, rec in pairs(tbl) do
                if type(rec) == "table" then
                    local hit = false
                    local level = tonumber(rec.level) or 0

                    -- R1: the fabricated / placeholder aura slots.
                    local stripped = Tracker._StripFabricatedSlots(rec.auraStates)
                    if stripped > 0 then
                        counts.auraBlocks = (counts.auraBlocks or 0) + 1
                        counts.auraSlots  = (counts.auraSlots or 0) + stripped
                        hit = true
                    end

                    -- R2: Dire Maul Tribute buffs below the dungeon's level.
                    if level > 0 and level < dmtMin and type(rec.auraStates) == "table" then
                        for slot in pairs(dmtSlots) do
                            local cell = rec.auraStates[slot]
                            if type(cell) == "table" and (tonumber(cell.duration) or 0) > 0 then
                                rec.auraStates[slot] = nil
                                counts.dmt = (counts.dmt or 0) + 1
                                hit = true
                            end
                        end
                    end

                    -- R3: gated attunements below any possible chain completion.
                    if level > 0 and level < attuneMin and type(rec.attunements) == "table" then
                        for key in pairs(gated) do
                            if rec.attunements[key] == true then
                                rec.attunements[key] = nil
                                counts.attune = (counts.attune or 0) + 1
                                hit = true
                            end
                        end
                    end

                    if hit then touched = touched + 1 end
                end
            end
        end
    end
    return touched
end

-- PURE given its arguments: demote impossible gated trues inside the "attune"
-- namespace payloads. `levelOf(nameRealm)` returns a known level or nil/0.
-- Returns the number of flags demoted.
function Tracker._RepairAttuneNamespace(nsTbl, levelOf)
    if type(nsTbl) ~= "table" or type(levelOf) ~= "function" then return 0 end
    local S = ns.Store
    local attuneMin = (S and S.ATTUNE_MIN_LEVEL) or 50
    local gated     = (S and S.ATTUNE_GATED_RAIDS) or { MC = true, BWL = true, Ony = true, Naxx = true }

    local demoted = 0
    for _, entry in pairs(nsTbl) do
        local data = type(entry) == "table" and entry.data
        if type(data) == "table" then
            for nameRealm, flags in pairs(data) do
                local level = tonumber(levelOf(nameRealm)) or 0
                if type(flags) == "table" and level > 0 and level < attuneMin then
                    for key in pairs(gated) do
                        if flags[key] == true then
                            flags[key] = nil
                            demoted = demoted + 1
                        end
                    end
                end
            end
        end
    end
    return demoted
end

----------------------------------------------------------------------
-- R4 — THE IMPOSSIBLE BOON SLOT (its own one-shot pass, its own marker).
--
-- Every record written while ParseBoonBlock walked all ten slots can be carrying
-- an auraStates[9] (or [10]) with source == BOON: the "Battle Shout (Boon)" card
-- row. Nothing re-probes those records — a peer's copy of a character that never
-- logs in again keeps the row forever — so it needs the same one-shot sweep the
-- fabricated blocks got.
--
-- WHY A SEPARATE MARKER, not a fourth rule inside RepairImpossibleRecords: that
-- pass's marker (`impossibleRecordsRepaired`) is ALREADY true in every store that
-- has run the mesh-bleed build. Adding a rule under the same key would ship a
-- repair that never runs for exactly the people who need it. The new key means
-- one extra pass on the first login after this build, and never again.
--
-- The rule needs no level evidence and no threshold: source == BOON on a
-- non-boonable slot is impossible outright (see Store.NON_BOONABLE_AURA_SLOTS).
-- Only the boon-sourced cell goes; a LIVE or RELAYED Battle Shout is a perfectly
-- ordinary buff and is never touched.
--
-- The persisted tooltip caches are swept too: `caches.tooltipBoon[nameRealm]`
-- is a second, independent source that captureAuras re-injects from, so healing
-- only the records would let the cache write the row straight back.
----------------------------------------------------------------------
Tracker.BOON_SCOPE_REPAIR_KEY = "nonBoonableBoonSlotsRepaired"

-- PURE: strip boon-sourced cells from non-boonable slots. Returns the count.
function Tracker._StripNonBoonableBoonSlots(states)
    if type(states) ~= "table" then return 0 end
    local removed = 0
    for slot, cell in pairs(states) do
        if not BOONABLE_SLOT[slot] and type(cell) == "table"
           and (tonumber(cell.source) or 0) == BOON_SOURCE then
            states[slot] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- PURE given its arguments: sweep ONE account bucket. Returns records changed,
-- accumulating the slot total into counts.boonSlots.
function Tracker._RepairBoonScopeIn(bucket, counts)
    if type(bucket) ~= "table" then return 0 end
    counts = counts or {}
    local touched = 0
    for _, tbl in ipairs({ bucket.characters, bucket.homeless }) do
        if type(tbl) == "table" then
            for _, rec in pairs(tbl) do
                if type(rec) == "table" then
                    local n = Tracker._StripNonBoonableBoonSlots(rec.auraStates)
                    if n > 0 then
                        counts.boonSlots = (counts.boonSlots or 0) + n
                        touched = touched + 1
                    end
                end
            end
        end
    end
    return touched
end

-- PURE given its argument: sweep the persisted tooltip-boon caches. Returns the
-- number of cache entries changed; also corrects each entry's stored count.
function Tracker._RepairBoonCaches(tooltipBoon)
    if type(tooltipBoon) ~= "table" then return 0 end
    local touched = 0
    for _, entry in pairs(tooltipBoon) do
        if type(entry) == "table" and type(entry.slots) == "table" then
            local dropped = Tracker.ScrubNonBoonableSlots(entry.slots)
            if dropped > 0 then
                entry.count = math.max(0, (tonumber(entry.count) or 0) - dropped)
                touched = touched + 1
            end
        end
    end
    return touched
end

-- The one-shot runner for R4. Returns the number of records changed.
function Tracker.RepairNonBoonableBoonSlots()
    local S = ns.Store
    local data = S and S.data
    if type(data) ~= "table" then return 0 end
    if data[Tracker.BOON_SCOPE_REPAIR_KEY] then return 0 end

    local counts = {}
    local touched = 0
    if type(data.accounts) == "table" then
        for _, bucket in pairs(data.accounts) do
            touched = touched + Tracker._RepairBoonScopeIn(bucket, counts)
        end
    end
    local caches = Tracker._RepairBoonCaches(data.caches and data.caches.tooltipBoon)

    data[Tracker.BOON_SCOPE_REPAIR_KEY] = true

    if touched > 0 or caches > 0 then
        if ns and ns.Print then
            ns:Print(string.format(
                "|cffffc020removed %d impossible stored-buff slot(s)|r from %d character "
                .. "record(s) and %d saved boon snapshot(s) "
                .. "(Battle Shout / Fire Festival Fury cannot go into a chronoboon)",
                counts.boonSlots or 0, touched, caches))
        end
    end
    return touched
end

-- The one-shot runner. Sweeps EVERY account bucket, not just our own: the
-- placeholder skeletons ride the mesh, so a peer bucket holds the same landmines,
-- and a peer whose owner has not patched yet would otherwise re-detonate into a
-- copy we keep. A peer record cleared here simply re-fills from that peer's next
-- push. Returns the number of records changed.
function Tracker.RepairImpossibleRecords()
    local S = ns.Store
    local data = S and S.data
    if type(data) ~= "table" then return 0 end
    if data[Tracker.AURA_REPAIR_KEY] then return 0 end

    local counts = {}
    local touched = 0

    -- Level index across every bucket, for the namespace pass below.
    local levels = {}
    if type(data.accounts) == "table" then
        for _, bucket in pairs(data.accounts) do
            if type(bucket) == "table" then
                for _, tbl in ipairs({ bucket.characters, bucket.homeless }) do
                    if type(tbl) == "table" then
                        for nameRealm, rec in pairs(tbl) do
                            local lv = type(rec) == "table" and tonumber(rec.level) or nil
                            if lv and lv > (levels[nameRealm] or 0) then levels[nameRealm] = lv end
                        end
                    end
                end
            end
        end
        for _, bucket in pairs(data.accounts) do
            touched = touched + Tracker._RepairImpossibleIn(bucket, counts)
        end
    end

    local nsAttune = 0
    if type(data.syncNamespaces) == "table" then
        nsAttune = Tracker._RepairAttuneNamespace(
            data.syncNamespaces[ATTUNE_NS], function(n) return levels[n] end)
    end
    counts.nsAttune = nsAttune

    data[Tracker.AURA_REPAIR_KEY] = true

    if touched > 0 or nsAttune > 0 then
        Tracker.InvalidateAttuneIndex()
        if (counts.attune or 0) > 0 or nsAttune > 0 then
            markAttuneDirty()          -- republish: rev bump, peers re-pull
        end
        if ns and ns.Print then
            ns:Print(string.format(
                "|cffffc020repaired %d character record(s) with impossible data|r "
                .. "(%d fabricated buff set(s), %d Dire Maul buff(s), %d attunement flag(s))",
                touched, counts.auraBlocks or 0, counts.dmt or 0,
                (counts.attune or 0) + nsAttune))
        end
    end
    return touched
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
    local fresh, anyTrue = Tracker.AttunementFlags(questCompleted)
    if not fresh then return false end          -- API missing: keep what we had
    Tracker._attuneCheckedAt = now

    -- WARMTH GATE. An all-false probe is UNKNOWN until it earns belief; see the
    -- ATTUNE_WARM_DELAY block above. Returning early here writes nothing and
    -- publishes nothing, so the character reads nil (= attuned) meanwhile.
    if anyTrue then
        Tracker._attuneAllFalseRuns = 0         -- a true proves the cache is warm
    else
        local trusted, runs = Tracker.TrustAllFalse(
            Tracker._attuneAllFalseRuns, Tracker.SinceEnteringWorld())
        Tracker._attuneAllFalseRuns = runs
        if not trusted then return false end
    end

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
        -- right after login, so the FIRST honest read is often this one — and
        -- being cold again is exactly why the all-false agreement counter has to
        -- reset here. Carrying it across a loading screen would let one stale
        -- pre-screen probe pair up with one cold post-screen probe and "agree"
        -- their way to a trusted all-false.
        Tracker._attuneForce = true
        Tracker._attuneAllFalseRuns = 0
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
    Tracker._attuneAllFalseRuns = 0
    -- One-shot: demote the MC falses the single-id probe left behind (no-op
    -- after the first run, and on a fresh install).
    if ns.SafeCall then ns:SafeCall(Tracker.MigrateMCFalses) else Tracker.MigrateMCFalses() end
    -- One-shot: scrub the buff sets the synthetic-duration bug fabricated, the
    -- import placeholder skeletons that fabricate them, and any level-impossible
    -- attunement. No-op after the first run, and on a fresh install.
    if ns.SafeCall then
        ns:SafeCall(Tracker.RepairImpossibleRecords)
    else
        Tracker.RepairImpossibleRecords()
    end
    -- One-shot (own marker, see R4): strip the boon-stored Battle Shout / Fire
    -- Festival Fury slots the all-ten tooltip parse used to write, from the
    -- records AND from the saved boon snapshots.
    if ns.SafeCall then
        ns:SafeCall(Tracker.RepairNonBoonableBoonSlots)
    else
        Tracker.RepairNonBoonableBoonSlots()
    end
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

----------------------------------------------------------------------
-- Diagnostic: /nexus debug sanity
--
-- Reads the inbound sanity guard's counters (layer (a) of the Wyx-Whitemane
-- fix) plus the repair pass's marker. A non-zero record count means a peer on
-- the mesh is still handing us level-impossible claims — i.e. that account has
-- not picked up the fix yet, and the guard is doing its job.
----------------------------------------------------------------------
function Tracker.DebugSanity()
    local S = ns.Store
    local c = S and S._inboundSanity
    if type(c) ~= "table" then
        ns:Print("debug sanity: the inbound guard is not loaded")
        return
    end
    ns:Print(string.format(
        "inbound sanity guard: %d record(s) stripped -- %d attunement flag(s), %d aura slot(s), "
        .. "%d impossible boon slot(s)",
        c.records or 0, c.attune or 0, c.auras or 0, c.boon or 0))
    ns:Print(string.format("  gates: attunement < %d, Dire Maul buffs < %d",
        S.ATTUNE_MIN_LEVEL or 0, S.DMT_MIN_LEVEL or 0))
    ns:Print(string.format("  nameless inbound dropped: %d",
        S._droppedNamelessInbound or 0))
    -- Own-account authority: inbound copies of OUR OWN characters, refused at
    -- the arbitration boundary regardless of epoch. A non-zero count is normal
    -- and healthy on a multi-account mesh — it is the relay traffic this
    -- account is correctly declining to believe about itself.
    local oa = S._ownAuthority
    if type(oa) == "table" then
        local worst, worstN = nil, 0
        for nr, n in pairs(oa.names or {}) do
            if n > worstN then worst, worstN = nr, n end
        end
        ns:Print(string.format(
            "  own-account authority: %d inbound record(s) about OUR characters dropped%s",
            oa.drops or 0,
            worst and string.format(" (most: %s x%d)", worst, worstN) or ""))
    end
    ns:Print(string.format("  tooltip lines naming an unboonable buff, ignored: %d",
        Tracker._boonScopeRejects or 0))
    -- The evidence-preservation rule. "refused" counts empty reads that were NOT
    -- allowed to delete stored slots (of which "cold item data" is the sub-count
    -- that was provably a cold tooltip); "honoured" counts the empty reads that
    -- really did mean the boon is gone or empty. A non-zero refusal count is the
    -- wipe being caught, not a fault.
    ns:Print(string.format(
        "  boon empty-reads refused: %d (cold item data: %d) / honoured: %d",
        Tracker._boonReadsPreserved or 0, Tracker._boonReadsCold or 0,
        Tracker._boonReadsCleared or 0))
    local bp = Tracker._boonParsed
    if bp then
        ns:Print(string.format("  boon snapshot: %d slot(s), dmf=%s%s",
            Tracker._boonSlotCount(bp), tostring(bp.dmf and true or false),
            bp.stale and " |cffffc020(PRESERVED — not refreshed by the last read)|r" or ""))
    end
    local done = S.data and S.data[Tracker.AURA_REPAIR_KEY]
    ns:Print("  one-shot impossible-record repair: " .. (done and "already run" or "PENDING"))
    local boonDone = S.data and S.data[Tracker.BOON_SCOPE_REPAIR_KEY]
    ns:Print("  one-shot unboonable-slot repair: " .. (boonDone and "already run" or "PENDING"))
end

if ns.RegisterDebugCommand then
    ns:RegisterDebugCommand("auras", function() Tracker.DebugAuras() end)
    ns:RegisterDebugCommand("sanity", function() Tracker.DebugSanity() end)
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

----------------------------------------------------------------------
-- BOON SCOPE (the "Battle Shout (Boon)" card row) + the residual duration leak.
--
-- Two defects, one parser:
--
--  1. ParseBoonBlock walked all ten BUFF_SLOTS while every other writer of
--     source = BOON walked BOONABLE_SLOT. The spec's tracked-set table marks
--     slot 9 (Battle Shout, 25101) and slot 10 (Fire Festival Fury) "Not
--     boonable", so a tooltip that merely CONTAINED the words wrote slots[9] and
--     the dashboard rendered a state the game cannot produce.
--
--  2. The duration search ran from the buff's name to the END OF THE BLOCK, so a
--     name with no parenthetical of its own adopted the NEXT buff's minutes —
--     the surviving half of the original "Fengus' 119m landed on Rallying Cry"
--     symptom. Reproduced below from the parse header's own description.
----------------------------------------------------------------------
local function testBoonScope(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- ---- 1) the unboonable slots are never boon-marked -------------------
    local WITH_BS =
        "World effects suspended:\n" ..
        "Rallying Cry of the Dragonslayer (115m)\n" ..
        "Battle Shout (14m)\n" ..
        "Fengus' Ferocity (119m)\n" ..
        "Fire Festival Fury (30m)\n" ..
        "Sayge's Dark Fortune (119m)"

    local savedRejects = Tracker._boonScopeRejects
    Tracker._boonScopeRejects = 0
    local slots, dmf = Tracker.ParseBoonBlock(WITH_BS)

    ck(slots[9] == nil, "BS: a Battle Shout tooltip line is NOT boon-marked (slot 9)")
    ck(slots[10] == nil, "FFF: a Fire Festival Fury line is NOT boon-marked (slot 10)")
    ck(Tracker._boonScopeRejects == 2, "BS/FFF: both rejections hit the debug counter")
    -- ...and the boonable slots around them parse exactly as before.
    ck(slots[1] and slots[1].duration == 115 * 60, "BS fixture: slot 1 still 115m")
    ck(slots[6] and slots[6].duration == 119 * 60, "BS fixture: slot 6 still 119m")
    ck(slots[5] and slots[5].duration == 119 * 60, "BS fixture: slot 5 (DMF) still 119m")
    ck(dmf == true, "BS fixture: DMF still flagged")
    local n = 0; for _ in pairs(slots) do n = n + 1 end
    ck(n == 3, "BS fixture: exactly the three BOONABLE slots resolve (got " .. n .. ")")
    Tracker._boonScopeRejects = savedRejects

    -- A block that is ONLY a Battle Shout yields nothing at all.
    local only = Tracker.ParseBoonBlock("World effects suspended:\nBattle Shout (110m)")
    ck(next(only) == nil, "BS alone: an unboonable-only block parses to no slots")

    -- Every slot the parser can emit is boonable, whatever the input.
    for slot in pairs(Tracker.ParseBoonBlock(WITH_BS)) do
        ck(BOONABLE_SLOT[slot] == true,
           "parser emitted non-boonable slot " .. tostring(slot))
    end

    -- ---- 2) the Fengus duration leak -------------------------------------
    -- The parse header's own description: a buff named with no parenthetical of
    -- its own, immediately followed by Fengus' 119m.
    local LEAK =
        "World effects suspended:\n" ..
        "Rallying Cry of the Dragonslayer\n" ..
        "Fengus' Ferocity (119m)\n" ..
        "Mol'dar's Moxie (120m)"
    local ls = Tracker.ParseBoonBlock(LEAK)
    ck(ls[1] and ls[1].duration == 0,
       "leak: a name with no duration of its own reads 0, not the next buff's")
    ck(not (ls[1] and ls[1].duration == 119 * 60),
       "leak: Fengus' 119m must NOT land on Rallying Cry")
    ck(ls[6] and ls[6].duration == 119 * 60, "leak: Fengus keeps its own 119m")
    ck(ls[7] and ls[7].duration == 120 * 60, "leak: Mol'dar keeps its own 120m")

    -- Same-line separation (no newlines at all) must clamp on the NEXT NAME.
    local ONELINE = "suspended: Rallying Cry of the Dragonslayer Fengus' Ferocity (119m)"
    local os_ = Tracker.ParseBoonBlock(ONELINE)
    ck(os_[1] and os_[1].duration == 0,
       "leak: with no newline the clamp is the next buff NAME")
    ck(os_[6] and os_[6].duration == 119 * 60, "leak: one-line Fengus still 119m")

    -- ---- 3) presence-without-duration is not a reconcile correction ------
    -- A 0 from the tooltip means "listed, minutes unreadable". Correcting a good
    -- cached duration down to it would be the leak wearing a different hat.
    local cached = { slots = { [1] = { duration = 6900, option = 3 } }, dmf = false, count = 1 }
    local out = Tracker.ReconcileBoonSnapshot(
        { slots = { [1] = { duration = 0 } }, dmf = false, count = 1 }, cached)
    ck(out.slots[1] and out.slots[1].duration == 6900,
       "reconcile: a presence-only (0s) tooltip reading keeps the cached duration")
    ck(out.slots[1].option == 3, "reconcile: presence-only keeps the variant too")

    -- ---- 4) the stored-buff COUNT agrees with the boonable set -----------
    -- STORED_BUFF_NAMES feeds Tracker.BoonedBuffCount. Battle Shout and FFF used
    -- to be in it and inflated the count by up to two.
    for j = 1, #STORED_BUFF_NAMES do
        local nm = STORED_BUFF_NAMES[j]
        local slot = Tracker.MatchBuffSlot(nm)
        -- Either it maps to a boonable dashboard slot, or it is one of the two
        -- chronoboon-only extras that have no slot at all.
        ck(slot == nil or BOONABLE_SLOT[slot] == true,
           "stored-buff name '" .. nm .. "' maps to a NON-boonable slot")
    end
    local function has(list, needle)
        for j = 1, #list do if list[j] == needle then return true end end
        return false
    end
    ck(not has(STORED_BUFF_NAMES, "battle shout"), "count: Battle Shout is not a stored buff")
    ck(not has(STORED_BUFF_NAMES, FFF_AURA_PREFIX), "count: FFF is not a stored buff")
    ck(has(STORED_BUFF_NAMES, "boon of blackfathom"),
       "count: the slotless chronoboon extras are still counted")

    -- ---- 5) the local mirror and the canonical set agree ------------------
    if ns.Store and ns.Store.BOONABLE_AURA_SLOTS then
        for slot in pairs(ns.Store.BOONABLE_AURA_SLOTS) do
            ck(BOONABLE_SLOT[slot] == true, "mirror: Store says " .. slot .. " is boonable")
        end
        for slot in pairs(BOONABLE_SLOT) do
            ck(ns.Store.BOONABLE_AURA_SLOTS[slot] == true,
               "mirror: tracker says " .. slot .. " is boonable")
        end
        for slot in pairs(ns.Store.NON_BOONABLE_AURA_SLOTS) do
            ck(BOONABLE_SLOT[slot] == nil, "mirror: " .. slot .. " must NOT be boonable")
        end
    end

    -- ---- 6) the record-side writers refuse a non-boonable slot ------------
    -- Injection: a poisoned cache (a pre-fix disk snapshot) cannot reach the record.
    local savedParsed = Tracker._boonParsed
    Tracker._boonParsed = { slots = { [1] = { duration = 3000 },
                                      [9] = { duration = 800 } }, dmf = false, count = 2 }
    local injected = {}
    for slot, cell in pairs(Tracker._boonParsed.slots) do
        local dur = tonumber(cell.duration) or 0
        if BOONABLE_SLOT[slot] and dur > 0 then injected[slot] = dur end
    end
    ck(injected[1] == 3000 and injected[9] == nil,
       "injection guard: only boonable slots reach the record")
    Tracker._boonParsed = savedParsed

    -- The disk-cache scrubber.
    local dirty = { [1] = { duration = 3000 }, [9] = { duration = 800 },
                    [10] = { duration = 100 } }
    ck(Tracker.ScrubNonBoonableSlots(dirty) == 2, "scrub: both impossible slots removed")
    ck(dirty[1] ~= nil and dirty[9] == nil and dirty[10] == nil,
       "scrub: the boonable slot survives")
    ck(Tracker.ScrubNonBoonableSlots(nil) == 0, "scrub: nil is a no-op")
end

----------------------------------------------------------------------
-- TOOLTIP SCRAPE COVERAGE (spec §4.4: "every left/right tooltip line plus every
-- font-string region").
--
-- The scrape read GameTooltipTextLeft1..NumLines and nothing else. Two whole
-- renderings were therefore unreadable:
--
--   1. name on the LEFT FontString, duration on the RIGHT one. We saw the buff
--      and lost its minutes — presence without a number.
--   2. the suspended-effects block in an UNNAMED font-string region, which the
--      TextLeft/TextRight enumeration never mentions. We saw nothing at all.
--
-- Widening the scrape re-opens a question the narrow one could not raise: the
-- numbered FontStrings ARE regions, so the sweep must not read them twice, and
-- a duplicated buff name must never let the POORER reading win — ParseBoonBlock
-- takes a slot's first occurrence, so a bare name collected ahead of the copy
-- carrying the duration would pin the slot to 0. Both halves of the dedupe are
-- asserted below, and the fixtures assert the EXACT collected block, which is
-- what makes a broken dedupe visible at all (a stray duplicate carries no buff
-- name, so it changes the text without changing any slot).
--
-- Nothing global is stomped: CollectBoonTooltipText takes the tooltip and the
-- _G lookup as arguments, and these fixtures pass fakes.
----------------------------------------------------------------------

-- Build a fake tooltip. `rows` is an array of { leftText, rightText } (either
-- may be nil/omitted); `extras` an array of strings rendered as ANONYMOUS
-- font-string regions; `junk` an array of ready-made non-FontString regions.
-- GetRegions returns the line FontStrings (in reading order) followed by the
-- extras, exactly as a real tooltip enumerates its own children.
local function fakeBoonTooltip(rows, extras, junk)
    local named, regions = {}, {}
    local function fontString(text)
        return {
            GetText       = function() return text end,
            GetObjectType = function() return "FontString" end,
        }
    end
    for i = 1, #rows do
        local row = rows[i]
        if row[1] then
            local fs = fontString(row[1])
            named["GameTooltipTextLeft" .. i] = fs
            regions[#regions + 1] = fs
        end
        if row[2] then
            local fs = fontString(row[2])
            named["GameTooltipTextRight" .. i] = fs
            regions[#regions + 1] = fs
        end
    end
    for i = 1, #(extras or {}) do regions[#regions + 1] = fontString(extras[i]) end
    for i = 1, #(junk or {})   do regions[#regions + 1] = junk[i] end
    local tip = {
        NumLines   = function() return #rows end,
        GetRegions = function() return unpack(regions) end,
    }
    return tip, function(name) return named[name] end
end

local function testBoonScrapeCoverage(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function collect(rows, extras, junk)
        local tip, lookup = fakeBoonTooltip(rows, extras, junk)
        return Tracker.CollectBoonTooltipText(tip, lookup)
    end
    local function parse(block) return Tracker.ParseBoonBlock(normName(block)) end
    local function occurrences(hay, needle)
        local n, at = 0, 1
        while true do
            local s = normName(hay):find(needle, at, true)
            if not s then return n end
            n, at = n + 1, s + 1
        end
    end

    -- ---- 1) the duration lives on the RIGHT FontString --------------------
    local RIGHT_ROWS = {
        { "Chronoboon Displacement" },
        { "World effects suspended:" },
        { "Rallying Cry of the Dragonslayer", "(115m)" },
        { "Fengus' Ferocity", "(119m)" },
    }
    local block = collect(RIGHT_ROWS)
    ck(block == "Chronoboon Displacement\nWorld effects suspended:\n" ..
                "Rallying Cry of the Dragonslayer (115m)\nFengus' Ferocity (119m)",
       "right column: each line's two halves join as one 'Name (duration)' line")
    ck(occurrences(block, "(115m)") == 1, "right column: no line is collected twice")
    local slots = parse(block)
    ck(slots[1] and slots[1].duration == 115 * 60,
       "right column: slot 1 reads the RIGHT FontString's 115m, not presence-only")
    ck(slots[6] and slots[6].duration == 119 * 60, "right column: slot 6 reads 119m")

    -- The same tooltip with the right column removed is the pre-fix reading:
    -- the names are found, the minutes are not. This is both the regression
    -- guard for the left-only path and the proof that the right column is what
    -- supplies the durations above.
    local LEFT_ONLY = { { "Chronoboon Displacement" }, { "World effects suspended:" },
                        { "Rallying Cry of the Dragonslayer" }, { "Fengus' Ferocity" } }
    local lo = parse(collect(LEFT_ONLY))
    ck(lo[1] and lo[1].duration == 0, "left-only: a name with no duration still reads 0")
    ck(lo[6] and lo[6].duration == 0, "left-only: presence-only degradation preserved")

    -- ---- 2) a stored buff rendered ONLY in an anonymous region -------------
    local REGION_ROWS = { { "Chronoboon Displacement" }, { "World effects suspended:" } }
    local rblock = collect(REGION_ROWS,
        { "Songflower Serenade (59m)\nSpirit of Zandalar (114m)" })
    local rs = parse(rblock)
    ck(rs[4] and rs[4].duration == 59 * 60,
       "region: a buff present only in an unnamed region resolves (slot 4, 59m)")
    ck(rs[3] and rs[3].duration == 114 * 60, "region: and its neighbour (slot 3, 114m)")

    -- ---- 3) dedupe: a region that repeats a line --------------------------
    -- (a) EXACT repeat -> dropped, once and only once in the block.
    local dupBlock = collect({ { "Chronoboon Displacement" }, { "Mol'dar's Moxie (120m)" } },
                             { "Mol'dar's Moxie (120m)" })
    ck(dupBlock == "Chronoboon Displacement\nMol'dar's Moxie (120m)",
       "dedupe: an exact region repeat of a line is dropped")
    ck(occurrences(dupBlock, "mol'dar's moxie") == 1, "dedupe: the name appears once")
    local ds = parse(dupBlock)
    ck(ds[7] and ds[7].duration == 120 * 60, "dedupe: the duration survives the drop")

    -- (b) the region EXTENDS a bare-name line -> it replaces it, so the HIGHER
    --     duration wins. First-occurrence parsing would otherwise pin slot 2 to
    --     0 from the bare line and throw the region's 60m away.
    local hiBlock = collect({ { "Chronoboon Displacement" }, { "Warchief's Blessing" } },
                            { "Warchief's Blessing (60m)" })
    ck(hiBlock == "Chronoboon Displacement\nWarchief's Blessing (60m)",
       "dedupe: the richer rendering replaces the bare name, it does not follow it")
    ck(occurrences(hiBlock, "warchief's blessing") == 1, "dedupe: still one occurrence")
    local hs = parse(hiBlock)
    ck(hs[2] and hs[2].duration == 60 * 60,
       "dedupe: the highest duration wins per slot (60m, not the bare line's 0)")

    -- (c) the region is POORER than what we hold -> ignored, no downgrade.
    local poor = parse(collect({ { "Chronoboon Displacement" },
                                 { "Spirit of Zandalar (114m)" } },
                               { "Spirit of Zandalar" }))
    ck(poor[3] and poor[3].duration == 114 * 60,
       "dedupe: a bare-name region never downgrades a line that has the minutes")

    -- ---- 4) the owner's 7-line fixture, left-only, unchanged ---------------
    local OWNER = { { "Chronoboon Displacement" }, { "World effects suspended:" },
                    { "Fengus' Ferocity (119m)" }, { "Mol'dar's Moxie (120m)" },
                    { "Rallying Cry of the Dragonslayer (115m)" },
                    { "Warchief's Blessing (60m)" }, { "Spirit of Zandalar (114m)" },
                    { "Songflower Serenade (59m)" }, { "Sayge's Dark Fortune (119m)" } }
    local os_ = parse(collect(OWNER))
    local n = 0; for _ in pairs(os_) do n = n + 1 end
    ck(n == 7, "regression: the owner 7-line tooltip still resolves 7 slots (got " .. n .. ")")
    ck(os_[1] and os_[1].duration == 115 * 60, "regression: slot 1 still 115m")
    ck(os_[5] and os_[5].duration == 119 * 60, "regression: slot 5 still 119m")
    ck(os_[7] and os_[7].duration == 120 * 60, "regression: slot 7 still 120m")

    -- ---- 5) defensive: the shapes a real tooltip hands us on a bad frame ---
    local TEXTURE = { GetObjectType = function() return "Texture" end }
    local NO_TEXT = { GetObjectType = function() return "FontString" end }  -- no GetText
    local messy = collect({ { "Chronoboon Displacement" },
                            { nil, "(115m)" },               -- right with no left
                            { "" },                          -- empty left
                            { "Songflower Serenade", "" },   -- empty right
                          }, { "" }, { TEXTURE, NO_TEXT, "not a widget", 7 })
    ck(messy == "Chronoboon Displacement\n(115m)\nSongflower Serenade",
       "defensive: nil/empty FontStrings and non-FontString regions are skipped")

    local empty = Tracker.CollectBoonTooltipText(
        { NumLines = function() return 0 end }, function() return nil end)
    ck(empty == "", "defensive: a zero-line tooltip collects nothing")
    ck(Tracker.CollectBoonTooltipText({}, function() return nil end) == "",
       "defensive: a tooltip with no NumLines collects nothing")
    -- A tooltip with no GetRegions at all (an older client) still reads lines.
    local noRegions = Tracker.CollectBoonTooltipText(
        { NumLines = function() return 1 end },
        function(name)
            if name == "GameTooltipTextLeft1" then
                return { GetText = function() return "Chronoboon Displacement" end }
            end
        end)
    ck(noRegions == "Chronoboon Displacement",
       "defensive: a client without GetRegions still reads the numbered lines")
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

----------------------------------------------------------------------
-- THE EVIDENCE-PRESERVATION RULE — the boon WIPE suite.
--
-- Owner symptom: a fully booned 60 intermittently renders with every world-buff
-- tile empty, and hovering the chronoboon brings them back. The SavedVariables
-- showed the self record with chronoboonActive = true, boonCount = 4 and
-- auraStates = {}, while the peers' older copies still held all seven booned
-- slots — a WIPE written by our own capture, not lost in transit.
--
-- What this suite pins, in the order the precedence table states it:
--   * a COLD tooltip read (title only, item data not cached) PRESERVES;
--   * a read with the boon item genuinely GONE from bags AND bank CLEARS;
--   * a WARM, complete, genuinely empty tooltip with the item still in bags
--     CLEARS (the post-release state — the boon really is empty now);
--   * the capture that follows a preserved read still writes the stored slots
--     into the record, so the PUBLISH path can never ship a degraded read as an
--     authoritative empty;
--   * MUTATION TESTS: each guard is individually disabled and the suite proves
--     the wipe comes straight back. A preservation rule that cannot fail is a
--     preservation rule nobody is testing.
----------------------------------------------------------------------
local function testBoonEvidencePreservation(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local C = Tracker.ClassifyBoonRead
    local ADOPT, CLEAR, PRESERVE =
        Tracker.BOON_READ_ADOPT, Tracker.BOON_READ_CLEAR, Tracker.BOON_READ_PRESERVE

    -- ---- 1) the precedence table, row by row, on the PURE classifier -------
    -- Row 1: any positive evidence adopts, whatever else is true.
    ck(C({ parsedSlots = 1, cachedSlots = 5, itemPresent = false, itemKnown = true,
           dataCached = false, hasBody = false }) == ADOPT,
       "row 1: a read that resolved a slot is EVIDENCE and is adopted")
    -- Row 2: nothing cached, nothing to protect.
    ck(C({ parsedSlots = 0, cachedSlots = 0, itemPresent = true, itemKnown = true,
           dataCached = false }) == CLEAR,
       "row 2: an empty read with an empty cache is a no-op CLEAR")
    -- Row 3: the item is provably gone -> the empty read agrees with the bags.
    ck(C({ parsedSlots = 0, cachedSlots = 7, itemPresent = false, itemKnown = true,
           dataCached = true, hasBody = true }) == CLEAR,
       "row 3: boon item gone from bags AND bank -> CLEAR")
    ck(C({ parsedSlots = 0, cachedSlots = 7, itemPresent = false, itemKnown = true,
           dataCached = nil, hasBody = false }) == CLEAR,
       "row 3 beats rows 4-6: a gone item needs no tooltip warmth to be believed")
    -- Row 4: cold item data -> the read is not evidence of anything.
    ck(C({ parsedSlots = 0, cachedSlots = 7, itemPresent = true, itemKnown = true,
           dataCached = false, hasBody = true }) == PRESERVE,
       "row 4: COLD item data -> PRESERVE (the bug that bit the owner)")
    -- Row 5: no warmth proof available at all.
    ck(C({ parsedSlots = 0, cachedSlots = 7, itemPresent = true, itemKnown = true,
           dataCached = nil, hasBody = true }) == PRESERVE,
       "row 5: a client with no IsItemDataCachedByID cannot delete data")
    ck(C({ parsedSlots = 0, cachedSlots = 7, itemPresent = false, itemKnown = false,
           dataCached = true, hasBody = true }) == PRESERVE,
       "row 5: an unreadable bag API is not proof the item is gone")
    -- Row 6: warm by the item cache, but the tooltip plainly did not render.
    ck(C({ parsedSlots = 0, cachedSlots = 7, itemPresent = true, itemKnown = true,
           dataCached = true, hasBody = false }) == PRESERVE,
       "row 6: a title-only tooltip is partial by inspection -> PRESERVE")
    -- Row 7: the genuine post-release empty.
    ck(C({ parsedSlots = 0, cachedSlots = 7, itemPresent = true, itemKnown = true,
           dataCached = true, hasBody = true }) == CLEAR,
       "row 7: warm + present + rendered + empty is a real CLEAR")
    -- Degenerate input never throws and never deletes.
    ck(C(nil) == CLEAR, "a nil context has nothing cached, so it CLEARs harmlessly")
    ck(C({ cachedSlots = 3 }) == PRESERVE,
       "an all-unknown context with a live cache PRESERVEs")

    -- ---- 2) the LIVE scan against fake tooltips ---------------------------
    local saved = {
        tip      = _G.GameTooltip,
        left1    = _G.GameTooltipTextLeft1,
        item     = _G.C_Item,
        getTime  = _G.GetTime,
        unitName = _G.UnitName,
        realm    = _G.GetRealmName,
        parsed   = Tracker._boonParsed,
        count    = Tracker._boonTooltipCount,
        seen     = Tracker._boonTooltipSeen,
        entered  = Tracker._enteredWorldAt,
        leaving  = Tracker._leavingWorld,
        logout   = Tracker._loggingOut,
        auraAt   = Tracker._auraCapturedAt,
        requests = Tracker.RequestCapture,
        auras    = _G.C_UnitAuras,
        now      = ns.Store and ns.Store.Now,
    }
    local FRAME, EPOCH = 50000, 1700000000
    _G.GetTime = function() return FRAME end
    ns.Store.Now = function() return EPOCH end
    _G.UnitName = function() return "Poonyx" end
    _G.GetRealmName = function() return "Whitemane" end
    Tracker._leavingWorld, Tracker._loggingOut = false, false
    Tracker._enteredWorldAt = FRAME - 600         -- long past every grace window

    local captures = 0
    Tracker.RequestCapture = function() captures = captures + 1 end

    -- Item probe knobs.
    local itemCount, itemWarm, hasCachedAPI, loadRequests = 1, true, true, 0
    _G.C_Item = {
        GetItemCount = function() return itemCount end,
        IsItemDataCachedByID = function()
            if not hasCachedAPI then return nil end
            return itemWarm
        end,
        RequestLoadItemDataByID = function() loadRequests = loadRequests + 1 end,
    }
    -- The class-only build: no IsItemDataCachedByID at all.
    local function dropCachedAPI()
        hasCachedAPI = false
        _G.C_Item.IsItemDataCachedByID = nil
    end
    local function restoreCachedAPI()
        hasCachedAPI = true
        _G.C_Item.IsItemDataCachedByID = function() return itemWarm end
    end

    -- Install a fake tooltip into the globals the scan actually reads.
    local installed = {}
    local function installTooltip(rows)
        for name in pairs(installed) do _G[name] = nil end
        installed = {}
        local tip, lookup = fakeBoonTooltip(rows)
        _G.GameTooltip = tip
        for i = 1, #rows do
            for _, side in ipairs({ "Left", "Right" }) do
                local name = "GameTooltipText" .. side .. i
                local fs = lookup(name)
                if fs then _G[name] = fs; installed[name] = true end
            end
        end
    end

    local FULL_ROWS = {
        { "Chronoboon Displacement" },
        { "World effects suspended:" },
        { "Rallying Cry of the Dragonslayer", "(115m)" },
        { "Fengus' Ferocity", "(119m)" },
    }
    -- The COLD render: the title line landed, the body never did.
    local COLD_ROWS = { { "Chronoboon Displacement" } }
    -- The WARM EMPTY render: a complete tooltip that lists nothing (post-release).
    local EMPTY_ROWS = {
        { "Chronoboon Displacement" },
        { "No world effects are suspended." },
    }

    local function seedCache()
        Tracker._boonParsed = { slots = { [1] = { duration = 6900 },
                                          [6] = { duration = 7140 } },
                                dmf = false, count = 2 }
        Tracker._boonTooltipCount = 2
    end
    local function slotsHeld()
        return Tracker._boonSlotCount(Tracker._boonParsed)
    end

    local ok, err = pcall(function()

    -- (a) COLD TOOLTIP -> the stored slots survive.
    seedCache()
    itemCount, itemWarm = 1, false
    loadRequests, captures = 0, 0
    installTooltip(COLD_ROWS)
    Tracker._scanTooltipForStoredBuffs()
    ck(slotsHeld() == 2, "cold tooltip: both stored slots PRESERVED")
    ck(Tracker._boonParsed.slots[1].duration == 6900,
       "cold tooltip: the preserved duration is kept verbatim")
    ck(Tracker._boonParsed.stale == true,
       "cold tooltip: the snapshot is flagged un-refreshed, not fresh")
    ck(loadRequests > 0, "cold tooltip: the item data is requested for the next read")
    ck(captures == 0, "cold tooltip: no capture is fired (nothing changed)")

    -- (b) BOON ITEM GONE -> the read is believed and the slots clear.
    seedCache()
    itemCount, itemWarm = 0, true
    captures = 0
    installTooltip(COLD_ROWS)
    Tracker._scanTooltipForStoredBuffs()
    ck(slotsHeld() == 0, "item gone: an empty read legitimately CLEARS")
    ck(captures == 1, "item gone: the clear is captured and published")

    -- (c) WARM, COMPLETE, GENUINELY EMPTY -> clears.
    seedCache()
    itemCount, itemWarm = 1, true
    captures = 0
    installTooltip(EMPTY_ROWS)
    Tracker._scanTooltipForStoredBuffs()
    ck(slotsHeld() == 0, "warm empty tooltip: the post-release state CLEARS")
    ck(captures == 1, "warm empty tooltip: the clear is captured")

    -- (d) A REAL READ still adopts, and the A7.5 phantom rule still bites.
    Tracker._boonParsed = { slots = { [1] = { duration = 6900 },
                                      [4] = { duration = 900 } }, dmf = false, count = 2 }
    itemCount, itemWarm = 1, true
    installTooltip(FULL_ROWS)
    Tracker._scanTooltipForStoredBuffs()
    ck(Tracker._boonParsed.slots[1] ~= nil and Tracker._boonParsed.slots[6] ~= nil,
       "real read: the listed slots are adopted")
    ck(Tracker._boonParsed.slots[4] == nil,
       "real read: the phantom rule still drops a slot the tooltip does not list")
    ck(Tracker._boonParsed.stale == nil,
       "real read: a fresh snapshot is NOT flagged stale")

    -- (e) NO IsItemDataCachedByID (belt and braces) -> preserve.
    seedCache()
    dropCachedAPI()
    itemCount = 1
    installTooltip(COLD_ROWS)
    Tracker._scanTooltipForStoredBuffs()
    ck(slotsHeld() == 2, "no warmth API: an empty read cannot delete the cache")
    restoreCachedAPI()

    -- (f) THE RECORD SIDE — the capture that follows a preserved read.
    -- captureAuras sees the chronoboon aura plus nothing else: exactly the live
    -- reading a fully booned character produces. The record must come out
    -- holding the booned slots, because that is what the mesh publishes.
    local auraList = { { name = "Chronoboon Displacement", spellId = 349858,
                         expirationTime = 0 } }
    _G.C_UnitAuras = { GetBuffDataByIndex = function(_, i) return auraList[i] end }
    seedCache()
    Tracker._auraCapturedAt = EPOCH
    local rec = { nameRealm = "Poonyx-Whitemane",
                  auraStates = { [1] = { duration = 6900, option = 0, source = 2 },
                                 [6] = { duration = 7140, option = 0, source = 2 } },
                  chronoboonActive = true, boonCount = 4 }
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].source == 2,
       "publish: a preserved read still writes slot 1 as BOONED into the record")
    ck(rec.auraStates[6] and rec.auraStates[6].duration == 7140,
       "publish: the booned duration is frozen, not decayed")
    ck(rec.chronoboonActive == true, "publish: the record still reads as booned")

    -- ...and the SECOND layer: even with the cache emptied by some other path,
    -- the record's own booned slots survive a capture. This is the guard that
    -- makes an authoritative-empty publish unreachable.
    Tracker._boonParsed = nil
    Tracker._boonTooltipCount = 0
    Tracker._auraCapturedAt = EPOCH
    rec = { nameRealm = "Poonyx-Whitemane",
            auraStates = { [1] = { duration = 6900, option = 0, source = 2 },
                           [5] = { duration = 7140, option = 0, source = 2 },
                           [6] = { duration = 7140, option = 0, source = 2 } },
            chronoboonActive = true, boonCount = 4, dmfInBoon = true }
    Tracker._captureAuras(rec)
    local kept = 0
    for _, cell in pairs(rec.auraStates) do
        if (cell.source or 0) == 2 then kept = kept + 1 end
    end
    ck(kept == 3, "publish: an empty CACHE cannot empty a booned RECORD")
    ck(rec.dmfInBoon == true, "publish: the booned fortune survives with its slot")
    ck(Tracker._boonSlotCount(Tracker._boonParsed) == 3,
       "publish: the cache is re-seeded from the record it just rescued")
    ck(Tracker._boonParsed.stale == true,
       "publish: the re-seeded cache is marked preserved evidence, not observed")

    -- A LIVE world buff still wins over the preserved boon copy (an unboon that
    -- landed between captures must not be shadowed by frozen state).
    auraList = { { name = "Chronoboon Displacement", spellId = 349858, expirationTime = 0 },
                 { name = "Rallying Cry of the Dragonslayer", spellId = 22888,
                   expirationTime = FRAME + 1234 } }
    Tracker._boonParsed = nil
    Tracker._auraCapturedAt = EPOCH
    rec = { nameRealm = "Poonyx-Whitemane",
            auraStates = { [1] = { duration = 6900, option = 0, source = 2 } },
            chronoboonActive = true }
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].source == 0,
       "publish: a LIVE reading of a slot beats the preserved booned copy")

    -- ---- 3) MUTATION TESTS -----------------------------------------------
    -- Disable each guard in turn and prove the wipe returns. If any of these
    -- stops failing, the guard it names has become decorative.
    auraList = { { name = "Chronoboon Displacement", spellId = 349858, expirationTime = 0 } }
    local realClassify = Tracker.ClassifyBoonRead

    -- Mutant 1: the classifier always trusts an empty read (the OLD behaviour).
    Tracker.ClassifyBoonRead = function() return CLEAR end
    seedCache()
    itemCount, itemWarm = 1, false
    installTooltip(COLD_ROWS)
    Tracker._scanTooltipForStoredBuffs()
    ck(slotsHeld() == 0,
       "MUTANT 1: with the classifier defeated the cold read wipes the cache " ..
       "(this is the shipped bug; if it does not wipe, the test is not reaching it)")
    Tracker.ClassifyBoonRead = realClassify

    -- Mutant 2: the classifier always preserves -> the genuine post-release
    -- empty can never clear. Proves rows 3 and 7 are load-bearing, not padding.
    Tracker.ClassifyBoonRead = function() return PRESERVE end
    seedCache()
    itemCount, itemWarm = 0, true
    installTooltip(EMPTY_ROWS)
    Tracker._scanTooltipForStoredBuffs()
    ck(slotsHeld() == 2,
       "MUTANT 2: a blanket-preserve classifier cannot clear a released boon")
    Tracker.ClassifyBoonRead = realClassify
    -- ...and the real classifier does clear it, in the same fixture.
    seedCache()
    Tracker._scanTooltipForStoredBuffs()
    ck(slotsHeld() == 0, "MUTANT 2 control: the real rule DOES clear a released boon")

    -- Mutant 3: defeat the record-side layer by claiming the character is not
    -- booned. The booned slots must then legitimately go (this is the unboon
    -- path, and it has to keep working).
    Tracker._boonParsed = nil
    Tracker._auraCapturedAt = EPOCH
    auraList = { { name = "Ordinary Food Buff", spellId = 1, expirationTime = FRAME + 60 } }
    rec = { nameRealm = "Poonyx-Whitemane",
            auraStates = { [1] = { duration = 6900, option = 0, source = 2 } },
            chronoboonActive = true }
    Tracker._captureAuras(rec)
    ck(rec.chronoboonActive == false and rec.auraStates[1] == nil,
       "MUTANT 3: with the chronoboon aura GONE the booned slots clear as before")

    end)

    -- ---- restore ----------------------------------------------------------
    for name in pairs(installed) do _G[name] = nil end
    _G.GameTooltip            = saved.tip
    _G.GameTooltipTextLeft1   = saved.left1
    _G.C_Item                 = saved.item
    _G.GetTime                = saved.getTime
    _G.UnitName               = saved.unitName
    _G.GetRealmName           = saved.realm
    _G.C_UnitAuras            = saved.auras
    ns.Store.Now              = saved.now
    Tracker.RequestCapture    = saved.requests
    Tracker._boonParsed       = saved.parsed
    Tracker._boonTooltipCount = saved.count
    Tracker._boonTooltipSeen  = saved.seen
    Tracker._enteredWorldAt   = saved.entered
    Tracker._leavingWorld     = saved.leaving
    Tracker._loggingOut       = saved.logout
    Tracker._auraCapturedAt   = saved.auraAt
    if not ok then fails[#fails + 1] = "evidence preservation :: " .. tostring(err) end
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

    -- ---- REGRESSION: the Wyx-Whitemane fabricated world-buff set -----------
    -- A record loaded FROM DISK carrying import.lua's ten zero-duration
    -- placeholder slots, on a character that holds nothing. The first capture of
    -- a session is always partial (login sits inside ENTERING_WORLD_GRACE), and
    -- partial calls preserveSlots. Before the fix every placeholder detonated
    -- into a full world buff and a level-16 alt came out holding 10/10 at 1h59m.
    -- The discriminator is that _auraCapturedAt is nil: nothing has been written
    -- this session, so these zeros provably came off disk and mean "not held".
    local function importSlot() return { duration = 0, option = 1, source = 0 } end
    settle()                                     -- settle() sets _auraCapturedAt = nil
    rec = { auraStates = {} }
    for s = 1, 10 do rec.auraStates[s] = importSlot() end
    Tracker._enteredWorldAt = frameNow           -- inside the grace => partial
    setAuras()                                   -- a buffless level 16
    Tracker._captureAuras(rec)
    local fabricated = 0
    for _, cell in pairs(rec.auraStates) do
        if (tonumber(cell.duration) or 0) > 0 then fabricated = fabricated + 1 end
    end
    ck(fabricated == 0,
       "import placeholders off disk do NOT synthesize into world buffs (Wyx bug)")
    ck(rec.auraStates[SLOT_REND] == nil,
       "off-disk zero on Rend is dropped, not turned into 3600s")

    -- The SAME zeros, once the session has written slots itself, are the genuine
    -- A6.1 case (live but unreadable) and MUST still synthesize. This is the
    -- mutation guard: a fix that simply deleted synthDuration passes the case
    -- above and fails this one.
    settle()
    rec = { auraStates = { [SLOT_REND] = liveSlot(0), [1] = liveSlot(0) } }
    Tracker._auraCapturedAt = epochNow           -- this session HAS written slots
    Tracker._enteredWorldAt = frameNow           -- partial, not teardown
    setAuras()
    Tracker._captureAuras(rec)
    ck(rec.auraStates[SLOT_REND] and rec.auraStates[SLOT_REND].duration == 3600,
       "in-session zero on Rend still synthesizes 3600s (A6.1 preserved)")
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 7200,
       "in-session zero still synthesizes 7200s (A6.1 preserved)")

    -- A REAL buff carried off disk is untouched by the gate — only zeros were
    -- ever ambiguous, and a positive duration is evidence in its own right.
    settle()
    rec = { auraStates = { [1] = liveSlot(3000), [4] = importSlot() } }
    Tracker._enteredWorldAt = frameNow
    setAuras()
    Tracker._captureAuras(rec)
    ck(rec.auraStates[1] and rec.auraStates[1].duration == 3000,
       "off-disk slot with a real duration is preserved unchanged")
    ck(rec.auraStates[4] == nil,
       "off-disk placeholder alongside a real buff is still dropped")

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

----------------------------------------------------------------------
-- XP / RESTED CAPTURE — the fields the instance log's Rest view reads, and the
-- LOGOUT WIPE that emptied them (owner: "XP and REST show — for every character").
--
-- Driven end to end through the real Tracker.Capture, not captureXP in isolation:
-- the defect was never in the arithmetic, it was that the session's FINAL capture
-- — fired synchronously and forced by PLAYER_LEAVING_WORLD / PLAYER_LOGOUT — wrote
-- cold-API zeros over good data and that write is the one SavedVariables keeps.
-- Testing the helper alone would have passed while the bug shipped.
----------------------------------------------------------------------
local function testXPCapture(fails)
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
        level = _G.UnitLevel, xp = _G.UnitXP, xpMax = _G.UnitXPMax,
        exhaust = _G.GetXPExhaustion,
    }
    local savedLatch = {
        Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt,
        Tracker._auraCapturedAt, Tracker._cdCapturedAt,
        Tracker._lastPushHash, Tracker._lastPushAt,
    }

    local frameNow, epochNow = 30000, 1700000000
    _G.GetTime   = function() return frameNow end
    ns.Store.Now = function() return epochNow end
    ns.state.loggedIn = true

    _G.C_UnitAuras = { GetBuffDataByIndex = function() return nil end }
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

    -- One durable record across captures, exactly as the game holds it.
    local rec = {}
    ns.Store.EnsureSelfCharacter = function() return rec end
    ns.Store.WriteSelfCharacter  = function() end

    -- The live XP APIs, swappable between warm and cold.
    local lvl, xpNow, xpMaxNow, restedNow = 41, 50000, 155000, 232500
    _G.UnitLevel        = function() return lvl end
    _G.UnitXP           = function() return xpNow end
    _G.UnitXPMax        = function() return xpMaxNow end
    _G.GetXPExhaustion  = function() return restedNow end
    -- Teardown / loading-screen cold reads: the unit APIs answer 0 / nil.
    local function goCold() xpNow, xpMaxNow, restedNow = 0, 0, nil end
    -- ...or GARBAGE. The A17.2 header's word for teardown reads is "nothing OR
    -- garbage", and every other capture piece freezes rather than sort the two
    -- apart. These non-zero values slip past the cold-read rule, so they are what
    -- isolate the TEARDOWN rule from it — one mutant per rule.
    local function goGarbage() xpNow, xpMaxNow, restedNow = 7, 11, 13 end
    local function goWarm(x, m, r) xpNow, xpMaxNow, restedNow = x, m, r end

    local ok, err = pcall(function()
        Tracker._leavingWorld, Tracker._loggingOut = false, false
        Tracker._enteredWorldAt = frameNow - 60
        Tracker._auraCapturedAt, Tracker._cdCapturedAt = nil, nil
        Tracker._lastPushHash, Tracker._lastPushAt = nil, 0

        -- 1) A normal in-session capture WRITES the three fields. This is the
        --    contract the Rest view consumes; without it every row is an em-dash.
        Tracker.Capture()
        ck(rec.xp == 50000, "capture writes xp (got " .. tostring(rec.xp) .. ")")
        ck(rec.xpMax == 155000, "capture writes xpMax (got " .. tostring(rec.xpMax) .. ")")
        ck(rec.restedXP == 232500, "capture writes restedXP (got " .. tostring(rec.restedXP) .. ")")
        -- The view's actual gate: RestedPercent must produce a number, not nil.
        ck(ns.Store.RestedPercent(rec) == 150,
           "captured record yields a rested percent (got " .. tostring(ns.Store.RestedPercent(rec)) .. ")")

        -- 2) THE REGRESSION — PLAYER_LEAVING_WORLD. The latch is set; the forced
        --    teardown capture must NOT touch the trio. This is the write
        --    SavedVariables persists, so a failure here is precisely the reported
        --    bug. Asserted with GARBAGE rather than zeros on purpose: zeros are
        --    also refused by the cold-read rule, so only a non-zero teardown read
        --    can prove the TEARDOWN gate itself is present.
        goGarbage()
        Tracker._leavingWorld = true
        Tracker.Capture(true)
        ck(rec.xp == 50000 and rec.xpMax == 155000 and rec.restedXP == 232500,
           "leaving-world teardown must FREEZE xp/xpMax/restedXP (got "
           .. tostring(rec.xp) .. "/" .. tostring(rec.xpMax) .. "/" .. tostring(rec.restedXP) .. ")")

        -- 3) Same for PLAYER_LOGOUT, the terminal latch — the last capture of the
        --    session and the one that used to zero every character.
        Tracker._leavingWorld = false
        Tracker._loggingOut = true
        Tracker.Capture(true)
        ck(rec.xp == 50000 and rec.xpMax == 155000 and rec.restedXP == 232500,
           "logout teardown must FREEZE xp/xpMax/restedXP (got "
           .. tostring(rec.xp) .. "/" .. tostring(rec.xpMax) .. "/" .. tostring(rec.restedXP) .. ")")
        ck(ns.Store.RestedPercent(rec) == 150,
           "the rested percent survives the logout capture (the whole point)")

        -- 3b) And the cold-zero flavour of teardown — the shape actually found in
        --     the owner's store — is refused too, by whichever rule gets there first.
        goCold()
        Tracker.Capture(true)
        ck(rec.xp == 50000 and rec.xpMax == 155000 and rec.restedXP == 232500,
           "a cold-zero logout capture must not wipe the trio either")

        -- 4) A COLD xpMax with NO teardown latch — a fresh login before the unit
        --    APIs warm up. xpMax 0 on a sub-60 is impossible, so it is evidence of
        --    a cold API, never of "no XP". Freeze, do not wipe. (This is the case
        --    the teardown gate does NOT cover, so it pins the second rule.)
        Tracker._loggingOut = false
        Tracker.Capture()
        ck(rec.xp == 50000 and rec.xpMax == 155000 and rec.restedXP == 232500,
           "a cold sub-60 xpMax must not wipe the stored trio")

        -- 5) The freeze is not a one-way stick: a warm read updates as normal,
        --    including a rested pool that has legitimately drained to 0.
        goWarm(60000, 155000, 0)
        Tracker.Capture()
        ck(rec.xp == 60000 and rec.xpMax == 155000, "a warm read updates after a freeze")
        ck(rec.restedXP == 0, "a genuinely drained rested pool writes 0")
        ck(ns.Store.RestedPercent(rec) == 0,
           "0 rested with a valid xpMax is 0%, NOT absent data")

        -- 6) Level 60: the zeros are the fact, not a cold read. Written honestly
        --    even though the APIs are handing back live numbers.
        lvl = 60
        goWarm(12345, 67890, 4242)
        Tracker.Capture()
        ck(rec.xp == 0 and rec.xpMax == 0 and rec.restedXP == 0,
           "a level-60 capture zeroes the trio honestly (got "
           .. tostring(rec.xp) .. "/" .. tostring(rec.xpMax) .. "/" .. tostring(rec.restedXP) .. ")")
        ck(ns.Store.RestedPercent(rec) == nil, "a level 60 has no rested percent")
    end)

    _G.C_UnitAuras, _G.C_Container, _G.C_Item, _G.C_Map = saved.auras, saved.cont, saved.item, saved.map
    _G.GetTime, _G.IsResting = saved.getTime, saved.resting
    _G.UnitIsPVP, _G.UnitIsPVPFreeForAll = saved.pvp, saved.ffa
    _G.IsInInstance, _G.GetNumSavedInstances = saved.inInst, saved.savedInst
    _G.GetSubZoneText, _G.GetMinimapZoneText = saved.sub, saved.mini
    _G.UnitLevel, _G.UnitXP, _G.UnitXPMax = saved.level, saved.xp, saved.xpMax
    _G.GetXPExhaustion = saved.exhaust
    ns.Store.Now, ns.Store.GetSettings = saved.now, saved.settings
    ns.Store.EnsureSelfCharacter, ns.Store.WriteSelfCharacter = saved.ensure, saved.write
    ns.state.loggedIn = saved.loggedIn
    Tracker._leavingWorld, Tracker._loggingOut, Tracker._enteredWorldAt = savedLatch[1], savedLatch[2], savedLatch[3]
    Tracker._auraCapturedAt, Tracker._cdCapturedAt = savedLatch[4], savedLatch[5]
    Tracker._lastPushHash, Tracker._lastPushAt = savedLatch[6], savedLatch[7]

    if not ok then fails[#fails + 1] = "error in xp-capture fixtures: " .. tostring(err) end
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
    -- J4 / schema v3: the capture publishes the WIRE MIRROR the encoder reads.
    -- Without this the v3 tail ships 0 on every frame and the remote card silently
    -- keeps its flag-only rendering forever — a failure with no symptom locally.
    ck(rec.dmfCooldownRemaining == 14400,
       "J4: a fresh gain must publish the wire mirror, got " .. tostring(rec.dmfCooldownRemaining))

    -- ...and holding it does not re-stamp on every capture.
    epochNow = EPOCH + 900
    Tracker._captureDMF(rec)
    ck(ns.Store.DMFCooldownRemaining(rec) == 13500,
       "holding the fortune: the tick decrements, it does not re-stamp")
    ck(rec.dmfCooldownRemaining == 13500,
       "J4: the mirror follows the tick (it is republished on every capture)")

    -- ---- teardown stamps the offline epoch ---------------------------------
    Tracker._loggingOut = true
    epochNow = EPOCH + 1000
    Tracker._captureDMF(rec)
    ck(rec.dmfCooldown.offlineSince == EPOCH + 1000, "teardown: offlineSince stamped")
    -- J4: the teardown path RETURNS EARLY out of the edge logic, so the mirror is
    -- published by the wrapper rather than by the body — which is the point of the
    -- wrapper. The logout frame must carry the same number the record holds.
    ck(rec.dmfCooldownRemaining == ns.Store.DMFCooldownRemaining(rec),
       "J4: the teardown path skipped the wire mirror")
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
    -- J4: the push-clear path also returns early. A cleared cooldown must publish
    -- 0 — a mirror left holding the old countdown would keep peers showing a
    -- timer for a cooldown that is over.
    ck(rec.dmfCooldownRemaining == 0,
       "J4: the debuff-push clear must publish 0, got " .. tostring(rec.dmfCooldownRemaining))
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
    ck(Tracker.AttunementFlags(probeFor({ 7761 })).BWL == true, "BWL: 7761 attunes")
    ck(Tracker.AttunementFlags(probeFor({ 7761 })).MC == false, "BWL quest does not attune MC")

    -- ---- 2b) MC FACTION SPLIT — the 2026-08-02 live bug -------------------
    -- MC shipped with only 7487, so every character holding the OTHER faction's
    -- id read false forever. Either id must attune, and neither may leak into
    -- another raid's answer.
    ck(Tracker.AttunementFlags(probeFor({ 7487 })).MC == true, "MC: 7487 attunes")
    ck(Tracker.AttunementFlags(probeFor({ 7848 })).MC == true,
       "MC: 7848 (the other faction's same-named quest) ALSO attunes")
    ck(Tracker.AttunementFlags(probeFor({ 7848 })).BWL == false,
       "MC: 7848 does not attune BWL")
    ck(Tracker.AttunementFlags(probeFor({ 7848 })).Ony == false,
       "MC: 7848 does not attune Ony")
    ck(Tracker.AttunementFlags(probeFor({ 7487, 7848 })).MC == true,
       "MC: both ids complete still attunes")
    ck(Tracker.AttunementFlags(probeFor({ 7486 })).MC == false,
       "MC: a neighbouring id does not attune")
    ck(Tracker.AttunementFlags(probeFor({ 7849 })).MC == false,
       "MC: a neighbouring id of the second variant does not attune")
    -- The owner's live regression, replayed: a WARM probe (BWL/Ony/Naxx all
    -- true) that only ever held the second MC id used to report MC=false.
    local warm = Tracker.AttunementFlags(probeFor({ 7848, 7761, 6602, 9121 }))
    ck(warm.MC == true and warm.BWL == true and warm.Ony == true and warm.Naxx == true,
       "MC: the owner's warm all-attuned character reads true on ALL FOUR raids")

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
    local EXPECT = { MC = { 7487, 7848 }, BWL = { 7761 }, Ony = { 6502, 6602 },
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

    -- ---- 6b) WARMTH: anyTrue, and the all-false agreement counter ----------
    -- anyTrue is the warmth proof: a gated TRUE can only come from loaded data.
    local _, warmA = Tracker.AttunementFlags(probeFor({ 7761 }))
    ck(warmA == true, "warmth: a gated true reports anyTrue")
    local _, warmB = Tracker.AttunementFlags(probeFor({}))
    ck(warmB == false, "warmth: an all-false probe reports anyTrue=false")
    -- ZG/AQ20/AQ40 are true by construction and must NOT count as warmth,
    -- otherwise every cold probe would license its own falses.
    local coldFlags, coldWarm = Tracker.AttunementFlags(probeFor({}))
    ck(coldFlags.ZG == true and coldWarm == false,
       "warmth: the always-attuned raids do not count as a warmth proof")

    local TAF = Tracker.TrustAllFalse
    local WARM, AGREE = Tracker.ATTUNE_WARM_DELAY, Tracker.ATTUNE_AGREE_COUNT
    ck(WARM > 0 and AGREE >= 2, "warmth: the thresholds are meaningful")
    local t1, r1 = TAF(0, 0)
    ck(t1 == false and r1 == 1, "trust: probe 1 at 0s online is NOT trusted")
    local t2, r2 = TAF(r1, 1)
    ck(t2 == false and r2 == 2, "trust: agreeing twice is not enough while still cold")
    local t3 = TAF(0, WARM + 1)
    ck(t3 == false, "trust: one lone probe is not enough even when warm")
    local t4 = TAF(AGREE - 1, WARM)
    ck(t4 == true, "trust: warm enough AND agreeing enough -> trusted")
    ck(TAF(nil, WARM + 100) == false, "trust: a nil counter starts a fresh run")
    ck(TAF(99, WARM - 1) == false, "trust: agreement alone never beats the warm delay")

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

    -- ---- level impossibility (the Wyx-Whitemane raid row) ------------------
    -- A level 16 with NO attunement data used to answer nil, which the detail
    -- pane renders as attuned/green — the second half of the owner's report.
    local lowBare = { nameRealm = "Wyx-Whitemane", level = 16 }
    for _, k in ipairs({ "MC", "BWL", "Ony", "Naxx" }) do
        ck(RA(lowBare, k) == false,
           "RaidAttuned: " .. k .. " is FALSE for a level 16 (impossible, not unknown)")
    end
    for _, k in ipairs({ "ZG", "AQ20", "AQ40" }) do
        ck(RA(lowBare, k) == true,
           "RaidAttuned: " .. k .. " needs no attunement — still true at level 16")
    end
    -- Impossibility outranks even a stored true (that true IS the corruption).
    local lowLying = { nameRealm = "Wyx-Whitemane", level = 16,
                       attunements = { MC = true, Naxx = true } }
    ck(RA(lowLying, "MC") == false, "RaidAttuned: an impossible stored true is overruled")
    ck(RA(lowLying, "Naxx") == false, "RaidAttuned: impossibility beats monotonic true")
    -- The gate is `below`, not `at or below`, and an unknown level is not evidence.
    local atGate = { nameRealm = "Edge-Realm", level = ns.Store.ATTUNE_MIN_LEVEL }
    ck(RA(atGate, "MC") == nil, "RaidAttuned: exactly at the gate is not judged")
    local noLevel = { nameRealm = "Stranger-Realm" }
    ck(RA(noLevel, "MC") == nil, "RaidAttuned: an unknown level still answers nil")
    local sixty = { nameRealm = "Main-Realm", level = 60, attunements = { MC = true } }
    ck(RA(sixty, "MC") == true, "RaidAttuned: a level 60 is unaffected by the gate")

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

        -- MONOTONIC OR across the two sources. A record false must NOT be able
        -- to suppress a namespace true: NON_WIRE_CARRY pins `attunements` onto a
        -- peer record forever, so precedence made a pre-heal false permanent.
        ck(RA({ nameRealm = "Peer-Realm", attunements = { MC = false } }, "MC") == true,
           "OR: a stale record FALSE cannot beat a fresh namespace TRUE")
        ck(RA({ nameRealm = "Alt-Realm", attunements = { MC = true } }, "MC") == true,
           "OR: a record TRUE wins over a namespace false")
        ck(RA({ nameRealm = "Alt-Realm", attunements = { MC = false } }, "MC") == false,
           "OR: false on both sides still greys")
        ck(RA({ nameRealm = "Nobody-Realm", attunements = { BWL = false } }, "BWL") == false,
           "OR: a record false with no namespace opinion still greys")
        ck(RA({ nameRealm = "Alt-Realm" }, "MC") == false,
           "OR: namespace-only false still greys")

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

    local savedEW   = Tracker._enteredWorldAt
    local savedRuns = Tracker._attuneAllFalseRuns

    local ok, err = pcall(function()
        local cap = Tracker._captureAttunements
        local gt  = (GetTime and GetTime()) or 0
        -- Pretend the last loading screen finished `n` seconds ago.
        local function onlineFor(n) Tracker._enteredWorldAt = gt - n end

        -- ---- COLD PROBE: an all-false answer at login publishes NOTHING -----
        -- This is the failure the owner would have seen on a first-ever login:
        -- the API is present and answering, it is just answering false.
        local cold = { nameRealm = "Cold-Realm" }
        Tracker._attuneCheckedAt    = nil
        Tracker._attuneAllFalseRuns = 0
        onlineFor(0)
        ck(cap(cold, true) == false, "cold: an all-false probe at login reports no change")
        ck(cold.attunements == nil,
           "cold: NOTHING is written -- the matrix stays UNKNOWN, never all-false")
        ck(ns.Store.RaidAttuned(cold, "MC") == nil,
           "cold: the character reads nil (renders ATTUNED), never greyed on a cold read")

        -- A second agreeing probe still inside the warm delay is still unknown.
        epochNow = epochNow + Tracker.ATTUNE_RECHECK_INTERVAL + 1
        ck(cap(cold, true) == false, "cold: agreeing twice inside the warm delay is still unknown")
        ck(cold.attunements == nil, "cold: still nothing written")

        -- ---- WARM DOUBLE-AGREE: a genuinely unattuned alt earns its grey ----
        onlineFor(Tracker.ATTUNE_WARM_DELAY + 1)
        epochNow = epochNow + Tracker.ATTUNE_RECHECK_INTERVAL + 1
        ck(cap(cold, true) == true, "warm: the agreeing all-false probe is finally trusted")
        ck(type(cold.attunements) == "table", "warm: the matrix is written")
        ck(cold.attunements.MC == false, "warm: a fresh alt really is not MC attuned")
        ck(cold.attunements.ZG == true,  "warm: ZG true regardless")
        ck(ns.Store.RaidAttuned(cold, "MC") == false, "warm: NOW it greys")

        -- ---- ANY GATED TRUE licenses the falses at once, even at 0s online --
        local rec = { nameRealm = "Cap-Realm" }
        completed[7761] = true                  -- BWL only
        Tracker._attuneCheckedAt    = nil
        Tracker._attuneAllFalseRuns = 0
        onlineFor(0)
        ck(cap(rec, true) == true, "anyTrue: a probe holding a gated TRUE is trusted at once")
        ck(rec.attunements.BWL == true, "anyTrue: BWL true")
        ck(rec.attunements.MC == false, "anyTrue: the falses beside it are believed")
        ck(rec.attunements.ZG == true,  "capture: ZG true immediately")

        -- ---- FALSE -> TRUE SELF-HEAL, via the second MC id (the live bug) ---
        completed[7848] = true
        epochNow = epochNow + Tracker.ATTUNE_RECHECK_INTERVAL + 1
        ck(cap(rec, false) == true, "heal: the matrix moved -> capture reports a republish")
        ck(rec.attunements.MC == true, "heal: MC flips false -> true through the 2nd faction id")
        ck(ns.Store.RaidAttuned(rec, "MC") == true, "heal: the raid stops greying")

        -- Throttled: a completed quest is NOT picked up until the window passes.
        completed[9122] = true
        ck(cap(rec, false) == false, "capture: an unforced re-probe inside the window is a no-op")
        ck(rec.attunements.Naxx == false, "capture: the throttled call did not re-probe")

        -- Forced (a quest turn-in) bypasses the throttle immediately.
        ck(cap(rec, true) == true, "capture: a FORCED probe bypasses the throttle")
        ck(rec.attunements.Naxx == true, "capture: Naxx (Revered variant) picked up")

        -- No change -> no dirty signal.
        epochNow = epochNow + Tracker.ATTUNE_RECHECK_INTERVAL + 1
        ck(cap(rec, false) == false, "capture: an unchanged matrix reports no change")

        -- A DEAD api must not wipe what we already knew.
        _G.C_QuestLog = { IsQuestFlaggedCompleted = function() error("cold") end }
        epochNow = epochNow + Tracker.ATTUNE_RECHECK_INTERVAL + 1
        ck(cap(rec, true) == false, "capture: a dead API reports no change")
        ck(rec.attunements.MC == true and rec.attunements.Naxx == true,
           "capture: a dead API does NOT regress stored attunements")

        -- The namespace payload only publishes records that carry a matrix.
        local payload = Tracker.AttunePayload()
        ck(type(payload) == "table", "payload: AttunePayload returns a table")
        for nameRealm, flags in pairs(payload) do
            ck(type(nameRealm) == "string" and type(flags) == "table",
               "payload: entries are nameRealm -> flags")
        end
    end)

    -- ---- 11b) PAYLOAD MUTATION ISOLATION -----------------------------------
    -- AttunePayload must publish COPIES, never live references into the stored
    -- character records. Mutating what we handed the namespace must not reach
    -- the store, and mutating the store must not retro-edit a payload already
    -- published. Fixture drives GetSelfAccount through a stubbed self bucket.
    do
        local savedAcc = ns.Store.data.accounts
        local savedAID = ns.GetAccountID
        ns.GetAccountID = function() return "1" end
        local stored  = { MC = true,  BWL = false }
        local parked  = { Naxx = false }
        ns.Store.data.accounts = {
            ["1"] = {
                isSelf = true,
                characters = { ["Live-Realm"]   = { attunements = stored } },
                homeless   = { ["Parked-Realm"] = { attunements = parked } },
                segments = { sixties = {}, summoners = {}, norole = {} },
                segmentHashes = {},
            },
        }

        local p = Tracker.AttunePayload()
        ck(p["Live-Realm"] ~= nil and p["Parked-Realm"] ~= nil,
           "isolation: both characters (characters + homeless) are published")
        ck(p["Live-Realm"] ~= stored,
           "THE FIX: the published table is NOT the stored table (no aliasing)")
        ck(p["Parked-Realm"] ~= parked,
           "THE FIX: homeless records are copied too")
        ck(p["Live-Realm"].MC == true and p["Live-Realm"].BWL == false,
           "isolation: the copy carries the same values")

        -- Mutating the PAYLOAD must not touch the store.
        p["Live-Realm"].MC  = false
        p["Live-Realm"].ZG  = true
        p["Parked-Realm"].Naxx = true
        ck(stored.MC == true, "isolation: a payload edit does not regress the stored matrix")
        ck(stored.ZG == nil,  "isolation: a payload insert does not leak into the record")
        ck(parked.Naxx == false, "isolation: same for a homeless record")

        -- Mutating the STORE must not retro-edit an already-published payload.
        stored.BWL = true
        ck(p["Live-Realm"].BWL == false,
           "isolation: a later store write does not mutate a published payload")

        -- Two successive payloads are independent of each other, too.
        local q = Tracker.AttunePayload()
        ck(q["Live-Realm"] ~= p["Live-Realm"],
           "isolation: successive payloads do not share tables")

        ns.GetAccountID        = savedAID
        ns.Store.data.accounts = savedAcc
    end

    Tracker._enteredWorldAt     = savedEW
    Tracker._attuneAllFalseRuns = savedRuns

    _G.C_QuestLog = savedQL
    ns.Store.Now  = savedNow
    Tracker._attuneCheckedAt = savedAt
    if not ok then fails[#fails + 1] = "error in attunement fixtures: " .. tostring(err) end

    -- ---- 12) the one-shot MC cleanup --------------------------------------
    -- Demotes the falses the single-id probe left behind to UNKNOWN, so a
    -- parked alt that will not log in again renders attuned instead of wrongly
    -- greyed. TRUE is never touched, and no other raid key is touched.
    local MIG = Tracker._MigrateMCFalsesIn
    local bucket = {
        characters = {
            ["Stale-Realm"]  = { attunements = { MC = false, BWL = true,  Ony = false, ZG = true } },
            ["Attuned-Realm"]= { attunements = { MC = true,  BWL = false } },
            ["Bare-Realm"]   = { },
        },
        homeless = {
            ["Parked-Realm"] = { attunements = { MC = false, Naxx = false } },
        },
    }
    local n = MIG(bucket)
    ck(n == 2, "migration: exactly the two MC=false records were touched")
    ck(bucket.characters["Stale-Realm"].attunements.MC == nil,
       "migration: an untrustworthy MC false becomes UNKNOWN")
    ck(bucket.homeless["Parked-Realm"].attunements.MC == nil,
       "migration: homeless records are migrated too")
    ck(bucket.characters["Attuned-Realm"].attunements.MC == true,
       "migration: a stored MC TRUE is never touched (monotonic)")
    ck(bucket.characters["Stale-Realm"].attunements.BWL == true
       and bucket.characters["Stale-Realm"].attunements.Ony == false
       and bucket.characters["Stale-Realm"].attunements.ZG == true,
       "migration: no other raid key is disturbed")
    ck(bucket.homeless["Parked-Realm"].attunements.Naxx == false,
       "migration: Naxx=false is left alone (its probe asked about every id)")
    ck(bucket.characters["Bare-Realm"].attunements == nil,
       "migration: a record with no matrix is left alone")
    ck(MIG(bucket) == 0, "migration: idempotent -- a second pass touches nothing")
    ck(MIG(nil) == 0, "migration: a nil bucket is a no-op")
    -- The demoted value now reads as UNKNOWN, i.e. renders ATTUNED.
    ck(ns.Store.RaidAttuned({ nameRealm = "Stale-Only-Realm",
                              attunements = bucket.characters["Stale-Realm"].attunements },
                            "MC") == nil,
       "migration: the demoted MC reads nil -> the card renders attuned")
end

----------------------------------------------------------------------
-- THE ONE-SHOT REPAIR PASS (layer (b) of the Wyx-Whitemane fix)
--
-- Fixture shapes, all taken from the owner's real store:
--   Wyx      lvl 16, ten detonated placeholders (the reported bug)
--   Ceporah  lvl 20, nine placeholders + ONE genuine live capture (option 0)
--   Phoenix  lvl 60, a real booned buff set — must not be touched
--   Zaan     lvl 60, three placeholders mixed with real slots — below the
--            threshold, so the block is left alone (conservative by design)
----------------------------------------------------------------------
local function testImpossibleRepair(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function ph()   return { duration = 7172, option = 1, source = 0 } end  -- detonated
    local function zero() return { duration = 0,    option = 1, source = 0 } end  -- undetonated
    local function real(d) return { duration = d,   option = 0, source = 2 } end  -- genuine

    local function mkBucket()
        -- Wyx and Parked carry real XP/rested data as well as the fabricated
        -- slots: the repair pass rewrites both records, and must come nowhere
        -- near the trio the Rest view reads. (The XP fields have their own
        -- capture-side story — see testXPCapture — and no repair can know a
        -- parked alt's XP, so touching them here could only ever destroy data.)
        local wyx = { level = 16, auraStates = {}, xp = 1200, xpMax = 3600, restedXP = 5400 }
        for s = 1, 10 do wyx.auraStates[s] = ph() end
        local cep = { level = 20, auraStates = { [1] = { duration = 4074, option = 0, source = 0 } } }
        for s = 2, 10 do cep.auraStates[s] = ph() end
        local pho = { level = 60, auraStates = { [1] = real(7020), [2] = real(3540),
                                                 [3] = real(6780), [5] = real(7200) },
                      attunements = { MC = true, BWL = true, Ony = true, Naxx = true } }
        local zaan = { level = 60, auraStates = { [1] = zero(), [3] = zero(), [9] = zero(),
                                                  [2] = real(7199), [7] = real(7132) } }
        local lowAtt = { level = 16, attunements = { MC = true, Naxx = true, ZG = true },
                         xp = 900, xpMax = 3600, restedXP = 0 }
        return { characters = { Wyx = wyx, Ceporah = cep, Phoenix = pho, Zaan = zaan },
                 homeless   = { Parked = lowAtt } }
    end

    local function slotCount(rec)
        local n = 0
        if type(rec.auraStates) == "table" then for _ in pairs(rec.auraStates) do n = n + 1 end end
        return n
    end

    -- ---- the pure per-bucket worker ---------------------------------------
    local b, counts = mkBucket(), {}
    local touched = Tracker._RepairImpossibleIn(b, counts)

    ck(slotCount(b.characters.Wyx) == 0,
       "repair: the fabricated 10/10 world-buff set is cleared (Wyx)")
    ck(slotCount(b.characters.Ceporah) == 1,
       "repair: nine placeholders stripped, the one REAL capture survives (Ceporah)")
    ck(b.characters.Ceporah.auraStates[1] ~= nil
       and b.characters.Ceporah.auraStates[1].duration == 4074,
       "repair: the surviving slot keeps its real duration")
    ck(slotCount(b.characters.Phoenix) == 4,
       "repair: a genuine level-60 buff set is untouched")
    ck(b.characters.Phoenix.attunements.MC == true
       and b.characters.Phoenix.attunements.Naxx == true,
       "repair: a level-60's attunements are untouched")
    ck(slotCount(b.characters.Zaan) == 5,
       "repair: a block below the fabricated threshold is left alone (conservative)")
    ck(b.homeless.Parked.attunements.MC == nil
       and b.homeless.Parked.attunements.Naxx == nil,
       "repair: level-impossible attunements demoted in HOMELESS records too")
    ck(b.homeless.Parked.attunements.ZG == true,
       "repair: ungated raids survive the attunement demotion")
    ck(touched == 3, "repair: exactly three records changed (Wyx, Ceporah, Parked)")
    -- The repair rewrites Wyx and Parked, and must leave the Rest view's fields alone.
    ck(b.characters.Wyx.xp == 1200 and b.characters.Wyx.xpMax == 3600
       and b.characters.Wyx.restedXP == 5400,
       "repair: xp/xpMax/restedXP survive a record the pass rewrites (Wyx)")
    ck(b.homeless.Parked.xp == 900 and b.homeless.Parked.xpMax == 3600
       and b.homeless.Parked.restedXP == 0,
       "repair: a 0 rested pool is DATA and is not confused for absence (Parked)")
    ck(ns.Store.RestedPercent(b.characters.Wyx) == 150,
       "repair: the repaired record still renders a rested percent")
    ck((counts.auraBlocks or 0) == 2, "repair: two records had fabricated slots")
    ck((counts.auraSlots or 0) == 19, "repair: 10 + 9 fabricated slots stripped")
    ck((counts.attune or 0) == 2, "repair: two impossible attunement flags demoted")

    -- ---- idempotent: a second pass over the SAME bucket changes nothing ----
    local counts2 = {}
    ck(Tracker._RepairImpossibleIn(b, counts2) == 0,
       "repair: a second pass over repaired data touches nothing")
    ck(next(counts2) == nil, "repair: the second pass accumulates no counts")
    ck(Tracker._RepairImpossibleIn(nil, {}) == 0, "repair: a nil bucket is a no-op")

    -- ---- the fabricated-block predicate -----------------------------------
    local eight = {}
    for s = 1, 8 do eight[s] = zero() end
    ck(Tracker._IsFabricatedAuraBlock(eight) == true, "predicate: 8 slots meets the threshold")
    local seven = {}
    for s = 1, 7 do seven[s] = zero() end
    ck(Tracker._IsFabricatedAuraBlock(seven) == false, "predicate: 7 slots is below the threshold")
    local allReal = {}
    for s = 1, 10 do allReal[s] = real(7000) end
    ck(Tracker._IsFabricatedAuraBlock(allReal) == false,
       "predicate: ten GENUINE slots are never fabricated (source/option differ)")
    local liveOptZero = {}
    for s = 1, 10 do liveOptZero[s] = { duration = 7000, option = 0, source = 0 } end
    ck(Tracker._IsFabricatedAuraBlock(liveOptZero) == false,
       "predicate: live capture (option 0) is never mistaken for the import default")
    ck(Tracker._IsFabricatedAuraBlock(nil) == false, "predicate: nil block is not fabricated")

    -- ---- the attune NAMESPACE pass ----------------------------------------
    local levels = { ["Wyx-Whitemane"] = 16, ["Phoenix-Whitemane"] = 60 }
    local nsTbl = {
        ["1"] = { data = {
            ["Wyx-Whitemane"]     = { MC = true, Naxx = true, ZG = true },
            ["Phoenix-Whitemane"] = { MC = true, Naxx = true },
            ["Unknown-Whitemane"] = { MC = true },
        }, rev = 73 },
    }
    local demoted = Tracker._RepairAttuneNamespace(nsTbl, function(n) return levels[n] end)
    ck(demoted == 2, "namespace: exactly the two impossible flags demoted")
    ck(nsTbl["1"].data["Wyx-Whitemane"].MC == nil
       and nsTbl["1"].data["Wyx-Whitemane"].Naxx == nil,
       "namespace: a level-16's gated flags are demoted")
    ck(nsTbl["1"].data["Wyx-Whitemane"].ZG == true,
       "namespace: ungated raids survive")
    ck(nsTbl["1"].data["Phoenix-Whitemane"].MC == true,
       "namespace: a level-60's flags are untouched")
    ck(nsTbl["1"].data["Unknown-Whitemane"].MC == true,
       "namespace: a character with no known level is not judged")
    ck(Tracker._RepairAttuneNamespace(nsTbl, function(n) return levels[n] end) == 0,
       "namespace: idempotent")
    ck(Tracker._RepairAttuneNamespace(nil, function() end) == 0, "namespace: nil table is a no-op")

    -- ---- the MARKER makes the runner one-shot -----------------------------
    local S = ns.Store
    local savedAccounts = S.data.accounts
    local savedNs       = S.data.syncNamespaces
    local savedMarker   = S.data[Tracker.AURA_REPAIR_KEY]
    S.data.accounts       = { ["9"] = mkBucket() }
    S.data.syncNamespaces = nil
    S.data[Tracker.AURA_REPAIR_KEY] = nil

    local first = Tracker.RepairImpossibleRecords()
    ck(first == 3, "runner: the first run repairs the corrupted fixture")
    ck(S.data[Tracker.AURA_REPAIR_KEY] == true, "runner: the marker is set after the run")
    ck(slotCount(S.data.accounts["9"].characters.Wyx) == 0, "runner: Wyx is healed")

    -- Re-corrupt, then prove the marker stops a second run cold.
    S.data.accounts["9"] = mkBucket()
    ck(Tracker.RepairImpossibleRecords() == 0,
       "runner: the marker makes a second run a no-op")
    ck(slotCount(S.data.accounts["9"].characters.Wyx) == 10,
       "runner: the second run really did not touch the data")

    S.data.accounts       = savedAccounts
    S.data.syncNamespaces = savedNs
    S.data[Tracker.AURA_REPAIR_KEY] = savedMarker
end

----------------------------------------------------------------------
-- R4 REPAIR + INBOUND GUARD for the impossible boon slot.
--
-- Records written before the parse was scoped can carry auraStates[9] with
-- source = BOON. Two layers, exactly as the mesh-bleed fix has it: a one-shot
-- repair for what is already on disk (marker-guarded, its OWN marker because the
-- older pass's marker is already true everywhere), and an always-on inbound guard
-- for what peers keep sending until they patch.
----------------------------------------------------------------------
local function testBoonScopeRepair(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local S = ns.Store
    local BOON = (S.AURA_SOURCE and S.AURA_SOURCE.BOON) or 2

    local function boon(dur) return { duration = dur, option = 0, source = BOON } end
    local function live(dur) return { duration = dur, option = 0, source = 0 } end

    -- ---- the pure stripper ------------------------------------------------
    local states = { [1] = boon(6900), [6] = boon(7000), [9] = boon(800), [10] = boon(100) }
    ck(Tracker._StripNonBoonableBoonSlots(states) == 2,
       "strip: exactly the two impossible slots go")
    ck(states[1] and states[6], "strip: the booned boonable slots survive")
    ck(states[9] == nil and states[10] == nil, "strip: slots 9/10 are gone")
    ck(Tracker._StripNonBoonableBoonSlots(states) == 0, "strip: idempotent")

    -- A LIVE Battle Shout is an ordinary legal buff and is NEVER touched.
    local liveBS = { [9] = live(800), [10] = live(100), [1] = boon(6900) }
    ck(Tracker._StripNonBoonableBoonSlots(liveBS) == 0,
       "strip: a LIVE Battle Shout is legal and is left alone")
    ck(liveBS[9] and liveBS[10], "strip: live slots 9/10 survive intact")
    -- Relayed (source 1) likewise.
    local relayed = { [9] = { duration = 800, option = 0, source = 1 } }
    ck(Tracker._StripNonBoonableBoonSlots(relayed) == 0, "strip: a RELAYED slot 9 is left alone")
    ck(Tracker._StripNonBoonableBoonSlots(nil) == 0, "strip: nil block is a no-op")

    -- ---- the bucket sweep -------------------------------------------------
    local function mkBucket()
        return {
            characters = {
                Boonwar = { nameRealm = "Boonwar-R", level = 60,
                            auraStates = { [1] = boon(6900), [9] = boon(800) } },
                Clean   = { nameRealm = "Clean-R", level = 60,
                            auraStates = { [1] = boon(6900), [9] = live(800) } },
            },
            homeless = {
                Parked = { nameRealm = "Parked-R", level = 60,
                           auraStates = { [10] = boon(100) } },
            },
        }
    end
    local b, counts = mkBucket(), {}
    ck(Tracker._RepairBoonScopeIn(b, counts) == 2,
       "sweep: two records changed (characters AND homeless)")
    ck((counts.boonSlots or 0) == 2, "sweep: two slots counted")
    ck(b.characters.Boonwar.auraStates[9] == nil, "sweep: the booned slot 9 is gone")
    ck(b.characters.Boonwar.auraStates[1] ~= nil, "sweep: the real booned slot survives")
    ck(b.characters.Clean.auraStates[9] ~= nil, "sweep: a LIVE slot 9 is untouched")
    ck(b.homeless.Parked.auraStates[10] == nil, "sweep: homeless records are swept too")
    ck(Tracker._RepairBoonScopeIn(b, {}) == 0, "sweep: a second pass changes nothing")
    ck(Tracker._RepairBoonScopeIn(nil, {}) == 0, "sweep: a nil bucket is a no-op")

    -- ---- the persisted tooltip caches ------------------------------------
    local caches = {
        ["Boonwar-R"] = { slots = { [1] = { duration = 6900 }, [9] = { duration = 800 } },
                          dmf = false, count = 2 },
        ["Clean-R"]   = { slots = { [1] = { duration = 6900 } }, dmf = false, count = 1 },
    }
    ck(Tracker._RepairBoonCaches(caches) == 1, "caches: one snapshot changed")
    ck(caches["Boonwar-R"].slots[9] == nil, "caches: the impossible slot is scrubbed")
    ck(caches["Boonwar-R"].count == 1, "caches: the stored count comes down with it")
    ck(caches["Clean-R"].count == 1, "caches: a clean snapshot is untouched")
    ck(Tracker._RepairBoonCaches(caches) == 0, "caches: idempotent")
    ck(Tracker._RepairBoonCaches(nil) == 0, "caches: nil is a no-op")

    -- ---- the runner + its OWN marker --------------------------------------
    local savedAccounts = S.data.accounts
    local savedCaches   = S.data.caches
    local savedMarker   = S.data[Tracker.BOON_SCOPE_REPAIR_KEY]
    local savedOld      = S.data[Tracker.AURA_REPAIR_KEY]

    S.data.accounts = { ["9"] = mkBucket() }
    S.data.caches   = { tooltipBoon = { ["Boonwar-R"] = {
        slots = { [9] = { duration = 800 } }, count = 1 } } }
    S.data[Tracker.BOON_SCOPE_REPAIR_KEY] = nil
    -- THE POINT OF THE SEPARATE MARKER: the older pass has already run in every
    -- live store, so this one must not be gated behind it.
    S.data[Tracker.AURA_REPAIR_KEY] = true

    ck(Tracker.RepairNonBoonableBoonSlots() == 2,
       "runner: runs even though the OLDER repair marker is already set")
    ck(S.data[Tracker.BOON_SCOPE_REPAIR_KEY] == true, "runner: its own marker is set")
    ck(S.data.accounts["9"].characters.Boonwar.auraStates[9] == nil, "runner: the record is healed")
    ck(S.data.caches.tooltipBoon["Boonwar-R"].slots[9] == nil, "runner: the cache is healed")

    S.data.accounts["9"] = mkBucket()
    ck(Tracker.RepairNonBoonableBoonSlots() == 0, "runner: the marker makes a second run a no-op")
    ck(S.data.accounts["9"].characters.Boonwar.auraStates[9] ~= nil,
       "runner: the second run really did not touch the data")

    S.data.accounts = savedAccounts
    S.data.caches   = savedCaches
    S.data[Tracker.BOON_SCOPE_REPAIR_KEY] = savedMarker
    S.data[Tracker.AURA_REPAIR_KEY]       = savedOld

    -- ---- the ALWAYS-ON inbound guard --------------------------------------
    -- Unlike the level rules it is not gated on level, because "the chronoboon
    -- cannot hold a Battle Shout" is true at every level — including a record
    -- that never told us its level at all.
    local saved = S._inboundSanity
    S._inboundSanity = { attune = 0, auras = 0, records = 0, boon = 0 }

    local inb = { level = 60, auraStates = { [1] = boon(6900), [9] = boon(800), [10] = boon(50) } }
    ck(S.SanitizeInboundRecord(inb) == 2, "inbound: both impossible boon slots stripped")
    ck(inb.auraStates[9] == nil and inb.auraStates[10] == nil, "inbound: slots 9/10 gone")
    ck(inb.auraStates[1] ~= nil, "inbound: the legal booned slot survives")
    ck(S._inboundSanity.boon == 2, "inbound: the boon counter incremented per slot")
    ck(S._inboundSanity.records == 1, "inbound: the record counter incremented once")

    local nolv = { auraStates = { [9] = boon(800) } }
    ck(S.SanitizeInboundRecord(nolv) == 1,
       "inbound: an UNKNOWN level is no excuse — impossible is impossible")
    ck(nolv.auraStates[9] == nil, "inbound: stripped without any level evidence")

    local ok = { level = 60, auraStates = { [9] = live(800), [10] = live(50) } }
    ck(S.SanitizeInboundRecord(ok) == 0, "inbound: a live Battle Shout passes untouched")
    ck(ok.auraStates[9] ~= nil, "inbound: and is still there afterwards")

    S._inboundSanity = saved
end

----------------------------------------------------------------------
-- COORDINATE OVERRIDE ZONE SCOPING
--
-- The live bug this guards: `(not o.zone or o.zone == zone)` scoped an
-- UNSCOPED rule (zone = "") to a zone literally named "" — `not ""` is false
-- in Lua — so it could never match anywhere. Both producers emit that shape
-- (the SN import, and the options "Add Location" path), which meant every
-- imported location override and every hand-added unscoped rule was silently
-- dead, while HUD._RendOverrideHit — reading the SAME stored rules with the
-- lenient form — matched them. The two matchers must agree.
----------------------------------------------------------------------
local function testCoordinateOverride(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- ---- 1) the pure scope predicate --------------------------------------
    local M = Tracker._OverrideZoneMatches
    ck(M(nil, "Orgrimmar") == true,        "scope: nil zone is unscoped -> matches")
    ck(M("", "Orgrimmar") == true,         "scope: EMPTY zone is unscoped -> matches (the bug)")
    ck(M("   ", "Orgrimmar") == true,      "scope: whitespace-only zone is unscoped -> matches")
    ck(M("\t\n", "Orgrimmar") == true,     "scope: tab/newline zone is unscoped -> matches")
    ck(M("", "") == true,                  "scope: empty rule vs empty zone text still matches")
    ck(M("Orgrimmar", "Orgrimmar") == true,  "scope: exact zone matches its own zone")
    ck(M("Orgrimmar", "Durotar") == false,   "scope: a scoped rule does NOT match another zone")
    ck(M("Orgrimmar", "") == false,          "scope: scoped rule does not match empty zone text")
    -- Defensive: corrupt SavedVariables must not error on the capture path.
    ck(M(42, "Orgrimmar") == false,        "scope: a numeric zone is rejected, not errored on")
    ck(M({}, "Orgrimmar") == false,        "scope: a table zone is rejected, not errored on")
    ck(M(true, "Orgrimmar") == false,      "scope: a boolean zone is rejected, not errored on")

    -- ---- 2) end-to-end through ResolveCoordinateOverride -------------------
    local savedZone, savedMap = _G.GetRealZoneText, _G.C_Map
    local savedGS = ns.Store and ns.Store.GetSettings

    local zoneText, px, py = "Orgrimmar", 0.5, 0.5
    local overrides = {}
    _G.GetRealZoneText = function() return zoneText end
    ns.Store.GetSettings = function() return { coordinateOverrides = overrides } end
    _G.C_Map = {
        GetBestMapForUnit = function() return 1454 end,
        GetPlayerMapPosition = function()
            return { GetXY = function() return px, py end }
        end,
    }

    local BOX = { minX = 0.4, maxX = 0.6, minY = 0.4, maxY = 0.6 }
    local function rule(zone)
        return { label = "Staging", zone = zone,
                 minX = BOX.minX, maxX = BOX.maxX, minY = BOX.minY, maxY = BOX.maxY }
    end

    local ok, err = pcall(function()

    -- An unscoped rule fires in ANY zone — that is the whole point of no scope.
    overrides = { rule(nil) }
    zoneText = "Orgrimmar"
    ck(Tracker.ResolveCoordinateOverride() == "Staging", "nil-zone rule fires in Orgrimmar")
    zoneText = "Mulgore"
    ck(Tracker.ResolveCoordinateOverride() == "Staging", "nil-zone rule fires in Mulgore too")

    -- The regression itself: the "" shape stored by the options path.
    overrides = { rule("") }
    zoneText = "Orgrimmar"
    ck(Tracker.ResolveCoordinateOverride() == "Staging", 'EMPTY-zone rule fires (was dead everywhere)')
    zoneText = "Un'Goro Crater"
    ck(Tracker.ResolveCoordinateOverride() == "Staging", 'EMPTY-zone rule fires in a second zone')

    overrides = { rule("  ") }
    ck(Tracker.ResolveCoordinateOverride() == "Staging", "whitespace-zone rule is unscoped and fires")

    -- A zone-scoped rule still REQUIRES its zone — leniency must not leak.
    overrides = { rule("Orgrimmar") }
    zoneText = "Orgrimmar"
    ck(Tracker.ResolveCoordinateOverride() == "Staging", "scoped rule fires inside its own zone")
    zoneText = "Durotar"
    ck(Tracker.ResolveCoordinateOverride() == nil, "scoped rule stays silent in another zone")

    -- Unscoped is a ZONE waiver, not a BOX waiver: coordinates still gate.
    overrides = { rule("") }
    zoneText = "Orgrimmar"
    px, py = 0.9, 0.9
    ck(Tracker.ResolveCoordinateOverride() == nil, "unscoped rule still requires the coordinate box")
    px, py = 0.5, 0.5

    -- A corrupt rule is skipped, and does not stop a good later rule matching.
    overrides = { rule(42), rule(nil) }
    ck(Tracker.ResolveCoordinateOverride() == "Staging",
       "a corrupt-zone rule is skipped without erroring, later rule still wins")

    -- ---- 3) the SN import fixture now RESOLVES -----------------------------
    -- Producer + matcher checked together: what the import writes must be
    -- something the capture path can actually match.
    if ns.Import and ns.Import._MapCoordinateOverrides then
        local imported = ns.Import._MapCoordinateOverrides({
            { name = "Rend North", x = 0.5, y = 0.47, tolerance = 0.02 },
            { name = "", x = 0, y = 0, tolerance = 0.08 },
        })
        ck(#imported == 1, "import fixture: one named override survives")
        ck(imported[1].zone == nil, "import fixture: zone is nil (unscoped), not the dead \"\"")
        overrides = imported
        px, py = 0.5, 0.47
        zoneText = "Orgrimmar"
        ck(Tracker.ResolveCoordinateOverride() == "Rend North",
           "import fixture: the imported override RESOLVES at its point")
        zoneText = "Blasted Lands"
        ck(Tracker.ResolveCoordinateOverride() == "Rend North",
           "import fixture: unscoped, so it resolves in any zone")
        px, py = 0.5, 0.53   -- outside the +/-0.02 tolerance box
        ck(Tracker.ResolveCoordinateOverride() == nil,
           "import fixture: outside the tolerance box it does not fire")
    end

    -- ---- 4) agreement with the HUD matcher ---------------------------------
    -- HUD._RendOverrideHit reads the same rules with the lenient form. Where it
    -- is loaded, the two must answer alike for every zone shape.
    if ns.HUD and ns.HUD._RendOverrideHit then
        local rendBox = { { name = "Rend North Staging", zone = "",
                            minX = 0.4, maxX = 0.6, minY = 0.4, maxY = 0.6 } }
        overrides = rendBox
        px, py, zoneText = 0.5, 0.5, "Mulgore"
        local hudHit = ns.HUD._RendOverrideHit(rendBox, zoneText, px, py)
        local trkHit = Tracker.ResolveCoordinateOverride() ~= nil
        ck(hudHit == trkHit,
           "matchers agree on an empty-zone rule (HUD and tracker read one store)")
    end

    end)

    _G.GetRealZoneText, _G.C_Map = savedZone, savedMap
    if ns.Store then ns.Store.GetSettings = savedGS end
    if not ok then fails[#fails + 1] = "error in coordinate-override fixtures: " .. tostring(err) end
end

function Tracker.RunSelfTests(verbose)
    local suites = {
        { name = "state-push change filter (A10.1)", fn = testChangeFilter },
        { name = "hash-after-send rollback", fn = testHashAfterSend },
        { name = "armed safety rescan (30s)", fn = testSafetyRescan },
        { name = "boon parsing", fn = testBoonParsing },
        { name = "boon block (owner 7-line fixture)", fn = testBoonBlock },
        { name = "boon scope (unboonable slots + duration leak)", fn = testBoonScope },
        { name = "boon scope repair + inbound guard", fn = testBoonScopeRepair },
        { name = "boon tooltip scrape coverage (left + right + regions)",
          fn = testBoonScrapeCoverage },
        { name = "live aura matching (apostrophe matrix)", fn = testLiveAuraMatching },
        { name = "spell-ID matching (A6.4/A6.6)", fn = testSpellIDMatching },
        { name = "teardown latch + grace windows", fn = testTeardownLatch },
        { name = "xp/rested capture + logout freeze", fn = testXPCapture },
        { name = "capture guards (A6.1/A6.2/A6.3/A17.2/A9.2)", fn = testCaptureGuards },
        { name = "boon cast lifecycle (A7.1/A7.2/A7.3/A7.4)", fn = testBoonCastLifecycle },
        { name = "boon tooltip reconciliation (A7.5)", fn = testBoonReconcile },
        { name = "boon evidence preservation (the wipe)", fn = testBoonEvidencePreservation },
        { name = "DMF capture edges + debuff push (A8)", fn = testDMFCapture },
        { name = "raid attunement (quest matrix + RaidAttuned tri-state)", fn = testAttunement },
        { name = "coordinate override zone scoping", fn = testCoordinateOverride },
        { name = "impossible-record repair pass", fn = testImpossibleRepair },
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
