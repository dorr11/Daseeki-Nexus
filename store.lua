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
local DMF_OFFLINE_CLEAR  = 8 * 3600      -- ~8h resting-offline clears sibling DMF CD
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
            enabled        = false,
            alwaysAccept   = false,
            freshBuffWindow = 19,            -- seconds; accept if a buff is <19s old
            triggers       = {},             -- ["buffKey"] = true
            dropOnTaxiPvp  = true,
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
    -- Horde threshold overrides: Rend/Warchief's is a Horde-native buff,
    -- so the default fresh-buff window is tightened for summon gating.
    horde.autoSummon.freshBuffWindow = 15
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

-- Default coordinate overrides (spec: up to 15; ships with the three
-- canonical staging/DMF rules). Each rule maps a zone + coord box to a
-- human label shown in the dashboard location column.
local function defaultCoordinateOverrides()
    return {
        { name = "Rend North Staging", zone = "Orgrimmar",
          minX = 0.30, maxX = 0.55, minY = 0.55, maxY = 0.80, label = "Rend Staging (N)" },
        { name = "Rend South Staging", zone = "Durotar",
          minX = 0.40, maxX = 0.60, minY = 0.10, maxY = 0.30, label = "Rend Staging (S)" },
        { name = "DMF Mulgore", zone = "Mulgore",
          minX = 0.30, maxX = 0.50, minY = 0.55, maxY = 0.75, label = "Darkmoon Faire" },
    }
end

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

local function defaultAlertMatrix()
    local matrix = {}
    for _, evt in ipairs(ALERT_EVENT_TYPES) do
        local perBuff = {}
        local snd = ALERT_EVENT_SOUND[evt] or "RaidWarning"
        for _, buff in ipairs(ALERT_EVENT_BUFFS[evt]) do
            perBuff[buff] = { notify = true, chat = false, flash = false, sound = snd }
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
-- Songflower display-duration default correction (owner-confirmed).
--
-- An earlier build shipped flowerMinusDuration=120 / flowerUpDuration=5, but
-- songflower respawn is 25 minutes; those defaults decayed a live node to
-- "No data" ~125s after a pick. The accurate values are 1500s (25m, matching
-- Timers.NODE_RESPAWN) and 0 (indefinite UP? window, matching NodeState). Only
-- values that STILL equal the old defaults are rewritten — a user-customized
-- number is preserved. Idempotent by nature (1500 ~= 120, 0 ~= 5).
----------------------------------------------------------------------

function Store.MigrateSongflowerDefaults(db)
    if type(db) ~= "table" then return end
    local fw = db.timerSettings and db.timerSettings.felwood
    if type(fw) ~= "table" then return end
    if fw.flowerMinusDuration == 120 then fw.flowerMinusDuration = 1500 end
    if fw.flowerUpDuration    == 5   then fw.flowerUpDuration    = 0    end
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
-- Init: attach SVs, apply defaults, run the version-stamped wipe
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

    applyDefaults(DaseekiNexusDB, defaultSettings())
    DaseekiNexusDB.settingsVersion = Store.SETTINGS_VERSION

    -- One-time, additive install of the per-faction aura thresholds (spec §4.6)
    -- and the Rend / Battle Shout class expectations (spec §4.7). Runs AFTER
    -- applyDefaults so factionSettings/auraOpts is guaranteed to exist, and
    -- self-disables via auraOpts.defaultsApplied (never re-seeds).
    Store.SeedAuraDefaults(DaseekiNexusDB)

    -- Data SV
    if type(DaseekiNexusData) ~= "table" then
        DaseekiNexusData = defaultData()
    end

    -- Version-stamped wipe: if the storage schema advanced, discard the
    -- character-graph (accounts) but PRESERVE timers, social, and
    -- manualLocations exactly, per spec.
    if DaseekiNexusData.version ~= Store.STORAGE_VERSION then
        local preservedTimers  = DaseekiNexusData.timers
        local preservedSocial  = DaseekiNexusData.social
        local preservedManual  = DaseekiNexusData.manualLocations
        local preservedNotes   = DaseekiNexusData.notes
        local preservedNotesMig = DaseekiNexusData.notesMigrated
        local preservedDeleted = DaseekiNexusData.deletedAIDs
        -- Instance ledger is account-scoped state the wipe must PRESERVE (like
        -- notes/manualLocations): the caps math is only useful across sessions.
        local preservedInstances = DaseekiNexusData.instances
        -- The suite-namespace payloads are cross-account caches (like accounts,
        -- reconstructible from the mesh) but expensive to re-pull -- KBs per
        -- owner -- so preserve them across a character-graph wipe rather than
        -- forcing every peer to resend. Not schema-coupled to the char graph.
        local preservedSyncNS  = DaseekiNexusData.syncNamespaces
        local preservedSyncKV  = DaseekiNexusData.syncKV
        local preservedImported = DaseekiNexusData.bagsImported

        DaseekiNexusData = defaultData()
        DaseekiNexusData.version = Store.STORAGE_VERSION
        if preservedTimers  then DaseekiNexusData.timers = preservedTimers end
        if preservedSocial  then DaseekiNexusData.social = preservedSocial end
        if preservedManual  then DaseekiNexusData.manualLocations = preservedManual end
        if preservedNotes   then DaseekiNexusData.notes = preservedNotes end
        if preservedNotesMig ~= nil then DaseekiNexusData.notesMigrated = preservedNotesMig end
        if preservedDeleted then DaseekiNexusData.deletedAIDs = preservedDeleted end
        if preservedInstances then DaseekiNexusData.instances = preservedInstances end
        if preservedSyncNS  then DaseekiNexusData.syncNamespaces = preservedSyncNS end
        if preservedSyncKV  then DaseekiNexusData.syncKV = preservedSyncKV end
        if preservedImported ~= nil then DaseekiNexusData.bagsImported = preservedImported end
    end

    -- Backfill any structure a partial/older DB is missing.
    applyDefaults(DaseekiNexusData, defaultData())

    -- One-time additive copy of legacy location overrides into empty notes.
    Store.MigrateNotes(DaseekiNexusData)

    Store.db   = DaseekiNexusDB
    Store.data = DaseekiNexusData
