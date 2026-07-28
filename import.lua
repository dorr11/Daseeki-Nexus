-- Daseeki Nexus — import.lua  (WAVE N4b: ShadowNetwork IMPORTER)
--
-- One-way, non-destructive importer that lifts a returning ShadowNetwork
-- user's SavedVariables DATA into Daseeki-Nexus's store shape, so Drew's
-- accounts re-mesh and re-populate with zero manual re-setup.
--
-- LEGAL / FIREWALL NOTE
-- --------------------
-- This is the ONE file permitted to name ShadowNetwork identifiers, and ONLY
-- the two SavedVariables GLOBALS the user owns (`ShadowNetworkDB`,
-- `ShadowNetworkStorageDB`) plus the SV key strings inside them. No line of
-- the ShadowNetwork ADDON was read to write this; the mapping is derived
-- solely from the clean-room engine spec (§2a/§2b) and the owner's own SV
-- data files. We only ever READ those globals — never write them.
--
-- ARCHITECTURE
-- ------------
-- The mapping is split into PURE cores that take the SN tables as arguments
-- and return our-shaped partial tables + per-category counts. They touch no
-- WoW globals, so the offline validation harness runs the exact shipping
-- logic against the real SV files. `Run()`/`IsAvailable()` are the thin
-- WoW-facing wrappers that read the globals and apply into the live Store.

local ADDON, ns = ...

local Import = {}
ns.Import = Import

----------------------------------------------------------------------
-- The two ShadowNetwork SavedVariables GLOBAL names. These two strings +
-- the SV key strings referenced in the mapping below are the ONLY
-- "ShadowNetwork" tokens permitted anywhere in the repo (firewall gate).
----------------------------------------------------------------------

local SN_SETTINGS_GLOBAL = "ShadowNetworkDB"
local SN_STORAGE_GLOBAL  = "ShadowNetworkStorageDB"

----------------------------------------------------------------------
-- Small pure helpers (no WoW globals)
----------------------------------------------------------------------

