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
-- R3 item 24: DMF now HAS a buff-row home (buffGain), so it maps to our "dmf".
local ALERT_BUFF_EXPANSION = {
    rend        = { "rend" },
    ony         = { "onyH", "onyA" },
    nef         = { "nefH", "nefA" },
    zan         = { "zg" },
    battleshout = { "battleShout" },
    dmf         = { "dmf" },
}

-- Per-event default sound key (mirrors Store.ALERT_EVENT_SOUND) so an SN row with
-- a sound enabled but an unmappable token still lands on a sensible key.
local ALERT_EVENT_DEFAULT_SOUND = {
    questHandin  = "QuestListOpen",
    pullTimer    = "RaidWarning",
    npcDied      = "TellMessage",
    npcRespawned = "TellMessage",
    cdWarning    = "AuctionWindowOpen",
    cdExpired    = "ReadyCheck",
    buffGain     = "CheckboxOn",
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
    "dmf", "ony", "dmtAP", "dmtSP", "dmtStam", "songflower", "zg", "rend",
    "battleShout", "fff",   -- item 23/36: FFF is the 10th positional slot
}

-- Which summon trigger key (auto.lua SUMMON_TRIGGER_BUFFS) each aura slot maps
-- to. R3 item 23: ALL 10 world buffs are summon triggers now (dmf/battleShout/
-- fff gained triggers). Keys MUST match auto.lua Auto.SUMMON_TRIGGER_BUFFS.
local AURA_SLOT_TRIGGER = {
    [1]  = "dmf",          -- Sayge's Dark Fortune
    [2]  = "dragonslayer", -- ony  -> Rallying Cry of the Dragonslayer
    [3]  = "fengus",       -- dmtAP
    [4]  = "slipkik",      -- dmtSP
    [5]  = "moldar",       -- dmtStam
    [6]  = "songflower",   -- songflower
    [7]  = "zandalar",     -- zg
    [8]  = "warchief",     -- rend -> Warchief's Blessing
    [9]  = "battleShout",  -- Battle Shout
    [10] = "fff",          -- seasonal FFF
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
    local ao = f.auraOpts or {}
    return {
        autoGroup = {
            acceptFromRoster  = ag.acceptFromRoster,
            acceptFromGuild   = ag.acceptFromGuild,
            acceptFromFriends = ag.acceptFromFriends,
            acceptFromAnyone  = ag.acceptFromAnyone,
            -- Per-category whisper-invite send gates (item 22) — now first-class.
            sendToRoster      = ag.sendToRoster,
            sendToGuild       = ag.sendToGuild,
            sendToFriends     = ag.sendToFriends,
            sendToAnyone      = ag.sendToAnyone,
            inviteKeyword     = ag.inviteKeyword,
            whitelist         = deepCopy(ag.inviteWhitelist) or {},
            whitelistEnabled  = ag.inviteWhitelistEnabled,   -- item 35 (was dropped)
            defaultsApplied   = ag.inviteWhitelistDefaultsApplied,
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
        -- Interact Buttons feature was cut; SN's autoInteract.npcs is dropped.
        auraOpts = {
            thresholds  = mapThresholds(ao.thresholds),
            rend        = invertClassMap(ao.rendClasses),
            battleShout = invertClassMap(ao.bsClasses),
            -- Slip'kik's Savvy (dmtSP) is a Nexus-only class rule — SN has no
            -- source map, so we emit NOTHING here. _Apply's overwriteMerge only
            -- replaces keys present in this partial, so the store's dmtSP default
            -- (physical=ignored, casters=optional) survives an import untouched.
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

-- Output is EVENT-MAJOR (R3 item 14): out[eventType][ourBuffKey] =
--   { notify, chat, flash, sound = <soundKey> }, where sound is now a HUD.SOUNDS
-- KEY string ("None" = silent) mapped from SN's per-row sound token (item 14).
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
                    -- Per-row sound token -> our SoundKit key; unmapped-but-set
                    -- falls back to the event's default key; off/none -> "None".
                    local soundKey = "None"
                    if on and cell.sound ~= nil and cell.sound ~= "none" and cell.sound ~= "" then
                        soundKey = mapSound(cell.sound)
                            or ALERT_EVENT_DEFAULT_SOUND[evt] or "RaidWarning"
                    end
                    local mapped = {
                        notify = on and (cell.notify or false) or false,
                        chat   = on and (cell.chat or false) or false,
                        flash  = on and (cell.flash or false) or false,
                        sound  = soundKey,
                    }
                    out[evt] = out[evt] or {}
                    for _, ourBuff in ipairs(targets) do
                        out[evt][ourBuff] = deepCopy(mapped)
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
            -- Legacy single sizes (kept for back-compat).
            worldPinSize   = t.wmFlowerIconSize,
            minimapPinSize = t.mmFlowerIconSize,
            -- Full 5-field pin sizing (item 26). SN's per-node icon sizes map 1:1;
            -- nil leaves our store default for any field SN doesn't carry.
            worldFlowerSize   = t.wmFlowerIconSize,
            worldTuberSize    = t.wmTuberIconSize,
            worldTimerFont    = t.wmTimerFontSize,
            minimapFlowerSize = t.mmFlowerIconSize,
            minimapTuberSize  = t.mmTuberIconSize,
            -- ROUND-17 (songflower accuracy audit, fix 1) — DELIBERATELY NOT
            -- IMPORTED: SN's `flowerMinusTimerDuration` and `flowerUpDuration`.
            --
            -- These used to be copied into felwood.flowerMinusDuration /
            -- flowerUpDuration, and GetNodeState read the former as the RESPAWN
            -- LENGTH. SN's stock minus-timer is 120s, so importing a profile
            -- made every songflower count down two minutes and then report
            -- itself available — the owner's "timers don't seem accurate", with
            -- an import as the trigger. Songflower respawn is a game constant
            -- (1500s) and is no longer configurable from anywhere, so there is
            -- nothing on the SN side left to map: SN's value describes SN's
            -- display model, not the game's respawn.
            --
            -- store.lua's MigrateSongflowerDefaults heals saves already poisoned
            -- by an earlier import.
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
            channel          = mesh.mainChannel,   -- item 38: the owner's SN channel name
                                                   -- carries over so his accounts reconnect
            enabled          = mesh.mainEnabled,
            optOut           = mesh.meshOptOut,
            bondChannels     = deepCopy(mesh.bondChannels) or { "", "", "" },
            autoLeaveChannel = mesh.autoLeaveEnabled,
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
-- NovaInstanceTracker (NIT) instance-run import
-- --------------------------------------------------------------------
-- The owner's own NovaInstanceTracker SavedVariables DATA (global `NITdatabase`)
-- — interop like the ShadowNetwork importer above. The NIT ADDON SOURCE is NEVER
-- read (firewall); this mapping was derived solely from the SHAPE of the owner's
-- own SavedVariables data files.
--
-- OBSERVED NIT SHAPE (field names CONFIRMED against the owner's real SV; counts
-- below are from that file, 644 entries total):
--   NITdatabase.global[<realm>].instances = { <run>, ... }   (array, newest…oldest)
--   <run> = {
--     playerName    = "Artaeum",             -- character (no realm; realm is the key)
--     instanceName  = "Blackwing Lair",      -- display name
--     instanceID    = 469,                    -- stable numeric id  (our mapID)
--     type          = "raid",                 -- "bg" | "party" | "raid"  (304 records;
--                                             --   79 are "bg". THE primary pvp filter.
--                                             --   Older records omit it -- hence the
--                                             --   instance-id set + structural sniff.)
--     enteredTime   = 1660972435,             -- entry epoch        (our t)
--     leftTime      = 1660983242,             -- exit epoch         (our exitT)
--     enteredMoney  = 20301778, leftMoney = 137816,   -- copper wallet snapshots
--     rawMoneyCount = 41250,                  -- LOOT-ONLY copper (565 records) -- the
--                                             --   honest gold figure; preferred.
--     enteredXP     = 0,        leftXP    = 0,         -- xp snapshots (ding-poisoned)
--     xpFromChat    = 12500,                  -- chat XP accumulator (641 records) --
--                                             --   level-up safe; preferred.
--     GUID, GUIDSource,                       -- serial provenance:
--                                             --   "combatLog" | "mouseover" | "target"
--     mobCount        = 312,                  -- XP-derived kill count  (our mobXP)
--     mobCountFromKill= 318,                  -- combat-log kill count  (our mobKill)
--     enteredLevel    = 58,                   -- level walked in at
--     group           = { ... },              -- per-member level/class/guild
--     groupAverage    = 57.4,                 -- average group level incl. the player
--     zoneID, difficultyID, class, rep, ...   -- carried, unused
--   }
--   plus, on the REALM bucket alongside `instances`, a trade log whose records
--   carry { time, where, tradeWho, playerMoney, targetMoney } — `where` is the
--   instance name when the trade happened inside one. The container's key name is
--   not guessed; the log is located structurally (Import._NITTradeLog).
--
-- Each run -> our instances entry { t, name, mapID, dur, gold, xp, merged=false },
-- keyed under Name-Realm (realm whitespace stripped, matching tracker.lua's
-- selfNameRealm). Characters the store already knows are attributed to their
-- account; unknown characters go to the ORPHAN bucket, which counts against NO
-- meter. Idempotent via Instances.MergeEntryList ((nameRealm,t) dedup + the
-- existing 60-ring cap).
--
-- BATTLEGROUND / ARENA RUNS ARE SKIPPED. The source array stores them alongside
-- dungeon and raid runs, and the reader they came from excludes them from every
-- cap computation. Our live capture already excludes them (COUNTED_TYPES); the
-- importer must apply the same rule or every WSG/AB/AV the owner ever ran becomes
-- a phantom instance slot in the hour and day meters -- and can evict a real
-- dungeon entry out of the 60-entry ring.
----------------------------------------------------------------------

-- Battleground and arena instance ids (public, stable game constants). Classic
-- Era only ever produces the first three; the rest are carried so a TBC/Wrath
-- era file imports correctly too.
local PVP_INSTANCE_IDS = {
    [30] = true,   -- Alterac Valley
    [489] = true,  -- Warsong Gulch
    [529] = true,  -- Arathi Basin
    [566] = true,  -- Eye of the Storm
    [607] = true,  -- Strand of the Ancients
    [628] = true,  -- Isle of Conquest
    [559] = true,  -- Nagrand Arena
    [562] = true,  -- Blade's Edge Arena
    [572] = true,  -- Ruins of Lordaeron
    [617] = true,  -- Dalaran Sewers
    [618] = true,  -- Ring of Valor
}
Import.PVP_INSTANCE_IDS = PVP_INSTANCE_IDS

-- Run-type values, as they actually appear in the owner's file: the `type` field
-- reads "bg" | "party" | "raid". The wider word set is kept so a record written
-- by another client flavour (arena/scenario/delve) is also excluded.
local NONCOUNTED_TYPE_WORDS = {
    bg = true, pvp = true, arena = true, battleground = true,
    scenario = true, delve = true,
}
-- Values that positively confirm a slot-billing run. When one of these is
-- present the record is settled and the weaker heuristics below are SKIPPED --
-- an explicit "party" must never be second-guessed by a structural sniff.
local COUNTED_TYPE_WORDS = { party = true, raid = true }

-- `type` is the confirmed, primary signal (present on the newer records; the
-- older ones predate it, which is what the id set and the structural signature
-- below are for). The extra key names cost nothing and cover a record written by
-- a different version.
local TYPE_KEYS = { "type", "instanceType", "iType", "runType", "instType" }
local PVP_FLAG_KEYS = { "pvp", "isPvP", "isPvp", "isPVP", "pvpFlag" }

-- Classify one source run: "counted" (a dungeon/raid that bills a slot),
-- "pvp" (battleground/arena/scenario/delve -- store-but-never-count), or
-- "invalid" (unusable: no entry epoch or no instance name). Pure.
--
-- Signal order is deliberate: the explicit stored type first (ground truth),
-- then the instance-id set, then a pvp flag, and only then the structural
-- signature -- which is a sniff, and must never override a record that told us
-- plainly what it is.
function Import.ClassifyNITRun(run)
    if type(run) ~= "table" then return "invalid" end
    local t = tonumber(run.enteredTime)
    local name = run.instanceName
    if not t or t <= 0 or type(name) ~= "string" or name == "" then return "invalid" end

    -- 1. The stored run type. PRIMARY: on the records that carry it this is the
    --    whole answer, in both directions.
    for i = 1, #TYPE_KEYS do
        local v = run[TYPE_KEYS[i]]
        if type(v) == "string" then
            local w = v:lower()
            if NONCOUNTED_TYPE_WORDS[w] then return "pvp", "type" end
            if COUNTED_TYPE_WORDS[w] then return "counted", "type" end
        end
    end

    -- 2. Instance id against the public battleground/arena set -- carries the
    --    older records that predate the type field.
    local id = tonumber(run.instanceID)
    if id and PVP_INSTANCE_IDS[id] then return "pvp", "id" end

    -- 3. A pvp flag, if this record version carries one.
    for i = 1, #PVP_FLAG_KEYS do
        local v = run[PVP_FLAG_KEYS[i]]
        if v == true or v == 1 then return "pvp", "flag" end
        if type(v) == "string" and NONCOUNTED_TYPE_WORDS[v:lower()] then return "pvp", "flag" end
    end

    -- 4. The structural signature of a PvP record: difficulty id absent AND both
    --    wallet snapshots stripped. All three keys are confirmed, and a genuine
    --    dungeon record carries all three; requiring all three to be missing at
    --    once -- on a record that is otherwise well-formed (it has an instance
    --    id) -- keeps this from stealing real runs out of the meter. A record
    --    with no instance id is malformed, not PvP, and is left to the mapper to
    --    reject so it lands in the honest "unusable" bucket.
    if id and run.difficultyID == nil and run.enteredMoney == nil and run.leftMoney == nil then
        return "pvp", "stripped"
    end

    return "counted"
end

-- Build our canonical Name-Realm from a NIT playerName + its realm bucket key.
-- Realm whitespace is stripped to match tracker.lua's selfNameRealm().
function Import._NITNameRealm(playerName, realm)
    if type(playerName) ~= "string" or playerName == "" then return nil end
    local r = (type(realm) == "string" and (realm:gsub("%s+", ""))) or ""
    return playerName .. "-" .. r
end

-- The two accumulators the source record keeps ALONGSIDE its snapshots: the
-- loot-only coin total and the chat-parsed XP total. Both are preferred over the
-- snapshot deltas, precisely because the wallet delta includes repairs, vendor
-- sales, reagents and mail, and the XP delta goes NEGATIVE across a ding.
--
-- These key names are CONFIRMED against the owner's own data file: `xpFromChat`
-- appears on 641 of 644 entries, `rawMoneyCount` on 565. They are deliberately
-- the only names checked -- an earlier tolerant scan guessed at half a dozen
-- plausible alternatives, and a wrong guess that happens to hit a numeric field
-- is far worse than falling through to the snapshot fallback. Records without
-- the key still get the fallback path below.
local LOOT_COIN_KEYS = { "rawMoneyCount" }
local CHAT_XP_KEYS   = { "xpFromChat" }

local function firstNumericField(run, keys)
    for i = 1, #keys do
        local v = tonumber(run[keys[i]])
        if v and v >= 0 then return v, keys[i] end
    end
    return nil
end

----------------------------------------------------------------------
-- PER-RUN DETAIL (the fields the register's row hover needs)
--
-- CONFIRMED key names in the owner's own SavedVariables, exactly as for
-- `xpFromChat` / `rawMoneyCount` above: `mobCount` (XP-derived kills),
-- `mobCountFromKill` (combat-log kills), `enteredLevel`, `group`, `groupAverage`,
-- and — on the realm bucket's own trade log, not on the run — `time`, `where`,
-- `tradeWho`, `playerMoney`, `targetMoney`.
--
-- Every mapping is best-effort and SKIPS GRACEFULLY: a record that predates a
-- field simply imports without it, exactly as the live capture leaves the field
-- nil on a run where nothing was observed. Nothing here can fail an import.
----------------------------------------------------------------------

-- The stored group is per-member level/class/guild (behaviour spec §8.2) but the
-- concrete container shape is not something we can know without reading the
-- source, so this accepts every plausible one: an array of member tables, an
-- array of bare names, a name->table map, or a name->level map. Returns our
-- normalized { {name=, level=}, ... } or nil. Pure.
function Import._NormalizeNITGroup(g, selfName)
    if type(g) ~= "table" then return nil end
    local out = {}
    for i = 1, #g do                      -- array form first (deterministic order)
        local v = g[i]
        if type(v) == "table" then
            local nm = v.name or v.playerName or v.unitName or v[1]
            if type(nm) == "string" and nm ~= "" then
                out[#out + 1] = { name = nm, level = tonumber(v.level) or 0 }
            end
        elseif type(v) == "string" and v ~= "" then
            out[#out + 1] = { name = v, level = 0 }
        end
    end
    if #out == 0 then                     -- map form: name -> table | level
        for k, v in pairs(g) do
            if type(k) == "string" and k ~= "" then
                if type(v) == "table" then
                    out[#out + 1] = { name = k, level = tonumber(v.level) or 0 }
                elseif type(v) == "number" then
                    out[#out + 1] = { name = k, level = v }
                elseif v ~= nil then
                    out[#out + 1] = { name = k, level = 0 }
                end
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
    end
    if #out == 0 then return nil end
    if type(selfName) == "string" and selfName ~= "" then
        for i = 1, #out do
            if out[i].name == selfName then out[i].isSelf = true end
        end
    end
    return out
end

-- One source trade record -> our { t, who, gave, got, where } or nil. Money-only,
-- matching the live capture and the hover's own content. Pure.
local function normalizeNITTrade(rec)
    if type(rec) ~= "table" then return nil end
    local t = tonumber(rec.time)
    if not t or t <= 0 then return nil end
    local gave = math.floor(tonumber(rec.playerMoney) or 0)
    local got  = math.floor(tonumber(rec.targetMoney) or 0)
    if gave < 0 then gave = 0 end
    if got  < 0 then got  = 0 end
    if gave == 0 and got == 0 then return nil end
    local who = rec.tradeWho
    if type(who) ~= "string" or who == "" then who = "?" end
    local where = (type(rec.where) == "string" and rec.where ~= "" and rec.where) or nil
    return { t = t, who = who, gave = gave, got = got, where = where }
end

-- The realm bucket's trade log, found STRUCTURALLY. The behaviour spec says the
-- bucket holds one (§8.1) and the record keys are confirmed, but the container's
-- own key name is not something we are willing to guess: a wrong guess that
-- happens to hit another array is worse than finding nothing. So we look for an
-- array whose records carry BOTH `tradeWho` and `time`, which no other bucket
-- member does. Returns a time-ascending array (possibly empty). Pure.
function Import._NITTradeLog(realmData)
    local out = {}
    if type(realmData) ~= "table" then return out end
    for key, v in pairs(realmData) do
        if key ~= "instances" and type(v) == "table" and #v > 0 then
            local probe = v[1]
            if type(probe) == "table" and probe.tradeWho ~= nil and probe.time ~= nil then
                for i = 1, #v do
                    local tr = normalizeNITTrade(v[i])
                    if tr then out[#out + 1] = tr end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return tostring(a.who) < tostring(b.who)
    end)
    return out
end

-- Select the trades that happened INSIDE one run: inside its [entry, exit]
-- window, and — when the record carries a location at all — located to this
-- instance (the reference stamps the instance name on a trade taken inside one).
-- A run that never recorded an exit has no window and gets none. Pure.
function Import._TradesForRun(trades, entry)
    if type(trades) ~= "table" or #trades == 0 or type(entry) ~= "table" then return nil end
    local from = tonumber(entry.t)
    local to   = tonumber(entry.exitT)
    if not from or not to or to <= from then return nil end
    local cap = (ns.Instances and ns.Instances.MAX_TRADES) or 20
    local out
    for i = 1, #trades do
        local tr = trades[i]
        if tr.t >= from and tr.t <= to and ((not tr.where) or tr.where == entry.name) then
            out = out or {}
            if #out >= cap then break end
            out[#out + 1] = { t = tr.t, who = tr.who, gave = tr.gave, got = tr.got }
        end
    end
    return out
end

-- Map ONE source run record -> our instances entry, or nil if unusable.
-- Returns (entry, usedLootField, usedXPField) so the caller can report how often
-- the preferred accumulators were found.
function Import._MapInstanceEntry(run)
    if type(run) ~= "table" then return nil end
    if Import.ClassifyNITRun(run) ~= "counted" then return nil end
    local t = tonumber(run.enteredTime)
    local name = run.instanceName
    local left = tonumber(run.leftTime)
    local dur = (left and left > t) and (left - t) or 0

    -- Gold: keep the wallet delta (it is what the file reliably has) AND the
    -- loot-only total when the record carries one. Mirrors the live capture,
    -- which now populates both fields.
    local gold = 0
    local em, lm = tonumber(run.enteredMoney), tonumber(run.leftMoney)
    if em and lm then gold = lm - em end
    local goldLoot, lootKey = firstNumericField(run, LOOT_COIN_KEYS)

    -- XP: prefer the chat accumulator. The snapshot delta is level-up-poisoned,
    -- so when it is all we have it is CLAMPED at zero -- a run containing a ding
    -- imports as 0 rather than as a large negative number. The true figure is
    -- not recoverable from two snapshots that straddle a reset.
    local xp, xpKey = firstNumericField(run, CHAT_XP_KEYS)
    if not xp then
        local ex, lx = tonumber(run.enteredXP), tonumber(run.leftXP)
        if ex and lx then xp = math.max(0, lx - ex) else xp = 0 end
    end

    local entry = {
        t = t, name = name, mapID = tonumber(run.instanceID),
        dur = dur, gold = gold, xp = xp, merged = false,
        goldLoot = goldLoot or 0,
        -- Provenance. The register's display grouping reads this: an imported
        -- ledger contains NO merged runs (spec §8.3 — a merged record is deleted
        -- at the source and its totals folded into the survivor), so every row
        -- here is already a distinct instance entry and must never be folded
        -- together by the serial-less legacy heuristic.
        src = "nit",
    }
    -- Historical exit epoch, so the register can recompute a duration on demand
    -- exactly as it does for live runs. Zero means the run was never closed.
    if left and left > t then entry.exitT = left end

    -- ── ADDITIVE per-run detail (all optional; absent keys simply stay nil) ──
    local detail = {}
    -- Mob counts: the same two-counter model the live capture keeps — the
    -- XP-derived count and the kill-derived one that carries boosted grey runs.
    local mobXP = tonumber(run.mobCount)
    if mobXP and mobXP >= 0 then entry.mobXP = math.floor(mobXP); detail.mob = true end
    local mobKill = tonumber(run.mobCountFromKill)
    if mobKill and mobKill >= 0 then entry.mobKill = math.floor(mobKill); detail.mob = true end
    -- Level the character entered at.
    local lvl = tonumber(run.enteredLevel)
    if lvl and lvl > 0 then entry.enteredLevel = math.floor(lvl); detail.level = true end
    -- Group snapshot + average, encoded into our compact stored form.
    local members = Import._NormalizeNITGroup(run.group, run.playerName)
    if members and ns.Instances and ns.Instances.EncodeGroup then
        local gstr = ns.Instances.EncodeGroup(members)
        if gstr then
            entry.group = gstr
            entry.groupAvg = tonumber(run.groupAverage)
                             or (ns.Instances.AverageGroupLevel and ns.Instances.AverageGroupLevel(members))
            if entry.groupAvg then
                entry.groupAvg = math.floor(entry.groupAvg * 10 + 0.5) / 10
            end
            detail.group = true
        end
    end
    return entry, (lootKey ~= nil), (xpKey ~= nil), detail
end

-- PURE core: NITdatabase -> our per-account/per-character instances partial + counts.
--   ownerIndex = { [nameRealm] = aid }  (accounts the store already knows a char under)
--   selfAID    = local account id (used only for the summary line)
-- Returns (mapped, counts):
--   mapped = { [aid] = { [nameRealm] = { entries = { entry, ... } } } }
--   counts = { runs, skipped, pvpSkipped, pvpBy, chars, attributed, orphaned,
--              lootFieldHits, xpFieldHits, perAccount = {[aid]=n} }
--
-- ATTRIBUTION: a character the store already knows goes to ITS account. A
-- character nobody claims goes to the ORPHAN bucket, NOT to the local account.
-- Dumping unattributable alts onto the local account's meter inflates exactly
-- the number that must never be wrong; the orphan bucket keeps the runs visible
-- in the register while counting against nothing.
function Import._MapNITData(nitDB, ownerIndex, selfAID)
    ownerIndex = ownerIndex or {}
    selfAID = selfAID or ""
    local orphanAID = (ns.Instances and ns.Instances.ORPHAN_AID) or "orphan"
    local mapped, charSet = {}, {}
    local counts = {
        runs = 0, skipped = 0, pvpSkipped = 0, chars = 0,
        attributed = 0, orphaned = 0, lootFieldHits = 0, xpFieldHits = 0,
        pvpBy = { id = 0, type = 0, flag = 0, stripped = 0 },
        detail = { level = 0, group = 0, mob = 0, trades = 0, tradeRecords = 0 },
        perAccount = {}, orphanAID = orphanAID,
    }
    local g = (type(nitDB) == "table") and nitDB.global
    if type(g) ~= "table" then return mapped, counts end
    for realm, realmData in pairs(g) do
        local runs = (type(realmData) == "table") and realmData.instances
        -- The realm bucket's trade log, located structurally (see _NITTradeLog).
        local tradeLog = Import._NITTradeLog(realmData)
        counts.detail.tradeRecords = counts.detail.tradeRecords + #tradeLog
        if type(runs) == "table" then
            for i = 1, #runs do
                local run = runs[i]
                local kind, why = Import.ClassifyNITRun(run)
                if kind == "pvp" then
                    counts.pvpSkipped = counts.pvpSkipped + 1
                    counts.pvpBy[why] = (counts.pvpBy[why] or 0) + 1
                else
                    local entry, lootHit, xpHit, detail = Import._MapInstanceEntry(run)
                    local nameRealm = entry and Import._NITNameRealm(run.playerName, realm)
                    if entry and nameRealm then
                        -- Trades taken while inside THIS run.
                        local trades = Import._TradesForRun(tradeLog, entry)
                        if trades then
                            entry.trades = trades
                            counts.detail.trades = counts.detail.trades + 1
                        end
                        if detail then
                            for k in pairs(detail) do
                                counts.detail[k] = (counts.detail[k] or 0) + 1
                            end
                        end
                        local known = ownerIndex[nameRealm]
                        local aid = known or orphanAID
                        local acct = mapped[aid]; if not acct then acct = {}; mapped[aid] = acct end
                        local crec = acct[nameRealm]; if not crec then crec = { entries = {} }; acct[nameRealm] = crec end
                        crec.entries[#crec.entries + 1] = entry
                        counts.runs = counts.runs + 1
                        counts.perAccount[aid] = (counts.perAccount[aid] or 0) + 1
                        if lootHit then counts.lootFieldHits = counts.lootFieldHits + 1 end
                        if xpHit then counts.xpFieldHits = counts.xpFieldHits + 1 end
                        if known then counts.attributed = counts.attributed + 1
                        else counts.orphaned = counts.orphaned + 1 end
                        if not charSet[nameRealm] then charSet[nameRealm] = true; counts.chars = counts.chars + 1 end
                    elseif run ~= nil then
                        counts.skipped = counts.skipped + 1
                    end
                end
            end
        end
    end
    return mapped, counts
end

-- Reverse index of every character the store already knows -> its account id
-- (the characters bucket wins over homeless). Used to attribute NIT runs.
local function buildOwnerIndex()
    local idx = {}
    local Store = ns.Store
    local data = Store and Store.GetData and Store.GetData()
    local accounts = data and data.accounts
    if type(accounts) == "table" then
        for aid, bucket in pairs(accounts) do
            if type(bucket) == "table" then
                if type(bucket.characters) == "table" then
                    for nameRealm in pairs(bucket.characters) do idx[nameRealm] = aid end
                end
                if type(bucket.homeless) == "table" then
                    for nameRealm in pairs(bucket.homeless) do if idx[nameRealm] == nil then idx[nameRealm] = aid end end
                end
            end
        end
    end
    return idx
end

-- Merge the mapped NIT partial into the live Store.data.instances, idempotently
-- (Instances.MergeEntryList dedups by t and caps to the 60-ring). Returns added.
function Import._ApplyInstances(mapped)
    local Store = ns.Store
    if not (Store and Store.GetData) then return 0 end
    local data = Store.GetData()
    if not data then return 0 end
    if type(data.instances) ~= "table" then data.instances = {} end
    local Instances = ns.Instances
    local added = 0
    for aid, chars in pairs(mapped) do
        local dest = data.instances[aid]
        if type(dest) ~= "table" then dest = {}; data.instances[aid] = dest end
        for nameRealm, crec in pairs(chars) do
            local drec = dest[nameRealm]
            if type(drec) ~= "table" then drec = { entries = {} }; dest[nameRealm] = drec end
            if Instances and Instances.MergeEntryList then
                local mergedList, n = Instances.MergeEntryList(drec.entries, crec.entries)
                drec.entries = mergedList
                added = added + n
            else
                for _, e in ipairs(crec.entries) do drec.entries[#drec.entries + 1] = e end
                added = added + #crec.entries
            end
        end
    end
    if added > 0 and ns.Fire then
        ns:Fire("INSTANCES_CHANGED")
        ns:Fire("STORE_REFRESHED")
    end
    return added
end

-- Ordered summary lines for the NIT counts table (mirrors summaryLines' style).
local function instanceSummaryLines(counts, selfAID)
    local by = counts.pvpBy or {}
    local orphanAID = counts.orphanAID or "orphan"
    local lines = {
        string.format("instances: runs=%d mapped, characters=%d, unusable=%d",
            counts.runs or 0, counts.chars or 0, counts.skipped or 0),
        string.format("pvp filter: %d battleground/arena runs skipped (by id=%d, type=%d, flag=%d, stripped-fields=%d)",
            counts.pvpSkipped or 0, by.id or 0, by.type or 0, by.flag or 0, by.stripped or 0),
        string.format("attribution: %d to known accounts, %d to the ORPHAN bucket \"%s\" (counts against NO meter)",
            counts.attributed or 0, counts.orphaned or 0, orphanAID),
        string.format("field preference: %d runs had a loot-coin total, %d had a chat-XP total (0 means those keys are absent -- snapshot fallback used)",
            counts.lootFieldHits or 0, counts.xpFieldHits or 0),
        string.format("run detail: %d with an entry level, %d with a group snapshot, %d with mob counts, %d with trades (from %d trade records)",
            (counts.detail and counts.detail.level) or 0,
            (counts.detail and counts.detail.group) or 0,
            (counts.detail and counts.detail.mob) or 0,
            (counts.detail and counts.detail.trades) or 0,
            (counts.detail and counts.detail.tradeRecords) or 0),
    }
    if (counts.orphaned or 0) > 0 then
        lines[#lines + 1] = "NOTE: populate the account index for those characters and re-run to attribute them."
    end
    local aids = {}
    for aid in pairs(counts.perAccount or {}) do aids[#aids + 1] = aid end
    table.sort(aids)
    for _, aid in ipairs(aids) do
        lines[#lines + 1] = string.format("  %s: %d runs",
            (aid == orphanAID and "ORPHAN") or ("acct " .. ((aid ~= "" and aid) or "(unset)")),
            counts.perAccount[aid])
    end
    return lines
end
Import._InstanceSummaryLines = instanceSummaryLines

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

-- The NovaInstanceTracker SavedVariables global (or nil). Behind _G indexing so
-- the firewall grep sees the name only as a data string (mirrors snGlobals).
local function nitGlobal()
    local G = _G or getfenv(0)
    return G["NITdatabase"]
end

-- True when the NovaInstanceTracker SavedVariable is loaded in memory.
function Import.InstancesAvailable()
    return type(nitGlobal()) == "table"
end

-- Import NovaInstanceTracker instance runs into Store.data.instances. `dryRun`
-- truthy => compute + print counts, apply nothing. Idempotent when applied.
-- Returns (ok, counts).
function Import.RunInstances(dryRun)
    local nitDB = nitGlobal()
    if type(nitDB) ~= "table" then
        if ns.Print then ns:Print("import instances: no NovaInstanceTracker SavedVariables found (is it still installed + enabled?).") end
        return false, nil
    end
    local selfAID = (ns.GetAccountID and ns:GetAccountID()) or ""
    local ownerIndex = buildOwnerIndex()
    local mapped, counts = Import._MapNITData(nitDB, ownerIndex, selfAID)

    if ns.Print then
        ns:Print(dryRun and "import instances DRY-RUN (nothing applied):" or "import instances applied:")
        local lines = instanceSummaryLines(counts, selfAID)
        for i = 1, #lines do ns:Print("  " .. lines[i]) end
    end

    if not dryRun then
        local added = Import._ApplyInstances(mapped)
        if ns.Print then ns:Print(string.format("  merged %d new entries into the store (idempotent — re-import adds 0).", added)) end
    end
    return true, counts
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

    -- Data: overwrite the account graph, manualLocations, tombstones.
    data.accounts = dataPartial.accounts
    overwriteMerge(data.manualLocations, dataPartial.manualLocations)
    overwriteMerge(data.deletedAIDs, dataPartial.deletedAIDs)

    -- ROUND-17 (songflower accuracy audit, fix 7) — TIMERS MERGE, NOT REPLACE.
    --
    -- This used to be `data.timers = dataPartial.timers`, a wholesale swap. An
    -- import is not a point-in-time restore of a dead profile: SN's saved
    -- variables were written when the user last logged out of SN, so its node
    -- epochs are routinely HOURS stale, while ours may have been set seconds ago
    -- by a live pick, an NWB payload or a mesh peer. Replacing the table threw
    -- every one of those away and handed the user a screen of expired flowers.
    --
    -- Node epochs now go through Timers.MarkNode, which already owns the
    -- newest-wins rule and the overwrite guards — so a fresher local epoch
    -- survives an import of an older one, and an import can still fill in nodes
    -- we have never seen. Everything else in the timers block keeps the previous
    -- replace semantics.
    local incoming = dataPartial.timers or {}
    local nodeKinds = { flower = true, tuber = true, dragon = true }
    local Timers = ns.Timers
    data.timers = data.timers or {}

    for key, v in pairs(incoming) do
        if not nodeKinds[key] then data.timers[key] = v end
    end

    for kind in pairs(nodeKinds) do
        local src = incoming[kind]
        if type(src) == "table" then
            -- MarkNode reads and writes through the store, so the destination
            -- table is guaranteed to exist by the time we call it.
            data.timers[kind] = data.timers[kind] or {}
            for i, epoch in pairs(src) do
                local idx, z = tonumber(i), tonumber(epoch)
                if idx and z and z > 0 then
                    if Timers and Timers.MarkNode then
                        -- "sn" trust + the standard network guards: an imported
                        -- epoch is second-hand and must not stomp a local pick.
                        Timers.MarkNode(kind, idx, z, "sn",
                            Timers._netNodeOpts and Timers._netNodeOpts() or nil)
                    elseif z > (data.timers[kind][idx] or 0) then
                        -- Engine absent (bare VM): fall back to newest-wins.
                        data.timers[kind][idx] = z
                    end
                end
            end
        end
    end

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
        -- Announce a bulk data refresh so live views repaint. This is a
        -- DEDICATED, args-free signal — NOT STATE_CHANGED, whose (nameRealm,
        -- record) contract the mesh relies on to push our own live character.
        -- The mesh ignores STORE_REFRESHED (imported other-account data must
        -- never be broadcast as ours); the dashboard/HUD subscribe to repaint.
        if ns.Fire then ns:Fire("STORE_REFRESHED") end
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
        local first, remainder = rest:match("^(%S*)%s*(.-)%s*$")
        first, remainder = first or "", remainder or ""

        -- `/nexus import instances [dry]` — NovaInstanceTracker instance runs.
        if first == "instances" then
            if not Import.InstancesAvailable() then
                ns:Print("import: NovaInstanceTracker is not loaded — nothing to import.")
                return
            end
            local dry = (remainder == "dry" or remainder == "dryrun" or remainder == "preview")
            Import.RunInstances(dry)
            return
        end

        -- `/nexus import [dry]` — ShadowNetwork settings + data (default).
        if not Import.IsAvailable() then
            ns:Print("import: ShadowNetwork is not loaded — nothing to import.")
            return
        end
        local dry = (rest == "dry" or rest == "dryrun" or rest == "preview")
        Import.Run(dry)
    end, "import from ShadowNetwork; 'import instances' pulls NovaInstanceTracker runs ('dry' previews either)")
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

    -- Alert transpose (EVENT-MAJOR) + buff expansion + sound token->key + gate.
    local am = Import._MapAlertMatrix({
        pullTimer = {
            ony  = { enabled = true, notify = true, chat = false, flash = true, sound = "clear_announce" },
            zan  = { enabled = false, notify = true, chat = true, flash = true, sound = "bell" },
        },
        buffGain = {
            dmf  = { enabled = true, notify = true, sound = "bell" },  -- item 24: dmf now maps
        },
    })
    check("alert event-major ony->onyH", am.pullTimer and am.pullTimer.onyH and am.pullTimer.onyH.notify == true)
    check("alert ony->onyA duplicated", am.pullTimer.onyA and am.pullTimer.onyA.flash == true)
    check("alert sound token->key", am.pullTimer.onyH.sound == "RaidWarning")
    check("alert zan->zg disabled gate", am.pullTimer.zg and am.pullTimer.zg.notify == false and am.pullTimer.zg.sound == "None")
    check("alert dmf maps to buffGain.dmf", am.buffGain and am.buffGain.dmf and am.buffGain.dmf.sound == "AuctionWindowOpen")

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

    -- Faction zanza priority + summonWindow rename + positional->keyed
    -- thresholds/triggers (canonical aura order). (Interact feature was cut.)
    local fac = Import._MapFaction({
        autoQuest = { zanzaEnabled = true, zanzaPicks = { spirit = true } },
        -- buffTriggers slots: 1=dmf 2=ony 3=dmtAP -> dmf=true, dragonslayer=false,
        -- fengus=true (item 23: all 10 slots are triggers now).
        autoSummon = { summonWindow = 19, buffTriggers = { true, false, true } },
        autoGroup = {
            inviteWhitelist = { ["A-B"] = true }, inviteWhitelistDefaultsApplied = true,
            inviteWhitelistEnabled = false,
            sendToRoster = true, sendToGuild = true, sendToFriends = false, sendToAnyone = true,
        },
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
    check("faction buffTriggers dmf mapped (item 23)", fac.autoSummon.triggers.dmf == true)
    check("faction thresholds->keys (slot1->dmf)", fac.auraOpts.thresholds.dmf and fac.auraOpts.thresholds.dmf.normal == 100)
    check("faction thresholds->keys (slot2->ony)", fac.auraOpts.thresholds.ony and fac.auraOpts.thresholds.ony.minimum == 90)
    check("faction thresholds->keys (slot8->rend)", fac.auraOpts.thresholds.rend and fac.auraOpts.thresholds.rend.normal == 800)
    check("faction thresholds unset slot nil", fac.auraOpts.thresholds.zg == nil)
    -- Slip'kik's Savvy (dmtSP) is Nexus-only: the importer must emit no map, so
    -- overwriteMerge leaves the store's dmtSP default intact after an import.
    check("faction dmtSP not imported (default survives)", fac.auraOpts.dmtSP == nil)
    check("faction zanza priority", fac.autoQuest.zanza.priority.spirit == true)
    check("faction interact dropped", fac.autoInteract == nil)
    check("faction whitelist", fac.autoGroup.whitelist["A-B"] == true)
    -- Item 22 per-category send gates + item 35 whitelist enable.
    check("faction sendToGuild mapped", fac.autoGroup.sendToGuild == true)
    check("faction sendToFriends mapped", fac.autoGroup.sendToFriends == false)
    check("faction sendToAnyone mapped", fac.autoGroup.sendToAnyone == true)
    check("faction whitelistEnabled mapped", fac.autoGroup.whitelistEnabled == false)

    -- Settings-level: mesh channel (item 38) + 5-field pin sizing (item 26).
    local st = Import._MapSettings({
        mesh = { meshToken = "abc123", mainChannel = "MyGuildBuffChannel", mainEnabled = true },
        timerSettings = {
            wmFlowerIconSize = 18, wmTuberIconSize = 16, wmTimerFontSize = 11,
            mmFlowerIconSize = 13, mmTuberIconSize = 12,
        },
    })
    check("mesh channel imported (item 38)", st.mesh.channel == "MyGuildBuffChannel")
    check("pin worldFlowerSize", st.timerSettings.felwood.worldFlowerSize == 18)
    check("pin worldTuberSize", st.timerSettings.felwood.worldTuberSize == 16)
    check("pin worldTimerFont", st.timerSettings.felwood.worldTimerFont == 11)
    check("pin minimapTuberSize", st.timerSettings.felwood.minimapTuberSize == 12)

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

    ------------------------------------------------------------------
    -- NIT instance-run import: shape mapping, attribution, idempotency.
    ------------------------------------------------------------------
    -- Fixture built on the REAL field names from the owner's SavedVariables:
    -- `type` ("bg"/"party"/"raid"), `xpFromChat`, `rawMoneyCount`, alongside the
    -- older records that carry none of them.
    local ORPHAN = (ns.Instances and ns.Instances.ORPHAN_AID) or "orphan"
    local nitFixture = {
        global = {
            ["Jom Gabbar"] = { instances = {
                -- Newer records: `type` present and authoritative.
                { playerName = "Artaeum", instanceName = "Blackwing Lair", instanceID = 469,
                  type = "raid", difficultyID = 1, enteredTime = 1000, leftTime = 4600,
                  enteredMoney = 500, leftMoney = 1500,
                  enteredXP = 0, leftXP = 0, mobCount = 900, mobCountFromKill = 912,
                  enteredLevel = 60, groupAverage = 59.5,
                  group = { Artaeum = { level = 60, class = "MAGE" },
                            Bramble = { level = 59, class = "ROGUE" } },
                  rawMoneyCount = 41250, xpFromChat = 0,
                  GUID = "Creature-0-3151-469-4821-11583-000082EA3F", GUIDSource = "mouseover" },
                { playerName = "Artaeum", instanceName = "Molten Core", instanceID = 409,
                  type = "raid", difficultyID = 1, enteredTime = 5000, leftTime = 8600,
                  enteredMoney = 2000, leftMoney = 1000,   -- repaired in MC: wallet went DOWN
                  rawMoneyCount = 63000, GUIDSource = "target" },
                -- Battlegrounds, flagged by `type` -- must NEVER count.
                { playerName = "Artaeum", instanceName = "Warsong Gulch", instanceID = 489,
                  type = "bg", enteredTime = 6000, leftTime = 7000 },
                { playerName = "Artaeum", instanceName = "Alterac Valley", instanceID = 30,
                  type = "bg", enteredTime = 6100, leftTime = 9100 },
                -- An OLDER bg record with no `type` at all: the id set must catch it.
                { playerName = "Artaeum", instanceName = "Arathi Basin", instanceID = 529,
                  enteredTime = 6200, leftTime = 7200 },
                { playerName = "", instanceName = "Bad", enteredTime = 9000 },  -- no player -> unusable
                { instanceName = "NoTime", enteredTime = 0 },                   -- no entry time -> unusable
            },
            -- The realm bucket's TRADE LOG, alongside `instances`. The container
            -- key is deliberately not the one the mapper looks for by name -- it
            -- is found structurally, by the confirmed record keys.
            tradeLog = {
                { time = 2000, where = "Blackwing Lair", tradeWho = "Bramble",
                  playerMoney = 500000, targetMoney = 0 },
                { time = 3000, where = "Blackwing Lair", tradeWho = "Cera",
                  playerMoney = 0, targetMoney = 120000 },
                { time = 3500, where = "Orgrimmar", tradeWho = "Dorn",     -- outside
                  playerMoney = 700000, targetMoney = 0 },
                { time = 99000, where = "Blackwing Lair", tradeWho = "Late", -- after the run
                  playerMoney = 100, targetMoney = 0 },
                { time = 2500, where = "Blackwing Lair", tradeWho = "Items", -- item-only
                  playerMoney = 0, targetMoney = 0 },
            },
            -- A same-shaped array that is NOT a trade log must be ignored.
            somethingElse = { { time = 2100, note = "not a trade" } },
        },
            ["Whitemane"] = { instances = {
                { playerName = "Stranger", instanceName = "Scholomance", instanceID = 289,
                  type = "party", difficultyID = 1, enteredTime = 2000, leftTime = 3000,
                  enteredMoney = 10, leftMoney = 60,
                  enteredXP = 900, leftXP = 100,   -- LEVELLED UP mid-run: delta is negative
                  xpFromChat = 14200, rawMoneyCount = 8300 },
            } },
        },
    }
    -- Artaeum-JomGabbar is a KNOWN char on account "2"; Stranger-Whitemane is unknown.
    local mapped, counts = Import._MapNITData(nitFixture, { ["Artaeum-JomGabbar"] = "2" }, "1")
    check("nit runs mapped (2 JG + 1 WM)", counts.runs == 3)
    check("nit skipped invalid runs", counts.skipped == 2)
    check("nit distinct characters", counts.chars == 2)
    check("nit attributed to known acct", counts.attributed == 2)
    check("nit orphaned count", counts.orphaned == 1)
    check("nit per-account: acct 2 = 2 runs", counts.perAccount["2"] == 2)

    -- A5.1 -- the top-severity importer defect: battlegrounds are phantom slots.
    check("nit skips all 3 battlegrounds", counts.pvpSkipped == 3)
    check("nit two bgs skipped by the confirmed `type` field", counts.pvpBy.type == 2)
    check("nit the type-less legacy bg skipped by the id set", counts.pvpBy.id == 1)
    check("nit no bg run reached the ledger", counts.perAccount["2"] == 2)

    -- The confirmed accumulators were found on the records that carry them.
    check("nit found rawMoneyCount on 3 runs", counts.lootFieldHits == 3)
    check("nit found xpFromChat on 2 runs", counts.xpFieldHits == 2)

    -- A5.4 -- orphans must NOT pile onto the local account's meter.
    check("nit orphan does NOT land on local acct 1", mapped["1"] == nil)
    check("nit orphan lands in the orphan bucket", mapped[ORPHAN] ~= nil)
    check("nit orphan per-account is the orphan bucket", counts.perAccount[ORPHAN] == 1)

    local jg = mapped["2"] and mapped["2"]["Artaeum-JomGabbar"]
    check("nit known char under acct 2", jg and #jg.entries == 2)
    local wm = mapped[ORPHAN] and mapped[ORPHAN]["Stranger-Whitemane"]
    check("nit orphan char under the orphan bucket", wm and #wm.entries == 1)

    local bwl = jg and jg.entries[1]
    check("nit t<-enteredTime", bwl and bwl.t == 1000)
    check("nit name<-instanceName", bwl and bwl.name == "Blackwing Lair")
    check("nit mapID<-instanceID", bwl and bwl.mapID == 469)
    check("nit dur = left-entered", bwl and bwl.dur == 3600)
    check("nit exitT<-leftTime", bwl and bwl.exitT == 4600)
    check("nit gold = left-entered (copper)", bwl and bwl.gold == 1000)
    check("nit goldLoot <- rawMoneyCount", bwl and bwl.goldLoot == 41250)
    check("nit merged=false", bwl and bwl.merged == false)
    local mc = jg and jg.entries[2]
    check("nit negative wallet gold survives (repaired in-run)", mc and mc.gold == -1000)
    check("nit loot total is positive on that same run", mc and mc.goldLoot == 63000)

    ------------------------------------------------------------------
    -- PER-RUN DETAIL: the fields the row hover needs, from the confirmed keys.
    ------------------------------------------------------------------
    check("nit mobXP <- mobCount", bwl and bwl.mobXP == 900)
    check("nit mobKill <- mobCountFromKill", bwl and bwl.mobKill == 912)
    check("nit enteredLevel imported", bwl and bwl.enteredLevel == 60)
    check("nit group encoded, self marked, name-sorted",
        bwl and bwl.group == "*Artaeum:60|Bramble:59")
    check("nit groupAvg <- groupAverage", bwl and bwl.groupAvg == 59.5)
    check("nit stamps import provenance", bwl and bwl.src == "nit")
    -- Trades: inside the window AND located to this instance.
    check("nit trades attached to the run they happened in", bwl and bwl.trades and #bwl.trades == 2)
    check("nit trade partner + coin given", bwl and bwl.trades[1].who == "Bramble"
        and bwl.trades[1].gave == 500000)
    check("nit trade coin received", bwl and bwl.trades[2].who == "Cera" and bwl.trades[2].got == 120000)
    check("nit a trade taken OUTSIDE is not attached", mc == nil or mc.trades == nil)
    check("nit trade-log records counted (item-only dropped)",
        counts.detail and counts.detail.tradeRecords == 4)
    check("nit runs-with-trades counted", counts.detail and counts.detail.trades == 1)
    check("nit detail counters", counts.detail and counts.detail.level == 1
        and counts.detail.group == 1 and counts.detail.mob == 1)
    -- A record that predates every one of these keys imports cleanly without them.
    local bare = Import._MapInstanceEntry({
        instanceName = "Uldaman", instanceID = 70, type = "party", difficultyID = 1,
        enteredTime = 10, leftTime = 20, enteredMoney = 0, leftMoney = 0 })
    check("nit record without detail keys imports with none of them",
        bare and bare.enteredLevel == nil and bare.group == nil and bare.trades == nil)
    check("nit that record still maps its core fields", bare and bare.t == 10 and bare.dur == 10)

    -- Group normalizer: every plausible container shape.
    local arr = Import._NormalizeNITGroup({ { name = "Ann", level = 60 }, { name = "Bob", level = 58 } }, "Ann")
    check("group array-of-tables", arr and #arr == 2 and arr[1].name == "Ann" and arr[1].isSelf == true)
    local names = Import._NormalizeNITGroup({ "Ann", "Bob" })
    check("group array-of-names", names and #names == 2 and names[2].level == 0)
    local lvlMap = Import._NormalizeNITGroup({ Ann = 60, Bob = 58 })
    check("group name->level map", lvlMap and #lvlMap == 2 and lvlMap[1].name == "Ann" and lvlMap[1].level == 60)
    check("group nil/garbage -> nil", Import._NormalizeNITGroup(nil) == nil
        and Import._NormalizeNITGroup({}) == nil and Import._NormalizeNITGroup("x") == nil)

    -- Trade-log location + windowing, in isolation.
    local log = Import._NITTradeLog({ instances = {}, whatever = {
        { time = 50, tradeWho = "A", playerMoney = 10, targetMoney = 0 },
        { time = 10, tradeWho = "B", playerMoney = 0, targetMoney = 20 },
    } })
    check("trade log found structurally and time-sorted", #log == 2 and log[1].who == "B")
    check("trade log ignores a non-trade array",
        #Import._NITTradeLog({ notes = { { time = 1, text = "x" } } }) == 0)
    local win = Import._TradesForRun(log, { t = 5, exitT = 20, name = "Anywhere" })
    check("trades windowed to the run", win and #win == 1 and win[1].who == "B")
    check("an unclosed run gets no trades",
        Import._TradesForRun(log, { t = 5, name = "Anywhere" }) == nil)

    -- A5.3 -- the XP snapshot delta goes negative across a ding (900 -> 100).
    -- xpFromChat is the level-up-safe figure and must win outright.
    check("nit xp <- xpFromChat, not the negative delta", wm and wm.entries[1].xp == 14200)
    check("nit goldLoot <- rawMoneyCount on the orphan run", wm and wm.entries[1].goldLoot == 8300)

    -- A record with NO xpFromChat and a ding-poisoned delta still clamps at 0.
    local legacyDing = Import._MapInstanceEntry({
        instanceName = "Maraudon", instanceID = 349, type = "party", difficultyID = 1,
        enteredTime = 100, leftTime = 700, enteredMoney = 0, leftMoney = 0,
        enteredXP = 40000, leftXP = 1200,
    })
    check("nit legacy record without xpFromChat clamps a negative delta", legacyDing and legacyDing.xp == 0)
    check("nit legacy record without rawMoneyCount gets goldLoot 0", legacyDing and legacyDing.goldLoot == 0)

    -- The confirmed accumulators beat the snapshots even when the snapshots exist.
    local pref = Import._MapInstanceEntry({
        instanceName = "Stratholme", instanceID = 329, type = "party", difficultyID = 1,
        enteredTime = 100, leftTime = 700, enteredMoney = 0, leftMoney = -5000,
        enteredXP = 500, leftXP = 100, xpFromChat = 7400, rawMoneyCount = 31234,
    })
    check("nit prefers rawMoneyCount", pref and pref.goldLoot == 31234)
    check("nit prefers xpFromChat", pref and pref.xp == 7400)
    check("nit still keeps the wallet delta alongside", pref and pref.gold == -5000)

    -- The confirmed `type` values, in both directions.
    check("nit type=bg -> pvp", Import.ClassifyNITRun({
        instanceName = "Warsong Gulch", instanceID = 489, enteredTime = 1, type = "bg" }) == "pvp")
    check("nit type=party -> counted", Import.ClassifyNITRun({
        instanceName = "Deadmines", instanceID = 36, enteredTime = 1, type = "party" }) == "counted")
    check("nit type=raid -> counted", Import.ClassifyNITRun({
        instanceName = "Molten Core", instanceID = 409, enteredTime = 1, type = "raid" }) == "counted")
    -- An explicit type must OUTRANK the structural sniff: this record has no
    -- difficultyID and no wallet snapshots, which alone would read as PvP.
    check("nit explicit type=party beats the structural sniff", Import.ClassifyNITRun({
        instanceName = "Deadmines", instanceID = 36, enteredTime = 1, type = "party" }) == "counted")
    local _, why = Import.ClassifyNITRun({
        instanceName = "Deadmines", instanceID = 36, enteredTime = 1, type = "party" })
    check("nit reports `type` as the deciding signal", why == "type")

    -- The tolerant type/flag signals, independent of the id list.
    check("nit classifies a type word", Import.ClassifyNITRun({
        instanceName = "Somewhere", instanceID = 9999, enteredTime = 1,
        difficultyID = 1, enteredMoney = 0, leftMoney = 0, type = "arena" }) == "pvp")
    check("nit classifies a pvp flag", Import.ClassifyNITRun({
        instanceName = "Somewhere", instanceID = 9999, enteredTime = 1,
        difficultyID = 1, enteredMoney = 0, leftMoney = 0, pvp = true }) == "pvp")
    check("nit classifies the stripped-field signature", Import.ClassifyNITRun({
        instanceName = "Somewhere", instanceID = 9999, enteredTime = 1 }) == "pvp")
    check("nit does NOT call an id-less record pvp", Import.ClassifyNITRun({
        instanceName = "Somewhere", enteredTime = 1 }) == "counted")
    check("nit keeps a normal dungeon", Import.ClassifyNITRun({
        instanceName = "Deadmines", instanceID = 36, enteredTime = 1,
        difficultyID = 1, enteredMoney = 0, leftMoney = 0 }) == "counted")
    check("nit rejects an unusable record", Import.ClassifyNITRun({ instanceName = "X" }) == "invalid")
    -- Zul'Gurub and AQ20 genuinely DO bill a slot -- they must not be filtered.
    check("nit keeps Zul'Gurub (309)", Import.ClassifyNITRun({
        instanceName = "Zul'Gurub", instanceID = 309, enteredTime = 1,
        difficultyID = 1, enteredMoney = 0, leftMoney = 0 }) == "counted")

    check("nit nameRealm strips realm spaces", Import._NITNameRealm("Artaeum", "Jom Gabbar") == "Artaeum-JomGabbar")
    check("nit nameRealm nil on empty player", Import._NITNameRealm("", "Jom Gabbar") == nil)

    -- Orphaned runs must not reach any cap meter once applied.
    if ns.Instances and ns.Instances.WindowCounts then
        local Store = ns.Store
        local savedData, savedGet = Store.data, ns.GetAccountID
        ns.GetAccountID = function() return "1" end
        Store.data = { instances = {} }
        Import._ApplyInstances(mapped)
        local orphanCounts = ns.Instances.WindowCounts(ORPHAN, 2500)
        check("applied orphan runs count against no meter",
            orphanCounts.hour == 0 and orphanCounts.day == 0)
        local view = ns.Instances.AllAccounts(2500)
        check("orphan bucket absent from the cross-account view", view.accounts[ORPHAN] == nil)
        -- At t=2500 acct 2 has exactly one in-window run (t=1000; t=5000 is in the
        -- future and rejected) and the orphan has one (t=2000). The total must see
        -- only acct 2's -- had the orphan landed on a meter it would read 2.
        check("acct 2 has its one in-window run", view.accounts["2"].day == 1)
        check("orphan runs excluded from the aggregate total", view.total.day == 1)
        Store.data, ns.GetAccountID = savedData, savedGet
    end

    -- Idempotency via the apply path's dedup+cap (Instances.MergeEntryList): a
    -- re-import of the same mapped list adds ZERO on the second pass.
    if ns.Instances and ns.Instances.MergeEntryList then
        local listA, addedA = ns.Instances.MergeEntryList({}, jg.entries)
        check("nit merge first pass adds all", addedA == 2)
        local _, addedB = ns.Instances.MergeEntryList(listA, jg.entries)
        check("nit merge re-import idempotent (adds 0)", addedB == 0)
    end

    ------------------------------------------------------------------
    -- ROUND-17 songflower accuracy audit: fixes 1 and 7 on the apply path.
    ------------------------------------------------------------------

    -- Fix 1: SN's minus-timer must NOT reach any respawn-affecting key. It used
    -- to be copied into felwood.flowerMinusDuration, which GetNodeState read as
    -- the respawn length — a stock SN install (120s) made every songflower count
    -- two minutes and then read available.
    do
        local ts = Import._MapTimerSettings({
            flowerMinusTimerDuration = 120,
            flowerUpDuration = 5,
            showFelwoodPins = true,
        })
        local fw = ts and ts.felwood
        if fw then
            check("SN flowerMinusTimerDuration is NOT imported", fw.flowerMinusDuration == nil)
            check("SN flowerUpDuration is NOT imported", fw.flowerUpDuration == nil)
            -- The rest of the felwood mapping is untouched by that removal.
            check("other felwood mapping survives", fw.showFlowerPins == true)
        end
    end

    -- Fix 7: node epochs merge, they do not replace. An SN profile's saved
    -- variables were written at ITS last logout, so its flower epochs are
    -- routinely hours stale while ours may be seconds old.
    if ns.Store and ns.Store.GetData and ns.Store.GetTimers and ns.Timers then
        local data = ns.Store.GetData()
        local savedTimers = data.timers
        local nowT = (ns.Timers._now and ns.Timers._now()) or os.time()

        data.timers = {
            flower = { [1] = nowT - 10, [2] = nowT - 1200 },
            tuber  = {},
            logs   = { rend = {}, onyH = {}, onyA = {} },
            timerVersion = 9,
            lastWeeklyResetAt = 42,
        }
        -- Clear trust so the local-hold guard is not what we are measuring here.
        local tt = ns.Store.GetTimers()
        tt.nodeTrust = {}

        Import._Apply({}, {
            accounts = {},
            manualLocations = {},
            deletedAIDs = {},
            timers = {
                -- node 1: STALE import vs our fresh live epoch -> ours survives
                -- node 2: fresher than ours                    -> import wins
                -- node 5: we have never seen it                -> import fills in
                flower = { [1] = nowT - 5000, [2] = nowT - 300, [5] = nowT - 600 },
                tuber  = { [3] = nowT - 400 },
                logs   = { rend = {}, onyH = {}, onyA = {} },
                timerVersion = 1,
                lastWeeklyResetAt = 7,
            },
        })

        local f = ns.Store.GetTimers().flower
        check("import does NOT clobber a fresher live flower epoch", f[1] == nowT - 10)
        check("a fresher imported epoch still wins", f[2] == nowT - 300)
        check("an unseen node is filled in by the import", f[5] == nowT - 600)
        check("imported tuber merges too", ns.Store.GetTimers().tuber[3] == nowT - 400)
        -- Non-node timer fields keep the previous replace semantics.
        check("non-node timer fields still replace", ns.Store.GetTimers().lastWeeklyResetAt == 7)

        data.timers = savedTimers
    end

    if verbose and ns.Print then
        ns:Print(pass and "  import selftest: PASS" or "  import selftest: FAIL")
    end
    return pass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("import", selfTest)
end
Import._SelfTest = selfTest