end

----------------------------------------------------------------------
-- Login: run sweeps that should happen once the world is available
----------------------------------------------------------------------

function Store.OnLogin()
    Store.SweepTombstones()
    Store.WeeklyResetSweep()
    Store.SweepOrphanBucket()
    Store.SweepOfflineDMF()
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
        boonCount       = 0,
        shardCount      = 0,       -- warlock soul shards
        soulstoneReady  = false,   -- warlock: a soulstone is available (item in bags
                                   -- and/or Create Soulstone off cooldown) — item 6
        itemCooldown    = 0,       -- remaining seconds on the tracked trinket/item
        hearthstoneCD   = 0,       -- remaining seconds
        dmfInBoon       = false,   -- currently holding a Darkmoon fortune
        dmfCooldownActive = false,
        dmfCooldown     = { offlineSince = 0 },
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
    bucket.characters[nameRealm] = record
    return true
end

----------------------------------------------------------------------
-- Retention: timer logs (cap 15, 48h expiry, 30s dedup)
----------------------------------------------------------------------

-- Insert a log entry newest-first with dedup + expiry + cap. `entry` is
-- { epoch, who, killed?/quest? }. Returns true if inserted.
function Store.AddTimerLog(logKey, entry)
    local logs = Store.data.timers.logs
    local list = logs[logKey]
    if not list then
        list = {}
        logs[logKey] = list
    end
    local now = entry.epoch or serverNow()
    -- Dedup: same source within the dedup window is a duplicate report.
    for i = 1, #list do
        local e = list[i]
        if math.abs((e.epoch or 0) - now) <= LOG_DEDUP_WINDOW
           and e.who == entry.who then
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
-- Retention: offline sibling DMF cooldown clear (~8h resting-offline)
----------------------------------------------------------------------

function Store.SweepOfflineDMF()
    local now = serverNow()
    for aid, bucket in pairs(Store.data.accounts) do
        for _, rec in pairs(bucket.characters) do
            if rec.dmfCooldownActive and rec.dmfCooldown then
                local since = rec.dmfCooldown.offlineSince or 0
                if since > 0 and (now - since) >= DMF_OFFLINE_CLEAR then
                    rec.dmfCooldownActive = false
                    rec.dmfCooldown.offlineSince = 0
                end
            end
        end
    end
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
    -- User-customized values are preserved.
    local custom = { timerSettings = { felwood = {
        flowerMinusDuration = 900, flowerUpDuration = 3 } } }
    Store.MigrateSongflowerDefaults(custom)
    ck(custom.timerSettings.felwood.flowerMinusDuration == 900, "custom minus 900 untouched")
    ck(custom.timerSettings.felwood.flowerUpDuration == 3, "custom UP? 3 untouched")
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

function Store.RunSelfTests(verbose)
    local suites = {
        { name = "defaults",        fn = testDefaults },
        { name = "alert migration", fn = testAlertMigration },
        { name = "aura seeds",      fn = testAuraSeeds },
        { name = "songflower migration", fn = testSongflowerMigration },
        { name = "notes",           fn = testNotes },
        { name = "inbound name guard", fn = testInboundNameGuard },
        { name = "rested percent",  fn = testRestedPercent },
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