local function shallowCopy(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = (type(v) == "table") and deepCopy(v) or v
    end
    return out
end

local function countKeys(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

-- Recursive overwrite-merge: copy every key from `src` onto `dst`, replacing
-- scalars and descending into tables. Used to apply an imported partial over
-- the live (defaulted) Store without dropping keys the importer didn't touch.
-- Idempotent: re-applying the same partial yields the same result.
local function overwriteMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            overwriteMerge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end
Import._OverwriteMerge = overwriteMerge

-- {r,g,b} floats (0..1) -> "RRGGBB" upper-hex. Nil-safe.
local function rgbToHex(c)
    if type(c) ~= "table" then return nil end
    local function b(x)
        x = math.floor((tonumber(x) or 0) * 255 + 0.5)
        if x < 0 then x = 0 elseif x > 255 then x = 255 end
        return string.format("%02X", x)
    end
    return b(c[1]) .. b(c[2]) .. b(c[3])
end
Import._RgbToHex = rgbToHex

----------------------------------------------------------------------
-- Vocabulary translation tables
----------------------------------------------------------------------

-- ShadowNetwork's custom sound-file tokens -> nearest Blizzard SoundKit name.
-- Our store keeps sound choices as SoundKit *names* (matching store.lua's
-- defaults: "RaidWarning" / "AuctionWindowOpen" / "TellMessage"); hud.lua owns
-- the final name->SoundKit resolution, so an unknown name simply falls back
-- there. "none"/"" -> nil (leave the store default untouched).
local SOUND_MAP = {
    bell             = "AuctionWindowOpen",
    happy_bells      = "AuctionWindowOpen",
    correct_reward   = "AuctionWindowOpen",
    atm_press        = "TellMessage",
    interface_select = "TellMessage",
    digital_tone     = "TellMessage",
    clear_announce   = "RaidWarning",
    game_win         = "RaidWarning",
    wrong_answer     = "RaidWarning",
    none             = nil,
}
Import._SoundMap = SOUND_MAP

local function mapSound(tok)
    if tok == nil or tok == "" or tok == "none" then return nil end
    return SOUND_MAP[tok]   -- nil for unknown tokens -> keep store default
end

-- Our alert matrix is keyed by faction-split buff keys; SN's alert matrix uses
-- faction-agnostic keys. Expansion: an SN "ony" entry seeds BOTH onyH & onyA.
-- SN "dmf" has no buff-key home in our ALERT_BUFF_KEYS -> dropped (documented).
local ALERT_BUFF_EXPANSION = {
    rend        = { "rend" },
    ony         = { "onyH", "onyA" },
    nef         = { "nefH", "nefA" },
    zan         = { "zg" },
    battleshout = { "battleShout" },
    -- dmf = nil  (intentionally unmapped; no faction/world-buff slot for it)
}

-- SN dmfBuffTypes / auraOpts states are passed through verbatim (same string
-- vocabulary the consumer expects); only structure is transformed.

----------------------------------------------------------------------
-- Character record mapping (SN §2b record -> our Store.NewCharacterRecord shape)
--
-- KNOWN FIELD DELTAS (see the migration table in the deliverable):
--   * SN "heartstoneCD"        -> our "hearthstoneCD"     (SN misspells the H)
--   * SN "pvpExpireAtEpoch"    -> our "pvpExpiry"
--   * SN "lastSeenEpoch"       -> our "lastSeen"          (server epoch; SN's
--                                  client-uptime "lastSeen" is non-portable)
--   * SN "lastDataUpdateEpoch" -> our "lastDataUpdate" AND "ownerEpoch"
--   * SN "dmfCooldown.offlineSinceEpoch" -> our "dmfCooldown.offlineSince"
--     (SN's remainingOnlineSecs / lastTickEpoch have no slot -> dropped;
--      rebuild live from the DMF lifecycle tracker)
--   * SN "lastChronoboonSeenAt" is client-uptime -> our chronoboonLastSeen is
--     seeded from lastSeenEpoch when a boon is active (rebuilds live anyway)
----------------------------------------------------------------------

local function mapAuraStates(sn)
    local out = {}
    if type(sn) ~= "table" then return out end
    for i = 1, #sn do
        local a = sn[i]
        out[i] = {
            duration = (a and a.duration) or 0,
            option   = (a and a.option) or 1,
            source   = (a and a.source) or 0,
        }
    end
    return out
end
Import._MapAuraStates = mapAuraStates

function Import._MapCharacterRecord(sn)
    local dmfOffline = 0
    if type(sn.dmfCooldown) == "table" then
        dmfOffline = sn.dmfCooldown.offlineSinceEpoch or 0
    end
    return {
        nameRealm          = sn.nameRealm,
        classTag           = sn.classTag,
        className          = sn.className,
        faction            = sn.faction,
        level              = sn.level or 0,
        location           = sn.location,
        inInstance         = sn.inInstance or false,
        isResting          = sn.isResting or false,
        pvpFlagged         = sn.pvpFlagged or false,
        pvpExpiry          = sn.pvpExpireAtEpoch or 0,
        chronoboonActive   = sn.chronoboonActive or false,
        chronoboonLastSeen = (sn.chronoboonActive and (sn.lastSeenEpoch or 0)) or 0,
        boonCount          = sn.boonCount or 0,
        shardCount         = sn.shardCount or 0,
        itemCooldown       = sn.itemCooldown or 0,
        hearthstoneCD      = sn.heartstoneCD or 0,   -- SN spelling delta
        dmfInBoon          = sn.dmfInBoon or false,
        dmfCooldownActive  = sn.dmfCooldownActive or false,
        dmfCooldown        = { offlineSince = dmfOffline },
        raidLockouts       = deepCopy(sn.raidLockouts) or {},
        auraStates         = mapAuraStates(sn.auraStates),
        lastSeen           = sn.lastSeenEpoch or 0,
        lastDataUpdate     = sn.lastDataUpdateEpoch or 0,
        ownerEpoch         = sn.lastDataUpdateEpoch or 0,
    }
end

----------------------------------------------------------------------
-- Account bucket mapping (SN account -> our Store.NewAccountBucket shape)
-- Skips the per-bucket `homeless` sub-table (design: rebuilds live).
----------------------------------------------------------------------

function Import._MapAccountBucket(snAcct)
    local seg = snAcct.segments or {}
    local bucket = {
        isSelf     = snAcct.isSelf or false,
        characters = {},
        segments   = {
            sixties   = deepCopy(seg.sixties) or {},
            summoners = deepCopy(seg.summoners) or {},
            norole    = deepCopy(seg.norole) or {},
        },
        -- SN's segment hashes use SN's hash function; ours are recomputed live
        -- from segments on the next heartbeat (Mesh.AccountHashes never reads
        -- stored hashes), so keeping SN's is advisory-only but preserves the
        -- manifest epoch used by owner-wins tiebreaks.
        segmentHashes = deepCopy(snAcct.segmentHashes) or {},
        homeless      = {},   -- SKIP per design
    }
    local n = 0
    if type(snAcct.characters) == "table" then
        for nameRealm, rec in pairs(snAcct.characters) do
            bucket.characters[nameRealm] = Import._MapCharacterRecord(rec)
            n = n + 1
        end
    end
    return bucket, n
end

----------------------------------------------------------------------
-- Per-faction settings mapping (SN §2a factionSettings -> our defaultFactionBlock)
----------------------------------------------------------------------

-- Invert an SN class->state map ({WARRIOR="required",...}) into our
-- state->class-set shape ({required={WARRIOR=true},optional={},ignored={}}).
local function invertClassMap(m)
    local out = { required = {}, optional = {}, ignored = {} }
    if type(m) == "table" then
        for class, state in pairs(m) do
            if out[state] then out[state][class] = true end
        end
    end
    return out
end
Import._InvertClassMap = invertClassMap

-- Canonical positional aura order shared by SN's auraOpts.thresholds[i] and
-- autoSummon.buffTriggers[i]. Source of truth: NETWORK_SPEC_UI §2 Thresholds
-- table order (DMF, Ony, DMT AP, DMT SP, DMT STAM, Songflower, ZG, Rend,
-- Battle Shout), which our options.lua AURA_DEFS mirrors 1:1. SN stores these
-- positionally; our store keys them by aura name, so the importer resolves the
-- ordinal here. Keys MUST match options.lua AURA_DEFS exactly.
local AURA_SLOT_KEY = {
    "dmf", "ony", "dmtAP", "dmtSP", "dmtStam", "songflower", "zg", "rend", "battleShout",
}

-- Which summon trigger key (auto.lua SUMMON_TRIGGER_BUFFS) each aura slot maps
-- to. dmf (slot 1) and battleShout (slot 9) have no summon trigger and are
-- skipped. Keys MUST match auto.lua Auto.SUMMON_TRIGGER_BUFFS.
local AURA_SLOT_TRIGGER = {
    [2] = "dragonslayer",  -- ony  -> Rallying Cry of the Dragonslayer
    [3] = "fengus",        -- dmtAP
    [4] = "slipkik",       -- dmtSP
    [5] = "moldar",        -- dmtStam
    [6] = "songflower",    -- songflower
    [7] = "zandalar",      -- zg
    [8] = "warchief",      -- rend -> Warchief's Blessing
}

-- Map SN's positional {normal,minimum} threshold array onto our NAMED aura
-- keys (store auraOpts.thresholds is keyed by aura name; ui_shell.GetThreshold
-- and options.lua both read it by key). Unknown/overflow slots are dropped.
local function mapThresholds(arr)
    local out = {}
    if type(arr) == "table" then
        -- Iterate the canonical slot count (not #arr) so a sparse/short array
        -- still resolves every present slot to its named key.
        for i = 1, #AURA_SLOT_KEY do
            local e = arr[i]
            if e ~= nil then
                out[AURA_SLOT_KEY[i]] = { normal = (e and e.normal) or 0, minimum = (e and e.minimum) or 0 }
            end
        end
    end
    return out
end

-- Map SN's positional buffTriggers array onto our summon-trigger KEYS
-- (auto.lua consumes autoSummon.triggers[key]). Slots without a trigger
-- (dmf, battleShout) are skipped.
local function mapBuffTriggers(arr)
    local out = {}
    if type(arr) == "table" then
        -- Iterate the canonical slot count (not #arr) so a sparse/short array
        -- still resolves every trigger-bearing slot to its named key.
        for i = 1, #AURA_SLOT_KEY do
            local key = AURA_SLOT_TRIGGER[i]
            if key and arr[i] ~= nil then out[key] = arr[i] and true or false end
        end
    end
    return out
end

function Import._MapFaction(f)
    f = f or {}
    local ag = f.autoGroup or {}
    local as = f.autoSummon or {}
    local ago = f.autoGossip or {}
    local aq = f.autoQuest or {}
    local ai = f.autoInteract or {}
    local ao = f.auraOpts or {}
    return {
        autoGroup = {
            acceptFromRoster  = ag.acceptFromRoster,
            acceptFromGuild   = ag.acceptFromGuild,
            acceptFromFriends = ag.acceptFromFriends,
            acceptFromAnyone  = ag.acceptFromAnyone,
            sendToRoster      = ag.sendToRoster,
            inviteKeyword     = ag.inviteKeyword,
            whitelist         = deepCopy(ag.inviteWhitelist) or {},
            defaultsApplied   = ag.inviteWhitelistDefaultsApplied,
            -- SN sendToGuild/sendToFriends/sendToAnyone/inviteWhitelistEnabled
            -- have no slot in our simplified send model (sendToRoster only).
        },
        autoSummon = {
            enabled         = as.enabled,
            alwaysAccept    = as.alwaysAccept,
            freshBuffWindow = as.summonWindow,
            dropOnTaxiPvp   = as.taxiPvpDrop,
            triggers        = mapBuffTriggers(as.buffTriggers),
        },
        autoGossip = {
            dmt = ago.dmtEnabled,
            bwl = ago.bwlEnabled,
            dmf = {
                enabled    = ago.dmfEnabled,
                skipCookie = ago.dmfSkipCookie,
                buffType   = deepCopy(ago.dmfBuffTypes) or {},
            },
        },
        autoQuest = {
            eko        = aq.ekoEnabled,
            zgCoins    = aq.coinsEnabled,
            roids      = aq.roidsEnabled,
            autoRepair = aq.autoRepairEnabled,
            zanza      = { enabled = aq.zanzaEnabled, priority = deepCopy(aq.zanzaPicks) or {} },
        },
        -- SN nests interact NPCs under `.npcs`; our store keeps them flat.
        autoInteract = deepCopy(ai.npcs) or {},
        auraOpts = {
            thresholds  = mapThresholds(ao.thresholds),
            rend        = invertClassMap(ao.rendClasses),
            battleShout = invertClassMap(ao.bsClasses),
        },
    }
end

----------------------------------------------------------------------
-- coordinateOverrides mapping (SN point+tolerance -> our zone box + label)
--
-- SN stores up to 15 slots of {name,x,y,tolerance}; empties are padded with
-- name="". We import only the named entries, converting the point+tolerance
-- into our min/max box. SN carries no zone, so `zone` is left "" (the pins/
-- location matcher treats an empty zone as unscoped; the user can re-pick).
----------------------------------------------------------------------

function Import._MapCoordinateOverrides(arr)
    local out = {}
    if type(arr) ~= "table" then return out end
    for i = 1, #arr do
        local e = arr[i]
        if e and e.name and e.name ~= "" then
            local tol = e.tolerance or 0.02
            out[#out + 1] = {
                name  = e.name,
                label = e.name,
                zone  = "",
                minX  = (e.x or 0) - tol,
                maxX  = (e.x or 0) + tol,
                minY  = (e.y or 0) - tol,
                maxY  = (e.y or 0) + tol,
            }
        end
    end
    return out
end

----------------------------------------------------------------------
-- Alert matrix mapping (SN [event][buff] -> our [buff][event], sound-name->bool)
----------------------------------------------------------------------

local ALERT_EVENTS = {
    "questHandin", "pullTimer", "npcDied", "npcRespawned",
    "cdWarning", "cdExpired", "buffGain",
}

function Import._MapAlertMatrix(snAlerts)
    local out = {}
    local entries = 0
    if type(snAlerts) ~= "table" then return out, entries end
    for _, evt in ipairs(ALERT_EVENTS) do
        local perBuff = snAlerts[evt]
        if type(perBuff) == "table" then
            for snBuff, cell in pairs(perBuff) do
                local targets = ALERT_BUFF_EXPANSION[snBuff]
                if targets and type(cell) == "table" then
                    -- SN's per-cell `enabled=false` disables every channel.
                    local on = cell.enabled ~= false
                    local mapped = {
                        notify = on and (cell.notify or false) or false,
                        chat   = on and (cell.chat or false) or false,
                        flash  = on and (cell.flash or false) or false,
                        sound  = on and (cell.sound ~= nil and cell.sound ~= "none"
                                          and cell.sound ~= "") or false,
                    }
                    for _, ourBuff in ipairs(targets) do
                        out[ourBuff] = out[ourBuff] or {}
                        out[ourBuff][evt] = deepCopy(mapped)
                        entries = entries + 1
                    end
                end
            end
        end
    end
    return out, entries
end

----------------------------------------------------------------------
-- timerSettings mapping (SN flat -> our nested)
----------------------------------------------------------------------

function Import._MapTimerSettings(t)
    t = t or {}
    local alerts, alertEntries = Import._MapAlertMatrix(t.alerts)

    -- soundKeys: only set entries whose SN token resolves to a SoundKit name;
    -- nil leaves the store default in place.
    local soundKeys = {}
    local sNpc = mapSound(t.soundNpcDeath)
    if sNpc then soundKeys.npcDied = sNpc; soundKeys.npcRespawned = sNpc end
    local sPull = mapSound(t.soundRend) or mapSound(t.soundOnyNef)
    if sPull then soundKeys.pullTimer = sPull end

    local rd = (type(t.alerts) == "table" and t.alerts.raidDisable) or {}

    return {
        felwood = {
            -- SN has a single master `showFelwoodPins`; our store splits pins.
            showFlowerPins = t.showFelwoodPins,
            showTuberPins  = t.showFelwoodPins,
            worldPinSize   = t.wmFlowerIconSize,
            minimapPinSize = t.mmFlowerIconSize,
            -- Songflower display durations (nil leaves our store default).
            flowerMinusDuration = t.flowerMinusTimerDuration,
            flowerUpDuration    = t.flowerUpDuration,
        },
        pullBar = {
            width     = t.pullTimerMainBarWidth,
            height    = t.pullTimerMainBarHeight,
            anchor    = t.pullTimerMainAnchor,
            offsetX   = t.pullTimerMainOffsetX,
            offsetY   = t.pullTimerMainOffsetY,
            locked    = t.pullTimerLocked,
            colorFill = rgbToHex(t.pullTimerBarColor),
        },
        soundChannel = t.soundChannel,
        soundKeys    = soundKeys,
        alerts       = alerts,
        raidDisable  = {
            notify = rd.notify,
            chat   = rd.chat,
            flash  = rd.flash,
            sound  = rd.sound,
            -- SN raidDisable.pullTimerBars has no store slot -> dropped.
        },
    }, alertEntries
end

----------------------------------------------------------------------
-- PURE settings core: SN ShadowNetworkDB -> our settings partial + counts
----------------------------------------------------------------------

function Import._MapSettings(sn)
    sn = sn or {}
    local counts = {}
    local mesh = sn.mesh or {}
    local ui = sn.ui or {}

    local coords = Import._MapCoordinateOverrides(sn.coordinateOverrides)
    local timerSettings, alertEntries = Import._MapTimerSettings(sn.timerSettings)

    local out = {
        accountID         = sn.accountId or "",
        autoConvertToRaid = sn.autoConvertToRaid,
        autoAssistAll     = sn.autoAssistAll,
        hardThrottle      = sn.hardThrottleEnabled,
        minimap = {
            -- SN's minimapPos is an on-minimap angle; our button is free-float
            -- (§9), so position is not carried — only visibility + lock.
            hide = (sn.showMinimapButton == false),
            lock = sn.lockMinimapButton,
        },
        mesh = {
            token            = mesh.meshToken,     -- 6-char SN token; our validation is non-empty
            enabled          = mesh.mainEnabled,
            optOut           = mesh.meshOptOut,
            bondChannels     = deepCopy(mesh.bondChannels) or { "", "", "" },
            autoLeaveChannel = mesh.autoLeaveEnabled,
            -- SN mainChannel name is not carried: our channel is derived from
            -- the token (Mesh.GetChannelName).
        },
        classColors         = deepCopy(sn.classColors) or {},
        coordinateOverrides = coords,
        factionSettings = {
            Alliance = Import._MapFaction((sn.factionSettings or {}).Alliance),
            Horde    = Import._MapFaction((sn.factionSettings or {}).Horde),
        },
        timerSettings = timerSettings,
        ui = {
            summonerSortDir   = (ui.summonersAscending == false) and "desc" or "asc",
            selectedCharacter = ui.selectedCharacter,
            blacklist         = deepCopy(ui.blacklist) or {},
            whitelist         = deepCopy(ui.whitelist) or {},
            -- SN ui.activeFaction has no store slot -> dropped (UI default).
        },
    }

    counts.accountID          = (out.accountID ~= nil and out.accountID ~= "") and 1 or 0
    counts.meshToken          = (mesh.meshToken and mesh.meshToken ~= "") and 1 or 0
    counts.coordinateOverrides = #coords
    counts.classColors        = countKeys(out.classColors)
    counts.factions           = 2
    counts.blacklist          = countKeys(out.ui.blacklist)
    counts.whitelist          = countKeys(out.ui.whitelist)
    counts.alertEntries       = alertEntries
    return out, counts
end

----------------------------------------------------------------------
-- PURE data core: SN ShadowNetworkStorageDB -> our data partial + counts
----------------------------------------------------------------------

-- SN timers block uses flat flowerN/tuberN keys + rendLog/onyLogH/onyLogA;
-- our store nests flower[1..10]/tuber[1..6] and logs.{rend,onyH,onyA}.
local function mapTimers(snT)
    snT = snT or {}
    local flower, tuber = {}, {}
    local flowerN, tuberN = 0, 0
    for i = 1, 10 do
        local v = snT["flower" .. i]
        if v and v > 0 then flower[i] = v; flowerN = flowerN + 1 end
    end
    for i = 1, 6 do
        local v = snT["tuber" .. i]
        if v and v > 0 then tuber[i] = v; tuberN = tuberN + 1 end
    end
    local logs = {
        rend = deepCopy(snT.rendLog) or {},
        onyH = deepCopy(snT.onyLogH) or {},
        onyA = deepCopy(snT.onyLogA) or {},
    }
    return {
        flower            = flower,
        tuber             = tuber,
        logs              = logs,
        timerVersion      = snT.timerVersion or 1,
        lastWeeklyResetAt = snT.lastWeeklyResetAt or 0,
        -- SN rendYell/rendTimer are live-CD runtime fields with no store slot;
        -- recoverable from logs + live detection, so dropped.
    }, flowerN, tuberN, #logs.rend, #logs.onyH, #logs.onyA
end

function Import._MapData(sn)
    sn = sn or {}
    local counts = { accounts = 0, characters = 0, tombstones = 0 }

    local accounts = {}
    if type(sn.accounts) == "table" then
        for aid, snAcct in pairs(sn.accounts) do
            local bucket, n = Import._MapAccountBucket(snAcct)
            accounts[aid] = bucket
            counts.accounts = counts.accounts + 1
            counts.characters = counts.characters + n
        end
    end

    local timers, flowerN, tuberN, rendN, onyHN, onyAN = mapTimers(sn.timers)

    local manualLocations = deepCopy(sn.manualLocations) or {}
    local deletedAIDs = deepCopy(sn.deletedAIDs) or {}
    counts.tombstones = countKeys(deletedAIDs)
    counts.manualLocations = countKeys(manualLocations)
    counts.flower = flowerN
    counts.tuber = tuberN
    counts.logRend = rendN
    counts.logOnyH = onyHN
    counts.logOnyA = onyAN

    local out = {
        accounts        = accounts,
        timers          = timers,
        manualLocations = manualLocations,
        deletedAIDs     = deletedAIDs,
        -- SKIP per design: caches (localBoonCache/tooltipBoonCache), social,
        -- per-bucket homeless. These rebuild live from mesh + game events.
    }
    return out, counts
end

----------------------------------------------------------------------
-- WoW-facing wrappers
----------------------------------------------------------------------

-- Read the two SN globals (or nil). Kept behind _G indexing so the firewall
-- grep sees the names only as data strings, never as bareword references.
local function snGlobals()
    local G = _G or getfenv(0)
    return G[SN_SETTINGS_GLOBAL], G[SN_STORAGE_GLOBAL]
end

-- True when either ShadowNetwork SavedVariable is loaded in memory (i.e. the
-- addon is still installed + enabled this session).
function Import.IsAvailable()
    local db, data = snGlobals()
    return (type(db) == "table") or (type(data) == "table")
end

-- Format the count table into ordered summary lines for chat / harness.
local function summaryLines(sc, dc)
    return {
        string.format("settings: accountID=%d, meshToken=%d, coordOverrides=%d, classColors=%d, factions=%d, alertEntries=%d, blacklist=%d, whitelist=%d",
            sc.accountID or 0, sc.meshToken or 0, sc.coordinateOverrides or 0,
            sc.classColors or 0, sc.factions or 0, sc.alertEntries or 0,
            sc.blacklist or 0, sc.whitelist or 0),
        string.format("data: accounts=%d, characters=%d, tombstones=%d, manualLocations=%d",
            dc.accounts or 0, dc.characters or 0, dc.tombstones or 0, dc.manualLocations or 0),
        string.format("timers: flowers=%d, tubers=%d, rendLog=%d, onyLogH=%d, onyLogA=%d",
            dc.flower or 0, dc.tuber or 0, dc.logRend or 0, dc.logOnyH or 0, dc.logOnyA or 0),
    }
end
Import._SummaryLines = summaryLines

-- Apply the mapped partials into the live Store (settings + data). Overwrite-
-- merges so re-import is idempotent. Never touches the SN globals.
function Import._Apply(settingsPartial, dataPartial)
    local Store = ns.Store
    if not (Store and Store.GetSettings and Store.GetData) then return false end
    local db   = Store.GetSettings()
    local data = Store.GetData()
    if not (db and data) then return false end

    overwriteMerge(db, settingsPartial)

    -- Data: overwrite the account graph, timers, manualLocations, tombstones.
    data.accounts = dataPartial.accounts
    data.timers = dataPartial.timers
    overwriteMerge(data.manualLocations, dataPartial.manualLocations)
    overwriteMerge(data.deletedAIDs, dataPartial.deletedAIDs)

    -- Backfill any structure the imported partials didn't set, from defaults.
    if Store.ApplyDefaults then
        -- Re-run the defaults fill via Init's helpers is overkill; the store's
        -- own defaults are already present pre-import, and overwriteMerge only
        -- replaced touched keys, so no explicit backfill is required here.
    end
    return true
end

-- Run the import. `dryRun` truthy => compute + print counts, apply nothing.
-- Returns (ok, summaryTable) where summaryTable = { settings=..., data=... }.
function Import.Run(dryRun)
    local db, data = snGlobals()
    if not (type(db) == "table" or type(data) == "table") then
        if ns.Print then ns:Print("import: no ShadowNetwork SavedVariables found (is it still installed + enabled?).") end
        return false, nil
    end

    local settingsPartial, sc = Import._MapSettings(db or {})
    local dataPartial, dc = Import._MapData(data or {})

    if ns.Print then
        ns:Print(dryRun and "import DRY-RUN (nothing applied):" or "import applied:")
        local lines = summaryLines(sc, dc)
        for i = 1, #lines do ns:Print("  " .. lines[i]) end
    end

    if not dryRun then
        local ok = Import._Apply(settingsPartial, dataPartial)
        if not ok then
            if ns.Print then ns:Print("import: store not ready; nothing applied.") end
            return false, { settings = sc, data = dc }
        end
        -- Announce the state change so live views (dashboard/HUD/mesh) refresh.
        if ns.Fire then ns:Fire("STATE_CHANGED", "import") end
        if ns.Print then ns:Print("import complete. Consider disabling ShadowNetwork now.") end
    end

    return true, { settings = sc, data = dc }
end

----------------------------------------------------------------------
-- Slash subcommand: /dsn import [dry]
----------------------------------------------------------------------

if ns.RegisterSubcommand then
    ns:RegisterSubcommand("import", function(rest)
        rest = (rest and rest:match("^%s*(.-)%s*$")) or ""
        if not Import.IsAvailable() then
            ns:Print("import: ShadowNetwork is not loaded — nothing to import.")
            return
        end
        local dry = (rest == "dry" or rest == "dryrun" or rest == "preview")
        Import.Run(dry)
    end, "import settings + data from ShadowNetwork ('dry' to preview)")
end

----------------------------------------------------------------------
-- Self-test: SN-shaped fixture -> our shape, per category (pure; no globals)
----------------------------------------------------------------------

local function selfTest(verbose)
    local pass = true
    local function check(name, cond)
        if not cond then
            pass = false
            if verbose and ns.Print then ns:Print("  import selftest FAIL: " .. name) end
        end
    end

    -- Character record: spelling + epoch + dmf deltas.
    local rec = Import._MapCharacterRecord({
        nameRealm = "Foo-Bar", classTag = "MAGE", level = 60,
        heartstoneCD = 120, pvpExpireAtEpoch = 999, lastSeenEpoch = 111,
        lastDataUpdateEpoch = 222, chronoboonActive = true,
        dmfCooldown = { offlineSinceEpoch = 333, remainingOnlineSecs = 14400 },
        auraStates = { { option = 2, duration = 7000, source = 2 } },
    })
    check("hearthstoneCD spelling", rec.hearthstoneCD == 120)
    check("pvpExpiry", rec.pvpExpiry == 999)
    check("lastSeen<-epoch", rec.lastSeen == 111)
    check("ownerEpoch<-dataUpdateEpoch", rec.ownerEpoch == 222 and rec.lastDataUpdate == 222)
    check("dmf offlineSince", rec.dmfCooldown.offlineSince == 333)
    check("chronoboonLastSeen seeded", rec.chronoboonLastSeen == 111)
    check("auraStates slot", rec.auraStates[1] and rec.auraStates[1].duration == 7000)

    -- Class-map inversion.
    local inv = Import._InvertClassMap({ WARRIOR = "required", HUNTER = "ignored" })
    check("invert required", inv.required.WARRIOR == true)
    check("invert ignored", inv.ignored.HUNTER == true)
    check("invert absent", inv.optional.WARRIOR == nil)

    -- Alert transpose + buff expansion + sound-string->bool + enabled gate.
    local am = Import._MapAlertMatrix({
        pullTimer = {
            ony  = { enabled = true, notify = true, chat = false, flash = true, sound = "clear_announce" },
            zan  = { enabled = false, notify = true, chat = true, flash = true, sound = "bell" },
            dmf  = { enabled = true, notify = true, sound = "bell" },  -- no target
        },
    })
    check("alert transpose ony->onyH", am.onyH and am.onyH.pullTimer and am.onyH.pullTimer.notify == true)
    check("alert ony->onyA duplicated", am.onyA and am.onyA.pullTimer and am.onyA.pullTimer.flash == true)
    check("alert sound name->bool", am.onyH.pullTimer.sound == true)
    check("alert zan->zg disabled gate", am.zg and am.zg.pullTimer and am.zg.pullTimer.notify == false and am.zg.pullTimer.sound == false)
    check("alert dmf dropped", am.dmf == nil)

    -- coordinateOverrides point+tol -> box, empties skipped.
    local co = Import._MapCoordinateOverrides({
        { name = "Rend North", x = 0.5, y = 0.47, tolerance = 0.02 },
        { name = "", x = 0, y = 0, tolerance = 0.08 },
    })
    check("coord count skips empties", #co == 1)
    check("coord box minX", math.abs(co[1].minX - 0.48) < 1e-9)
    check("coord label", co[1].label == "Rend North")

    -- rgb->hex.
    check("rgb->hex", Import._RgbToHex({ 0.2, 0.8, 0.2 }) == "33CC33")

    -- Faction autoInteract flatten + zanza priority + summonWindow rename +
    -- positional->keyed thresholds/triggers (canonical aura order).
    local fac = Import._MapFaction({
        autoQuest = { zanzaEnabled = true, zanzaPicks = { spirit = true } },
        -- buffTriggers slots: 1=dmf(skip) 2=ony 3=dmtAP; so ony->dragonslayer=false,
        -- dmtAP->fengus=true, dmf dropped.
        autoSummon = { summonWindow = 19, buffTriggers = { true, false, true } },
        autoInteract = { npcs = { ["Auctioneer Jaxon"] = true } },
        autoGroup = { inviteWhitelist = { ["A-B"] = true }, inviteWhitelistDefaultsApplied = true },
        -- threshold slots: 1=dmf 2=ony 8=rend.
        auraOpts = { thresholds = {
            [1] = { normal = 100, minimum = 50 },
            [2] = { normal = 200, minimum = 90 },
            [8] = { normal = 800, minimum = 400 },
        } },
    })
    check("faction summonWindow->freshBuffWindow", fac.autoSummon.freshBuffWindow == 19)
    check("faction buffTriggers->keys (dmtAP->fengus)", fac.autoSummon.triggers.fengus == true)
    check("faction buffTriggers->keys (ony->dragonslayer)", fac.autoSummon.triggers.dragonslayer == false)
    check("faction buffTriggers dmf skipped", fac.autoSummon.triggers.dmf == nil)
    check("faction thresholds->keys (slot1->dmf)", fac.auraOpts.thresholds.dmf and fac.auraOpts.thresholds.dmf.normal == 100)
    check("faction thresholds->keys (slot2->ony)", fac.auraOpts.thresholds.ony and fac.auraOpts.thresholds.ony.minimum == 90)
    check("faction thresholds->keys (slot8->rend)", fac.auraOpts.thresholds.rend and fac.auraOpts.thresholds.rend.normal == 800)
    check("faction thresholds unset slot nil", fac.auraOpts.thresholds.zg == nil)
    check("faction zanza priority", fac.autoQuest.zanza.priority.spirit == true)
    check("faction interact flattened", fac.autoInteract["Auctioneer Jaxon"] == true)
    check("faction whitelist", fac.autoGroup.whitelist["A-B"] == true)

    -- Data timers: flat flowerN -> array, logs rename.
    local dp = Import._MapData({
        accounts = { ["1"] = { isSelf = true, characters = { ["X-Y"] = { nameRealm = "X-Y", heartstoneCD = 5 } }, segments = { sixties = { "X-Y" } } } },
        timers = { flower1 = 100, flower3 = 300, tuber2 = 0, rendLog = { { epoch = 1, who = "a" } }, onyLogH = {}, timerVersion = 2 },
        deletedAIDs = {},
    })
    check("data account mapped", dp.accounts["1"] and dp.accounts["1"].isSelf == true)
    check("data char mapped w/ spelling", dp.accounts["1"].characters["X-Y"].hearthstoneCD == 5)
    check("data homeless skipped", next(dp.accounts["1"].homeless) == nil)
    check("timers flower array", dp.timers.flower[1] == 100 and dp.timers.flower[3] == 300)
    check("timers tuber0 skipped", dp.timers.tuber[2] == nil)
    check("timers logs rename", dp.timers.logs.rend[1].who == "a")

    -- Idempotent overwrite-merge.
    local dst = { a = 1, nested = { x = 1, y = 2 } }
    Import._OverwriteMerge(dst, { a = 9, nested = { x = 7 } })
    Import._OverwriteMerge(dst, { a = 9, nested = { x = 7 } })
    check("merge overwrite scalar", dst.a == 9)
    check("merge keeps untouched", dst.nested.y == 2)
    check("merge overwrote nested", dst.nested.x == 7)

    if verbose and ns.Print then
        ns:Print(pass and "  import selftest: PASS" or "  import selftest: FAIL")
    end
    return pass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("import", selfTest)
end
Import._SelfTest = selfTest
