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
            -- per-aura normal/minimum duration thresholds (seconds)
            thresholds = {},                 -- ["auraKey"] = { normal=, minimum= }
            -- per-class required/optional/ignored maps for Rend & Battle Shout
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
        social = {
            guild   = {},       -- ["Name-Realm"] = true
            friends = {},       -- ["Name-Realm"] = true
        },
        deletedAIDs = {},       -- [aid] = tombstoneEpoch (local-only, never broadcast)
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

        DaseekiNexusData = defaultData()
        DaseekiNexusData.version = Store.STORAGE_VERSION
        if preservedTimers  then DaseekiNexusData.timers = preservedTimers end
        if preservedSocial  then DaseekiNexusData.social = preservedSocial end
        if preservedManual  then DaseekiNexusData.manualLocations = preservedManual end
        if preservedNotes   then DaseekiNexusData.notes = preservedNotes end
        if preservedNotesMig ~= nil then DaseekiNexusData.notesMigrated = preservedNotesMig end
        if preservedDeleted then DaseekiNexusData.deletedAIDs = preservedDeleted end
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
-- Convenience read accessors for other modules
----------------------------------------------------------------------

function Store.GetSettings()      return Store.db end
function Store.GetData()          return Store.data end
function Store.GetTimers()        return Store.data.timers end
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

function Store.RunSelfTests(verbose)
    local suites = {
        { name = "defaults",        fn = testDefaults },
        { name = "alert migration", fn = testAlertMigration },
        { name = "songflower migration", fn = testSongflowerMigration },
        { name = "notes",           fn = testNotes },
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
