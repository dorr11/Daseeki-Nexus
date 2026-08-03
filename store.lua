-- Daseeki Nexus — store.lua
-- The two-SavedVariables data model (spec §2), its defaults, the
-- version-stamped data wipe, retention/sweep rules, and the
-- character-record read/write API consumed by the tracker and (later)
-- the mesh layer.
--
-- SV split (design decision): DaseekiNexusDB holds settings; the
-- churny, large character/timer data lives in DaseekiNexusData so it
-- can be version-wiped independently while settings survive.

local ADDON, ns = ...

local Store = {}
ns.Store = Store

----------------------------------------------------------------------
-- Version / retention constants
----------------------------------------------------------------------

Store.SETTINGS_VERSION = 2     -- R3: alert matrix flipped buff-major -> event-major (migration below)
Store.STORAGE_VERSION  = 1     -- bump wipes character data, keeps timers/social/manualLocations
-- Inventory module owners-graph schema. Versioned independently of
-- STORAGE_VERSION: the graph is additive suite data, not mesh character data, so
-- a character-data wipe must not take the cross-account gold with it.
Store.INVENTORY_SCHEMA = 1

-- Aura-slot source codes (the numeric `source` field on each auraStates slot).
-- LIVE   = captured live from this character's own auras (self, highest trust).
-- RELAYED= arrived over the mesh from a peer (set by the mesh receive path).
-- BOON    = parsed out of a Chronoboon Displacement tooltip (stored/frozen buff);
--           the dashboard renders these durations with a "(Boon)" suffix (item 37).
Store.AURA_SOURCE = { LIVE = 0, RELAYED = 1, BOON = 2 }

local LOG_CAP            = 15
local LOG_EXPIRY         = 48 * 3600     -- 48h
local LOG_DEDUP_WINDOW   = 30            -- 30s
local NOROLE_CAP         = 10            -- per account, evict oldest, never self
local MESH_CAP           = 8             -- accounts
local TOMBSTONE_TTL      = 14 * 86400    -- 14 days
-- A8: the Darkmoon-fortune cooldown model (spec §5). ONLINE_TIME length is what
-- the countdown actually spends: 4h of time spent logged in, decremented on
-- capture ticks and FROZEN while the fortune is stashed in a chronoboon. The
-- OFFLINE_CLEAR threshold (8h + 1 min safety margin) is the separate rule that
-- forgives the cooldown for a character parked offline — and only when it logged
-- out RESTING with DMF not booned (A8.3; the old code applied a flat 8h to every
-- offline record regardless).
local DMF_COOLDOWN_ONLINE = 14400        -- 4h of ONLINE time
local DMF_OFFLINE_CLEAR   = 28860        -- 8h + 60s safety margin, resting-only
Store.DMF_COOLDOWN_ONLINE = DMF_COOLDOWN_ONLINE
Store.DMF_OFFLINE_CLEAR   = DMF_OFFLINE_CLEAR
local WEEK_SECONDS       = 7 * 86400
-- Suite-namespace store (Daseeki.Sync v2, wave N5): retention for the
-- cross-account payloads other suite addons publish through Nexus (e.g. Bags).
local SYNCNS_STALE       = 30 * 86400   -- drop an owner entry not refreshed in 30 days
local SYNCNS_SIZE_WARN   = 64           -- per-namespace owner-count sanity threshold (log only)
-- Wednesday 04:00 as an offset into the server-local week.
-- Calendar weekday: 1=Sunday .. 4=Wednesday. secondsOfWeek uses
-- (weekday-1) full days + hours/minutes/seconds.
local WEEKLY_RESET_OFFSET = (4 - 1) * 86400 + 4 * 3600   -- Wed 04:00 = 273600s

-- The seven tracked raid lockouts, in a fixed order used by the binary
-- schema and every roster view.
Store.RAID_KEYS = { "Naxx", "AQ40", "BWL", "MC", "ZG", "AQ20", "Ony" }

-- The nine Classic Era player classes, fixed order (binary schema index).
Store.CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}

----------------------------------------------------------------------
-- A9.1 — ITEM COOLDOWNS ARE START EPOCHS
--
-- Spec §6: "Remaining is always derived as 3600 - (now - stored start epoch)".
-- We used to store REMAINING SECONDS, which is only as good as the last capture:
-- Store.WriteSelfCharacter re-stamps lastDataUpdate on EVERY capture, and the UI
-- decays the stored remaining against that stamp — so on the live character the
-- elapsed term is always ~0 and the countdown never moves, while a capture that
-- failed to read C_Container wrote 0 and the cooldown vanished. Both failure
-- modes disappear once the record carries WHEN the cooldown started.
--
-- Field model (ADDITIVE — see the SavedVariables note below):
--     hearthstone  epoch rec.hearthstoneCDStart   legacy mirror rec.hearthstoneCD
--     chronoboon   epoch rec.chronoboonCDStart    legacy mirror rec.itemCooldown
-- chronoboonCDStart already existed (A7.2 stamped it on a successful boon cast);
-- this unifies BOTH items onto that one model.
--
-- SAVEDVARIABLES / CHANGELOG NOTE ------------------------------------------
-- The two legacy remaining-seconds fields are STILL WRITTEN on every capture and
-- still carried on the wire. They are the compatibility surface for
--   (a) the u16 wire fields (protocol.lua is frozen — no SCHEMA_VERSION bump),
--   (b) any record written by an older client that has not been re-captured yet,
--   (c) Mesh.StateHashInput, which coarsens them by 300s.
-- Keep them for ONE RELEASE CYCLE, then delete the mirrors, drop the legacy
-- branch of Store.ItemCdRemaining, and convert the wire fields at the boundary
-- only (Store.WireItemCd / Store.AdoptWireCooldowns already isolate that).
----------------------------------------------------------------------

-- Both tracked item cooldowns are 60 minutes in Classic Era.
local ITEM_CD_HEARTHSTONE = 3600
local ITEM_CD_CHRONOBOON  = 3600

-- Spec §6 sanity gates on any API-derived cooldown, shared by every writer.
Store.ITEM_CD_GCD_MAX   = 1.5    -- duration <= this is the global cooldown, not an item CD
Store.ITEM_CD_ABSURD    = 7200   -- duration > this is loading-screen garbage
Store.ITEM_CD_SKEW      = 5      -- epoch acceptance window: [now - duration - 5, now + 5]
-- An API-derived start epoch only DISPLACES a stored one when it is newer by
-- more than this. Re-reading a live cooldown reproduces the same start ±1s of
-- rounding; without the margin that jitter would creep the stamp forward and
-- silently extend the cooldown. A real re-use (or the instance-kick reset the
-- spec calls out) moves the start by minutes, so it always clears the bar.
Store.ITEM_CD_RESET_SLACK = 2

-- which -> { epoch field, legacy remaining-seconds field, duration }
local ITEM_CD = {
    hearthstone = { epoch = "hearthstoneCDStart", legacy = "hearthstoneCD", duration = ITEM_CD_HEARTHSTONE },
    chronoboon  = { epoch = "chronoboonCDStart",  legacy = "itemCooldown",  duration = ITEM_CD_CHRONOBOON },
}
Store.ITEM_CD_KEYS = { "hearthstone", "chronoboon" }
Store.ITEM_CD_DURATION = {
    hearthstone = ITEM_CD_HEARTHSTONE,
    chronoboon  = ITEM_CD_CHRONOBOON,
}

local U16_MAX = 65535

function Store.ItemCdSpec(which) return ITEM_CD[which] end

----------------------------------------------------------------------
-- Time helpers
----------------------------------------------------------------------

-- Server epoch (GetServerTime is catalog-verified). Falls back to time()
-- only if the modern call is somehow unavailable.
local function serverNow()
    if GetServerTime then return GetServerTime() end
    return time()
end
Store.Now = serverNow

-- Epoch of the most recent Wednesday-04:00 server-local boundary at or
-- before `now`. Uses the calendar's weekday/hour so it honours the
-- server's local week rather than the client's UTC offset.
local function lastWeeklyResetBoundary(now)
    now = now or serverNow()
    local cal = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime
              and C_DateAndTime.GetCurrentCalendarTime() or nil
    if not cal or not cal.weekday then
        -- Conservative fallback: no boundary known, treat now as boundary.
        return now
    end
    local secondsOfWeek = (cal.weekday - 1) * 86400
        + (cal.hour or 0) * 3600
        + (cal.minute or 0) * 60
        + (cal.second or 0)
    local delta = (secondsOfWeek - WEEKLY_RESET_OFFSET) % WEEK_SECONDS
    return now - delta
end
Store.LastWeeklyResetBoundary = lastWeeklyResetBoundary

----------------------------------------------------------------------
-- Defaults trees
----------------------------------------------------------------------

-- Per-faction settings block. Horde receives threshold overrides applied
-- after this base is copied (see buildFactionSettings).
local function defaultFactionBlock()
    return {
        autoGroup = {
            acceptFromRoster  = true,
            acceptFromGuild   = true,
            acceptFromFriends = true,
            acceptFromAnyone  = false,
            -- Per-category whisper-invite SEND gates (item 22). The N4a build
            -- collapsed sends to a single roster gate; the reference gates each
            -- trust category independently, matching the four accept-from gates.
            sendToRoster      = true,
            sendToGuild       = false,
            sendToFriends     = false,
            sendToAnyone      = false,
            inviteKeyword     = "inv",
            whitelist         = {},          -- ["Name-Realm"] = true
            whitelistEnabled  = true,        -- master gate for whitelist bypass (item 35)
            defaultsApplied   = false,       -- one-time seeding guard
        },
        autoSummon = {
            -- Master toggle. The spec defaults this ON; the OWNER chose to ship
            -- it OFF ("seed the triggers, but don't auto-accept until I say so").
            -- The trigger set below is still seeded so that flipping this one
            -- checkbox gives the full spec'd behaviour with no further setup.
            enabled        = false,
            alwaysAccept   = false,
            freshBuffWindow = 19,            -- seconds; accept if a buff is <19s old
            -- Left EMPTY here on purpose, exactly like auraOpts.thresholds: the
            -- seven spec'd ON triggers are installed once by
            -- Store.SeedAutoSummonDefaults under the `defaultsApplied` guard
            -- below. If they lived in this tree, applyDefaults would resurrect
            -- every trigger the owner unchecked on the next login (the options
            -- UI writes an unchecked box as nil, so "off" IS absence here).
            triggers       = {},             -- ["triggerKey"] = true
            dropOnTaxiPvp  = true,
            -- Sticky one-time seeding guard, mirroring auraOpts.defaultsApplied.
            defaultsApplied = false,
        },
        autoGossip = {
            dmt = false,                     -- Dire Maul tribute guard
            bwl = false,                     -- Orb of Command
            dmf = {                          -- Sayge's Dark Fortune
                enabled   = false,
                buffType  = {},              -- ["CLASS"] = "damage"/"stats"/...
                skipCookie = false,
            },
        },
        autoQuest = {
            eko       = false,
            zgCoins   = false,
            zanza     = { enabled = false, priority = {} },
            roids     = false,
            autoRepair = false,
        },
        -- autoInteract removed: the Interact Buttons feature was cut pre-release.
        auraOpts = {
            -- per-aura normal/minimum duration thresholds (seconds).
            -- Left EMPTY here on purpose: the nine per-aura, per-faction pairs
            -- (spec §4.6) are installed once by Store.SeedAuraDefaults under the
            -- `defaultsApplied` guard below, NOT by applyDefaults. If they lived
            -- in this tree, applyDefaults would resurrect any row the owner
            -- deliberately deleted on every single login.
            thresholds = {},                 -- ["auraKey"] = { normal=, minimum= }
            -- per-class required/optional/ignored maps for Rend & Battle Shout.
            -- Also empty here and seeded once (spec §4.7) for the same reason.
            rend        = { required = {}, optional = {}, ignored = {} },
            battleShout = { required = {}, optional = {}, ignored = {} },
            -- Slip'kik's Savvy (DMT SP): physical damage users typically don't
            -- want it, so Warrior/Rogue/Hunter default to IGNORED (hidden from
            -- their cards); every caster/hybrid defaults to OPTIONAL (greyed,
            -- no border, when missing). Owner-adjustable in the Auras page; the
            -- three maps carry all 9 classes explicitly so the defaults are
            -- self-documenting (absence would also read as ignored). Faction
            -- filtering happens in the UI, so both factions share these seeds.
            dmtSP       = {
                required = {},
                optional = { MAGE = true, WARLOCK = true, PRIEST = true,
                             DRUID = true, PALADIN = true, SHAMAN = true },
                ignored  = { WARRIOR = true, ROGUE = true, HUNTER = true },
            },
            -- Sticky one-time seeding guard for thresholds + rend/battleShout
            -- class maps (mirrors autoGroup.defaultsApplied above). Once true it
            -- is never re-examined, so an owner who clears a threshold row or
            -- demotes a class keeps that choice across every future login.
            defaultsApplied = false,
        },
    }
end

local function buildFactionSettings()
    local alliance = defaultFactionBlock()
    local horde    = defaultFactionBlock()
    -- NOTE: a previous build tightened the Horde fresh-buff window to 15 s with
    -- the rationale "Rend/Warchief's is a Horde-native buff". That override has
    -- no basis in the spec -- SN §13 quotes a flat "fresh-buff window: 19
    -- seconds" for both factions, and the Horde/Alliance split covers aura
    -- THRESHOLDS only (see AURA_THRESHOLD_SEEDS). The override is removed so a
    -- fresh install matches the spec on both sides. This is fresh-install only:
    -- applyDefaults never overwrites a key that already exists, so an existing
    -- Horde SavedVariables file keeps whatever window it already stored.
    return { Alliance = alliance, Horde = horde }
end

----------------------------------------------------------------------
-- Aura threshold + class-requirement SEEDS (spec §4.6 / §4.7)
--
-- These are the "first run" values, deliberately kept OUT of the defaults
-- tree (see defaultFactionBlock) so applyDefaults can never resurrect a row
-- the owner removed. Store.SeedAuraDefaults installs them exactly once per
-- faction, gated by factionSettings[F].auraOpts.defaultsApplied.
--
-- UNITS: the store keeps thresholds in SECONDS. The options Auras page
-- displays and edits them in MINUTES (it divides by 60 on read and
-- multiplies by 60 on write, options.lua buildAuras), and the spec quotes
-- minutes — so every pair below is spec-minutes * 60.
--
-- Spec §4.6 (minutes, normal/minimum):
--   Alliance: DMF 117/59 · Ony 89/59 · DMT AP 89/59 · DMT SP 89/59 ·
--             DMT STAM 89/59 · SF 58/57 · ZG 89/59 · Rend 58/57 · BS 13/12
--   Horde:    DMF 117/60 · Ony 95/90 · DMT AP 95/90 · DMT SP 95/90 ·
--             DMT STAM 95/90 · SF 58/57 · ZG 95/90 · Rend 58/57 · BS 13/12
-- (FFF has no thresholds, and neither do the two tail slots Silithyst /
-- Boon of Blackfathom — they carry thresholdKey = nil in AURA_META.)
--
-- KEYS are the exact aura keys shared by options.lua AURA_DEFS,
-- import.lua AURA_SLOT_KEY and ui_shell.lua AURA_META.thresholdKey:
--   dmf, ony, dmtAP, dmtSP, dmtStam, songflower, zg, rend, battleShout
----------------------------------------------------------------------

local M = 60   -- spec quotes minutes; the store holds seconds

Store.AURA_THRESHOLD_SEEDS = {
    Alliance = {
        dmf         = { normal = 117 * M, minimum = 59 * M },   -- 7020 / 3540
        ony         = { normal =  89 * M, minimum = 59 * M },   -- 5340 / 3540
        dmtAP       = { normal =  89 * M, minimum = 59 * M },   -- 5340 / 3540
        dmtSP       = { normal =  89 * M, minimum = 59 * M },   -- 5340 / 3540
        dmtStam     = { normal =  89 * M, minimum = 59 * M },   -- 5340 / 3540
        songflower  = { normal =  58 * M, minimum = 57 * M },   -- 3480 / 3420
        zg          = { normal =  89 * M, minimum = 59 * M },   -- 5340 / 3540
        rend        = { normal =  58 * M, minimum = 57 * M },   -- 3480 / 3420
        battleShout = { normal =  13 * M, minimum = 12 * M },   --  780 /  720
    },
    Horde = {
        dmf         = { normal = 117 * M, minimum = 60 * M },   -- 7020 / 3600
        ony         = { normal =  95 * M, minimum = 90 * M },   -- 5700 / 5400
        dmtAP       = { normal =  95 * M, minimum = 90 * M },   -- 5700 / 5400
        dmtSP       = { normal =  95 * M, minimum = 90 * M },   -- 5700 / 5400
        dmtStam     = { normal =  95 * M, minimum = 90 * M },   -- 5700 / 5400
        songflower  = { normal =  58 * M, minimum = 57 * M },   -- 3480 / 3420
        zg          = { normal =  95 * M, minimum = 90 * M },   -- 5700 / 5400
        rend        = { normal =  58 * M, minimum = 57 * M },   -- 3480 / 3420
        battleShout = { normal =  13 * M, minimum = 12 * M },   --  780 /  720
    },
}

-- Spec §4.7 per-class expectation seeds.
--   Rend (Warchief's Blessing): Warrior + Rogue required, EVERY other class
--     optional (warn-when-missing, never red).
--   Battle Shout: Warrior + Rogue required, every other class ignored
--     (hidden). The spec's reference table only lists War/Rogue/Hunter and
--     treats any unlisted class as ignored; we write all nine explicitly so
--     the shipped default is self-documenting in the Auras page. Absence and
--     an explicit `ignored` entry are behaviourally identical -- see
--     Dashboard.ClassRuleState, which falls through to "ignored".
--   DMT SP (Slip'kik's Savvy) is NOT seeded here: the spec gives it no
--     required/optional/ignored defaults, and our defaults tree already ships
--     an owner-approved caster/physical split (see defaultFactionBlock).
-- Both factions share these class rules (class expectations are not faction-
-- dependent; the Horde/Alliance split only affects thresholds).

local function classMapSeed(required, otherState)
    local req, opt, ign = {}, {}, {}
    local isReq = {}
    for _, c in ipairs(required) do isReq[c] = true; req[c] = true end
    for _, c in ipairs(Store.CLASS_ORDER) do
        if not isReq[c] then
            if otherState == "optional" then opt[c] = true else ign[c] = true end
        end
    end
    return { required = req, optional = opt, ignored = ign }
end

Store.CLASS_RULE_SEEDS = {
    rend        = classMapSeed({ "WARRIOR", "ROGUE" }, "optional"),
    battleShout = classMapSeed({ "WARRIOR", "ROGUE" }, "ignored"),
}

-- True when a required/optional/ignored map carries no class at all.
local function classMapEmpty(o)
    if type(o) ~= "table" then return true end
    for _, bucket in ipairs({ "required", "optional", "ignored" }) do
        local t = o[bucket]
        if type(t) == "table" and next(t) ~= nil then return false end
    end
    return true
end

local function copyPairs(src)
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            local inner = {}
            for k2, v2 in pairs(v) do inner[k2] = v2 end
            out[k] = inner
        else
            out[k] = v
        end
    end
    return out
end

----------------------------------------------------------------------
-- One-time seeding of aura thresholds + Rend/Battle Shout class rules.
--
-- ADDITIVE ONLY, and sticky. For each faction:
--   * `auraOpts.defaultsApplied` already true -> do nothing at all. This is
--     what keeps a deleted threshold row or a demoted class deleted.
--   * thresholds table completely empty -> install all nine pairs.
--     Non-empty (an older DB the owner already configured) -> left EXACTLY
--     as-is; we never merge into a table the owner has touched.
--   * rend / battleShout maps with no class in any of the three buckets ->
--     install the seed. Any class already present -> left as-is.
--   * Then stamp defaultsApplied = true so this never runs again.
--
-- Nothing is ever deleted or rewritten, so this satisfies the release-safety
-- rule against destructive SavedVariables migrations. Safe to call repeatedly.
----------------------------------------------------------------------

function Store.SeedAuraDefaults(db)
    if type(db) ~= "table" then return end
    local fsAll = db.factionSettings
    if type(fsAll) ~= "table" then return end

    for faction, seeds in pairs(Store.AURA_THRESHOLD_SEEDS) do
        local fs = fsAll[faction]
        local ao = type(fs) == "table" and fs.auraOpts or nil
        if type(ao) == "table" and not ao.defaultsApplied then
            -- Thresholds: only when genuinely unseeded (empty table).
            if type(ao.thresholds) ~= "table" then ao.thresholds = {} end
            if next(ao.thresholds) == nil then
                for key, pair in pairs(seeds) do
                    ao.thresholds[key] = { normal = pair.normal, minimum = pair.minimum }
                end
            end
            -- Class rules: only when no class is configured in any bucket.
            for optKey, seed in pairs(Store.CLASS_RULE_SEEDS) do
                if classMapEmpty(ao[optKey]) then
                    ao[optKey] = copyPairs(seed)
                end
            end
            ao.defaultsApplied = true
        end
    end
end

----------------------------------------------------------------------
-- Auto-summon TRIGGER seeds (spec §13)
--
-- Spec §13: "Per-slot buff triggers decide what counts as a fresh buff.
--   Defaults ON:  DMF, Ony, Songflower, ZG, Rend, Battle Shout, FFF.
--   Defaults OFF: DMT AP, DMT SP, DMT STAM."
--
-- KEY NAMESPACE WARNING: the trigger keys are NOT the aura/threshold keys used
-- by AURA_THRESHOLD_SEEDS. The authoritative catalog is
-- Auto.SUMMON_TRIGGER_BUFFS (auto.lua), which names them after the buff's aura
-- rather than its source, and import.lua maps the SN positional slots onto the
-- same names. The mapping is:
--     DMF          -> "dmf"
--     Ony          -> "dragonslayer"   (Rallying Cry of the Dragonslayer)
--     ZG           -> "zandalar"       (Spirit of Zandalar)
--     Songflower   -> "songflower"
--     Rend         -> "warchief"       (Warchief's Blessing)
--     Battle Shout -> "battleShout"
--     FFF          -> "fff"            (seasonal)
--     DMT AP/STAM/SP -> "fengus" / "moldar" / "slipkik"   <- deliberately NOT seeded
--
-- Only the seven ON triggers are listed. The three DMT triggers are seeded by
-- OMISSION, not by an explicit `false`, because absence IS "off" throughout this
-- feature: options.lua writes an unchecked box as `triggers[key] = nil`, and
-- auto.lua tests `triggers[key]` for truthiness. Writing `false` would produce a
-- row the UI can never reproduce, so the seeded table is byte-identical to what
-- an owner would get by ticking those seven boxes by hand.
----------------------------------------------------------------------

Store.SUMMON_TRIGGER_SEEDS = {
    "dmf", "dragonslayer", "zandalar", "songflower",
    "warchief", "battleShout", "fff",
}

-- All TEN live trigger keys, mirroring Auto.SUMMON_TRIGGER_BUFFS (auto.lua owns
-- the catalog; this is the store's copy so seeding does not depend on load
-- order). Used to tell a real trigger from a DEAD one: options.lua shipped the
-- six aura keys ("ony"/"zg"/"rend"/"dmtAP"/"dmtSP"/"dmtStam") on its trigger
-- checkboxes, so an install from before this batch can hold ticks that
-- Auto.ScanTriggerBuffs never reads. A store selftest asserts this list matches
-- the catalog exactly, so the two cannot drift.
Store.SUMMON_TRIGGER_KEYS = {
    "dmf", "dragonslayer", "zandalar", "songflower", "warchief",
    "battleShout", "fff", "fengus", "moldar", "slipkik",
}

-- Does this triggers table hold at least one key the engine actually reads?
-- A table that is empty -- OR that holds nothing but dead pre-batch aura keys --
-- counts as unseeded, because in both cases the owner has zero working triggers
-- and seeding is purely additive. Any LIVE key means the owner has a real,
-- working selection, and we never merge into it.
local function triggersUnseeded(t)
    if type(t) ~= "table" then return true end
    local live = {}
    for _, k in ipairs(Store.SUMMON_TRIGGER_KEYS) do live[k] = true end
    for k, v in pairs(t) do
        if v and live[k] then return false end
    end
    return true
end
Store._triggersUnseeded = triggersUnseeded

-- Spec §13 fresh-buff window, in seconds. Seeded only when the key is ABSENT;
-- the defaults tree already carries it for both factions, so in practice this
-- only rescues a hand-edited or partially-migrated SavedVariables file.
Store.SUMMON_FRESH_WINDOW_SEED = 19

----------------------------------------------------------------------
-- One-time seeding of the auto-summon trigger set.
--
-- Same contract as Store.SeedAuraDefaults -- ADDITIVE ONLY, and sticky. Per
-- faction:
--   * `autoSummon.defaultsApplied` already true -> do nothing at all. This is
--     what keeps an unchecked trigger unchecked forever.
--   * triggers table holding no LIVE trigger -> install the seven spec'd ON
--     triggers. "No live trigger" means empty, or holding nothing but the dead
--     aura keys options.lua wrote before this batch (see triggersUnseeded).
--     Any working trigger present -> left EXACTLY as-is; we never merge into a
--     table the owner has a real selection in. Dead keys are left in place
--     rather than deleted, per the no-destructive-migrations rule; they are
--     inert and the UI no longer offers a way to make more.
--   * freshBuffWindow absent -> install 19. An existing value is never touched.
--   * Then stamp defaultsApplied = true so this never runs again.
--
-- DELIBERATELY DOES NOT TOUCH `enabled`. The owner's decision for this batch is
-- "seeds without enable": the trigger set ships pre-checked so the feature is
-- one click away, but auto-accept itself stays OFF until the owner turns it on.
-- A fresh install must therefore show seven ticked Buff Triggers AND an unticked
-- "Auto-accept summon".
--
-- Nothing is ever deleted or rewritten, so this satisfies the release-safety
-- rule against destructive SavedVariables migrations. Safe to call repeatedly.
----------------------------------------------------------------------

function Store.SeedAutoSummonDefaults(db)
    if type(db) ~= "table" then return end
    local fsAll = db.factionSettings
    if type(fsAll) ~= "table" then return end

    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local fs = fsAll[faction]
        local as = type(fs) == "table" and fs.autoSummon or nil
        if type(as) == "table" and not as.defaultsApplied then
            if type(as.triggers) ~= "table" then as.triggers = {} end
            if triggersUnseeded(as.triggers) then
                for _, key in ipairs(Store.SUMMON_TRIGGER_SEEDS) do
                    as.triggers[key] = true
                end
            end
            if as.freshBuffWindow == nil then
                as.freshBuffWindow = Store.SUMMON_FRESH_WINDOW_SEED
            end
            as.defaultsApplied = true
        end
    end
end

-- Default coordinate overrides (spec: up to 15; ships with the three canonical
-- staging/DMF rules). Each rule maps an optional zone + coord box to a human
-- label shown in the dashboard location column.
--
-- A17.3 — these seeds shipped ~12x oversized. The reference defines each default
-- as a POINT + tolerance 0.02 (a 0.04 x 0.04 box, ~0.16% of the map); ours were
-- hand-written as 0.25 x 0.25 / 0.20 x 0.20 rectangles, so a quarter of Orgrimmar
-- matched "Rend North Staging" and characters standing anywhere near the middle
-- of the city reported their location as "Rend Staging (N)". The centres had
-- drifted too — every one of the three was wrong, not merely wide.
--
-- Both are now taken from the reference's three default rules:
--     Rend North   (0.509452, 0.475196) tol 0.02
--     Rend South   (0.491113, 0.683181) tol 0.02
--     Mulgore DMF  (0.447506, 0.592198) tol 0.02
--
-- ZONE SCOPING: the reference matches on coordinates alone. We keep our zone
-- scope ONLY for the DMF rule, whose name names its zone. The two Rend rules are
-- left UNSCOPED (`zone` omitted -> nil), because a wrong zone guess makes an
-- override silently dead, and at ±0.02 the box is doing the work anyway. nil is
-- deliberate rather than "": the location matcher treats nil as unscoped, while
-- "" compares unequal to every real zone name.
local COORD_TOL = 0.02
local function box(x, y, tol)
    tol = tol or COORD_TOL
    return x - tol, x + tol, y - tol, y + tol
end

local function defaultCoordinateOverrides()
    local nX1, nX2, nY1, nY2 = box(0.509452, 0.475196)
    local sX1, sX2, sY1, sY2 = box(0.491113, 0.683181)
    local mX1, mX2, mY1, mY2 = box(0.447506, 0.592198)
    return {
        { name = "Rend North Staging",
          minX = nX1, maxX = nX2, minY = nY1, maxY = nY2, label = "Rend Staging (N)" },
        { name = "Rend South Staging",
          minX = sX1, maxX = sX2, minY = sY1, maxY = sY2, label = "Rend Staging (S)" },
        { name = "DMF Mulgore", zone = "Mulgore",
          minX = mX1, maxX = mX2, minY = mY1, maxY = mY2, label = "Darkmoon Faire" },
    }
end
Store.DefaultCoordinateOverrides = defaultCoordinateOverrides

-- Default class hex colors (Blizzard Classic palette). Kept as an
-- override table; the dashboard falls back to RAID_CLASS_COLORS when a
-- class is absent here.
local function defaultClassColors()
    return {
        WARRIOR = "C79C6E", PALADIN = "F58CBA", HUNTER = "ABD473",
        ROGUE   = "FFF569", PRIEST  = "FFFFFF", SHAMAN = "0070DE",
        MAGE    = "69CCF0", WARLOCK = "9482C9", DRUID  = "FF7D0A",
    }
end

-- The alert matrix (R3 item 13/14/24). EVENT-MAJOR:
--   alerts[eventType][buffKey] = { notify, chat, flash, sound = <soundKey> }
-- (was buff-major with a boolean `sound`; migrated in-place by MigrateSettings.)
-- `sound` is now a HUD.SOUNDS *key* string per row ("None" = silent), so every
-- buff row on every event can carry its own tone (item 14). Each event lists the
-- buff rows the reference shows for it (item 24 — buff gain gains DMF, pull gains
-- Battle Shout, CD is Ony/Rend, NPC events are Ony/Nef).
local ALERT_EVENT_TYPES = {
    "questHandin", "pullTimer", "npcDied", "npcRespawned",
    "cdWarning", "cdExpired", "buffGain",
}
-- All buff-row keys the alert matrix can carry (superset across events).
local ALERT_BUFF_KEYS = {
    "rend", "onyH", "onyA", "nefH", "nefA", "zg", "battleShout", "dmf",
}
-- Per-event buff-row sets (reference-aligned; item 24).
local ALERT_EVENT_BUFFS = {
    questHandin  = { "rend", "onyH", "onyA", "nefH", "nefA", "zg" },
    pullTimer    = { "rend", "onyH", "onyA", "nefH", "nefA", "zg", "battleShout" },
    npcDied      = { "onyH", "onyA", "nefH", "nefA" },
    npcRespawned = { "onyH", "onyA", "nefH", "nefA" },
    cdWarning    = { "rend", "onyH", "onyA" },
    cdExpired    = { "rend", "onyH", "onyA" },
    buffGain     = { "rend", "onyH", "onyA", "nefH", "nefA", "zg", "battleShout", "dmf" },
}
-- Default per-event sound key (a HUD.SOUNDS key). Seeds every row's sound.
local ALERT_EVENT_SOUND = {
    questHandin  = "QuestListOpen",
    pullTimer    = "RaidWarning",
    npcDied      = "TellMessage",
    npcRespawned = "TellMessage",
    cdWarning    = "AuctionWindowOpen",
    cdExpired    = "ReadyCheck",
    buffGain     = "CheckboxOn",
}

-- F12 (spec §11): "Nefarian quest hand-in additionally flashes." The Nef hand-in
-- is the one event a raid lead can miss while tabbed out — it is not on a
-- cooldown clock, so there is no second chance to catch it — and it is the only
-- row the reference ships with the client-icon flash channel on by default.
local ALERT_DEFAULT_FLASH = {
    questHandin = { nefH = true, nefA = true },
}

local function defaultAlertMatrix()
    local matrix = {}
    for _, evt in ipairs(ALERT_EVENT_TYPES) do
        local perBuff = {}
        local snd = ALERT_EVENT_SOUND[evt] or "RaidWarning"
        local flashRows = ALERT_DEFAULT_FLASH[evt]
        for _, buff in ipairs(ALERT_EVENT_BUFFS[evt]) do
            perBuff[buff] = {
                notify = true, chat = false,
                flash  = (flashRows and flashRows[buff]) == true,
                sound  = snd,
            }
        end
        matrix[evt] = perBuff
    end
    return matrix
end

local function defaultTimerSettings()
    return {
        felwood = {
            showFlowerPins = true,
            showTuberPins  = true,
            -- Legacy single sizes kept for back-compat with any older reader.
            worldPinSize   = 14,
            minimapPinSize = 12,
            -- Full 5-field pin sizing (item 26): worldmap songflower/tuber px,
            -- worldmap timer font pt, minimap songflower/tuber px. pins.lua +
            -- options.lua consume these (published in SURFACES). Defaults keep the
            -- prior single-size look (14 world / 12 minimap, 10pt timer font).
            worldFlowerSize   = 14,
            worldTuberSize    = 14,
            worldTimerFont    = 10,
            minimapFlowerSize = 12,
            minimapTuberSize  = 12,
            -- Songflower display durations (seconds) consumed by the timers-tab
            -- UP?/minus state machine (timers.lua NodeState). Songflower respawn
            -- is 25 minutes, so minus-timer = 1500s (matches Timers.NODE_RESPAWN)
            -- and UP? window = 0 (indefinite, matching NodeState semantics). The
            -- earlier 120/5 defaults decayed a live node to "No data" ~125s after
            -- a pick; MigrateSongflowerDefaults rewrites any SV still holding them.
            flowerMinusDuration = 1500,
            flowerUpDuration    = 0,
        },
        pullBar = {
            width   = 220,
            height  = 18,
            anchor  = "CENTER",
            offsetX = 0,
            offsetY = 160,
            locked  = true,
            colorFill = "b02020",   -- token-resolved at render; stored as hex seed
            colorBG   = "202020",
            -- Idle/small-bar geometry + expand trigger. Defaults match hud.lua's
            -- runtime fallbacks (smallWidth = floor(width*0.72+0.5)=158,
            -- smallHeight = max(12, height-4)=14, expandThreshold = 10s).
            smallWidth      = 158,
            smallHeight     = 14,
            expandThreshold = 10,
        },
        soundChannel = "Master",
        soundKeys = {
            pullTimer   = "RaidWarning",
            cdWarning   = "AuctionWindowOpen",
            npcDied     = "TellMessage",
            npcRespawned = "TellMessage",
        },
        alerts = defaultAlertMatrix(),
        raidDisable = {
            notify = true,   -- suppress on-screen notify while in a raid instance
            chat   = false,
            flash  = true,
            sound  = false,
        },
        -- Per-buff manual pull-window overrides (seconds). Empty by default; when
        -- a buff key is set here (a number pins both yell stages, or a table
        -- {[1]=,[2]=} pins per stage) the timer engine's EffectivePullWindow uses
        -- it ahead of the observed median and the seeded default. No options UI
        -- this pass — the engine only READS this key. ADDITIVE.
        pullWindows = {},
    }
end

local function defaultSettings()
    return {
        settingsVersion = Store.SETTINGS_VERSION,
        autoConvertToRaid = false,
        autoAssistAll     = false,
        hardThrottle      = false,
        -- Instances tab: chat warning on entry when the account hits the hourly
        -- warn threshold ("4 of 5 hourly instances used."). Default ON. ADDITIVE;
        -- the engine only READS this key — the options UI lands with the tab wave.
        instancesWarnOnEntry = true,
        -- A8.4: when the debuff bar pushes the hidden DMF cooldown aura off,
        -- announce it publicly (SAY, plus RAID/PARTY when grouped) so the raid
        -- knows everyone's fortune just came back up. Default ON per the spec.
        -- ADDITIVE and read through Tracker.DMFPushAnnounceEnabled, which treats
        -- an ABSENT key as ON — so an existing SavedVariables file behaves the
        -- same as a fresh one. FLAGGED: the options UI checkbox for this lives in
        -- options.lua, which this batch does not own.
        dmfPushAnnounce   = true,
        -- Inventory module (inventory.lua): cross-account item counts + gold.
        -- Default ON, and Inventory.IsEnabled treats an ABSENT key as ON too, so
        -- a SavedVariables file written before this key existed behaves exactly
        -- like a fresh one. ADDITIVE — no settingsVersion bump needed.
        inventoryEnabled  = true,
        accountID         = "",           -- user sets via /dsn account
        minimap = {
            hide = false,
            lock = false,
            -- free-floating button (NOT minimap-anchored, per §9)
            point = "CENTER", x = 0, y = 200,
        },
        mesh = {
            token       = "",
            channel     = "",                -- required user-set channel name (item 38);
                                             -- mesh stays down until channel + token are set
            enabled     = false,
            optOut      = false,
            bondChannels = { "", "", "" },   -- unimplemented slots preserved for parity
            autoLeaveChannel = true,
        },
        coordinateOverrides = defaultCoordinateOverrides(),
        classColors         = defaultClassColors(),
        factionSettings     = buildFactionSettings(),
        timerSettings       = defaultTimerSettings(),
        ui = {
            summonerSortDir  = "asc",
            selectedCharacter = "",
            blacklist = {},    -- ["Name-Realm"] = true
            whitelist = {},    -- ["Name-Realm"] = true
        },
    }
end

-- Fresh, empty data DB shell.
local function defaultData()
    return {
        version  = Store.STORAGE_VERSION,
        accounts = {},          -- [aid] = accountBucket ; "" is the orphan bucket
        timers = {
            flower = {},        -- [1..10] = popEpoch
            tuber  = {},        -- [1..6]  = popEpoch
            logs   = { rend = {}, onyH = {}, onyA = {} },
            -- Pull auto-calibration: [buffKey][yellNum] = { observedSeconds, ... }
            -- (newest last, capped in the timer engine). ADDITIVE; the engine
            -- also lazily creates this so it appears on pre-existing saves.
            pullObservations  = {},
            timerVersion      = 1,
            lastWeeklyResetAt = 0,
        },
        caches = {
            localBoon  = {},    -- ["Name-Realm"] = encoded snapshot
            tooltipBoon = {},   -- ["Name-Realm"] = encoded snapshot
        },
        manualLocations = {},   -- ["Name-Realm"] = "label" (legacy location override; retained, no longer edited via UI)
        notes = {},             -- ["Name-Realm"] = "free-text note" (replaces the location-override concept)
        notesMigrated = false,  -- one-time marker: legacy manualLocations copied into empty notes
        instances = {},         -- [aid] = { ["Name-Realm"] = { entries = { {t,name,mapID,dur,gold,xp,merged}, ... capped 60 } } }
                                -- instance-entry ledger (NEXUS_INSTANCES_DESIGN). ADDITIVE; version-wipe-preserved like notes.
        social = {
            guild   = {},       -- ["Name-Realm"] = true
            friends = {},       -- ["Name-Realm"] = true
        },
        deletedAIDs = {},       -- [aid] = tombstoneEpoch (local-only, never broadcast)
        -- Suite-namespace store (Daseeki.Sync v2, wave N5). Each consuming
        -- addon owns a namespace key; every data owner (a character or account,
        -- depending on the namespace) has one revision-stamped payload here.
        --   syncNamespaces[nsKey][ownerKey] = { rev, updatedAt, data }
        -- Mesh-transported, revision-gated, store-and-forward; persists so a
        -- peer's data survives relogs and can be served to newly-appearing peers.
        syncNamespaces = {},
        -- Legacy key-value lane retained for Daseeki.Config's offline catch-up
        -- (the helper file-mirror is retired; this now lives in the SV instead
        -- of the vanished DaseekiWoWHelperRemote global).
        syncKV = {},
        -- One-time idempotent guard for the wave-N5 Bags import (see MigrateBags).
        bagsImported = false,
        -- Inventory module owners graph (inventory.lua). ADDITIVE and
        -- schema-versioned independently of STORAGE_VERSION, so it can grow
        -- without touching the character-data wipe contract.
        --   owners[ownerKey] = { rev, updatedAt, data = <"bags" payload> }
        --   parts[nameRealm] = { bank, mail, mailN, mailMoney, bankAt, mailAt }
        --     — our own cold components (bank + mail are only readable while
        --       their frame is open, so their counts are kept between visits).
        --   migrated         — sticky one-time Daseeki-Bags 1.x import guard.
        --       Set ONLY after a non-empty import; an absent or empty source
        --       leaves it clear so a later Bags install still migrates.
        inventory = {
            schema   = Store.INVENTORY_SCHEMA,
            owners   = {},
            parts    = {},
            migrated = false,
        },
    }
end

Store.ALERT_BUFF_KEYS    = ALERT_BUFF_KEYS
Store.ALERT_EVENT_TYPES  = ALERT_EVENT_TYPES
Store.ALERT_EVENT_BUFFS  = ALERT_EVENT_BUFFS   -- per-event buff-row sets (UI/hud)
Store.ALERT_EVENT_SOUND  = ALERT_EVENT_SOUND   -- per-event default sound key

----------------------------------------------------------------------
-- Defaults application (recursive fill, never clobbers existing values)
----------------------------------------------------------------------

local function applyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then
                target[k] = {}
            end
            applyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end
Store.ApplyDefaults = applyDefaults

----------------------------------------------------------------------
-- Settings migration (settingsVersion 1 -> 2)
--
-- v1 stored the alert matrix BUFF-MAJOR with a boolean `sound`:
--     alerts[buffKey][eventType] = { notify, chat, flash, sound=bool }
-- v2 stores it EVENT-MAJOR with a per-row sound KEY (item 13/14/24):
--     alerts[eventType][buffKey] = { notify, chat, flash, sound=<soundKey> }
-- The transpose preserves every channel toggle a user set; a v1 sound=true maps
-- to that event's default sound key, sound=false/absent maps to "None".
-- Idempotent + shape-detected, so it is safe if settingsVersion is missing.
----------------------------------------------------------------------

function Store.MigrateSettings(db)
    if type(db) ~= "table" then return end
    if (db.settingsVersion or 1) >= 2 then return end   -- already current

    local ts = db.timerSettings
    local alerts = ts and ts.alerts
    -- Old buff-major shape: top-level keys are buff keys, not event types.
    local looksBuffMajor = type(alerts) == "table"
        and alerts.questHandin == nil
        and (alerts.rend ~= nil or alerts.onyH ~= nil or alerts.zg ~= nil
             or alerts.battleShout ~= nil)
    if looksBuffMajor then
        local newM = {}
        for _, evt in ipairs(ALERT_EVENT_TYPES) do newM[evt] = {} end
        for buffKey, perEvent in pairs(alerts) do
            if type(perEvent) == "table" then
                for evt, cell in pairs(perEvent) do
                    if newM[evt] and type(cell) == "table" then
                        local snd = (cell.sound == true)
                            and (ALERT_EVENT_SOUND[evt] or "RaidWarning") or "None"
                        newM[evt][buffKey] = {
                            notify = cell.notify and true or false,
                            chat   = cell.chat and true or false,
                            flash  = cell.flash and true or false,
                            sound  = snd,
                        }
                    end
                end
            end
        end
        ts.alerts = newM
    end

    db.settingsVersion = Store.SETTINGS_VERSION
end

----------------------------------------------------------------------
-- Songflower display-duration correction (owner-confirmed).
--
-- An earlier build shipped flowerMinusDuration=120 / flowerUpDuration=5, but
-- songflower respawn is 25 minutes; those defaults decayed a live node to
-- "No data" ~125s after a pick. The first version of this migration therefore
-- rewrote exactly the literal pair 120/5 and left anything else alone.
--
-- ROUND-17 (songflower accuracy audit, fix 1) — that was not enough. The 120
-- did not only arrive as a shipped default: import.lua copied the imported
-- `flowerMinusTimerDuration` into this key on every SN import, and SN's value is
-- whatever the user set over there. So a poisoned save could hold 90, or 300, or
-- any other sub-respawn number, and the old equality test walked straight past
-- it while GetNodeState used it as the RESPAWN LENGTH — every flower counting a
-- couple of minutes and then reporting itself available. That is the owner's
-- "timers don't seem accurate".
--
-- Two things fix it together: the engine no longer lets ANY setting shorten the
-- respawn (timers.lua GetNodeState now always passes NODE_RESPAWN), and this
-- migration heals the stored values so nothing reads a respawn-shaped number
-- that lies. ANY flowerMinusDuration below the true 1500s respawn is rewritten,
-- not just the literal 120.
--
-- A value at or above 1500 is left untouched: it cannot under-report a respawn,
-- so it is either our own old default or a deliberate choice, and we do not
-- overwrite user intent. Idempotent (1500 is not < 1500).
--
-- FOLLOW-UP FOR THE OPTIONS OWNER (options.lua is not this branch's file):
-- the slider labelled "Minus-timer duration" (options.lua ~2178) still writes
-- flowerMinusDuration, and that key no longer affects anything — the respawn is
-- now a constant. The post-respawn "expired" window is the setting that
-- replaces it, stored as `flowerExpiredWindow` (seconds, default 300, clamped
-- 0-900 by Timers.ExpiredWindow). Repoint that slider at flowerExpiredWindow
-- and relabel it "Expired window"; until then it is an inert control.
----------------------------------------------------------------------

Store.SONGFLOWER_RESPAWN        = 1500   -- game constant; mirrors Timers.NODE_RESPAWN
Store.SONGFLOWER_EXPIRED_WINDOW = 300    -- default post-respawn display band

function Store.MigrateSongflowerDefaults(db)
    if type(db) ~= "table" then return end
    local fw = db.timerSettings and db.timerSettings.felwood
    if type(fw) ~= "table" then return end
    -- Heal ANY sub-respawn value (covers the SN-imported poison, not just 120).
    local minus = tonumber(fw.flowerMinusDuration)
    if minus and minus < Store.SONGFLOWER_RESPAWN then
        fw.flowerMinusDuration = Store.SONGFLOWER_RESPAWN
    end
    if fw.flowerUpDuration == 5 then fw.flowerUpDuration = 0 end
    -- Seed the replacement setting once, so the value exists before the options
    -- slider is repointed at it. Never overwrites an existing choice.
    if fw.flowerExpiredWindow == nil then
        fw.flowerExpiredWindow = Store.SONGFLOWER_EXPIRED_WINDOW
    end
end

----------------------------------------------------------------------
-- A17.3 — coordinate-override box correction.
--
-- The three seeded rules shipped with rectangles ~12x the reference's ±0.02
-- tolerance (and drifted centres), so a character standing in mid-Orgrimmar was
-- labelled "Rend Staging (N)". Existing saves already hold the bad boxes, so the
-- seed fix alone heals nobody who has logged in.
--
-- MATCH-BY-VALUE, exactly like MigrateSongflowerDefaults: a stored rule is
-- rewritten ONLY when its name is one of ours AND all four of its bounds still
-- equal the old shipped literals. Anyone who nudged a box — even by one axis —
-- has expressed intent and is left completely alone. That makes this safe to run
-- unconditionally and idempotent (after the rewrite the bounds no longer match,
-- so a second pass is a no-op) with no marker flag to maintain.
----------------------------------------------------------------------

-- The exact rectangles the bad build shipped. Keyed by rule name.
local LEGACY_COORD_BOXES = {
    ["Rend North Staging"] = { minX = 0.30, maxX = 0.55, minY = 0.55, maxY = 0.80 },
    ["Rend South Staging"] = { minX = 0.40, maxX = 0.60, minY = 0.10, maxY = 0.30 },
    ["DMF Mulgore"]        = { minX = 0.30, maxX = 0.50, minY = 0.55, maxY = 0.75 },
}

-- Float compare against stored literals; they round-trip exactly through the SV
-- writer, but an epsilon costs nothing and survives a reformat.
local function sameCoord(a, b)
    return type(a) == "number" and math.abs(a - b) < 1e-9
end

local function isLegacyCoordBox(rule)
    local old = rule and rule.name and LEGACY_COORD_BOXES[rule.name]
    if not old then return false end
    return sameCoord(rule.minX, old.minX) and sameCoord(rule.maxX, old.maxX)
       and sameCoord(rule.minY, old.minY) and sameCoord(rule.maxY, old.maxY)
end
Store._IsLegacyCoordBox = isLegacyCoordBox

function Store.MigrateCoordinateOverrides(db)
    if type(db) ~= "table" then return 0 end
    local list = db.coordinateOverrides
    if type(list) ~= "table" then return 0 end

    -- Index the corrected seeds by name so each stored rule heals to its own.
    local fresh = {}
    for _, r in ipairs(defaultCoordinateOverrides()) do fresh[r.name] = r end

    local fixed = 0
    for i = 1, #list do
        local rule = list[i]
        if type(rule) == "table" and isLegacyCoordBox(rule) then
            local new = fresh[rule.name]
            if new then
                rule.minX, rule.maxX = new.minX, new.maxX
                rule.minY, rule.maxY = new.minY, new.maxY
                -- The two Rend rules become unscoped along with their geometry;
                -- the stored zone was part of the same wrong seed.
                rule.zone = new.zone
                fixed = fixed + 1
            end
        end
    end
    return fixed
end

----------------------------------------------------------------------
-- Notes migration (replaces the per-character location-override concept).
--
-- The manual-location override is retired in favour of a free-text note. This
-- one-time, additive pass copies any legacy manualLocations value into the
-- character's note WHEN that note is empty; it never deletes or modifies the
-- stored manualLocations data (we do not destroy user data — the UI simply
-- stops consuming it). Guarded by the `notesMigrated` marker so a later user
-- edit (e.g. clearing a note) is never re-clobbered by the old location.
----------------------------------------------------------------------

function Store.MigrateNotes(data)
    if type(data) ~= "table" then return end
    if data.notesMigrated then return end
    if type(data.notes) ~= "table" then data.notes = {} end
    local locs = data.manualLocations
    if type(locs) == "table" then
        for nameRealm, label in pairs(locs) do
            if type(label) == "string" and label ~= "" then
                local existing = data.notes[nameRealm]
                if existing == nil or existing == "" then
                    data.notes[nameRealm] = label
                end
            end
        end
    end
    data.notesMigrated = true
end

----------------------------------------------------------------------
-- Account bucket shape
----------------------------------------------------------------------

local function newAccountBucket(isSelf)
    return {
        isSelf     = isSelf or false,
        characters = {},                 -- ["Name-Realm"] = record
        segments   = { sixties = {}, summoners = {}, norole = {} },  -- "X" = tombstone slot
        segmentHashes = {},              -- [segmentName] = { hash=, epoch= }
        homeless   = {},                 -- ["Name-Realm"] = record (no manifest slot yet)
    }
end
Store.NewAccountBucket = newAccountBucket

----------------------------------------------------------------------
-- Storage migration chain  (AT-RISK-3 fix — stamp, don't wipe)
--
-- MIGRATIONS[n] upgrades a DaseekiNexusData table stamped version n to version
-- n+1: a PURE transform-in-place. Nothing is discarded -- the character graph
-- (accounts + attunements), tombstones (deletedAIDs), timers, social, notes,
-- instances and the sync caches all ride through untouched unless a step
-- deliberately rewrites them. This replaces the old rebuild-from-defaults branch
-- that silently wiped `accounts` on any version change.
--
-- STORAGE_VERSION ships at 1, so the chain has no steps yet; the runner exists
-- now so the FIRST real storage bump is a data change (add MIGRATIONS[1]), not a
-- plumbing change -- and the wipe branch is gone, so a future bump can never fall
-- back to discarding the graph.
--
-- Contract (mirrors Daseeki-ClassHUD/store.lua Store.Migrate, the house model):
--   * absent / unknown version -> STAMP to current. Today's saved data already
--     has the current shape, so assume-compatible-and-seed; NEVER wipe.
--   * version NEWER than ours   -> leave EXACTLY as-is (never downgrade); the
--     caller logs once and skips the additive backfill.
--   * a known older version     -> run the ordered step(s) n -> n+1 in place.
--   * a MISSING step in the chain -> STOP with a "gap" error rather than
--     half-converting or wiping. Unreachable in a correctly-shipped build.
----------------------------------------------------------------------

Store.MIGRATIONS = {}

-- Returns: ok, fromVersion, toVersion, note
--   ok=true  with note "stamped"  (version was absent -> set to current)
--   ok=true  with note "migrated" (0+ steps ran; safe to backfill defaults)
--   ok=false with note "future"   (saved by a newer build; left untouched)
--   ok=false with note "gap"      (older, but a step is missing; stopped clean)
--   ok=false with note "no table" (defensive; nothing to do)
function Store.MigrateData(data)
    if type(data) ~= "table" then return false, nil, nil, "no table" end
    local from = tonumber(data.version)
    if from == nil then
        -- Fresh table, or a pre-version private build: the data is already
        -- current-shaped, so stamp it. applyDefaults (below) fills any gaps.
        data.version = Store.STORAGE_VERSION
        return true, nil, Store.STORAGE_VERSION, "stamped"
    end
    if from > Store.STORAGE_VERSION then
        -- Saved by a newer build. Leave it EXACTLY as-is -- downgrading a
        -- player's character graph is worse than not reading it this session.
        return false, from, from, "future"
    end
    while (data.version or 0) < Store.STORAGE_VERSION do
        local step = Store.MIGRATIONS[data.version]
        if type(step) ~= "function" then
            -- No path forward: STOP rather than half-convert or wipe.
            return false, from, data.version, "gap"
        end
        step(data)                              -- pure transform-in-place
        data.version = data.version + 1
    end
    return true, from, data.version, "migrated"
end

----------------------------------------------------------------------
-- Init: attach SVs, apply defaults, run the storage migration chain
----------------------------------------------------------------------

function Store.Init()
    -- Settings SV
    if type(DaseekiNexusDB) ~= "table" then
        DaseekiNexusDB = {}
    end

    -- Settings migrations run BEFORE applyDefaults so a legacy shape is
    -- transformed first, then any still-missing keys are backfilled.
    Store.MigrateSettings(DaseekiNexusDB)
    -- Rewrite any SV still holding the wrong songflower defaults (120/5 -> 1500/0)
    -- before defaults backfill; user-customized values are left untouched.
    Store.MigrateSongflowerDefaults(DaseekiNexusDB)
    -- A17.3: shrink the three oversized seeded coordinate boxes to the reference
    -- ±0.02 tolerance. Match-by-value, so user-edited boxes are never touched.
    Store.MigrateCoordinateOverrides(DaseekiNexusDB)

    applyDefaults(DaseekiNexusDB, defaultSettings())
    DaseekiNexusDB.settingsVersion = Store.SETTINGS_VERSION

    -- One-time, additive install of the per-faction aura thresholds (spec §4.6)
    -- and the Rend / Battle Shout class expectations (spec §4.7). Runs AFTER
    -- applyDefaults so factionSettings/auraOpts is guaranteed to exist, and
    -- self-disables via auraOpts.defaultsApplied (never re-seeds).
    Store.SeedAuraDefaults(DaseekiNexusDB)

    -- One-time, additive install of the seven spec'd auto-summon buff triggers
    -- (spec §13). Same ordering constraint as SeedAuraDefaults -- must run AFTER
    -- applyDefaults so factionSettings/autoSummon exists -- and self-disables via
    -- autoSummon.defaultsApplied. Does NOT enable auto-accept (owner decision).
    Store.SeedAutoSummonDefaults(DaseekiNexusDB)

    -- Data SV
    if type(DaseekiNexusData) ~= "table" then
        DaseekiNexusData = defaultData()
    end

    -- Storage migration (AT-RISK-3): an additive MIGRATIONS chain that
    -- TRANSFORMS the saved data in place. Nothing is discarded -- the character
    -- graph (accounts + attunements), tombstones (deletedAIDs), timers, social,
    -- notes, instances and the sync caches all survive a version change, which
    -- the old rebuild-from-defaults branch used to silently wipe. See
    -- Store.MigrateData for the stamp / never-downgrade / stop-on-gap contract.
    local dataOK, dataFrom, dataTo, dataNote = Store.MigrateData(DaseekiNexusData)
    if dataOK then
        -- Backfill any structure a partial / older / freshly-stamped DB is
        -- missing. Additive and non-clobbering, so a migration step's output
        -- (and every existing value) is never overwritten.
        applyDefaults(DaseekiNexusData, defaultData())

        -- One-time additive copy of legacy location overrides into empty notes.
        Store.MigrateNotes(DaseekiNexusData)
    elseif dataNote == "future" then
        -- Left exactly as-is; run this session against the newer-shaped data.
        if ns and ns.Print then
            ns:Print("your Daseeki-Nexus character data was saved by a newer version "
                .. "(storage v" .. tostring(dataFrom) .. "). It has been left untouched -- "
                .. "update the addon to use it.")
        end
    else
        -- "gap" (a missing migration step) or a malformed table: stop clean,
        -- change nothing, so a later build with the step can still convert it.
        if ns and ns.Print then
            ns:Print("your Daseeki-Nexus character data could not be upgraded from "
                .. "storage v" .. tostring(dataFrom) .. " (stopped at v" .. tostring(dataTo)
                .. "); no changes were made.")
        end
    end

    Store.db   = DaseekiNexusDB
    Store.data = DaseekiNexusData
end

----------------------------------------------------------------------
-- Login: run sweeps that should happen once the world is available
----------------------------------------------------------------------

function Store.OnLogin()
    -- B5.1: FIRST, because it is a precondition for the sweeps below. A bucket
    -- wrongly flagged isSelf is immune to stale-twin retirement, so demoting the
    -- impostors before SweepStaleTwins runs is what lets a single reload heal an
    -- existing duplicate instead of leaving it stranded until the next write.
    Store.SanitizeSelfBuckets()
    Store.SweepTombstones()
    Store.WeeklyResetSweep()
    Store.SweepOrphanBucket()
    Store.SweepOfflineDMF()
    -- A9.1: one-time, additive synthesis of item-cooldown START EPOCHS from the
    -- legacy remaining-seconds fields already in SavedVariables. Runs before the
    -- first capture so an alt parked mid-hearthstone keeps a truthful countdown
    -- across the relog instead of freezing at its last captured value.
    Store.MigrateItemCdEpochsAll()
    -- B4 (sender side): publishable manifest membership for our own account.
    Store.RebuildSelfSegments()
    -- B5: retire stale twins left behind when an account re-set up under a new
    -- AID (the "same character drawn twice, both green" bug). Strictly-older
    -- copies only, never from a self bucket — see the B5 block for the guards.
    Store.SweepStaleTwins()
    -- Wave N5: one-time import of legacy Bags cross-account data, then a
    -- retention sweep over the suite-namespace store.
    Store.MigrateBags()
    Store.SweepSyncNamespaces()
end

function Store.OnLogout()
    -- Trim volatile logs on the way out; final network flush is wave N2.
    Store.TrimAllLogs()
end

----------------------------------------------------------------------
-- Account access + self-immunity guards
----------------------------------------------------------------------

-- Return (and lazily create) the bucket for an account id. The empty
-- string keys the orphan bucket for synced-but-unattributed characters.
function Store.GetAccount(aid, createIfMissing)
    aid = aid or ""
    local accounts = Store.data.accounts
    local bucket = accounts[aid]
    if not bucket and createIfMissing then
        local selfID = ns:GetAccountID()
        bucket = newAccountBucket(aid ~= "" and aid == selfID)
        accounts[aid] = bucket
    end
    return bucket
end

-- The account bucket that represents THIS account (flagged isSelf).
function Store.GetSelfAccount(createIfMissing)
    local aid = ns:GetAccountID()
    if aid == "" then
        -- No account id chosen yet: use the orphan bucket but mark it self
        -- so self-immunity still protects our own live characters.
        local bucket = Store.GetAccount("", createIfMissing)
        if bucket then bucket.isSelf = true end
        return bucket
    end
    local bucket = Store.GetAccount(aid, createIfMissing)
    if bucket then bucket.isSelf = true end
    return bucket
end

-- Is this account bucket ours? Inbound mesh data must never overwrite it.
function Store.IsSelfAccount(aid)
    local bucket = Store.data.accounts[aid or ""]
    return bucket ~= nil and bucket.isSelf == true
end

----------------------------------------------------------------------
-- Character-record API (used by tracker now; mesh + UI later)
----------------------------------------------------------------------

-- A canonical empty record. Field set matches spec §2b / §6 and the
-- binary schema in protocol.lua.
function Store.NewCharacterRecord(nameRealm)
    return {
        nameRealm       = nameRealm,
        classTag        = nil,     -- e.g. "WARLOCK"
        className       = nil,     -- localized
        faction         = nil,     -- "Alliance" / "Horde" / nil
        level           = 0,
        xp              = 0,       -- current XP into the level (0 at max level)
        xpMax           = 0,       -- total XP for the level    (0 at max level)
        restedXP        = 0,       -- rested (double-XP) pool    (0 when unrested)
        location        = nil,     -- resolved label / zone
        inInstance      = false,
        isResting       = false,
        pvpFlagged      = false,
        pvpExpiry       = 0,       -- epoch when the flag drops (0 = none)
        chronoboonActive = false,
        chronoboonLastSeen = 0,
        chronoboonCDStart = 0,     -- A9.1/A7.2: START EPOCH of the chronoboon item
                                   -- cooldown. Written by the successful BOON CAST
                                   -- (authoritative) or derived from the bag API
                                   -- (fallback). 0 = no cooldown.
        boonCount       = 0,
        shardCount      = 0,       -- warlock soul shards
        soulstoneReady  = false,   -- warlock: a soulstone is available (item in bags
                                   -- and/or Create Soulstone off cooldown) — item 6
        hearthstoneCDStart = 0,    -- A9.1: START EPOCH of the hearthstone cooldown
                                   -- (0 = none). Remaining is always DERIVED.
        -- A9.1 LEGACY MIRRORS — remaining seconds, recomputed from the epochs on
        -- every capture and at the wire boundary. Kept for one release cycle so
        -- the frozen u16 wire fields and older records keep working; see the
        -- SavedVariables/CHANGELOG note at the top of this file.
        itemCooldown    = 0,       -- chronoboon item CD, remaining seconds (mirror)
        hearthstoneCD   = 0,       -- hearthstone CD, remaining seconds  (mirror)
        dmfInBoon       = false,   -- the Darkmoon fortune is stashed IN the boon.
                                   -- A8: this is now literally "in boon" (it used
                                   -- to mean "holds a fortune, live or booned"),
                                   -- because the cooldown FREEZES on this flag.
        dmfCooldownActive = false,
        -- A8.1: a real 4h ONLINE-TIME cooldown, not a boolean.
        --   remainingOnlineSecs — seconds of ONLINE time still owed.
        --   lastTickEpoch       — epoch the remaining was last decremented at.
        --   offlineSince        — epoch of logout (0 while online / resumed).
        -- Both new fields are ADDITIVE: an older record that carries only
        -- offlineSince still loads, and reads as "on CD, remaining unknown" until
        -- the local tick seeds it (see Store.DMFCooldownTick).
        dmfCooldown     = { offlineSince = 0, remainingOnlineSecs = 0, lastTickEpoch = 0 },
        raidLockouts    = {},      -- [raidKey] = expiryEpoch
        auraStates      = {},      -- [1..10] = { duration, option, source }
        lastSeen        = 0,
        lastDataUpdate  = 0,
        ownerEpoch      = 0,       -- sync tiebreaker
    }
end

-- Rested pool as a PERCENTAGE OF THE CURRENT LEVEL: restedXP / xpMax * 100.
--
-- Semantics (Classic Era): the rested "bubble" pool grants +100% XP (double XP)
-- while it lasts and accrues up to a hard cap of 1.5 levels of XP. Expressed as a
-- percentage of ONE level that cap is 150%, so the DISPLAY value is clamped to
-- 150 (the raw ratio can momentarily read higher mid-tick, but the game caps
-- accrual at 1.5 levels). The value is computed honestly from the record's own
-- xpMax — it is NOT pre-capped in the stored data, only at display time here.
--
-- Returns nil (no rested line — the UI shows "Level 60" only) when:
--   * rec is not a table, or xp/rested fields are absent/non-numeric, or
--   * xpMax <= 0  (max level, or level data not yet captured — divide-by-zero guard).
-- Returns 0 for a rested pool of 0 on a sub-60 character (distinct from nil).
-- Pure; harness-tested (see testRestedPercent).
function Store.RestedPercent(rec)
    if type(rec) ~= "table" then return nil end
    local xpMax  = rec.xpMax
    local rested = rec.restedXP
    if type(xpMax) ~= "number" or type(rested) ~= "number" then return nil end
    if xpMax <= 0 then return nil end          -- max level / no level data captured
    local pct = rested / xpMax * 100
    if pct < 0   then pct = 0   end
    if pct > 150 then pct = 150 end            -- classic rest cap = 1.5 levels
    return pct
end

-- Read a character record from any account bucket. Searches the given
-- account (or self by default), then its homeless bucket.
function Store.GetCharacter(nameRealm, aid)
    local bucket
    if aid then
        bucket = Store.GetAccount(aid, false)
    else
        bucket = Store.GetSelfAccount(false)
    end
    if not bucket then return nil end
    return bucket.characters[nameRealm] or bucket.homeless[nameRealm]
end

-- Write a live (self) character record. Always lands in the self bucket
-- and stamps sync bookkeeping. Self-immunity is enforced by routing all
-- inbound mesh writes through a different path (wave N2), never here.
function Store.WriteSelfCharacter(nameRealm, record)
    local bucket = Store.GetSelfAccount(true)
    if not bucket then return nil end
    record.nameRealm = nameRealm
    record.lastDataUpdate = serverNow()
    if record.lastSeen == 0 then record.lastSeen = record.lastDataUpdate end
    bucket.characters[nameRealm] = record
    -- B4 (sender side): keep our own manifest membership honest. Cheap — it only
    -- rewrites (and only bumps the segment epoch) when membership really moved.
    Store.RebuildSelfSegments(record.lastDataUpdate)
    -- B5: our own copy is by definition the freshest one there is, so any twin
    -- of this character parked under an OLD account bucket (the same machine
    -- re-set-up under a new AID) is stale and gets retired. Self buckets are
    -- never touched by the sweep, so this can only ever remove a foreign copy.
    Store.ReconcileStaleTwins(nameRealm, ns:GetAccountID())
    return record
end

-- Get-or-create the self record for a character (used by the tracker to
-- update in place without losing prior fields).
function Store.EnsureSelfCharacter(nameRealm)
    local bucket = Store.GetSelfAccount(true)
    if not bucket then return nil end
    local rec = bucket.characters[nameRealm]
    if not rec then
        rec = Store.NewCharacterRecord(nameRealm)
        bucket.characters[nameRealm] = rec
    end
    return rec
end

----------------------------------------------------------------------
-- NON-WIRE FIELD CARRY-FORWARD (the inbound write is a REPLACE, not a merge)
--
-- Store.WriteInboundCharacter swaps the whole record table in. That is correct
-- for everything the wire carries — the owner is authoritative and MUST be able
-- to clear a field by sending it empty — but it silently destroyed the fields
-- the BINARY schema does not carry. A record adopted over the SEGMENT path
-- (whole Lua tables, so it carries everything) had those fields wiped by the
-- very next STATE push seconds later.
--
-- The list is EXPLICIT, never a blanket merge: a blanket merge would resurrect
-- exactly the values the wire is trying to clear. Adding a field to the binary
-- schema means DELETING it from this list.
--
-- ENUMERATED, and why each one is here:
--
--   attunements                        Tracker's per-character raid attunement
--                                      matrix. Not in the binary schema at all;
--                                      rides the SEGMENT path and the "attune"
--                                      namespace. Monotonic (attunement is never
--                                      lost), so carrying it forward can only
--                                      ever preserve truth.
--   dmfCooldown.remainingOnlineSecs    A8.1 online-time cooldown accounting.
--   dmfCooldown.lastTickEpoch          Protocol.DecodeCharacter rebuilds
--                                      rec.dmfCooldown as `{ offlineSince = u32 }`,
--                                      so a STATE push drops both of these and the
--                                      detail pane fell from a real countdown back
--                                      to a bare "on CD". Carried ONLY while the
--                                      incoming record still says the cooldown is
--                                      active — a wire-borne `dmfCooldownActive =
--                                      false` is the owner clearing it, and that
--                                      clear must win.
--
-- DELIBERATELY NOT CARRIED (checked, and each is here for a reason):
--
--   notes            NOT a record field. Store.SetNote persists to
--                    Store.data.notes[nameRealm] (store.lua ~2533), a sibling
--                    table the character graph never touches — so notes were
--                    never at risk from the wholesale replace.
--   chronoboonCDStart / hearthstoneCDStart / itemCooldown / hearthstoneCD
--                    Wire-derived by design. Store.AdoptWireCooldowns runs on the
--                    INCOMING record just above and re-anchors these onto our own
--                    clock (A9.1). Carrying the old ones forward would defeat the
--                    entire epoch-conversion boundary and freeze a cooldown that
--                    the owner has since used or cleared.
--   _srcAID          Bookkeeping this function stamps itself on the line below.
--
-- PURE given its two arguments. Mutates `incoming` only; `existing` is read-only.
----------------------------------------------------------------------
Store.NON_WIRE_CARRY = { "attunements" }
Store.NON_WIRE_CARRY_DMF = { "remainingOnlineSecs", "lastTickEpoch" }

function Store.CarryNonWireFields(existing, incoming)
    if type(existing) ~= "table" or type(incoming) ~= "table" then return incoming end

    -- Top-level fields the binary schema does not carry at all.
    for i = 1, #Store.NON_WIRE_CARRY do
        local k = Store.NON_WIRE_CARRY[i]
        if incoming[k] == nil and existing[k] ~= nil then
            incoming[k] = existing[k]
        end
    end

    -- The DMF cooldown sub-table: only the two additive keys, and only while the
    -- incoming record still claims the cooldown is running.
    if incoming.dmfCooldownActive then
        local old = existing.dmfCooldown
        if type(old) == "table" then
            local new = incoming.dmfCooldown
            if type(new) ~= "table" then new = {}; incoming.dmfCooldown = new end
            for i = 1, #Store.NON_WIRE_CARRY_DMF do
                local k = Store.NON_WIRE_CARRY_DMF[i]
                if new[k] == nil and old[k] ~= nil then new[k] = old[k] end
            end
        end
    end
    return incoming
end

-- Inbound (relayed) write helper. Enforces self-immunity and the
-- owner/epoch tiebreaker. `senderAID` (optional) is the account ID of the
-- mesh peer that relayed this record; when two inbound writes carry an EQUAL
-- ownerEpoch the one from the LOWEST account ID wins (spec §3/§6 tiebreak).
-- The winning writer's id is stamped on the record (_srcAID) so a later
-- equal-epoch write can be compared against it deterministically.
-- Returns true if the write was applied.
--
-- Wave N2a: added the optional 4th `senderAID` param and the lowest-account-ID
-- tie resolution. Callers passing 3 args keep the N1 behaviour (ties rejected).
function Store.WriteInboundCharacter(aid, nameRealm, record, senderAID)
    -- Guard: a nil/empty nameRealm would index bucket.characters[nil] below and
    -- error, DROPPING this record AND error-storming the rest of the receive
    -- batch — which is how a peer's characters silently stopped showing online.
    -- Inbound frames legitimately arrive nameless: Protocol.EncodeCharacter writes
    -- `rec.nameRealm or ""` and Protocol.DecodeCharacter turns "" back into nil
    -- (protocol.lua:398), so any push of a record without a nameRealm (an early-
    -- login self record before the name is stamped, or the import STORE_REFRESHED
    -- backstop noted in EncodeCharacter) lands here with nameRealm==nil. Drop it
    -- deterministically and count it for diagnostics rather than crashing.
    if type(nameRealm) ~= "string" or nameRealm == "" then
        Store._droppedNamelessInbound = (Store._droppedNamelessInbound or 0) + 1
        return false
    end
    if Store.IsSelfAccount(aid) then
        return false   -- never overwrite our own data from the wire
    end
    -- A9.1 DECODE BOUNDARY. Every inbound record — binary STATE frames (u16
    -- remaining) and whole-table SEGMENT records alike — funnels through here, so
    -- this is the single place the wire's remaining-seconds become a LOCAL epoch.
    -- Done before the epoch guard on purpose: `record` is a decoded temporary,
    -- and converting a record we then reject costs nothing.
    Store.AdoptWireCooldowns(record, serverNow())
    local bucket = Store.GetAccount(aid, true)
    if not bucket then return false end
    local existing = bucket.characters[nameRealm]
    if existing then
        -- Owner data wins; tie broken by lowest account id.
        local ea = existing.ownerEpoch or 0
        local na = record.ownerEpoch or 0
        if na < ea then
            return false
        elseif na == ea then
            -- Equal epoch: resolve by lowest relaying account ID when known.
            -- Without a sender id (legacy 3-arg call) keep existing.
            if senderAID == nil then return false end
            local existingSrc = existing._srcAID
            if existingSrc ~= nil then
                local es = tonumber(existingSrc)
                local ns_ = tonumber(senderAID)
                if es ~= nil and ns_ ~= nil then
                    if ns_ >= es then return false end   -- not strictly lower
                elseif tostring(senderAID) >= tostring(existingSrc) then
                    return false
                end
            end
        end
    end
    record._srcAID = senderAID
    -- The swap below REPLACES the record. Carry the explicitly-enumerated fields
    -- the wire does not represent (see Store.CarryNonWireFields) so a STATE push
    -- cannot destroy data that only the SEGMENT path or the local tick maintains.
    Store.CarryNonWireFields(existing, record)
    bucket.characters[nameRealm] = record
    -- B5: this write may have just created the LIVE half of a stale twin pair —
    -- the owner re-set-up an account under a new/differently-formatted AID, so
    -- the same Name-Realm now sits under two buckets and the roster drew it
    -- twice. Retire the strictly-older copies (see the B5 block below for the
    -- guards). Cheap: it only walks buckets that actually hold this name.
    Store.ReconcileStaleTwins(nameRealm, aid)
    return true
end

----------------------------------------------------------------------
-- A9.1 — the shared item-cooldown epoch helpers
--
-- EVERY writer and EVERY reader goes through this block: the tracker's capture,
-- the boon-cast stamp, the mesh wire boundary in both directions, the SV
-- migration, the cards, the detail pane. There is exactly one place that knows
-- how a stored epoch becomes a countdown.
----------------------------------------------------------------------

-- PURE. Is `epoch` a believable START for a cooldown of `duration` at `nowE`?
-- Spec §6: "a converted epoch is only accepted if it falls in [now-3605, now+5]"
-- — i.e. no further back than one full cooldown (plus the skew allowance) and no
-- more than the skew allowance into the future.
function Store.ItemCdEpochSane(epoch, nowE, duration)
    epoch = tonumber(epoch) or 0
    if epoch <= 0 then return false end
    nowE = tonumber(nowE) or serverNow()
    duration = tonumber(duration) or ITEM_CD_HEARTHSTONE
    local slack = Store.ITEM_CD_SKEW
    return epoch >= (nowE - duration - slack) and epoch <= (nowE + slack)
end

-- PURE. Turn a REMAINING-SECONDS reading taken at `atE` into a start epoch.
-- Returns 0 when the remaining is not a usable cooldown (<=0, or larger than the
-- cooldown itself / the absurd-duration gate — both are garbage readings).
function Store.ItemCdEpochFromRemaining(remaining, atE, duration)
    remaining = tonumber(remaining) or 0
    duration  = tonumber(duration) or ITEM_CD_HEARTHSTONE
    if remaining <= 0 then return 0 end
    if remaining > duration or remaining > Store.ITEM_CD_ABSURD then return 0 end
    return (tonumber(atE) or serverNow()) - (duration - remaining)
end

-- PURE. Seconds remaining on `which` cooldown for `rec`, at `nowE`.
--
-- WHO OWNS THE RECORD is decided by whether the epoch FIELD EXISTS, not by
-- whether it is non-zero. Any record this release has touched carries a number
-- there (Store.NewCharacterRecord seeds 0, every writer stamps one), and for
-- those the epoch is the ONLY truth — a zero means "no cooldown", full stop.
-- Only a record from before this release, which has no such field at all, falls
-- back to the legacy mirror. Without that rule an expired epoch healed to 0
-- would fall through and let a stale mirror resurrect the countdown.
--
--   epoch field, sane value -> duration - (now - epoch)         [the model]
--   epoch field, 0/insane   -> 0                                [self-healing]
--   NO epoch field          -> legacy remaining decayed against rec.lastDataUpdate
--                              (and a legacy value above the cooldown with no
--                              usable reference heals to 0 — spec §6)
-- The legacy branch exists only for records written before this release (and for
-- records produced by import.lua, which carry the remainings and no epochs); it
-- is deleted along with the mirrors one cycle from now.
function Store.ItemCdRemaining(rec, which, nowE)
    local spec = ITEM_CD[which]
    if type(rec) ~= "table" or not spec then return 0 end
    nowE = tonumber(nowE) or serverNow()

    if rec[spec.epoch] ~= nil then
        local epoch = tonumber(rec[spec.epoch]) or 0
        if epoch <= 0 then return 0 end
        if not Store.ItemCdEpochSane(epoch, nowE, spec.duration) then return 0 end
        local rem = spec.duration - (nowE - epoch)
        if rem <= 0 then return 0 end
        if rem > spec.duration then rem = spec.duration end
        return math.floor(rem)
    end

    local legacy = tonumber(rec[spec.legacy]) or 0
    if legacy <= 0 then return 0 end
    local ref = tonumber(rec.lastDataUpdate) or 0
    if ref <= 0 then
        -- No reference epoch at all: a value above the cooldown is unhealable
        -- garbage (the "9000-minute" shape), anything else freezes as-is.
        if legacy > spec.duration then return 0 end
        return math.floor(legacy)
    end
    local elapsed = nowE - ref
    if elapsed < 0 then elapsed = 0 end
    local rem = legacy - elapsed
    if rem <= 0 then return 0 end
    return math.floor(rem)
end

-- Recompute the legacy remaining-seconds mirror for one cooldown from its epoch.
-- Clamped to the u16 range the wire uses. Returns the value written.
function Store.RefreshItemCdMirror(rec, which, nowE)
    local spec = ITEM_CD[which]
    if type(rec) ~= "table" or not spec then return 0 end
    local rem = Store.ItemCdRemaining(rec, which, nowE)
    if rem > U16_MAX then rem = U16_MAX end
    rec[spec.legacy] = rem
    return rem
end

-- Recompute BOTH mirrors. Called at the end of every capture and at the encode
-- boundary, so the legacy fields (and therefore the wire, and the state hash)
-- always agree with the epochs.
function Store.RefreshItemCdMirrors(rec, nowE)
    if type(rec) ~= "table" then return rec end
    nowE = tonumber(nowE) or serverNow()
    for i = 1, #Store.ITEM_CD_KEYS do
        Store.RefreshItemCdMirror(rec, Store.ITEM_CD_KEYS[i], nowE)
    end
    return rec
end

-- Write a start epoch, subject to the acceptance window. Returns true on write.
-- `force` skips the "must be newer than what we hold" rule; the boon cast and
-- the migration use it, the bag-API fallback does not (spec §6: the API is
-- accepted "when no cooldown is stored, or when the API's derived start epoch is
-- newer than the stored one — the instance-kick reset case").
function Store.ItemCdSetStart(rec, which, epoch, nowE, force)
    local spec = ITEM_CD[which]
    if type(rec) ~= "table" or not spec then return false end
    nowE = tonumber(nowE) or serverNow()
    epoch = tonumber(epoch) or 0
    if epoch <= 0 then return false end
    if not Store.ItemCdEpochSane(epoch, nowE, spec.duration) then return false end
    if not force then
        local held = tonumber(rec[spec.epoch]) or 0
        if held > 0 and Store.ItemCdEpochSane(held, nowE, spec.duration) then
            if epoch <= held + Store.ITEM_CD_RESET_SLACK then return false end
        end
    end
    rec[spec.epoch] = epoch
    Store.RefreshItemCdMirror(rec, which, nowE)
    return true
end

-- Clear a cooldown (both the epoch and its mirror).
function Store.ItemCdClear(rec, which)
    local spec = ITEM_CD[which]
    if type(rec) ~= "table" or not spec then return end
    rec[spec.epoch] = 0
    rec[spec.legacy] = 0
end

-- Drop an epoch that has fully elapsed or fallen outside the sane window, so a
-- stale stamp cannot linger in SavedVariables forever. Returns true if it healed
-- something. (The READER is pure and already reads 0 for these; this is the
-- write-side sweep the tracker runs on capture.)
function Store.HealItemCdEpochs(rec, nowE)
    if type(rec) ~= "table" then return false end
    nowE = tonumber(nowE) or serverNow()
    local healed = false
    for i = 1, #Store.ITEM_CD_KEYS do
        local which = Store.ITEM_CD_KEYS[i]
        local spec  = ITEM_CD[which]
        local epoch = tonumber(rec[spec.epoch]) or 0
        if epoch > 0 and not Store.ItemCdEpochSane(epoch, nowE, spec.duration) then
            -- Clear the mirror alongside the epoch: leaving a stale remaining
            -- behind is exactly how a healed cooldown came back from the dead.
            Store.ItemCdClear(rec, which)
            healed = true
        end
    end
    return healed
end

-- MIGRATION (spec: additive, on first capture). A record written by an older
-- client carries only the remaining-seconds mirrors. Synthesize the epoch once:
--     start = reference - (duration - remaining)
-- where the reference is rec.lastDataUpdate (the epoch the remaining was read
-- at) or, when that is missing, `nowE` — which FREEZES the countdown at its
-- stored value rather than back-dating it by an unknown offline stretch.
-- Never touches a record that already carries an epoch. Returns true if it wrote.
function Store.MigrateItemCdEpochs(rec, nowE)
    if type(rec) ~= "table" then return false end
    nowE = tonumber(nowE) or serverNow()
    local wrote = false
    for i = 1, #Store.ITEM_CD_KEYS do
        local which = Store.ITEM_CD_KEYS[i]
        local spec  = ITEM_CD[which]
        local epoch = tonumber(rec[spec.epoch]) or 0
        if epoch <= 0 then
            local legacy = tonumber(rec[spec.legacy]) or 0
            local synth = 0
            if legacy > 0 then
                local ref = tonumber(rec.lastDataUpdate) or 0
                if ref <= 0 or ref > nowE then ref = nowE end
                synth = Store.ItemCdEpochFromRemaining(legacy, ref, spec.duration)
                if not Store.ItemCdEpochSane(synth, nowE, spec.duration) then
                    -- Unhealable legacy garbage (the >3600-with-no-reference case).
                    synth = 0
                    rec[spec.legacy] = 0
                end
            end
            -- Always STAMP the field, even with 0: that is what promotes the
            -- record to the epoch model so the legacy branch stops being used.
            rec[spec.epoch] = synth
            if synth > 0 then wrote = true end
        end
    end
    if wrote then Store.RefreshItemCdMirrors(rec, nowE) end
    return wrote
end

----------------------------------------------------------------------
-- A9.1 — THE WIRE BOUNDARY
--
-- protocol.lua is FROZEN: it carries two u16 REMAINING-SECONDS fields and no
-- SCHEMA_VERSION bump is permitted. So the epoch model is converted at the edge.
--
-- ENCODE (Store.WireItemCd, via Mesh.WireRecord): recompute the mirrors from the
-- epochs at SEND time, so the number that goes out is the remaining as of the
-- moment of transmission rather than the moment of the last capture.
--
-- DECODE (Store.AdoptWireCooldowns, called from Store.WriteInboundCharacter):
-- convert the received remaining straight back into a LOCAL epoch,
--     epoch = receiveTime - (duration - remaining)
-- and from then on the countdown ticks locally against OUR clock forever.
--
-- DRIFT CHARACTERISTICS
--   * The only error introduced is the send->receive transit: the remaining was
--     true at send time and is re-anchored at receive time, so the reconstructed
--     epoch is LATE by exactly that delay and the countdown reads HIGH by it.
--     That is bounded by the scheduler's whisper latency (token bucket: capacity
--     8, refill 1/s) plus network — seconds, not minutes — and it never
--     accumulates: each subsequent push re-anchors from the owner's own epoch.
--   * NO cross-machine clock skew enters the value. Both sides do pure duration
--     arithmetic; the sender's epoch is never trusted. This is the strict
--     improvement over today, where the receiver decayed the stored remaining
--     against rec.lastDataUpdate — the SENDER's clock — so any skew between the
--     two machines landed directly in the displayed countdown, unbounded.
--   * A record that stops being refreshed now keeps counting down correctly
--     instead of freezing (self) or decaying off a stale stamp (remote).
--   * u16 clamp: both cooldowns are 3600s, far inside 65535, so the clamp never
--     bites in practice and is kept only as a wire-safety net.
----------------------------------------------------------------------

-- ENCODE side. Refreshes the mirrors on the record handed to the encoder.
function Store.WireItemCd(rec, nowE)
    return Store.RefreshItemCdMirrors(rec, nowE)
end

-- DECODE side. Re-anchor the received remaining-seconds onto our own clock.
-- A record that already carries a sane epoch (a peer running this release that
-- sent a full record over the SEGMENT path, where tables travel whole) keeps it.
function Store.AdoptWireCooldowns(rec, nowE)
    if type(rec) ~= "table" then return rec end
    nowE = tonumber(nowE) or serverNow()
    for i = 1, #Store.ITEM_CD_KEYS do
        local which = Store.ITEM_CD_KEYS[i]
        local spec  = ITEM_CD[which]
        local held  = tonumber(rec[spec.epoch]) or 0
        if held > 0 and Store.ItemCdEpochSane(held, nowE, spec.duration) then
            -- keep the owner's own epoch (segment path)
        else
            local rem = tonumber(rec[spec.legacy]) or 0
            local synth = Store.ItemCdEpochFromRemaining(rem, nowE, spec.duration)
            rec[spec.epoch] = Store.ItemCdEpochSane(synth, nowE, spec.duration) and synth or 0
        end
    end
    Store.RefreshItemCdMirrors(rec, nowE)
    return rec
end

-- One-time SavedVariables sweep: synthesize epochs for every character record we
-- already hold (our own alts and every cached peer character), so a relog does
-- not have to wait for each of them to be re-captured or re-pushed. Sticky —
-- `Store.data.itemCdEpochsMigrated` stops it re-running. Returns the count.
function Store.MigrateItemCdEpochsAll(nowE)
    local data = Store.data
    if type(data) ~= "table" then return 0 end
    if data.itemCdEpochsMigrated then return 0 end
    nowE = tonumber(nowE) or serverNow()
    local n = 0
    for _, bucket in pairs(data.accounts or {}) do
        for _, tbl in pairs({ bucket.characters, bucket.homeless }) do
            for _, rec in pairs(tbl or {}) do
                if Store.MigrateItemCdEpochs(rec, nowE) then n = n + 1 end
            end
        end
    end
    data.itemCdEpochsMigrated = true
    return n
end

----------------------------------------------------------------------
-- B4 — MANIFEST ADOPTION + GHOST CLEANUP
--
-- Spec §9.7: "a remote manifest is applied only when its epoch is strictly newer
-- than the locally stored one for that segment. On adoption the addon performs
-- ghost cleanup — any local character classified into that segment but absent
-- from the new manifest is deleted, PROVIDED ITS OWN DATA EPOCH IS <= THE
-- MANIFEST EPOCH. Homeless characters named by the new manifest are adopted."
--
-- Without this, an alt you delete or rename on one account lingers on every
-- other account's roster forever — there is no other delete signal on the wire.
--
-- The guards, all of which are tested:
--   * NEVER our own account (self-immunity; our roster is authoritative locally)
--   * NEVER a tombstoned account (spec §1.3: silently rejected on EVERY inbound
--     path, manifest included)
--   * NEVER an account we hold no bucket for (nothing to clean, and creating one
--     from a manifest would resurrect a purged account)
--   * only the SYNCED segments (spec §3.1: norole is local + opportunistic and
--     is never manifest-driven, so it must never be ghost-cleaned)
--   * stale/equal manifest epoch -> no adoption at all
--   * a record whose own ownerEpoch is NEWER than the manifest survives: it is
--     out-of-order delivery (the character was re-created / re-classified after
--     that manifest was cut), not a ghost.
----------------------------------------------------------------------

local SYNCED_SEGMENTS = { sixties = true, summoners = true }
Store.SYNCED_SEGMENTS = SYNCED_SEGMENTS

-- PURE. Which segment a record belongs to (spec §3.1).
function Store.SegmentFor(rec)
    if type(rec) ~= "table" then return "norole" end
    local lvl = tonumber(rec.level) or 0
    if lvl == 60 then return "sixties" end
    if rec.classTag == "WARLOCK" and lvl >= 20 then return "summoners" end
    return "norole"
end

Store.GHOST_LOG_CAP = 20
Store._ghostLog = {}          -- newest-first ring, surfaced by /dsn debug mesh

local function ghostLog(msg)
    local ring = Store._ghostLog
    table.insert(ring, 1, { at = serverNow(), text = msg })
    while #ring > Store.GHOST_LOG_CAP do table.remove(ring) end
    if ns and ns.Print then ns:Print("|cffffc020" .. msg .. "|r") end
end
Store._ghostLogWrite = ghostLog

-- Adopt a remote manifest for (aid, area) and ghost-clean the segment.
-- `list` is the ordered Name-Realm list ("X" = tombstone slot), `epoch` the
-- manifest epoch, `hash` the sender's advertised segment hash (stored as-is;
-- the local hash is always recomputed live from characters at send time).
--
-- Returns applied(boolean), info(table) where info is
--   { reason = <why not applied>, deleted = {names}, adopted = {names} }.
function Store.AdoptManifest(aid, area, list, epoch, hash)
    local info = { deleted = {}, adopted = {} }
    if aid == nil or aid == "" then info.reason = "no-aid"; return false, info end
    if type(area) ~= "string" or not SYNCED_SEGMENTS[area] then
        info.reason = "unsynced-area"; return false, info
    end
    if type(list) ~= "table" then info.reason = "no-list"; return false, info end
    if Store.IsSelfAccount(aid) then info.reason = "self"; return false, info end
    if Store.IsTombstoned(aid) then info.reason = "tombstoned"; return false, info end

    local bucket = Store.GetAccount(aid, false)
    if not bucket then info.reason = "unknown-account"; return false, info end

    epoch = tonumber(epoch) or 0
    local held = bucket.segmentHashes[area]
    local heldEpoch = (held and tonumber(held.epoch)) or 0
    if epoch <= 0 or epoch <= heldEpoch then
        info.reason = "stale-epoch"; return false, info
    end

    -- Named set from the manifest ("X" slots are tombstones, not names).
    local named = {}
    for i = 1, #list do
        local nameRealm = list[i]
        if type(nameRealm) == "string" and nameRealm ~= "" and nameRealm ~= "X" then
            named[nameRealm] = true
        end
    end

    -- (1) GHOST CLEANUP.
    local doomed = {}
    for nameRealm, rec in pairs(bucket.characters) do
        if not named[nameRealm] and Store.SegmentFor(rec) == area then
            local recEpoch = tonumber(rec.ownerEpoch) or 0
            if recEpoch <= epoch then
                doomed[#doomed + 1] = nameRealm
            end
        end
    end
    table.sort(doomed)
    for i = 1, #doomed do
        bucket.characters[doomed[i]] = nil
        info.deleted[#info.deleted + 1] = doomed[i]
    end

    -- (2) HOMELESS ADOPTION: a character parked without a manifest slot that this
    -- manifest now names moves into the real table (spec §3.2).
    local adopted = {}
    for nameRealm in pairs(named) do
        if bucket.homeless[nameRealm] and not bucket.characters[nameRealm] then
            adopted[#adopted + 1] = nameRealm
        end
    end
    table.sort(adopted)
    for i = 1, #adopted do
        local nameRealm = adopted[i]
        bucket.characters[nameRealm] = bucket.homeless[nameRealm]
        bucket.homeless[nameRealm] = nil
        info.adopted[#info.adopted + 1] = nameRealm
    end

    -- (3) Store the manifest itself.
    local seg = {}
    for i = 1, #list do seg[i] = list[i] end
    bucket.segments[area] = seg
    bucket.segmentHashes[area] = { hash = hash, epoch = epoch }

    if #info.deleted > 0 then
        ghostLog(("mesh: manifest %s/%s (epoch %d) removed %d ghost character(s): %s")
            :format(tostring(aid), area, epoch, #info.deleted,
                    table.concat(info.deleted, ", ")))
    end
    return true, info
end

-- SENDER SIDE of B4. Ghost cleanup only works if the account that DELETED the
-- alt publishes a manifest that no longer names it, with a NEWER epoch — so our
-- own segments have to be maintained and the epoch bumped when membership
-- actually changes. Nothing built them before (they were only ever populated by
-- the legacy importer in import.lua), which would have left the receive side
-- dead code.
--
-- Membership-only: the epoch moves when a character joins, leaves or changes
-- segment (a level-60 ding, a deleted alt), and NOT on a data refresh — so this
-- cannot churn manifests on every capture. Returns true if anything changed.
function Store.RebuildSelfSegments(nowE)
    local bucket = Store.GetSelfAccount(false)
    if not bucket then return false end
    nowE = tonumber(nowE) or serverNow()

    local built = { sixties = {}, summoners = {}, norole = {} }
    for nameRealm, rec in pairs(bucket.characters) do
        local seg = built[Store.SegmentFor(rec)]
        seg[#seg + 1] = nameRealm
    end

    local changed = false
    for area in pairs(built) do
        local nextList = built[area]
        table.sort(nextList)
        local prev = bucket.segments[area] or {}
        local same = (#prev == #nextList)
        if same then
            for i = 1, #nextList do
                if prev[i] ~= nextList[i] then same = false; break end
            end
        end
        if not same then
            bucket.segments[area] = nextList
            local h = bucket.segmentHashes[area] or {}
            -- Monotonic: a same-second rebuild still has to advance the epoch or
            -- the peer's strictly-newer gate would drop it.
            local prevEpoch = tonumber(h.epoch) or 0
            h.epoch = (nowE > prevEpoch) and nowE or (prevEpoch + 1)
            h.hash = nil                      -- recomputed live at send time
            bucket.segmentHashes[area] = h
            changed = true
        end
    end
    return changed
end

----------------------------------------------------------------------
-- B5 — STALE-TWIN RECONCILIATION  (owner bug: "Puucons" drawn TWICE, both green)
--
-- THE FAILURE. Account ids are the only thing that partitions the character
-- graph. When an account is re-set up — a fresh install, a wiped SavedVariables,
-- an AID that comes back in a different FORMAT — its characters start arriving
-- under a BRAND NEW aid while the old bucket still holds a full, untouched copy
-- of every one of them. Nothing on the wire says "these two buckets are the same
-- machine", so the store happily keeps both: same Name-Realm, two buckets, two
-- roster cards, and (because online exclusivity is deliberately PER-ACCOUNT —
-- see ui_shell's ComputeOnlineWinners) each bucket elects its own online winner,
-- so both cards light green.
--
-- THE RULE. A Name-Realm is one character. If it sits in bucket X and also in
-- bucket Y with a STRICTLY OLDER ownerEpoch, the copy in Y is a leftover of the
-- account's previous identity and is retired — characters table, homeless table,
-- and any manifest slot that still names it (rewritten to the "X" tombstone, the
-- same convention AdoptManifest and TrimNoroleSegment already use).
--
-- THE GUARDS, all tested:
--   * NEVER a bucket flagged isSelf. Our own roster is authoritative locally and
--     is the one thing on this machine no remote epoch may delete. If the STALE
--     bucket is the self one (an owner who re-set up THIS account keeps the old
--     bucket flagged self) nothing is removed and the UI-side dedup in
--     ui_shell.GatherRoster is what stops the double card.
--   * NEVER on an EQUAL ownerEpoch. Equal epochs are genuinely ambiguous — two
--     copies of the same push, or an epoch that was never stamped (both 0). The
--     display dedup covers those; deleting on a coin-flip would not.
--   * The keeper must really hold the record. No keeper -> nothing to compare
--     against -> no removals.
--
-- SELF-HEALING. Because the keeper is whichever bucket just received fresh data,
-- the old bucket's copies age out on their own as the live account keeps pushing:
-- one push per character retires that character's twin. The login sweep does the
-- same pass over the whole store so a reload heals it without waiting.
----------------------------------------------------------------------

-- The copy of `nameRealm` a bucket holds, if any. The real characters table wins
-- over the homeless table (a bucket can briefly hold both — AdoptManifest moves
-- records between them). Returns rec, fromHomeless.
local function bucketCopyOf(bucket, nameRealm)
    if type(bucket) ~= "table" then return nil end
    local rec = bucket.characters and bucket.characters[nameRealm]
    if rec then return rec, false end
    rec = bucket.homeless and bucket.homeless[nameRealm]
    if rec then return rec, true end
    return nil
end

-- Erase every trace of one character from ONE bucket. Returns true if a record
-- was actually removed (a manifest slot alone does not count — that is bookkeeping
-- for a character we no longer hold either way).
local function purgeFromBucket(bucket, nameRealm)
    if type(bucket) ~= "table" then return false end
    local removed = false
    if bucket.characters and bucket.characters[nameRealm] ~= nil then
        bucket.characters[nameRealm] = nil
        removed = true
    end
    if bucket.homeless and bucket.homeless[nameRealm] ~= nil then
        bucket.homeless[nameRealm] = nil
        removed = true
    end
    -- Manifest slots keep their POSITION (the list is ordered and hashed); a
    -- vacated slot becomes the "X" tombstone rather than being spliced out.
    for _, seg in pairs(bucket.segments or {}) do
        if type(seg) == "table" then
            for i = 1, #seg do
                if seg[i] == nameRealm then seg[i] = "X" end
            end
        end
    end
    return removed
end

-- Retire every strictly-older twin of `nameRealm`, keeping the copy in `keepAID`.
-- Returns the array of account ids it removed a copy from (empty = no-op).
function Store.ReconcileStaleTwins(nameRealm, keepAID)
    local removed = {}
    if type(nameRealm) ~= "string" or nameRealm == "" then return removed end
    local accounts = Store.data and Store.data.accounts
    if type(accounts) ~= "table" then return removed end
    keepAID = keepAID or ""

    local keeper = accounts[keepAID]
    local keepRec = bucketCopyOf(keeper, nameRealm)
    if not keepRec then return removed end
    local keepEpoch = math.floor(tonumber(keepRec.ownerEpoch) or 0)

    local doomed = {}
    for aid, bucket in pairs(accounts) do
        if aid ~= keepAID and bucket ~= keeper and bucket.isSelf ~= true then
            local rec = bucketCopyOf(bucket, nameRealm)
            -- STRICTLY older only. Equal (incl. two unstamped 0s) is ambiguous.
            if rec and (math.floor(tonumber(rec.ownerEpoch) or 0)) < keepEpoch then
                doomed[#doomed + 1] = aid
            end
        end
    end
    table.sort(doomed)

    for i = 1, #doomed do
        if purgeFromBucket(accounts[doomed[i]], nameRealm) then
            removed[#removed + 1] = doomed[i]
        end
    end

    if #removed > 0 then
        local shown = {}
        for i = 1, #removed do shown[i] = (removed[i] ~= "" and removed[i]) or "(orphan)" end
        ghostLog(("store: %s kept under account %s (epoch %d); retired %d stale twin(s) from %s")
            :format(nameRealm, (keepAID ~= "" and keepAID) or "(orphan)",
                    keepEpoch, #removed, table.concat(shown, ", ")))
    end
    return removed
end

-- Whole-store pass: for every Name-Realm held by more than one bucket, keep the
-- newest-ownerEpoch copy and retire the strictly-older ones. Run at login so a
-- reload heals an existing duplicate without waiting for the live account's next
-- push. Returns the number of copies removed.
--
-- The keeper choice among EQUAL top epochs is irrelevant to the outcome —
-- ReconcileStaleTwins only ever removes STRICTLY older copies, so every bucket at
-- the maximum epoch survives regardless of which of them is nominated. The
-- tiebreak below exists purely so the debug log reads the same way twice.
function Store.SweepStaleTwins()
    local accounts = Store.data and Store.data.accounts
    if type(accounts) ~= "table" then return 0 end

    local best = {}     -- nameRealm -> { aid = , epoch = , aids = set, n = count }
    local function note(aid, tbl)
        for nameRealm, rec in pairs(tbl or {}) do
            local e = math.floor(tonumber(rec.ownerEpoch) or 0)
            local b = best[nameRealm]
            if not b then
                b = { aid = aid, epoch = e, aids = {}, n = 0 }
                best[nameRealm] = b
            elseif e > b.epoch or (e == b.epoch and tostring(aid) < tostring(b.aid)) then
                b.aid, b.epoch = aid, e
            end
            -- Distinct BUCKETS holding the name (a bucket that lists it in both
            -- characters and homeless is still one bucket, not a duplicate).
            if not b.aids[aid] then b.aids[aid] = true; b.n = b.n + 1 end
        end
    end
    for aid, bucket in pairs(accounts) do
        note(aid, bucket.characters)
        note(aid, bucket.homeless)
    end

    local n = 0
    for nameRealm, b in pairs(best) do
        if b.n > 1 then
            n = n + #Store.ReconcileStaleTwins(nameRealm, b.aid)
        end
    end
    return n
end

----------------------------------------------------------------------
-- B5.1 — self-bucket sanity pass (login)
--
-- THE CORRUPTION. `isSelf` is a singleton claim: exactly one bucket on this
-- machine is *us*. Two paths can leave a second bucket wearing the flag:
--
--   * GetSelfAccount with NO account id chosen yet deliberately flags the
--     ORPHAN ("") bucket self, so self-immunity still protects our live
--     characters before setup. Once the owner later sets a real account id,
--     GetSelfAccount flags the real bucket too — and nothing ever takes the
--     flag back off the "" bucket. Both are now self.
--   * An account id that CHANGES (a re-setup, or an import that wrote a
--     bucket under the old id) leaves the previous key's bucket flagged.
--
-- WHY IT IS PERMANENT DAMAGE. ReconcileStaleTwins refuses, by design, to
-- remove anything from a bucket flagged isSelf (our roster is the one thing
-- on this machine no remote epoch may delete). So a stale duplicate parked in
-- a wrongly-self bucket is immortal: the live account re-pushes that character
-- forever and the twin is never retired. The owner's account-#3 SavedVariables
-- shows exactly this — a second "Puucons-Whitemane" under the EMPTY-STRING key
-- whose bucket carries isSelf = true, sitting beside the genuine self bucket.
--
-- THE RULE. At most ONE bucket may be isSelf: the one whose KEY EQUALS
-- ns:GetAccountID(). Any OTHER bucket wearing the flag — empty-key or a
-- mismatched key — has it cleared. Clearing is all we do: no record is
-- removed here. That is the point. Demoting the bucket to an ordinary foreign
-- bucket makes its contents eligible for the NORMAL stale-twin retirement,
-- which then applies its own guards (strictly-older ownerEpoch only, equal is
-- ambiguous) rather than this pass inventing a deletion rule of its own.
--
-- THE GUARDS:
--   * The bucket matching the current account id is NEVER touched — not
--     cleared, not set. GetSelfAccount owns flagging it.
--   * If the account id is unset or invalid we do NOTHING. Without a valid id
--     we cannot tell which of the flagged buckets is genuine, and guessing
--     could strip self-immunity from our real roster. Pre-setup (id "") the
--     "" bucket being self is CORRECT, not corrupt.
--   * Idempotent: once a run has cleared the impostors, every later run finds
--     one flagged bucket (or none) and changes nothing.
--
-- Returns the number of buckets demoted.
----------------------------------------------------------------------

function Store.SanitizeSelfBuckets()
    local accounts = Store.data and Store.data.accounts
    if type(accounts) ~= "table" then return 0 end

    -- Without a VALID id there is no way to name the genuine self bucket, so
    -- there is no safe edit to make. Covers the unset ("") pre-setup case.
    local aid = ns and ns.GetAccountID and ns:GetAccountID()
    if not (ns and ns.IsValidAccountID and ns:IsValidAccountID(aid)) then return 0 end

    local cleared = 0
    for key, bucket in pairs(accounts) do
        if key ~= aid and type(bucket) == "table" and bucket.isSelf == true then
            bucket.isSelf = false
            cleared = cleared + 1
            ghostLog(("store: account %s was wrongly flagged as this account (self is %s); "
                      .. "flag cleared — its stale copies can now be retired normally")
                :format((key ~= "" and key) or "(orphan)", aid))
        end
    end
    return cleared
end

----------------------------------------------------------------------
-- Retention: timer logs (cap 15, 48h expiry, 30s dedup)
----------------------------------------------------------------------

-- F10 — an entry's KIND. Spec §10.1 dedups "of the same kind for Ony — pop vs
-- kill", so a kill and a pop 5s apart are two real events, while two reports of
-- the same kill are one. Normalized to a boolean so nil / false / absent all
-- read alike.
local function logKind(entry)
    return (entry and entry.killed) and true or false
end

-- F10 — is a stored `who` actually missing? The wire carries "?" for "a pop
-- happened but nobody knows who", so it is absence, not a name.
local function whoMissing(who)
    return who == nil or who == "" or who == "?"
end
Store._LogKind, Store._WhoMissing = logKind, whoMissing

-- Insert a log entry newest-first with dedup + expiry + cap. `entry` is
-- { epoch, who, killed?/quest? }. Returns true if inserted.
--
-- F10 — dedup keys on EPOCH ±30s + KIND, per spec §10.1. It used to also require
-- `e.who == entry.who`, which made the identity of an event include who reported
-- it: one Rend pop arriving from Thrall's yell, the world-buff addon's log, the
-- mesh and SN produced FOUR rows in the pop log (different `who` each time), and
-- every consumer that counts entries or reads "the newest pop" saw a log full of
-- phantom pops. Same epoch window + same kind is the SAME EVENT no matter who
-- says so; the extra reports now merge into the stored row:
--   * the HIGHER epoch wins (the later report is the better-resolved timestamp)
--   * a missing `who` ("?" or absent) is BACK-FILLED from whoever does know
-- so the merged row is strictly more informative than either report alone.
function Store.AddTimerLog(logKey, entry)
    local logs = Store.data.timers.logs
    local list = logs[logKey]
    if not list then
        list = {}
        logs[logKey] = list
    end
    local now = entry.epoch or serverNow()
    local kind = logKind(entry)
    for i = 1, #list do
        local e = list[i]
        if math.abs((e.epoch or 0) - now) <= LOG_DEDUP_WINDOW
           and logKind(e) == kind then
            -- Duplicate of a known event: merge rather than drop outright.
            if now > (e.epoch or 0) then e.epoch = now end
            if whoMissing(e.who) and not whoMissing(entry.who) then
                e.who = entry.who
            end
            return false
        end
    end
    table.insert(list, 1, entry)         -- newest-first
    Store.TrimLog(logKey)
    return true
end

function Store.TrimLog(logKey)
    local list = Store.data.timers.logs[logKey]
    if not list then return end
    local now = serverNow()
    -- Expiry: drop entries older than 48h.
    for i = #list, 1, -1 do
        if now - (list[i].epoch or 0) > LOG_EXPIRY then
            table.remove(list, i)
        end
    end
    -- Cap: keep the newest LOG_CAP.
    while #list > LOG_CAP do
        table.remove(list)               -- removes oldest (tail)
    end
end

function Store.TrimAllLogs()
    for key in pairs(Store.data.timers.logs) do
        Store.TrimLog(key)
    end
end

----------------------------------------------------------------------
-- Retention: norole segment cap (10 per account, evict oldest, never self)
----------------------------------------------------------------------

function Store.TrimNoroleSegment(aid)
    if Store.IsSelfAccount(aid) then return end   -- never evict our own
    local bucket = Store.GetAccount(aid, false)
    if not bucket then return end
    local seg = bucket.segments.norole
    -- Count real (non-tombstone) entries.
    local realCount = 0
    for i = 1, #seg do
        if seg[i] ~= "X" then realCount = realCount + 1 end
    end
    -- Evict oldest (front of list) real entries until within cap.
    local i = 1
    while realCount > NOROLE_CAP and i <= #seg do
        if seg[i] ~= "X" then
            local nameRealm = seg[i]
            table.remove(seg, i)
            if bucket.characters[nameRealm] then
                bucket.characters[nameRealm] = nil
            end
            realCount = realCount - 1
        else
            i = i + 1
        end
    end
end

----------------------------------------------------------------------
-- Retention: account tombstones (14-day TTL, local only)
----------------------------------------------------------------------

-- Record a local tombstone so a deleted account cannot be resurrected by
-- inbound mesh traffic before the TTL lapses.
function Store.TombstoneAccount(aid)
    if aid == nil or aid == "" then return end
    Store.data.deletedAIDs[aid] = serverNow()
    Store.data.accounts[aid] = nil
end

function Store.IsTombstoned(aid)
    local t = Store.data.deletedAIDs[aid]
    if not t then return false end
    if serverNow() - t > TOMBSTONE_TTL then
        Store.data.deletedAIDs[aid] = nil
        return false
    end
    return true
end

function Store.SweepTombstones()
    local now = serverNow()
    for aid, t in pairs(Store.data.deletedAIDs) do
        if now - t > TOMBSTONE_TTL then
            Store.data.deletedAIDs[aid] = nil
        end
    end
end

----------------------------------------------------------------------
-- Retention: weekly reset sweep (Wed 04:00 server-local)
----------------------------------------------------------------------

-- Wipe timer node/log data if a Wednesday-04:00 boundary has passed since
-- the last sweep. Preserves settings and character data (those are not
-- weekly-scoped). Returns true if a wipe occurred.
function Store.WeeklyResetSweep()
    local timers = Store.data.timers
    local boundary = lastWeeklyResetBoundary()
    if (timers.lastWeeklyResetAt or 0) >= boundary then
        return false
    end
    timers.flower = {}
    timers.tuber  = {}
    timers.logs   = { rend = {}, onyH = {}, onyA = {} }
    timers.timerVersion = (timers.timerVersion or 1) + 1
    timers.lastWeeklyResetAt = boundary
    return true
end

----------------------------------------------------------------------
-- Retention: orphan-bucket sweep
--
-- Characters that arrived without an account attribution sit in the ""
-- bucket. Once their owning account is known they are adopted; anything
-- still homeless past staleness is discarded so the orphan bucket does
-- not grow without bound.
----------------------------------------------------------------------

local ORPHAN_STALE = 3 * 86400   -- 3 days without an update

function Store.SweepOrphanBucket()
    local orphan = Store.data.accounts[""]
    if not orphan then return end
    local now = serverNow()
    for nameRealm, rec in pairs(orphan.characters) do
        if now - (rec.lastDataUpdate or 0) > ORPHAN_STALE then
            orphan.characters[nameRealm] = nil
        end
    end
    for nameRealm, rec in pairs(orphan.homeless) do
        if now - (rec.lastDataUpdate or 0) > ORPHAN_STALE then
            orphan.homeless[nameRealm] = nil
        end
    end
end

----------------------------------------------------------------------
-- A8 — Darkmoon Faire cooldown lifecycle (spec §5)
--
-- MODEL. The cooldown is 14,400 s of ONLINE time. It is not a wall-clock
-- deadline: a character that logs out at 3h30m remaining still owes 3h30m of
-- play when it logs back in. Three gates stop the clock:
--   * `offlineSince > 0`  — logout stamped but the login-resume handler has not
--     run yet. Ticking here would burn the whole offline span in one step.
--   * `rec.dmfInBoon`     — the fortune is suspended in a chronoboon; the game
--     does not run the cooldown against it, so neither do we (only the tick
--     timestamp advances so the freeze does not bank elapsed time).
--   * not `dmfCooldownActive` — nothing to tick.
--
-- The ONLY wall-clock rule is the offline forgiveness (A8.3): a character that
-- logged out RESTING, with DMF NOT booned, and has been gone >= 28,860 s has its
-- cooldown cleared. The previous code applied a flat 8h to EVERY offline record
-- with no resting/boon precondition, so a character parked in the open world got
-- a free reset.
--
-- BACKWARD COMPATIBILITY. `remainingOnlineSecs` / `lastTickEpoch` are additive.
-- A record written before this change carries neither: it reads as "on cooldown,
-- remaining unknown" (Store.DMFCooldownRemaining -> 0, which the UI renders as
-- "on CD"), and the first local tick seeds it to a full 4h rather than inventing
-- a number. Remote records never carry the new fields at all — see the FLAGGED
-- FOLLOW-UP note on Store.DMFCooldownRemaining.
----------------------------------------------------------------------

local function dmfCD(rec)
    if type(rec) ~= "table" then return nil end
    rec.dmfCooldown = rec.dmfCooldown or {}
    return rec.dmfCooldown
end

-- "3h 12m" for the chat lines (local, so store.lua does not depend on the UI).
local function dmfHM(secs)
    secs = math.max(0, math.floor(tonumber(secs) or 0))
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

local function dmfChat(msg)
    if ns and ns.Print then ns:Print("|cff44ff44" .. msg .. "|r") end
end

-- Seconds of ONLINE time still owed, for display. 0 means either "not on
-- cooldown" (caller checks rec.dmfCooldownActive first) or "on cooldown,
-- remaining unknown" — the UI contract keeps those distinct:
--   not active            -> "READY"
--   active, remaining > 0 -> the duration
--   active, remaining = 0 -> "on CD"
--
-- ⚠ FLAGGED FOLLOW-UP (no wire change in this batch): Protocol.DecodeCharacter
-- rebuilds `rec.dmfCooldown` as `{ offlineSince = <u32> }`, so a record that
-- arrives over the mesh never carries remainingOnlineSecs. Remote characters
-- therefore render the spec's tri-state (DMF in Boon / DMF on CD / DMFable) and
-- never a countdown — which is exactly what spec §5 "Display" prescribes for
-- other accounts. Syncing the real remaining would need a protocol bump.
function Store.DMFCooldownRemaining(rec, nowE)
    if type(rec) ~= "table" or not rec.dmfCooldownActive then return 0 end
    local cd = rec.dmfCooldown
    if type(cd) ~= "table" then return 0 end
    local rem = tonumber(cd.remainingOnlineSecs)
    if not rem or rem <= 0 then return 0 end
    return math.floor(rem)
end

-- Start (or hard re-stamp) a full 4h cooldown. Used on a fresh DMF gain, on an
-- unboon that restores DMF, and on entering a boon carrying DMF (spec §5 Start).
function Store.DMFCooldownStart(rec, nowE)
    local cd = dmfCD(rec)
    if not cd then return end
    nowE = nowE or serverNow()
    rec.dmfCooldownActive     = true
    cd.remainingOnlineSecs    = DMF_COOLDOWN_ONLINE
    cd.lastTickEpoch          = nowE
    cd.offlineSince           = 0
end

-- Clear the cooldown. `label` (a character name) prints the spec's green line.
function Store.DMFCooldownClear(rec, label, extra)
    local cd = dmfCD(rec)
    if not cd then return end
    rec.dmfCooldownActive  = false
    cd.remainingOnlineSecs = 0
    cd.lastTickEpoch       = 0
    cd.offlineSince        = 0
    if label then
        dmfChat("Darkmoon fortune cooldown is up for " .. label
                .. (extra and (" (" .. extra .. ")") or "") .. " — DMFable.")
    end
end

-- Decrement by elapsed ONLINE time. Returns true when this tick cleared the CD.
-- Called from the tracker on every capture of the played character.
function Store.DMFCooldownTick(rec, nowE, label)
    if type(rec) ~= "table" or not rec.dmfCooldownActive then return false end
    local cd = dmfCD(rec)
    nowE = nowE or serverNow()

    -- Legacy / never-seeded record: adopt a full 4h rather than invent a number.
    if tonumber(cd.remainingOnlineSecs) == nil then
        cd.remainingOnlineSecs = DMF_COOLDOWN_ONLINE
        cd.lastTickEpoch = nowE
        return false
    end

    -- Gate 1: logout stamped, login-resume has not run. Do not burn the gap.
    if (tonumber(cd.offlineSince) or 0) > 0 then return false end

    local last = tonumber(cd.lastTickEpoch) or 0
    if last <= 0 then cd.lastTickEpoch = nowE return false end
    local elapsed = nowE - last
    if elapsed < 0 then elapsed = 0 end
    cd.lastTickEpoch = nowE

    -- Gate 2: frozen while stashed in the boon (timestamp still advances, so the
    -- freeze cannot bank the elapsed time and dump it on the next tick).
    if rec.dmfInBoon then return false end

    cd.remainingOnlineSecs = cd.remainingOnlineSecs - elapsed
    if cd.remainingOnlineSecs <= 0 then
        Store.DMFCooldownClear(rec, label)
        return true
    end
    return false
end

-- Logout: a final tick, then stamp the offline epoch (spec §5 Logout).
function Store.DMFCooldownStampOffline(rec, nowE)
    if type(rec) ~= "table" or not rec.dmfCooldownActive then return end
    nowE = nowE or serverNow()
    Store.DMFCooldownTick(rec, nowE)
    if not rec.dmfCooldownActive then return end   -- the final tick cleared it
    local cd = dmfCD(rec)
    cd.offlineSince = nowE
end

-- Is this record eligible for the offline forgiveness? Pure; shared by the
-- login-resume path and the sibling sweep so the two can never drift.
function Store.DMFOfflineClearable(rec, nowE)
    if type(rec) ~= "table" or not rec.dmfCooldownActive then return false end
    local cd = rec.dmfCooldown
    if type(cd) ~= "table" then return false end
    local since = tonumber(cd.offlineSince) or 0
    if since <= 0 then return false end
    if not rec.isResting then return false end     -- A8.3: resting at logout
    if rec.dmfInBoon then return false end          -- A8.3: not stashed in a boon
    nowE = nowE or serverNow()
    return (nowE - since) >= DMF_OFFLINE_CLEAR, (nowE - since)
end

-- Login resume for the character we just logged into (spec §5 Login resume).
-- Either forgives the cooldown outright or resumes it from the SAME value with a
-- fresh tick timestamp (so the offline span is never billed as online time).
-- Returns true if the cooldown was cleared.
function Store.DMFCooldownResume(rec, nowE)
    if type(rec) ~= "table" or not rec.dmfCooldownActive then return false end
    local cd = dmfCD(rec)
    nowE = nowE or serverNow()
    local since = tonumber(cd.offlineSince) or 0
    if since <= 0 then
        cd.lastTickEpoch = nowE
        return false
    end
    local clearable, offlineFor = Store.DMFOfflineClearable(rec, nowE)
    if clearable then
        Store.DMFCooldownClear(rec, rec.nameRealm or "you", dmfHM(offlineFor) .. " offline")
        return true
    end
    cd.offlineSince  = 0
    cd.lastTickEpoch = nowE
    return false
end

----------------------------------------------------------------------
-- Retention: offline sibling DMF cooldown clear (resting-only, >= 8h01m)
--
-- Spec §5 "Sibling reconciliation": walk the OTHER characters of OUR OWN
-- account and apply the same offline-rest rule, bumping the data epoch so peers
-- re-sync, one green chat line per character that crossed.
--
-- ⚠ NARROWED from the previous behaviour, deliberately: the old sweep walked
-- EVERY account bucket, so it forgave cooldowns on characters owned by other
-- clients. Those records are the remote owner's to age out (and its sweep does
-- exactly that), and clearing them locally just loses to the next inbound sync.
----------------------------------------------------------------------

function Store.SweepOfflineDMF()
    local now = serverNow()
    local bucket = Store.GetSelfAccount(false)
    if not bucket or not bucket.characters then return 0 end
    local cleared = 0
    for nameRealm, rec in pairs(bucket.characters) do
        local clearable, offlineFor = Store.DMFOfflineClearable(rec, now)
        if clearable then
            Store.DMFCooldownClear(rec, nameRealm, dmfHM(offlineFor) .. " offline")
            -- Bump the data epoch so peers accept our clear on the next sync.
            rec.lastDataUpdate = now
            rec.ownerEpoch     = now
            cleared = cleared + 1
        end
    end
    return cleared
end

----------------------------------------------------------------------
-- Suite-namespace store (Daseeki.Sync v2, wave N5)
--
-- The persistent backing for the mesh-transported namespace payloads other
-- suite addons publish through Nexus. Shape:
--   syncNamespaces[nsKey][ownerKey] = { rev = <number>, updatedAt = <epoch>,
--                                       data = <table> }
-- `rev` is a per-owner monotonic revision (owner-wins-by-rev on merge); a
-- strictly-greater rev replaces the stored payload, an equal/lower rev is
-- rejected as stale. This is the same last-writer-wins discipline the mesh
-- character graph uses, applied per namespace owner.
----------------------------------------------------------------------

-- The whole namespace table (lazily created).
function Store.SyncNS()
    local d = Store.data
    d.syncNamespaces = d.syncNamespaces or {}
    return d.syncNamespaces
end

-- The owner->entry map for one namespace (lazily created when `create`).
function Store.SyncNSNamespace(nsKey, create)
    if type(nsKey) ~= "string" or nsKey == "" then return nil end
    local all = Store.SyncNS()
    local nsp = all[nsKey]
    if not nsp and create then
        nsp = {}
        all[nsKey] = nsp
    end
    return nsp
end

-- Read one owner's stored entry (or nil).
function Store.SyncNSGet(nsKey, ownerKey)
    local nsp = Store.SyncNSNamespace(nsKey, false)
    return nsp and nsp[ownerKey] or nil
end

-- Read one owner's payload data (or nil).
function Store.SyncNSGetData(nsKey, ownerKey)
    local e = Store.SyncNSGet(nsKey, ownerKey)
    return e and e.data or nil
end

-- The owner->entry map (never nil; empty table if absent).
function Store.SyncNSAll(nsKey)
    return Store.SyncNSNamespace(nsKey, false) or {}
end

-- PURE core: owner-wins-by-rev merge into a namespace table. `nsp` is the
-- owner->entry map. Returns "applied" if the incoming rev strictly beats the
-- stored one (or the owner is new), else "stale". Mutates `nsp` on apply.
function Store.SyncNSApply(nsp, ownerKey, rev, data, now)
    if type(ownerKey) ~= "string" or ownerKey == "" then return "stale" end
    rev = tonumber(rev) or 0
    local existing = nsp[ownerKey]
    local curRev = existing and existing.rev or -1
    if rev <= curRev then
        return "stale"
    end
    nsp[ownerKey] = { rev = rev, updatedAt = now or serverNow(), data = data }
    return "applied"
end

-- Live wrapper: put/merge one owner's payload into a namespace with owner-wins
-- rev gating. Returns "applied"/"stale".
function Store.SyncNSPut(nsKey, ownerKey, rev, data, now)
    local nsp = Store.SyncNSNamespace(nsKey, true)
    if not nsp then return "stale" end
    return Store.SyncNSApply(nsp, ownerKey, rev, data, now)
end

-- Remove one owner from a namespace (tombstone / eviction).
function Store.SyncNSDrop(nsKey, ownerKey)
    local nsp = Store.SyncNSNamespace(nsKey, false)
    if nsp then nsp[ownerKey] = nil end
end

-- Retention: drop stale entries (not refreshed within SYNCNS_STALE) and any
-- entry whose ownerKey names a tombstoned account (account-granular
-- namespaces). Char-granular namespaces like "bags" simply age out by
-- staleness. Emits a one-line size-sanity note if a namespace grows past
-- SYNCNS_SIZE_WARN owners. Returns the number of entries dropped.
function Store.SweepSyncNamespaces(now)
    now = now or serverNow()
    local all = Store.SyncNS()
    local dropped = 0
    for nsKey, nsp in pairs(all) do
        local count = 0
        for ownerKey, entry in pairs(nsp) do
            local stale = (now - (entry.updatedAt or 0)) > SYNCNS_STALE
            local tombstoned = Store.IsTombstoned and Store.IsTombstoned(ownerKey)
            if stale or tombstoned then
                nsp[ownerKey] = nil
                dropped = dropped + 1
            else
                count = count + 1
            end
        end
        if count > SYNCNS_SIZE_WARN and ns and ns.Print then
            ns:Print(string.format(
                "sync: namespace '%s' holds %d owners (over sanity threshold %d).",
                nsKey, count, SYNCNS_SIZE_WARN))
        end
    end
    return dropped
end

----------------------------------------------------------------------
-- Wave N5 migration: seed syncNamespaces["bags"] from the legacy Bags
-- cross-account cache.
--
-- Redefinition note (2026-07-28): the retired DaseekiWoWHelper never actually
-- populated a `DaseekiWoWHelperRemote` global inside Daseeki-Bags -- Bags used
-- an in-game DBAG mesh whose received cross-account snapshots live in the
-- `DaseekiBagsMesh` SavedVariable (shape per owner:
--   { ts, rev, class, race, sex, level, faction, itemCounts, currency, money }).
-- We import BOTH sources for forward-compatibility: any legacy
-- DaseekiWoWHelperRemote table if one is ever present (spec-literal path,
-- a no-op on today's data) AND DaseekiBagsMesh (the real legacy store). The
-- import is one-time (bagsImported guard), idempotent, and NON-DESTRUCTIVE --
-- the legacy globals are only read, never written.
----------------------------------------------------------------------

-- PURE core: build a { ownerKey -> { rev, updatedAt, data } } seed from the
-- legacy sources. `sources.mesh` is a DaseekiBagsMesh-shaped table
-- ({ [realm] = { [charName] = snapshot } }); `sources.helper` is an optional
-- DaseekiWoWHelperRemote-shaped table whose ["bags"] key (if a table) is
-- treated as an already-keyed { ownerKey -> snapshot|entry } map. Returns the
-- seed table plus a small stats table for validation/reporting.
function Store.BuildBagsNamespaceSeed(sources, now)
    now = now or serverNow()
    sources = sources or {}
    local seed = {}
    local stats = { fromMesh = 0, fromHelper = 0, realms = 0, bagsWithItems = 0 }

    local function put(ownerKey, snapshot, rev, ts)
        if type(ownerKey) ~= "string" or ownerKey == "" then return false end
        if type(snapshot) ~= "table" then return false end
        seed[ownerKey] = {
            rev = tonumber(rev) or tonumber(snapshot.rev) or 1,
            updatedAt = tonumber(ts) or tonumber(snapshot.ts) or now,
            data = snapshot,
        }
        if type(snapshot.itemCounts) == "table" and next(snapshot.itemCounts) then
            stats.bagsWithItems = stats.bagsWithItems + 1
        end
        return true
    end

    -- DaseekiBagsMesh: { [realm] = { [charName] = snapshot } } -> "Char-Realm".
    local mesh = sources.mesh
    if type(mesh) == "table" then
        for realm, byChar in pairs(mesh) do
            if type(realm) == "string" and type(byChar) == "table" then
                stats.realms = stats.realms + 1
                for charName, snap in pairs(byChar) do
                    if type(charName) == "string" and type(snap) == "table" then
                        if put(charName .. "-" .. realm, snap, snap.rev, snap.ts) then
                            stats.fromMesh = stats.fromMesh + 1
                        end
                    end
                end
            end
        end
    end

    -- DaseekiWoWHelperRemote.bags: already an ownerKey-keyed map (spec-literal
    -- path; absent on today's data). Each value is either a raw snapshot or a
    -- { rev, updatedAt/ts, data } entry. Mesh entries win on an ownerKey tie
    -- only when strictly newer by rev.
    local helper = sources.helper
    local helperBags = type(helper) == "table" and helper.bags or nil
    if type(helperBags) == "table" then
        for ownerKey, val in pairs(helperBags) do
            if type(ownerKey) == "string" and type(val) == "table" then
                local snap = val.data or val
                local rev  = val.rev or (snap and snap.rev)
                local ts   = val.updatedAt or val.ts or (snap and snap.ts)
                local existing = seed[ownerKey]
                if not existing or (tonumber(rev) or 1) > existing.rev then
                    if put(ownerKey, snap, rev, ts) then
                        stats.fromHelper = stats.fromHelper + 1
                    end
                end
            end
        end
    end

    stats.total = 0
    for _ in pairs(seed) do stats.total = stats.total + 1 end
    return seed, stats
end

-- Run the one-time import into DaseekiNexusData.syncNamespaces["bags"]. Reads
-- the legacy globals at runtime (present because Bags loads alongside Nexus
-- until its own cutover branch merges). Guarded + non-destructive. Returns the
-- stats table (or nil if already imported / nothing to import).
function Store.MigrateBags(now)
    if Store.data.bagsImported then return nil end
    now = now or serverNow()
    local G = _G or getfenv(0)
    local sources = {
        mesh   = (type(G.DaseekiBagsMesh) == "table") and G.DaseekiBagsMesh or nil,
        helper = (type(G.DaseekiWoWHelperRemote) == "table") and G.DaseekiWoWHelperRemote or nil,
    }
    -- Nothing to import: still set the guard so we don't re-scan every login.
    if not sources.mesh and not sources.helper then
        Store.data.bagsImported = true
        return nil
    end

    local seed, stats = Store.BuildBagsNamespaceSeed(sources, now)
    local nsp = Store.SyncNSNamespace("bags", true)
    -- Merge with owner-wins-by-rev so a re-run (or already-live mesh data)
    -- never clobbers a newer payload we already hold.
    for ownerKey, entry in pairs(seed) do
        Store.SyncNSApply(nsp, ownerKey, entry.rev, entry.data, entry.updatedAt)
    end
    Store.data.bagsImported = true
    if ns and ns.Print then
        ns:Print(string.format(
            "sync: imported %d cross-account Bags owner(s) into the 'bags' namespace.",
            stats.total))
    end
    return stats
end

----------------------------------------------------------------------
-- INVENTORY OWNERS GRAPH (inventory.lua) — additive area
--
-- The system of record for cross-account item counts and gold. Three inputs
-- converge here: our own capture, every peer payload the mesh delivered into
-- syncNamespaces["bags"], and the one-time Daseeki-Bags 1.x import. Entries are
-- shaped like the namespace store on purpose —
--   owners[ownerKey] = { rev, updatedAt, data = <the "bags" wire payload> }
-- — so projecting one into the other is a copy, not a translation.
--
-- Distinct from syncNamespaces["bags"] in one way that matters: that table is
-- the TRANSPORT and holds only what crossed (or is about to cross) the wire.
-- This one additionally holds this account's own alts, imported from Bags 1.x,
-- which no peer ever published and which the mesh has no way to carry.
--
-- The rev gate is owner-wins-by-rev with a timestamp tiebreak, because the two
-- inputs count revisions independently: Bags bumps per local edit, the mesh
-- bumps per publish, and the two sequences meet here.
----------------------------------------------------------------------

function Store.InventoryArea()
    local d = Store.data
    if type(d) ~= "table" then return nil end
    local a = d.inventory
    if type(a) ~= "table" then
        a = {}
        d.inventory = a
    end
    if type(a.owners) ~= "table" then a.owners = {} end
    if type(a.parts)  ~= "table" then a.parts  = {} end
    if a.schema   == nil then a.schema   = Store.INVENTORY_SCHEMA end
    if a.migrated == nil then a.migrated = false end
    return a
end

function Store.InventoryOwners()
    local a = Store.InventoryArea()
    return a and a.owners or {}
end

function Store.InventoryGet(ownerKey)
    local a = Store.InventoryArea()
    return a and a.owners[ownerKey] or nil
end

function Store.InventoryGetData(ownerKey)
    local e = Store.InventoryGet(ownerKey)
    return e and e.data or nil
end

-- Our own cold components for one character (bank + mail counts between visits).
function Store.InventoryParts(nameRealm, create)
    if type(nameRealm) ~= "string" or nameRealm == "" then return nil end
    local a = Store.InventoryArea()
    if not a then return nil end
    local p = a.parts[nameRealm]
    if not p and create then
        p = { bank = {}, mail = {}, mailN = 0, mailMoney = 0, bankAt = 0, mailAt = 0 }
        a.parts[nameRealm] = p
    end
    return p
end

-- PURE core: owner-wins-by-rev merge into an owners map. A strictly greater rev
-- wins; an equal rev wins only with a strictly newer timestamp (which keeps a
-- repeated import idempotent while still letting a same-rev refresh through).
-- Returns "applied" or "stale"; mutates `owners` on apply.
function Store.InventoryApply(owners, ownerKey, rev, data, now)
    if type(owners) ~= "table" then return "stale" end
    if type(ownerKey) ~= "string" or ownerKey == "" then return "stale" end
    if type(data) ~= "table" then return "stale" end
    rev = tonumber(rev) or 0
    now = tonumber(now) or 0
    local cur = owners[ownerKey]
    if cur then
        local curRev = tonumber(cur.rev) or 0
        local curAt  = tonumber(cur.updatedAt) or 0
        if rev < curRev then return "stale" end
        if rev == curRev and now <= curAt then return "stale" end
    end
    owners[ownerKey] = { rev = rev, updatedAt = now, data = data }
    return "applied"
end

-- Live wrapper.
function Store.InventoryPut(ownerKey, rev, data, now)
    local a = Store.InventoryArea()
    if not a then return "stale" end
    return Store.InventoryApply(a.owners, ownerKey, rev, data, now or serverNow())
end

function Store.InventoryDrop(ownerKey)
    local a = Store.InventoryArea()
    if a then a.owners[ownerKey] = nil end
end

----------------------------------------------------------------------
-- Convenience read accessors for other modules
----------------------------------------------------------------------

function Store.GetSettings()      return Store.db end
function Store.GetData()          return Store.data end
function Store.GetTimers()        return Store.data.timers end
-- Instance ledger accessors (consumed by instances.lua + the mesh sync path).
function Store.GetInstances()     return Store.data.instances end
function Store.GetInstancesForAID(aid)
    local all = Store.data.instances
    return all and all[aid or ""] or nil
end
function Store.GetSocial()        return Store.data.social end
function Store.GetManualLocation(nameRealm)
    return Store.data.manualLocations[nameRealm]
end
function Store.SetManualLocation(nameRealm, label)
    Store.data.manualLocations[nameRealm] = label
end

-- Per-character free-text note (replaces the location-override concept). Same
-- persistence scope as manualLocations (lives in DaseekiNexusData, preserved
-- across version wipes). Empty string normalizes to nil on write, and a stored
-- "" reads back as nil.
function Store.GetNote(nameRealm)
    local notes = Store.data.notes
    local n = notes and notes[nameRealm]
    if n == "" then return nil end
    return n
end
function Store.SetNote(nameRealm, text)
    if type(Store.data.notes) ~= "table" then Store.data.notes = {} end
    if text == "" then text = nil end
    Store.data.notes[nameRealm] = text
end

-- Faction settings block for the given faction ("Alliance"/"Horde").
function Store.GetFactionSettings(faction)
    local fs = Store.db.factionSettings
    return fs[faction] or fs.Alliance
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; registered as suite "store")
----------------------------------------------------------------------

local function testDefaults(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local s = defaultSettings()
    -- R3 schema additions.
    ck(s.mesh.channel == "", "mesh.channel default empty")
    local ag = s.factionSettings.Alliance.autoGroup
    ck(ag.sendToGuild == false and ag.sendToFriends == false
        and ag.sendToAnyone == false, "per-category send gates default off")
    ck(ag.whitelistEnabled == true, "whitelistEnabled default true")
    local fw = s.timerSettings.felwood
    ck(fw.flowerUpDuration == 0, "songflower UP? default indefinite (0)")
    ck(fw.flowerMinusDuration == 1500, "songflower minus default 1500s (25m)")
    ck(fw.worldFlowerSize == 14 and fw.worldTuberSize == 14
        and fw.worldTimerFont == 10 and fw.minimapFlowerSize == 12
        and fw.minimapTuberSize == 12, "5-field pin sizing present")
    -- Alert matrix is event-major with per-row sound KEYS.
    local a = s.timerSettings.alerts
    ck(a.questHandin ~= nil and a.rend == nil, "alert matrix event-major")
    ck(a.buffGain and a.buffGain.dmf ~= nil, "buffGain has a DMF row (item 24)")
    ck(a.pullTimer and a.pullTimer.battleShout ~= nil, "pull has battleShout row")
    ck(type(a.pullTimer.rend.sound) == "string", "per-row sound is a key string")
    -- Character record has the soulstone field.
    local rec = Store.NewCharacterRecord("X-Y")
    ck(rec.soulstoneReady == false, "record has soulstoneReady field")
    -- v2 experience/rest fields default to 0 (additive; applyDefaults/decode-safe).
    ck(rec.xp == 0 and rec.xpMax == 0 and rec.restedXP == 0,
        "record has xp/xpMax/restedXP fields defaulting to 0")
    -- Instances tab additive keys.
    ck(s.instancesWarnOnEntry == true, "instancesWarnOnEntry default ON")
    local d = defaultData()
    ck(type(d.instances) == "table", "defaultData has an instances table")
end

local function testAlertMigration(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- v1 buff-major DB with a mix of sound bools + channel toggles.
    local db = {
        settingsVersion = 1,
        timerSettings = { alerts = {
            rend = {
                pullTimer = { notify = true, chat = true, flash = false, sound = true },
                cdWarning = { notify = false, chat = false, flash = true, sound = false },
            },
            onyH = {
                buffGain = { notify = true, chat = false, flash = false, sound = true },
            },
        } },
    }
    Store.MigrateSettings(db)
    local a = db.timerSettings.alerts
    ck(a.rend == nil, "old buff-major key removed")
    ck(a.pullTimer and a.pullTimer.rend, "transposed to event-major")
    ck(a.pullTimer.rend.chat == true, "channel toggles preserved")
    ck(a.pullTimer.rend.sound == "RaidWarning", "sound=true -> event default key")
    ck(a.cdWarning.rend.sound == "None", "sound=false -> None")
    ck(a.buffGain.onyH.notify == true, "onyH buffGain migrated")
    ck(db.settingsVersion == 2, "settingsVersion bumped to 2")
    -- Idempotent: re-running does not corrupt the event-major shape.
    Store.MigrateSettings(db)
    ck(db.timerSettings.alerts.pullTimer.rend.chat == true, "migration idempotent")
end

-- B11 + B12: aura threshold + class-requirement seeding (spec §4.6 / §4.7).
local function testAuraSeeds(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    ------------------------------------------------------------------
    -- 1. Fresh store: every seed lands, in SECONDS.
    ------------------------------------------------------------------
    local db = { factionSettings = buildFactionSettings() }
    local A0 = db.factionSettings.Alliance.auraOpts
    ck(next(A0.thresholds) == nil, "pre-seed: thresholds ship empty")
    ck(A0.defaultsApplied == false, "pre-seed: defaultsApplied is false")

    Store.SeedAuraDefaults(db)
    local A = db.factionSettings.Alliance.auraOpts
    local H = db.factionSettings.Horde.auraOpts

    -- All nine keys present on both factions, none nil, both fields set.
    local KEYS = { "dmf", "ony", "dmtAP", "dmtSP", "dmtStam",
                   "songflower", "zg", "rend", "battleShout" }
    local nA, nH = 0, 0
    for _ in pairs(A.thresholds) do nA = nA + 1 end
    for _ in pairs(H.thresholds) do nH = nH + 1 end
    ck(nA == 9, "Alliance seeds exactly 9 thresholds (got " .. nA .. ")")
    ck(nH == 9, "Horde seeds exactly 9 thresholds (got " .. nH .. ")")
    for _, k in ipairs(KEYS) do
        local a, h = A.thresholds[k], H.thresholds[k]
        ck(type(a) == "table" and a.normal and a.minimum, "Alliance threshold " .. k .. " seeded")
        ck(type(h) == "table" and h.normal and h.minimum, "Horde threshold " .. k .. " seeded")
        if a then ck(a.normal >= a.minimum, "Alliance " .. k .. " normal >= minimum") end
        if h then ck(h.normal >= h.minimum, "Horde " .. k .. " normal >= minimum") end
    end

    -- Spot-checks against spec §4.6 (minutes * 60).
    ck(A.thresholds.dmf.normal == 7020, "spot: DMF Alliance normal = 117m (7020s)")
    ck(A.thresholds.dmf.minimum == 3540, "spot: DMF Alliance minimum = 59m (3540s)")
    ck(H.thresholds.ony.minimum == 5400, "spot: Ony Horde minimum = 90m (5400s)")
    ck(H.thresholds.ony.normal == 5700, "spot: Ony Horde normal = 95m (5700s)")
    ck(H.thresholds.dmf.minimum == 3600, "spot: DMF Horde minimum = 60m (3600s), not 59m")
    ck(A.thresholds.songflower.normal == 3480 and A.thresholds.songflower.minimum == 3420,
        "spot: Songflower 58/57 both factions (Alliance)")
    ck(H.thresholds.songflower.normal == 3480 and H.thresholds.songflower.minimum == 3420,
        "spot: Songflower 58/57 both factions (Horde)")
    ck(A.thresholds.battleShout.normal == 780 and A.thresholds.battleShout.minimum == 720,
        "spot: Battle Shout 13/12 (780/720s)")
    ck(A.thresholds.rend.normal == 3480 and A.thresholds.rend.minimum == 3420,
        "spot: Rend 58/57 (3480/3420s)")
    ck(A.thresholds.zg.normal == 5340 and H.thresholds.zg.normal == 5700,
        "spot: ZG differs by faction (89m vs 95m)")
    -- Units sanity: a minutes-valued seed would be absurdly small.
    ck(A.thresholds.dmf.normal > 600, "units: thresholds stored as seconds, not minutes")

    -- Class rules (spec §4.7).
    ck(A.rend.required.WARRIOR == true, "spot: rend WARRIOR required")
    ck(A.rend.required.ROGUE == true, "rend ROGUE required")
    ck(A.rend.optional.MAGE == true and A.rend.optional.PRIEST == true
        and A.rend.optional.DRUID == true and A.rend.optional.PALADIN == true
        and A.rend.optional.HUNTER == true and A.rend.optional.SHAMAN == true
        and A.rend.optional.WARLOCK == true, "rend: all 7 non-required classes optional")
    ck(next(A.rend.ignored) == nil, "rend: nothing ignored")
    ck(A.battleShout.required.WARRIOR == true and A.battleShout.required.ROGUE == true,
        "battleShout WARRIOR + ROGUE required")
    ck(A.battleShout.ignored.MAGE == true, "spot: battleShout MAGE ignored")
    ck(A.battleShout.ignored.HUNTER == true, "battleShout HUNTER ignored (spec §4.7)")
    ck(next(A.battleShout.optional) == nil, "battleShout: nothing optional")
    ck(A.rend.required.WARRIOR == H.rend.required.WARRIOR
        and A.battleShout.ignored.MAGE == H.battleShout.ignored.MAGE,
        "class rules identical on both factions")
    -- Seeds must be per-faction copies, never shared references.
    ck(A.thresholds.ony ~= H.thresholds.ony, "faction threshold tables are distinct objects")
    ck(A.rend ~= H.rend, "faction class maps are distinct objects")
    ck(A.rend ~= Store.CLASS_RULE_SEEDS.rend, "seeded map is a copy, not the shared seed")
    -- dmtSP is NOT part of the seed pass (its defaults ship in the tree).
    ck(A.dmtSP.ignored.WARRIOR == true and A.dmtSP.optional.MAGE == true,
        "dmtSP defaults untouched by the seed pass")

    ck(A.defaultsApplied == true and H.defaultsApplied == true,
        "defaultsApplied stamped on both factions")

    ------------------------------------------------------------------
    -- 2. Sticky flag: a deleted row is NOT resurrected by a re-seed.
    ------------------------------------------------------------------
    A.thresholds.zg = nil
    A.rend.required.WARRIOR = nil
    Store.SeedAuraDefaults(db)
    ck(A.thresholds.zg == nil, "sticky: deleted threshold row stays deleted")
    ck(A.rend.required.WARRIOR == nil, "sticky: demoted class stays demoted")
    -- ...and an owner edit survives.
    A.thresholds.dmf.normal = 42 * 60
    Store.SeedAuraDefaults(db)
    ck(A.thresholds.dmf.normal == 2520, "sticky: owner-edited threshold survives re-seed")

    ------------------------------------------------------------------
    -- 3. Pre-populated DB with the flag already set -> seeding skipped.
    ------------------------------------------------------------------
    local db2 = { factionSettings = buildFactionSettings() }
    local A2 = db2.factionSettings.Alliance.auraOpts
    A2.thresholds = { ony = { normal = 111, minimum = 22 } }
    A2.rend.required.MAGE = true
    A2.defaultsApplied = true
    Store.SeedAuraDefaults(db2)
    ck(A2.thresholds.ony.normal == 111, "flag set: existing threshold untouched")
    ck(A2.thresholds.dmf == nil, "flag set: no new threshold rows added")
    ck(A2.rend.required.MAGE == true and A2.rend.required.WARRIOR == nil,
        "flag set: class map untouched")

    ------------------------------------------------------------------
    -- 4. Legacy DB (no flag) that the owner already configured -> left alone,
    --    but stamped so it is never touched again.
    ------------------------------------------------------------------
    local db3 = { factionSettings = buildFactionSettings() }
    local A3 = db3.factionSettings.Alliance.auraOpts
    A3.thresholds = { songflower = { normal = 900, minimum = 300 } }
    A3.rend.optional.WARRIOR = true
    Store.SeedAuraDefaults(db3)
    ck(A3.thresholds.songflower.normal == 900, "legacy edited: threshold preserved")
    ck(A3.thresholds.dmf == nil, "legacy edited: non-empty table not merged into")
    ck(A3.rend.optional.WARRIOR == true and A3.rend.required.WARRIOR == nil,
        "legacy edited: configured class map preserved")
    ck(A3.defaultsApplied == true, "legacy edited: flag stamped so it never re-runs")
    -- Its Horde side was genuinely empty, so it DID get seeded (per-faction gate).
    ck(db3.factionSettings.Horde.auraOpts.thresholds.ony.normal == 5700,
        "per-faction gate: untouched Horde side still seeds")
    -- battleShout on A3 was empty in all three buckets -> seeded independently.
    ck(A3.battleShout.required.WARRIOR == true,
        "independent gate: empty battleShout map seeds even when rend was edited")

    ------------------------------------------------------------------
    -- 5. Robustness: no factionSettings / bad input must not throw.
    ------------------------------------------------------------------
    Store.SeedAuraDefaults(nil)
    Store.SeedAuraDefaults({})
    Store.SeedAuraDefaults({ factionSettings = "nope" })
    Store.SeedAuraDefaults({ factionSettings = { Alliance = {} } })

    ------------------------------------------------------------------
    -- 6. UI read path: Dashboard.GetThreshold must return the seeded values
    --    instead of the generic 20m/5m fallback.
    ------------------------------------------------------------------
    local D = ns and ns.Dashboard
    if D and D.GetThreshold then
        local savedDB = Store.db
        local liveDB = { factionSettings = buildFactionSettings() }
        Store.SeedAuraDefaults(liveDB)
        Store.db = liveDB
        local sf = D.GetThreshold("Alliance", "songflower")
        ck(sf and sf.normal == 3480 and sf.minimum == 3420,
            "GetThreshold(Alliance, songflower) -> seeded 58/57, not the 20m/5m fallback")
        local onyH = D.GetThreshold("Horde", "ony")
        ck(onyH and onyH.minimum == 5400, "GetThreshold(Horde, ony) -> seeded 90m minimum")
        local dmfA = D.GetThreshold("Alliance", "dmf")
        ck(dmfA and dmfA.normal == 7020, "GetThreshold(Alliance, dmf) -> seeded 117m normal")
        -- Keys with no threshold still fall back to the generic default.
        local none = D.GetThreshold("Alliance", nil)
        ck(none and none.normal == 1200, "nil thresholdKey still falls back to 20m/5m")
        -- Class-rule read path (the red-missing attention model).
        if D.ClassRuleState then
            ck(D.ClassRuleState("rend", "WARRIOR", "Alliance") == "required",
                "ClassRuleState rend/WARRIOR -> required")
            ck(D.ClassRuleState("rend", "MAGE", "Alliance") == "optional",
                "ClassRuleState rend/MAGE -> optional")
            ck(D.ClassRuleState("battleShout", "MAGE", "Alliance") == "ignored",
                "ClassRuleState battleShout/MAGE -> ignored")
            ck(D.ClassRuleState("battleShout", "ROGUE", "Horde") == "required",
                "ClassRuleState battleShout/ROGUE (Horde) -> required")
        end
        Store.db = savedDB
    end
end

-- Auto-summon trigger seeds (spec §13). Mirrors testAuraSeeds: the sticky-flag
-- contract is what keeps an unchecked trigger unchecked, so it is tested the
-- same five ways (fresh / sticky / pre-flagged / legacy-edited / robustness).
local function testAutoSummonSeeds(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local ON  = { "dmf", "dragonslayer", "zandalar", "songflower",
                  "warchief", "battleShout", "fff" }
    local OFF = { "fengus", "moldar", "slipkik" }

    ------------------------------------------------------------------
    -- 1. Fresh store: the seven ON triggers land, the three DMT stay absent.
    ------------------------------------------------------------------
    local db = { factionSettings = buildFactionSettings() }
    local A0 = db.factionSettings.Alliance.autoSummon
    ck(next(A0.triggers) == nil, "pre-seed: triggers ship empty")
    ck(A0.defaultsApplied == false, "pre-seed: autoSummon.defaultsApplied is false")
    ck(A0.enabled == false, "pre-seed: auto-accept ships OFF")

    Store.SeedAutoSummonDefaults(db)
    local A = db.factionSettings.Alliance.autoSummon
    local H = db.factionSettings.Horde.autoSummon

    for _, f in ipairs({ { "Alliance", A }, { "Horde", H } }) do
        local name, as = f[1], f[2]
        local n = 0
        for _ in pairs(as.triggers) do n = n + 1 end
        ck(n == 7, name .. ": exactly 7 triggers seeded (got " .. n .. ")")
        for _, k in ipairs(ON) do
            ck(as.triggers[k] == true, name .. ": trigger " .. k .. " seeded ON")
        end
        -- OFF is ABSENCE, not an explicit false -- the options UI writes nil for
        -- an unchecked box, so a `false` here would be a row it can never make.
        for _, k in ipairs(OFF) do
            ck(as.triggers[k] == nil, name .. ": DMT trigger " .. k .. " absent (off)")
        end
        ck(as.freshBuffWindow == 19, name .. ": freshBuffWindow is the spec's 19s")
        ck(as.defaultsApplied == true, name .. ": defaultsApplied stamped")
        -- OWNER DECISION: seeds without enable.
        ck(as.enabled == false, name .. ": auto-accept still OFF after seeding")
    end

    ------------------------------------------------------------------
    -- 2. Sticky flag: an unchecked trigger is NOT resurrected by a re-seed.
    ------------------------------------------------------------------
    A.triggers.dmf = nil                      -- owner unticks DMF
    Store.SeedAutoSummonDefaults(db)
    ck(A.triggers.dmf == nil, "unticked trigger stays unticked across a re-seed")
    ck(A.triggers.ony == nil, "re-seed did not invent a non-catalog key")
    A.freshBuffWindow = 30                    -- owner retunes the window
    Store.SeedAutoSummonDefaults(db)
    ck(A.freshBuffWindow == 30, "owner's freshBuffWindow survives a re-seed")

    ------------------------------------------------------------------
    -- 3. Pre-populated DB with the flag already set -> seeding skipped whole.
    ------------------------------------------------------------------
    local db2 = { factionSettings = buildFactionSettings() }
    local A2 = db2.factionSettings.Alliance.autoSummon
    A2.defaultsApplied = true
    Store.SeedAutoSummonDefaults(db2)
    ck(next(A2.triggers) == nil, "flag already set -> triggers left empty")

    ------------------------------------------------------------------
    -- 4. Legacy DB (no flag) the owner already configured -> left EXACTLY as-is.
    ------------------------------------------------------------------
    local db3 = { factionSettings = buildFactionSettings() }
    local A3 = db3.factionSettings.Alliance.autoSummon
    A3.triggers = { slipkik = true }          -- an owner-built set, DMT-only
    Store.SeedAutoSummonDefaults(db3)
    ck(A3.triggers.slipkik == true, "legacy edited: owner's trigger kept")
    ck(A3.triggers.dmf == nil, "legacy edited: no merge into a touched table")
    ck(A3.defaultsApplied == true, "legacy edited: flag stamped so it never re-runs")
    ck(db3.factionSettings.Horde.autoSummon.triggers.dmf == true,
        "legacy edited: the untouched faction still seeds normally")

    ------------------------------------------------------------------
    -- 4b. Pre-batch install whose ticks are all DEAD aura keys. options.lua
    --     used to write "ony"/"zg"/"rend"/"dmtAP"/... on its trigger boxes, and
    --     Auto.ScanTriggerBuffs never reads those -- so the owner has zero
    --     WORKING triggers and seeding is still purely additive.
    ------------------------------------------------------------------
    ck(triggersUnseeded({}) == true, "dead-key: an empty table is unseeded")
    ck(triggersUnseeded({ ony = true, zg = true, rend = true }) == true,
        "dead-key: only stale aura keys reads as unseeded")
    ck(triggersUnseeded({ dragonslayer = true }) == false,
        "dead-key: one live trigger means the owner has a real selection")
    ck(triggersUnseeded({ dragonslayer = false }) == true,
        "dead-key: a falsy live key does not count as a selection")
    ck(triggersUnseeded("nope") == true, "dead-key: a non-table reads as unseeded")

    local db4 = { factionSettings = buildFactionSettings() }
    local A4 = db4.factionSettings.Alliance.autoSummon
    A4.triggers = { ony = true, rend = true, dmtAP = true }   -- pre-batch ticks
    Store.SeedAutoSummonDefaults(db4)
    ck(A4.triggers.dragonslayer == true, "dead-key install: live Ony trigger seeded")
    ck(A4.triggers.warchief == true, "dead-key install: live Rend trigger seeded")
    ck(A4.triggers.fengus == nil, "dead-key install: DMT stays off (seed set is the 7)")
    -- Dead keys are inert; we do NOT delete them (no destructive migrations).
    ck(A4.triggers.ony == true, "dead-key install: stale key left in place, not deleted")

    -- A genuinely-configured install is still never merged into.
    local db5 = { factionSettings = buildFactionSettings() }
    local A5 = db5.factionSettings.Alliance.autoSummon
    A5.triggers = { ony = true, dragonslayer = true }   -- stale AND live
    Store.SeedAutoSummonDefaults(db5)
    ck(A5.triggers.zandalar == nil,
        "a live trigger present -> seeding skipped even alongside stale keys")

    ------------------------------------------------------------------
    -- 5. Robustness: bad input must not throw.
    ------------------------------------------------------------------
    Store.SeedAutoSummonDefaults(nil)
    Store.SeedAutoSummonDefaults({})
    Store.SeedAutoSummonDefaults({ factionSettings = "nope" })
    Store.SeedAutoSummonDefaults({ factionSettings = { Alliance = {} } })
    ck(true, "SeedAutoSummonDefaults survives malformed input")

    ------------------------------------------------------------------
    -- 6. Trigger keys must exist in auto.lua's authoritative catalog. This is
    --    the guard that would have caught seeding the AURA keys (ony/zg/rend)
    --    instead of the trigger keys (dragonslayer/zandalar/warchief).
    ------------------------------------------------------------------
    if ns.Auto and type(ns.Auto.SUMMON_TRIGGER_BUFFS) == "table" then
        local known = {}
        for _, d in ipairs(ns.Auto.SUMMON_TRIGGER_BUFFS) do known[d.key] = true end
        for _, k in ipairs(Store.SUMMON_TRIGGER_SEEDS) do
            ck(known[k] == true, "seed key '" .. k .. "' exists in Auto.SUMMON_TRIGGER_BUFFS")
        end
        -- SUMMON_TRIGGER_KEYS must mirror the catalog EXACTLY, both directions:
        -- a key missing here would be misread as dead and could let the seeder
        -- overwrite a real selection.
        local mine = {}
        for _, k in ipairs(Store.SUMMON_TRIGGER_KEYS) do
            mine[k] = true
            ck(known[k] == true, "SUMMON_TRIGGER_KEYS '" .. k .. "' exists in the catalog")
        end
        for k in pairs(known) do
            ck(mine[k] == true, "catalog key '" .. k .. "' is present in SUMMON_TRIGGER_KEYS")
        end
        ck(#Store.SUMMON_TRIGGER_KEYS == 10, "10 trigger keys (7 seeded on + 3 DMT off)")
        ck(#Store.SUMMON_TRIGGER_SEEDS == 7, "7 triggers seeded ON per spec §13")
    end

    ------------------------------------------------------------------
    -- 7. The options UI must offer a checkbox for every seeded trigger, keyed
    --    the way the engine reads it. This is the exact defect this batch fixed:
    --    options.lua's TRIGGER_DEFS carried the AURA keys, so six of the ten
    --    boxes wrote settings Auto.ScanTriggerBuffs never looked at.
    ------------------------------------------------------------------
    if ns.Options and type(ns.Options.TRIGGER_DEFS) == "table" then
        local ui = {}
        for _, d in ipairs(ns.Options.TRIGGER_DEFS) do ui[d.key] = true end
        for _, k in ipairs(Store.SUMMON_TRIGGER_KEYS) do
            ck(ui[k] == true, "options TRIGGER_DEFS offers a checkbox for '" .. k .. "'")
        end
    end
end

local function testSongflowerMigration(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Stored old defaults are rewritten to the accurate values.
    local db = { timerSettings = { felwood = {
        flowerMinusDuration = 120, flowerUpDuration = 5 } } }
    Store.MigrateSongflowerDefaults(db)
    ck(db.timerSettings.felwood.flowerMinusDuration == 1500, "120 minus -> 1500")
    ck(db.timerSettings.felwood.flowerUpDuration == 0, "5 UP? -> 0")
    -- Idempotent by nature: re-running leaves the corrected values alone.
    Store.MigrateSongflowerDefaults(db)
    ck(db.timerSettings.felwood.flowerMinusDuration == 1500, "songflower migration idempotent")
    ck(db.timerSettings.felwood.flowerExpiredWindow == 300, "expired window seeded to 300")

    -- ROUND-17: ANY sub-respawn value is poison, not just the literal 120. An SN
    -- import wrote SN's own minus-timer here, so 90 / 300 / 900 were all
    -- reachable and all made a 25-minute flower report itself available early.
    -- The old migration only matched 120 and walked past every one of them.
    for _, poisoned in ipairs({ 5, 90, 120, 300, 900, 1499 }) do
        local p = { timerSettings = { felwood = { flowerMinusDuration = poisoned } } }
        Store.MigrateSongflowerDefaults(p)
        ck(p.timerSettings.felwood.flowerMinusDuration == 1500,
           "poisoned minus " .. poisoned .. " -> 1500")
    end

    -- At or above the true respawn the value cannot under-report, so it is left
    -- alone: either our own old default or a deliberate choice.
    local custom = { timerSettings = { felwood = {
        flowerMinusDuration = 1800, flowerUpDuration = 3 } } }
    Store.MigrateSongflowerDefaults(custom)
    ck(custom.timerSettings.felwood.flowerMinusDuration == 1800, "custom minus 1800 untouched")
    ck(custom.timerSettings.felwood.flowerUpDuration == 3, "custom UP? 3 untouched")

    -- An existing expired-window choice is never overwritten.
    local win = { timerSettings = { felwood = { flowerExpiredWindow = 60 } } }
    Store.MigrateSongflowerDefaults(win)
    ck(win.timerSettings.felwood.flowerExpiredWindow == 60, "existing expired window preserved")

    -- Non-numeric junk must not error or be treated as a number.
    local junk = { timerSettings = { felwood = { flowerMinusDuration = "soon" } } }
    Store.MigrateSongflowerDefaults(junk)
    ck(junk.timerSettings.felwood.flowerExpiredWindow == 300, "junk minus still seeds the window")

    -- Missing felwood block is a safe no-op.
    Store.MigrateSongflowerDefaults({})
    Store.MigrateSongflowerDefaults(nil)
end

local function testNotes(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local saved = Store.data
    Store.data = { notes = {}, manualLocations = {} }
    -- Round-trip.
    Store.SetNote("A-Realm", "meet at inn")
    ck(Store.GetNote("A-Realm") == "meet at inn", "note round-trip")
    -- Empty string normalizes to nil.
    Store.SetNote("A-Realm", "")
    ck(Store.GetNote("A-Realm") == nil, "empty string -> nil on read")
    ck(Store.data.notes["A-Realm"] == nil, "empty string stored as nil")
    Store.data = saved
    -- Migration: copies location into empty note, preserves existing note,
    -- never destroys manualLocations.
    local data = {
        notes = { ["C-Realm"] = "kept" },
        manualLocations = { ["B-Realm"] = "Stormwind", ["C-Realm"] = "Ironforge" },
    }
    Store.MigrateNotes(data)
    ck(data.notes["B-Realm"] == "Stormwind", "location copied into empty note")
    ck(data.notes["C-Realm"] == "kept", "existing note not overwritten")
    ck(data.manualLocations["B-Realm"] == "Stormwind", "manualLocations not destroyed")
    ck(data.notesMigrated == true, "notesMigrated marker set")
    -- Idempotent via marker: clearing a note then re-running does not re-copy.
    data.notes["B-Realm"] = nil
    Store.MigrateNotes(data)
    ck(data.notes["B-Realm"] == nil, "note migration idempotent via marker")
end

-- K guard: a nameless inbound record must be dropped (never crash the receive
-- batch). Regression for the "other account's characters not showing online" bug.
local function testInboundNameGuard(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedCount = Store._droppedNamelessInbound
    Store._droppedNamelessInbound = 0
    local rec = Store.NewCharacterRecord(nil)
    rec.ownerEpoch = 1
    -- nil / empty nameRealm from a non-self account: dropped, not applied, no error.
    local okNil   = Store.WriteInboundCharacter("42", nil, rec, "42")
    local okEmpty = Store.WriteInboundCharacter("42", "",  rec, "42")
    ck(okNil == false,   "nil nameRealm inbound dropped (no crash)")
    ck(okEmpty == false, "empty nameRealm inbound dropped")
    ck(Store._droppedNamelessInbound == 2, "dropped-nameless counter incremented twice")
    -- A real nameRealm from a non-self account still writes through.
    local okReal = Store.WriteInboundCharacter("42", "Peer-Realm", rec, "42")
    ck(okReal == true, "named inbound from another account still applied")
    -- Cleanup the throwaway account bucket so the shared store is left untouched.
    if Store.data and Store.data.accounts then Store.data.accounts["42"] = nil end
    Store._droppedNamelessInbound = savedCount
end

-- Non-wire fields must SURVIVE an inbound replace, while everything the wire
-- carries must still be authoritatively overwritten (including being cleared).
-- Drives the real Store.WriteInboundCharacter, not the helper in isolation, so
-- the carry is proven to happen on the actual write path.
local function testNonWireCarryForward(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local AID = "43"
    local savedAcct = Store.data and Store.data.accounts and Store.data.accounts[AID]

    -- Seed the "already adopted over the SEGMENT path" copy: it carries the
    -- non-wire fields a whole-table record brings with it.
    local seeded = Store.NewCharacterRecord("Peer-Realm")
    seeded.ownerEpoch = 100
    seeded.level      = 60
    seeded.location   = "Orgrimmar"
    seeded.attunements = { MC = true, Ony = false }
    seeded.dmfCooldownActive = true
    seeded.dmfCooldown = { offlineSince = 0, remainingOnlineSecs = 9000, lastTickEpoch = 555 }
    ck(Store.WriteInboundCharacter(AID, "Peer-Realm", seeded, AID) == true,
        "seed write applied")

    -- Now a STATE push: a freshly decoded binary record. It has NO attunements
    -- and a dmfCooldown rebuilt as { offlineSince } only — exactly what
    -- Protocol.DecodeCharacter produces.
    local push = Store.NewCharacterRecord("Peer-Realm")
    push.ownerEpoch = 200
    push.level      = 60
    push.location   = "Blackrock Depths"
    push.attunements = nil
    push.dmfCooldownActive = true
    push.dmfCooldown = { offlineSince = 0 }
    ck(Store.WriteInboundCharacter(AID, "Peer-Realm", push, AID) == true,
        "state push applied")

    local held = Store.GetCharacter("Peer-Realm", AID)
    ck(held ~= nil, "record still present after the push")
    -- Non-wire fields survived.
    ck(held and type(held.attunements) == "table" and held.attunements.MC == true,
        "attunements survived the inbound replace")
    ck(held and held.attunements and held.attunements.Ony == false,
        "a FALSE attunement flag survives too (not just truthy ones)")
    ck(held and held.dmfCooldown and held.dmfCooldown.remainingOnlineSecs == 9000,
        "dmfCooldown.remainingOnlineSecs survived")
    ck(held and held.dmfCooldown and held.dmfCooldown.lastTickEpoch == 555,
        "dmfCooldown.lastTickEpoch survived")
    -- Wire fields were still authoritatively replaced.
    ck(held and held.location == "Blackrock Depths",
        "wire field still wins (location replaced)")
    ck(held and held.ownerEpoch == 200, "wire epoch still wins")

    -- The wire must be able to CLEAR: an incoming record that carries its own
    -- attunement matrix replaces ours rather than being merged into it, and a
    -- wire-borne dmfCooldownActive=false drops the stale online-time accounting.
    local push2 = Store.NewCharacterRecord("Peer-Realm")
    push2.ownerEpoch  = 300
    push2.attunements = { MC = false }
    push2.dmfCooldownActive = false
    push2.dmfCooldown = { offlineSince = 0 }
    ck(Store.WriteInboundCharacter(AID, "Peer-Realm", push2, AID) == true,
        "clearing push applied")
    held = Store.GetCharacter("Peer-Realm", AID)
    ck(held and held.attunements and held.attunements.MC == false,
        "an incoming matrix REPLACES ours (no blanket merge)")
    ck(held and held.attunements and held.attunements.Ony == nil,
        "the old matrix is not merged underneath the incoming one")
    ck(held and held.dmfCooldown and held.dmfCooldown.remainingOnlineSecs == nil,
        "a wire-borne cooldown CLEAR is not undone by the carry-forward")

    -- Notes are not record fields at all — prove the write path leaves them be.
    Store.SetNote("Peer-Realm", "carry me")
    local push3 = Store.NewCharacterRecord("Peer-Realm")
    push3.ownerEpoch = 400
    Store.WriteInboundCharacter(AID, "Peer-Realm", push3, AID)
    ck(Store.GetNote("Peer-Realm") == "carry me",
        "notes live outside the record and are untouched by an inbound write")
    Store.SetNote("Peer-Realm", "")

    -- The helper itself is a no-op on junk arguments.
    ck(Store.CarryNonWireFields(nil, nil) == nil, "helper tolerates nil arguments")

    if Store.data and Store.data.accounts then Store.data.accounts[AID] = savedAcct end
end

-- Rested% derivation matrix: 0, partial, exactly-capped, over-cap, level-60,
-- and missing/malformed fields. Pure — asserts Store.RestedPercent semantics.
local function testRestedPercent(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function rec(xpMax, rested) return { xpMax = xpMax, restedXP = rested } end

    -- 0 rested on a sub-60 character -> 0% (NOT nil; xpMax is valid).
    ck(Store.RestedPercent(rec(1000, 0)) == 0, "0 rested -> 0%")
    -- Partial: 250/1000 -> 25%.
    ck(Store.RestedPercent(rec(1000, 250)) == 25, "250/1000 -> 25%")
    -- Half a level: 500/1000 -> 50%.
    ck(Store.RestedPercent(rec(1000, 500)) == 50, "500/1000 -> 50%")
    -- Exactly at the 1.5-level cap: 1500/1000 -> 150 (not clamped below).
    ck(Store.RestedPercent(rec(1000, 1500)) == 150, "1500/1000 -> 150% (cap)")
    -- Over the cap: 3000/1000 raw 300 -> clamped to 150.
    ck(Store.RestedPercent(rec(1000, 3000)) == 150, "over-cap clamps to 150%")
    -- Level 60 / no XP data: xpMax 0 -> nil (UI shows "Level 60" only).
    ck(Store.RestedPercent(rec(0, 0)) == nil, "xpMax 0 (level 60) -> nil")
    ck(Store.RestedPercent(rec(0, 123)) == nil, "xpMax 0 with stray rested -> nil")
    -- Missing / malformed fields -> nil.
    ck(Store.RestedPercent({ xpMax = 1000 }) == nil, "missing restedXP -> nil")
    ck(Store.RestedPercent({ restedXP = 100 }) == nil, "missing xpMax -> nil")
    ck(Store.RestedPercent({ xpMax = "x", restedXP = 1 }) == nil, "non-numeric xpMax -> nil")
    ck(Store.RestedPercent(nil) == nil, "nil rec -> nil")
    ck(Store.RestedPercent("nope") == nil, "non-table rec -> nil")
    -- A freshly-defaulted record (all zero) reads as level-60-style nil.
    ck(Store.RestedPercent(Store.NewCharacterRecord("X-Y")) == nil,
        "default record (0/0/0) -> nil")
end

-- A8 — the DMF cooldown model. Everything here is driven with EXPLICIT epochs so
-- the suite is deterministic; nothing touches the real clock.
local function testDMFCooldown(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T0 = 1700000000

    -- Constants are the spec's, not the old flat 8h.
    ck(Store.DMF_COOLDOWN_ONLINE == 14400, "DMF online cooldown is 14400s (4h)")
    ck(Store.DMF_OFFLINE_CLEAR == 28860, "DMF offline clear is 28860s (8h + 60s)")

    -- ---- start + online tick decrement ------------------------------------
    local rec = Store.NewCharacterRecord("Alt-Realm")
    Store.DMFCooldownStart(rec, T0)
    ck(rec.dmfCooldownActive == true, "start: cooldown active")
    ck(Store.DMFCooldownRemaining(rec) == 14400, "start: remaining is a full 4h")
    ck(rec.dmfCooldown.offlineSince == 0, "start: offline stamp cleared")

    Store.DMFCooldownTick(rec, T0 + 600)
    ck(Store.DMFCooldownRemaining(rec) == 13800, "tick: 600s online -> 13800 left")
    Store.DMFCooldownTick(rec, T0 + 600)     -- same epoch twice = no double-bill
    ck(Store.DMFCooldownRemaining(rec) == 13800, "tick: repeated at the same epoch is a no-op")

    -- ---- frozen while stashed in the boon ---------------------------------
    rec.dmfInBoon = true
    Store.DMFCooldownTick(rec, T0 + 4000)
    ck(Store.DMFCooldownRemaining(rec) == 13800, "boon freeze: remaining does not move")
    ck(rec.dmfCooldown.lastTickEpoch == T0 + 4000,
       "boon freeze: tick timestamp still advances (no banked time)")
    rec.dmfInBoon = false
    Store.DMFCooldownTick(rec, T0 + 4100)
    ck(Store.DMFCooldownRemaining(rec) == 13700,
       "unfreeze: only the 100s since the last tick is billed, not the frozen span")

    -- ---- reaching zero clears --------------------------------------------
    Store.DMFCooldownTick(rec, T0 + 4100 + 13700)
    ck(rec.dmfCooldownActive == false, "tick to zero: cooldown cleared")
    ck(Store.DMFCooldownRemaining(rec) == 0, "tick to zero: remaining reads 0")

    -- ---- logout stamp then the pending-offline gate -----------------------
    rec = Store.NewCharacterRecord("Alt-Realm")
    Store.DMFCooldownStart(rec, T0)
    Store.DMFCooldownStampOffline(rec, T0 + 1000)
    ck(rec.dmfCooldown.offlineSince == T0 + 1000, "logout: offlineSince stamped")
    ck(Store.DMFCooldownRemaining(rec) == 13400, "logout: a final tick ran first")
    Store.DMFCooldownTick(rec, T0 + 100000)
    ck(Store.DMFCooldownRemaining(rec) == 13400,
       "offline gate: no tick while an offline stamp is pending")

    -- ---- resume: not resting -> resumes at the SAME value -----------------
    rec.isResting = false
    local wasCleared = Store.DMFCooldownResume(rec, T0 + 1000 + 40000)
    ck(wasCleared == false, "resume (not resting): NOT cleared even after 11h offline")
    ck(Store.DMFCooldownRemaining(rec) == 13400, "resume (not resting): value preserved")
    ck(rec.dmfCooldown.offlineSince == 0, "resume: offline stamp cleared")
    ck(rec.dmfCooldown.lastTickEpoch == T0 + 1000 + 40000,
       "resume: tick epoch re-based so the offline span is never billed")

    -- ---- resume: resting + long enough -> cleared -------------------------
    rec = Store.NewCharacterRecord("Alt-Realm")
    Store.DMFCooldownStart(rec, T0)
    rec.isResting = true
    Store.DMFCooldownStampOffline(rec, T0 + 10)
    ck(Store.DMFOfflineClearable(rec, T0 + 10 + 28859) == false,
       "offline clear: 28859s is one second short")
    ck(Store.DMFOfflineClearable(rec, T0 + 10 + 28860) == true,
       "offline clear: 28860s exactly is enough")
    Store.DMFCooldownResume(rec, T0 + 10 + 28860)
    ck(rec.dmfCooldownActive == false, "resume (resting, >=8h01m): cleared")

    -- ---- resume: resting but BOONED -> not cleared (A8.3) -----------------
    rec = Store.NewCharacterRecord("Alt-Realm")
    Store.DMFCooldownStart(rec, T0)
    rec.isResting = true
    rec.dmfInBoon = true
    Store.DMFCooldownStampOffline(rec, T0 + 10)
    ck(Store.DMFOfflineClearable(rec, T0 + 100000) == false,
       "offline clear: booned DMF is never forgiven, however long the logout")
    ck(Store.DMFCooldownResume(rec, T0 + 100000) == false, "resume (booned): not cleared")

    -- ---- legacy record tolerance (additive SV) ----------------------------
    local legacy = { dmfCooldownActive = true, dmfCooldown = { offlineSince = 0 } }
    ck(Store.DMFCooldownRemaining(legacy) == 0,
       "legacy record (no remainingOnlineSecs): reads 0 -> UI shows 'on CD'")
    Store.DMFCooldownTick(legacy, T0)
    ck(legacy.dmfCooldown.remainingOnlineSecs == 14400,
       "legacy record: the first tick SEEDS a full 4h rather than inventing a number")
    Store.DMFCooldownTick(legacy, T0 + 60)
    ck(Store.DMFCooldownRemaining(legacy) == 14340, "legacy record: ticks normally after seeding")

    -- ---- not-on-cooldown records are inert --------------------------------
    ck(Store.DMFCooldownRemaining({ dmfCooldownActive = false }) == 0, "inactive -> 0")
    ck(Store.DMFCooldownRemaining(nil) == 0, "nil rec -> 0")
    ck(Store.DMFCooldownTick({ dmfCooldownActive = false }, T0) == false, "inactive tick -> no-op")
    ck(Store.DMFOfflineClearable(nil) == false, "nil rec is not clearable")
end

----------------------------------------------------------------------
-- A9.1 — item cooldowns as start epochs
----------------------------------------------------------------------
local function testItemCdEpochs(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = 1700000000

    -- ---- the acceptance window (spec §6: [now-3605, now+5]) ----------------
    ck(Store.ItemCdEpochSane(T - 3605, T, 3600) == true,  "epoch at now-3605 accepted (edge)")
    ck(Store.ItemCdEpochSane(T - 3606, T, 3600) == false, "epoch at now-3606 rejected")
    ck(Store.ItemCdEpochSane(T + 5, T, 3600) == true,     "epoch at now+5 accepted (edge)")
    ck(Store.ItemCdEpochSane(T + 6, T, 3600) == false,    "epoch at now+6 rejected (clock skew)")
    ck(Store.ItemCdEpochSane(0, T, 3600) == false,        "epoch 0 is not a cooldown")

    -- ---- remaining is DERIVED ----------------------------------------------
    local rec = { hearthstoneCDStart = T - 1200, chronoboonCDStart = 0 }
    ck(Store.ItemCdRemaining(rec, "hearthstone", T) == 2400, "hearth: 3600-(now-epoch) = 2400")
    ck(Store.ItemCdRemaining(rec, "hearthstone", T + 600) == 1800, "hearth: 10 min later = 1800")
    ck(Store.ItemCdRemaining(rec, "hearthstone", T + 2400) == 0, "hearth: exactly elapsed -> 0")
    ck(Store.ItemCdRemaining(rec, "hearthstone", T + 99999) == 0, "hearth: long past -> 0, never negative")
    ck(Store.ItemCdRemaining(rec, "chronoboon", T) == 0, "a zero epoch reads ready")
    ck(Store.ItemCdRemaining(nil, "hearthstone", T) == 0, "nil record -> 0")
    ck(Store.ItemCdRemaining(rec, "nonsense", T) == 0, "unknown cooldown key -> 0")

    -- An epoch-native record NEVER falls back to the mirror, even at 0. This is
    -- the regression that let a healed cooldown come back from the dead.
    local healed = { hearthstoneCDStart = 0, hearthstoneCD = 1200, lastDataUpdate = T }
    ck(Store.ItemCdRemaining(healed, "hearthstone", T) == 0,
       "epoch-native record ignores a stale legacy mirror")

    -- ---- the legacy fallback (records with NO epoch field at all) ----------
    local legacy = { hearthstoneCD = 1200, lastDataUpdate = T }
    ck(Store.ItemCdRemaining(legacy, "hearthstone", T) == 1200, "legacy record still reads")
    ck(Store.ItemCdRemaining(legacy, "hearthstone", T + 200) == 1000, "legacy record decays vs lastDataUpdate")
    local unref = { hearthstoneCD = 540000 }      -- the "9000 minute" shape, no reference
    ck(Store.ItemCdRemaining(unref, "hearthstone", T) == 0,
       "legacy value above the cooldown with no reference heals to 0 (spec §6)")

    -- ---- MIGRATION: legacy remaining + lastDataUpdate -> start epoch --------
    local m1 = { hearthstoneCD = 1200, itemCooldown = 600, lastDataUpdate = T - 300 }
    ck(Store.MigrateItemCdEpochs(m1, T) == true, "migration reports it wrote")
    ck(m1.hearthstoneCDStart == T - 300 - 2400, "hearth epoch synthesized from lastDataUpdate")
    ck(m1.chronoboonCDStart  == T - 300 - 3000, "chrono epoch synthesized from lastDataUpdate")
    ck(m1.hearthstoneCD == 900, "mirror refreshed: 1200 captured 300s ago = 900 now")
    ck(m1.itemCooldown  == 300, "chrono mirror refreshed the same way")
    ck(Store.MigrateItemCdEpochs(m1, T) == false, "migration is idempotent — never re-runs on a record")

    -- No reference epoch: FREEZE at the stored value rather than invent an
    -- offline stretch (a fresh login must not wipe the record).
    local m2 = { hearthstoneCD = 1200 }
    Store.MigrateItemCdEpochs(m2, T)
    ck(m2.hearthstoneCDStart == T - 2400, "no lastDataUpdate -> epoch anchored at now (frozen)")
    ck(Store.ItemCdRemaining(m2, "hearthstone", T) == 1200, "...so the remaining is unchanged")

    -- Unhealable garbage is dropped, and the record is still PROMOTED to the
    -- epoch model so it can never fall back to the mirror again.
    local m3 = { hearthstoneCD = 540000 }
    Store.MigrateItemCdEpochs(m3, T)
    ck(m3.hearthstoneCDStart == 0 and m3.hearthstoneCD == 0, "9000-minute legacy garbage migrates to 0/0")

    -- ---- THE RELOG / "9000-MINUTE" REGRESSION ------------------------------
    -- The old model: WriteSelfCharacter re-stamps lastDataUpdate on EVERY
    -- capture, so the UI's elapsed term was always ~0 and a stored remaining
    -- never moved. Reproduce that shape, then prove the epoch model fixes it.
    local stuck = { hearthstoneCD = 1200, lastDataUpdate = T }
    ck(Store.ItemCdRemaining(stuck, "hearthstone", T + 900) == 300, "legacy: honest while the stamp is old")
    stuck.lastDataUpdate = T + 900                       -- a capture re-stamps it
    ck(Store.ItemCdRemaining(stuck, "hearthstone", T + 900) == 1200,
       "legacy BUG reproduced: a re-stamped capture freezes the countdown at 1200")
    local fixed = { hearthstoneCDStart = T - 2400, hearthstoneCD = 1200, lastDataUpdate = T }
    fixed.lastDataUpdate = T + 900                       -- same re-stamp
    ck(Store.ItemCdRemaining(fixed, "hearthstone", T + 900) == 300,
       "A9.1: the epoch model is immune to the re-stamp — 300s left, correctly")
    -- ...and it survives the relog: same stored epoch, a session later.
    ck(Store.ItemCdRemaining(fixed, "hearthstone", T + 1200) == 0, "and it reaches ready on its own")

    -- ---- ItemCdSetStart acceptance rules -----------------------------------
    local s = { hearthstoneCDStart = T - 1200 }
    ck(Store.ItemCdSetStart(s, "hearthstone", T - 1201, T) == false, "an OLDER derived start is ignored")
    ck(Store.ItemCdSetStart(s, "hearthstone", T - 1199, T) == false, "a start inside the reset slack is ignored")
    ck(Store.ItemCdSetStart(s, "hearthstone", T - 10, T) == true, "a genuinely newer start displaces (re-use / kick reset)")
    ck(s.hearthstoneCDStart == T - 10 and s.hearthstoneCD == 3590, "...and the mirror follows")
    ck(Store.ItemCdSetStart(s, "hearthstone", T + 600, T) == false, "an out-of-window start is refused")
    ck(Store.ItemCdSetStart(s, "hearthstone", T - 3000, T, true) == true, "force (a CAST) displaces regardless")

    -- ---- self-heal ----------------------------------------------------------
    local h = { hearthstoneCDStart = T - 5000, hearthstoneCD = 1200 }
    ck(Store.HealItemCdEpochs(h, T) == true, "an out-of-window epoch is healed")
    ck(h.hearthstoneCDStart == 0 and h.hearthstoneCD == 0, "heal clears the mirror too")

    -- ---- THE WIRE BOUNDARY --------------------------------------------------
    -- ENCODE: the mirror is recomputed at SEND time, not capture time.
    local out = { hearthstoneCDStart = T - 1200, chronoboonCDStart = T - 3000, hearthstoneCD = 0, itemCooldown = 0 }
    Store.WireItemCd(out, T + 300)
    ck(out.hearthstoneCD == 2100, "encode: hearth remaining computed at send time")
    ck(out.itemCooldown  == 300,  "encode: chrono remaining computed at send time")

    -- DECODE: remaining -> a LOCAL epoch. Zero transit = exact.
    local inb = Store.NewCharacterRecord("Peer-Realm")
    inb.hearthstoneCD, inb.itemCooldown = 2100, 300
    Store.AdoptWireCooldowns(inb, T + 300)
    ck(inb.hearthstoneCDStart == T - 1200, "decode: remaining re-anchored to the identical epoch")
    ck(Store.ItemCdRemaining(inb, "hearthstone", T + 300) == 2100, "decode: round-trips exactly with no transit")

    -- DRIFT: the reconstructed epoch is LATE by exactly the transit delay, so the
    -- countdown reads HIGH by it — bounded, and it does not accumulate.
    local drifted = Store.NewCharacterRecord("Peer-Realm")
    drifted.hearthstoneCD = 2100
    Store.AdoptWireCooldowns(drifted, T + 300 + 4)          -- 4s in flight
    ck(drifted.hearthstoneCDStart == T - 1200 + 4, "decode: epoch is late by exactly the transit time")
    ck(Store.ItemCdRemaining(drifted, "hearthstone", T + 300) - 2100 == 4,
       "drift == transit delay, and nothing else (no clock skew enters the value)")

    -- A record that already carries a sane epoch (SEGMENT path, whole tables)
    -- keeps the OWNER's epoch instead of re-deriving it.
    local seg = Store.NewCharacterRecord("Peer-Realm")
    seg.hearthstoneCDStart, seg.hearthstoneCD = T - 1200, 2100
    Store.AdoptWireCooldowns(seg, T + 300 + 4)
    ck(seg.hearthstoneCDStart == T - 1200, "segment path: the owner's own epoch is preserved")

    -- Garbage on the wire (remaining above the cooldown) converts to no cooldown.
    local junk = Store.NewCharacterRecord("Peer-Realm")
    junk.hearthstoneCD = 60000
    Store.AdoptWireCooldowns(junk, T)
    ck(junk.hearthstoneCDStart == 0 and junk.hearthstoneCD == 0, "wire garbage -> no cooldown")

    -- ---- the one-time SavedVariables sweep ---------------------------------
    local savedAccounts = Store.data.accounts
    local savedFlag     = Store.data.itemCdEpochsMigrated
    Store.data.accounts = {
        ["77"] = { isSelf = false, characters = { ["A-R"] = { hearthstoneCD = 1200, lastDataUpdate = T } },
                   segments = {}, segmentHashes = {},
                   homeless = { ["B-R"] = { itemCooldown = 600, lastDataUpdate = T } } },
    }
    Store.data.itemCdEpochsMigrated = nil
    ck(Store.MigrateItemCdEpochsAll(T) == 2, "SV sweep migrates characters AND homeless records")
    ck(Store.data.accounts["77"].characters["A-R"].hearthstoneCDStart == T - 2400, "swept character got its epoch")
    ck(Store.data.accounts["77"].homeless["B-R"].chronoboonCDStart == T - 3000, "swept homeless record got its epoch")
    ck(Store.MigrateItemCdEpochsAll(T) == 0, "the sweep is sticky — never runs twice")
    Store.data.accounts = savedAccounts
    Store.data.itemCdEpochsMigrated = savedFlag
end

----------------------------------------------------------------------
-- B4 — manifest adoption + ghost cleanup
----------------------------------------------------------------------
local function testManifestGhostCleanup(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = 1700000000

    -- ---- segment classification (spec §3.1) --------------------------------
    ck(Store.SegmentFor({ level = 60 }) == "sixties", "level 60 -> sixties")
    ck(Store.SegmentFor({ level = 60, classTag = "WARLOCK" }) == "sixties", "a 60 warlock is a SIXTY, not a summoner")
    ck(Store.SegmentFor({ level = 34, classTag = "WARLOCK" }) == "summoners", "warlock >=20 and not 60 -> summoners")
    ck(Store.SegmentFor({ level = 19, classTag = "WARLOCK" }) == "norole", "warlock below 20 -> norole")
    ck(Store.SegmentFor({ level = 45, classTag = "MAGE" }) == "norole", "everything else -> norole")
    ck(Store.SegmentFor(nil) == "norole", "nil record -> norole")

    local savedAccounts = Store.data.accounts
    local savedDeleted  = Store.data.deletedAIDs
    local savedLog      = Store._ghostLog
    Store._ghostLog = {}

    local function sixty(ownerEpoch) return { level = 60, ownerEpoch = ownerEpoch } end
    local function bucket(chars, homeless, segEpoch)
        return { isSelf = false, characters = chars or {}, homeless = homeless or {},
                 segments = { sixties = {}, summoners = {}, norole = {} },
                 segmentHashes = segEpoch and { sixties = { epoch = segEpoch } } or {} }
    end

    -- ---- THE MATRIX --------------------------------------------------------
    Store.data.deletedAIDs = {}
    Store.data.accounts = {
        ["9"] = bucket({
            ["Keeper-R"]  = sixty(T - 100),          -- named by the manifest
            ["Ghost-R"]   = sixty(T - 100),          -- absent, OLDER  -> deleted
            ["Fresh-R"]   = sixty(T + 500),          -- absent, NEWER  -> kept
            ["Equal-R"]   = sixty(T),                -- absent, EQUAL  -> deleted (<=)
            ["Lock-R"]    = { level = 40, classTag = "WARLOCK", ownerEpoch = T - 100 },
        }, { ["Homeless-R"] = sixty(T - 50) }, T - 1000),
    }
    local applied, info = Store.AdoptManifest("9", "sixties", { "Keeper-R", "Homeless-R", "X" }, T, "abc")
    local chars = Store.data.accounts["9"].characters
    ck(applied == true, "a strictly newer manifest is adopted")
    ck(chars["Keeper-R"] ~= nil, "named in the manifest -> kept")
    ck(chars["Ghost-R"] == nil, "absent + older record epoch -> DELETED")
    ck(chars["Fresh-R"] ~= nil, "absent + NEWER record epoch -> kept (out-of-order protection)")
    ck(chars["Equal-R"] == nil, "absent + equal epoch -> deleted (the rule is <=)")
    ck(chars["Lock-R"] ~= nil, "a SUMMONER is untouched by the sixties manifest")
    ck(chars["Homeless-R"] ~= nil, "a homeless character named by the manifest is ADOPTED")
    ck(Store.data.accounts["9"].homeless["Homeless-R"] == nil, "...and leaves the homeless table")
    ck(#info.deleted == 2 and #info.adopted == 1, "info reports 2 deletions + 1 adoption")
    ck(Store.data.accounts["9"].segmentHashes.sixties.epoch == T, "the manifest epoch is stored")
    ck(Store.data.accounts["9"].segments.sixties[1] == "Keeper-R", "the manifest list is stored verbatim")
    ck(#Store._ghostLog == 1, "the deletion is written to the debug log")

    -- ---- stale / equal epoch: no adoption, NOTHING deleted ------------------
    Store.data.accounts = { ["9"] = bucket({ ["Ghost-R"] = sixty(T - 100) }, nil, T) }
    local ok2, i2 = Store.AdoptManifest("9", "sixties", {}, T, "abc")
    ck(ok2 == false and i2.reason == "stale-epoch", "an EQUAL manifest epoch is refused")
    ck(Store.data.accounts["9"].characters["Ghost-R"] ~= nil, "...and deletes nothing")
    local ok3 = Store.AdoptManifest("9", "sixties", {}, T - 1, "abc")
    ck(ok3 == false, "an OLDER manifest epoch is refused")
    ck(Store.data.accounts["9"].characters["Ghost-R"] ~= nil, "...and still deletes nothing")

    -- ---- SELF: never, under any epoch --------------------------------------
    Store.data.accounts = { ["9"] = bucket({ ["Mine-R"] = sixty(T - 100) }, nil, T - 1000) }
    Store.data.accounts["9"].isSelf = true
    local ok4, i4 = Store.AdoptManifest("9", "sixties", {}, T + 9999, "abc")
    ck(ok4 == false and i4.reason == "self", "our OWN account is never manifest-cleaned")
    ck(Store.data.accounts["9"].characters["Mine-R"] ~= nil, "...our character survives")

    -- ---- TOMBSTONED: silently rejected on every inbound path (spec §1.3) ----
    Store.data.accounts = { ["9"] = bucket({ ["Ghost-R"] = sixty(T - 100) }, nil, T - 1000) }
    Store.data.deletedAIDs = { ["9"] = serverNow() }
    local ok5, i5 = Store.AdoptManifest("9", "sixties", {}, T, "abc")
    ck(ok5 == false and i5.reason == "tombstoned", "a tombstoned account's manifest is rejected")
    ck(Store.data.accounts["9"].characters["Ghost-R"] ~= nil, "...and deletes nothing")
    Store.data.deletedAIDs = {}

    -- ---- unsynced segment: norole is local + opportunistic (spec §3.1) -----
    Store.data.accounts = { ["9"] = bucket({ ["Alt-R"] = { level = 30, ownerEpoch = T - 100 } }, nil, T - 1000) }
    local ok6, i6 = Store.AdoptManifest("9", "norole", {}, T, "abc")
    ck(ok6 == false and i6.reason == "unsynced-area", "a norole manifest is refused outright")
    ck(Store.data.accounts["9"].characters["Alt-R"] ~= nil, "...norole characters are never ghost-cleaned")

    -- ---- an account we hold no bucket for is never created from a manifest --
    Store.data.accounts = {}
    local ok7, i7 = Store.AdoptManifest("9", "sixties", {}, T, "abc")
    ck(ok7 == false and i7.reason == "unknown-account", "an unknown account is not resurrected by a manifest")
    ck(Store.data.accounts["9"] == nil, "...no bucket is created")

    -- ---- malformed input ----------------------------------------------------
    Store.data.accounts = { ["9"] = bucket({}, nil, 0) }
    ck(select(1, Store.AdoptManifest(nil, "sixties", {}, T)) == false, "nil aid refused")
    ck(select(1, Store.AdoptManifest("9", "sixties", nil, T)) == false, "nil list refused")
    ck(select(1, Store.AdoptManifest("9", nil, {}, T)) == false, "nil area refused")

    -- ---- SENDER SIDE: our own segments, epoch bumped only on membership -----
    Store.data.accounts = { ["1"] = bucket({
        ["Sixty-R"] = { level = 60 },
        ["Lock-R"]  = { level = 40, classTag = "WARLOCK" },
        ["Alt-R"]   = { level = 12 },
    }, nil, nil) }
    Store.data.accounts["1"].isSelf = true
    local savedGetAID = ns.GetAccountID
    ns.GetAccountID = function() return "1" end
    ck(Store.RebuildSelfSegments(T) == true, "first rebuild publishes our segments")
    local me = Store.data.accounts["1"]
    ck(me.segments.sixties[1] == "Sixty-R", "our 60 lands in sixties")
    ck(me.segments.summoners[1] == "Lock-R", "our warlock lands in summoners")
    ck(me.segments.norole[1] == "Alt-R", "our low alt lands in norole")
    ck(me.segmentHashes.sixties.epoch == T, "the segment epoch is stamped")
    ck(Store.RebuildSelfSegments(T + 60) == false, "an unchanged roster does NOT bump the epoch")
    ck(me.segmentHashes.sixties.epoch == T, "...so peers see no spurious manifest")
    me.characters["Sixty-R"] = nil                       -- delete the alt
    ck(Store.RebuildSelfSegments(T + 120) == true, "deleting a character DOES bump the epoch")
    ck(me.segmentHashes.sixties.epoch == T + 120, "...to the new time")
    ck(#me.segments.sixties == 0, "...and the manifest no longer names it — which is what deletes it on peers")
    me.characters["Alt-R"].level = 60                    -- a ding re-segments
    ck(Store.RebuildSelfSegments(T + 180) == true, "a level-60 ding bumps both affected segments")
    ck(me.segments.sixties[1] == "Alt-R" and #me.segments.norole == 0, "...and moves the character")
    ns.GetAccountID = savedGetAID

    Store.data.accounts   = savedAccounts
    Store.data.deletedAIDs = savedDeleted
    Store._ghostLog        = savedLog
end

----------------------------------------------------------------------
-- B5 — stale-twin reconciliation
----------------------------------------------------------------------
local function testStaleTwins(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = 1700000000
    local OLD = T - 14 * 86400        -- the owner's two-week-old imported bucket

    local savedAccounts = Store.data.accounts
    local savedLog      = Store._ghostLog
    local savedGetAID   = ns.GetAccountID

    local function rec(epoch, level)
        return { level = level or 60, ownerEpoch = epoch }
    end
    local function bucket(chars, homeless, isSelf, segs)
        return { isSelf = isSelf or false, characters = chars or {}, homeless = homeless or {},
                 segments = segs or { sixties = {}, summoners = {}, norole = {} },
                 segmentHashes = {} }
    end

    -- ---- THE OWNER'S CASE ---------------------------------------------------
    -- Puucons under the stale imported bucket 3 AND under the account that just
    -- re-joined the mesh under a new aid. The stale copy is retired.
    Store._ghostLog = {}
    Store.data.accounts = {
        ["3"]  = bucket({ ["Puucons-R"] = rec(OLD) }, nil, false,
                        { sixties = { "Puucons-R", "Other-R" }, summoners = {}, norole = {} }),
        ["11"] = bucket({ ["Puucons-R"] = rec(T) }),
    }
    local gone = Store.ReconcileStaleTwins("Puucons-R", "11")
    ck(#gone == 1 and gone[1] == "3", "the strictly-older twin's account is reported")
    ck(Store.data.accounts["3"].characters["Puucons-R"] == nil, "THE FIX: the stale copy is removed")
    ck(Store.data.accounts["11"].characters["Puucons-R"] ~= nil, "the live copy is kept")
    ck(Store.data.accounts["3"].segments.sixties[1] == "X",
        "the vacated manifest slot becomes the 'X' tombstone")
    ck(Store.data.accounts["3"].segments.sixties[2] == "Other-R",
        "...and the rest of the ordered list keeps its positions")
    ck(#Store._ghostLog == 1, "the removal is written to the debug log (B4 pattern)")

    -- ---- GUARD: never from a bucket flagged isSelf --------------------------
    Store.data.accounts = {
        ["3"]  = bucket({ ["Mine-R"] = rec(OLD) }, nil, true),
        ["11"] = bucket({ ["Mine-R"] = rec(T) }),
    }
    ck(#Store.ReconcileStaleTwins("Mine-R", "11") == 0, "a self bucket is never reconciled away")
    ck(Store.data.accounts["3"].characters["Mine-R"] ~= nil,
        "...our own copy survives however stale it looks (UI dedup covers the display)")

    -- ---- GUARD: equal epochs are ambiguous, so nothing moves ----------------
    Store.data.accounts = {
        ["3"]  = bucket({ ["Twin-R"] = rec(T) }),
        ["11"] = bucket({ ["Twin-R"] = rec(T) }),
    }
    ck(#Store.ReconcileStaleTwins("Twin-R", "11") == 0, "equal ownerEpoch -> no removal")
    ck(Store.data.accounts["3"].characters["Twin-R"] ~= nil, "...both copies stay")
    -- Two UNSTAMPED records are equal at 0 and must not annihilate each other.
    Store.data.accounts = {
        ["3"]  = bucket({ ["Bare-R"] = {} }),
        ["11"] = bucket({ ["Bare-R"] = {} }),
    }
    ck(#Store.ReconcileStaleTwins("Bare-R", "11") == 0, "two unstamped (epoch 0) copies -> no removal")

    -- ---- GUARD: a NEWER twin is never removed -------------------------------
    Store.data.accounts = {
        ["3"]  = bucket({ ["Fresh-R"] = rec(T) }),
        ["11"] = bucket({ ["Fresh-R"] = rec(OLD) }),
    }
    ck(#Store.ReconcileStaleTwins("Fresh-R", "11") == 0, "keeping the OLDER copy removes nothing")
    ck(Store.data.accounts["3"].characters["Fresh-R"] ~= nil, "...the newer copy is untouched")

    -- ---- the homeless table is cleaned too ----------------------------------
    Store.data.accounts = {
        ["3"]  = bucket(nil, { ["Drift-R"] = rec(OLD) }),
        ["11"] = bucket({ ["Drift-R"] = rec(T) }),
    }
    ck(#Store.ReconcileStaleTwins("Drift-R", "11") == 1, "a stale HOMELESS twin is retired")
    ck(Store.data.accounts["3"].homeless["Drift-R"] == nil, "...and leaves the homeless table")

    -- ---- malformed / no-op input --------------------------------------------
    Store.data.accounts = { ["11"] = bucket({ ["Solo-R"] = rec(T) }) }
    ck(#Store.ReconcileStaleTwins("Solo-R", "11") == 0, "a character held once is a no-op")
    ck(#Store.ReconcileStaleTwins("Solo-R", "99") == 0, "an unknown keeper removes nothing")
    ck(#Store.ReconcileStaleTwins(nil, "11") == 0, "nil nameRealm refused")
    ck(#Store.ReconcileStaleTwins("", "11") == 0, "empty nameRealm refused")

    -- ---- THE LOGIN SWEEP: whole store, newest wins --------------------------
    Store.data.accounts = {
        ["3"]  = bucket({ ["Puucons-R"] = rec(OLD), ["Alt-R"] = rec(OLD), ["Only3-R"] = rec(OLD) }),
        ["11"] = bucket({ ["Puucons-R"] = rec(T),   ["Alt-R"] = rec(T) }),
        ["12"] = bucket({ ["Puucons-R"] = rec(T) }),          -- equal to the max -> survives
    }
    local n = Store.SweepStaleTwins()
    ck(n == 2, "the sweep retires exactly the two strictly-older copies (got " .. tostring(n) .. ")")
    ck(Store.data.accounts["3"].characters["Puucons-R"] == nil, "sweep: stale Puucons gone")
    ck(Store.data.accounts["3"].characters["Alt-R"] == nil, "sweep: stale Alt gone")
    ck(Store.data.accounts["3"].characters["Only3-R"] ~= nil,
        "sweep: a character held by ONE bucket is never touched")
    ck(Store.data.accounts["11"].characters["Puucons-R"] ~= nil
       and Store.data.accounts["12"].characters["Puucons-R"] ~= nil,
        "sweep: every copy AT the maximum epoch survives (equal is ambiguous)")
    ck(Store.SweepStaleTwins() == 0, "the sweep is idempotent — a second pass removes nothing")

    -- ---- the WRITE PATHS call it (this is what makes the fix self-healing) --
    -- Inbound: the live account pushes a fresh Puucons; the stale bucket's copy
    -- is physically gone by the time the write returns.
    ns.GetAccountID = function() return "1" end
    Store.data.accounts = {
        ["1"]  = bucket({}, nil, true),
        ["3"]  = bucket({ ["Puucons-R"] = rec(OLD) }),
        ["11"] = bucket({}),
    }
    local inbound = Store.NewCharacterRecord("Puucons-R")
    inbound.ownerEpoch = T
    ck(Store.WriteInboundCharacter("11", "Puucons-R", inbound, "11") == true, "the inbound write lands")
    ck(Store.data.accounts["3"].characters["Puucons-R"] == nil,
        "WriteInboundCharacter reconciles: the stale twin is gone after the live push")

    -- Self: writing our own character retires a foreign stale twin of it.
    Store.data.accounts = {
        ["1"] = bucket({}, nil, true),
        ["3"] = bucket({ ["Tester-R"] = rec(OLD) }),
    }
    local mine = Store.NewCharacterRecord("Tester-R")
    mine.ownerEpoch = T
    Store.WriteSelfCharacter("Tester-R", mine)
    ck(Store.data.accounts["3"].characters["Tester-R"] == nil,
        "WriteSelfCharacter reconciles a foreign stale twin of our own character")
    ck(Store.data.accounts["1"].characters["Tester-R"] ~= nil, "...and our copy is the one kept")

    ns.GetAccountID     = savedGetAID
    Store.data.accounts = savedAccounts
    Store._ghostLog     = savedLog
end

----------------------------------------------------------------------
-- B5.1 — self-bucket sanity pass
----------------------------------------------------------------------
local function testSelfBucketSanity(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = 1700000000
    local OLD = T - 14 * 86400

    local savedAccounts = Store.data.accounts
    local savedLog      = Store._ghostLog
    local savedGetAID   = ns.GetAccountID

    local function rec(epoch) return { level = 60, ownerEpoch = epoch } end
    local function bucket(chars, isSelf, segs)
        return { isSelf = isSelf or false, characters = chars or {}, homeless = {},
                 segments = segs or { sixties = {}, summoners = {}, norole = {} },
                 segmentHashes = {} }
    end

    -- ---- THE OWNER'S ACCOUNT-#3 SHAPE, REPRODUCED -------------------------
    -- His SavedVariables carry the genuine self bucket under key "3" AND a
    -- stale duplicate "Puucons-Whitemane" under the EMPTY-STRING key whose
    -- bucket is ALSO flagged isSelf (left over from before he set an account
    -- id). Two isSelf buckets = corrupt state.
    local function ownerShape()
        Store.data.accounts = {
            ["3"] = bucket({ ["Puucons-Whitemane"] = rec(T) }, true),
            [""]  = bucket({ ["Puucons-Whitemane"] = rec(OLD) }, true,
                           { sixties = { "Puucons-Whitemane", "Other-R" },
                             summoners = {}, norole = {} }),
        }
    end
    ns.GetAccountID = function() return "3" end

    -- CONTROL: with BOTH flagged self, the stale twin is immortal — this is
    -- precisely the bug. ReconcileStaleTwins refuses to touch an isSelf bucket.
    ownerShape()
    ck(#Store.ReconcileStaleTwins("Puucons-Whitemane", "3") == 0,
        "control: while the empty-key bucket is flagged self, the duplicate is immortal")
    ck(Store.data.accounts[""].characters["Puucons-Whitemane"] ~= nil,
        "control: ...the stale copy survives (the defect the sanity pass fixes)")

    -- THE SANITY PASS.
    ownerShape()
    Store._ghostLog = {}
    ck(Store.SanitizeSelfBuckets() == 1, "exactly one impostor bucket is demoted")
    ck(Store.data.accounts[""].isSelf == false,
        "THE FIX: the empty-key bucket's isSelf claim is cleared")
    ck(Store.data.accounts["3"].isSelf == true,
        "the genuine bucket (key == account id) keeps its flag")
    ck(Store.data.accounts[""].characters["Puucons-Whitemane"] ~= nil,
        "the pass CLEARS A FLAG ONLY — it never removes a record itself")
    ck(#Store._ghostLog == 1, "the demotion is written to the debug ring (+ amber line)")

    -- ...and retirement now proceeds, both by the login sweep...
    ck(Store.SweepStaleTwins() == 1, "the login sweep now retires the unblocked stale copy")
    ck(Store.data.accounts[""].characters["Puucons-Whitemane"] == nil,
        "THE OWNER'S CASE RESOLVES: the duplicate Puucons-Whitemane is gone")
    ck(Store.data.accounts["3"].characters["Puucons-Whitemane"] ~= nil,
        "...and his real character is the copy kept")
    ck(Store.data.accounts[""].segments.sixties[1] == "X",
        "...the vacated manifest slot is tombstoned as usual")

    -- ...and on the next ordinary WRITE of that character.
    ownerShape()
    Store.SanitizeSelfBuckets()
    local mine = Store.NewCharacterRecord("Puucons-Whitemane")
    mine.ownerEpoch = T
    Store.WriteSelfCharacter("Puucons-Whitemane", mine)
    ck(Store.data.accounts[""].characters["Puucons-Whitemane"] == nil,
        "retirement also proceeds on the next write, with no reload needed")

    -- IDEMPOTENT.
    ownerShape()
    ck(Store.SanitizeSelfBuckets() == 1, "first pass demotes")
    ck(Store.SanitizeSelfBuckets() == 0, "second pass finds nothing left to demote")
    ck(Store.SanitizeSelfBuckets() == 0, "...and stays a no-op")
    ck(Store.data.accounts["3"].isSelf == true, "...the genuine flag survives every pass")

    -- ---- GUARD: a MISMATCHED key, not just the empty one -------------------
    ns.GetAccountID = function() return "11" end
    Store.data.accounts = {
        ["11"] = bucket({ ["Mine-R"] = rec(T) }, true),
        ["3"]  = bucket({ ["Mine-R"] = rec(OLD) }, true),    -- old identity
        ["7"]  = bucket({ ["Peer-R"] = rec(T) }, false),     -- ordinary peer
    }
    ck(Store.SanitizeSelfBuckets() == 1, "a mismatched-KEY self bucket is demoted too")
    ck(Store.data.accounts["3"].isSelf == false, "...the old identity loses the claim")
    ck(Store.data.accounts["11"].isSelf == true, "...the current account keeps it")
    ck(Store.data.accounts["7"].isSelf == false, "...an ordinary peer is unchanged")

    -- ---- GUARD: unset account id -> DO NOTHING -----------------------------
    -- Pre-setup, GetSelfAccount deliberately flags the "" bucket self so our
    -- live characters keep self-immunity. That is CORRECT, not corruption, and
    -- with no id there is no way to name a genuine bucket anyway.
    ns.GetAccountID = function() return "" end
    Store.data.accounts = {
        [""]  = bucket({ ["Mine-R"] = rec(T) }, true),
        ["3"] = bucket({ ["Mine-R"] = rec(OLD) }, true),
    }
    ck(Store.SanitizeSelfBuckets() == 0, "an UNSET account id is a total no-op")
    ck(Store.data.accounts[""].isSelf == true, "...the pre-setup orphan keeps self-immunity")
    ck(Store.data.accounts["3"].isSelf == true, "...and nothing else is touched either")

    -- ---- GUARD: invalid account id -> DO NOTHING ---------------------------
    for _, bad in ipairs({ "abc", "123", "  ", "3x" }) do
        ns.GetAccountID = function() return bad end
        Store.data.accounts = {
            [""]  = bucket({}, true),
            ["3"] = bucket({}, true),
        }
        ck(Store.SanitizeSelfBuckets() == 0,
            "an INVALID account id (" .. bad .. ") is a no-op")
        ck(Store.data.accounts[""].isSelf == true and Store.data.accounts["3"].isSelf == true,
            "...no flag is disturbed on an invalid id (" .. bad .. ")")
    end
    ns.GetAccountID = function() return nil end
    Store.data.accounts = { [""] = bucket({}, true) }
    ck(Store.SanitizeSelfBuckets() == 0, "a nil account id is a no-op")

    -- ---- GUARD: the genuine bucket is never TOUCHED, in either direction ---
    -- Not cleared, and not set either: flagging it is GetSelfAccount's job.
    ns.GetAccountID = function() return "3" end
    Store.data.accounts = { ["3"] = bucket({ ["Mine-R"] = rec(T) }, false) }
    ck(Store.SanitizeSelfBuckets() == 0, "an unflagged genuine bucket needs no demotion")
    ck(Store.data.accounts["3"].isSelf == false,
        "...and the pass does not SET the flag either (GetSelfAccount owns that)")

    -- ---- no accounts / already-clean stores are no-ops ---------------------
    Store.data.accounts = {}
    ck(Store.SanitizeSelfBuckets() == 0, "an empty store is a no-op")
    Store.data.accounts = { ["3"] = bucket({}, true), ["7"] = bucket({}, false) }
    ck(Store.SanitizeSelfBuckets() == 0, "an already-correct store is a no-op")

    ns.GetAccountID     = savedGetAID
    Store.data.accounts = savedAccounts
    Store._ghostLog     = savedLog
end

-- F10 — timer-log dedup (spec §10.1). The identity of a pop is EPOCH ±30s +
-- KIND. It used to include `who`, so the same pop reported by the local yell,
-- the world-buff addon's log, the mesh and SN landed as four separate rows and
-- every "when did Rend last pop" reader saw phantom pops.
local function testTimerLogDedup(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local savedTimers = Store.data and Store.data.timers
    Store.data = Store.data or {}
    -- Base on the real clock: TrimLog purges anything older than 48h, so a
    -- synthetic small epoch would be deleted the moment it was inserted.
    local T = Store.Now()
    local function reset() Store.data.timers = { logs = {} } end
    local function rows(k) return Store.data.timers.logs[k] or {} end

    ------------------------------------------------------------------
    -- 1. THE BUG: one pop, four reporters, four different `who`.
    ------------------------------------------------------------------
    reset()
    ck(Store.AddTimerLog("rend", { epoch = T,      who = "Thrall"   }) == true,
        "the first report inserts")
    ck(Store.AddTimerLog("rend", { epoch = T + 3,  who = "NWBlog"   }) == false,
        "the world-buff addon's relay of the same pop is a duplicate")
    ck(Store.AddTimerLog("rend", { epoch = T + 11, who = "MeshPeer" }) == false,
        "the mesh relay is a duplicate")
    ck(Store.AddTimerLog("rend", { epoch = T + 29, who = "SN"       }) == false,
        "an SN relay still inside 30s is a duplicate")
    ck(#rows("rend") == 1, "one pop logs exactly ONE row (was 4)")
    ck(rows("rend")[1].epoch == T + 29, "the merged row keeps the HIGHEST epoch")
    ck(rows("rend")[1].who == "Thrall", "an established who is never overwritten")

    ------------------------------------------------------------------
    -- 2. `who` back-fill: "?" / "" / nil are absence, not a name.
    ------------------------------------------------------------------
    for _, blank in ipairs({ "?", "", "\0nil" }) do
        reset()
        local first = { epoch = T }
        if blank ~= "\0nil" then first.who = blank end
        Store.AddTimerLog("rend", first)
        Store.AddTimerLog("rend", { epoch = T + 5, who = "Ragefire" })
        ck(#rows("rend") == 1, "the anonymous row absorbs the named report")
        ck(rows("rend")[1].who == "Ragefire",
            "a missing who (" .. blank .. ") is back-filled from whoever knows")
    end

    ------------------------------------------------------------------
    -- 3. Outside the window is a genuinely new event.
    ------------------------------------------------------------------
    reset()
    Store.AddTimerLog("rend", { epoch = T })
    ck(Store.AddTimerLog("rend", { epoch = T + 31 }) == true,
        "31s apart is a second event, not a duplicate")
    ck(#rows("rend") == 2, "and both rows are kept")

    ------------------------------------------------------------------
    -- 4. KIND separates an Ony NPC kill from an Ony pop inside the window.
    ------------------------------------------------------------------
    reset()
    ck(Store.AddTimerLog("onyH", { epoch = T, killed = true }) == true,
        "a kill logs")
    ck(Store.AddTimerLog("onyH", { epoch = T + 5 }) == true,
        "a pop 5s after the kill is a DIFFERENT kind, not a duplicate")
    ck(#rows("onyH") == 2, "kill and pop coexist")
    ck(Store.AddTimerLog("onyH", { epoch = T + 6, killed = true }) == false,
        "a second report of the KILL is a duplicate of the kill")
    ck(#rows("onyH") == 2, "...and adds no row")

    if savedTimers then Store.data.timers = savedTimers end
end

-- A17.3 — coordinate-override boxes. The seeds shipped ~12x the reference
-- tolerance AND with drifted centres, so a character in mid-Orgrimmar reported
-- their location as "Rend Staging (N)".
local function testCoordinateOverrides(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function inBox(r, x, y)
        return x >= r.minX and x <= r.maxX and y >= r.minY and y <= r.maxY
    end

    ------------------------------------------------------------------
    -- 1. Every seed is a ±0.02 box centred on the reference point.
    ------------------------------------------------------------------
    local d = Store.DefaultCoordinateOverrides()
    ck(#d == 3, "three rules ship by default")
    local CENTRES = {
        ["Rend North Staging"] = { 0.509452, 0.475196 },
        ["Rend South Staging"] = { 0.491113, 0.683181 },
        ["DMF Mulgore"]        = { 0.447506, 0.592198 },
    }
    for _, r in ipairs(d) do
        local c = CENTRES[r.name]
        ck(c ~= nil, "seed '" .. tostring(r.name) .. "' is a known rule")
        if c then
            ck(math.abs((r.maxX - r.minX) - 0.04) < 1e-9, r.name .. ": X span is the ±0.02 tolerance")
            ck(math.abs((r.maxY - r.minY) - 0.04) < 1e-9, r.name .. ": Y span is the ±0.02 tolerance")
            ck(math.abs((r.minX + r.maxX) / 2 - c[1]) < 1e-9, r.name .. ": centred on the reference X")
            ck(math.abs((r.minY + r.maxY) / 2 - c[2]) < 1e-9, r.name .. ": centred on the reference Y")
            ck(inBox(r, c[1], c[2]), r.name .. ": the staging point itself matches")
        end
    end
    ck(d[1].zone == nil and d[2].zone == nil, "the two Rend rules are unscoped (nil, not \"\")")
    ck(d[3].zone == "Mulgore", "the DMF rule keeps the zone its name states")

    ------------------------------------------------------------------
    -- 2. Point-in-box matrix — the live symptom.
    ------------------------------------------------------------------
    local north  = d[1]
    local LEGACY = { minX = 0.30, maxX = 0.55, minY = 0.55, maxY = 0.80 }
    ck(inBox(LEGACY, 0.45, 0.60),
        "mid-Orgrimmar DID match the old oversized seed (this was the bug)")
    ck(not inBox(north, 0.45, 0.60),
        "mid-Orgrimmar no longer matches Rend Staging (N)")
    ck(not inBox(north, 0.509452, 0.560000), "a point 0.085 north of the spot misses")
    ck(inBox(north, 0.509452 + 0.019, 0.475196), "just inside the tolerance still hits")

    ------------------------------------------------------------------
    -- 3. Migration: match-by-value only, idempotent, user edits untouched.
    ------------------------------------------------------------------
    local db = { coordinateOverrides = {
        { name = "Rend North Staging", zone = "Orgrimmar", minX = 0.30, maxX = 0.55, minY = 0.55, maxY = 0.80, label = "Rend Staging (N)" },
        { name = "Rend South Staging", zone = "Durotar",   minX = 0.40, maxX = 0.60, minY = 0.10, maxY = 0.30, label = "Rend Staging (S)" },
        { name = "DMF Mulgore",        zone = "Mulgore",   minX = 0.30, maxX = 0.50, minY = 0.55, maxY = 0.75, label = "Darkmoon Faire" },
    } }
    ck(Store.MigrateCoordinateOverrides(db) == 3, "all three legacy boxes are rewritten")
    local m = db.coordinateOverrides
    ck(math.abs(m[1].minX - (0.509452 - 0.02)) < 1e-9, "north healed to the reference box")
    ck(m[1].zone == nil, "the migrated Rend rule becomes unscoped")
    ck(m[3].zone == "Mulgore", "the migrated DMF rule keeps its zone")
    ck(m[1].label == "Rend Staging (N)", "labels are presentation — never rewritten")
    ck(Store.MigrateCoordinateOverrides(db) == 0, "idempotent: a second pass changes nothing")

    local edited = { coordinateOverrides = {
        { name = "Rend North Staging", zone = "Orgrimmar",
          minX = 0.31, maxX = 0.55, minY = 0.55, maxY = 0.80, label = "mine" },
    } }
    ck(Store.MigrateCoordinateOverrides(edited) == 0,
        "one nudged bound is user intent — the rule is left alone")
    ck(edited.coordinateOverrides[1].minX == 0.31, "...and is genuinely unmodified")

    ------------------------------------------------------------------
    -- 4. Robustness.
    ------------------------------------------------------------------
    Store.MigrateCoordinateOverrides(nil)
    Store.MigrateCoordinateOverrides({})
    Store.MigrateCoordinateOverrides({ coordinateOverrides = "nope" })
    Store.MigrateCoordinateOverrides({ coordinateOverrides = { "junk", {}, { name = "x" } } })
    ck(true, "MigrateCoordinateOverrides survives malformed input")

    ------------------------------------------------------------------
    -- 5. F12 — the Nef quest hand-in rows flash by default (spec §11).
    ------------------------------------------------------------------
    local alerts = defaultAlertMatrix()
    ck(alerts.questHandin.nefH.flash == true, "Nef Horde hand-in flashes by default")
    ck(alerts.questHandin.nefA.flash == true, "Nef Alliance hand-in flashes by default")
    ck(alerts.questHandin.rend.flash == false, "every other hand-in row stays unflashed")
    ck(alerts.pullTimer.nefH.flash == false, "the flash default is hand-in only, not Nef-wide")
end

----------------------------------------------------------------------
-- Storage migration chain (AT-RISK-3): stamp-don't-wipe, never downgrade,
-- stop-on-gap; the character graph (accounts + attunements) and tombstones
-- (deletedAIDs) survive every path, and additive defaults still seed.
----------------------------------------------------------------------
local function testStorageMigration(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- A representative saved-data table: a character graph carrying an
    -- attunement, plus a tombstone, timers and a note. Every case below proves
    -- this rides through untouched.
    local function sampleData(ver)
        return {
            version = ver,
            accounts = {
                ["7"] = {
                    isSelf = true,
                    characters = {
                        ["Alt-R"] = { level = 60, attunements = { mc = true, ony = true } },
                    },
                },
            },
            deletedAIDs = { ["9"] = 1699000000 },   -- a tombstone: must not resurrect
            timers      = { flower = { 111 } },
            notes       = { ["Alt-R"] = "keep me" },
        }
    end

    -- (1) ABSENT version -> STAMPED to current, NOTHING wiped.
    local d = sampleData(nil)
    local ok, from, to, note = Store.MigrateData(d)
    ck(ok == true and note == "stamped", "absent version -> stamped (not wiped)")
    ck(from == nil and to == Store.STORAGE_VERSION and d.version == Store.STORAGE_VERSION,
        "stamped to the current storage version")
    ck(d.accounts["7"].characters["Alt-R"].attunements.mc == true,
        "STAMP preserves the character graph + attunements")
    ck(d.deletedAIDs["9"] == 1699000000, "STAMP preserves tombstones (no resurrection)")

    -- current-version table is a no-op "migrated" (0 steps); data untouched.
    local dCur = sampleData(Store.STORAGE_VERSION)
    local okC, _, _, noteC = Store.MigrateData(dCur)
    ck(okC == true and noteC == "migrated", "current version -> migrated (0 steps)")
    ck(dCur.accounts["7"] ~= nil, "current-version data left intact")

    -- (2) NEWER version -> left EXACTLY as-is, ok=false / "future".
    local dF = sampleData(Store.STORAGE_VERSION + 5)
    local okF, fromF, toF, noteF = Store.MigrateData(dF)
    ck(okF == false and noteF == "future", "newer version -> future (never downgraded)")
    ck(fromF == Store.STORAGE_VERSION + 5 and dF.version == Store.STORAGE_VERSION + 5,
        "future version left untouched")
    ck(dF.accounts["7"].characters["Alt-R"].attunements.ony == true,
        "future data left exactly as-is")

    -- (3) A simulated 1 -> 2 transform runs IN PLACE and preserves everything.
    local savedSV   = Store.STORAGE_VERSION
    local savedStep = Store.MIGRATIONS[1]
    Store.STORAGE_VERSION = 2
    local ran = false
    Store.MIGRATIONS[1] = function(data)
        ran = true
        data.migratedFlag = true           -- pure transform: add, don't remove
    end
    local dm = sampleData(1)
    local okM, fromM, toM, noteM = Store.MigrateData(dm)
    ck(okM == true and noteM == "migrated", "known older version -> migrated")
    ck(ran == true and fromM == 1 and toM == 2, "the 1->2 step ran; cursor advanced to 2")
    ck(dm.version == 2, "version stamped to 2 after the step")
    ck(dm.migratedFlag == true, "the transform's output is present")
    ck(dm.accounts["7"].characters["Alt-R"].attunements.mc == true,
        "1->2 preserves accounts + attunements")
    ck(dm.deletedAIDs["9"] == 1699000000, "1->2 preserves tombstones")
    ck(dm.notes["Alt-R"] == "keep me" and dm.timers.flower[1] == 111,
        "1->2 preserves notes + timers")

    -- (4) MISSING step in the chain -> STOP with "gap"; nothing half-done/wiped.
    Store.MIGRATIONS[1] = nil
    local dg = sampleData(1)
    local okG, fromG, toG, noteG = Store.MigrateData(dg)
    ck(okG == false and noteG == "gap", "missing step -> gap (not a partial convert / wipe)")
    ck(dg.version == 1, "gap leaves the version where the chain stalled")
    ck(dg.accounts["7"] ~= nil, "gap preserves the character graph (no wipe)")
    ck(dg.deletedAIDs["9"] == 1699000000, "gap preserves tombstones")

    Store.STORAGE_VERSION = savedSV
    Store.MIGRATIONS[1]   = savedStep

    -- (6) Additive defaults still seed AFTER a stamp, and never clobber. This is
    -- the Init sequence: MigrateData (stamp) then applyDefaults(defaultData()).
    local dS = { version = nil,
                 accounts = { ["7"] = { characters = {} } },
                 notes    = { ["Keep-R"] = "user note" } }
    local okS = Store.MigrateData(dS)
    ck(okS == true, "stamp precedes the defaults backfill")
    Store.ApplyDefaults(dS, { social = { guild = {}, friends = {} },
                              notes  = { ["Keep-R"] = "SHOULD NOT OVERWRITE" } })
    ck(type(dS.social) == "table" and type(dS.social.guild) == "table",
        "additive defaults seed missing structure after a stamp")
    ck(dS.notes["Keep-R"] == "user note",
        "additive defaults never clobber an existing value")

    -- defensive: a non-table is refused, not crashed.
    ck(select(1, Store.MigrateData(nil)) == false, "nil data refused (no crash)")
end

function Store.RunSelfTests(verbose)
    local suites = {
        { name = "defaults",        fn = testDefaults },
        { name = "storage migration (AT-RISK-3)", fn = testStorageMigration },
        { name = "alert migration", fn = testAlertMigration },
        { name = "aura seeds",      fn = testAuraSeeds },
        { name = "autosummon seeds", fn = testAutoSummonSeeds },
        { name = "songflower migration", fn = testSongflowerMigration },
        { name = "notes",           fn = testNotes },
        { name = "inbound name guard", fn = testInboundNameGuard },
        { name = "non-wire carry-forward", fn = testNonWireCarryForward },
        { name = "rested percent",  fn = testRestedPercent },
        { name = "dmf cooldown",    fn = testDMFCooldown },
        { name = "item cd epochs (A9.1)",   fn = testItemCdEpochs },
        { name = "manifest ghost cleanup (B4)", fn = testManifestGhostCleanup },
        { name = "stale-twin reconciliation (B5)", fn = testStaleTwins },
        { name = "self-bucket sanity (B5.1)", fn = testSelfBucketSanity },
        { name = "timer log dedup (F10)", fn = testTimerLogDedup },
        { name = "coordinate overrides (A17.3)", fn = testCoordinateOverrides },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok = pcall(suite.fn, fails)
        local passed = ok and #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS store/" .. suite.name)
            elseif not ok then ns:Print("  FAIL store/" .. suite.name .. " :: error in test")
            else for _, f in ipairs(fails) do ns:Print("  FAIL store/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("store", Store.RunSelfTests)
end
